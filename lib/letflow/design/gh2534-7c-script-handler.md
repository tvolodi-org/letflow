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
| C2 | A separate `ScriptTaskDispatcher.Poller` GenServer (gated `:start_script_task_dispatcher`), claiming ONE row per claim transaction and running it before claiming the next. | Script runs (<= 7 s each with the caller margin) must not delay HTTP dispatch and vice versa; one-row claims keep every claimed row's lease alive (a batch claim would let queued rows' leases expire while earlier rows run). The poller process IS "the dispatcher" whose death the 7a watchdog observes. |
| C3 | Lease = `5_000` (platform max wall clock) + `2_000` (7a caller margin) + `lease_margin_ms` (config, default 23_000, clamped >= 1_000) = 30 s by default, set at claim. | D2: "at least the maximum wall clock plus a margin". It is set before the manifest is loaded, so it uses the platform maximum, not the version's own timeout. |
| C4 | The CAS key is the row id plus `(instance_id, node_id, attempt)` and `status = 'running'`, read `FOR UPDATE` in the apply transaction. | D2/F-E: a duplicate or late apply (or one racing the lease sweeper) finds no matching row and writes nothing. `attempt` increments at every claim, so an apply from an older claim never matches. |
| C5 | Busy policy: on `script_busy` the row goes back to `pending` (same CAS) with `next_attempt_at = now + min(500 * 2^busy_retries, 30_000)` ms, no jitter, no instance event; after `busy_retry_limit` (default 10) rescheduled attempts the next busy outcome is terminal (`script_busy`, detail `busy_retries_exhausted`) and becomes an incident. Every other outcome is terminal on its first occurrence. | D7: only `script_busy` is retriable; a cap is needed so a permanently saturated node cannot loop forever. Deterministic backoff matches `ServiceTask.compute_service_task_backoff_ms/3`. |
| C6 | An expired lease (`status = 'running' AND lease_expires_at < now`) is turned by the poller's sweep into a terminal `timeout` / detail `lease_expired` incident through the same CAS; it is NEVER put back to `pending`. | D2: never re-run automatically; the CAS makes a late apply from a slow-but-alive dispatcher a no-op. |
| C7 | Pin `:script`: `ref` = script key, `version` = the integer version as a string (existing `pinned_version` convention), `resolved_id` = `script_rules.id`, plus a NEW field `sha256`. A definition that binds two different versions of the same key is refused (`script_version_conflict`). Script pins are NOT overridable, NOT rebindable (`PinRebind` keeps its closed kind list) and NOT inherited by or from sub-process children. | `{kind, ref}` must identify one pin; D3 requires the frozen `(key, version, sha256)` to never change for an in-flight instance; `apply_inheritance/2` would replace a child's own version with the parent's and drop `sha256` (0.4), so the child would run a version its definition does not name. A script version is part of a definition's own logic, bound by the node attribute and the activation check. |
| C8 | Activation is refused in ALL three activation paths (0.5) and, independently, an instance start refuses an unresolvable script pin. | D2 + F8: pack/promotion-installed definitions must be guarded; start-time refusal is defence in depth (a version retired after activation of a now-deprecated definition cannot be newly pinned, D1). |
| C9 | Instance variables are read by the ENGINE (projection, no lock) and only the 7c-2 master reads go through the port. | The instance's own variables are engine data; routing them through `Letflow.Entities` would invert ownership and add a needless edge. "Pre-fetch" = both sources assembled host-side before the run (section 5.3). |
| C10 | A binding whose manifest opts into restricted data (non-empty `restricted_inputs`, or any `reads[].restricted_fields`) is REFUSED at activation (`script_restricted_opt_in_unsupported`) and rejected at run time as a backstop. | 0053 D5: "the host refuses activation/publish if [a derived output] maps to a target field with fewer restrictions". Hook 1's only targets are process variables, which carry NO field restrictions, so every target has fewer restrictions; the manifest has no key to declare derived outputs. Restricted fields listed only in `fields` remain readable-and-REDACTED (7b-2a P12), and run-time re-checks still apply (7c-2). Lifting this needs restricted variables or Record E. |
| C11 | Write-command recognition: the top-level output key namespace `$` is reserved for host channels; ANY top-level key starting with `"$"` (the designated future channel is `"$writes"`) is refused: outcome `output_invalid`, detail `writes_not_allowed`. The same pure check runs at stored-test evaluation and dry-run, and the manifest refuses `output_schema.properties` names starting with `"$"` (422 `invalid_manifest`). | Supervisor fence: no entity writes; a precise, stable, cheap test that cannot collide with a legitimate variable (no shipped variable starts with `$`); refusing at save/publish/dry-run tells authors early. Nested `$` keys inside a variable's value are plain data and allowed. |
| C12 | The per-run record is an instance-stream event `SCRIPT_RUN_RECORDED` with a closed, value-free payload (section 7); the applied output is recorded separately in `SCRIPT_TASK_COMPLETED` (the replay source). | D9 places the per-run record on the instance stream and forbids values in it; D5 requires replay to apply RECORDED results, which needs the output somewhere; it is instance variable data, the same class as TASK_COMPLETED `output_variables` (and only ever lands in variables). |
| C13 | One terminal attempt = one `SCRIPT_RUN_RECORDED` (applied or failed, including a pre-run rejection and a lease expiry, distinguished by `phase`). A busy attempt that is rescheduled writes none. An attempt whose instance is no longer active at apply writes no event (append refuses completed/cancelled instances, 0.2); its trace is the dispatch row's `outcome`/`outcome_detail`. | Every incident is attributable; no event for something that changed nothing. |
| C14 | The HMAC covers `canonical({"ctx": {instance_id, node_id, token_id, now}, "input": input})`, HMAC-SHA256 under the tenant key resolved through `HmacSecret`, recorded as lowercase hex plus the secret `key_id` (`#n`). The key never leaves a closure (`HmacSecret.hmac_fun/1`). | ctx changes the output (uuid, now), so it belongs in "same inputs"; storing `key_id` lets an auditor recompute with the right key after rotation; a closure keeps the plaintext out of crash reports (function arguments in a `FunctionClauseError` are printed, closure captures are not). |
| C15 | Missing secret: outcome `script_rejected`, detail `hmac_secret_missing`, plus ONE edge-triggered operator alert per tenant (new trigger `script_hmac_secret_missing`, re-armed by the next run that finds the key). Nothing creates a key on this path. | 0053 D9 / advisor Q11 ("never lazily"); "one alert" = edge-triggered, like the existing four triggers. |
| C16 | Incidents use `error_type :script_task_failed`, `affected {:node, node_id}`, a FIXED reason sentence per outcome code, `details` = `%{outcome, detail, fail_code, script_key, script_version, attempt}` (codes and constants only). | INV-8 / D7: stable codes only; no rejected value (unlike the human-task merge path) and no fail `details` (a script can put input values there). |
| C17 | `LuaScriptAudit` retirement: delete `execute_script_for_audit/6` and its insert path; keep `AuditRecord` (read) and the `Executor` behaviour (still implemented by `Lua.Executor`); a tenant migration adds a trigger refusing INSERT/UPDATE/DELETE and a statement trigger refusing TRUNCATE on `lua_script_execution_audit`. | Advisor Q11: no new writes, table stays read-only history. Defence in depth at the DB. |
| C18 | Engine -> Scripts calls go through ONE facade, `Letflow.Scripts.Runtime`; engine -> Entities only through the port (7c-2), resolved from config at run time. | Minimises the new engine->scripts surface for REVIEWER; keeps 0053 F10 ("the engine names no `Letflow.Entities` module") mechanically checkable. |
| C19 | Retire of a version bound by an ACTIVE definition -> 409 `version_in_use`; revoke is never blocked. Activation locks the bound `script_rules` rows `FOR SHARE`; retire already locks the row `FOR UPDATE`, so the two serialise. | D3: "Retiring a script referenced by an active definition is blocked"; revoke is the incident action and fails pinned instances closed at run. |

