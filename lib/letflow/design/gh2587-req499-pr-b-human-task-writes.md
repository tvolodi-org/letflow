# GH #2587 / REQ-499 PR B: HUMAN_TASK path of process-step entity writes (decision 0054)

Author: CODE-DESIGNER, 2026-10-15. Branch `design/GH-2587-pr-b`, from `origin/main` `26e6cdbd`
("feat(GH #2623): refuse _sys references in catalog endpoint_url", #2637). Scope: issue #2587
"Group B: HUMAN_TASK path" plus the PR A carry-overs (parent design
`gh2587-req499-pr-a-prerequisites.md` sections 14-16), #2621 (`gh2621-sys-value-types.md`
section 9, hard PR B constraints), #2623 and #2633. Group C (SERVICE_TASK) is PR C and is NOT
designed here beyond the fail-closed fences B needs.

Design only. Signatures, type shapes, step lists, tables and test briefs; no function bodies.

## Changelog

### Revision 1 (2026-10-15): CDV FAIL (6 blockers) and supervisor rulings applied

| Id | Change | Where |
|---|---|---|
| CDV-1 | F-2 harm restated: orphan records plus an ERROR instance; a retry gets `{:instance_not_active, :error}` (409), NOT `idempotency_conflict`; test B-2 replaced | 3 F-2, 11.1 B-2 |
| CDV-2 | Lock inventory gains the sub-process completion cascade (child tasks -> child projection -> type sequence, then parent token -> parent projection) vs a parallel-branch parent completion: a real `40P01` cycle; outcome stated; B-3 case added | 7.2, 9, 11.1 B-3 |
| CDV-3 | Activator status: absent user row fails closed; reader `Letflow.Identity.get_user/2` (`identity.ex:353`); `check_boundaries` has no engine -> identity rule; stub recovery path (cancel, or rollback re-activation) and a cancel test; real status deferred | 7.3, 11.1 B-13, 16 |
| CDV-4 | Fail-closed "lines but no plan" guard lives in the existing `:completion_guards` step as a pure branch (no extra step) | 4 D-B.3 |
| CDV-5 | B1 test seam: app-env flag `:entity_writes_execution_enabled` (default off) read by `validate_lines/2`; named B1 tests flip it; B2 deletes it | 4 D-B.6, 11.1 B-1 |
| CDV-6 | D4a.3 completer-scope: `Tasks.authorize_completion/3` is the existing authorization; scope ceilings vacuous before 0051; non-assignee test B-18 | 4 D-B.23, 11.1 |
| CDV-7..16 | Scope-predicate seam named; `activated_by` forge invariant and test B-19; step names and tuple/atom routing (D-B.25); INV labelling; `Activator` takes `platform_tenant?`; line drift; ONE refusal envelope; create defaults; ambiguous-commit retry (B-17); Lua row; OQ-B4 asymmetry | 4, 5, 8, 9, 10, 11, 12 |
| Rulings | OQ-B1..OQ-B6 closed per supervisor | 15 |

### Revision 0 (2026-10-15): first design

First version. Written against `main` `26e6cdbd`; every file:line below was re-read on that
tree (section 2). Eleven findings (section 3) change or sharpen the issue text; the questions that
were ruled by the supervisor (section 15, OQ-B1..OQ-B6, all closed).

## 1. Summary, sizing and proposed split

### 1.1 What PR B delivers

A HUMAN_TASK node may declare `entity_writes`: up to 20 `create` lines on `writable_by_process`,
append-only, non-managed entity types. Activation validates them (`validate_lines/2`, real). A
completion with lines runs, in the SAME Postgres transaction as the task completion: SET LOCAL
timeouts, the lines (through `Records.command_multi/3`, authority `:tenant`), the engine-only
`_sys.*` output variables, one `INSTANCE_SYS_VARIABLES_SET` and one `TASK_ENTITY_WRITES_APPLIED`
instance event, and one tenant audit entry per line. Any refusal rolls everything back; the task
stays `pending`.

### 1.2 Size: cannot be built and reviewed in one agent turn

Touch count (section 13): 3 activation paths plus 4 routers plus `activate/2` option plumbing and
a tenant migration (B1); `engine.ex` pre-transaction phase, Multi composition, tail, error union,
snapshot and result fold plus `StepWrites.multi/3` plus a `records.ex` contract edit and about 12
new test files (B2); 5 router edits plus an `Instances` query filter (B3). Two of the surfaces
(the completion transaction and the activation authority) are each independently
security-reviewable. Recorded reason for the split (core-directives "Merge Discipline" item 1):
three surfaces with different gates, each a coherent review unit; one diff would exceed one turn.

### 1.3 Proposed split, serial, merge order B3 -> B1 -> B2

| PR | Name | Contents | Independent value | Depends on | Gate before merge |
|---|---|---|---|---|---|
| **B3** | API gating | Strip engine-written `_sys.*` values from instance reads, reconstruct, task-completion response and instance history; hide the two engine event types from history/timeline (CO-1); static test that every `"variables"` response key goes through the one helper | Closes the INV-2 exposure BEFORE any `_sys` value exists; zero behaviour change today (no `_sys` key is written yet) | none | SECURITY-REVIEWER |
| **B1** | Validation and activation | Real `validate_lines/2`; `entity_writes` structural parse; the three activation call sites; `activated_by` column, option plumbing and recording; fail-closed fences (SERVICE_TASK refused, execution gate); CO-3, CO-5, CO-6 | Closes today's hole: ANY `entity_writes` attribute is silently ignored by activation and execution; after B1 a definition carrying one is either validated-and-refused (gate) or refused for a reason | B3 not required; merge after it | SECURITY-REVIEWER, REVIEWER |
| **B2** | Completion-transaction composition | Everything in section 7: pre-transaction plan, `prepare/2` with the writable filter, SET LOCAL, `StepWrites.multi/3`, `:entity_writes` step, tail (`_sys`, two events, audit), contention rescue, error union, router mapping, execution gate removed; CO-2, CO-4, CO-7, CO-9, CO-10 | The feature | B1, B3 merged; CO-8 gate satisfied | SECURITY-REVIEWER, REVIEWER (engine -> entities edge, EE-12 sentence 5 reword) |

Cut line if ELIXIR-DEV's estimate says B1 is still over one turn: **B1a** = `activated_by`
(migration, option plumbing at the three paths, `Activator` builder, router wiring, the
`:entity_write_activator_required` refusal); **B1b** = `validate_lines/2` and the call sites. B1a
has no completion-path effect; B1b needs B1a only for the activator violation. Do not cut B2.

