# Module write handlers: the strict manifest-hash pilot limit

GH #2590 / REQ-501 (decision `docs/migration/decisions/0054-process-step-writes-entity.md` D6;
design `lib/letflow/design/gh2590-req501-module-write-handlers.md` OQ-R3, OQ-R7).

Audience: whoever deploys a build, and whoever supports a tenant that uses a module's write
handlers.

## Status

PR R3 adds the ACTIVATION checks. No handler is executed yet (R4b), so today the only visible
effects are (a) a definition that declares `module_writes` is validated when it is activated and
(b) a completion of a task whose node declares `module_writes` is refused with a 500 and the task
stays pending. No production tenant uses handlers.

## The rule (strict equality)

A process definition may call a module's write handler only if ALL of these hold at activation
(and, from R4b, again at every completion):

1. the definition version was created by that module's install (it carries the ownership stamp);
2. the manifest hash recorded at install (`tenant_modules.manifest_hash`) equals the stamp;
3. that installed hash equals the hash of the manifest compiled into the RUNNING build
   (`Letflow.Modules.Catalog.manifest_hash/1`);
4. the handler is registered in the compiled manifest, and the graph still matches the stamped body.

There is no drift tolerance: a deploy that changes a module's manifest surface (a `version` bump,
or a change to a handler's name, function, targets or arguments, or to the managed types) makes
rule 3 fail for every tenant that installed the older manifest, until the tenant is upgraded to
the new manifest. The upgrade path (re-stamping) is decision 0055 and does not exist yet.

The manifest hash covers the DECLARED surface only, not handler code. Bump the module `version`
whenever handler behaviour changes.

## What an operator sees after such a deploy

| Where | Symptom |
|---|---|
| Activating a new version of a handler-calling definition | 422 `entity_writes_invalid` with a violation `code: "module_write_hash_mismatch"` at the handler line's `index` |
| Rolling back to an older stamped version, or a promotion apply | the same 422 |
| A tenant whose module was installed before the hash column existed (pre-R2 install, no recorded hash) | the same 422 on activation: reinstall the module (OQ-R7, no backfill) |
| Completing an in-flight task of a handler-calling definition (R4b onward) | 403 `write_not_permitted` with the handler call's `line_index`; the task stays `pending`; the tenant audit log has an `entity_write.refused` entry with detail `hash_mismatch` |

Tasks are not lost: they complete after the module is upgraded to the matching manifest.

## Recovery

Until decision 0055 exists the recovery is to revert the deploy (restore the previous manifest),
or to reinstall the module in the affected tenant. Coordinate any deploy that touches a
handler-bearing module with the operators of its tenants BEFORE shipping it. Violations never
contain a hash; compare `tenant_modules.manifest_hash` with the build's
`Letflow.Modules.Catalog.manifest_hash("<module id>")` on a console to confirm a mismatch.

## Related

* A tenant-created, edited, imported, promoted copy of a stamped version has no stamp:
  `module_write_stamp_missing`. This is intended (decision 0054 D6 property 1).
* Deleting a stamped definition does not stop its pinned running instances: a completion of a node
  declaring `module_writes` fails closed (the pinned snapshot carries the graph).

## R4b removal note

R3's interim completion guard (`check_module_writes_unsupported/2`) is deleted by R4b. The R4b
executor MUST re-verify, at execution time and before any handler runs, the install row
(`tenant_modules`), the installed manifest hash against the stamp AND the compiled manifest hash,
and the body hash of the pinned snapshot. Activation-time checks alone are not enough: the
tenant's install state and the build can change between activation and completion.