## 3. Data model (7c-1)

### 3.1 Tenant migration `20261015000001_create_script_task_dispatches.exs`

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

### 3.2 Tenant migration `20261015000002_lua_script_audit_read_only.exs`

Function `lua_script_execution_audit_read_only()` raising `LF001`; `BEFORE INSERT OR UPDATE OR
DELETE ... FOR EACH ROW` and `BEFORE TRUNCATE ... FOR EACH STATEMENT` on
`lua_script_execution_audit`. Down drops both triggers and the function.

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
:script_not_published | :script_version_conflict | :script_reads_unsupported (7c-1 only) |
:script_restricted_opt_in_unsupported`. For every `{key, version}` bound by a SERVICE_TASK node:
`SELECT ... FROM script_rules WHERE key = $1 AND version = $2 FOR SHARE` (bound); refused unless
`status == "published"` and `hook_kind == "service_task"` (absent, draft, discarded, retired,
revoked all -> `:script_not_published`); manifest checks per C10 and (7c-1) non-empty `reads`.
Must run inside the caller's transaction (it takes row locks).

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
query over `process_definitions WHERE status = 'active' AND graph @> $1` with `$1` = the jsonb
document `{"nodes": [{"attributes": {"script_key": key, "script_version": version}}]}` passed as a
BOUND parameter (INV-7). True -> `Repo.rollback(:version_in_use)`; router 409 `{"error":
"version_in_use"}`; nothing written or audited. Revoke unchanged.

## 5. Dispatcher (7c-1)

### 5.1 Modules and config

* `Letflow.Engine.ScriptTaskDispatcher` (`lib/letflow/engine/script_task_dispatcher.ex`), plain
  context module, owns the table, the claim, the sweep, the per-row pipeline, the reschedule and
  cancel writes.
* `Letflow.Engine.ScriptTaskDispatcher.Poller` (`.../script_task_dispatcher/poller.ex`), GenServer,
  same shape as the HTTP poller: zero-delay first tick; per tick, for every provisioned tenant schema,
  `poll_and_dispatch/1`. Child of `Letflow.Supervisor.Pollers`, gated
  `Application.get_env(:letflow, :start_script_task_dispatcher, true)`; `config/test.exs` sets false.
* `config :letflow, :script_task_dispatcher, poll_interval_ms: 1_000, max_dispatches_per_cycle: 16,
  sweep_limit: 64, lease_margin_ms: 23_000, busy_retry_limit: 10, busy_backoff_base_ms: 500,
  busy_backoff_cap_ms: 30_000` (read fresh per tick).
* Test seam: `:script_task_runner` (default `Letflow.Engine.Lua.ScriptRunner`, a module with
  `run/3`), honoured only when `Application.get_env(:letflow, :scripts_test_hooks, false) == true`
  (the 7b-2a seam convention; set only in `config/test.exs`).

Public functions (`@spec` shapes):

```
poll_and_dispatch(prefix :: String.t()) ::
  %{tenant_schema, swept, claimed, applied, failed, rescheduled, stale, cancelled :: non_neg_integer()}
