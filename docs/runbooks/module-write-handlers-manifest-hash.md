# Module write handlers: the strict manifest-hash pilot limit

GH #2590 / REQ-501 (decision `docs/migration/decisions/0054-process-step-writes-entity.md` D6;
design `lib/letflow/design/gh2590-req501-module-write-handlers.md` OQ-R3, OQ-R7).

Audience: whoever deploys a build, and whoever supports a tenant that uses a module's write
handlers.

## Status

PR R3 added the ACTIVATION checks; PR R4b executes the handlers on a HUMAN_TASK completion and
re-runs the same checks at every completion; PR R5 (this revision) does the same for a SERVICE_TASK
node (HTTP and script-bound), where a refusal cannot leave anything pending and lands the instance
in ERROR + DLQ instead (`docs/runbooks/service-task-entity-write-refusal.md`). A definition that declares
`module_writes` is validated when it is activated, and a completion of a task whose node declares
`module_writes` runs the handler inside the completion transaction (or is refused with a 403
`write_not_permitted` and the task stays pending, see the table below). No production tenant uses
handlers.

## The rule (strict equality)

A process definition may call a module's write handler only if ALL of these hold at activation
and again at every completion (the pre-transaction authorization, plus a no-lock recheck of the
install row and both hashes inside the transaction):

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
| Completing an in-flight task of a handler-calling definition (R4b onward) | 403 `write_not_permitted` with the handler call's DECLARED `line_index` (declarative lines come first, so a node with N declarative lines reports N for its first handler call); the task stays `pending`; nothing is committed; the tenant audit log has an `entity_write.refused` entry with detail `hash_mismatch` (the detail also reads `hash_mismatch` when the install row has no recorded hash) |
| A completion on a tenant that was never replayed to the `TASK_ENTITY_WRITES_APPLIED` v2 event schema | the same 403; audit detail `event_schema_outdated`; run `TenantProvisioning.replay_all_pending/0` (see Rollout) |
| A completion whose stamp, installed module, handler or pinned graph no longer matches | the same 403; audit detail `stamp_missing`, `stamp_mismatch`, `module_not_installed`, `handler_unknown`, `body_changed`, `arg_unknown` or `arg_missing` |
| Completing a SERVICE_TASK node that calls handlers (R5) | there is no request and no task that can stay pending: the instance goes to ERROR with one DLQ entry `{"line_index", "code": "write_not_permitted", "dispatch_id"}` and an `entity_write.refused` audit entry with the same detail atoms as above; the service result is not applied. Re-driving the instance after the cause is fixed is a separate operator action |
| A handler that rejects its arguments | 422 `validation_failed`, same `line_index`; audit detail `handler_invalid_arguments` |
| A handler fault (raise, throw, exit, contract violation) | 500 with no body detail; the log line carries the module id and handler name only |

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

## Rollout: replay every tenant BEFORE deploying a build that emits handler lines

A handler write adds three keys (`handler_module`, `handler`, `write_ordinal`) to the lines of the
`TASK_ENTITY_WRITES_APPLIED` instance event. Only schema version 2 of that event type accepts
them, and a tenant gains v2 ONLY when `Letflow.TenantProvisioning.replay_all_pending/0` has run for
it (provisioning and onboarding run the same replay; nothing in `lib/` calls the sweep at boot).
Before the first build that lets a tenant complete a handler-calling task is deployed, run
`replay_all_pending/0` and confirm every tenant's highest `TASK_ENTITY_WRITES_APPLIED` version in
`event_type_registry` is 2. The engine refuses a handler completion on a tenant without v2
(403 `write_not_permitted`, audit detail `event_schema_outdated`, nothing committed): that refusal
is the fail-closed backstop, not the plan.

## R5 note: replay_all_pending and the infra inventory

R5 lifts the last activation fence: before it, a SERVICE_TASK node declaring `module_writes` could
not be activated. The same `replay_all_pending/0` precondition applies, now also to service
completions. Inventory to re-run before enabling a handler-calling service definition in a tenant:
the count of active definition versions whose graph has `module_writes` on a SERVICE_TASK node
(expected zero before R5: activation refused it, and run time refused a hand-edited snapshot).

## R4b note: what the removal of the interim guard changed

R3's interim completion guard (`check_module_writes_unsupported/2`, a 500 for every completion of
a `module_writes` node) is gone. A deleted stamped definition whose pinned instances are still
running still fails closed: the node declares writes but the completion has no readable
definition row, so it is refused as an internal failure (500, nothing committed) by the existing
"lines but no plan" guard.
