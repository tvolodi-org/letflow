# GH 2534 PR 7c: SERVICE_TASK `script` handler (hook 1) (decision 0053 D2, D3, D5, D7 kill switch, D8, D9; F-E)

Decision: `docs/migration/decisions/0053-tenant-scripted-rules.md` (ratified; D2, D3, D5, D7, D8,
D9, the D6 amendment, the 7b rulings, F-A..F-E, "Dependency hazards found by the 7a SECURITY
gate"). Stacked on 7b-2b (PR #2593, open); 7a, 7b-1 and 7b-2a are merged. Normative inputs:
`gh2534-7a-script-runtime.md` (ScriptRunner API, outcomes, watchdog, admission),
`gh2534-7b1-script-registry.md` (table, sha256, manifest, HMAC secret), `gh2534-7b2a-script-policy.md`
section 8 (the 7c read contract: `kill_switch_on?/1`, `check_reads/2`, detail codes
`scripts_disabled` and `reads_not_allowed`, redaction, SEC N1), `gh2534-7b2b-script-sod.md`.

Scope fence (supervisor, binding): script OUTPUTS go ONLY to process VARIABLES, through
`VariableMerge.merge/3` with real validations (0053 D2). NO entity writes from scripts in 7c (they
come after #2587/#2590 via module handlers). A script output that carries write commands is
refused with a stable code (section 8.2).

7c is split in two PRs (section 1). Both parts are designed here; their ACs are separate
(section 14).

Revision 2 (2026-10-15): split ACCEPTED and C10 CONFIRMED by the supervisor. SECURITY-REVIEWER
S1-S6 and CODE-DESIGN-VALIDATOR C1-C12 resolved; each resolution is tagged [SEC Sn] / [CDV Cn].

## 0. Verified facts (this worktree, branch head cd5b5db5)

### 0.1 SERVICE_TASK today

* Route kinds are `:inline_url | :catalog_service` only (`engine/service_task.ex:81`); the parser
  picks the kind from `service_id`/`endpoint` and refuses neither present
  (`:missing_url_and_service_id`, `service_task.ex:197-234`). Retry classes timeout/network/429
  (`:436-442`), backoff `min(base * 2^n, cap)` (`:475-479`).
* Graph CHK-10 requires `endpoint` unless `service_id` is present (`definitions/graph.ex:974-994`);
  it runs at definition create/update (`definitions.ex:559`, `:1680`).
* Activation (`Letflow.Engine`): `prepare_service_task_dispatch/6` (`engine.ex:993-1078`) parses
  config and builds arm attrs (`resolve_service_task_arm_attrs/6`, `:1100-1144`); a catalog route
  resolves the instance's OWN pin at activation (`:1149-1209`) and freezes a `config_snapshot`
  (`:1252-1274`). Arm rows are inserted by `build_service_task_dispatch_multi/5` (`:1437-1452`) at
  every hop-chain site. `{:catalog_resolution_error, ...}` is handled at `engine.ex:640, 1067-1076,
  1409, 3514, 4493, 4579-4590`.
* Dispatcher `Letflow.Engine.ServiceTaskDispatcher`: table `service_task_dispatches`, status CHECK
  `pending | advanced | given_up` (`service_task_dispatcher.ex:121-127,185`); claim = unlocked join
  on `instance_projections.status == :active` then `FOR UPDATE SKIP LOCKED` by id (`:419-440`);
  one transaction per row that locks the dispatch row and runs the HTTP call INSIDE it
  (`:747-795`); success commits the row `advanced` BEFORE the engine applies the body in a second
  transaction (`:1213-1223`, `:560-649`); a failed re-entry is never re-armed (at-most-once,
  `:629-647`). `route_kind_atom/1` accepts only the two HTTP strings (`:1190-1194`).
  `cancel_pending_dispatches/4` flips only `pending` rows (`:473-495`), called from
  `cancel_instance` (`engine.ex:6021`).
* Engine re-entry `advance_after_service_task_outcome/4` (`engine.ex:3641-3669`): re-locks the
  dispatch row (`:3719-3730`), locks the projection, merges with `VariableMerge.merge(vars, body,
  nil)` (`:3691`: NO validations), advances (`:3751-3837`), persists with a nested
  `repo.transaction(multi)` (`:3914-4073`) and appends `SERVICE_TASK_COMPLETED` with the full
  `decoded_body` (`:4079-4104`); a no-matching-edge after the node writes EXECUTION_ERROR + DLQ in
  the open transaction (`:3853-3880`); give-up calls `set_instance_error/2` (`:4117-4124`).
* Poller `ServiceTaskDispatcher.Poller` is one GenServer that loops every provisioned tenant schema
  per tick and calls `poll_and_dispatch/1` inline (`service_task_dispatcher/poller.ex:64-83`); it is
  started by `Letflow.Supervisor.Pollers`, gated `:start_service_task_dispatcher`
  (`supervisor/pollers.ex:102,156-158`).

### 0.2 Variables, incidents, replay

* `VariableMerge.merge/3` takes precomputed per-key validations; `nil` = none (`variable_merge.ex:
  211-245`). Real validations come from `VariableSchema.variable_validations/5`
  (`variable_schema.ex:279-299`), which needs the instance's `definition_id`.
* `ExecutionError.append_multi/3` (`execution_error.ex:192`) writes EXECUTION_ERROR, flips the
  projection to `:error` and enqueues the DLQ row (`Dlq.enqueue`, `:254`); `error_type` is open
  (`atom()`, `:99-107`); `details` is persisted as `error_detail`. `Dlq.retry/2` is bookkeeping only
  (`dlq.ex:235-263`): nothing re-executes an instance step.
* `Reconstruction.apply_event/4` has clauses for INSTANCE_STARTED, TASK_COMPLETED,
  INSTANCE_CANCELLED, EXECUTION_ERROR, SUB_PROCESS_COMPLETED, TIMER_FIRED (`reconstruction.ex:
  569-722`); any other type fails replay with `{:unrecognized_event_type, ...}` (`:724-726`).
  **SERVICE_TASK_COMPLETED has no replay clause** (pre-existing gap, residual R6).
* `EventStore.append/2` refuses an instance that is `:completed`/`:cancelled`
  (`{:instance_terminated, _}`) and dedupes by idempotency key (`is_duplicate`) (`event_store.ex:
  150-218`); `platform_actor_id/0` (`:891`).

### 0.3 Event type registry

* Instance event types are seeded per tenant from `@platform_event_type_seed_attrs`
  (`tenant_provisioning.ex:898`, SERVICE_TASK_COMPLETED entry `:1188-1204`) by
  `maybe_seed_platform_event_types/2` (`:1274-1283`), which `replay_migrations/2` runs after every
  default-manifest replay (`:387-414`), i.e. at provisioning AND at the boot replay of every
  existing tenant (`replay_all_pending/0`, `:446-466`; caller `migration_replay_boot.ex:91`). A
  duplicate `(name, schema_version)` counts as success, so adding a NEW name reaches existing
  tenants on the next boot. `Letflow.Entities.EventTypes` (`entities/event_types.ex`) seeds only the
  three entity-record types; it is NOT the instance registry 0053 D9 names.
* INSTANCE_STARTED's schema constrains only `definition_id`, `correlation_key`,
  `initial_variables` (`tenant_provisioning.ex:900-912`): a new pin field needs no registry change.

### 0.4 Pins

* `PinResolver.kind :: :catalog_entry | :variable_schema | :module` (`pin_resolver.ex:190`);
  `pinned_version` = `kind, ref, resolved_id, version (string), source` (`:199-205`); `Lookup`
  struct, three ENFORCED fields (`:254-279`); `default_lookup/0` (`:295-303`); `resolve/4` collects
  refs per node type (`:333-372`); overrides are verified against the lookup (`:396-430`);
  `merge_effective_pins/3` normalises string kinds with a CLOSED `normalize_kind/1` (`:552-614`:
  an unknown string raises `FunctionClauseError`); `apply_inheritance/2` lets a PARENT pin win over
  a child's own pin of the same `{kind, ref}` and drops any extra field (`:703-758`); `pin_for/3`
  (`:775-780`). `Engine.pin_lookup/2` uses `ServiceCatalog.PinLookup.build/1`, which copies the
  other lookups from `default_lookup/0` (`engine.ex:1470-1473`, `service_catalog/pin_lookup.ex:44-46`).
  Pins are embedded as `pinned_versions` in INSTANCE_STARTED (`engine.ex:2074-2094`).
* `PinRebind` is the only later pin writer; its entry kinds are a closed list
  (`pin_rebind.ex:299-309`); a rebind sets `resolved_id: nil` (`pin_resolver.ex:583-592`).

### 0.5 Definition activation paths (all three make a definition `:active`)

* `Definitions.activate/2` -> `run_activate_transaction/4` (row `FOR UPDATE`, optional injected
  service-scope validator, semantic validation, `activate_draft/3`) (`definitions.ex:750-763,
  2310-2339, 2409`).
* Promotion: `Promotion.activate_new_definition/2` (`definitions/promotion.ex:487-493`).
* Version rollback: `swap_active_pointer/3` (`definitions.ex:2669-2685`).

### 0.6 Script registry, policy, secret (7b)

* `Scripts.get/3` (`scripts.ex:111-123`); `retire/5`/`revoke/5` -> `transition/8` with
  `lock_row!/3` (`:554-598`); retire does NOT check definition references today (7b-1 6.4 defers it
  to 7c). `Validation.manifest/1` keys (`scripts/validation.ex:20-21,55`); output check helper
  (`:335`). `ScriptRule` fields (`scripts/script_rule.ex:17-41`).
* `Policy.kill_switch_on?/1` (`scripts/policy.ex:101`, true when the row is absent), `check_reads/3`
  (`:142-161`), `readable_master?/2` (`:122`); `Policy` aliases `Letflow.Entities.Definitions`
  (`:35`): the Scripts context already depends on Entities.
* `HmacSecret.ensure/1` (`scripts/hmac_secret.ex:30-57`), `exists?/1` (`:61-69`); reference
  `sec://tenant/<slug>/platform/script-input-hmac`; only `HmacSecret` passes `platform: true`
  (source-scan test, 7b-1). `Secrets.resolve/2` with `consumer: :script_runner` may resolve only
  `:script_hmac` (`secrets.ex:289-300,367`) and returns `key_id`.
* Backfill `Mix.Tasks.Letflow.BackfillScriptHmacSecrets.backfill/1` returns `{created,
  already_present, failed}` (`lib/mix/tasks/letflow.backfill_script_hmac_secrets.ex`).
* Run-time role re-derivation for a user id: `Identity.list_effective_role_names/2`
  (`identity.ex:961`), `Identity.get_user/2` (`:352`), `Identity.active_user?/1` (`:2198`),
  `Authorization.has_permission_in_scope?/3` (`api/authorization.ex:1411`); the publish route
  computes the publisher's `:EntitiesRestrictionsManage` the same way (`routers/script_rules.ex:329-337`).
  NOT used by 7c (C10 removes every opt-in path, [CDV C3]); recorded for when C10 is lifted.

### 0.7 Runtime (7a)

* `ScriptRunner.run/3 :: {:ok, %{output, stats}} | {:error, code, detail}`, eight codes
  (`engine/lua/script_runner.ex:52-60,96-128`); stats only on success; `input_dropped` in stats;
  the watchdog acquires the `ScriptAdmission` slot and monitors the CALLER, the worker is linked to
  the watchdog (7a section 4).

### 0.8 LuaScriptAudit

* `LuaScriptAudit.execute_script_for_audit/6` is the ONLY writer of `lua_script_execution_audit`
  (`engine/lua_script_audit.ex:135,190-199`) and has no production caller. Test users:
  `test/letflow/engine/lua_script_audit_test.exs`, `test/letflow/engine/lua/manifest_executor_audit_test.exs`.
  `Lua.Executor` implements its `Executor` behaviour (`engine/lua/executor.ex:247,298`).

### 0.9 Layering and boundaries

* `lib/letflow/engine.ex` and `lib/letflow/engine/**` (recursive) contain NO reference to
  `Letflow.Entities` and NO reference to `Letflow.Scripts` (grep, this branch).
* `mix letflow.check_boundaries` checks ONLY module-subdir edges (`lib/letflow/modules/<id>/`):
  Rule 0 returns `:ok` for any other target (`lib/mix/tasks/letflow.check_boundaries.ex:207-250`).
  There is no engine->entities rule today; "checked against the boundaries config" therefore needs
  a new rule (section 11.4).
* Entity reads: `Record.Latest.get/3` (`entities/record/latest.ex:86-98`; `deleted` flag `:31`),
  `Query.Compiler.compile/2` (bound parameters, allowlisted fields, `entities/query/compiler.ex:
  153-171`), `FieldGrants.load_restrictions/3` (per-user anti-join, `entities/query/field_grants.ex:
  84-104`), `Definitions.get_active_definition_by_name/2`, `entity_type_restrictions` (TypeAccess).
  No org-scope column exists on entity records (grep `scope` over `lib/letflow/entities/`).

### 0.10 Alerts

* `Letflow.Obs.Alerts` has a FIXED set of four triggers (moduledoc table), edge-triggered via
  `alert_trigger_state` (`obs/alerts.ex:395-430`), hooks fired fire-and-forget (`:459+`).

### 0.11 Tenant migrations

Latest tenant migrations `20261014000001..3` (scripts), `20261014100001..2`
(`tenant_provisioning.ex:666-680`).

### 0.12 Boot order, cancel lock order, test-schema reset, tenant status [CDV C5, C6, C10, SEC S5]

* `Letflow.Application` children: `Letflow.Supervisor.Infrastructure` FIRST, then the platform-tenant
  check, then `Letflow.Supervisor.Pollers` (`application.ex:62-76`). `TenantProvisioning.
  MigrationReplayBoot` is Infrastructure child 3 and runs `replay_all_pending/0` SYNCHRONOUSLY in
  `start_link/1` (`tenant_provisioning/migration_replay_boot.ex` moduledoc; `supervisor/
  infrastructure.ex:50,223`). Hence every existing tenant's event-type seed (0.3) completes before
  any poller, including the new script poller, starts.
* `cancel_instance` Multi order: `:timer_cancellations`, `:service_task_dispatch_cancellations`,
  THEN `:instance_projection` (`engine.ex:5995-6025`); the comments state the rule "dispatch-table
  lock before the projection lock" to avoid AB-BA deadlocks.
* Pooled test schemas are reset by `TenantTemplate.reset_clone_schema!/3`, which TRUNCATEs dirty
  tables and relies on "no BEFORE TRUNCATE trigger" on the immutable tables (`test/support/
  tenant_template.ex:621-683`); a trigger change is treated as definition drift.
* `Identity.Tenant.status :: :active | :migrating | :inactive` (`identity/tenant.ex:79`);
  `Identity.get_tenant/1` (`identity.ex:1501`).
* No file under `lib/letflow/engine*` references `Letflow.Obs` today (grep).

## 1. Split and merge order

| PR | Content | Merge |
|---|---|---|
| **7c-1** | route kind `:script`, graph check, `:script` pin kind, activation refusal (3 paths), retire block, `script_task_dispatches` + poller + lease + CAS apply + busy retry, kill switch at run, output validation + write-key refusal + VariableMerge with real validations, events + registry + replay clauses, per-run record + HMAC + missing-secret alert, LuaScriptAudit retirement, worked example, backfill re-run test, WASM route test. A version whose manifest declares non-empty `reads` is REFUSED at activation (`script_reads_unsupported`) and, as a backstop, at run time (`reads_not_allowed`). | first, after 7b-2b (#2593) |
| **7c-2** | `Letflow.Engine.ScriptReadPort` behaviour, `Letflow.Entities.ScriptReads` implementation, config injection, `check_boundaries` Rule 6, run-time `check_reads`, redaction, N1, row caps, no caching; lifts the 7c-1 `reads` refusal. Closes #2534. | second |

7c-1 is safe on its own: no entity read path exists until 7c-2, and nothing a tenant can publish
in 7c-1 reaches an entity.

## 2. Decisions taken in this design (each with its reason)

| # | Decision | Reason |
|---|---|---|
| C1 | NEW tenant table `script_task_dispatches`; `service_task_dispatches` is not reused. | The HTTP row commits `advanced` BEFORE the engine applies (two commits, `service_task_dispatcher.ex:1213`), has no lease, no `running` state and no attempt-keyed CAS, and its claim query takes any `pending` row (`:419-440`): reusing it would change the HTTP status CHECK, the claim query and the cancel step, all regression risk on the at-most-once HTTP path the issue says stays unchanged. A separate table keeps HTTP byte-unchanged and gives the script row the D2 shape (`running` + lease, CAS keyed by attempt, terminal status written in the SAME transaction as the instance effect, which also avoids anti-pattern "dispatch row committed terminal, then a rolled-back re-entry"). Cost: one arm branch and one cancel step in the engine. |
| C2 | A separate `ScriptTaskDispatcher.Poller` GenServer (gated `:start_script_task_dispatcher`), claiming ONE row per claim transaction and running it before claiming the next; tenants are served ROUND-ROBIN, one row per tenant per pass, under a global wall-time budget per tick (5.1a) [SEC S2]. | Script runs (<= 7 s each with the caller margin) must not delay HTTP dispatch and vice versa; one-row claims keep every claimed row's lease alive; round-robin under a tick budget stops one tenant's backlog from delaying every other tenant. The poller process IS "the dispatcher" whose death the 7a watchdog observes. |
| C3 | Lease = `5_000` (platform max wall clock) + `2_000` (7a caller margin) + `lease_margin_ms` (config, default 23_000, clamped >= 1_000) = 30 s by default, set at claim. | D2: "at least the maximum wall clock plus a margin". It is set before the manifest is loaded, so it uses the platform maximum, not the version's own timeout. |
| C4 | The CAS key is the row id plus `(instance_id, node_id, attempt)` and `status = 'running'`, read `FOR UPDATE` in the apply transaction. | D2/F-E: a duplicate or late apply (or one racing the lease sweeper) finds no matching row and writes nothing. `attempt` increments at every claim, so an apply from an older claim never matches. |
| C5 | Busy policy: on `script_busy` the row goes back to `pending` (same CAS) with `next_attempt_at = now + min(500 * 2^busy_retries, 30_000)` ms, no jitter, no instance event; after `busy_retry_limit` (default 10) rescheduled attempts the next busy outcome is terminal (`script_busy`, detail `busy_retries_exhausted`) and becomes an incident. Every other outcome is terminal on its first occurrence. | D7: only `script_busy` is retriable; a cap is needed so a permanently saturated node cannot loop forever. Deterministic backoff matches `ServiceTask.compute_service_task_backoff_ms/3`. |
| C6 | An expired lease (`status = 'running' AND lease_expires_at < now`) is turned by the poller's sweep into a terminal `timeout` / detail `lease_expired` incident through the same CAS; it is NEVER put back to `pending`. | D2: never re-run automatically; the CAS makes a late apply from a slow-but-alive dispatcher a no-op. |
| C7 | Pin `:script`: `ref` = script key, `version` = the integer version as a string (existing `pinned_version` convention), `resolved_id` = `script_rules.id`, plus a NEW field `sha256`. A definition that binds two different versions of the same key is refused (`script_version_conflict`). Script pins are NOT overridable, NOT rebindable (`PinRebind` keeps its closed kind list) and NOT inherited by or from sub-process children. | `{kind, ref}` must identify one pin; D3 requires the frozen `(key, version, sha256)` to never change for an in-flight instance; `apply_inheritance/2` would replace a child's own version with the parent's and drop `sha256` (0.4), so the child would run a version its definition does not name. A script version is part of a definition's own logic, bound by the node attribute and the activation check. |
| C8 | Activation is refused in ALL three activation paths (0.5) and, independently, an instance start refuses an unresolvable script pin. | D2 + F8: pack/promotion-installed definitions must be guarded; start-time refusal is defence in depth (a version retired after activation of a now-deprecated definition cannot be newly pinned, D1). |
| C9 | Instance variables are read by the ENGINE (projection, no lock) and only the 7c-2 master reads go through the port. | The instance's own variables are engine data; routing them through `Letflow.Entities` would invert ownership and add a needless edge. "Pre-fetch" = both sources assembled host-side before the run (section 5.3). |
| C10 | A binding whose manifest opts into restricted data (non-empty `restricted_inputs`, or any `reads[].restricted_fields`) is REFUSED at activation (`script_restricted_opt_in_unsupported`) and rejected at run time as a backstop. | 0053 D5: "the host refuses activation/publish if [a derived output] maps to a target field with fewer restrictions". Hook 1's only targets are process variables, which carry NO field restrictions, so every target has fewer restrictions; the manifest has no key to declare derived outputs. Restricted fields listed only in `fields` remain readable-and-REDACTED (7b-2a P12), and run-time re-checks still apply (7c-2). Lifting this needs restricted variables or Record E. **CONFIRMED by the supervisor 2026-10-15** as an interim limit (narrows 0053 OP2's opt-in until variables can carry restrictions; recorded in 0053's notes by letflow-2). Split 7c-1 / 7c-2 ACCEPTED the same day. |
| C11 | Write-command recognition: the top-level output key namespace `$` is reserved for host channels; ANY top-level key starting with `"$"` (the designated future channel is `"$writes"`) is refused: outcome `output_invalid`, detail `writes_not_allowed`. The same pure check runs at stored-test evaluation and dry-run, and the manifest refuses `output_schema.properties` names starting with `"$"` (422 `invalid_manifest`). | Supervisor fence: no entity writes; a precise, stable, cheap test that cannot collide with a legitimate variable (no shipped variable starts with `$`); refusing at save/publish/dry-run tells authors early. Nested `$` keys inside a variable's value are plain data and allowed. |
| C11a | [SEC S1] A hook-1 binding requires a CLOSED output schema: `output_schema` has top-level `"type": "object"`, a NON-EMPTY `properties` map and `"additionalProperties": false` (ONE predicate, `Scripts.Runtime.closed_output_schema?/1`, identical to 4.5 and shared by activation, `prepare_run/3` and the apply step; late gate note b); otherwise activation is refused (`script_output_schema_open`) and a run is rejected as a backstop (`script_rejected` / `output_schema_open`). At run time only the declared top-level properties are merged (`Map.take(output, declared)` after validation); an undeclared key fails validation first (`output_invalid` / `output_schema`). | Under SoD the publisher is not the definition author; an open schema would let a script overwrite ANY instance variable (gateway conditions, later HTTP body inputs). A closed schema makes the set of variables a script can write visible to, and accepted by, whoever activates the definition. |
| C12 | The per-run record is an instance-stream event `SCRIPT_RUN_RECORDED` with a closed, value-free payload (section 7); the applied output is recorded separately in `SCRIPT_TASK_COMPLETED` (the replay source). | D9 places the per-run record on the instance stream and forbids values in it; D5 requires replay to apply RECORDED results, which needs the output somewhere; it is instance variable data, the same class as TASK_COMPLETED `output_variables` (and only ever lands in variables). |
| C13 | One terminal attempt = one `SCRIPT_RUN_RECORDED` (applied or failed, including a pre-run rejection and a lease expiry, distinguished by `phase`). A busy attempt that is rescheduled writes none. An attempt whose instance is no longer active at apply writes no event (append refuses completed/cancelled instances, 0.2); its trace is the dispatch row's `outcome`/`outcome_detail`. | Every incident is attributable; no event for something that changed nothing. |
| C14 | The HMAC covers `canonical({"ctx": {instance_id, node_id, token_id, now}, "input": input})`, HMAC-SHA256 under the tenant key resolved through `HmacSecret`, recorded as lowercase hex plus the secret `key_id` (`#n`). The key never leaves a closure (`HmacSecret.hmac_fun/1`); the closure catches every crypto failure and returns a fixed `:hmac_failed` (7.2) [SEC S3]. | ctx changes the output (uuid, now), so it belongs in "same inputs"; storing `key_id` lets an auditor recompute with the right key after rotation; a closure keeps the plaintext out of crash reports (function arguments in a `FunctionClauseError` are printed, closure captures are not). |
| C15 | Missing secret: outcome `script_rejected`, detail `hmac_secret_missing`, plus ONE edge-triggered operator alert per tenant (new trigger `script_hmac_secret_missing`, re-armed by the next run that finds the key). Nothing creates a key on this path. | 0053 D9 / advisor Q11 ("never lazily"); "one alert" = edge-triggered, like the existing four triggers. |
| C16 | Incidents use `error_type :script_task_failed`, `affected {:node, node_id}`, a FIXED reason sentence per outcome code, `details` = `%{outcome, detail, fail_code, script_key, script_version, attempt}` (codes and constants only). | INV-8 / D7: stable codes only; no rejected value (unlike the human-task merge path) and no fail `details` (a script can put input values there). |
| C17 | `LuaScriptAudit` retirement: delete `execute_script_for_audit/6` and its insert path; keep `AuditRecord` (read) and the `Executor` behaviour (still implemented by `Lua.Executor`); a tenant migration adds a ROW trigger refusing INSERT/UPDATE/DELETE on `lua_script_execution_audit`. NO TRUNCATE trigger [CDV C6]. | Advisor Q11: no new writes, table stays read-only history. TRUNCATE is left open exactly like `audit_entries` (0.12): the pooled test-schema reset depends on it, and no `lib/` code truncates tenant tables. |
| C18 | Engine -> Scripts calls go through ONE facade, `Letflow.Scripts.Runtime`; engine -> Entities only through the port (7c-2), resolved from config at run time. The DISPATCHER (engine) calls `Obs.Alerts`, never `Letflow.Scripts` [CDV C1, C8]. | Minimises the new engine->scripts surface for REVIEWER; keeps 0053 F10 ("the engine names no `Letflow.Entities` module") mechanically checkable; keeps Scripts free of an Obs edge. |
| C20 | [SEC S5] `prepare_run/3` fails closed when the tenant is not `:active` (`:migrating` or `:inactive`): `script_rejected` / `tenant_inactive`. | A deactivated tenant's scripts must not keep running from pending rows; a distinct code keeps the operator's kill-switch signal (`scripts_disabled`) unambiguous. |
| C21 | [CDV C9] A lease-sweep apply that keeps failing is bounded: column `sweep_failures`; each failed sweep apply increments it in its own tiny CAS update; at 5 the sweep stops selecting that row, logs ONE error line (dispatch id, tenant schema, tag `sweep_stuck`) and emits telemetry; per tick at most one aggregated warning per tenant with the failure count. | A permanently failing row must not produce unbounded logs or starve the sweep of other rows (the sweep is ordered by `lease_expires_at` and capped). A stuck row is visible (log, telemetry, row column) and is an operator matter. |
| C19 | Retire of a version bound by an ACTIVE definition -> 409 `version_in_use`; revoke is never blocked. Activation locks the bound `script_rules` rows `FOR SHARE`; retire already locks the row `FOR UPDATE`, so the two serialise. | D3: "Retiring a script referenced by an active definition is blocked"; revoke is the incident action and fails pinned instances closed at run. |

## 3. Data model (7c-1)

### 3.1 Tenant migration `20261015100001_create_script_task_dispatches.exs` (next free slot, 19a)

`if prefix()` guard; entry in `@tenant_scoped_migration_manifest` after `20261014100002`
(ELIXIR-DEV takes the next free timestamp if a sibling PR claims it). No SQL interpolates anything
but `prefix()` (INV-7).

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `instance_id` | uuid NOT NULL | |
| `token_id` | uuid NOT NULL | |
| `node_id` | text NOT NULL | |
| `script_key` | text NOT NULL | CHECK `~ '^[a-z][a-z0-9_]{0,63}$'` |
| `script_version` | integer NOT NULL | CHECK `> 0` |
| `script_sha256` | text NOT NULL | CHECK `~ '^[0-9a-f]{64}$'`; frozen from the pin at arm |
| `status` | text NOT NULL default `'pending'` | CHECK in `pending, running, applied, failed, cancelled` |
| `attempt` | integer NOT NULL default 0 | CHECK `>= 0`; +1 at every claim |
| `busy_retries` | integer NOT NULL default 0 | CHECK `>= 0` |
| `sweep_failures` | integer NOT NULL default 0 | CHECK `>= 0`; C21 |
| `next_attempt_at` | utc_datetime_usec NOT NULL | |
| `claimed_at` | utc_datetime_usec NULL | |
| `lease_expires_at` | utc_datetime_usec NULL | CHECK `status <> 'running' OR lease_expires_at IS NOT NULL` |
| `claimed_by` | text NULL | `Atom.to_string(node())`, CHECK `char_length <= 255` |
| `event_time` | utc_datetime_usec NOT NULL | the arm-time `now` of the hop chain = `ctx.now` (D5) |
| `triggering_user_id` | uuid NULL | the command actor at arm; NULL for platform-actor hops |
| `outcome` | text NULL | CHECK in `ok, script_error, budget_exceeded, memory_limit_exceeded, output_invalid, timeout, script_failed, script_rejected, script_busy` |
| `outcome_detail` | text NULL | CHECK `~ '^[a-z][a-z0-9_]{0,63}$'` (codes only; closed list in 5.6) |
| `finished_at` | utc_datetime_usec NULL | |
| `inserted_at`, `updated_at` | utc_datetime_usec | every write sets `updated_at` (anti-pattern 4183) |

Indexes: `(next_attempt_at) WHERE status = 'pending'`; `(lease_expires_at) WHERE status =
'running'`; `(instance_id)`.

Trigger `script_task_dispatches_guard()` (`BEFORE UPDATE`, ERRCODE `LF001`): refuses any UPDATE
whose `OLD.status IN ('applied','failed','cancelled')` and any change of `id, instance_id,
token_id, node_id, script_key, script_version, script_sha256, event_time, triggering_user_id`.
DELETE is not refused (a future instance purge must be able to remove rows).

Ecto schema `Letflow.Engine.ScriptTaskDispatcher.ScriptTaskDispatch` (no `@schema_prefix`, every
call passes `prefix:`), changesets: `arm_changeset/2` (identity columns, `event_time`,
`triggering_user_id`, `next_attempt_at`; status/attempt not castable), and no other changeset: the
claim, reschedule, finish and cancel writes are explicit `update_all` with full predicates, each
setting `updated_at`.

### 3.2 Tenant migration `20261015100002_lua_script_audit_read_only.exs`

Function `lua_script_execution_audit_read_only()` raising `LF001`; one trigger `BEFORE INSERT OR
UPDATE OR DELETE ... FOR EACH ROW` on `lua_script_execution_audit`. No TRUNCATE trigger (C17,
[CDV C6]): the pooled test reset (0.12) keeps working unchanged and the table's definition digest
is simply re-baselined by the template build. Down drops the trigger and the function.

## 4. Route kind, graph check, pin, activation (7c-1)

### 4.1 Node attributes and config parse

A SERVICE_TASK node binds a script with `"script_key"` (string) and `"script_version"` (integer).

`Letflow.Engine.ServiceTask.Config` gains `script_key :: String.t() | nil`, `script_version ::
pos_integer() | nil`; `route_kind :: :inline_url | :catalog_service | :script`.
`parse_config_from_node_attributes/1`: `script_key` present (non-empty string) -> route `:script`;
requires `script_version` a positive integer (else `{:invalid_script_reference, :version}`) and the
key regex (else `{:invalid_script_reference, :key}`); `script_key` together with `endpoint` or
`service_id` -> `{:error, :conflicting_routes}`. `method`, `timeout_ms`, `retry_limit`, `headers`,
`body_template` are ignored for `:script`. `config_parse_error` gains `:conflicting_routes |
{:invalid_script_reference, :key | :version}`. The HTTP branches are unchanged.

### 4.2 Graph checks (`definitions/graph.ex`)

* CHK-10 widened: a SERVICE_TASK needs `endpoint`, `service_id` OR `script_key`.
* New CHK-10s (in `validate_node_attributes/1`): a node with `script_key` must have a key matching
  `^[a-z][a-z0-9_]{0,63}$` and an integer `script_version >= 1` (violation `:invalid_script_reference`),
  and must not also carry `endpoint` or `service_id` (`:conflicting_service_task_routes`). Messages
  name the node id only.
* Definitions without `script_key` see no change (anti-pattern 4670: grep the shipped definitions and
  tests for `script_key` before merging; none expected).

### 4.3 Pin kind `:script` (`pin_resolver.ex`)

* `kind` adds `:script`; `pinned_version`/`effective_pin` gain `optional(:sha256) => String.t()`
  (present iff kind `:script`).
* `Lookup` gains NON-enforced field `script_lookup :: nil | (key :: String.t(), version ::
  pos_integer() -> {:ok, %{resolved_id: String.t(), version: String.t(), sha256: String.t()}} |
  {:error, :not_found})`; `default_lookup/0` sets it to a function returning `{:error,
  :not_found}`. `nil` behaves as not found (existing `%Lookup{}` literals keep compiling).
* `resolve/4`: collects `{script_key, script_version}` from SERVICE_TASK nodes; two different
  versions of one key -> `{:error, {:script_version_conflict, key}}`; lookup not found ->
  `{:error, {:unresolved_script_ref, key}}`; an override of kind `:script` is never applied and is
  reported by `check_no_stray_overrides` as `{:unresolved_pin_override, ref}`.
  `resolve_error` gains both new tuples.
* `normalize_kind/1` adds `"script" -> :script`; `merge_effective_pins/3` carries `sha256` from the
  INSTANCE_STARTED entry (string or atom key); a PINS_REBOUND entry of kind `script` (cannot be
  written, see below) is ignored rather than raising.
* `apply_inheritance/2`: parent pins of kind `:script` are never added to a child, and a child's own
  `:script` pin is never replaced or recorded as a conflict (C7).
* `PinRebind.validate_entry_kind/2` stays closed: `"script"`/`:script` -> `{:malformed_entry, i,
  {:invalid_kind, value}}` (test asserts it).
* `Engine.pin_lookup/2` -> `pin_lookup(attrs, tenant_id, prefix)`: default `%{PinLookup.build(tenant_id)
  | script_lookup: Letflow.Scripts.Runtime.pin_lookup(prefix)}`; a caller-supplied `attrs[:pin_lookup]`
  is returned unchanged.
* `Letflow.Scripts.Runtime.pin_lookup(prefix)` returns the closure: one query of `script_rules` by
  `(key, version)` in `prefix`; `{:ok, ...}` ONLY when `status == "published"` and `hook_kind ==
  "service_task"`; everything else (absent, draft, discarded, retired, revoked) `{:error,
  :not_found}` (D1: retired = no new pins).

Effect: INSTANCE_STARTED carries `%{"kind" => "script", "ref" => key, "version" => "1",
"resolved_id" => row_id, "sha256" => hex, "source" => "resolved"}`; a later publish of version 2
changes nothing for that instance (D3).

### 4.4 Arming a script dispatch (`engine.ex`)

* `resolve_service_task_arm_attrs/6` gains a `:script` clause: the pin for `script_key` from the
  same pin source the catalog route uses (`{:pins, list}` at create, `{:reconstruct, ...}`
  elsewhere); missing pin, a pin whose `version` differs from `Integer.to_string(script_version)`, or
  a pin without `sha256` -> `{:script_binding_error, node_id, reason}` with `reason in
  [:pin_missing, :pin_mismatch]`. Success returns `{:ok, %{kind: :script, arm_attrs}, ctx}` with
  arm attrs `instance_id, node_id, script_key, script_version, script_sha256, event_time: now,
  next_attempt_at: now, triggering_user_id`.
* The `catalog_dispatch_ctx` map gains optional `actor_id` (default nil); each hop-chain site passes
  its command actor where it has one (create/2: the starting actor; complete_task/3: the completing
  user); timer, HTTP-advance, script-advance and sub-process hops pass nil. The platform actor id is
  stored as NULL.
* `prepared_service_task_dispatch` gains `kind :: :http | :script` (existing rows: `:http`).
  `build_service_task_dispatch_multi/5` inserts `:http` entries exactly as today and `:script`
  entries via `ScriptTaskDispatch.arm_changeset/2` into `script_task_dispatches` (same compound
  Multi key pattern, `{:script_task_dispatch, token_record_id}`).
* Every site that handles `{:catalog_resolution_error, ...}` (0.1) handles `{:script_binding_error,
  node_id, reason, variables}` the same way: create/2 -> `{:error, {:activation_failed,
  {:script_binding_unresolved, node_id, reason}}}`; other hops -> ExecutionError with `error_type
  :script_task_pin_unresolved`, fixed reason sentence, `details %{reason: atom}`.

### 4.5 Activation refusal (D2) and retire block (D3)

`Letflow.Scripts.Runtime.check_bindings(graph :: Graph.t(), prefix :: String.t()) :: :ok | {:error,
{:script_binding_invalid, node_id :: String.t(), reason}}`, `reason ::
:script_not_published | :script_version_conflict | :script_output_schema_open |
:script_reads_unsupported (7c-1 only) | :script_restricted_opt_in_unsupported`. For every `{key,
version}` bound by a SERVICE_TASK node, in this order: `SELECT ... FROM script_rules WHERE key = $1
AND version = $2 FOR SHARE` (bound); refused unless `status == "published"` and `hook_kind ==
"service_task"` (absent, draft, discarded, retired, revoked all -> `:script_not_published`); then
`closed_output_schema?(manifest)` (C11a: top-level `"type": "object"`, `"properties"` a non-empty
map, `"additionalProperties" == false`) else `:script_output_schema_open` [SEC S1]; then C10
(non-empty `restricted_inputs` or any non-empty `reads[].restricted_fields`) else
`:script_restricted_opt_in_unsupported`; then (7c-1 only) non-empty `reads` else
`:script_reads_unsupported`. The first failing node (graph node order) is reported. Must run inside
the caller's transaction (it takes row locks).

`closed_output_schema?(manifest :: map()) :: boolean()` and `declared_outputs(manifest :: map()) ::
[String.t()]` (the top-level `properties` keys) are public pure functions of `Scripts.Runtime`,
shared by activation, `prepare_run/3` and the apply step.

Called, inside the activating transaction, BEFORE the status write, from:
1. `run_activate_transaction/4` after the service-scope validator and semantic validation;
2. Promotion, before `activate_new_definition/2`, in the target prefix;
3. Rollback, before `swap_active_pointer/3`, for the graph being re-activated.

Each path maps the error to its existing error union: `Definitions.activate/2` gains `{:error,
{:script_binding_invalid, node_id, reason}}`; the definitions router maps it to 422 `{"error":
"script_binding_invalid", "node_id": <id>, "reason": <code>}` (the node id is the caller's own
graph). Promotion and rollback return the same tuple through their existing error paths.

Retire: `Scripts.retire/5` (inside `transition/8`, after `lock_row!/3`, only for `to ==
"retired"`) runs `Runtime.referenced_by_active_definition?(prefix, key, version) :: boolean()`: one
query, through the leaf schema module `Letflow.Definitions.ProcessDefinition` (no call into the
`Letflow.Definitions` context, so no file-level cycle with `definitions.ex`, see 17 item 4), over
`process_definitions WHERE status = 'active' AND graph @> $1` with `$1` = the jsonb
document `{"nodes": [{"attributes": {"script_key": key, "script_version": version}}]}` passed as a
BOUND parameter (INV-7). True -> `Repo.rollback(:version_in_use)`; router 409 `{"error":
"version_in_use"}`; nothing written or audited. Revoke unchanged.

## 5. Dispatcher (7c-1)

### 5.1 Modules and config

* `Letflow.Engine.ScriptTaskDispatcher` (`lib/letflow/engine/script_task_dispatcher.ex`), plain
  context module, owns the table, the claim, the sweep, the per-row pipeline, the reschedule and
  cancel writes.
* `Letflow.Engine.ScriptTaskDispatcher.Poller` (`.../script_task_dispatcher/poller.ex`), GenServer,
  same shape as the HTTP poller: zero-delay first tick; per tick it lists the provisioned tenant
  schemas (as the HTTP poller does) and calls `run_tick/2` (5.1a). Child of
  `Letflow.Supervisor.Pollers`, gated `Application.get_env(:letflow, :start_script_task_dispatcher,
  true)`; `config/test.exs` sets false. Its state holds only the round-robin offset
  (`non_neg_integer()`). [CDV C10] It cannot start before the event types it appends exist: Pollers
  starts after `Supervisor.Infrastructure`, whose child `MigrationReplayBoot` seeds every existing
  tenant synchronously (0.12).
* `config :letflow, :script_task_dispatcher, poll_interval_ms: 1_000, tick_budget_ms: 10_000,
  max_dispatches_per_cycle: 16, sweep_limit: 64, sweep_failure_limit: 5, lease_margin_ms: 23_000,
  busy_retry_limit: 10, busy_backoff_base_ms: 500, busy_backoff_cap_ms: 30_000` (read fresh per
  tick; `max_dispatches_per_cycle` is the PER-TENANT cap per tick).
* Test seams, ALL honoured only when `Application.get_env(:letflow, :scripts_test_hooks, false) ==
  true` (the 7b-2a seam convention; set only in `config/test.exs`; a test asserts each is ignored
  when the flag is false; the application refuses to boot in `:prod` with it set, 19a late gate
  note c):
  * `:script_task_runner` (default `Letflow.Engine.Lua.ScriptRunner`, a module with `run/3`);
  * `:script_task_hmac_fun_override` (7.2);
  * `:script_task_apply_pause` (a 1-arity function given `:after_cas`, called inside the apply
    transaction between the CAS lock and the projection lock; AC18a);
  * `:script_task_cancel_pause` (called inside `cancel_open_dispatches/4` after its update; AC18a);
  * `:script_task_sweep_fault` (a 1-arity function given the dispatch id; returning `:fail` makes the
    sweep treat that apply as `{:error, :forced}`; AC30).

Types [CDV C1]:

```
@type code      :: Letflow.Engine.Lua.ScriptRunner.code()
                   # :script_error | :budget_exceeded | :memory_limit_exceeded | :output_invalid
                   # | :timeout | :script_failed | :script_rejected | :script_busy
@type outcome   :: :ok | code()
@type detail    :: :scripts_disabled | :tenant_inactive | :reads_not_allowed | :script_unavailable
                 | :script_revoked | :pin_mismatch | :restricted_opt_in_unsupported
                 | :output_schema_open | :hmac_secret_missing | :hmac_failed | :input_invalid
                 | :output_decode | :output_not_object | :writes_not_allowed | :output_schema
                 | :variable_schema_rejected | :busy_retries_exhausted | :lease_expired | :apply_failed
                 | :no_matching_gateway_edge | :instance_not_active | :instance_cancelled
@type claim     :: %{dispatch_id: Ecto.UUID.t(), instance_id: Ecto.UUID.t(), node_id: String.t(),
                     attempt: pos_integer()}
@type run_facts :: %{row: ScriptTaskDispatch.t(), phase: :rejected | :ran | :lease_expired,
                     outcome: outcome(), detail: detail() | nil, fail_code: String.t() | nil,
                     hmac: {key_version :: pos_integer(), hex :: String.t()} | nil,
                     stats: nil | %{duration_us: non_neg_integer(),
                                    instructions_used: non_neg_integer() | nil,
                                    heap_words: non_neg_integer() | nil,
                                    input_dropped: non_neg_integer() | nil}}
@type run_record :: %{required(String.t()) => String.t() | integer() | nil}   # exactly the 7.1 keys
@type result    :: {:ok, output :: map(), run_facts()}
                 | {:failed, code(), detail() | nil, run_facts()}
@type tick_summary :: %{tenants: non_neg_integer(), passes: non_neg_integer(), swept: non_neg_integer(),
                        sweep_failed: non_neg_integer(), ran: non_neg_integer(), applied: non_neg_integer(),
                        failed: non_neg_integer(), rescheduled: non_neg_integer(),
                        stale: non_neg_integer(), cancelled: non_neg_integer(),
                        budget_exhausted: boolean()}
```

Public functions of `ScriptTaskDispatcher`:

```
run_tick(schemas :: [String.t()], offset :: non_neg_integer()) :: {tick_summary(), next_offset :: non_neg_integer()}
sweep_expired_leases(prefix :: String.t(), limit :: pos_integer()) :: %{swept: non_neg_integer(), failed: non_neg_integer()}
claim_next(prefix) :: {:ok, ScriptTaskDispatch.t()} | :none
run_claimed(ScriptTaskDispatch.t(), prefix) ::
  {:ok, :applied | :failed | :rescheduled | :cancelled | :stale} | {:error, :apply_failed}
reschedule_busy(claim(), run_facts(), prefix) ::
  {:ok, :rescheduled | :failed | :stale} | {:error, term()}      # :failed = limit reached, applied as incident
cancel_open_dispatches(repo :: module(), instance_id :: Ecto.UUID.t(), at :: DateTime.t(), prefix) ::
  {:ok, non_neg_integer()}
busy_backoff_ms(busy_retries :: non_neg_integer()) :: pos_integer()            # pure
lease_ms() :: pos_integer()                                                      # 7_000 + max(lease_margin_ms, 1_000)
```

`ScriptTaskDispatcher.RunRecord.build(run_facts()) :: run_record()` (arity 1): reads ONLY the listed
`run_facts` fields and the row's `id, node_id, attempt, script_key, script_version, script_sha256,
triggering_user_id`; `principal` derived from key and version.

`run_tick/2` never raises: every per-row step runs inside `try/rescue/catch`; a catch maps to a
count and ONE log line whose only fields are dispatch id, tenant schema and a class tag (`raised |
thrown | exited`). The rescue binds no `__STACKTRACE__`, never calls `inspect/1`,
`Exception.message/1` or `Exception.format*/…` on the exception, and passes nothing caught to Logger
metadata [SEC S3].

### 5.1a Tick: round-robin under a budget [SEC S2]

`run_tick(schemas, offset)`:
1. Rotate `schemas` to start at `offset rem length(schemas)`; `deadline = monotonic now +
   tick_budget_ms`.
2. Sweep pass: `sweep_expired_leases(prefix, sweep_limit)` for each schema in the rotated order (no
   script runs in a sweep; it is bounded by `sweep_limit` rows per tenant).
3. Run passes: in the rotated order, for each tenant that still has budget left in this tick
   (fewer than `max_dispatches_per_cycle` rows run for it) and was not found empty earlier in this
   tick: if `monotonic now >= deadline` stop the tick (`budget_exhausted: true`); else
   `claim_next(prefix)`; `:none` marks the tenant empty for this tick; `{:ok, row}` ->
   `run_claimed/2` (AT MOST ONE row per tenant per pass). Repeat passes while at least one tenant ran
   a row in the previous pass and the deadline is not reached.
4. Return the summary and `next_offset = offset + 1` (the next tick starts one tenant later).

Fairness guarantee (stated, tested; R4) [late gate note d]: WITHIN a tick, no tenant runs its
k+1-th row before every other tenant that had a due row has run its k-th, so a tenant with a due
row waits for at most `n - 1` rows (one per other busy tenant) before its own row runs; a run takes
at most `timeout_ms + 2_000 <= 7_000` ms plus the apply, i.e. at most `(n - 1) x 7 s`. The
deadline is checked only between rows, so a tick lasts at most `tick_budget_ms + 7 s` plus one
apply. ACROSS ticks, when the budget runs out every tick, the rotating start offset (one tenant
later per tick) bounds how long a tenant can be passed over: it is served first after at most
about `n / 2` ticks on average (at most `n - 1` ticks), instead of a fixed order always serving the
same tenant last. One tenant's backlog therefore delays another tenant by at most one row per pass,
never by its whole backlog.

### 5.2 Claim (transaction A, short)

1. Unlocked select of at most one id: `status = 'pending' AND next_attempt_at <= now` joined to
   `instance_projections.status = :active`, ordered by `next_attempt_at`.
2. Lock by id `FOR UPDATE SKIP LOCKED` with `status = 'pending'` re-asserted; set `status =
   'running'`, `attempt = attempt + 1`, `claimed_at = now`, `lease_expires_at = now + lease_ms()`,
   `claimed_by`, `updated_at`; COMMIT. Returns the updated row.

The run itself holds NO transaction and NO pooled connection (D2, F3).

### 5.3 Per-row pipeline (`run_claimed/2`, no transaction)

Order is normative. Steps 1-4 (all inside `Scripts.Runtime.prepare_run/3`) run before admission
and before any data read (D7 kill switch, 7b-2a section 8). A refusal at any step jumps to apply
(5.4) with `{:failed, :script_rejected, detail, facts}` and `phase: :rejected`.

`Scripts.Runtime.prepare_run/3` [CDV C1]:

```
@spec prepare_run(prefix :: String.t(), tenant_id :: Ecto.UUID.t(), binding()) ::
        {:ok, run_spec()} | {:rejected, ScriptTaskDispatcher.detail()}
@type binding  :: %{script_key: String.t(), script_version: pos_integer(), script_sha256: String.t()}
@type run_spec :: %{source: String.t(), manifest: map(),
                    limits: %{instructions: pos_integer(), timeout_ms: pos_integer(), heap_words: pos_integer()},
                    fail_codes: [String.t()], reads: [map()], declared_outputs: [String.t()],
                    hmac_fun: HmacSecret.hmac_fun(), principal: String.t()}
```

`tenant_id` comes from `TenantProvisioning.tenant_id_for_schema_name(prefix)` (the dispatcher
resolves it once per row; `{:error, _}` -> `tenant_inactive`). `prepare_run/3` never calls
`Obs.Alerts`; the DISPATCHER does (step 4).

1. **Kill switch, tenant.** `Policy.kill_switch_on?(prefix)` true -> `scripts_disabled`; then
   `Identity.get_tenant(tenant_id)` with `status != :active` (or not found) -> `tenant_inactive`
   [SEC S5].
2. **Version.** Load `script_rules` by `(script_key, script_version)`: absent/draft/discarded ->
   `script_unavailable`; `revoked` -> `script_revoked`; `sha256 != script_sha256` or `hook_kind !=
   "service_task"` -> `pin_mismatch`; `published` and `retired` run (D1, T13).
3. **Manifest backstops and reads**, in this order:
   a. `closed_output_schema?(manifest)` false -> `output_schema_open` [SEC S1];
   b. non-empty `restricted_inputs` or any non-empty `reads[].restricted_fields` ->
      `restricted_opt_in_unsupported` (C10; a REFUSAL, there is no restricted-allowed path in 7c
      [CDV C3]);
   c. 7c-1: non-empty `reads` -> `reads_not_allowed`. 7c-2: `Policy.check_reads(prefix, manifest)`
      `{:error, :reads_not_allowed}` -> `reads_not_allowed` (11.3).
4. **Secret.** `HmacSecret.hmac_fun(tenant_id)`: `{:error, :missing}` -> `hmac_secret_missing`.
   On return the DISPATCHER calls `Obs.Alerts.notify_script_hmac_secret_missing(prefix)` for that
   detail, and `Obs.Alerts.clear_script_hmac_secret_missing(prefix)` (re-arm; a no-op when armed)
   for `{:ok, _}`.
5. **Input.** Read the instance projection's `variables` (unlocked `Repo.get`). `ScriptInput.build(
   variables, manifest, reads_result) :: {:ok, input} | {:error, :input_invalid}`: input = the
   variables whose keys are in `manifest["input_schema"]["properties"]` (no undeclared variable
   enters, field-minimal), plus `"reads" => reads_result` when reads are declared (7c-2); validated
   with `JsonSchema.validate(input, input_schema) == []`. Invalid -> `script_rejected` /
   `input_invalid`.
6. **HMAC.** `run_spec.hmac_fun.(ScriptInput.canonical(input, ctx))` returns `{:ok, {key_version,
   hex}}` or `{:error, :hmac_failed}` (-> `script_rejected` / `hmac_failed`, nothing logged but the
   tag) where `ctx = %{"instance_id", "node_id", "token_id", "now" (ISO-8601 of event_time)}` and
   canonical = `Canonicaliser.canonicalize_content("application/json", Jason.encode!(%{"ctx" => ctx,
   "input" => input}))` (C14). `ScriptInput.build(variables :: map(), manifest :: map(),
   reads_result :: %{optional(String.t()) => [map()]} | nil) :: {:ok, map()} | {:error,
   :input_invalid}`; `ScriptInput.canonical(input :: map(), ctx :: map()) :: binary()`.
7. **Run.** `t0 = System.monotonic_time()`; `runner.run(source, input, tenant: prefix, ctx: %{
   instance_id, node_id, token_id, now: event_time}, fail_codes: manifest["fail_codes"],
   instructions:, timeout_ms:, heap_words:)` called FROM THE POLLER PROCESS (the watchdog monitors it;
   the slot holder is the watchdog, D8/F-E). `duration_us` measured around the call for every
   outcome; `instructions_used`, `heap_words`, `input_dropped` from `stats` on success, NULL
   otherwise.
8. **Output check** (pure, `Scripts.Runtime.check_output(output :: term(), manifest :: map()) ::
   {:ok, declared :: map()} | {:error, :output_not_object | :writes_not_allowed | :output_schema}`),
   in this order: not a map -> `output_not_object`; any top-level key starting with `"$"` ->
   `writes_not_allowed` (C11); any top-level key not in `declared_outputs(manifest)` or
   `JsonSchema.validate(output, output_schema) != []` -> `output_schema` [SEC S1]; else `{:ok,
   Map.take(output, declared_outputs(manifest))}`: ONLY declared properties ever reach the merge.
   Each error -> `output_invalid` with that detail.
9. **Result.** `{:ok, declared_output, facts}` | `{:failed, code, detail, facts}`; a runner
   `script_busy` goes to 5.5 instead. Runner error codes map 1:1 (`output_invalid` from the decoder
   -> detail `output_decode`; `script_failed` -> `fail_code` = the validated fail code, `details`
   dropped).
10. **Apply** (5.4) or **reschedule** (5.5).

### 5.4 Apply (transaction B, `Letflow.Engine.apply_script_task_result/3`)

```
@spec apply_script_task_result(ScriptTaskDispatcher.claim(), ScriptTaskDispatcher.result(), prefix :: String.t()) ::
        {:ok, :applied | :failed | :cancelled | :stale} | {:error, term()}
```

The engine turns `run_facts` into the payload with `RunRecord.build/1` inside the transaction.

One `repo.transaction`:
1. **CAS.** `SELECT ... FROM script_task_dispatches WHERE id = $1 AND instance_id = $2 AND node_id =
   $3 AND attempt = $4 AND status = 'running' FOR UPDATE`. No row -> return `{:ok, :stale}`, NOTHING
   written (duplicate, late, swept or cancelled).
2. Lock the projection (`fetch_and_lock_instance_projection/3`). Not `:active` -> row `cancelled`,
   `outcome`, `outcome_detail = "instance_not_active"`, `finished_at`; no event (C13); `{:ok,
   :cancelled}`.
3. **Success:** `VariableSchema.variable_validations(repo, projection.definition_id, variables,
   output, prefix: prefix)`; `{:error, _}` -> treated as failure `script_rejected` / `apply_failed`
   (step 4). `VariableMerge.merge(variables, output, validations)`: `{:rejected, ...}` -> failure
   `output_invalid` / `variable_schema_rejected` (step 4, the rejected value is NOT recorded).
   `{:ok, merged, _}` -> the existing advance pipeline (`persist_service_task_advance` ->
   `do_persist_service_task_advance`), GENERALISED by a completion descriptor so the HTTP call sites
   pass exactly today's values (merge validations `nil`, event SERVICE_TASK_COMPLETED, idempotency key
   `"service_task_dispatch:<id>"`, no row step) and the script site passes: completion event
   `SCRIPT_TASK_COMPLETED` (section 6), idempotency key `"script_task_dispatch:<id>:<attempt>"`, and
   two extra Multi steps in the same transaction: append `SCRIPT_RUN_RECORDED` (idempotency key
   `"script_run:<id>:<attempt>"`) and set the row `applied`, `outcome "ok"`, `finished_at`.
   No-matching-edge after the node (`persist_service_task_no_matching_edge`): EXECUTION_ERROR + DLQ
   as for HTTP, plus `SCRIPT_RUN_RECORDED` (outcome `ok`) and the row `failed` / `outcome "ok"` /
   detail `no_matching_gateway_edge`, same transaction; no SCRIPT_TASK_COMPLETED.
4. **Failure:** `ExecutionError.append_multi(error_args, prefix:, locked_projection:)` with C16 args
   (`variables` = the CURRENT variables, unchanged), plus `SCRIPT_RUN_RECORDED`, plus row `failed`,
   `outcome`, `outcome_detail`, `finished_at`; `{:ok, :failed}`.
5. Any `{:error, _}` rolls the whole transaction back (row stays `running`). The dispatcher then runs
   ONE follow-up transaction B' = step 4 with `script_rejected` / `apply_failed` (same CAS). If B'
   also fails, the row stays `running` and the lease sweep turns it into an incident (5.6): never a
   silent stall, never a re-run.

**Completion descriptor [CDV C1].** The shared private pipeline (`persist_service_task_advance`,
`persist_service_task_no_matching_edge`, `do_persist_service_task_advance`,
`append_service_task_completed_event`) is changed to take a `dispatch_ref` and a `completion`
instead of `%ServiceTaskDispatch{}` and `decoded_body`; the merge stays in each caller (HTTP:
`advance_service_task_dispatch/4`, script: step 3 above):

```
@typep dispatch_ref :: %{id: Ecto.UUID.t(), instance_id: Ecto.UUID.t(), node_id: String.t(),
                         token_id: Ecto.UUID.t()}
@typep completion :: %{
         event_type: String.t(),                 # "SERVICE_TASK_COMPLETED" | "SCRIPT_TASK_COMPLETED"
         event_payload: map(),                   # appended as-is
         idempotency_key: String.t(),            # also used for error args / sub-process children
         on_advanced: (Ecto.Multi.t() -> Ecto.Multi.t()),          # appended before :projection
         on_no_matching_edge: (Ecto.Multi.t() -> Ecto.Multi.t())   # appended after ExecutionError
       }
```

HTTP contract (keeps HTTP byte-unchanged): `http_completion(dispatch, decoded_body)` =
`%{event_type: "SERVICE_TASK_COMPLETED", event_payload: %{dispatch_id: dispatch.id, node_id:
dispatch.node_id, decoded_body: decoded_body}, idempotency_key: "service_task_dispatch:" <>
dispatch.id, on_advanced: &Function.identity/1, on_no_matching_edge: &Function.identity/1}`, and the
HTTP merge keeps `nil` validations. Script: `event_type "SCRIPT_TASK_COMPLETED"`, payload of section
6, `idempotency_key "script_task_dispatch:<id>:<attempt>"`, `on_advanced` = append
SCRIPT_RUN_RECORDED + row `applied`, `on_no_matching_edge` = append SCRIPT_RUN_RECORDED + row
`failed` / `no_matching_gateway_edge`. HTTP regression guard: every existing
`advance_after_service_task_outcome/4` test stays green, plus one new assertion pinning the HTTP
event payload keys and idempotency key.

### 5.5 Busy reschedule

`ScriptTaskDispatcher.reschedule_busy(claim, facts, prefix)`: one transaction, same CAS predicate
(no row -> `{:ok, :stale}`); if `busy_retries < busy_retry_limit`: `status = 'pending'`,
`busy_retries + 1`, `next_attempt_at = now + busy_backoff_ms(busy_retries)`, `lease_expires_at =
NULL`, `updated_at`; no event; `{:ok, :rescheduled}`. Else, after that transaction, it calls
`apply_script_task_result(claim, {:failed, :script_busy, :busy_retries_exhausted, facts}, prefix)`
(`phase: :ran`) and returns `{:ok, :failed}` (or `{:ok, :stale}`).

### 5.6 Lease sweep, cancellation, detail codes

* Sweep (5.1a step 2): up to `sweep_limit` ids with `status = 'running' AND lease_expires_at < now
  AND sweep_failures < sweep_failure_limit`, ordered by `lease_expires_at` (unlocked select), then
  per id `apply_script_task_result` with the row's own `attempt` and `{:failed, :timeout,
  :lease_expired, facts}` (`phase: :lease_expired`, HMAC and stats NULL). The CAS makes a concurrent
  live apply and the sweep mutually exclusive. Never re-pends. [CDV C9] An `{:error, _}` (or a
  caught raise) increments `sweep_failures` in its own CAS update (`status = 'running' AND attempt =
  $n`); the transition to `sweep_failure_limit` logs ONE error line (dispatch id, tenant schema, tag
  `sweep_stuck`) and emits `[:letflow, :script_task, :sweep_stuck]`; otherwise failures are reported
  as ONE aggregated warning per tenant per tick carrying only the count. A stuck row stays `running`
  (visible), never re-run.
* `Engine.cancel_instance` [CDV C5]: a new Multi step `:script_task_dispatch_cancellations`, calling
  `ScriptTaskDispatcher.cancel_open_dispatches/4`, is inserted immediately AFTER
  `:service_task_dispatch_cancellations` and BEFORE `:instance_projection` (lock order dispatch row
  -> projection, the same order as the apply transaction and the existing timer/HTTP steps, 0.12). It
  sets `pending` AND `running` rows of the instance to `cancelled` (`finished_at`, `outcome_detail =
  "instance_cancelled"`, `updated_at`); an ineligible cancel rolls it back with the rest of the
  Multi. A running script finishes in its sandbox and its apply is `:stale`.
* Apply vs cancel [SEC S6]: both take the dispatch row lock before the projection lock, so they
  serialise: cancel first -> the apply's CAS re-evaluates `status = 'running'` after the wait and
  returns `:stale`; apply first -> the row is `applied` (not matched by the cancel update) and the
  cancel then proceeds on the advanced instance. Should Postgres still report a deadlock (`40P01`) on
  the apply, the apply transaction rolls back, B' runs with the same CAS and finds the row
  `cancelled` -> `:stale`; on the cancel side the existing error path returns and nothing is written.
* Closed detail-code list (`outcome_detail`, run record `detail`, incident `details.detail`): the
  `detail()` type of 5.1. Runner outcomes `script_error, budget_exceeded, memory_limit_exceeded,
  timeout, script_failed` carry detail NULL.

## 6. Instance events, registry, replay (7c-1)

Both added to `@platform_event_type_seed_attrs` (schema_version 1; reaches existing tenants at the
next boot replay, 0.3). Both schemas `additionalProperties: false`, every listed key required.

| Event | Payload |
|---|---|
| `SCRIPT_TASK_COMPLETED` | `dispatch_id` string, `node_id` string, `attempt` integer, `script_key` string, `script_version` integer, `output` object (the merged output, the replay source) |
| `SCRIPT_RUN_RECORDED` | section 7.1 |

Both are appended with `actor_id = EventStore.platform_actor_id()`.

`Reconstruction.apply_event/4` gains:
* `SCRIPT_RUN_RECORDED` -> `{:ok, state}` (no state change).
* `SCRIPT_TASK_COMPLETED` -> `fetch_string_field("node_id")`, `fetch_map_field("output")`,
  `find_task_completion_token(state.tokens, node_id)`, `VariableMerge.merge(vars, output, nil)`
  (validations ran live; replay applies the recorded result, as TASK_COMPLETED does), drop the token's
  entry from `pending_service_task_nodes`, then a new private `dispatch_service_task_completion/3`
  that mirrors the live path (`Transition.advance_off_completed_node/4` on the node's outgoing edges,
  then `Engine.advance_until_stable/4`). A merge rejection -> `{:error, {:variable_merge_rejected,
  event_id, key}}` as for TASK_COMPLETED.

Replay never re-executes a script (D5, MUST 11) [SEC S4]: the source scan is scoped to
`lib/letflow/engine/reconstruction.ex` exactly: it names neither `ScriptRunner`,
`ScriptTaskDispatcher`, `ScriptReadPort` nor `Letflow.Scripts`. The runtime proof (AC15) replays a
definition with TWO CONSECUTIVE script tasks and no HTTP task (R6), asserting zero runner calls,
zero queries against `script_rules` / `script_policy` / `script_readable_masters` (i.e. zero
`Scripts.Runtime` lookups) and zero INSERTs into `script_task_dispatches` during the replay (Ecto
telemetry, test-pid scoped). Replay folds events with `Engine.advance_until_stable/4`, which returns
pending events but persists nothing, so arming never happens on that path.

## 7. Per-run record, HMAC secret, alert (7c-1)

### 7.1 `SCRIPT_RUN_RECORDED` payload (exact key set; built by `ScriptTaskDispatcher.RunRecord.build/1` from `run_facts()`, 5.1, an allowlist constructor)

`dispatch_id, node_id, attempt, script_key, script_version, script_sha256, phase ("rejected" |
"ran" | "lease_expired"), outcome ("ok" | eight codes), detail (code | null), fail_code (manifest
code | null), input_hmac (64 hex | null), input_hmac_key_version (integer | null), duration_us
(integer | null), instructions_used (integer | null), heap_words (integer | null), input_dropped
(integer | null), principal ("script:<key>@<version>"), triggering_user_id (uuid string | null)`.

It holds NO input value, NO output value, NO fail `details`, NO print buffer, NO source; the
`script_task_dispatches` row's columns are equally value-free (3.1). Logs on every path carry only
dispatch id, tenant schema, outcome and detail codes.

### 7.2 HMAC (`Letflow.Scripts.HmacSecret`, changed)

```
@type hmac_fun :: (binary() -> {:ok, {key_version :: pos_integer(), hex :: String.t()}} | {:error, :hmac_failed})
@spec hmac_fun(tenant_id :: Ecto.UUID.t()) :: {:ok, hmac_fun()} | {:error, :missing}
```

Looks up the tenant (`Identity.get_tenant/1`, matched with `case`) for its slug, then
`Secrets.resolve("sec://tenant/<slug>/platform/script-input-hmac", tenant_id: tenant_id, consumer:
:script_runner, platform: true)` (unpinned = newest active), matched with `case`: `{:ok, %{plaintext:
key, key_id: n}}` -> the closure; every other return -> `{:error, :missing}` (never a bare match,
so no `MatchError` can carry the plaintext into a log) [SEC S3]. The closure runs
`:crypto.mac(:hmac, :sha256, key, bytes)` inside `try ... rescue _ -> {:error, :hmac_failed} catch
_, _ -> {:error, :hmac_failed}` (no binding of the exception or stacktrace) and returns lowercase hex
with `n`. NEVER calls `ensure/1` or `Secrets.put`; still the ONLY `platform: true` caller.

The closure is built by `@doc false build_hmac_fun(key :: term(), key_id :: pos_integer()) ::
hmac_fun()` (pure; `hmac_fun/1` is its only production caller). Test seam for AC12's crypto fault:
the dispatcher uses `Application.get_env(:letflow, :script_task_hmac_fun_override)` (a 1-arity
function `tenant_id -> {:ok, hmac_fun()}`) instead of `HmacSecret.hmac_fun/1` ONLY when
`:scripts_test_hooks` is true; the test supplies `fn _ -> {:ok, HmacSecret.build_hmac_fun(<sentinel
non-binary key>, 1)} end`, which makes `:crypto.mac` raise inside the closure.

### 7.3 Missing-secret alert (`Letflow.Obs.Alerts`, changed)

`notify_script_hmac_secret_missing(prefix) :: :ok` and `clear_script_hmac_secret_missing(prefix) ::
:ok`, called ONLY by `Letflow.Engine.ScriptTaskDispatcher` (5.3 step 4), edge-triggered through `alert_trigger_state` key `"script_hmac_secret_missing"`: ARMED -> one
`Logger.error("script HMAC secret missing", component: "script_task", tenant_schema: prefix,
trigger: "script_hmac_secret_missing")`, hooks fired when `alert_hooks` is enabled (payload `{"trigger",
"tenant_schema"}`), state FIRED; FIRED -> nothing. `clear_` re-arms. Never raises. The trigger set
grows from four to five (closed-set change, section 17).

## 8. Outputs (7c-1)

### 8.1 Variables only

The only effect of a successful run is `VariableMerge.merge/3` into the instance's variables, with
real validations from the definition's variable schema (D2, this route only; HTTP unchanged,
Deviation 2), inside the apply transaction (5.4). Only the manifest's DECLARED output properties
can be merged: the binding requires a closed output schema (C11a, checked at activation and before
the run) and `check_output/2` hands only `Map.take(output, declared_outputs)` to the merge, after
refusing any undeclared key [SEC S1]. The set of variables a binding can write is therefore exactly
`declared_outputs(manifest)`, visible to whoever activates the definition. No entity, no other
instance, no event other than the two of section 6, no audit-chain entry.

### 8.2 Write-command refusal

C11. Recognition is exactly "the decoded output is a map AND at least one top-level key, as a
binary, starts with byte `$`". Applied by `Scripts.Runtime.check_output/2` at run (5.3 step 8), by
stored-test evaluation (`run_case`: a case whose output fails `check_output/2` fails with that
outcome) and by dry-run (`outcome: "output_invalid"`). `Validation.manifest/1` refuses an
`output_schema.properties` name starting with `$` (422 `invalid_manifest`).

## 9. Kill switch at run (7c-1)

Checked as step 1 of 5.3: after the claim (a control-plane write of the dispatch row) and before
the version load, the secret, any variable or entity read and admission. Effect: `script_rejected`
/ `scripts_disabled` incident (instance ERROR + DLQ), `phase: "rejected"`, not retried. Read fresh
for every row, never cached (7b-2a section 8). A run already executing finishes within its own wall
clock (7b-2a residual).

## 10. LuaScriptAudit retirement (7c-1)

C17. `lua_script_audit_test.exs` and the audit parts of `manifest_executor_audit_test.exs` are
replaced by: `function_exported?(LuaScriptAudit, :execute_script_for_audit, 6) == false`; raw
INSERT, UPDATE and DELETE on `lua_script_execution_audit` refused (`pg_code == "LF001"`) inside the
test's sandbox transaction (rolled back, so the pooled schema is never dirtied); a source scan finds
no `lua_script_execution_audit` writer in `lib/`. `Lua.Executor`'s own tests stay green.

"History stays readable" [CDV C6] runs on a DEDICATED, non-pooled tenant schema created by the test
(a bare schema from `TenantProvisioning.provision_tenant_schema/1`), never on a pooled clone: the
test migrates that schema with `Ecto.Migrator.run(Repo, TenantProvisioning.tenant_scoped_migrations(),
:up, to: <version before 20261015100002>, prefix: schema)`,
inserts one row through `AuditRecord.insert_changeset/2`, migrates to the latest version, then reads
the row back through `AuditRecord` and asserts a second insert is refused; `on_exit` drops the
schema. No trigger is ever disabled and the pooled reset (no TRUNCATE trigger, C17) is untouched.

## 11. Pre-fetch port and reads (7c-2)

### 11.1 Port (engine-defined)

`Letflow.Engine.ScriptReadPort` (`lib/letflow/engine/script_read_port.ex`), a behaviour:

```
@callback prefetch(prefix :: String.t(), reads :: [read_spec()], input_vars :: map()) ::
            {:ok, %{optional(String.t()) => [row()]}} | {:error, :reads_not_allowed}
read_spec :: %{"name", "entity_type", "match" => %{"id_from"} | %{"field", "value_from"},
               "fields" => [String.t()], optional("limit") => 1..50}
             # restricted_fields is always empty here: C10 refuses it before the port is called
row       :: %{required("id") => String.t(), optional(String.t()) => json_value()}
```

The dispatcher resolves the implementation with `Application.fetch_env!(:letflow,
:script_read_port)` (set in `config/config.exs` to `Letflow.Entities.ScriptReads`; tests may set a
recording stub), so no engine file names an Entities module. Called only when the manifest's `reads`
is non-empty, after 5.3 steps 1-4 and `check_reads` (11.3), before admission.

### 11.2 Implementation `Letflow.Entities.ScriptReads` (`lib/letflow/entities/script_reads.ex`)

Phase 1, for EVERY read, before any record query:
1. `entity_type` has an active definition (`get_active_definition_by_name/2`) and no
   `entity_type_restrictions` row; every name in `fields` and `match.field` is a field of that
   definition; `restricted_fields` absent or empty. Else `{:error, :reads_not_allowed}`.
2. `R` = the type's CURRENT restricted field names: `entity_field_restrictions WHERE entity_type =
   $1` (bound), with NO per-user grant anti-join (the script principal has no user, D5).
3. **N1:** `match.field in R` -> `{:error, :reads_not_allowed}` (no opt-in exists for hook 1, C10;
   the filter can never become an oracle on a restricted field).

Phase 2, exactly ONE query per read (INV-5, same round trips for hit, miss, malformed and unknown):
* `id_from`: value = `input_vars[id_from]`; a non-UUID or nil value is replaced by the nil UUID
  (never generated as a record id); `Record.Latest` by `(entity_type, record_id)` with `deleted =
  false`; at most 1 row.
* `field`/`value_from`: `Query.Compiler.compile(%{entity_type, filters: [%{field, op: :eq, value}]},
  prefix)` (allowlist + bound parameters), plus `deleted = false`, `order_by record_id`, `limit
  min(limit, 50)`; a nil/non-scalar value issues the same query with a constant-false predicate;
  a compile error -> `{:error, :reads_not_allowed}` (deterministic, type/field level).

Projection per row: `"id"` = record id; for each `f` in `fields`: included iff present in
`field_values` AND `f not in R`; otherwise OMITTED (absent = same as never set; no sentinel). Misses, deleted, unknown ids and redacted rows
are indistinguishable from "not set" (D5 read contract). The tenant prefix comes only from the
caller's run context; no table or schema name is ever built from manifest text. No ETS, no
persistent_term, no process-dictionary state survives a call (no caching across runs).

### 11.3 Run-time policy re-checks (dispatcher, 5.3 step 3 in 7c-2)

[CDV C3] In 7c-2, 5.3 step 3 runs exactly, in this order, with the first failure winning:
1. 3a `closed_output_schema?` (-> `output_schema_open`);
2. 3b restricted opt-in present (non-empty `restricted_inputs` or any non-empty
   `reads[].restricted_fields`) -> `restricted_opt_in_unsupported`: a REFUSAL backstop of C10 (the
   manifest is immutable and activation already refused it). There is NO `restricted_allowed?`
   value, NO publisher permission re-check and NO opt-in branch anywhere in 7c (no dead code). The
   7b-2a section 8 item 3 publisher re-check becomes relevant only when C10 is lifted;
3. 3c `Policy.check_reads(prefix, manifest)` -> `{:error, :reads_not_allowed}` -> `reads_not_allowed`
   (7b-2a section 8 item 2, including P12: a `match.field` that is restricted NOW and not in
   `restricted_fields`, which for hook 1 means ANY currently restricted `match.field`).

Then step 4 (secret), step 5 builds variables and calls the port; a port `{:error,
:reads_not_allowed}` (11.2 phase 1, which repeats the N1 check against the current restrictions) ->
`script_rejected` / `reads_not_allowed`; no partial input, no run. Both N1 checks (check_reads and
port phase 1) precede every record query, so a `match.field` restricted AFTER publish is refused
before any record is read (AC26).

### 11.4 Boundary rule (`mix letflow.check_boundaries`, Rule 6)

A declarative table `@layer_rules [{source_prefixes: ["lib/letflow/engine.ex",
"lib/letflow/engine/"], forbidden_target_prefixes: ["lib/letflow/entities.ex",
"lib/letflow/entities/"], reason: "engine -> entities only via Letflow.Engine.ScriptReadPort (0053
F10)"}]`, evaluated in `classify_edge/2` BEFORE Rule 0. Today the rule holds (0.9). Unit tests feed
synthetic edges; the real task run is part of `mix letflow.check`.

F10 interpretation [CDV C8], for REVIEWER to confirm: 0053 F10 says "the engine names no
`Letflow.Entities` module", i.e. a DIRECT edge, and Rule 6 checks direct file edges only. One
INDIRECT path exists and is accepted: engine -> `Scripts.Runtime` -> `Scripts.Policy` ->
`Entities.Definitions` (definition METADATA: active definition and field names, for `check_reads`).
Entity RECORDS are read only through the port. If REVIEWER reads F10 as transitive, the alternative
is to move `check_reads`' metadata lookups behind the port as a second callback; this design does not
do that.

## 12. Worked example (test fixture, 7c-1)

Fixture files under `test/support/fixtures/scripts/`: `purchase_request_pricing.lua`,
`purchase_request_pricing.manifest.json`, `purchase_request_pricing.test_cases.json`, and a
definition `purchase_request_definition.json`. Key `purchase_request_pricing`, version 1, a pure
function of the instance's own variables.

Manifest:

```json
{
  "input_schema": {
    "type": "object",
    "properties": {
      "line_items": {"type": "array", "items": {
        "type": "object",
        "properties": {
          "sku": {"type": "string", "minLength": 1, "maxLength": 64},
          "qty": {"type": "integer", "minimum": 1},
          "unit_price_cents": {"type": "integer", "minimum": 0}
        },
        "required": ["sku", "qty", "unit_price_cents"], "additionalProperties": false}},
      "tax_rate_bp": {"type": "integer", "minimum": 0, "maximum": 10000}
    },
    "required": ["line_items", "tax_rate_bp"]
  },
  "output_schema": {
    "type": "object",
    "properties": {
      "subtotal_cents": {"type": "integer", "minimum": 0},
      "tax_cents": {"type": "integer", "minimum": 0},
      "total_cents": {"type": "integer", "minimum": 0},
      "approval_tier": {"type": "string", "enum": ["auto", "manager", "director", "board"]}
    },
    "required": ["subtotal_cents", "tax_cents", "total_cents", "approval_tier"],
    "additionalProperties": false
  },
  "fail_codes": ["empty_order", "quantity_too_large"],
  "limits": {"instructions": 200000, "timeout_ms": 500, "heap_words": 1048576}
}
```

Source (Lua fixture data, not Elixir):

```lua
local items = ctx.input.line_items
local rate = ctx.input.tax_rate_bp
if #items == 0 then fail("empty_order") end
local subtotal = 0
for _, item in ipairs(items) do
  if item.qty > 10000 then fail("quantity_too_large") end
  subtotal = subtotal + item.qty * item.unit_price_cents
end
local tax = math.tointeger(math.floor((subtotal * rate + 5000) / 10000))
local total = subtotal + tax
local tier
if total < 100000 then tier = "auto"
elseif total < 1000000 then tier = "manager"
elseif total < 10000000 then tier = "director"
else tier = "board" end
return { subtotal_cents = subtotal, tax_cents = tax, total_cents = total, approval_tier = tier }
```

Tax is rounded half up in integer cents. `fail` carries no details (D5: details must never
interpolate input; the author keeps the SKU out). NOT VERIFIED on lua 1.0.2: that `math.floor` of a
float returns a float or an integer (either way `math.tointeger` yields an integer) and that `#` on
a metatable-free array table is the array length; the fixture's own stored tests prove both at
publish.

Stored test cases (all must pass at publish; inputs satisfy `input_schema`):

| name | input | expect |
|---|---|---|
| `manager_tier_two_lines` | `line_items: [{A-1, 2, 125000}, {B-2, 1, 50000}]`, `tax_rate_bp: 1200` | output `{300000, 36000, 336000, "manager"}` |
| `auto_tier_rounding` | `[{C-3, 3, 333}]`, `1250` | output `{999, 125, 1124, "auto"}` (exact tax 124.875 rounds to 125) |
| `director_tier` | `[{E-5, 4, 500000}]`, `800` | output `{2000000, 160000, 2160000, "director"}` |
| `board_tier_zero_tax` | `[{D-4, 10, 1000000}]`, `0` | output `{10000000, 0, 10000000, "board"}` |
| `empty_order` | `[]`, `1200` | fail `empty_order` |
| `quantity_too_large` | `[{F-6, 10001, 1}]`, `1200` | fail `quantity_too_large` |

(Output tuples are `{subtotal_cents, tax_cents, total_cents, approval_tier}`; the JSON file spells
each object in full.)

Definition: `START -> SERVICE_TASK "price_order" {"script_key": "purchase_request_pricing",
"script_version": 1} -> EXCLUSIVE_GATEWAY on approval_tier -> (auto: END) | (else: HUMAN_TASK
"approve" role APPROVER -> END)`; variable schema declares `line_items`, `tax_rate_bp`,
`subtotal_cents`, `tax_cents`, `total_cents` (integers) and `approval_tier` (enum of the four). A
second variable-schema variant restricts `approval_tier` to `["auto", "manager", "director"]` for
the `variable_schema_rejected` test.

Second fixture `purchase_request_writes_attempt` v1 (C11 test) [SEC S1]: input `{attempt_write:
boolean, amount_cents: integer}`; output_schema CLOSED: `{"type": "object", "properties":
{"total_cents": {"type": "integer"}}, "required": ["total_cents"], "additionalProperties": false}`
(so it activates under C11a). It returns `{total_cents = amount}` and, only when `attempt_write` is
true, also `["$writes"] = {{entity_type = "purchase_order", command = "create"}}`. Its stored test
uses `attempt_write: false` so it publishes; a run with `true` is refused `output_invalid` /
`writes_not_allowed` because the `$` check runs BEFORE the schema check (5.3 step 8), not
`output_schema`.

Third fixture `purchase_request_extra_output` v1 (C11a test): same closed schema; returns
`{total_cents = amount, approval_tier = "auto"}` when input `add_extra` is true (stored test uses
false); a run with `true` -> `output_invalid` / `output_schema`, and the instance's pre-existing
`approval_tier` variable is unchanged. A variant `purchase_request_open_schema` v1 with
`output_schema {"type": "object"}` publishes but its binding is refused at activation
(`script_output_schema_open`).

## 13. Changed and new modules (summary)

| Module | Part | Change |
|---|---|---|
| `Engine.ServiceTask` | 7c-1 | `:script` route, config fields, parse errors (4.1) |
| `Definitions.Graph` | 7c-1 | CHK-10 widened, CHK-10s (4.2) |
| `Engine.PinResolver`, `Engine.PinRebind` (test only) | 7c-1 | `:script` kind (4.3) |
| `Letflow.Engine` | 7c-1 | pin lookup, arm branch, binding error handling, cancel step, `apply_script_task_result/3`, generalised advance pipeline (4.4, 5.4, 5.6) |
| `Engine.ScriptTaskDispatcher` (+ `.ScriptTaskDispatch`, `.RunRecord`, `.Poller`), `Engine.ScriptInput` | 7c-1 new | section 5 |
| `Engine.Reconstruction` | 7c-1 | two clauses (6) |
| `Scripts.Runtime` | 7c-1 new | `pin_lookup/1`, `check_bindings/2`, `referenced_by_active_definition?/3`, `prepare_run/3`, `check_output/2`, `closed_output_schema?/1`, `declared_outputs/1` |
| `Scripts`, `Scripts.Validation`, `Scripts.HmacSecret` | 7c-1 | retire block, `check_output` in tests/dry-run, `$` names, `hmac_fun/1`, `build_hmac_fun/2` |
| `Definitions`, `Definitions.Promotion` | 7c-1 | `check_bindings/2` in three activation paths |
| `TenantProvisioning` | 7c-1 | two migrations, two event types |
| `Obs.Alerts` | 7c-1 | fifth trigger (7.3) |
| `Engine.LuaScriptAudit` | 7c-1 | writer removed (10) |
| `Supervisor.Pollers`, `config/*.exs` | 7c-1 | gated child, config keys |
| `Engine.ScriptReadPort`, `Entities.ScriptReads`, `check_boundaries` | 7c-2 new | section 11 |

## 14. Acceptance criteria

### 7c-1

* **AC1** A SERVICE_TASK with `script_key`/`script_version` parses to route `:script`; with also
  `endpoint` or `service_id` it is refused at definition save (`:conflicting_service_task_routes`)
  and at parse (`:conflicting_routes`); a bad key or non-integer/<1 version is refused
  (`:invalid_script_reference`). HTTP parse unchanged.
* **AC2** Activation of a definition binding a draft, discarded, retired, revoked or absent `(key,
  version)` is refused with `{:script_binding_invalid, node_id, :script_not_published}` (422) in
  `Definitions.activate/2`, in promotion and in version rollback; a published version activates.
  Two versions of one key -> `:script_version_conflict`; non-empty `reads` ->
  `:script_reads_unsupported`; restricted opt-in -> `:script_restricted_opt_in_unsupported`.
* **AC2a [SEC S1]** A binding whose `output_schema` lacks top-level `properties` or
  `"additionalProperties": false` is refused at activation with `:script_output_schema_open` (all
  three paths); the same version, run through `prepare_run/3` directly, is rejected
  `script_rejected` / `output_schema_open` before admission.
* **AC2b [SEC S1]** A run whose output carries a key not declared in the closed output schema
  (`purchase_request_extra_output`, `add_extra: true`) fails `output_invalid` / `output_schema`;
  the targeted pre-existing variable is unchanged; on success, the set of keys merged into the
  variables equals the declared properties present in the output, never more.
* **AC3** Retire of a version bound by an ACTIVE definition -> 409 `version_in_use`, nothing written
  or audited; after that definition is deprecated (no active binding left), the same retire
  succeeds; revoke is never blocked.
* **AC4** INSTANCE_STARTED carries the `:script` pin `(key, version, sha256, resolved_id)`; after
  version 2 is published and a new definition version binds it, the in-flight instance still runs
  version 1 (its run record shows version 1 and sha1). A retired version cannot be newly pinned
  (start refused `unresolved_script_ref`); a revoked pinned version fails closed (`script_rejected` /
  `script_revoked`). `PinRebind` refuses kind `script`; a sub-process child neither inherits nor
  loses a script pin.
* **AC5** A due row is claimed (`running`, attempt 1, lease = `lease_ms()` from claim), the run holds
  no transaction, and the result is applied in ONE transaction: variables merged with real
  validations, `SCRIPT_TASK_COMPLETED` + `SCRIPT_RUN_RECORDED` appended, row `applied`, token advanced.
* **AC6 (F-E)** The apply is a CAS on `(id, instance_id, node_id, attempt, status 'running')`: a
  second apply of the same result, an apply with an older attempt, and an apply after the lease
  sweep each return `:stale` and change nothing (events, variables, row, DLQ counts unchanged).
* **AC7a (F-E, killed dispatcher) [CDV C2]** Killing the dispatcher process mid-run (the process
  that called the runner) makes the watchdog kill the worker and exit; the `ScriptAdmission` slot is
  released (count back to 0); NO apply happens, so the row stays `running`; after its lease expires
  the sweep turns it into a `timeout` / `lease_expired` incident (ERROR + DLQ, `phase:
  lease_expired`) and the script is NOT run again.
* **AC7b (F-E, killed watchdog) [CDV C2]** Killing the watchdog mid-run kills the linked worker and
  releases the slot (Admission `:DOWN`); the caller's `Task.yield` gets `{:exit, _}`, which 7a maps
  to `script_error`; the dispatcher therefore applies IMMEDIATELY: row `failed`, outcome
  `script_error`, `phase: ran`, incident written, no lease wait, never re-run.
* **AC8** Only `script_busy` is retried: with all admission slots held the row returns to `pending`
  with `next_attempt_at = now + 500 ms`, `busy_retries 1`, no event; after release it is applied on a
  later claim (attempt 2). After `busy_retry_limit` reschedules the next busy outcome is a
  `script_busy` / `busy_retries_exhausted` incident. Each of `script_error`, `budget_exceeded`,
  `memory_limit_exceeded`, `timeout`, `script_failed`, `output_invalid` ends the row `failed` after
  exactly ONE run, with an incident, and the row is never claimed again. [CDV C11] A
  `script_rejected` row (e.g. kill switch) ends `failed` after ZERO runs (the runner seam records no
  call) and is never claimed again.
* **AC9** Output failing the manifest output schema -> `output_invalid` / `output_schema`, instance
  ERROR, DLQ incident; output rejected by the definition's variable schema -> `output_invalid` /
  `variable_schema_rejected`, variables unchanged; a list output -> `output_not_object`.
* **AC10 (fence)** An output with a top-level `$` key (the `$writes` fixture, closed schema) ->
  `output_invalid` / `writes_not_allowed`, no variable and no entity changed (entity table row counts
  unchanged); a stored test and a dry-run returning `$writes` report `output_invalid`; an
  `output_schema` property named `$x` is refused at save (422 `invalid_manifest`).
* **AC11** Kill switch ON (tenant latch, and separately the platform latch): the claimed row fails
  closed `script_rejected` / `scripts_disabled` with an incident; the runner seam is never called and
  no admission slot is acquired; it is not retried. [SEC S5] A tenant set `:inactive` (and
  separately `:migrating`) fails closed `script_rejected` / `tenant_inactive` the same way.
* **AC12** The per-run record has EXACTLY the section 7.1 key set; for a run whose variables and
  output contain unique sentinel strings, neither the `SCRIPT_RUN_RECORDED` payload, nor the
  dispatch row, nor any captured log line contains a sentinel; `input_hmac` equals HMAC-SHA256 under
  the tenant key of the canonical document and `input_hmac_key_version` equals the secret's
  `key_id`; `principal` and `triggering_user_id` are set (user for a complete_task-triggered run,
  NULL for a timer-triggered one). [SEC S3] Forced-crypto-failure sentinel: with a closure from
  `HmacSecret.build_hmac_fun/2` over a sentinel non-binary key, supplied through the
  `:script_task_hmac_fun_override` seam (7.2), `:crypto.mac` raises inside the closure, the closure
  returns `{:error, :hmac_failed}` and the row fails `script_rejected` / `hmac_failed`, and
  neither the captured logs nor the payload contain the injected key bytes, an exception message or a
  stacktrace frame; a forced raise inside the per-row pipeline likewise logs only dispatch id,
  tenant schema and the class tag.
* **AC13** A run finds the HMAC secret already present and creates none (secret row count and ids
  unchanged). [CDV C12] With EVERY row of the tenant's `platform/script-input-hmac` secret set to
  `:disabled` (all key versions, by a test-only `update_all` on `Secret` filtered by tenant,
  namespace and name), the run fails `script_rejected` / `hmac_secret_missing`, no secret row is
  created, and exactly ONE alert/log line is emitted across two failing runs; after one version is
  re-activated, a successful run re-arms the trigger.
* **AC14** HMAC backfill re-run: a second `backfill/1` over N tenants returns `{0, N, []}` and every
  secret row (id, key_id, ciphertext, status) is unchanged.
* **AC15 [SEC S4]** Replay of an instance of a definition with TWO CONSECUTIVE script tasks and NO
  HTTP task: `Reconstruction.reconstruct_instance/2`, run with the kill switch ON and both versions
  revoked, reproduces the projection's variables and nodes; during the replay the runner seam records
  zero calls, Ecto telemetry shows zero queries against `script_rules`, `script_policy` and
  `script_readable_masters` and zero INSERTs into `script_task_dispatches`. A source scan of
  `lib/letflow/engine/reconstruction.ex` (that file only) finds none of `ScriptRunner`,
  `ScriptTaskDispatcher`, `ScriptReadPort`, `Letflow.Scripts`.
* **AC16** `LuaScriptAudit`: no writer function, DB refuses INSERT/UPDATE/DELETE, history readable on
  a dedicated tenant (section 10).
* **AC17** Both event types are registered for a newly provisioned tenant and, after
  `replay_migrations/1`, for a tenant provisioned before the change; both migrations replay
  idempotently.
* **AC18** Instance cancel sets `pending` and `running` script rows `cancelled`; a later apply for the
  running one is `:stale`.
* **AC18a [SEC S6]** Apply vs cancel race: with the apply transaction paused after its CAS lock (test
  hook between CAS and projection lock) a concurrent `cancel_instance` blocks on the dispatch row and
  completes after the apply commits (instance cancelled after advancing); with the cancel paused
  after its dispatch-row step a concurrent apply blocks, then returns `:stale` and writes nothing.
  Neither order raises or deadlocks; the pause hooks honour `:scripts_test_hooks` only.
* **AC19** No tenant route can register a WASM plugin (source scan over `lib/letflow/routers/` and
  `lib/letflow/plugs/`: no reference to `PluginRegistry.register_plugin_handler`,
  `Wasm.ModuleRegistry.register` or `ModuleVersionRegistry.register_version`).
* **AC20** The worked example publishes (all six stored cases pass) and, run end to end through
  `run_tick/2`, sets the four output variables and routes by `approval_tier`.
* **AC21** No regression: every existing HTTP SERVICE_TASK, dispatcher, pin, activation and
  Lua/Executor test passes unchanged except the two LuaScriptAudit files replaced per section 10;
  one new assertion pins the HTTP completion event payload keys and idempotency key (5.4).
* **AC29 [SEC S2]** Fairness: tenant A with 6 due rows and tenant B with 1 due row, in one tick: B's
  row is claimed before A's SECOND row (`claimed_at` order); with `tick_budget_ms` small and slow
  rows the tick stops at the deadline (`budget_exhausted: true`) after at most one row past it, and
  the next tick starts at the other tenant (rotating offset). A tenant with a due row never waits for
  another tenant's full backlog: within a tick it waits at most `n - 1` rows; across ticks whose
  budget runs out, the rotating offset bounds the wait at about `n / 2` ticks (late gate note d).
* **AC30 [CDV C9]** A sweep apply that fails (test hook forcing `{:error, _}`) increments
  `sweep_failures`; at `sweep_failure_limit` the row is no longer selected, exactly one `sweep_stuck`
  error line is logged and telemetry emitted; repeated ticks before the limit produce one aggregated
  warning per tenant per tick, not one per row per tick.

### 7c-2

* **AC22** `mix letflow.check_boundaries` fails on a synthetic `lib/letflow/engine/x.ex ->
  lib/letflow/entities/y.ex` edge and passes on the real graph; no engine file names
  `Letflow.Entities`; the port implementation is selected only through `:script_read_port`.
* **AC23** A run of a version declaring reads of a flagged master gets `input["reads"][name]` rows
  with `id` plus the declared fields; by-id miss, deleted record, malformed id and unknown id all
  yield `[]` with exactly one entity query each (Ecto telemetry count); a field match is capped at
  its `limit`.
* **AC24** Each 7b-2a section 8 item-2 cause at run time (flag cleared, definition inactive, type
  restricted, field removed) fails closed `script_rejected` / `reads_not_allowed` before any record
  query.
* **AC25** A restriction added after activation on a field in `fields` is omitted from the delivered
  row on the NEXT run (no caching); removing it restores the field on the run after.
* **AC26 (N1, reachable) [CDV C3]** A published, activated version reads a master by `match.field
  = "status"`; an `entity_field_restrictions` row on `status` is added AFTER publish (not opted in;
  opt-in does not exist for hook 1). The next run fails closed `script_rejected` /
  `reads_not_allowed` with ZERO queries against `entity_record_latest` or the type's table (Ecto
  telemetry), and the port's phase 1 refuses the same read when called directly.
* **AC26a** A version with non-empty `restricted_fields` inserted directly (bypassing activation)
  is rejected by `prepare_run/3` with `restricted_opt_in_unsupported`, and the port is never called.
* **AC27** Kill switch ON with declared reads: zero port calls (recording stub).
* **AC28** A cross-tenant read is impossible: the port's queries carry only the run's prefix; a
  manifest naming another tenant's type behaves as an unknown type (`reads_not_allowed`).

## 15. Test brief (TEST-DESIGNER)

Rules: tests call `ScriptTaskDispatcher.run_tick/2`, `claim_next/1` and `run_claimed/2` directly
(the poller is off in test); the runner seam (`:script_task_runner` with `:scripts_test_hooks`) is
used ONLY for call-count assertions and the AC12 crypto fault, never to fake outcomes the real runner
can produce; real scripts drive every outcome (busy: hold all `ScriptAdmission` slots from helper
processes; memory: the 7a refc fixture; timeout: `pcall` busy loop with `timeout_ms: 100`). Lease
expiry is simulated by back-dating `lease_expires_at` (no sleeps on the lease). Kill tests (AC7a/b)
run the pipeline in a spawned process standing in for the poller, kill it (or the watchdog, found via
the Task.Supervisor's children), and wait with a monitor plus `assert_receive` with a generous
timeout (anti-pattern 4709). Sentinel assertions use `ExUnit.CaptureLog` over the whole pipeline.
Query counts use Ecto telemetry handlers scoped to the test pid. Concurrency tests (AC18a) use
`Ecto.Adapters.SQL.Sandbox` shared mode with two processes and the pause hooks. Tenants follow the
pooled-fixture rules (anti-pattern 4680); AC16's history test uses its own dedicated schema.

AC -> suite / named test [CDV C7]:

| AC | Suite (new unless marked) | Named test(s) |
|---|---|---|
| AC1 | `test/letflow/engine/service_task_test.exs` (ext), `test/letflow/definitions/graph_test.exs` (ext) | `script route parses`, `conflicting routes refused`, `invalid script reference` |
| AC2 | `test/letflow/definitions/script_bindings_activation_test.exs` | `refused per status x3 paths`, `version conflict`, `reads unsupported`, `restricted opt-in` |
| AC2a | same | `open output schema refused x3 paths`, `prepare_run output_schema_open` |
| AC2b | `test/letflow/engine/script_task_apply_test.exs` | `undeclared key refused`, `only declared keys merged` |
| AC3 | `test/letflow/routers/script_rules_test.exs` (ext) | `retire bound -> 409`, `retire after deprecate ok`, `revoke never blocked` |
| AC4 | `test/letflow/engine/pin_resolver_script_test.exs` | `pin frozen across publish`, `retired not pinnable`, `revoked fails closed`, `rebind refuses script`, `child no inherit` |
| AC5 | `test/letflow/engine/script_task_dispatcher_test.exs` | `claim then apply one tx` |
| AC6 | `script_task_apply_test.exs` | T-CAS-dup, T-CAS-old-attempt, T-CAS-after-sweep |
| AC7a / AC7b | `script_task_dispatcher_test.exs` | T-kill-dispatcher, T-kill-watchdog |
| AC8 | `script_task_dispatcher_test.exs` | T-busy-reschedule, T-busy-exhausted, T-terminal-<code> x6, T-rejected-zero-runs |
| AC9 | `script_task_apply_test.exs` | `output_schema`, `variable_schema_rejected`, `output_not_object` |
| AC10 | `script_task_apply_test.exs`, `test/letflow/scripts/validation_test.exs` (ext), `script_rules_test.exs` (ext) | T-writes-refused, `stored test $ fails`, `dry-run $`, `manifest $ name refused` |
| AC11 | `script_task_dispatcher_test.exs` | `kill switch tenant latch`, `kill switch platform latch`, `tenant inactive`, `tenant migrating` |
| AC12 | `test/letflow/engine/script_run_record_test.exs` | `exact key set`, `sentinels absent`, `hmac recomputes`, `principal and user`, T-crypto-fault, `raise logs tag only` |
| AC13 | `test/letflow/scripts/hmac_secret_test.exs` (ext) | T-secret-present-none-created, T-secret-missing-one-alert, `rearm after restore` |
| AC14 | `test/mix/tasks/letflow.backfill_script_hmac_secrets_test.exs` | T-backfill-rerun |
| AC15 | `test/letflow/engine/script_task_replay_test.exs` | T-R-two-scripts, `reconstruction.ex source scan` |
| AC16 | `test/letflow/engine/lua_script_audit_retired_test.exs` | `no writer`, `row trigger refuses`, `history readable (dedicated tenant)`, `no lib writer scan` |
| AC17 | `test/letflow/tenant_provisioning_script_events_test.exs` | `new tenant seeded`, `existing tenant seeded on replay`, `migrations idempotent` |
| AC18 | `script_task_dispatcher_test.exs` | `cancel pending and running`, `apply after cancel stale` |
| AC18a | `test/letflow/engine/script_task_cancel_race_test.exs` | `apply first`, `cancel first` |
| AC19 | `test/letflow/routers/no_tenant_wasm_registration_test.exs` | `source scan` |
| AC20 | `test/letflow/scripts/purchase_request_example_test.exs` | `publishes`, `end to end routes by tier` |
| AC21 | existing suites + `test/letflow/engine/service_task_engine_wiring_test.exs` (ext) | `http completion payload pinned` |
| AC29 | `script_task_dispatcher_test.exs` | T-fair-round-robin, T-tick-budget, T-rotating-offset |
| AC30 | `script_task_dispatcher_test.exs` | T-sweep-stuck, T-sweep-aggregated-log |
| AC22 | `test/mix/tasks/letflow.check_boundaries_test.exs` (ext) | `rule 6 synthetic edge`, `real graph passes` |
| AC23-AC25 | `test/letflow/entities/script_reads_test.exs` | `rows shape`, `miss equivalence one query`, `limit cap`, `run-time causes x4`, `restriction re-redacts next run` |
| AC26, AC26a | `script_reads_test.exs`, `test/letflow/scripts/runtime_test.exs` | T-N1-after-publish, `opt-in backstop` |
| AC27 | `script_task_dispatcher_test.exs` | `kill switch no port call` |
| AC28 | `script_reads_test.exs` | `prefix only from run context` |

## 16. Security mapping (INV)

* **INV-1** The tenant prefix comes only from the provisioned `Registration` list in the poller;
  every query (dispatch rows, `script_rules`, policy, projection, events, port) uses that prefix; the
  HMAC key is resolved by the tenant id derived from the prefix and `Secrets.resolve/2`'s own
  slug-to-id match. The port never accepts a prefix or type from anywhere but the run context and
  the validated manifest. [SEC S2] Cross-tenant fairness: round-robin under a tick budget (5.1a).
* **INV-2** Outputs land only in the instance's DECLARED variables (8.1, C11a); run record and
  dispatch row are value-free allowlists (7.1); restricted fields are omitted, opt-in is refused for
  hook 1 (C10), and run-time re-checks re-redact and refuse restricted match fields (11.2-11.3).
* **INV-3** Every execution goes through 7a's sandbox, limits, watchdog and admission; the kill
  switch, an inactive tenant and `revoked` stop runs before admission; no new host function; replay
  never executes.
* **INV-4** The HMAC key is resolved by reference through the reserved namespace with `case`
  matching, kept in a closure that catches crypto faults, never logged, returned or stored; only
  `key_id` is recorded; it is never created on the run path.
* **INV-5** Port misses, deleted, malformed and unknown ids and redacted rows are indistinguishable
  and cost one query each; activation refusal codes are tenant-local.
* **INV-6** New data-access paths: `script_task_dispatches` (tenant schema, no route), the port
  (tenant schema, flagged masters only), the retire reference query (tenant schema). This section is
  the scoping statement.
* **INV-7** All queries are Ecto with bound parameters, including the jsonb containment document and
  the field-match compile; migrations interpolate only `prefix()`.
* **INV-8** Every failure maps to one of the eight codes plus a closed detail code; the poller never
  raises; rescues bind no stacktrace and format nothing; incidents carry fixed sentences.
* **INV-10** No platform authority is used; the platform kill-switch latch is honoured through
  `kill_switch_on?/1`.

## 17. Closed-set changes and edges needing REVIEWER sign-off

1. Instance event types `SCRIPT_TASK_COMPLETED` and `SCRIPT_RUN_RECORDED` (seed list, 6).
2. Pin kind `:script` with the extra `sha256` field; excluded from overrides, rebind and inheritance (C7).
3. Route kind `:script` and config parse errors (4.1); graph CHK-10 widening and CHK-10s (4.2);
   the closed-output-schema binding rule (C11a).
4. New dependency edges [CDV C8]:
   * engine (`engine.ex`, `script_task_dispatcher.ex`) -> `Letflow.Scripts.Runtime` (facade, C18);
   * engine (`script_task_dispatcher.ex`) -> `Letflow.Obs.Alerts` (new: no engine file references
     Obs today, 0.12); `Letflow.Scripts` has NO edge to `Obs`;
   * `Letflow.Definitions` (`definitions.ex`, `definitions/promotion.ex`) -> `Scripts.Runtime`
     (`check_bindings/2`), and `Scripts.Runtime` -> `Definitions.Graph` and
     `Definitions.ProcessDefinition` (leaf struct/schema modules, for `check_bindings/2` and the
     retire reference query). Context-level this is Definitions <-> Scripts; file-level there is NO
     cycle (`graph.ex` and `process_definition.ex` reference neither `definitions.ex` nor any Scripts
     file). Justification: the activation check must run inside the definition's transaction
     (Definitions calls Scripts), and the retire check must see definitions (Scripts reads the
     schema); keeping the Scripts side on leaf modules avoids a compile or runtime call cycle.
   * engine -> entities ONLY via `ScriptReadPort` (7c-2), enforced by `check_boundaries` Rule 6 on
     DIRECT edges; the indirect metadata path engine -> `Scripts.Runtime` -> `Scripts.Policy` ->
     `Entities.Definitions` is accepted under the direct reading of F10 (11.4).
5. A fifth alert trigger `script_hmac_secret_missing` (7.3).
6. A new gated poller child under `Letflow.Supervisor.Pollers` (C2), started after
   `MigrationReplayBoot` by construction (0.12).
7. `error_type :script_task_failed` and `:script_task_pin_unresolved` (open atom set, listed for visibility).
8. Removal of `LuaScriptAudit.execute_script_for_audit/6` (C17).
9. [CDV C4] **C10, supervisor-ratified 2026-10-15**: restricted opt-in (`restricted_inputs`,
   `reads[].restricted_fields`) is refused for hook-1 bindings, narrowing 0053 open point 2's opt-in
   until process variables can carry restrictions (letflow-2 records it in 0053). REVIEWER signs the
   narrowing as consistent with D5.
10. `cancel_instance` gains the `:script_task_dispatch_cancellations` step before
    `:instance_projection` (lock order, 5.6).

## 18. Deferred

* Entity writes from scripts (`$writes` channel) after #2587/#2590 via module handlers.
* Restricted opt-in for hook 1 (needs restricted variables or Record E's derived-output declaration).
* Dynamic data API (Records E/F); hooks 2-4; pack scripts and promotion (Record P).
* Manual operator re-run of a failed script step (DLQ retry stays bookkeeping).
* Output validation for ALL service tasks (0053 Deviation 2).
* 0051 stage 2: `tenant_wide` replaces `script_readable_masters`; the port then adds the record-scope
  filter (records carry no scope today, 0.9).
* A tenant-facing view of `script_task_dispatches` (none in 7c); web rendering of the two new event
  types.

## 19. Residuals (stated)

* **R1** A readable-master flag cleared between `check_reads` and the port query (milliseconds) can
  let that one run read; the next run is refused (7b-2a P5, accepted there).
* **R2** A kill-switch flip does not stop a run already executing (<= 5 s, 7b-2a).
* **R3** If the database stalls past the 30 s lease, a slow-but-alive run becomes a `lease_expired`
  incident and its result is discarded by the CAS (safe direction: never a double apply).
* **R4 (fairness guarantee, not a residual risk) [SEC S2]** One poller per node runs scripts
  sequentially, round-robin across tenants, one row per tenant per pass, under `tick_budget_ms`
  (5.1a). Guarantee [late gate note d]: within a tick, a tenant with a due row waits at most `n - 1`
  rows, one of every other tenant with a due row in the same pass (<= `(n - 1) x 7 s`); across
  ticks, when the budget runs out every tick, the rotating start offset bounds the wait at about
  `n / 2` ticks (at most `n - 1`); no tenant's backlog can delay another by more than one row per
  pass; a tick overruns its budget by at most one row. What remains is throughput:
  with many busy tenants on one node, latency grows linearly with the number of busy tenants (more
  nodes add pollers, `SKIP LOCKED` spreads rows). HTTP dispatch is unaffected.
* **R5** An attempt whose instance is no longer active at apply leaves its trace only on the dispatch
  row (append refuses terminal instances).
* **R6** Pre-existing: HTTP `SERVICE_TASK_COMPLETED` has no replay clause, so replay of an instance
  that ran an HTTP service task fails `unrecognized_event_type`; not introduced or fixed here
  (scope fence); ORCH should file it.
* **R7** `math.floor`/`#` behaviour of lua 1.0.2 used by the fixture is proved by its stored tests,
  not by a separate spike (12).
* **R8** The triggering-user value depends on each hop site's existing actor; sites without one store
  NULL (4.4).
* **R9 [late gate note a]** An apply that commits while a `cancel_instance` waits on the dispatch row
  can leave an orphan `pending` script row on the cancelled instance: the apply's hop chain may arm
  the NEXT script node's row, which the cancel's already-running `UPDATE` statement cannot see
  (READ COMMITTED re-checks only rows in its snapshot). The row is inert: the claim joins
  `instance_projections.status = :active`, so it is never claimed, run or applied. The AC18a
  "apply first" test asserts any leftover row is never claimed. A future instance purge removes it
  (DELETE is not refused, 3.1).

## 19a. Implementation notes (7c-1, ELIXIR-DEV)

* [late gate note c, SECURITY] Boot guard: `Letflow.Application.start/2` refuses to start when
  `config :letflow, :config_env` (set from `config_env()` in `config/config.exs`) is `:prod` and
  `:scripts_test_hooks` is `true` (`Letflow.Scripts.Runtime.boot_check/2`, fixed-text raise). Every
  7b/7c test seam is honoured only while that flag is true. Test:
  `test/letflow/scripts/runtime_boot_check_test.exs`.
* Migration timestamps: main already carries tenant migration `20261015025331` (role scope grants),
  so the two 7c-1 migrations take the next free, ordered slots `20261015100001` (dispatch table)
  and `20261015100002` (LuaScriptAudit read-only), per 3.1 "next free timestamp".
* CHK-11 (`timeout_ms` required on every SERVICE_TASK) does not apply to a script-bound node: its
  `timeout_ms` is ignored (4.1), and the worked example's node (12) carries none.
* Stored-test evaluation and dry-run apply the C11 `$` refusal only (`Scripts.Runtime.writes_key?/1`
  -> `output_invalid`); the C11a undeclared-key refusal is a hook-1 BINDING rule (activation and
  run), so a draft with an open output schema keeps its 7b test/dry-run behaviour otherwise.
* The `script_busy` exhaustion, sweep and B' follow-up all reuse `apply_script_task_result/3`; the
  engine normalises the run facts' `outcome`/`detail` from the result tuple, so the run record and
  the row always agree.
* A missing/unusable `:script` pin at a non-create hop is handled exactly like the catalog case:
  `complete_task/3` routes it to an ExecutionError (`:script_task_pin_unresolved`); the timer,
  HTTP-advance, script-advance and sub-process hops roll back with a typed error (their existing
  catalog behaviour), which on the script-advance hop becomes a B' `apply_failed` incident.
* The 409 for a blocked retire uses the script-rules router's existing conflict family (`detail:
  "version_in_use"`), like `version_immutable`.

## 20. Open questions

None blocking. Items marked NOT VERIFIED above (R7, the exact actor value at each hop site) are
settled by ELIXIR-DEV's tests, not by assumption.