sweep_expired_leases(prefix, limit :: pos_integer()) :: non_neg_integer()
claim_next(prefix) :: {:ok, ScriptTaskDispatch.t()} | :none
run_claimed(ScriptTaskDispatch.t(), prefix) ::
  {:ok, :applied | :failed | :rescheduled | :cancelled | :stale} | {:error, :apply_failed}
cancel_open_dispatches(repo :: module(), instance_id, at :: DateTime.t(), prefix) :: {:ok, non_neg_integer()}
busy_backoff_ms(busy_retries :: non_neg_integer()) :: pos_integer()            # pure
lease_ms() :: pos_integer()                                                      # 7_000 + clamp(lease_margin_ms)
```

`poll_and_dispatch/1` never raises (per-row `try/rescue/catch`, each catch maps to a count and one
log line with dispatch id, tenant schema and a class tag only; never `inspect`).

### 5.2 Claim (transaction A, short)

1. Unlocked select of at most one id: `status = 'pending' AND next_attempt_at <= now` joined to
   `instance_projections.status = :active`, ordered by `next_attempt_at`.
2. Lock by id `FOR UPDATE SKIP LOCKED` with `status = 'pending'` re-asserted; set `status =
   'running'`, `attempt = attempt + 1`, `claimed_at = now`, `lease_expires_at = now + lease_ms()`,
   `claimed_by`, `updated_at`; COMMIT. Returns the updated row.

The run itself holds NO transaction and NO pooled connection (D2, F3).

### 5.3 Per-row pipeline (`run_claimed/2`, no transaction)

Order is normative. Steps 1-4 run before admission and before any data read (D7 kill switch,
7b-2a section 8). A refusal at any step jumps to apply (5.4) with `{:failed, :script_rejected,
detail, record}` and `phase: "rejected"`.

1. **Kill switch.** `Scripts.Runtime.prepare_run/3` first calls `Policy.kill_switch_on?(prefix)`;
   true -> detail `scripts_disabled`.
2. **Version.** Load `script_rules` by `(script_key, script_version)`: absent/draft/discarded ->
   `script_unavailable`; `revoked` -> `script_revoked`; `sha256 != script_sha256` or `hook_kind !=
   "service_task"` -> `pin_mismatch`; `published` and `retired` run (D1, T13).
3. **Reads and restricted opt-in.** 7c-1: non-empty `reads`, non-empty `restricted_inputs` ->
   `reads_not_allowed` / `restricted_opt_in_unsupported` (backstops of 4.5). 7c-2: section 11.
4. **Secret.** `HmacSecret.hmac_fun(tenant_id)` (tenant id from
   `TenantProvisioning.tenant_id_for_schema_name(prefix)`): `{:error, :missing}` ->
   `hmac_secret_missing` + `Alerts.notify_script_hmac_secret_missing(prefix)` (section 7.3);
   `{:ok, fun}` -> `Alerts.clear_script_hmac_secret_missing(prefix)` (re-arm, no-op when armed).
   `prepare_run/3` returns `{:ok, run_spec} | {:rejected, detail}` with `run_spec :: %{source,
   manifest, limits: %{instructions, timeout_ms, heap_words}, fail_codes, reads, restricted_allowed?,
   hmac_fun, principal}`.
5. **Input.** Read the instance projection's `variables` (unlocked `Repo.get`). `ScriptInput.build(
   variables, manifest, reads_result) :: {:ok, input} | {:error, :input_invalid}`: input = the
   variables whose keys are in `manifest["input_schema"]["properties"]` (no undeclared variable
   enters, field-minimal), plus `"reads" => reads_result` when reads are declared (7c-2); validated
   with `JsonSchema.validate(input, input_schema) == []`. Invalid -> `script_rejected` /
   `input_invalid`.
6. **HMAC.** `{key_version, hex} = run_spec.hmac_fun.(ScriptInput.canonical(input, ctx))` where
   `ctx = %{"instance_id", "node_id", "token_id", "now" (ISO-8601 of event_time)}` and canonical =
   `Canonicaliser.canonicalize_content("application/json", Jason.encode!(%{"ctx" => ctx, "input" =>
   input}))` (C14).
7. **Run.** `t0 = System.monotonic_time()`; `runner.run(source, input, tenant: prefix, ctx: %{
   instance_id, node_id, token_id, now: event_time}, fail_codes: manifest["fail_codes"],
   instructions:, timeout_ms:, heap_words:)` called FROM THE POLLER PROCESS (the watchdog monitors it;
   the slot holder is the watchdog, D8/F-E). `duration_us` measured around the call for every
   outcome; `instructions_used`, `heap_words`, `input_dropped` from `stats` on success, NULL
   otherwise.
8. **Output check** (pure, `Scripts.Runtime.check_output(output, manifest) :: :ok | {:error,
   detail}`): not a map -> `output_not_object`; any top-level key starting with `"$"` ->
   `writes_not_allowed` (C11); `JsonSchema.validate(output, output_schema) != []` ->
   `output_schema`. Each -> `output_invalid` with that detail.
9. **Result.** `{:ok, output, record}` | `{:failed, code, detail, record}` | `{:busy, record}`
   (runner `script_busy`). Runner error codes map 1:1 (`output_invalid` from the decoder -> detail
   `output_decode`; `script_failed` -> `fail_code` = the validated fail code, `details` dropped).
10. **Apply** (5.4) or **reschedule** (5.5).

### 5.4 Apply (transaction B, `Letflow.Engine.apply_script_task_result/3`)

```
@spec apply_script_task_result(claim, result, prefix :: String.t()) ::
        {:ok, :applied | :failed | :cancelled | :stale} | {:error, term()}
