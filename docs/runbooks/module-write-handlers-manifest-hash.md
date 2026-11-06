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
2. the manifest hash recorded at install (`tenant_modules.manifest_hash`) equals the stamp, or the
   stamp is in `tenant_modules.accepted_manifest_hashes` (REQ-769; written only by the upgrade apply,
   REQ-770, which is not built yet, so the list is empty everywhere until then);
3. that installed hash equals the hash of the manifest compiled into the RUNNING build
   (`Letflow.Modules.Catalog.manifest_hash/1`);
4. the handler is registered in the compiled manifest, and the graph still matches the stamped body.

There is no drift tolerance: a deploy that changes a module's manifest surface (a `version` bump,
or a change to a handler's name, function, targets or arguments, or to the managed types) makes
rule 3 fail for every tenant that installed the older manifest, until the tenant is upgraded to
the new manifest. The upgrade path (re-stamping) is decision 0055 and does not exist yet.

### Plan before apply (REQ-768)

`POST /api/v1/tenant/modules/:module_id/upgrade/plan` (`ModulesManage`) is the read-only dry run
(`Letflow.Modules.UpgradePlan`): per managed type the change class A, B or C with a reason code,
whether each stamped definition would pass the activation check after the upgrade, the upgrade steps,
`upgrade_path_available` (false for an install below the module's `min_upgradable_from`; the later apply
must refuse then), `applicable_on_boot` and a `plan_hash`. Its only write is one `planned` row in
`tenant_module_upgrades`. The apply itself (REQ-770) does not exist yet.

The manifest hash covers the DECLARED surface only, not handler code. Bump the module `version`
whenever handler behaviour changes.

## What an operator sees after such a deploy

| Where | Symptom |
|---|---|
| Activating a new version of a handler-calling definition | 422 `entity_writes_invalid` with a violation `code: "module_write_hash_mismatch"` at the handler line's `index` |
| Rolling back to an older stamped version, or a promotion apply | the same 422 |
| A tenant whose module was installed before the hash column existed (pre-R2 install, no recorded hash) | the same 422 on activation: reinstall the module (OQ-R7, no backfill) |
| Completing an in-flight task of a handler-calling definition when the ONLY reason is that the tenant's installed module differs from the compiled build (not upgraded yet; REQ-771) | 409 `upgrade_required` (the fixed `module-upgrade-required` problem, no module id, hash or line index); the task stays `pending`; nothing is committed; the audit entry is `entity_write.refused` with code `write_not_permitted` and detail `hash_mismatch`. Upgrade the module, then complete again |
| Completing an in-flight task of a handler-calling definition (R4b onward) | otherwise 403 `write_not_permitted` with the handler call's DECLARED `line_index` (declarative lines come first, so a node with N declarative lines reports N for its first handler call); the task stays `pending`; nothing is committed; the tenant audit log has an `entity_write.refused` entry with detail `hash_mismatch` (the detail also reads `hash_mismatch` when the install row has no recorded hash) |
| A completion on a tenant that was never replayed to the `TASK_ENTITY_WRITES_APPLIED` v3 event schema | the same 403; audit detail `event_schema_outdated`; run `TenantProvisioning.replay_all_pending/0` (see Rollout) |
| A completion whose stamp, installed module, handler or pinned graph no longer matches | the same 403; audit detail `stamp_missing`, `stamp_mismatch`, `module_not_installed`, `handler_unknown`, `body_changed`, `arg_unknown` or `arg_missing` |
| Completing a SERVICE_TASK node that calls handlers (R5) | there is no request and no task that can stay pending: the instance goes to ERROR with one DLQ entry `{"line_index", "code": "write_not_permitted", "dispatch_id"}` (code `upgrade_required` when the only reason is the not-upgraded module, REQ-771) and an `entity_write.refused` audit entry with the same detail atoms as above; the service result is not applied. Re-driving the instance after the cause is fixed is a separate operator action |
| A handler that rejects its arguments | 422 `validation_failed`, same `line_index`; audit detail `handler_invalid_arguments` |
| A handler fault (raise, throw, exit, contract violation) | 500 with no body detail; the log line carries the module id and handler name only |

Tasks are not lost: they complete after the module is upgraded to the matching manifest.

## Recovery