Pipeline note: the repo has one functional PR in CI at a time (core-directives "Merge
Discipline" 2). Each PR body states the split reason and cites this design. B3 first because it is
the smallest, is a hard prerequisite of B2's first `_sys` write, and carries no functional risk.

## 2. Sources and verification (all on `main` `26e6cdbd`)

| Fact | Where |
|---|---|
| `complete_task/3` | `engine.ex:2498`; `run_complete_task/6` `:2549`; Multi steps `:task` `:2559`, `:instance_projection` `:2560`, `:snapshot_and_state` `:2563`, `:completion_guards` `:2568`, `:form_expression_reevaluation` `:2575`, `:merge` `:2595`, `:transition` `:2632`, tail `Multi.merge` `:2648` |
| `Repo.transaction()` then `maybe_snapshot_after_complete_task`, `emit_task_completed_telemetry`, `interpret_complete_result`, function-level `rescue exception -> {:error, {:transaction_failed, exception}}` | `engine.ex:2658-2664` |
| `complete_error` union | `engine.ex:2412-2436`; `complete_result` `:2450-2457` |
| `:merge` may return `{:ok, {:execution_error, _}}` (reevaluation error `:2616`; `merge_output_variables/8` `:4732`, reserved-key guard `:4746-4761`, `apply_variable_merge/6` `:4873`) | `engine.ex` |
| `:transition` is a `Multi.run` that returns `{:ok, {:execution_error, _}}` for no matching edge (`:5095-5123`), empty URL, catalog resolution, script binding (`:5081-5090`) and sub-process activation failure (`:5075`); on `{:advanced, state, children, timers, dispatches}` it only PREPARES (reads) | `engine.ex:4998-5128` |
| Tail: execution-error clause `:5327-5340`; advanced clause `:5342-5529` (`:task_complete` `:5483`, task audit `:5493`, `:event` `:5496`, `:projection` `:5505`, `:complete_task_outcome` `:5528`) | `engine.ex` |
| `append_task_completed_event/5` (payload carries `output_variables` only; key = the completion's `idempotency_key`) | `engine.ex:6239-6270` |
| `interpret_complete_result/3` clauses (execution error `:6370`, completed `:6378`, refusals `:6405`, `:6428`, generic 4-tuple catch-all `:6465`; NO clause for a 2-tuple error) | `engine.ex` |
| `maybe_snapshot_after_complete_task/2` reads `changes.transition` final state | `engine.ex:2718-2754` |
| Router completion: `idempotency_key = Ecto.UUID.generate()` per request; `handle_complete_result` catch-all `{:error, _reason}` -> 500 | `routers/tasks.ex:326-327`, `:443-445` |
| `complete_result_map/1` serialises `"variables"` verbatim | `routers/tasks.ex:676-690` |
| `instance_map/1` `"variables"`; `render_reconstruct/2` `"variables"`; `history_item_map/2` `"payload"` verbatim; `timeline_item_map/1` | `routers/instances.ex:850`, `:730`, `:952`, `:988` |
| `Instances.history/3` and `timeline/3` query `events` by `instance_id` only (`filter_by_event_type`, no type exclusion) | `instances.ex:129-152`, `:183-208` |
| `EXECUTION_ERROR` payload carries the full `variables` map | `engine/execution_error.ex:295-318` |
| `Definitions.activate/2` opts: `prefix` and `service_scope_validator` ONLY (no actor); lifecycle audit uses `actor_id: nil` | `definitions.ex:194-197`, `:741-768`, `:1930-1960` |
| Activation `with` chain: `run_semantic_validation` -> `check_reserved_references` -> `check_script_bindings` -> `activate_draft` | `definitions.ex:2318-2349` (`check_reserved_references/1` `:2386`) |
| Rollback activation chain `check_reserved_references` -> `check_script_bindings` (has positional `actor_id`) | `definitions.ex:2660`, `:2728-2729` |
| Router activate: `Definitions.activate(raw_id, scoped_opts + validator)`; `conn.assigns.auth_context` carries `user_id`, `tenant_id`, `roles` | `routers/definitions.ex:940-943`, `plugs/authorize.ex:123` |
| `ProcessDefinition.version` is a `:string`, 1..255 bytes, no `activated_by` / `needs_reactivation` anywhere in `lib`/`priv` | `definitions/process_definition.ex:88`, `:155` |
| `StepWrites.prepare/2` skips a line with no binary `entity_type` and a type with no ACTIVE definition (does NOT test `writable?`); `validate_lines/2` and `multi/3` fail closed (`:entity_writes_not_enabled`) | `entities/step_writes.ex:43-60`, `:88-100`, `:104-110`, `:114-118` |
| `ProcessWritable.writable?/1` (flag true, `managed_by` nil, name not denied) | `entities/process_writable.ex:162` |
| `Records.command_multi/3` (build-time errors are RETURNED, not Multi errors), `interpret_in_multi/1`, `classify_step_error/1`, `step_source` with `definition_version :: pos_integer()`, `step_source_metadata/1` integer guard | `entities/records.ex:256-266`, `:574-609`, `:632-654`, `:763-786` (guard `:773`) |
| Step results: `{:line, i, :insert_event}` is the `%Event{}` (`global_seq` read-after-writes), `{:line, i, :recheck_definition}` is the re-read `EntityDefinition` | `records.ex:589-608`, `:942-945` |
| `Audit.append_multi/4` takes an ATOM step name; `insert_entry/3` locks the tenant `audit_chain_locks` sentinel row `FOR UPDATE` until commit | `audit.ex:182-191`, `:211-247` |
| `FieldGrants.load_restrictions/3` returns the field names restricted AND not granted to the user | `entities/query/field_grants.ex:82-110` |
| `VariableMerge.put_sys/3` strict `{:ok, map} | {:error, _}`; `put_sys_replayed/3`; `check_sys_entry/2`; `drop_reserved/1`; `reserved_keys/1`; `sys_event_type/0` | `engine/variable_merge.ex:340`, `:353`, `:402`, `:467`, `:484`, `:500` |
| `EntityPort` callbacks `prefetch/3`, `prepare/2`, `validate_lines/2`, `multi/3`; `impl/0`; `applied_event_type/0` | `engine/entity_port.ex:59`, `:84`, `:91`, `:95`, `:102`, `:106` |
| `ScopeNodePaths.lock!/1` (SHARE ROW EXCLUSIVE, validated prefix, re-entrant, raises outside a transaction) | `scope_node_paths.ex:129`, `:226` |
| No scoped-type or scope-column declaration exists on a definition document | `grep` of `entities/definition.ex`, `definition/validator.ex`, `managed_types.ex`, `definitions.ex`: none |
| Put_sys caller allow-list `[variable_merge.ex, reconstruction.ex]`; PR B adds `engine.ex` | `test/letflow/engine/put_sys_callers_test.exs:42` |
| Behaviour implementers other than `EntityPortImpl` | `test/support/script_task_fixture.ex:421`, `test/letflow/entities/script_reads_test.exs:430` |
| Tenant column-add precedent (migration + `TenantProvisioning` list entry) | `priv/repo/migrations/20261015000001_add_issuer_user_id_to_api_tokens.exs`, `tenant_provisioning.ex:~690` |
| Hand-seeding helpers to retire (CO-2) | `sys_namespace_sources_test.exs:145` (`hold_engine_values!/3`, `Repo.update_all variables`), `reconstruction_sys_test.exs:98` (`sys_event!/3`) |

### 2.1 Open-point-5 re-verification (0054 open point 5, rule 3a)

Re-read against merged REQ-496: `ScopeNodePaths.lock!/1` exists (`scope_node_paths.ex:129`), takes
`LOCK TABLE ... IN SHARE ROW EXCLUSIVE MODE` on the validated prefix (`:226`, INV-7), is re-entrant
and raises outside a transaction. Rule 3a (lock after the instance sequence row, before every
entity-type lock) is consistent with it. It is NOT exercised in PR B: org-tree types are
`managed_by` (refused) and no scoped-type declaration exists (F-7). The mode for a read-only
scoped-type ceiling check (SHARE vs SHARE ROW EXCLUSIVE) stays undecided until 0051 `scope_node`
exists; recorded as OQ-B6. Per the issue ("the PR may land the rule behind a fail-closed
refusal and state so"), PR B lands NO rule-3a code.

## 3. Findings from verification (each changes or sharpens the issue)

| Id | Finding | Consequence |
|---|---|---|
| **F-1** | `Records.step_source.definition_version` is `pos_integer()` and `step_source_metadata/1` refuses anything else (`records.ex:263`, `:773`), but `ProcessDefinition.version` is a free string up to 255 bytes (`"1"`, `"1.0.0"`, `"v2"`). The A2 contract cannot carry a real definition version. | D-B.9: PR B widens `definition_version` to a 1..255-byte string in `records.ex`; `records_command_multi_test.exs` is edited. |
| **F-2** | 0054 D3 places `:entity_writes` BEFORE `:transition` and AC 13 names only `:merge` execution errors. But `:transition` itself returns `{:ok, {:execution_error, _}}` (no matching edge, empty URL, catalog, script binding, sub-process activation: `engine.ex:5075-5123`); the tail then commits the instance as `:error` and leaves the task `pending` (`engine.ex:5327-5340`). Entity records written before it would COMMIT: orphan records for a completion that never completed, on an instance now in ERROR. The instance projection is `:error`, so any retry gets `{:instance_not_active, :error}` (`engine.ex:2773-2781`, 409): the completion can never succeed and the records stay orphaned. | D-B.2: `:entity_writes` runs AFTER `:transition` (which only prepares, takes no lock) and before the tail, and skips on either execution error. |
| **F-3** | `maybe_snapshot_after_complete_task/2` and `interpret_complete_result/3` read the final state from `changes.transition`. A `_sys` fold done only in the tail would leave the snapshot (taken at the `TASK_COMPLETED` sequence number, AFTER the SYS event) without `_sys` keys, so snapshot-based replay would lose them. | D-B.10: one pure fold of the `_sys` values into `changes.transition` right after the transaction returns, before snapshot, telemetry and interpret; the tail folds the same values for the projection write. |
| **F-4** | `Definitions.activate/2` has no actor input and writes `actor_id: nil` audit rows (`definitions.ex:194`, `:1930`). 0054 D4a needs `activated_by`, the evaluated permissions and the authorised pairs recorded at activation, and `source.activator_id` is required on every line. | D-B.14: new `activator` option on the three activation paths, one nullable jsonb column, refuse-when-absent for graphs with lines. |
| **F-5** | A new `{:error, {:entity_write_refused, _, _}}` result would hit the tasks router catch-all (`routers/tasks.ex:443`, 500) and has NO matching `interpret_complete_result/3` clause (the catch-all expects a 4-tuple). | Explicit clauses in both (section 7.6, 8). |
| **F-6** | Engine-written `_sys` values reach clients on MORE than the three surfaces SEC F2 named: `GET /instances/:id/history` returns `event.payload` verbatim, so `EXECUTION_ERROR.payload.variables`, the `INSTANCE_SYS_VARIABLES_SET` payload and the `TASK_ENTITY_WRITES_APPLIED` payload are readable by any `:InstancesRead` holder. | D-B.16 / CO-1 covers instance read, reconstruct, completion response, history and timeline. |
| **F-7** | No scoped-type or scope-column declaration exists on a definition document (grep, section 2). The 0054 D4b "scoped type refused" and "no value onto a scope column" refusals are therefore vacuous predicates today. | D-B.18: named predicates that return false today and are the single place 0051 plugs in; stated, tested as unit predicates. |
| **F-8** | The completion `idempotency_key` is a random UUID per request (`routers/tasks.ex:326`). The two new instance events need their own deterministic-per-completion keys that cannot collide with `sys:step:` (refused un-namespaced by EventStore) or with client keys. | D-B.22: derive `<completion key>::sys_vars` and `<completion key>::entity_writes` (the `SubProcess.derive_idempotency_key/3` join convention, `sub_process.ex:274`). |
| **F-9** | The engine cannot call `Records.interpret_in_multi/1` (engine -> entities is forbidden) and `StepWrites` adds step names of its own. | D-B.8: one new port callback `interpret_failure/2`; the two behaviour fixtures gain a delegate (else a missing-callback warning). |
| **F-10** | `command_multi/3` returns `{:error, reason}` at BUILD time, outside any Multi, and a line's field values depend on the merge outcome that exists only inside the transaction. | D-B.4: lines are built lazily in a `Multi.merge/2` after `:transition`; a build error becomes `Multi.error({:line, i, :build}, reason)`. |
| **F-11** | `Audit.append_multi/4` takes an ATOM step name (`audit.ex:189`); per-line step names are tuples. And every audit insert takes the tenant-wide chain lock until commit (`audit.ex:211-247`). | D-B.13: per-line audit via `Audit.insert_entry/3` inside `Multi.run`, placed in the tail next to the existing task-complete audit so the chain lock is taken at the same point as today. |

## 4. Decisions (one-line rationale each)

* **D-B.1 Three PRs, order B3 -> B1 -> B2.** B3 closes an exposure that has no writer yet and is a prerequisite of B2; B1 closes the activation hole; B2 turns the feature on. (Section 1.3.)
* **D-B.2 `:entity_writes` sits after `:transition` and before the tail `Multi.merge`; it skips when `changes.transition` is `{:execution_error, _}` (which also covers a `:merge` execution error, passed through).** Rationale: F-2. Lock order is unchanged: `:transition` only prepares (reads, no `FOR UPDATE`; ELIXIR-DEV greps `lock(` over the call tree `prepare_timer_arms/4`, `prepare_service_task_dispatch_for_completion/8`, `prepare_sub_process_children_for_completion/8`, `SubProcess.prepare_child_activation/4` and the statement-log test asserts it), so entity locks still precede every tail write. EE-12 sentence 4 ("(5) `:transition` and the tail") is reworded in B2 to "(5) the tail (the `:transition` step only computes)".
* **D-B.3 A read-only pre-transaction plan phase decides "has lines", runs `prepare/2` and never fails the completion by itself.** It reads the task row (unlocked), the instance's `definition_id`, the pinned snapshot graph and the node; any read error yields `:none` so the in-transaction flow produces today's canonical error. Because the snapshot and `task.node_id` are immutable, the in-transaction lines equal the planned lines; when P0 returned `:none` there is no `:entity_writes` step (and the golden Multi-name test forbids an extra step), so the fail-closed check is a pure branch INSIDE the existing `:completion_guards` step (`check_completion_guards/6`, `engine.ex:4823`): it already receives the graph and the task; if the node carries a non-empty `entity_writes` attribute and the completion has no plan, it returns `{:error, {:completion_refused, :entity_writes_not_planned}}`, mapped to `{:entity_write_failed, 0, :not_planned}` (500, nothing committed). A node without lines takes no new branch and behaves as today. Rationale: 0054 D2.3 / D3 step 0 and no new lock edge.
* **D-B.4 Lines are built in a `Multi.merge/2` after `:transition`, from the merge outcome, through closures in the port context.** The engine hands `StepWrites` two closures (`variables`, `skip?`) so Entities never learns engine step names. Rationale: F-10; the fields may name form outputs (D1a.5).
* **D-B.5 Line shape: `op`, `entity_type`, `fields`, optional `output_record_id_var`; field sources are tagged `{"var": name}` or `{"const": value}`.** Tagged so a constant map is never mistaken for a reference. `record` and `expected` are refused on a `create` line. Rationale: 0054 D1/D1a; create-only MVP (ruling, D1a.4).
* **D-B.6 `validate_lines/2` reports ALL violations, sorted `{index, code}`, and a B1-only gate appends `:entity_writes_execution_not_enabled` per line after every real check passes.** The gate is a seam, not a constant: `StepWrites.execution_enabled?/0` reads `Application.get_env(:letflow, :entity_writes_execution_enabled, false)` (default OFF in every environment, never set in `config/*.exs`). B1 tests that need a definition to ACTIVATE (the `activated_by` recording, rollback and promotion re-recording, activator cases) set it true in `setup` and restore it in `on_exit` (`async: false`); the case "valid definition is refused with `:entity_writes_execution_not_enabled`" runs with it off. B2 deletes the function, the env key and that case (execution is then always enabled). Rationale: B1 must ship `record_activator`/`activated_by` code that is testable, while production activation stays refused until B2. Rationale: B1 must not let an activated definition silently ignore lines (no write path until B2).
* **D-B.7 `prepare/2` stays lenient (skips a missing or non-binary type) and gains the `writable?/1` filter; `multi/3` re-normalises every line and refuses a malformed one.** Rationale: #2633 AC 3 option "keep lenient, document it, pin it"; `prepare/2` is not the guard, `validate_lines/2` (activation) and `multi/3` (run time, hand-edited snapshot) are. CO-3 satisfied inside `prepare/2` because the engine cannot name `ProcessWritable`.
* **D-B.8 New port callback `interpret_failure(step, reason)`.** F-9. Returns `{:refused, index, code, detail}`, `{:failed, index, step}` or `:not_a_line_failure`; `detail` is a closed atom for the tenant audit only.
* **D-B.9 `step_source.definition_version` becomes a 1..255-byte string.** F-1; the flat metadata value `source.definition_version` is the string as stored. Edits `records.ex` (type, guard) and `records_command_multi_test.exs`.
* **D-B.10 `_sys` output: strict `put_sys/3` in the engine after the lines, the SYS event BEFORE `TASK_COMPLETED`, the APPLIED event next to it, one pure fold into `changes.transition`.** F-3; D-A1.10; #2621 hard constraint 2 (the SYS event is appended only through `EventStore.append/2`, which traverses `Registry.validate_payload/3`).
* **D-B.11 SET LOCAL timeouts are the FIRST Multi step, only when the plan has lines; a 10 s wall-clock guard step precedes each line; a guard trip is `entity_write_contention` with audit detail `:deadline`.** Rationale: 0054 D3 "Timeouts"; the public code set stays closed (OQ-B3).
* **D-B.12 The contention `try/rescue` wraps exactly the `Repo.transaction()` call and only when the plan has lines; the tagged result skips the post-commit stages through an explicit `interpret_complete_result/3` clause.** 0054 D3; F-5.
* **D-B.13 Audit: one `Audit.insert_entry/3` per applied line, in the tail beside `record_task_complete_audit/4`, after-state without field values.** F-11.
* **D-B.14 Activator authority: nullable jsonb `process_definitions.activated_by`, written at the three activation paths only for graphs that carry lines; `activator` option built by `Activator.from_auth_context/2` (the router passes `platform_tenant?` in); absent or lacking `:EntitiesRecordsWrite` -> refused; a deactivated activator -> refusal-only stub (no new task status).** F-4; 0054 D4a and open point 9 (OQ-B2 on the stub).
* **D-B.15 Write-side field restrictions are checked at build time with the completer as subject.** D4c; create-only so no hidden-field carry-over from a row exists (a create reads no row). A restricted field the line does NOT name is simply absent from `field_values`: the type's own create semantics decide (a required field gives `validation_failed`; otherwise it is stored unset); PR B applies no extra default for it, and 0054 D4c's "carried over from the defaults of a create" is satisfied because the engine adds nothing the subject could not already see.
* **D-B.16 API gating (CO-1): STRIP, do not permission-gate.** No consumer needs engine bookkeeping (A1b ruled no expression, binding or interface may read `_sys`); a new permission would add an INV-10 classification, role-matrix and golden-file change for nothing; reopening later is cheap, closing later is not.
* **D-B.17 One uniform refusal body per code, `Response.entity_write_refused/3`; `write_not_permitted` is byte-identical for every cause.** INV-5, D8.
* **D-B.18 Scoped-type and scope-column refusals are named predicates, vacuously false today.** F-7; they are the single hook for 0051.
* **D-B.19 `%StepSource{}` struct (#2627): PR B does NOT introduce it.** B2 has exactly ONE constructor of a source (the engine-side line builder in `StepWrites`); PR C adds the second (`dispatch_id`), which is when a struct earns its keep. Recommendation: #2627 is picked up as the first commit of PR C (or standalone right after B2), after the shape on `main` is proven. State stays `blocked`.
* **D-B.20 `entity_writes` on a SERVICE_TASK node is refused at activation until PR C** (`:entity_writes_node_type_not_supported`), so a SERVICE_TASK can never carry a line that is silently ignored.
* **D-B.21 `expected` never reaches `Records`:** `command_multi/3` accepts only `:create` and no expectation; a line carrying `expected` is refused at activation and at run time.
* **D-B.23 Completer scope (0054 D4a.3).** The completer-scope check is `Tasks.authorize_completion/3` (`tasks.ex:549`), which the router already runs BEFORE `Engine.complete_task/3` (`routers/tasks.ex:323-335`); a non-assignee never reaches the transaction, so no line is built. The "scope ceiling of the instance" half is vacuous until 0051 `scope_node` (F-7). No new design element beyond test B-18.
* **D-B.24 `activated_by` is written only by the activation set.** The `create_changeset/2` and `update_changeset/2` casts (`process_definition.ex:122`, `:141`) do not list it; the only writer is the activation write of the three paths. Invariant I-B11, test B-19.
* **D-B.25 Step names and failure routing.** Per-line steps are tuples `{:line, i, step}` and route to `interpret_failure/2` (the engine matches the `{:line, _, _}` tuple shape only). Steps with ATOM names stay on the existing generic path: `:entity_write_timeouts`, `:entity_writes_started`, `:entity_writes`, `:sys_variables_event`, `:entity_writes_applied_event`. The per-line audit step is the 2-tuple `{:entity_write_audit, i}` (deliberately NOT `{:line, _, _}`; its failure is an internal 500 through the generic clause). `interpret_failure/2` therefore receives only `{:line, i, step}` names.
* **D-B.22 Instance-event keys:** `<completion idempotency_key>::sys_vars` and `<completion idempotency_key>::entity_writes`. Rationale: F-8.

## 5. Interfaces, specs and shapes (no bodies)

### 5.1 `Letflow.Engine.EntityPort` (`engine/entity_port.ex`)

```
@type line :: %{required(String.t()) => term()}                    # unchanged (string keys, as pinned)
@type line_violation :: %{index: non_neg_integer(), code: atom()}  # unchanged
@type definition_ctx :: %{
        required(:prefix) => String.t(),
        required(:node_id) => String.t(),
        required(:node_type) => :HUMAN_TASK | :SERVICE_TASK,
        optional(:activator) => activator() | nil,
        optional(:graph_output_vars) => [String.t()]      # _sys output vars declared by OTHER nodes (uniqueness)
      }
@type activator :: %{
        required(:user_id) => Ecto.UUID.t(),
        required(:roles) => [String.t()],
        required(:entities_records_write?) => boolean()
      }
@type multi_ctx :: %{
        required(:prefix) => String.t(),
        required(:task_id) => Ecto.UUID.t(),
        required(:instance_id) => Ecto.UUID.t(),
        required(:node_id) => String.t(),
        required(:definition_id) => Ecto.UUID.t(),
        required(:definition_version) => String.t(),          # 1..255 bytes (D-B.9)
        required(:actor_id) => Ecto.UUID.t(),                 # the completer
        required(:activator_id) => Ecto.UUID.t(),
        required(:authorized) => [{String.t(), String.t()}],  # recorded (entity_type, op) pairs
        required(:variables) => (changes :: map() -> map()),  # the merged variables after :merge
        required(:skip?) => (changes :: map() -> boolean()),  # true when transition/merge is an execution error
        optional(:now_fun) => (-> integer())                  # monotonic ms; test seam for the 10 s guard
      }
@type applied_line :: %{
        required(:line_index) => non_neg_integer(),
        required(:entity_type) => String.t(),
        required(:record_id) => Ecto.UUID.t(),
        required(:event_global_seq) => non_neg_integer(),
        optional(:output_var) => String.t() | nil
      }
@type entity_writes_result ::
        :skipped
        | %{required(:applied) => [applied_line()],
            required(:lines_hash) => String.t(),                    # lowercase hex SHA-256
            required(:sys_values) => %{optional(String.t()) => String.t() | non_neg_integer()}}
@type failure ::
        {:refused, index :: non_neg_integer(), code :: refusal_code(), detail :: atom()}
        | {:failed, index :: non_neg_integer(), step :: atom()}
        | :not_a_line_failure
@type refusal_code ::
        :write_not_permitted | :validation_failed | :entity_append_only | :idempotency_conflict
        | :record_version_conflict | :entity_type_inactive | :entity_write_contention

@callback interpret_failure(failed_step :: term(), reason :: term()) :: failure()
```

Contract changes to existing callbacks (moduledoc updated, names unchanged):

* `validate_lines/2` is real (section 6); for a non-empty list it may perform reads; it never writes.
* `multi/3` returns the input Multi with the line steps appended and ENDS with the named step `:entity_writes` whose value is `entity_writes_result()`. The engine reads that one key.
* `prepare/2` doc: "assumes validated lines; skips a line whose `entity_type` is not a binary; skips a type that is not active or not process-writable".

### 5.2 `Letflow.Entities.StepWrites` (`entities/step_writes.ex`)

```
@spec prepare([EntityPort.line()], EntityPort.prepare_ctx()) :: (unchanged union)
@spec validate_lines([EntityPort.line()], EntityPort.definition_ctx()) ::
        :ok | {:error, [EntityPort.line_violation()]}
@spec multi(Ecto.Multi.t(), [EntityPort.line()], EntityPort.multi_ctx()) :: Ecto.Multi.t()
@spec interpret_failure(term(), term()) :: EntityPort.failure()

@spec normalize_line(term()) :: {:ok, normalized_line()} | {:error, line_code()}   # pure, shared by validate and multi
@spec lines_hash([EntityPort.line()]) :: String.t()                                 # canonical, key-sorted JSON, SHA-256 hex
@spec scoped_type?(EntityDefinition.t()) :: boolean()                               # D-B.18, false today
@spec scope_column_field?(EntityDefinition.t(), field :: String.t()) :: boolean()   # D-B.18, false today
@spec execution_enabled?() :: boolean()                                             # B1 gate only; deleted in B2
```

`normalized_line()`: `%{index, entity_type, fields :: %{String.t() => {:var, String.t()} | {:const, term()}}, output_var :: String.t() | nil}`.

Per-line build/run step list inside `multi/3` (declared index `i`, execution order sorted by
`(entity_type, i)`, every name `{:line, i, step}`):

| Order | Step | Reads/locks | Fails with (reason) |
|---|---|---|---|
| 0 (once) | `:entity_writes_started` | monotonic clock | never |
| per line | `{:line, i, :deadline}` | clock | `:deadline_exceeded` |
| per line | `{:line, i, :build}` (error step, only when the build fails) | reads: definition, instance id, restrictions | the `command_multi/3` error, or `:field_restricted`, `:line_not_authorized`, `:line_malformed` |
| per line | the A2 steps: `:active_instance_guard`, `:assign_sequence` (type sequence row `FOR UPDATE`, held to commit), `:idempotency`, `:insert_event`, optional `:store_oversized_payload`, `:update_projection`, `:recheck_definition`, `:upsert_record_latest`, `:dual_write_promoted_columns` | as A2 | as `Records.interpret_in_multi/1` |
| per line | `{:line, i, :process_policy}` | the `:recheck_definition` result row | `:not_writable_by_process`, `:not_append_only`, `:scoped_type` |
| once | `:entity_writes` | none | never (assembles `entity_writes_result()`) |

`:process_policy` sits after the type lock and the recheck (so the flag is read from the same
row the write uses, 0054 D4a.2(c), A-design 15 "run-time recheck reads the `:recheck_definition`
step result"). A refusal there rolls the whole transaction back; nothing committed.

`multi/3` is a `Multi.merge/2` built from the engine's `variables`/`skip?` closures: when
`skip?.(changes)` is true it contributes only `Multi.run(:entity_writes, ... :skipped)`.

### 5.3 `Letflow.Definitions` and routers

```
@type activator_opt :: EntityPort.activator()
@type activate_opts :: [prefix: String.t(), service_scope_validator: ... | nil, activator: activator_opt() | nil]
# rollback_definition_version/4 opts and the promotion apply opts gain the same :activator key.

@type entity_writes_violation :: %{node_id: String.t(), index: non_neg_integer(), code: atom()}

@spec check_entity_writes(ProcessDefinition.t() | map(), prefix :: String.t(), activator_opt() | nil) ::
        :ok
        | {:error, :graph_structure_invalid}
        | {:error, {:entity_writes_invalid, [entity_writes_violation()]}}
# @doc false def, beside check_script_bindings/2. Reads only (definitions by name); takes no lock.
# Walks the graph's nodes in graph order; a node with a non-empty entity_writes attribute -> node-level
# checks (type, list shape, cap, SERVICE_TASK refusal, activator) then EntityPort.impl().validate_lines/2.

@spec record_activator(ProcessDefinition.t(), activator_opt(), [EntityPort.line()] ...) :: (internal)
# writes activated_by on the row being activated, same transaction; only for graphs with lines.
```

New pure module `Letflow.Definitions.Activator` (`definitions/activator.ex`):

```
@spec from_auth_context(auth_context :: map(), platform_tenant? :: boolean()) :: EntityPort.activator() | nil
# Pure in its arguments only: the router passes platform_tenant? in (recomputed there, as
# Letflow.Plugs.Authorize does at plugs/authorize.ex:109-123, from PlatformTenant.platform_tenant?/1).
# nil when user_id is missing. roles = Authorization.effective_roles(auth_context.roles, platform_tenant?); entities_records_write? =
# Authorization.has_permission?(effective_roles, :EntitiesRecordsWrite).
```

`activated_by` stored shape (jsonb, deterministic key order, no PII beyond ids):

```
%{"user_id" => uuid, "roles" => [sorted role names],
  "permissions" => ["DefinitionsActivate", "EntitiesRecordsWrite"],   # evaluated at activation
  "authorized" => [%{"entity_type" => t, "op" => "create"}, ...],     # sorted, distinct
  "activated_at" => iso8601}
```

`Letflow.Api.Response` gains (shared by the activate, rollback, promotion-apply and tenant
promote renderers, as A1b did):

```
@spec entity_writes_invalid(Plug.Conn.t(), [entity_writes_violation()]) :: Plug.Conn.t()      # 422
@spec entity_write_refused(Plug.Conn.t(), code :: atom(), index :: non_neg_integer() | nil) :: Plug.Conn.t()
@spec public_variables(map()) :: map()          # drops every reserved top-level key (CO-1); the ONE helper
```

### 5.4 Engine (`engine.ex`), private and public additions

```
@type complete_error  # gains:
        | {:error, {:entity_write_refused, index :: non_neg_integer() | :contention, code :: atom()}}
        | {:error, {:entity_write_failed, index :: non_neg_integer(), step :: atom()}}
        | {:error, :entity_write_needs_reactivation}

@typep entity_plan :: %{
         lines: [EntityPort.line()], node_id: String.t(), task_id: Ecto.UUID.t(),
         instance_id: Ecto.UUID.t(), definition_id: Ecto.UUID.t(), definition_version: String.t(),
         activator_id: Ecto.UUID.t(), authorized: [{String.t(), String.t()}]
       }

# private
@spec plan_entity_writes(task_id, prefix) :: {:lines, entity_plan()} | :none | {:error, :entity_write_needs_reactivation}
@spec fold_sys_into_transition(changes :: map()) :: map()   # pure; F-3
```

`VariableMerge`: no new public function (strict `put_sys/3` already exists). `Records`: the
`step_source` type and `step_source_metadata/1` guard (D-B.9). `Instances`: a private
`@hidden_event_types` list applied by `history/3` and `timeline/3` (CO-1).

## 6. Line shape and `validate_lines/2`

### 6.1 Stored shape (node attribute `entity_writes`, string keys)

| Key | Type | Rule |
|---|---|---|
| `op` | `"create"` | only value in the MVP; any other string, or absent -> `:entity_write_op_unsupported` |
| `entity_type` | non-empty, non-whitespace string, valid type name | missing/not a binary/empty/whitespace -> `:entity_type_missing`; else invalid name -> `:entity_type_name_invalid` (#2633) |
| `fields` | map `field_name -> source` | optional (absent = `%{}`); each source `{"var": <non-empty string>}` or `{"const": <JSON value>}`; anything else -> `:entity_write_field_source_invalid` |
| `output_record_id_var` | optional string | strict `\A_sys\.[A-Za-z0-9_]+\z`, id key <= 160 bytes AND `<name>.seq` key <= 160 bytes (name <= 151 bytes); a dotted name is refused (#2621 hard constraint 1) |
| `record`, `expected` | must be absent on `create` | present -> `:entity_write_record_not_allowed` / `:entity_write_expected_not_allowed` (also reported with `:entity_write_op_unsupported` for an update/delete line, so the "from a form output" case is covered) |
| any other key | refused | `:entity_write_unknown_key` |

A `var` source naming a reserved name (`_sys` or `_sys.*`) is refused
(`:entity_write_sys_reference`): consistent with the A1b ruling that no binding may read `_sys`,
and a create-only MVP has no use for it (line order is by type, so an earlier line's id is not
reliably available to a later one).

### 6.2 Violation codes (closed set; every code is a stable atom, no value, no field name)

| Code | Raised by | Condition |
|---|---|---|
| `:entity_writes_not_a_list` | Definitions (node level, index 0) | attribute present but not a list |
| `:entity_writes_too_many_lines` | `validate_lines/2` | more than 20 lines; index = 20 (first excess) |
| `:entity_writes_node_type_not_supported` | Definitions (node level, index 0) | SERVICE_TASK, or any node type other than HUMAN_TASK (D-B.20) |
| `:entity_write_activator_required` | Definitions (node level, index 0) | no `activator` option, or `entities_records_write?` false |
| `:entity_write_line_malformed` | `validate_lines/2` | line is not a map with binary keys |
| `:entity_write_unknown_key` | same | key outside 6.1 |
| `:entity_type_missing`, `:entity_type_name_invalid` | same | 6.1 |
| `:entity_type_not_found` | same | no ACTIVE definition for the type |
| `:entity_type_not_writable_by_process` | same | `ProcessWritable.writable?/1` false (flag absent, denied name) |
| `:entity_type_managed` | same | `managed_by` present (covers a stamp-like field on a plain tenant definition: managed is read from the definition ROW, never from request data) |
| `:entity_type_not_append_only` | same | CURRENT definition lacks literal `"append_only" => true` |
| `:entity_type_scoped` | same | `scoped_type?/1` (D-B.18) |
| `:entity_write_op_unsupported` | same | op not `"create"` |
| `:entity_write_record_not_allowed`, `:entity_write_expected_not_allowed` | same | 6.1 |
| `:entity_write_field_unknown` | same | `fields` key not a field of the type's definition |
| `:entity_write_field_scope_column` | same | `scope_column_field?/2` (D-B.18) |
| `:entity_write_field_source_invalid`, `:entity_write_sys_reference` | same | 6.1 |
| `:entity_write_output_var_shape` | same | not the strict shape or a key over 160 bytes |
| `:entity_write_output_var_duplicate` | same | the same var on two lines of the node, or named by another node's line (`graph_output_vars`) |
| `:entity_write_output_var_preseeded` | Definitions | the name is also a form property, `required_outputs` entry or `variable_schemas` field of the graph |
| `:entity_writes_execution_not_enabled` | `validate_lines/2` (B1 only) | appended per line when every real check passed; removed in B2 |

The result is sorted by `{index, code}`; the same input always yields the same list. HTTP: 422
body `{"error": "entity_writes_invalid", "violations": [{"node_id", "index", "code"}]}`: ids and
codes only (the caller is the designer of the definition and sees their own graph).

### 6.3 Where the check runs

| Path | Site | Order |
|---|---|---|
| Activate | `run_activate_transaction/4` `with` (`definitions.ex:2338`) | `run_semantic_validation` -> `check_reserved_references` -> **`check_entity_writes`** -> `check_script_bindings` -> `activate_draft` (+ `activated_by`) |
| Version rollback | `do_rollback` (`definitions.ex:2728`) | same position |
| Promotion apply and `POST /tenants/:id/promote/:key` | `Promotion` activation (`promotion.ex`, A1b call site) | same position |

Placement before `check_script_bindings/2` keeps the reads lock-free before the `FOR SHARE`
script-row locks. Save-time (`Graph` CHK-31) is NOT added: every semantic rule needs a database
read; the structural subset can move to save time later without changing codes (deferred).

Existing active definitions are never re-validated: a node already ACTIVE with an
`entity_writes` attribute keeps today's behaviour until B2, where the run-time `normalize_line/1`
and `:process_policy` refuse it as `validation_failed`/`write_not_permitted`. The pre-B2 inventory
(section 14) must find none.

## 7. Completion-transaction composition (B2)

### 7.1 Order (normative)

```
-- before the transaction -------------------------------------------------------------
P0  plan_entity_writes/2   (reads; nil plan when no lines; activator-status check, 7.4)
P1  EntityPort.impl().prepare(lines, %{prefix})   -- its own short transaction, SET LOCAL 2s/2s
-- one Repo.transaction() -------------------------------------------------------------
S0  :entity_write_timeouts       SET LOCAL lock_timeout='2s'; SET LOCAL statement_timeout='5s'   (plan only)
S1  :task                        tasks row FOR UPDATE
S2  :instance_projection         instance_projections row FOR UPDATE
S3  :snapshot_and_state, :completion_guards, :form_expression_reevaluation, :merge   (unchanged)
S4  :transition                  computation and reads (no FOR UPDATE)
S5  StepWrites.multi/3:          :entity_writes_started, then per line in (entity_type, index) order:
                                 {:line,i,:deadline}, {:line,i,:build}, A2 steps (type sequence row
                                 FOR UPDATE, idempotency, event, projection, recheck, record latest),
                                 {:line,i,:process_policy}; then :entity_writes
S6  tail Multi.merge             cancel timers, task activation, token reconcile, timers, dispatches,
                                 :task_complete, task audit, **per-line audit**, **:sys_variables_event**,
                                 **:entity_writes_applied_event**, :event (TASK_COMPLETED), :projection
                                 (variables with _sys folded), sub-process steps, :complete_task_outcome
-- after commit (unchanged) --------------------------------------------------------------
snapshot (folded state), telemetry, interpret
```

A completion without lines: S0 and S5 are absent, S6 contains none of the new steps; the Multi is
byte-identical to today (regression criterion B-15).

### 7.2 Lock inventory and ordering proof

| # | Lock | Taken by | Held to |
|---|---|---|---|
| 0 | pre-transaction `entity_type_instances` insert (unique index) | `prepare/2`, own short transaction | its own commit |
| 1 | `tasks` row | `:task` | commit |
| 2 | `instance_projections` row | `:instance_projection` | commit |
| 4a | per line, per type: the type's `instance_sequences` row, then the synthetic projection row (`:active_instance_guard`, `:update_projection`) | A2 steps | commit |
| 4c | the record row | none (create-only) | n/a |
| 5 | audit chain sentinel row (`audit_chain_locks`) | tail: task audit, per-line audit | commit |
| 6 | the instance's own `instance_sequences` row | tail events (SYS, APPLIED, `TASK_COMPLETED`) | commit |
| 7 | **cascade, when the completing instance is a sub-process child that reaches `:completed`** (GH #2695: the HUMAN tail's `:lock_ancestors` step takes the parent group first, after the entity-type steps 4 and before rows 5-6; this row's cascade lookup then re-locks the same rows): the parent projection `FOR UPDATE`, then the parent's waiting token row `FOR UPDATE` (`SubProcess.lock_waiting_parent/3` via `find_waiting_parent_token/3`, GH #2695; was token then projection), then the parent projection UPDATE (reconcile) | tail `append_sub_process_completion_cascade_multi` (`engine.ex:5565-5610`) | commit |

Order 1, 2, 4 (types ascending), then 5, 6 for EVERY completion with lines. The instance
sequence row (6) now follows 4 (0054 numbered it 3): harmless, as 0054 itself argued, because every
writer of an instance stream holds that instance's projection mutex (2) first, so row 6 is never
contended in the opposite order. The audit chain lock (5) is already taken today in the tail
(`record_task_complete_audit/4`, `engine.ex:5493`); B2 adds up to 20 inserts under it (a hold-time
cost, bounded by the 20-line cap and the 5 s statement timeout) and, because `lock_timeout` is now
2 s for completions with lines, a waiter maps to `entity_write_contention` instead of waiting
unbounded (accepted by 0054 D3 "Timeouts").

Two completions with line sets (A,B) and (B,A): both execute A then B (sorted), so the second
waits at A's type sequence row while the first holds it. No cycle. Test AC B-3.

**Cascade cycle (found in review; NOT closed by ordering).** A child instance's completion with
lines holds [child `tasks`, child projection, type-A sequence] and then, in the tail cascade, wants
[parent token, parent projection]. A parent-instance completion (a parallel-branch task of the
parent) holds [parent projection] and, with lines on type A, wants [type-A sequence]. That is a
real cycle: the parent holds its projection and wants A; the child holds A and wants the parent
projection. Postgres resolves it with `40P01` on one side (either may be the victim) or, because
`lock_timeout` is 2 s, `55P03`. Outcome: the victim's whole transaction rolls back, nothing is
committed (the tail is in the same transaction), and the result maps to
`entity_write_contention` (503, retryable); the retry re-runs from a clean state. The cycle needs a
parent with a parallel branch AND lines on the same type in child and parent, so it is rare, but it
is reachable and is stated, not excluded. Taking the parent locks before the lines would invert the
order for every completion and is rejected. EE-12 gains one sentence in B2: "a sub-process
child's completion cascade takes the parent token and projection after its entity-type locks; a
deadlock there is reported as contention".

### 7.3 Pre-transaction phase (P0, P1)

* P0 `plan_entity_writes/2` reads: the task (unlocked, by id), the instance projection's
  `definition_id`, the snapshot graph (`SnapshotStore.get_by_instance_id/2` then `build_graph/1`, the
  same helpers `fetch_graph/2` uses, `engine.ex:2824`), the node by `task.node_id`, and the
  definition row's `activated_by`. No lock, no write. Any error -> `:none` (the transaction's own
  steps return today's errors).
* Activator status stub (D-B.14): P0 reads the activator with the existing
  `Letflow.Identity.get_user/2` (`identity.ex:353`, `{:ok, %User{}} | {:error, :not_found}`, scoped
  by `opts[:prefix]` to the tenant `users` table; `identity/user.ex:41` `status :: :active |
  :inactive`). `{:ok, %User{status: :active}}` proceeds; `{:ok, %User{status: :inactive}}` AND
  `{:error, :not_found}` (row absent) both return `{:error, :entity_write_needs_reactivation}`
  (FAIL CLOSED: an unresolvable activator is treated as deactivated); nothing is opened or
  written, the task stays `pending`. Boundary: `check_boundaries` has one layer rule only (engine ->
  entities, `letflow.check_boundaries.ex:285-290`), so an engine -> `Letflow.Identity` edge is
  permitted; ELIXIR-DEV runs the task and quotes the result. (If REVIEWER prefers the engine
  identity-free, the read moves behind a fifth port callback `activator_active?/2`; nothing else
  changes.)
* **Recovery path for the stub.** `Definitions.activate/2` accepts DRAFT rows only
  (`definitions.ex:2328`), so an ACTIVE definition cannot be re-activated in place. Operators
  recover by (a) cancelling the affected instances (`POST /instances/:id/cancel`, unaffected by
  the stub), or (b) a version rollback or promotion that re-activates a row under a live principal
  (`activated_by` is re-recorded, 6.3), after which NEW instances pin that row. An instance already
  pinned to the old row stays refused until cancelled. The real `needs_reactivation` task status and
  an in-place re-activation flow are a FOLLOW-UP (section 16).
* P1 `prepare/2`: unchanged mechanism (A3), new filter. For each distinct binary type, sorted:
  `get_active_definition_by_name/2`, then `ProcessWritable.writable?/1` on that row; only a writable
  type reaches `get_or_create/2` (CO-3, SEC F7). `{:error, :entity_write_contention}` becomes
  `{:error, {:entity_write_refused, :contention, :entity_write_contention}}` before any
  transaction; `{:error, :prepare_inside_transaction}` or `{:error, {:entity_type_prepare_failed, _}}`
  -> `{:error, {:entity_write_failed, 0, :prepare}}` (internal, 500).

### 7.4 The `:entity_writes` step, per line (S5)

1. `normalize_line/1` on the pinned line (hand-edited snapshots): malformed -> `:line_malformed` ->
   `validation_failed`; a non-integer `expected` is `validation_failed` BEFORE any op check and
   never reaches `expected_seq/1` (B-6); `op` other than `"create"` -> `entity_append_only` (D7/D8).
2. Authorised pair: `{entity_type, "create"}` must be in `ctx.authorized` (the recorded
   `activated_by.authorized`), else `:line_not_authorized` -> `write_not_permitted` (D4a.3).
3. Values: each `{"var": v}` is read from `ctx.variables.(changes)` (a key absent or a reserved
   name -> field omitted, so the type's validation refuses a missing required field), each
   `{"const": c}` as is. Never from `_sys` and never from a request field.
4. `FieldGrants.load_restrictions(completer, type, prefix)`: any `fields` key in the returned set
   -> `:field_restricted` -> `write_not_permitted`; no field name in the result (D4c; create has no
   hidden-field carry-over because it reads no row).
5. `Records.command_multi(command, prefix, :tenant)` with `kind: :create`, `line_key = declared
   index`, `actor_id = completer`, `idempotency_key = "sys:step:" <> task_id <> ":" <> index`,
   `source = %{kind: "process_step", instance_id, task_id, node_id, definition_id,
   definition_version (string), line_index, activator_id}`. The authority argument is the LITERAL
   `:tenant` (A2 D-A2.9; `managed_types_callers_test.exs` unchanged). A returned `{:error, r}` ->
   `Multi.error({:line, i, :build}, r)`.
6. After the A2 steps, `{:line, i, :process_policy}` reads the `:recheck_definition` row:
   `ProcessWritable.writable?/1`, `append_only == true`, `not scoped_type?/1` (B-8, B-12: a type that
   became managed after activation is already refused by the recheck's authority check).
7. `:entity_writes` assembles `applied_line` per line: `record_id` from the built context,
   `event_global_seq` from the `{:line, i, :insert_event}` result (`%Event{global_seq}`), plus
   `lines_hash` and the `sys_values` map (id key -> record id, `<key>.seq` -> global seq) for lines
   that declare `output_record_id_var`.

### 7.5 Tail additions (S6) and the `_sys` fold

* `:sys_variables_event` (atom name): only when `sys_values` is non-empty. Built by folding every pair through
  strict `VariableMerge.put_sys/3` (an `{:error, _}` -> `{:error, {:entity_write_failed, 0,
  :sys_value}}`, rollback). Appended with `EventStore.append/2`: type
  `VariableMerge.sys_event_type()`, payload `%{"node_id", "cause" => "entity_writes", "values"}`,
  key `<completion key>::sys_vars`. It traverses `Registry.validate_payload/3` (#2621 constraint 2).
  Placed immediately BEFORE `:event` (D-A1.10).
* `:entity_writes_applied_event`: always when lines were applied. Type
  `EntityPort.applied_event_type()`, payload per A1 section 2.4 with `task_id` set and
  `dispatch_id` null, `lines` = `applied` (ids and sequences only, INV-2), key
  `<completion key>::entity_writes`. Placed after the SYS event, before `:event`.
* Per-line audit: step `{:entity_write_audit, i}` (declared index; D-B.25) running `Audit.insert_entry/3`, `action: "entity_write.process_step"`,
  `resource_type: "entity_record"`, `resource_id: record_id`, `before_state: nil`,
  `after_state: %{"entity_type", "record_id", "task_id", "instance_id", "node_id",
  "definition_id", "line_index", "lines_hash"}` (no field value), `actor_id: completer`.
* `:projection` and the sub-process completion cascade read the final state WITH the `_sys`
  values folded (strict `put_sys/3`); `fold_sys_into_transition/1` applies the same fold to
  `changes.transition` after the transaction so `maybe_snapshot_after_complete_task/2`,
  telemetry and `interpret_complete_result/3` see it (F-3).
* `complete_result.variables` keeps the true state internally; the router strips (section 10).

### 7.6 Error mapping

* New wrapper `run_transaction/2` (private): with a plan, `try Repo.transaction() rescue
  %Postgrex.Error{postgres: %{code: c}} when c in [:lock_not_available, :query_canceled,
  :deadlock_detected]` and `DBConnection.ConnectionError` -> `{:error, {:entity_write_refused,
  :contention, :entity_write_contention}}`. Without a plan it is `Repo.transaction()` verbatim
  (the function-level blanket rescue at `engine.ex:2662` is kept). Post-commit stages stay under
  the blanket rescue and are never mapped to contention (AC B-4).
* `maybe_snapshot_after_complete_task/2` and `emit_task_completed_telemetry/2` already pass any
  non-matching result through; `interpret_complete_result/3` gains: (a) a clause for the 2-tuple
  contention result, (b) a clause for `{:error, {:line, _, _} = step, reason, changes}` calling
  `EntityPort.impl().interpret_failure/2`, mapping `{:refused, i, code, detail}` to
  `{:error, {:entity_write_refused, i, code}}` after one best-effort audit
  (`entity_write.refused`, the `detail` atom and index only, written after the rollback exactly like
  `record_completion_refusal_audit/6`), `{:failed, i, step}` to `{:error, {:entity_write_failed,
  i, step}}` (step name logged, nothing else), `:not_a_line_failure` to the existing generic path.
  Clause order: before the generic 4-tuple clause at `engine.ex:6465`.
* The deadline guard and `:deadline_exceeded` map to `{:refused, i, :entity_write_contention,
  :deadline}` (OQ-B3).

## 8. Error and refusal table (HUMAN_TASK completion)

| Cause | Internal result | HTTP | Retryable | Notes |
|---|---|---|---|---|
| Managed type, type not process-writable, not append-only, scoped, line not authorised, field restricted, record not found | `{:entity_write_refused, i, :write_not_permitted}` | 403 | no | ONE code and ONE body; detail class (`:managed`, `:not_writable`, `:not_append_only`, `:scoped`, `:not_authorized`, `:field_restricted`) only in the tenant audit entry and the log (INV-5) |
| Field validation failure, malformed line, bad `expected`, `expected` on create | `:validation_failed` | 422 | no | no field names |
| update/delete op in a pinned line | `:entity_append_only` | 422 | no | D7/D8 |
| duplicate `sys:step:` key inside the transaction | `:idempotency_conflict` | 422 | no | D9; never success |
| type inactive / definition changed between build and recheck | `:entity_type_inactive` | 422 | no | |
| `55P03`, `57014`, `40P01`, pool timeout, 10 s guard | `{:entity_write_refused, :contention, :entity_write_contention}` | 503 | yes, after backoff | OQ-B3 |
| activator user inactive | `:entity_write_needs_reactivation` | 409 | no, until re-activation | stub (OQ-B2) |
| internal fault in a line step (`{:entity_write_failed, i, step}`) | | 500 | no | step atom logged; INV-4 |
| `:merge` or `:transition` execution error with lines | nothing written; existing `{:instance_execution_error, ...}` -> 409 | 409 | n/a | AC B-2, F-2 |
| `output_refused`, `separation_of_duties` | unchanged | 422, 403 | | evaluated BEFORE the lines (guards run at `:completion_guards`) |

Body for the refusals (`Response.entity_write_refused/3`): ONE envelope, `send_json/3` with the
flat map `{"error": "<code>", "line_index": <declared index> | null}` (the
`script_binding_invalid/3` precedent, `response.ex:196`), NOT `send_problem/2`, so the bytes are a
function of `(status, code, index)` alone; `write_not_permitted` is byte-identical
for every cause at the same index (test B-7). `record_version_conflict` (409) is mapped for
completeness but is unreachable in PR B (no update line exists).

## 9. Concurrency, transaction and idempotency analysis

* **Atomicity.** Lines, `_sys` event, APPLIED event, audit, task completion and projection commit
  or roll back as one transaction. A refusal in line k rolls back lines 0..k-1 (Multi semantics),
  the idempotency rows included. Verified by the forced-failure test (B-2).
* **Idempotency.** Line key `sys:step:<task_id>:<declared index>`, ids from a closed charset
  (UUID text). A retry after a rolled-back completion reuses the same keys and succeeds (nothing was
  claimed). A retry after a committed completion is `task_not_pending` before any line. A client
  that pre-claims the key through any entry point gets a namespaced key (#2550), so it cannot wedge
  the task; an in-process raw `sys:step:` key is refused (A2). The two instance-event keys are
  derived from the per-request completion key and never collide with it.
* **Replay.** Rebuilding never calls `StepWrites`; the SYS event folds through `put_sys_replayed/3`
  before `TASK_COMPLETED` (A1); APPLIED folds as a no-op. A stored pre-#2621 wide-shape SYS event
  replays to byte-identical variables and appends nothing (CO-7).
* **SET LOCAL scope.** `SET LOCAL` lasts to the end of the transaction, so the 2 s lock timeout
  also bounds the `tasks` and projection waits and the tail's writes, for lines-completions only.
  A completion without a plan issues no `SET LOCAL` (B-5).
* **Ambiguous commit.** `DBConnection.ConnectionError` mapped to contention can follow a server-side
  COMMIT whose acknowledgement was lost. The client sees 503 and retries; the retry finds the task
  `completed` and returns `{:task_not_pending, :completed}` (409) before any line: safe, no double
  write. Rescued `40P01`/`55P03` cannot be ambiguous (Postgres re-raises only after rollback).
* **Cross-instance contention.** The type sequence row is per TYPE, so every writer of that type
  in the tenant serialises behind a completion with lines (0054 Consequences). Bounded by 20 lines,
  2 s lock timeout, 5 s statement timeout, 10 s guard.
* **Stale pre-transaction plan.** Snapshot and node are immutable per instance; a concurrent
  completion of the same task is caught by the `:task` lock (`task_not_pending`). The activator
  status check is advisory (deactivation after the check is the accepted 0054 D4a.4 weakness).
* **`activated_by` read.** The definition row is immutable except `status`; the row an instance
  pinned by id is read, never "the current active version by name".

## 10. API gating (CO-1): exact routes, decision, shapes

Decision: STRIP every top-level reserved key from client-visible variable maps; no new permission,
no opt-in. Single helper `Response.public_variables/1` (wraps `VariableMerge.drop_reserved/1`).

| # | Route | Site | Change |
|---|---|---|---|
| 1 | `GET /instances/:id` | `routers/instances.ex:850` `instance_map/1`, key `"variables"` | `Response.public_variables(projection.variables)` |
| 2 | `POST /instances/:id/reconstruct` | `instances.ex:730` `render_reconstruct/2`, key `"variables"` (and the `write_back` persists the full state; only the RESPONSE is stripped) | same |
| 3 | `POST /tasks/:id/complete` | `routers/tasks.ex:676-690` `complete_result_map/1`, key `"variables"` | same |
| 4 | `GET /instances/:id/history` | `instances.ex:952` `history_item_map/2` and `Instances.history/3` | server-side exclusion of `INSTANCE_SYS_VARIABLES_SET` rows (cursor and `next_cursor` unaffected); `TASK_ENTITY_WRITES_APPLIED` payload reduced to `node_id`, `task_id`, `dispatch_id`, `lines_hash` and `lines` as `[{line_index, entity_type}]` (OQ-B4); `EXECUTION_ERROR` payload `"variables"` passed through `public_variables/1`; B3 amendment: any top-level `variables`, `output_variables` or `initial_variables` map of any event payload is passed through `public_variables/1` defensively (no-op today, `_sys` is refused at write) |
| 5 | `GET /instances/:id/timeline` | `Instances.timeline/3` | the same exclusion of `INSTANCE_SYS_VARIABLES_SET` |
| - | `GET /instances` (list), `GET /tasks/:id` | `list_item_map/1`, `task_detail_map` | no `variables` key; unchanged |
| - | Lua `get_instance_state` / `read_variable` (`lua/platform.ex`) and the Wasm `host_api` `read_variable` | B3 amendment (SEC F1): closed in B3 itself; `fetch_instance_state`, `do_read_variable` and the Wasm read pass the variables through `VariableMerge.drop_reserved/1` | `platform_test.exs` cases |
| - | webhooks, DLQ, service-task templates | grep: no `variables` serialisation; template/binding reads refused at activation (A1b) | none; pinned by the static test |

Asymmetry (OQ-B4, ruled): the instance history drops `record_id` and `event_global_seq`, but the hash-chained tenant AUDIT entry per line keeps them in `after_state` (actor = completer, `definition_version`, `record_id`), so `AuditRead` holders see the full trail; acceptable because audit access is the stronger permission and the ids are not field values. Test B-11.

Response shapes: the `"variables"` object simply lacks the reserved keys; no placeholder key and
no marker. Non-reserved keys and nested maps are untouched. A client that stored a variable named
`_sys...` can no longer exist (A1 refusal), so nothing legitimate disappears.

Static guard (B3 test): an AST scan over `lib/letflow/routers/**` flags any map entry whose key is
the literal `"variables"` and whose value is not a call to `Response.public_variables/1`; a second
rule lists the event types that `history_item_map/2` may emit verbatim. Non-vacuity on synthetic
snippets.

Frontend/mobile: no change (the contract only loses keys no client could set).

## 11. AC -> design -> test brief

Test files are the issue's names where it gives one. "DB" = tenant fixture; engine-level
composition tests run `async: false`. All new unless marked "edit".

### 11.1 Issue Group B

| AC | PR | Design | Test brief |
|---|---|---|---|
| **B-1** Declaration and activation validation | B1 | 6, 6.3 | `test/letflow/definitions/entity_writes_activation_test.exs`: one case per code of 6.2 with the code asserted at the exact `{node_id, index}`: unknown/inactive type, unknown field, type without the flag, managed type (also a plain tenant definition with a stamp-like field), update/delete line, non-append-only type, field mapped onto a scope column (seam: `scope_column_field?/2` and `scoped_type?/1` are pure functions of the definition ROW and read the closed key list `Application.get_env(:letflow, :entity_writes_scope_keys, [])`; a test sets e.g. `["scope_node"]` and uses a fixture definition carrying that key; the production list stays empty until 0051), 21 lines, `record`/`expected` from a form output, scoped type (predicate stubbed), `output_record_id_var` not `_sys.<seg>`, dotted, pre-seeded, key over 160 bytes (id and `.seq`), duplicate var; SERVICE_TASK node; missing activator; all reported together for a multi-defect line; deterministic order. B1 gate (flag off, the default): a fully valid definition is refused with `:entity_writes_execution_not_enabled`; with the flag on in `setup` the same definition activates and `activated_by` is recorded. B2 deletes the flag, its env key and the "flag off" case. The activation cases run on all three paths (activate, rollback, promotion apply). Runtime cap and append-only recheck on a hand-edited snapshot: `entity_writes_runtime_refusals_test.exs` (B2). |
| **B-2** Atomicity | B2 | 7.1, 9 | `test/letflow/engine/complete_task_entity_writes_test.exs`: two `create` lines commit both records, both entity events, `INSTANCE_SYS_VARIABLES_SET`, `TASK_ENTITY_WRITES_APPLIED`, `TASK_COMPLETED` and the task completion; force line 2 to fail (invalid field value) -> task `pending`, zero records, zero entity events, zero instance events, zero `event_idempotency` rows with the `sys:step:` prefix, zero audit rows; the `:merge` execution-error case writes no record; **the `:transition` no-matching-edge case (F-2): nothing written (zero records, zero entity events, zero `sys:step:` idempotency rows), the instance is `:error`, the task stays `pending`, and a second completion returns `{:error, {:instance_not_active, :error}}` (HTTP 409)**; a form-schema-rejected output (`output_refused`) writes nothing. |
| **B-3** Execution and lock order | B2 | 7.2 | `entity_writes_lock_order_test.exs` (`:auto` sandbox): statement log of one completion lists type sequence rows ascending, tail locks after; (A,B) vs (B,A) completions N-parallel (N <= 4, bounded by the machine load rules) finish without `40P01`; a source-level assertion that no `FOR UPDATE` is reachable from `dispatch_task_completion_hop_chain/7`'s prepare functions; rule-3a note: `ScopeNodePaths.lock!/1` is not called (asserted via statement log); **cascade case:** a child instance (sub-process) with lines on type A completes concurrently with a parent parallel-branch task with lines on type A, N rounds (N <= 4): every round ends with both committed or one `entity_write_contention` (503) with nothing committed for the victim, never a hang and never a partial write, asserted by record counts. |
| **B-4** Contention mapping | B2 | 7.6 | `entity_write_contention_test.exs`: force each of `55P03` (a second connection holds the type sequence row), `57014` (statement timeout injected), `40P01` (two-connection cycle), `DBConnection.ConnectionError` (checkout timeout) -> `{:error, {:entity_write_refused, :contention, :entity_write_contention}}`, HTTP 503, nothing committed; a contention code raised from `maybe_snapshot_after_complete_task/2` or telemetry AFTER commit (injected) is NOT mapped, task shown completed; a completion without lines raising the same code inside the transaction keeps today's `{:transaction_failed, _}`. |
| **B-5** Timeouts only when lines exist | B2 | 7.1 S0, 4 D-B.11 | statement-log capture per call (CO-4 helper): lines-completion issues exactly `SET LOCAL lock_timeout`, `SET LOCAL statement_timeout` as the FIRST two statements of the transaction; no-lines completion issues none; injected `now_fun` trips the 10 s guard between lines -> full rollback, `entity_write_contention`, audit detail `:deadline`. |
| **B-6** Bad `expected` never crashes | B2 | 7.4 step 1, D-B.21 | `entity_writes_expected_test.exs`: a hand-edited pinned line with `expected: "x"`, `1.5`, `-1`, `%{}` -> `validation_failed`, no raise, nothing written; with `expected: 5` on a create line -> `validation_failed`; documented deviation (OQ-B5): the "stale `expected` -> `record_version_conflict`" half is not reachable in the create-only MVP; the `:check_record_version` -> `record_version_conflict` mapping stays covered by A2's `interpret_in_multi/1` tests, referenced in the PR body. |
| **B-7** Uniform `write_not_permitted` | B2 | D-B.17, 8 | `entity_write_refusal_shape_test.exs`: managed type, type without the flag (flag removed after activation), field restriction, not-authorised pair, non-append-only type, scoped (stubbed) -> responses byte-identical (status, headers that vary excluded, body) at the same line index; the tenant audit entry carries the distinct detail atom; the response contains no field name and no entity type name. |
| **B-8** Run-time `writable_by_process` re-check | B2 | 7.4 step 6 | `writable_by_process_test.exs` (edit/extend): activate with the flag, create a pending task, remove the flag by a new type version, complete -> `write_not_permitted`, nothing written; `prepare/2` creates no synthetic instance for a non-writable type (CO-3). |
| **B-9** Write-side field restrictions | B2 | 7.4 step 4 | `entity_writes_field_restrictions_test.exs`: restricted field, completer without grant -> refused (`write_not_permitted`, no field name); with a `user_entity_grants` row -> allowed; `:EntitiesRestrictionsManage` alone grants nothing; the entity event and instance events carry no field value; the `Records` result is not in the response. |
| **B-10** Idempotency key and conflict | B2 | 9 | `entity_writes_idempotency_test.exs`: keys are `sys:step:<task_id>:<i>`; a client posting `idempotency_key: "sys:step:<task_id>:0"` through `POST /entities/records` is stored namespaced and the completion still succeeds; a manually inserted duplicate key (raw `event_idempotency` row) -> `idempotency_conflict`, rollback; retry after rollback succeeds. |
| **B-11** Actor, event shape, audit | B2 | 7.4, 7.5 | `entity_writes_audit_test.exs`: history shows the APPLIED event WITHOUT `record_id`/`event_global_seq`, while an `AuditRead` principal's audit page shows the per-line entries WITH `record_id`, the completer as actor and `definition_version` in `after_state`; entity event `actor_id` is the completer; metadata has exactly the nine `source.*` keys with `definition_version` the string; instance stream has ONE APPLIED event with `(line_index, entity_type, record_id, event_global_seq)` per line and `lines_hash` equal to `StepWrites.lines_hash/1`; no field value anywhere; one `entity_write.process_step` audit row per line; hash chain verifies (`Audit.verify_chain/2`). |
| **B-12** Managed types never a target | B1, B2 | 6.2, 7.4 | `test/letflow/definitions/entity_writes_managed_type_test.exs`: activation refused for a managed type, for a definition carrying a stamp-like field and for a plain definition alike; run time: hand-edited pinned snapshot -> `write_not_permitted`; type becomes managed after activation (create the managed version through the fixture owner) -> refused by the recheck authority; response byte-identical to B-7; no event, record or idempotency row. |
| **B-13** Activator authority recorded | B1, B2 | 5.3, 7.3 | `entity_writes_activator_test.exs` (flag `:entity_writes_execution_enabled` on in `setup`): activation by a principal with `:EntitiesDefinitionsWrite`+`:DefinitionsActivate` but without `:EntitiesRecordsWrite` -> `:entity_write_activator_required`; with it, `activated_by` holds user, roles, permissions, authorised pairs; a line whose pair is absent from `authorized` (hand-edited snapshot) is refused; activator user set `:inactive`, AND activator user row deleted (`:not_found`) -> `{:error, :entity_write_needs_reactivation}` (409), task `pending`, nothing written, and `POST /instances/:id/cancel` on that instance succeeds (recovery path); rollback and promotion re-record the new activator; a graph without lines leaves `activated_by` NULL. |
| **B-17** Ambiguous commit | B2 | 9 | in `entity_write_contention_test.exs`: a `DBConnection.ConnectionError` injected AFTER the commit statement (stub) -> 503; the retry returns `{:task_not_pending, :completed}` (409), record count unchanged. |
| **B-18** Completer scope (D4a.3) | B2 | D-B.23 | `entity_writes_completer_scope_test.exs`: a user who is not the task's assignee gets 403 from `Tasks.authorize_completion/3`; a port test double records ZERO `prepare/2`/`multi/3` calls and no `entity_type_instances` row is created. |
| **B-19** `activated_by` not forgeable | B1 | D-B.24, I-B11 | `entity_writes_activator_test.exs`: `POST /definitions` and `PUT /definitions/:id` with a body key `activated_by` (also nested in `graph`) store NULL; `Definitions.create/2` with the attr in the map -> NULL; only an activation (flag on) sets it. |
| **B-14** Replay never re-executes | B2 | 9 | `entity_writes_replay_test.exs` (AC 15, moved from A1): a `StepWrites`/port test double (configured through `:entity_port`) asserts zero `multi/3`, `prepare/2`, `validate_lines/2`, `interpret_failure/2` calls during `Reconstruction.reconstruct_instance/2`, projection rebuild, timer fire, escalation and cancel; rebuilt variables equal the live ones including `_sys.*`; snapshot-based rebuild (F-3) equals event-only rebuild. |
| **B-15** Regression | all | 7.1 | Full `mix test` green, quoted in each PR body; the existing `Records`, `complete_task`, `engine_concurrency_test.exs` suites unedited and green; a golden Multi-name test: a completion without lines yields exactly today's step names. |
| **B-16** Expressions referencing `_sys` | B1 | 6.1, A1b | `entity_writes_activation_test.exs` case: a `fields` `{"var": "_sys.r"}` and `{"var": "_sys"}` -> `:entity_write_sys_reference`; A1b's `reserved_references_*` suites unchanged and green. |

### 11.2 Carry-overs (numbered as requested)

| # | Carry-over | PR | Decision and design element | Test brief |
|---|---|---|---|---|
| **CO-1** | Strip or gate engine-written `_sys` values in responses (INV-2) | B3 | STRIP, no gate (D-B.16); five exact routes plus the static guard (section 10) | `test/letflow/routers/sys_variables_response_test.exs`: after a lines-completion (B2 fixture; in B3 alone the values are seeded by a raw projection update and the SYS event raw-inserted, the ONLY allowed hand-seed, marked as such and replaced in B2 per CO-2) assert on all five routes that no `_sys` key is present, non-reserved variables intact, history page size/cursor unchanged, `EXECUTION_ERROR` payload `variables` stripped; `routers_variables_helper_test.exs`: AST guard with synthetic negatives. |
| **CO-2** | Projection-seeded tests use the real writer | B2 | tests retire `hold_engine_values!/3` (`sys_namespace_sources_test.exs:145`) and `sys_event!/3` (`reconstruction_sys_test.exs:98`) in favour of a fixture `EntityWritesFixture.complete_with_lines!/1` that activates a definition with an append-only writable type and completes the task through `Engine.complete_task/3` | `sys_namespace_sources_test.exs` sources (3a), (3b), (4) and `reconstruction_sys_test.exs` re-driven; a grep test asserts neither helper name remains and no test calls `Repo.update_all` on `variables` with a `_sys` key outside the one B3 fixture. The raw-insert helper `insert_raw_event!/4` stays ONLY for malformed/wide-tier cases (#2621). |
| **CO-3** | `writable?/1` filter before `prepare/2` | B2 | 7.3 P1 (inside `prepare/2`, because the engine cannot name `ProcessWritable`) | `step_writes_prepare_test.exs` (edit): type with active definition but no flag -> no `entity_type_instances` row; with flag -> row; managed type with the flag key present -> no row. |
| **CO-4** | `SET LOCAL` in sandbox savepoints | B2 | 9 "SET LOCAL scope"; test-support helper `reset_local_timeouts!/0` (`RESET lock_timeout; RESET statement_timeout`) in `setup` of every module that asserts the no-SET-LOCAL property; statement-log capture filters by call window; contention/timeout modules `:auto` mode, `async: false` | the "no lines issues none" case runs first in its module and after `reset_local_timeouts!/0`; a meta-test runs it AFTER a lines-completion in the same sandbox test to prove the capture window (not the global session state) is what is asserted. |
| **CO-5** | `validate_lines/2` refuses a missing/non-string `entity_type` before `prepare/2` (#2633) | B1 | 6.1, 6.2 (`:entity_type_missing`); D-B.7 keeps `prepare/2` lenient and documents it | `entity_type_missing_test.exs`: key absent, `nil`, integer, `""`, `"   "` each -> `%{index: i, code: :entity_type_missing}`; ordering test: definition with one valid and one missing-type line -> activation fails, a spy port (configured through `:entity_port`) records ZERO `prepare/2` calls and no `entity_type_instances` row exists; `prepare/2` with the missing-type line returns `:ok` and creates nothing for it (pins "lenient"); valid lines behave as before. |
| **CO-6** | Dotted `output_record_id_var` refused (#2621 constraint 1) | B1 | 6.1 strict shape, both keys <= 160 bytes | cases `_sys.a.b`, `_sys.a.seq`, `_sys.`, `_sys`, `x`, name of 152 bytes (id key 157 ok, `.seq` key 161 refused), 151 bytes accepted; and an engine test (B2) that a 151-byte name's two keys both pass the strict `put_sys/3` and the registry guard. |
| **CO-7** | Replayed `_sys` state is wide-tier | B2 | 9 "Replay"; moduledoc note in `StepWrites` and `VariableMerge`: "a replayed `_sys.<name>` may hold a non-UUID string or any non-negative integer; a reader must apply `check_sys_entry/2` and treat failure as a refusal, never assume UUID/int64"; PR B has no reader (update/delete refused), so the note and the test are the deliverable | `reconstruction_sys_test.exs` new case: raw-inserted pre-change wide event `%{"_sys.line_0.id" => "any string", "_sys.r.seq" => 3}` -> rebuilt variables byte-identical to the committed golden map; event count before == after (no append, repair or rewrite); a second case for the 41-key event stays. |
| **CO-8** | QA `_sys` re-count gate | B2 (before merge) | Not code. Operator-run read-only counts, per tenant schema, exactly as in A design 16 OQ-1 (instances with a top-level `_sys` key in projections, in the five payload maps of `INSTANCE_STARTED`/`TASK_COMPLETED`/`SUB_PROCESS_COMPLETED`/`SERVICE_TASK_COMPLETED`/`SCRIPT_TASK_COMPLETED`, and the `$ref` payloads in `event_payload_store`) and the 2A.5 queries (`definitions_mentioning_sys`, `scripts_with_reserved_inputs`). Required result: all zero. Result recorded in B2's PR body with the QA run record id. The supervisor requests the run (OQ-B1); B2 does not open its PR without it. A non-zero result blocks B2 until each instance/definition is cancelled, repaired or re-versioned. | PR-body statement; no test. |
| **CO-9** | `%StepSource{}` (#2627) | not in B | D-B.19: B2 keeps a plain validated map built at one site; #2627 is taken first in PR C (second producer: `dispatch_id`) | none in B; B2's PR body links #2627 and states the decision. |
| **CO-10** | `applied_event_type/0`, `check_boundaries`, SEC F8 | B2 | The engine appends the APPLIED event through `EntityPort.applied_event_type/0` and the SYS event through `VariableMerge.sys_event_type/0`: no event-type literal enters `engine.ex`, so the literal allow-list of `put_sys_callers_test.exs` is UNCHANGED; the put_sys-CALLER allow-list gains `lib/letflow/engine.ex`. `engine.ex` and `definitions.ex` reference `Letflow.Engine.EntityPort` only (Rule 6 green). Static rule (SEC F8): write callbacks (`prepare`, `validate_lines`, `multi`, `interpret_failure`) stay unreachable from `lib/letflow/scripts/**` and `script_task_dispatcher.ex`. | `mix letflow.check_boundaries` output quoted in the PR body; `entity_port_boundary_test.exs` (edit): `@write_names` gains `:interpret_failure`; synthetic negative `port.interpret_failure(s, r)` under `lib/letflow/scripts/fake.ex` -> violation; `put_sys_callers_test.exs` (edit): `@put_sys_callers` gains `engine.ex`, event-literal set equality unchanged; behaviour fixtures (`script_task_fixture.ex:421`, `script_reads_test.exs:430`) delegate `interpret_failure/2`. |

## 12. Invariants

* **I-B1** A definition with an `entity_writes` node is ACTIVE only if every line passed `validate_lines/2` on that activation path AND `activated_by` was recorded in the same transaction.
* **I-B2** A completion with lines writes nothing unless every line, `_sys`, both events, audit and the task completion commit together; an execution error from `:merge` or `:transition` writes no record.
* **I-B3** `_sys` values are set only by strict `put_sys/3` (engine step) or `put_sys_replayed/3` (replay); never from line data, request, form or response.
* **I-B4** The engine names no `Letflow.Entities` module; `definitions.ex` and `engine.ex` reach lines only through `Letflow.Engine.EntityPort`.
* **I-B5** Authority is the literal `:tenant`; a managed type is never a declarative target, at activation or run time (read from the definition ROW, never from the node).
* **I-B6** The 20-line cap, create-only and append-only are enforced at activation AND at run time on the pinned snapshot and the CURRENT definition.
* **I-B7** Entity-type locks are taken only inside `:entity_writes` in `(entity_type, declared index)` order, after `tasks` and `instance_projections`, before every tail write.
* **I-B8** No client-visible variable map, history item or timeline item carries a reserved key or the two engine event payloads' record ids (CO-1).
* **I-B9** A replayed `_sys` value is never assumed to be a UUID or an int64 by any reader.
* **I-B11** `process_definitions.activated_by` is written only by the three activation paths; no create/update changeset casts it (a `POST`/`PUT /definitions` body key `activated_by` is dropped).
* **I-B10** A refusal body is one stable code plus the declared line index; no field name, field value, entity name or managed/scope detail.

### 12.1 Security invariants (`security-invariants.md` numbering)

| INV | How PR B satisfies it |
|---|---|
| INV-1 | `prefix` from `scoped_opts` (server context) everywhere; the activator and completer ids come from `auth_context`; no line field selects a schema or tenant |
| INV-2 | No field value in any event, audit entry, log or refusal; B3 strips `_sys` from every client-visible variable map and history payload; allowlist maps preserved |
| INV-3 | Lines are definition data, not scripts; write callbacks unreachable from `lib/letflow/scripts/**` (CO-10) |
| INV-4 | Secrets by reference only: PR B stores and returns no secret (`activated_by` holds ids, role names and permission names) |
| INV-9 | N/A: no outbound URL is validated or stored |
| (error hygiene) | Not INV-4: rescues map to atoms, `entity_write_failed` logs a step atom only, no exception text reaches a response (INV-8) |
| INV-5 | One `write_not_permitted` body for managed, not-writable, not-append-only, scoped, not-authorised, field-restricted and not-found (D-B.17); detail only in the tenant audit entry |
| INV-6 | New data-access paths stated for SECURITY-REVIEWER: pre-transaction plan reads, `activated_by` write/read, `check_entity_writes` reads, per-line writes via `command_multi/3`, history filter |
| INV-7 | SET LOCAL statements are compile-time constants (A3 mechanism reused); no interpolation; `ScopeNodePaths.lock!/1` not called |
| INV-8 | New clauses are explicit (no catch-all swallowing); `put_sys/3` returns tuples; contention is typed; the 2-tuple result has its own clause |
| INV-10 | No new permission, no new route; `:EntitiesRecordsWrite` evaluated at activation; effective-permission golden file unaffected |

0054 threats: T-1 (managed type, incl. becomes-managed-after-activation) covered by 7.4 steps 5-6
and B-12; T-2 by the per-type flag, recorded pairs and field restrictions; T-4 by A2 plus B-10;
T-5 vacuous (no update/expected); T-6 by 7.2 and 9; T-7 by D-B.17 and CO-1; T-8 by create-only on
append-only; T-9 by I-B3 and B-14; T-3 and T-10 by D-B.18 and D-B.20 (fences).

## 13. Files touched per PR

**B3**: `routers/instances.ex`, `routers/tasks.ex`, `instances.ex`, `api/response.ex`, tests
`test/letflow/routers/sys_variables_response_test.exs`, `routers_variables_helper_test.exs`.

**B1**: `engine/entity_port.ex` (types, moduledoc), `entities/step_writes.ex` (`validate_lines/2`,
`normalize_line/1`, predicates, gate), `definitions.ex` (`check_entity_writes/3`, option, three call
sites, `activated_by` write), `definitions/process_definition.ex` (field, activation changeset),
`definitions/promotion.ex`, `definitions/activator.ex` (new), `routers/definitions.ex`,
`routers/promotions.ex`, `routers/tenants.ex` (activator option, 422 clause), `api/response.ex`,
migration `priv/repo/migrations/<ts>_add_activated_by_to_process_definitions.exs` plus its entry in
`tenant_provisioning.ex`, tests (`entity_writes_activation_test.exs`,
`entity_writes_managed_type_test.exs` activation half, `entity_type_missing_test.exs`,
`entity_writes_activator_test.exs` recording half, edit `step_writes_prepare_test.exs`).

**B2**: `engine.ex` (plan phase, SET LOCAL step, `:entity_writes` placement, tail steps, fold,
`run_transaction/2`, `interpret_complete_result/3` clauses, `complete_error`, EE-12 sentence 4
reword), `engine/entity_port.ex` (`interpret_failure/2`, contexts), `entities/step_writes.ex`
(`multi/3`, `interpret_failure/2`, `prepare/2` filter, gate removed), `entities/entity_port_impl.ex`
(delegate), `entities/records.ex` (D-B.9 only), `routers/tasks.ex` (error clauses),
`api/response.ex` (`entity_write_refused/3`), tests listed in 11.1/11.2, fixtures
`test/support/script_task_fixture.ex`, `test/letflow/entities/script_reads_test.exs`,
`test/letflow/engine/put_sys_callers_test.exs`, `entity_port_boundary_test.exs`,
`records_command_multi_test.exs`, `sys_namespace_sources_test.exs`, `reconstruction_sys_test.exs`,
a new `test/support/entity_writes_fixture.ex`.

Docs touched: `docs/guides/adding-an-application-module.md` gets a short "process-writable types
and entity_writes" paragraph (B1); `docs/status` and requirement bookkeeping by DOC-UPDATER.

## 14. Migration, seed and inventory pins affected

| Item | PR | Effect |
|---|---|---|
| Tenant migration: `ALTER TABLE process_definitions ADD COLUMN activated_by jsonb NULL` | B1 | new file + `TenantProvisioning` entry (pattern of `20261015000001`); existing tenants get it at boot replay; NOT a new table, so `@expected_tenant_tables` (`test/support/tenant_fixture.ex`) is unaffected; the tenant-template staleness anti-pattern applies: run the template rebuild locally |
| Event types | none | `INSTANCE_SYS_VARIABLES_SET` and `TASK_ENTITY_WRITES_APPLIED` already seeded (A1); seed counts 22/19 unchanged |
| `step_source.definition_version` integer -> string | B2 | edits `records.ex` and `records_command_multi_test.exs` (the A2 tests pin integers) |
| `StepWrites` fail-closed pins | B1, B2 | `step_writes_prepare_test.exs:216-250` asserts `:entity_writes_not_enabled`: edited in B1 (validate) and B2 (multi) |
| Behaviour fixtures | B2 | `RecordingReadPort`, `ClearFlagThenReadPort` gain the new delegate |
| `put_sys_callers_test.exs` | B2 | caller allow-list adds `engine.ex` (reviewed diff, as A1 said) |
| Definitions/test suites that hand-build definitions and activate | B1 | anti-pattern "a validator that began refusing at activate broke already-merged test files": B1 greps the WHOLE `test/` tree for `entity_writes` (today only A-series tests mention it) and runs every file that activates hand-built definitions |
| Pre-merge inventories | B1, B2 | (a) count of definition rows (any status) with a node attribute `entity_writes` per tenant, must be zero or each reviewed; (b) CO-8 `_sys` counts, must be zero. Operator-run, read-only, constant SQL, quoted tenant schema from the registry; results in the PR bodies |
| EE-12 moduledoc | B2 | one sentence reworded (D-B.2); `engine_concurrency_test.exs` unedited |

## 15. Open questions: rulings (supervisor, 2026-10-15, binding)

* **OQ-B1 CLOSED: yes.** The infra QA `_sys` re-count run (CO-8) is requested before B2's PR; B2's body quotes the record id.
* **OQ-B2 CLOSED:** `needs_reactivation` is a refusal stub only (409, task stays pending, no new task status). Recovery path in 7.3; the real status and in-place re-activation are a follow-up (16).
* **OQ-B3 CLOSED:** a 10 s guard trip is `entity_write_contention`, HTTP 503, retryable.
* **OQ-B4 CLOSED:** history drops `record_id` and `event_global_seq`; the audit entry keeps them (section 10, test B-11).
* **OQ-B5 CLOSED:** a stale `expected` is unreachable in the create-only MVP; B2's `StepWrites` moduledoc and the REQ-499 entry in `docs/requirements.yaml` (DOC-UPDATER) say so.
* **OQ-B6 CLOSED:** vacuous named predicates for scoped types until 0051; B2's PR body states this as the pilot limit.
* **Verification items (not rulings).** ELIXIR-DEV confirms with a `lock(` grep that the `:transition` prepare call tree takes no `FOR UPDATE` (D-B.2); confirms `check_boundaries` is green with the engine -> `Letflow.Identity` edge (7.3); confirms the `send_json` envelope carries `line_index` as designed.

## 16. Deferred (not PR B)

* **PR C (SERVICE_TASK):** sentinel-actor proof (`platform_actor_id/0` on an entity stream),
  nested-Multi composition at `do_persist_service_task_advance/10`, dispatch-keyed
  `sys:step:<dispatch_id>:<i>`, service-path contention and `SET LOCAL` proof, lock-order proof
  against `complete_task`, `source.dispatch_id`, activator as the field-restriction subject (D4c),
  platform-actor scope ceiling; `%StepSource{}` (#2627) is its first commit.
* **#2590 / REQ-501:** module write handlers, `owner_module` stamp, manifest hash, `PinRebind` rule;
  `#2583`'s `Records.*` managed guard is its dependency, not B's.
* update/delete lines, `expected`/`record` from `_sys`, hook 2, script outputs as commands
  (#2534 7c), after-commit triggers, org-relative assignment, the `(instance, node, attempt)` stock
  business key (WMS slice 5).
* **Follow-up (file with B2):** a real `needs_reactivation` task status, inbox/UI filtering and an in-place re-activation flow for an ACTIVE definition (the stub's recovery today is cancel or rollback re-activation, 7.3).
* `%StepSource{}` (#2627) as PR C's first commit.
* Save-time structural check (Graph CHK-31), solution-pack path to a process-writable type (#2619),
  type classification replacing the denied-name list (#2618).
* Rule 3a lock code and scoped-type ceiling read (0051 `scope_node`, OQ-B6).

* **B3 follow-ups (from the B3 gates).** (F2) `Response.public_event_payload/2` is an allowlist by event type and key: a new map-valued event payload key carrying variables needs the helper and a test update. (F3) B2 must keep `_sys`-derived values out of instance-event `metadata` (history/timeline emit `metadata` verbatim).