claim  :: %{dispatch_id, instance_id, node_id, attempt}
result :: {:ok, output :: map(), run_record()} | {:failed, code(), detail() | nil, run_record()}
```

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

HTTP regression guard: every existing `advance_after_service_task_outcome/4` test stays green and
the generalisation is a pure refactor for HTTP (no change to merge validations, event, keys or row
handling).

### 5.5 Busy reschedule

`ScriptTaskDispatcher.reschedule_busy(claim, prefix)`: one transaction, same CAS predicate; if
`busy_retries < busy_retry_limit`: `status = 'pending'`, `busy_retries + 1`, `next_attempt_at = now
+ busy_backoff_ms(busy_retries)`, `lease_expires_at = NULL`, `updated_at`; no event. Else it calls
apply with `{:failed, :script_busy, :busy_retries_exhausted, record}` (`phase: "ran"`). Stale -> no-op.

### 5.6 Lease sweep, cancellation, detail codes

* Sweep (start of every tenant's poll): up to `sweep_limit` ids with `status = 'running' AND
  lease_expires_at < now` (unlocked select), then per id `apply_script_task_result` with the row's
  own `attempt` and `{:failed, :timeout, :lease_expired, record}` (`phase: "lease_expired"`, HMAC and
  stats NULL). The CAS makes a concurrent live apply and the sweep mutually exclusive. Never
  re-pends.
* `Engine.cancel_instance`: after `cancel_pending_dispatches/4`, `ScriptTaskDispatcher.
  cancel_open_dispatches/4` sets `pending` AND `running` rows of the instance to `cancelled`
  (`finished_at`, `outcome_detail = "instance_cancelled"`) in the same transaction; a running script
  finishes in its sandbox and its apply is `:stale`.
* Closed detail-code list (`outcome_detail`, run record `detail`, incident `details.detail`):
  `scripts_disabled, reads_not_allowed, script_unavailable, script_revoked, pin_mismatch,
  restricted_opt_in_unsupported, hmac_secret_missing, input_invalid, output_decode,
  output_not_object, writes_not_allowed, output_schema, variable_schema_rejected,
  busy_retries_exhausted, lease_expired, apply_failed, no_matching_gateway_edge, instance_not_active,
  instance_cancelled`. Runner outcomes `script_error, budget_exceeded, memory_limit_exceeded,
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

Replay never re-executes a script (D5, MUST 11): `reconstruction.ex` and everything it calls name
neither `ScriptRunner`, `ScriptTaskDispatcher` nor `Letflow.Scripts` (source-scan test), and a
runtime test proves it (15, T-R).

## 7. Per-run record, HMAC secret, alert (7c-1)

### 7.1 `SCRIPT_RUN_RECORDED` payload (exact key set; built by `ScriptTaskDispatcher.RunRecord.build/...`, an allowlist constructor)

`dispatch_id, node_id, attempt, script_key, script_version, script_sha256, phase ("rejected" |
"ran" | "lease_expired"), outcome ("ok" | eight codes), detail (code | null), fail_code (manifest
code | null), input_hmac (64 hex | null), input_hmac_key_version (integer | null), duration_us
(integer | null), instructions_used (integer | null), heap_words (integer | null), input_dropped
(integer | null), principal ("script:<key>@<version>"), triggering_user_id (uuid string | null)`.

It holds NO input value, NO output value, NO fail `details`, NO print buffer, NO source; the
`script_task_dispatches` row's columns are equally value-free (3.1). Logs on every path carry only
dispatch id, tenant schema, outcome and detail codes.

### 7.2 HMAC (`Letflow.Scripts.HmacSecret`, changed)

`hmac_fun(tenant_id :: Ecto.UUID.t()) :: {:ok, (binary() -> {key_version :: pos_integer(), hex ::
String.t()})} | {:error, :missing}`: looks up the tenant slug, `Secrets.resolve("sec://tenant/<slug>/
platform/script-input-hmac", tenant_id: tenant_id, consumer: :script_runner, platform: true)`
(unpinned = newest active); any error -> `{:error, :missing}`. The returned closure computes
`:crypto.mac(:hmac, :sha256, key, bytes)` lowercase hex and returns `key_id` from the resolve
result. NEVER calls `ensure/1` or `Secrets.put`; still the ONLY `platform: true` caller.