Upgrade the module in the affected tenant (REQ-768, REQ-770, decision 0080). As a `TENANT_ADMIN`
(`ModulesManage`): `POST /api/v1/tenant/modules/<module id>/upgrade/plan` returns the dry-run report
(entity change classes, whether every stamped definition still passes, `upgrade_path_available`,
`plan_hash`); `POST /api/v1/tenant/modules/<module id>/upgrade` with `{"plan_hash", "rationale"}` applies
that plan in one transaction when it has no data steps and no Class B or C row. The apply creates and
activates the new entity-definition versions, creates new process definitions as stamped drafts, ensures
the ledger storage, appends the replaced hash to `tenant_modules.accepted_manifest_hashes` (so the
definitions stamped with it keep working), and re-writes the row's version and hash. A stale hash is
409 `plan_mismatch`; a repeat of an applied plan answers the stored result. A module that declares no
`min_upgradable_from` has no upgrade path: reinstall it in the affected tenant. Not done by the apply:
`on_install/3` seeds of a newer version (a new document type of stock, for example) are not re-run.
Coordinate any deploy that touches a handler-bearing module with the operators of its tenants BEFORE
shipping it. Violations never contain a hash; compare `tenant_modules.manifest_hash` with the build's
`Letflow.Modules.Catalog.manifest_hash("<module id>")` on a console to confirm a mismatch.

## Related

* A tenant-created, edited, imported, promoted copy of a stamped version has no stamp:
  `module_write_stamp_missing`. This is intended (decision 0054 D6 property 1).
* Deleting a stamped definition does not stop its pinned running instances: a completion of a node
  declaring `module_writes` fails closed (the pinned snapshot carries the graph).

## Rollout: replay every tenant BEFORE deploying a build that emits handler lines

A handler write adds three keys (`handler_module`, `handler_name`, `write_ordinal`; all three or none, GH #2671) to the lines
of the `TASK_ENTITY_WRITES_APPLIED` instance event. Only schema version 3 of that event type accepts
them, and a tenant gains v3 ONLY when `Letflow.TenantProvisioning.replay_all_pending/0` has run for
it (provisioning and onboarding run the same replay, and `Letflow.TenantProvisioning.MigrationReplayBoot` runs it on every boot and always lets boot complete, so a failed boot replay is recorded, not fatal: GH #2727 persists the failure per tenant, readable with `bin/letflow rpc "Letflow.TenantProvisioning.list_replay_failures()"` (tenant id, fixed reason code, time; `[]` = clean). A later successful replay clears the entry.)
Before the first build that lets a tenant complete a handler-calling task is deployed, run
`replay_all_pending/0`, confirm `list_replay_failures/0` returns `[]`, and confirm every tenant's highest `TASK_ENTITY_WRITES_APPLIED` version in
`event_type_registry` is 3 (v2 is the R4a row: it uses the key `handler` and has no all-or-none rule, so a tenant at v2 is refused too). The engine refuses a handler completion on a tenant without v3
(403 `write_not_permitted`, audit detail `event_schema_outdated`, nothing committed): that refusal
is the fail-closed backstop, not the plan. Decision 0055 (rollout): `replay_all_pending/0` must
have run for ALL existing tenants before any build that emits handler lines (R4b onward) is
deployed; 403 `event_schema_outdated` only catches the tenant that was missed.

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

## A deploy that changes a module manifest refuses post tasks of older installs (T-1367)

The stamp and manifest hash of a module are written when the module is installed into a tenant. A
deploy that changes the module's manifest (for example the stock module registering new import
types) leaves a tenant installed from the older manifest with a different hash than the running
build. Completing a handler-calling task there, such as the stock document `post` task, is then
refused: 403 `write_not_permitted`, `line_index` 0, nothing committed. The cause is in the tenant
audit entry written by `record_entity_write_refusal_audit` (`hash_mismatch` or `stamp_mismatch`; the
other cause with the same shape is `event_schema_outdated`, see the rollout section above). There
is no upgrade path for the stamp yet.

QA operator recipe: read the audit entry to tell the causes apart. For `hash_mismatch` or
`stamp_mismatch`, reinstall the module in the tenant, or use a fresh tenant created after the
deploy. For `event_schema_outdated`, run `replay_all_pending/0` as described above. A 502 on a
complete that coincides with a QA deploy is the app container restarting, not a code fault.

Also found under T-1367: filtering `/entities/query` on an FK-promoted (`uuid`) column with
`in`/`not_in`/`eq` crashed with `Postgrex expected a binary of 16 bytes` because the values were
bound as text. The compiler now binds them as `Ecto.UUID` (allowlist entries of such columns carry
`pg_type: "uuid"`).
