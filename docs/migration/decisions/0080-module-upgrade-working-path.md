# 0080 -- Module upgrade, the working path: accepted earlier manifest hashes, one admin action, upgrade on deploy behind a flag, a clear refusal in the window, one-transaction apply

Status: Accepted for the prototype phase. Ruled by the portfolio manager under owner decision D-086 of 2026-11-04 (`ai-dala-portfolio/DECISIONS.md`: prototype mode, doubtful non-critical points are decided by the portfolio manager; security and production are NOT lifted). Every ruling below is the business analyst's default of REQ-767 (task T-1370), confirmed. Turning the upgrade on deploy ON in production stays the owner's decision. Nothing here changes code; the implementing entries REQ-768 to REQ-773 do.

Date: 2026-11-05. Requirement: REQ-767 (GH #3921). Written docs-only by task T-1394.

## What this record amends (exact sentences)

Amends 0055 (`0055-module-upgrade-migration-uninstall.md`):

* D5, bullet "A deploy never auto-upgrades a tenant.": the sentence "A deploy never auto-upgrades a tenant." is narrowed to: a deploy never auto-upgrades a tenant EXCEPT by the boot-time upgrade of Q3 below (flag, default off, plans of Class A only with no step). The rest of that bullet (fleet rollout as a loop of per-tenant upgrades by a platform operator) stands.
* D5, bullet "Three phases:": "(1) *Stage* (one transaction, xact lock) ... (2) *Migrate*: steps in batches ... (3) *Cutover*" is kept for plans that need the runner; for a plan that meets the Q5 conditions the three phases run inside ONE transaction (Q5). The `Task.Supervisor` runner and fencing of the D5 bullet "Runner (phase 2)." are untouched and still built by D12 step 2c.
* D5, bullet "Exclusion = the journal.": "a partial unique index on `(module_id)` WHERE `state IN ('running','failed')` (so a `failed` row blocks a new upgrade until it is resumed or abandoned ...)" is narrowed for rows of a one-transaction apply (Q5): such a failed row does not block.
* D2, open point 7 ruling: "Process-definition drafts created by an upgrade are activated MANUALLY; a module cannot declare auto-activation." is NOT changed (Q2 confirms it).
* D6, first bullet: "the upgrade creates new versions and never edits or deletes an existing definition row." is NOT changed (Q1 keeps it).

Amends 0054 (`0054-process-step-writes-entity.md`):

* D6 ruling: "At activation the stamp MUST equal the hash of the module version recorded in `tenant_modules`; otherwise activation is refused." becomes: at activation and at every completion the stamp MUST equal the installed hash OR be an element of `accepted_manifest_hashes` of that module's `tenant_modules` row (Q1). The sentence "It is written only by `Installs` and by the module-upgrade path (0055)" stands; the list is written only by the upgrade path.
* Amendment R3, "the installed manifest hash equals the stamp AND the hash of the manifest compiled into the running build (strict equality, OQ-R3 ...)": the stamp may now also be an accepted earlier hash; the installed hash must still equal the compiled hash (Q1).
* Pilot-limit paragraph (OQ-R3): "every in-flight task of a stamped, handler-calling definition answers 403 `write_not_permitted` (audit detail `hash_mismatch`) and stays `pending` until the upgrade path (decision 0055) re-stamps; recovery today is reverting the deploy." becomes: such a task answers 409 `upgrade_required` until the tenant is upgraded (Q4), then completes; nothing is re-stamped (Q1).

Amends `docs/runbooks/module-write-handlers-manifest-hash.md`, section "The rule (strict equality)": rule "2. the manifest hash recorded at install (`tenant_modules.manifest_hash`) equals the stamp;" and the sentence "There is no drift tolerance: ... The upgrade path (re-stamping) is decision 0055 and does not exist yet." REQ-769 rewrites that section, REQ-771 the table row "Completing an in-flight task ...", REQ-772 adds the flag.

## Questions and rulings

### Q1. Stamp after an upgrade

Options: (a) `tenant_modules` keeps a list of accepted earlier manifest hashes; (b) re-stamp in place; (c) strict rule kept, the upgrade creates new stamped versions and old ones stay refused.

**Ruling: (a).** A tenant migration adds `accepted_manifest_hashes` (text array, NOT NULL, default empty) to `tenant_modules` (REQ-769). Only the upgrade apply writes it, appending the hash it replaces. The run-time and activation check (`ModuleWrites.stamp_codes/3`, reached from activation and from `HandlerWrites.authorize_module_writes/2` at every completion) changes ONE condition: stamp hash = installed hash OR stamp hash is in the accepted list. The condition "installed hash equals the compiled hash" and every per-line and body check (handler registered now, arguments, body hash, graph still hashes to the stamped body) stay as they are.

Reason: (b) needs the `process_definitions_owner_stamp_immutable` trigger (migration `20261016100001_add_owner_stamp_to_process_definitions.exs`: the `owner_*` columns of a row are never updated) dropped or relaxed, and contradicts 0055 D6 and 0054 D6 property 2 ("a module-owned version is immutable"). (c) leaves every in-flight task refused and contradicts the runbook line "Tasks are not lost". (a) keeps both the trigger and the in-flight tasks.

Security reasoning (INV-1, INV-2, INV-6): the list lives in the tenant's own `tenant_modules` row (tenant schema, `:prefix` scoping, no cross-tenant read). A stamp is only ever written by the module install or upgrade (never by the definitions API), so a hash in the list was once a hash of the genuine module manifest installed in this tenant; accepting it widens nothing a caller can set. The guard against a stale hash being exploited is the unchanged check that the installed hash equals the compiled hash and that the handler, arguments and body still match NOW: an old stamp can only invoke a handler that is registered in the compiled manifest with the arguments of the compiled manifest. The list only grows (an apply appends); nothing removes entries in this record. Accepted-hash semantics for a rollback (0055 D9) are not decided here.

Files read: the stamp trigger migration; `lib/letflow/definitions/module_writes.ex` (`stamp_codes/3`, `compiled_differs?/2`); `lib/letflow/entities/handler_writes.ex` (`authorize_module_writes/2`); `lib/letflow/modules/installs.ex` (`installed_manifest_hash/2`); `lib/letflow/modules/stock/documents/posting.ex` (`ensure_active/3`: an active stock-stamped definition is kept, a draft is activated lazily only when none is active, so after an upgrade the old stamped active definition keeps posting).

### Q2. Process definitions the new pack ships

Options: drafts activated manually (0055 ruling), auto-activation, in-place edit.

**Ruling: the 0055 D2 ruling stands.** The upgrade creates new stamped DRAFT versions only for pack definitions whose graph differs from every stamped version of that name in the tenant, activates nothing, and the plan lists them as "draft, activate by hand". With Q1 (a) the old active version keeps working, so no write is refused in the meantime. Reason: activation stays a `:DefinitionsActivate` act (0052 D4); the prototype has no need to lift it. Files read: `posting.ex` `ensure_active/3`, 0055 D2.

### Q3. Upgrade on deploy

Options: keep "a deploy never auto-upgrades a tenant"; lift it for safe plans only; lift it for all plans.

**Ruling: lift it for safe plans only, behind a flag.**

* Flag: config key `:module_upgrade_on_boot` under the `:letflow` application (`Application.get_env(:letflow, :module_upgrade_on_boot, false)`), environment variable `LETFLOW_MODULE_UPGRADE_ON_BOOT`, which must be exactly `true` or `false` (anything else raises at boot, the way `LETFLOW_LOGIN_DISCOVERY_ENABLED` does in `config/runtime.exs`). **Default: off.** It is set to `true` on QA only. **Turning it on in production is the owner's decision**; production is not lifted by D-086.
* A boot-time child placed after `Letflow.TenantProvisioning.MigrationReplayBoot` in the supervision tree runs, when the flag is on, for every registered tenant and every installed module whose installed hash differs from the compiled hash: it computes the plan; if EVERY change is Class A (0055 D2 table) and the plan has NO step, it applies it as the system actor `00000000-0000-0000-0000-000000000000` (the actor of `lib/letflow/modules/exam/parent_rollout.ex`) with a fixed rationale text. The child never fails boot (it returns `:ignore`, like `MigrationReplayBoot`); each failure is recorded in the journal row (state `failed`, `error_code`) and logged with tenant id, module id and code as Logger metadata, not in the message.
* Any other plan (any Class B or C change, or any step, or a plan that answers `upgrade_needs_runner`) is NOT applied on boot; it is recorded as left for the admin action (`applicable_on_boot: false` in the plan report) and the tenant waits for the admin action of Q6.

Reason: a deploy that changes a manifest otherwise breaks every QA and demo tenant until an admin acts (Q4 window). Class A with no step cannot lose or reshape data (0055 D2). Files read: `lib/letflow/tenant_provisioning/migration_replay_boot.ex`, `lib/letflow/modules/exam/parent_rollout.ex`, 0055 D5.

### Q4. Refusal during the window between deploy and upgrade

Options: keep one public 403 `write_not_permitted` for every cause; answer a specific 409 for the not-yet-upgraded cause.

**Ruling: a specific 409 for exactly that cause.** When the cause is that the installed hash of the line's module differs from the compiled hash (the upgrade has not run), a task completion answers the existing problem of `Letflow.Api.Error.module_upgrade_required/0`: **HTTP 409, `extensions.code` = `upgrade_required`** (REQ-578). **Every other cause** (stamp missing or mismatching, module not installed, handler unknown, body changed, argument unknown or missing, event schema outdated) **keeps 403 `write_not_permitted`** from `Response.entity_write_refused/3`. The audit entry `entity_write.refused` keeps its detail `hash_mismatch` for the 409 case. REQ-771 builds it (it is NOT amended: the ruling is a second public code, not one).

INV-5 reasoning: INV-5 protects the caller who may not know a resource exists. This 409 is returned only after the caller has been authorized for the task (the caller holds the task: task visibility and the completion permission are checked before the engine's module-write authorization) and refers only to a module installed in the caller's OWN tenant. It reveals that the installed module is behind the compiled build, which a `ModulesManage` holder already sees on `GET /tenant/modules` and which names no hash, no version and no other tenant. A caller who may not know the task exists still gets the unchanged 404. The status and code reveal nothing about the stamp or the handler.

Files read: `lib/letflow/api/response.ex` (`entity_write_refused/3`, `module_upgrade_required/1`), `lib/letflow/api/error.ex` (`module_upgrade_required/0`), `lib/letflow/engine.ex` (`authorize_module_writes/7`, `check_applied_event_schema/5`), `lib/letflow/definitions/module_writes.ex` (`stamp_codes/3`).

### Q5. Apply shape

Options: always the supervised runner of 0055 D5; one transaction for small declarative plans; one transaction for all.

**Ruling: one transaction for small declarative plans, the runner for the rest.** A plan whose steps are all declarative (REQ-773 kinds) and which touch at most a configured number of records runs stage, migrate and cutover in ONE transaction under `pg_advisory_xact_lock` on (tenant prefix, module_id), with no runner. Any other plan answers **409 `upgrade_needs_runner`** until 0055 D12 step 2c's runner exists.

* Setting: config key `:module_upgrade_one_tx_max_records` under `:letflow`, environment variable `LETFLOW_MODULE_UPGRADE_ONE_TX_MAX_RECORDS`; **starting value 1000** records (summed over all steps of the plan, counted at plan time and re-counted at apply). A plan with no step touches 0 records and always qualifies.
* Failure: the transaction rolls back entirely (old version, old definitions, the accepted list, all records unchanged, no audit entry of the upgrade). The journal row is then written `failed` in its OWN transaction with an `error_code` from this closed set: `step_error` (a declarative step refused a record), `step_raised` (a raise, exit or throw was rescued), `activation_refused` (a definition activation or stamp check refused), `storage_refused` (ledger storage creation refused), `plan_mismatch` (the plan_hash no longer matches the tenant state), `lock_timeout` (the advisory or table lock was not obtained in time), `apply_timeout` (the statement timeout fired), `internal_error` (anything else). No exception text or stack trace is stored or returned (INV-4, INV-8).
* Journal lifecycle: `planned` does not block a new apply (a new plan call supersedes it); `done` and `abandoned` do not block; `running` blocks (a concurrent apply gets 409; the partial unique index of REQ-770 is on `(module_id)` WHERE `state = 'running'`); a `failed` row of a one-transaction apply does NOT block a new apply and is set `abandoned` by the next apply in the same transaction as that apply's `running` row. The 0055 D5 rule that a `failed` row blocks until resumed or abandoned applies to runner applies only and is added by 2c together with the runner.

Reason: the HTTP-request budget is enough for a bounded declarative apply, and one transaction gives the invariant "a failure leaves the tenant on the old version, fully working" with no fencing. The runner, fencing and catch-up of 0055 D5 are needed only for long data steps. Files read: `priv/repo/migrations/20261101100001_create_tenant_module_upgrades.exs` (the journal, no partial unique index yet), `lib/letflow/modules/tenant_module_upgrade.ex`, `lib/letflow/module_upgrade/writer.ex` and `capability.ex` (REQ-683), 0055 D5.

### Q6. One admin action

Options: keep the plan route and the apply route of 0055 D2; one combined route.

**Ruling: kept.** `POST /tenant/modules/:module_id/upgrade/plan` is the read-only dry-run report (it writes only a `planned` journal row); `POST /tenant/modules/:module_id/upgrade` is the one admin action: it carries the `plan_hash` and a non-blank rationale and applies. Both need `:ModulesManage`, tenant from the auth context only. Reason: the explicit hash binds the admin's decision to the plan they saw (0055 D2). Boot-time upgrade (Q3) uses the same apply function with the system actor.

## Split plan

Order of building (each entry depends on the earlier ones as its `depends_on` says):

1. REQ-768 (GH #3920): the plan route `POST /tenant/modules/:module_id/upgrade/plan` (dry-run report, change classes, `plan_hash`, planned journal row).
2. REQ-769 (GH #3919): `accepted_manifest_hashes` on `tenant_modules` and the stamp check that reads it (Q1).
3. REQ-770: the apply route `POST /tenant/modules/:module_id/upgrade` in one transaction, with the journal, audit and the real-HTTP stock posting test (Q1, Q2, Q5, Q6).
4. REQ-771: the 409 `upgrade_required` refusal for the not-yet-upgraded cause (Q4).
5. REQ-772: the boot-time child behind the flag (Q3).
6. REQ-773: declarative data steps inside the one-transaction apply (Q5, extends REQ-683).

A ruling different from the default would change: Q1 other than (a): REQ-769 and REQ-770 (and the runbook lines); Q2 other than "manual drafts": REQ-768 (report rows) and REQ-770; Q3 other than "Class A, no step, flag": REQ-772 (and REQ-768 `applicable_on_boot`); Q4 as one public 403: REQ-771 would be dropped; Q5 other than one transaction: REQ-770 and REQ-773; Q6: REQ-768 and REQ-770.

## Security review

Q1 (stamp acceptance) and Q4 (a new public refusal) are under the security invariants (`docs/agents/instructions/security-invariants.md`): INV-1, INV-2, INV-5, INV-6. The reasoning is stated in each section above; the verdict of the security reviewer for both is stated in the pull request of this record. Cross-tenant negative tests are required in REQ-768 and REQ-770.

## Not decided here

The runner, code steps, the tripwire, rollback (0055 D9), the fleet driver (0055 D12 step 4), the deploy-skew gate (`min_data_version`), removal of entries from `accepted_manifest_hashes`, and turning the boot upgrade on in production (the owner's decision).