### 7.3 Missing-secret alert (`Letflow.Obs.Alerts`, changed)

`notify_script_hmac_secret_missing(prefix) :: :ok` and `clear_script_hmac_secret_missing(prefix) ::
:ok`, edge-triggered through `alert_trigger_state` key `"script_hmac_secret_missing"`: ARMED -> one
`Logger.error("script HMAC secret missing", component: "script_task", tenant_schema: prefix,
trigger: "script_hmac_secret_missing")`, hooks fired when `alert_hooks` is enabled (payload `{"trigger",
"tenant_schema"}`), state FIRED; FIRED -> nothing. `clear_` re-arms. Never raises. The trigger set
grows from four to five (closed-set change, section 17).

## 8. Outputs (7c-1)

### 8.1 Variables only

The only effect of a successful run is `VariableMerge.merge/3` into the instance's variables, with
real validations from the definition's variable schema (D2, this route only; HTTP unchanged,
Deviation 2), inside the apply transaction (5.4). No entity, no other instance, no event other than
the two of section 6, no audit-chain entry.

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
INSERT, UPDATE, DELETE and TRUNCATE on `lua_script_execution_audit` refused (`pg_code == "LF001"`);
a pre-existing row (inserted in the test before the migration's trigger, or by disabling the
trigger inside the test transaction) stays readable through `AuditRecord`; a source scan finds no
`lua_script_execution_audit` writer in `lib/`. `Lua.Executor`'s own tests stay green.

## 11. Pre-fetch port and reads (7c-2)

### 11.1 Port (engine-defined)

`Letflow.Engine.ScriptReadPort` (`lib/letflow/engine/script_read_port.ex`), a behaviour:

```
@callback prefetch(prefix :: String.t(), reads :: [read_spec()], input_vars :: map(),
                   opts :: %{restricted_allowed?: boolean()}) ::
            {:ok, %{optional(String.t()) => [row()]}} | {:error, :reads_not_allowed}
read_spec :: %{"name", "entity_type", "match" => %{"id_from"} | %{"field", "value_from"},
               "fields" => [String.t()], optional("restricted_fields") => [String.t()], optional("limit") => 1..50}
row       :: %{required("id") => String.t(), optional(String.t()) => json_value()}
```

The dispatcher resolves the implementation with `Application.fetch_env!(:letflow,
:script_read_port)` (set in `config/config.exs` to `Letflow.Entities.ScriptReads`; tests may set a
recording stub), so no engine file names an Entities module. Called only when the manifest's `reads`
is non-empty, after 5.3 steps 1-4 and `check_reads` (11.3), before admission.

### 11.2 Implementation `Letflow.Entities.ScriptReads` (`lib/letflow/entities/script_reads.ex`)

Phase 1, for EVERY read, before any record query:
1. `entity_type` has an active definition (`get_active_definition_by_name/2`) and no
   `entity_type_restrictions` row; every name in `fields`, `restricted_fields`, `match.field` is a
   field of that definition. Else `{:error, :reads_not_allowed}`.
2. `R` = the type's CURRENT restricted field names: `entity_field_restrictions WHERE entity_type =
   $1` (bound), with NO per-user grant anti-join (the script principal has no user, D5).
3. **N1:** `match.field in R` and (`match.field not in restricted_fields` or not
   `restricted_allowed?`) -> `{:error, :reads_not_allowed}` (the filter can never become an oracle).

Phase 2, exactly ONE query per read (INV-5, same round trips for hit, miss, malformed and unknown):
* `id_from`: value = `input_vars[id_from]`; a non-UUID or nil value is replaced by the nil UUID
  (never generated as a record id); `Record.Latest` by `(entity_type, record_id)` with `deleted =
  false`; at most 1 row.
* `field`/`value_from`: `Query.Compiler.compile(%{entity_type, filters: [%{field, op: :eq, value}]},
  prefix)` (allowlist + bound parameters), plus `deleted = false`, `order_by record_id`, `limit
  min(limit, 50)`; a nil/non-scalar value issues the same query with a constant-false predicate;
  a compile error -> `{:error, :reads_not_allowed}` (deterministic, type/field level).

Projection per row: `"id"` = record id; for each `f` in `fields`: included iff present in
`field_values` AND (`f not in R` OR (`f in restricted_fields` AND `restricted_allowed?`)); otherwise
OMITTED (absent = same as never set; no sentinel). Misses, deleted, unknown ids and redacted rows
are indistinguishable from "not set" (D5 read contract). The tenant prefix comes only from the
caller's run context; no table or schema name is ever built from manifest text. No ETS, no
persistent_term, no process-dictionary state survives a call (no caching across runs).

### 11.3 Run-time policy re-checks (dispatcher, 5.3 step 3 in 7c-2)

1. `Policy.check_reads(prefix, manifest)` -> `{:error, :reads_not_allowed}` -> `script_rejected` /
   `reads_not_allowed` (7b-2a section 8 item 2).
2. `restricted_allowed?` = publisher re-check (7b-2a section 8 item 3): `Identity.get_user(
   publisher_id, prefix:)` is active AND `Authorization.has_permission_in_scope?(effective_roles(
   Identity.list_effective_role_names(publisher_id, prefix:), platform_tenant?),
   :EntitiesRestrictionsManage, platform_tenant?)`; computed per run in `Scripts.Runtime.prepare_run/3`.
3. C10 still refuses restricted opt-in at activation; 2 is the backstop and the gate for N1.
4. Port `{:error, :reads_not_allowed}` -> `script_rejected` / `reads_not_allowed`; no partial input.

### 11.4 Boundary rule (`mix letflow.check_boundaries`, Rule 6)

A declarative table `@layer_rules [{source_prefixes: ["lib/letflow/engine.ex",
"lib/letflow/engine/"], forbidden_target_prefixes: ["lib/letflow/entities.ex",
"lib/letflow/entities/"], reason: "engine -> entities only via Letflow.Engine.ScriptReadPort (0053
F10)"}]`, evaluated in `classify_edge/2` BEFORE Rule 0. Today the rule holds (0.9). Unit tests feed
synthetic edges; the real task run is part of `mix letflow.check`.

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

Second fixture `purchase_request_writes_attempt` v1 (C11 test): input `{attempt_write: boolean,
amount_cents: integer}`, output_schema `{"type": "object"}`; returns `{total_cents = amount}` and,
only when `attempt_write` is true, also `["$writes"] = {{entity_type = "purchase_order", command =
"create"}}`. Its stored test uses `attempt_write: false` so it publishes; a run with `true` is
refused `output_invalid` / `writes_not_allowed`.

## 13. Changed and new modules (summary)

| Module | Part | Change |
|---|---|---|
| `Engine.ServiceTask` | 7c-1 | `:script` route, config fields, parse errors (4.1) |
| `Definitions.Graph` | 7c-1 | CHK-10 widened, CHK-10s (4.2) |
| `Engine.PinResolver`, `Engine.PinRebind` (test only) | 7c-1 | `:script` kind (4.3) |
| `Letflow.Engine` | 7c-1 | pin lookup, arm branch, binding error handling, cancel step, `apply_script_task_result/3`, generalised advance pipeline (4.4, 5.4, 5.6) |
| `Engine.ScriptTaskDispatcher` (+ `.ScriptTaskDispatch`, `.RunRecord`, `.Poller`), `Engine.ScriptInput` | 7c-1 new | section 5 |
| `Engine.Reconstruction` | 7c-1 | two clauses (6) |
| `Scripts.Runtime` | 7c-1 new | `pin_lookup/1`, `check_bindings/2`, `referenced_by_active_definition?/3`, `prepare_run/3`, `check_output/2` |
| `Scripts`, `Scripts.Validation`, `Scripts.HmacSecret` | 7c-1 | retire block, `check_output` in tests/dry-run, `$` names, `hmac_fun/1` |
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
* **AC3** Retire of a version bound by an active definition -> 409 `version_in_use`, nothing written
  or audited; after the definition is deprecated, retire succeeds; revoke is never blocked.
* **AC4** INSTANCE_STARTED carries the `:script` pin `(key, version, sha256, resolved_id)`; after
  version 2 is published and a new definition version binds it, the in-flight instance still runs
  version 1 (its run record shows version 1 and sha1). A retired version cannot be newly pinned
  (start refused `unresolved_script_ref`); a revoked pinned version fails closed (`script_rejected` /
  `script_revoked`). `PinRebind` refuses kind `script`; a sub-process child neither inherits nor loses
  a script pin.
* **AC5** A due row is claimed (`running`, attempt 1, lease = `lease_ms()` from claim), the run holds
  no transaction, and the result is applied in ONE transaction: variables merged with real
  validations, `SCRIPT_TASK_COMPLETED` + `SCRIPT_RUN_RECORDED` appended, row `applied`, token advanced.
* **AC6 (F-E)** The apply is a CAS on `(id, instance_id, node_id, attempt, status 'running')`: a
  second apply of the same result, an apply with an older attempt, and an apply after the lease sweep
  each return `:stale` and change nothing (events, variables, row, DLQ counts unchanged).
* **AC7 (F-E)** Killing the poller (dispatcher) mid-run kills the worker and releases the
  `ScriptAdmission` slot (slot count back to 0); killing the watchdog does the same; the row stays
  `running` until its lease expires, then the sweep makes it a `timeout` / `lease_expired` incident
  (ERROR + DLQ) and the script is NOT run again.
* **AC8** Only `script_busy` is retried: with all admission slots held the row returns to `pending`
  with `next_attempt_at = now + 500 ms`, `busy_retries 1`, no event; after release it is applied on a
  later claim (attempt 2). After `busy_retry_limit` reschedules the next busy outcome is a
  `script_busy` / `busy_retries_exhausted` incident. Each of `script_error`, `budget_exceeded`,
  `memory_limit_exceeded`, `timeout`, `script_failed`, `output_invalid`, `script_rejected` ends the
  row `failed` after exactly one run, with an incident, and is never re-claimed.
* **AC9** Output failing the manifest output schema -> `output_invalid` / `output_schema`, instance
  ERROR, DLQ incident; output rejected by the definition's variable schema -> `output_invalid` /
  `variable_schema_rejected`, variables unchanged; a list output -> `output_not_object`.
* **AC10 (fence)** An output with a top-level `$` key (the `$writes` fixture) -> `output_invalid` /
  `writes_not_allowed`, no variable and no entity changed (entity table row counts unchanged); a
  stored test and a dry-run returning `$writes` report `output_invalid`; an `output_schema` property
  named `$x` is refused at save (422 `invalid_manifest`).
* **AC11** Kill switch ON (tenant latch, and separately the platform latch): the claimed row fails
  closed `script_rejected` / `scripts_disabled` with an incident; the runner seam is never called and
  no admission slot is acquired; it is not retried.
* **AC12** The per-run record has EXACTLY the section 7.1 key set; for a run whose variables and
  output contain unique sentinel strings, neither the `SCRIPT_RUN_RECORDED` payload, nor the
  dispatch row, nor any captured log line contains a sentinel; `input_hmac` equals HMAC-SHA256 under
  the tenant key of the canonical document and `input_hmac_key_version` equals the secret's `key_id`;
  `principal` and `triggering_user_id` are set (user for a complete_task-triggered run, NULL for a
  timer-triggered one).
* **AC13** A run finds the HMAC secret already present and creates none (secret row count and ids
  unchanged). With the secret missing (disabled), the run fails `script_rejected` /
  `hmac_secret_missing`, no secret is created, and exactly ONE alert/log line is emitted across two
  failing runs; after the secret is restored a successful run re-arms the trigger.
* **AC14** HMAC backfill re-run: a second `backfill/1` over N tenants returns `{0, N, []}` and every
  secret row (id, key_id, ciphertext, status) is unchanged.
* **AC15** Replay: `Reconstruction.reconstruct_instance/2` of a script instance reproduces the
  projection's variables and nodes with the kill switch ON and the version revoked, and the runner
  seam records zero calls; a source scan shows the replay path names no script runner module.
* **AC16** `LuaScriptAudit`: no writer function, DB refuses INSERT/UPDATE/DELETE/TRUNCATE, history
  readable (section 10).
* **AC17** Both event types are registered for a newly provisioned tenant and, after
  `replay_migrations/1`, for a tenant provisioned before the change; both migrations replay
  idempotently.
* **AC18** Instance cancel sets `pending` and `running` script rows `cancelled`; a later apply for the
  running one is `:stale`.
* **AC19** No tenant route can register a WASM plugin (source scan over `lib/letflow/routers/` and
  `lib/letflow/plugs/`: no reference to `PluginRegistry.register_plugin_handler`,
  `Wasm.ModuleRegistry.register` or `ModuleVersionRegistry.register_version`).
* **AC20** The worked example publishes (all six stored cases pass) and, run end to end through the
  poller pipeline, sets the four output variables and routes by `approval_tier`.
* **AC21** No regression: every existing HTTP SERVICE_TASK, dispatcher, pin, activation and
  Lua/Executor test passes unchanged except the two LuaScriptAudit files replaced per section 10.

### 7c-2

* **AC22** `mix letflow.check_boundaries` fails on a synthetic `lib/letflow/engine/x.ex ->
  lib/letflow/entities/y.ex` edge and passes on the real graph; no engine file names
  `Letflow.Entities`; the port implementation is selected only through `:script_read_port`.
* **AC23** A run of a version declaring reads of a flagged master gets `input["reads"][name]` rows
  with `id` plus the declared fields; by-id miss, deleted record, malformed id and unknown id all
  yield `[]` with exactly one entity query each (Ecto telemetry count); a field match is capped at
  its `limit`.
* **AC24** Each 7b-2a section 8 item-2 cause at run time (flag cleared, definition inactive, type
  restricted, field removed, `match.field` restricted and not opted in) fails closed
  `script_rejected` / `reads_not_allowed` before any record query.
* **AC25** A restriction added after activation on a field in `fields` (not opted in) is omitted
  from the delivered row on the NEXT run (no caching); removing it restores the field on the run
  after.
* **AC26 (N1)** With a `restricted_fields` read (version inserted directly, bypassing C10's
  activation refusal) and a publisher who lost `:EntitiesRestrictionsManage` (or was deactivated),
  a restricted `match.field` fails closed before any record query and restricted fields are omitted.
* **AC27** Kill switch ON with declared reads: zero port calls (recording stub).
* **AC28** A cross-tenant read is impossible: the port's queries carry only the run's prefix; a
  manifest naming another tenant's type behaves as an unknown type (`reads_not_allowed`).

## 15. Test brief (TEST-DESIGNER)

Suites (new unless noted): `test/letflow/engine/script_task_dispatcher_test.exs`,
`test/letflow/engine/script_task_apply_test.exs`, `test/letflow/engine/script_task_replay_test.exs`,
`test/letflow/engine/pin_resolver_script_test.exs`, `test/letflow/scripts/runtime_test.exs`,
`test/letflow/scripts/purchase_request_example_test.exs`, `test/letflow/engine/lua_script_audit_retired_test.exs`,
extend `test/letflow/scripts/hmac_secret_test.exs`, `test/letflow/definitions/*activate*` and graph
tests, `test/letflow/routers/script_rules_test.exs` (retire 409, dry-run `$`),
`test/mix/tasks/letflow.check_boundaries_test.exs` (7c-2), `test/letflow/entities/script_reads_test.exs` (7c-2).

Rules: tests call `ScriptTaskDispatcher.poll_and_dispatch/1` / `run_claimed/2` directly (the
poller is off in test); the runner seam (`:script_task_runner` with `:scripts_test_hooks`) is used
ONLY for call-count assertions (AC11, AC15) and never to fake outcomes that the real runner can
produce; real scripts drive every outcome (busy: hold all `ScriptAdmission` slots from helper
processes; memory: the 7a refc fixture; timeout: `pcall` busy loop with `timeout_ms: 100` in the
manifest). Lease expiry is simulated by back-dating `lease_expires_at` (no sleeps on the lease).
Kill tests (AC7) run the pipeline in a spawned process standing in for the poller, kill it, and
poll `Admission` state until the slot count is 0 with a bounded wait (anti-pattern 4709: no timer
shorter than load jitter; use a monitor plus `assert_receive` with a generous timeout). Sentinel
assertions (AC12) use `ExUnit.CaptureLog` over the whole pipeline, including a forced failure. Query
counts use Ecto telemetry handlers scoped to the test pid. Every test that creates tenants cleans up
per the pooled-fixture rules (anti-pattern 4680).

Named tests: T-CAS-dup, T-CAS-old-attempt, T-CAS-after-sweep (AC6); T-kill-dispatcher,
T-kill-watchdog (AC7); T-busy-reschedule, T-busy-exhausted, T-terminal-<code> x7 (AC8); T-R replay
(AC15); T-secret-present-none-created, T-secret-missing-one-alert (AC13); T-backfill-rerun (AC14);
T-writes-refused (AC10).

## 16. Security mapping (INV)

* **INV-1** The tenant prefix comes only from the provisioned `Registration` list in the poller;
  every query (dispatch rows, `script_rules`, policy, projection, events, port) uses that prefix; the
  HMAC key is resolved by the tenant id derived from the prefix and `Secrets.resolve/2`'s own
  slug-to-id match. The port never accepts a prefix or type from anywhere but the run context and
  the validated manifest.
* **INV-2** Outputs land only in the instance's variables (8.1); run record and dispatch row are
  value-free allowlists (7.1); restricted fields are omitted unless opted in, opt-in is refused at
  activation for hook 1 (C10), and run-time re-checks re-redact (11.2-11.3).
* **INV-3** Every execution goes through 7a's sandbox, limits, watchdog and admission; the kill
  switch and `revoked` stop runs before admission; no new host function; replay never executes.
* **INV-4** The HMAC key is resolved by reference through the reserved namespace, kept in a closure,
  never logged, returned or stored; only `key_id` is recorded; it is never created on the run path.
* **INV-5** Port misses, deleted, malformed and unknown ids and redacted rows are indistinguishable
  and cost one query each; activation refusal codes are tenant-local (a tenant sees only its own
  registry).
* **INV-6** New data-access paths: `script_task_dispatches` (tenant schema, no route), the port
  (tenant schema, flagged masters only), the retire reference query (tenant schema). This section is
  the scoping statement.
* **INV-7** All queries are Ecto with bound parameters, including the jsonb containment document and
  the field-match compile; migrations interpolate only `prefix()`.
* **INV-8** Every failure maps to one of the eight codes plus a closed detail code; the poller never
  raises; incidents carry fixed sentences; no `inspect`/`Exception.format` of run data on any surface.
* **INV-10** No platform authority is used; the platform kill-switch latch is honoured through
  `kill_switch_on?/1`.

## 17. Closed-set changes needing REVIEWER sign-off

1. Instance event types `SCRIPT_TASK_COMPLETED` and `SCRIPT_RUN_RECORDED` (seed list, 6).
2. Pin kind `:script` with the extra `sha256` field; excluded from overrides, rebind and inheritance (C7).
3. Route kind `:script` and config parse errors (4.1); graph CHK-10 widening and CHK-10s (4.2).
4. New dependency edges: engine -> `Letflow.Scripts.Runtime` (facade, C18); `Letflow.Definitions` ->
   `Letflow.Scripts.Runtime`; engine -> entities ONLY via `ScriptReadPort` (7c-2) with
   `check_boundaries` Rule 6 enforcing it.
5. A fifth alert trigger `script_hmac_secret_missing` (7.3).
6. A new gated poller child under `Letflow.Supervisor.Pollers` (C2).
7. `error_type :script_task_failed` and `:script_task_pin_unresolved` (open atom set, listed for visibility).
8. Removal of `LuaScriptAudit.execute_script_for_audit/6` (C17).

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
* **R4** One poller per node runs scripts sequentially (<= 16 per tenant per tick): throughput, not
  safety; HTTP dispatch is unaffected.
* **R5** An attempt whose instance is no longer active at apply leaves its trace only on the dispatch
  row (append refuses terminal instances).
* **R6** Pre-existing: HTTP `SERVICE_TASK_COMPLETED` has no replay clause, so replay of an instance
  that ran an HTTP service task fails `unrecognized_event_type`; not introduced or fixed here
  (scope fence); ORCH should file it.
* **R7** `math.floor`/`#` behaviour of lua 1.0.2 used by the fixture is proved by its stored tests,
  not by a separate spike (12).
* **R8** The triggering-user value depends on each hop site's existing actor; sites without one store
  NULL (4.4).

## 20. Open questions

None blocking. Items marked NOT VERIFIED above (R7, the exact actor value at each hop site) are
settled by ELIXIR-DEV's tests, not by assumption.
