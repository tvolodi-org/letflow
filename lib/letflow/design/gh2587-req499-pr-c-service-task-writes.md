# GH #2587 / REQ-499 PR C: SERVICE_TASK path of process-step entity writes (decision 0054)

Author: CODE-DESIGNER, 2026-10-16. Branch `design/GH-2587-pr-c`, from `origin/main` `53ad1cd9`
("feat(GH #2587): REQ-499 PR B2 HUMAN_TASK completion applies declarative entity writes", #2645).
Scope: issue #2587 "Group C: SERVICE_TASK path", the `%StepSource{}` struct (#2627, PR C's first
commit per the supervisor ruling), the PR B deferral list (`gh2587-req499-pr-b-human-task-writes.md`
section 16). #2590 / REQ-501 (module write handlers) is OUT of PR C; section 4 D-C.16 records the
interaction.

Design only. Signatures, type shapes, step lists, tables and test briefs; no function bodies.

## Changelog

### Revision 2 (2026-10-16): CDV re-check N1-N3

| Id | Change | Where |
|---|---|---|
| N1 | The landing performs an EXPLICIT `event_idempotency` read under the dispatch and projection locks before `ExecutionError.append_multi` (the false "collision answers already_final" premise is removed: `EventStore.append/2` returns the original event as `{:ok, _}` and ExecutionError would raise or flip a committed success); new landing-against-existing-key test; script route covered by the CAS (`:stale`) | D-C.8 b, 7.5, 8, 9, C-4 |
| N2 | Script deadline read from the CAS row `lease_expires_at` in P0; deadline is an attempt-start gate with a 15 s worst-case bound and a guard of `min(10 s, remaining)`; behaviour at remaining <= 0 and the always-run landing stated | D-C.9 |
| N3 | C-4 log capture scoped to the dispatcher call | C-4 |
| nit | 5.1/5.2/D-C.2 relabelled "C0 target, as reworked" | 5.1, 5.2 |

### Revision 1 (2026-10-16): CDV FAIL (4 majors, 4 minors) and supervisor rulings applied

| Id | Change | Where |
|---|---|---|
| M1 | The duplicate-apply read moves to immediately after the dispatch/CAS row and projection locks, BEFORE graph and token reads; key present + token missing and `instance_not_active` + key present both answer `already_final` | 7.1, 7.2, D-C.10, C-4, 9 |
| M2 | The ERROR landing gets the same bounded contention retry; the landing reads the completion key explicitly (a collision is NOT relied on, N1); I-C2 is qualified with the crash window; residual stated | D-C.8, D-C.9, 7.5, 8, 12 |
| M3 | Inventory (a) moves to C2's merge gate and covers in-flight instances' PINNED snapshots; "no window" claim corrected for pre-B1 rows | 1.3, 6, 14 |
| M4 | C0 re-stated to match the implemented `StepSource` (atom-keyed map only, optional `kind`, no `new!/1`, `origin/1` kept because C2 needs it, `step_source_callers_test.exs`, build-failure mapping) | 5.1, 5.2, D-C.2, I-C8, C-16 |
| m1 | Script route plan-only contention rescue sits inside the existing blanket rescue; HTTP entry rescue is new | 7.5 |
| m2 | Re-apply total deadline tied to the lease; lease-sweep interaction analysed | D-C.9, 9, C-14 |
| m3 | C-8 gains the "lines but no plan" case | 11.1 |
| m4 | Non-entity-write apply stall keeps its ISS-0928 reference | 8, 16 |
| Rulings | OQ-C1..OQ-C8 closed per supervisor; OQ-C8 itself resolved by GH #2648 (the cascade now exists on the service apply) | 15 |

### Revision 0 (2026-10-16): first design

First version. Written against `main` `53ad1cd9`; every file:line below was re-read on that tree
(section 2). Thirteen findings (section 3) change or sharpen the issue text, the largest being F-C1:
a SERVICE_TASK completion is not a request, so a refusal has no client, no "task stays pending" and
(on the HTTP route) no retry of the external call. Eight questions need a supervisor ruling
(section 15).

## 1. Summary, sizing and proposed split

### 1.1 What PR C delivers

A SERVICE_TASK node may declare `entity_writes` (same line shape as HUMAN_TASK: up to 20 `create`
lines on `writable_by_process`, append-only, non-managed types; `var` and `const` sources). When the
service call's result is applied (HTTP route: the 2xx body; script route: the script output), the
lines run in the SAME Postgres transaction as the apply: SET LOCAL timeouts, the lines through
`Records.command_multi/3` (authority literal `:tenant`), the engine-only `_sys.*` values, one
`INSTANCE_SYS_VARIABLES_SET` and one `TASK_ENTITY_WRITES_APPLIED` instance event, the
`SERVICE_TASK_COMPLETED` / `SCRIPT_TASK_COMPLETED` event, the projection write and one tenant audit
entry per line. Any refusal rolls all of it back, and the instance lands in ERROR with a DLQ entry
(D-C.8) instead of stalling.

### 1.2 Size: cannot be built and reviewed in one agent turn

Touch count (section 13): a new entity module and a `Records`/`StepWrites` contract edit (C0);
`engine.ex` plan phase, outer-transaction wrapper, Multi composition inside
`do_persist_service_task_advance/10`, tail, `_sys` fold, error classification, two ERROR-landing
paths, the contention re-apply loop, `entity_port.ex` context change, `StepWrites.multi/3` origin
union, size caps and about 10 new test files (C2); one activation fence plus the test flips (C1).
Recorded reason for the split (core-directives "Merge Discipline" item 1): three surfaces with
different gates (type safety of provenance, the transaction composition, the activation switch), each
a coherent review unit.

### 1.3 Proposed split, serial. Merge order C0 -> C2 -> C1 (NOT C0 -> C1 -> C2)

| PR | Name | Contents | Independent value | Depends on | Gate before merge |
|---|---|---|---|---|---|
| **C0** | `%StepSource{}` struct (#2627) | New `Letflow.Entities.StepSource` (`@enforce_keys`, `new/1`, `idempotency_key/1`, `to_metadata/1`); `command_multi/3` and `StepWrites` accept and build only the struct; `line_key` and `idempotency_key` derived from it; git-grep test that no literal source map remains; flat `source.*` metadata byte-identical | Type safety of provenance before the second producer origin exists; removes a real gap (today nothing checks that the `sys:step:` key embeds the same id as `source.task_id`); zero behaviour change | none | REVIEWER (SECURITY optional) |
| **C2** | Dispatch-time composition | Everything in section 7 for both routes: plan phase, SET LOCAL, `:entity_writes` inside the nested Multi, `_sys` fold, tail events and audit, contention re-apply, ERROR landing, sentinel-actor proof test, lock-order and replay tests. The activation fence of C1 is still in place, so no NEW definition can reach it; but see the pre-B1 window below | Reviewed "dark": the whole security-sensitive composition lands before anything can switch it on; fails closed for every row without a valid `activated_by` | C0, the OQ-C8 confirmation test, inventory (a) result zero | SECURITY-REVIEWER, REVIEWER (engine -> entities edge unchanged; EE-12 reword) |
| **C1** | Activation switch-on | `check_entity_writes/3` accepts `:SERVICE_TASK`; test flips; pre-merge inventory; docs paragraph | The feature, for definitions | C0, C2 merged | SECURITY-REVIEWER (activation is the authorization gate), REVIEWER |

**Pre-B1 window (CDV M3, corrected).** C2 is NOT behaviour-neutral for every existing row. A SERVICE
node that carries an `entity_writes` attribute from BEFORE B1 (when the attribute was silently
inert) is ACTIVE today and its lines are ignored. After C2, P0 reads those lines: an ACTIVE row
without `activated_by`, or any in-flight instance whose PINNED snapshot has such a node, lands in
ERROR + DLQ at its next apply. Therefore inventory (a) of section 14 is C2's merge gate (not C1's),
and it counts both definition rows (any status) and the pinned snapshots of non-terminal instances.
The required result is zero; a non-zero row is cancelled, repaired or re-versioned first. The result
is quoted in C2's PR body.

Why C2 before C1 (the requester's order was C1 validation, then C2): if C1 merged first, a
definition with SERVICE_TASK lines would ACTIVATE while the apply path silently ignored the
`entity_writes` attribute (exactly the hole B1 closed with a gate flag that B2 had to delete). With
C2 first there is NO flag and NO seam: the single activation fence already on `main`
(`definitions.ex:2587`) is the gate, and C1 is a few lines plus tests. If the supervisor prefers the
literal order C0 -> C1 -> C2, C1 must carry a run-time fail-closed refusal on the apply path (lines
present, no plan -> ERROR), deleted by C2; that is strictly more churn (OQ-C1).

Cut line if ELIXIR-DEV's estimate says C2 is over one turn: **C2a** = shared seam plus the HTTP
route (sections 7.1-7.8 for `advance_after_service_task_outcome/4`); **C2b** = the script route
(`apply_script_task_result/3`: plan from the claim, the second-transaction landing, detail atoms).
The seam is one function (`do_persist_service_task_advance/10`) driven by a descriptor key, so C2a
leaves the script route's descriptor without a plan; because the C1 fence is still closed, that is
unreachable, but C2a's PR body must say so and C1 must not merge before C2b. Do not cut the sentinel
proof or the ERROR landing out of C2.

## 2. Sources and verification (all on `main` `53ad1cd9`)

| Fact | Where |
|---|---|
| HTTP apply entry: `advance_after_service_task_outcome/4`; `{:advance, body}` clause opens `repo.transaction(fn -> ... repo.rollback(reason) end)`; `{:give_up, _}` clause calls `set_instance_error/2` through `give_up_service_task_dispatch/3` | `engine.ex:4276-4303`, `:4861-4868` |
| `advance_service_task_dispatch/4`: dispatch row `FOR UPDATE` (`:4370`), then `fetch_and_lock_instance_projection/3` (`:3265`), `fetch_graph/2` (`:3316`), tokens, `VariableMerge.merge(seed.variables, decoded_body, nil)` (nil validations) at `:4325`; reserved-key rejection -> `persist_service_task_reserved_key_error/6` (`:4346-4355`, `:4602-4631`); other rejection -> `{:error, {:variable_merge_rejected, _}}` (`:4357`); `status` is NOT changed by the apply, it stays `"advanced"` | `engine.ex:4312-4366` |
| `dispatch_ref/1`, `completion` descriptor type (`event_type`, `event_payload`, `idempotency_key`, `on_advanced`, `on_no_matching_edge`, optional `incident_variables`), `http_completion/2` (`SERVICE_TASK_COMPLETED`, key `service_task_dispatch:<id>`) | `engine.ex:4386-4427` |
| `persist_service_task_advance/10` (shared by both routes): hop chain, no-matching-edge -> `persist_service_task_no_matching_edge/7` (own Multi, commits ERROR, no completed event) | `engine.ex:4460-4546`, `:4567-4595` |
| `do_persist_service_task_advance/10`: prepares (`prepare_timer_arms`, `prepare_service_task_dispatch_abort_on_empty_url`, `prepare_sub_process_children_for_completion`) then ONE Multi: hop-chain token records + task activation + reconcile, timer arms, dispatch rows, sub-process children creation, `:service_task_completed_event`, `completion.on_advanced`, `:projection`; NESTED `repo.transaction(multi)` at `:4793`; failure returns `{:error, reason}` and DROPS the failed step name (`:4797-4813`); function-level `rescue exception -> {:error, {:transaction_failed, exception}}` (`:4820-4822`); `{:execution_error, _}` outcome -> `{:error, {:execution_error_not_supported_for_service_task_advance, _}}` (`:4816-4817`) | `engine.ex:4665-4823` |
| `append_service_task_completed_event/3`: `EventStore.append/2`, actor `EventStore.platform_actor_id()`, key from the descriptor | `engine.ex:4833-4848` |
| Script route: `apply_script_task_result/3` is ONE `Repo.transaction` with a function-level `rescue _ -> {:error, :raised}`; CAS on `(id, instance_id, node_id, attempt, status = 'running')` `FOR UPDATE`, then the projection lock; `apply_locked_script_result/5` merges with REAL variable validations (`:4963`) and calls the same `persist_service_task_advance/10` with `script_completion/5` (`SCRIPT_TASK_COMPLETED`, key `script_task_dispatch:<id>:<attempt>`, `on_advanced` appends the run record and finishes the row) | `engine.ex:4896-5048` |
| `script_failure/7`: ExecutionError + `SCRIPT_RUN_RECORDED` + row `failed`, one nested Multi, reason is a fixed sentence per code, details are codes only | `engine.ex:5053-5107` |
| HTTP dispatcher: the dispatch row is committed `"advanced"` by `handle_success/3` BEFORE the apply (`:1213-1220`); the poller claims `"pending"` rows only (`:428`), so an `"advanced"` row is never re-claimed (at-most-once HTTP) | `service_task_dispatcher.ex:428`, `:1213-1220` |
| Dispatcher post-apply: `{:error, reason}` is logged with a classified atom and best-effort audited as `service_task.advance_failed`; "the dispatch row is deliberately NOT reverted to retry" | `service_task_dispatcher.ex:578-679` |
| Script dispatcher: a failed apply is followed by ONE follow-up apply `{:failed, :script_rejected, :apply_failed, _}` (terminal ERROR) through the same CAS; `detail()` is a closed type | `script_task_dispatcher.ex:433-459`, `:85-110` |
| Sentinel: `@platform_actor_id` / `platform_actor_id/0`; `events.actor_id` is `uuid NOT NULL` with NO foreign key (comment: "`users` lives in the public schema") | `event_store.ex:963-985`; `priv/repo/migrations/20260816120001_create_events.exs:47,80`, `20260922000001_create_events_partitioned.exs:59` |
| Audit `actor_id` has no FK; the service path already writes audit rows with the sentinel | `20260830020001_create_audit_entries_tenant_scoped.exs:49`; `engine.ex:6702-6717` via `service_task_dispatcher.ex:671-676` |
| B2 plan phase, activator re-validation, SET LOCAL step, `run_transaction/2`, `_sys` fold, tail events and audit | `engine.ex:2589-2631` (entry), `:2811-2920` (`plan_entity_writes/3`, `recorded_activator/1`, `check_activator_active/2`), `:2922-2979`, `:2985-3019`, `:3024-3157` |
| `StepWrites.multi/3`, `build_lines/3`, `build_line/4` (source map literal at `:546-555`, key literal at `:545`), `check_restrictions/3` (subject = `ctx.actor_id`), `process_policy/1`, `assemble_result/3`, `interpret_failure/2` | `entities/step_writes.ex:463-478`, `:480-561`, `:609-619`, `:621-634`, `:636-661`, `:695-734` |
| `Records.step_source` map type (`task_id` XOR `dispatch_id` already supported), `step_command` (`line_key`, `idempotency_key`), `check_step_command/1`, `check_line_key/1`, `step_source_metadata/1`, `command_multi/3` | `entities/records.ex:256-277`, `:727-790`, `:572-640` |
| `check_entity_writes/3` and the node-type fence `node_type != :HUMAN_TASK -> [:entity_writes_node_type_not_supported]`; `validate_lines/2` call with `node_type` in the ctx; `entity_writes_activated_by/3` is node-type agnostic | `definitions.ex:2449-2484`, `:2576-2627`, `:2527-2542` |
| `EntityPort` `multi_ctx` (required `task_id`, `actor_id`, `activator_id`, `authorized`, `variables`, `skip?`), `definition_ctx.node_type :: :HUMAN_TASK | :SERVICE_TASK`, `applied_event_type/0`, `interpret_failure/2` | `engine/entity_port.ex:67-140` (types), `:106` (`multi_ctx`) |
| `Activator.from_auth_context/2`, `build_record/3` (stored shape, no change needed) | `definitions/activator.ex:40-88` |
| Event schemas already admit the service origin: `TASK_ENTITY_WRITES_APPLIED` has `dispatch_id` (nullable) and `task_id` (nullable); `INSTANCE_SYS_VARIABLES_SET` payload is `node_id`, `cause = "entity_writes"`, `values` | `tenant_provisioning.ex:1392-1440` |
| Replay: `INSTANCE_SYS_VARIABLES_SET` folds through `put_sys_replayed/3`; `TASK_ENTITY_WRITES_APPLIED` changes nothing | `engine/reconstruction.ex:806-835` |
| API shaping: `Response.public_variables/1`, `public_event_payload/2` (APPLIED payload reduced; `dispatch_id` already in the allowlist) | `api/response.ex:64-140` |
| DLQ API serialises `reason`, `full_reason`, `error_detail`, `source_payload`, `context_json` verbatim | `routers/dlq.ex:211-232` |
| `ExecutionError.error_type` is an OPEN atom type; `error_detail` is whatever `details` the caller passes; EXECUTION_ERROR payload carries `variables` | `engine/execution_error.ex:99-110`, `:240-255` |
| String fields carry no `maxLength` (the validator "never emits" it); no HTTP response size cap found in `service_task.ex` or the dispatcher | `entities/record/validator.ex:64,106`; `grep` of `engine/service_task*.ex` for body/size limits: none |
| Script-bound SERVICE_TASK nodes are identified by the node attribute `script_key` | `scripts/runtime.ex:160-165` |
| No external service-task callback route exists: `advance_after_service_task_outcome/4` and `apply_script_task_result/3` are called only by the two in-process dispatchers | `grep` of `lib/` (callers: `service_task_dispatcher.ex:579`, `script_task_dispatcher.ex:434,444,783`) |
| Sub-process completion cascade (`append_sub_process_completion_cascade_multi/6`) is composed in the HUMAN_TASK tail ONLY; `do_persist_service_task_advance/10` has no call to it | `engine.ex:6072`, `:6116-6170`; absent in `:4665-4823` |
| Test seam for golden step names exists for HUMAN_TASK only | `engine.ex:2637-2662` |
| Literal source-map sites to convert | `step_writes.ex:546-555`; tests `records_command_multi_test.exs:107`, `records_reserved_keys_test.exs:203`; flat-metadata assertions `records_command_multi_test.exs:213`, `entity_writes_gates_test.exs:236` |

### 2.1 Sibling write-path enumeration (anti-pattern "a gate-approved design missed a sibling write path")

Every path that completes or advances a node and can therefore reach an entity-write composition:

| Path | Composes entity writes | Note |
|---|---|---|
| HUMAN_TASK completion `run_complete_task/6` | yes, PR B2 | unchanged |
| HTTP SERVICE_TASK apply `advance_service_task_dispatch/4` -> `persist_service_task_advance/10` | yes, PR C2 | |
| Script SERVICE_TASK apply `apply_locked_script_result/5` -> `persist_service_task_advance/10` | yes, PR C2 (cut line C2b) | same descriptor seam |
| Timer fire `advance_after_timer_fired/3` / `persist_timer_fired_advance/7` | NO | 0054 D12: no entity write from timers |
| Escalation, cancellation, `set_instance_error/2`, `give_up_service_task_dispatch/3` | NO | D12 |
| `create/2` initial hop chain reaching a SERVICE_TASK | NO (it only inserts the dispatch row; the write happens at apply) | |
| Sub-process child completion cascade | NO new composition here; GH #2648 later added the cascade to the SERVICE/script apply (F-C10 resolved) | |
| Replay / reconstruction / projection rebuild | NO (D11) | |

Lines are therefore read from exactly two node types, and a node's `entity_writes` is applied by
exactly one of the three composing paths, selected by the completion path that owns the node.

## 3. Findings from verification (each changes or sharpens the issue)

| Id | Finding | Consequence |
|---|---|---|
| **F-C1** | A SERVICE_TASK completion has no client and no pending task. On the HTTP route the dispatch row is already `"advanced"` (committed, at-most-once call) when the apply runs, and nothing re-claims an `"advanced"` row (`service_task_dispatcher.ex:428`, `:1213`). Today an `{:error, _}` from the apply leaves the instance ACTIVE forever; ISS-0928 only made it loud (`:637-647`: log plus audit). A data-dependent refusal (a field the response did not provide) would therefore be a silent stall of the instance and a lost external effect. | D-C.8: a refusal or internal failure of the entity step lands the instance in ERROR with a DLQ entry, in a second transaction after the first rolled back. |
| **F-C2** | After `repo.transaction(multi)` returns an error INSIDE the still-open outer transaction, the outer transaction cannot be continued (documented in `engine.ex:4798-4812`, ISS-0784: a write there "would roll back right along"). | The ERROR landing cannot reuse the `persist_service_task_reserved_key_error/6` shape (which commits in the open outer); it is a second `Repo.transaction` after the outer returned. |
| **F-C3** | `StepWrites.prepare/2` refuses inside a transaction (`step_writes.ex:102`) and the apply opens its transaction at its first line (`engine.ex:4288`, `:4897`). | D-C.6: the plan phase runs before the outer transaction, in the entry function, and rides to the persist function in the completion descriptor. |
| **F-C4** | The nested `repo.transaction(multi)` result drops the failed step name (`engine.ex:4797-4813`), and the function-level `rescue` turns a raised `Postgrex.Error` into `{:transaction_failed, exception}` (`:4820-4822`). `interpret_failure/2` needs the step name; contention classification needs the exception. | Two small, plan-only changes: return a tagged `{:entity_write_step_failed, step, reason}` when a plan exists; classify `{:transaction_failed, %Postgrex.Error{}}` / `%DBConnection.ConnectionError{}` in the entry function. Without a plan every byte of today's result is unchanged. |
| **F-C5** | There is no external completion callback: both routes are driven by in-process pollers, and the HTTP call is synchronous inside `attempt_dispatch`. A "duplicate completion callback" is a second apply of the same dispatch id, reachable only through a defect or a future callback route. | D-C.10: a duplicate apply is detected BEFORE the lines and answers `already_final`; the `sys:step:` key is the second line of defence, never an ERROR trigger. |
| **F-C6** | The DLQ API returns `reason`, `full_reason` and `error_detail` verbatim (`routers/dlq.ex:211-232`), and EXECUTION_ERROR carries `variables`. | The landing uses a fixed sentence and a value-free `details` map (`line_index`, public code, `dispatch_id`); `variables` is the PRE-merge state, so the response body is never copied into an error event. |
| **F-C7** | The script route already has a follow-up that converts ANY apply error into a terminal `script_rejected`/`apply_failed` (`script_task_dispatcher.ex:433-459`). A transient contention would become a permanent ERROR, and the entity-write cause would be lost. | D-C.9 / D-C.8: the engine re-applies contention itself (bounded) and lands refusals itself with a specific detail atom; the dispatcher follow-up never sees an entity-write error. |
| **F-C8** | String fields have no `maxLength` and no HTTP response cap was found, so a service response can put an arbitrarily large string into a record (stored payload `$ref` above 4096 bytes). Type validation does not bound size. | D-C.7: a run-time per-value and per-line byte cap on the service origin. |
| **F-C9** | HTTP bodies are merged with NIL validations (`engine.ex:4325`): response keys are not checked against `variable_schemas`; the script route validates (`:4963`). The target entity type's validator is the only typing of a response-sourced field. | D-C.7: stated, not changed; the type validator (`validate_field_values`) and the size cap bound it. |
| **F-C10** | The service apply path has no sub-process completion cascade (section 2). A SERVICE_TASK that ends a sub-process child completes the child projection but never wakes the parent token (`find_waiting_parent_token`, `engine.ex:6128`, is reached only from the HUMAN_TASK tail). This is pre-existing and not caused by PR C. **RESOLVED by GH #2648**: the apply now runs `append_sub_process_completion_cascade_multi/6` in its own transaction (lock order child, then parent), so a service apply CAN be the cascade initiator; the 7.3 cycle analysis holds for the parent-side participant and the child side is the HUMAN path's order. | Consequence for PR C: the HUMAN-path cascade cycle of B 7.2 has a different partner here (7.3); and OQ-C8 asked for an ISS (confirmed by a running probe; fixed by GH #2648, after which a service apply can be the cascade initiator, see 7.3). |
| **F-C11** | The platform sentinel is already the actor of the service path's instance events and audit rows, and both columns have no FK, but it has never been used on an ENTITY-type stream (the synthetic per-type instance). Whether anything on that path reads `actor_id` as a user (projection, FieldGrants, Records result) is unproven. | D-C.4: the sentinel proof test is the first commit of C2 and a hard gate (0054 AC 22 / N8). |
| **F-C12** | `completion.on_advanced` runs AFTER `:service_task_completed_event` (`engine.ex:4782-4788`); the lines must run BEFORE it (the SYS event must precede the completion event for replay, D-A1.10) and BEFORE `:projection`. | A new optional descriptor key `entity_plan`; the composition is inline in `do_persist_service_task_advance/10`, not in `on_advanced`. |
| **F-C13** | The service path's entity-type locks are taken AFTER the hop chain's own writes (token records, task rows, dispatch rows, sub-process child streams), unlike HUMAN_TASK where `:transition` only computes. | 7.3: shown harmless (those rows are new rows or instance-mutex rows); the lock-order test asserts it. |

## 4. Decisions (one-line rationale each)

**Revision 3 notes (C2 review).** (1) D-C.9 guard budget is `min(10 s, remaining - 8 s)`, see D-C.9. (2) D-C.5 / 7.2: a `module_writes` attribute on a SERVICE_TASK node can only be a hand-edited snapshot (the activation fence refuses it for every node type but HUMAN_TASK); the plan phase refuses it fail-closed as `write_not_permitted` (audit detail `module_writes`, line index = the number of declarative lines), pinned by `service_task_entity_writes_test.exs`. (3) The ERROR landing for the HTTP route is ONE Multi (SET LOCAL, dispatch lock, projection lock, completion-key read, ExecutionError steps), not a nested transaction, so its failure classification is exact; the `entity_write.refused` audit entry is a THIRD, best-effort transaction after it.

* **D-C.1 Three PRs, order C0 -> C2 -> C1.** The switch-on is the last, smallest, separately gated step; no flag or seam is needed. (Section 1.3, OQ-C1.)
* **D-C.2 `%Letflow.Entities.StepSource{}` (C0 target, as reworked on `feat/GH-2627-step-source-struct`):** `@enforce_keys` on the always-present fields (`kind` included, the constructor supplies it), `new/1` taking an ATOM-keyed map only (closed key set, `kind` optional and defaulting to `"process_step"`, any other kind refused) and returning `{:ok, t} | {:error, :invalid_step_source}`, `to_metadata/1` producing the flat `source.*` map byte-identically, `idempotency_key/1`, and `origin/1` (kept: C2 needs the tagged origin for `multi_ctx`). No keyword input, no `new!/1`. `command_multi/3` accepts ONLY the struct, and re-runs `new/1` on it so a hand-built literal cannot skip validation. `line_key` and the `sys:step:` key are DERIVED from the struct and removed from `step_command` (OQ-C7 ruled). Build-failure mapping: an invalid source is `{:error, :invalid_step_source}` from `command_multi/3`, becomes `Multi.error({:line, i, :build}, :invalid_step_source)` in `StepWrites`, and `Records.classify_step_error/1` has no clause for it, so it falls to `:internal` -> `{:entity_write_failed, i, :build}` (500 on the human path, `entity_write_failed` landing on the service path); ELIXIR-DEV verifies in `records.ex` and the C0 test pins it.
* **D-C.3 Source identity on the service origin is the dispatch row id:** `source.dispatch_id`, idempotency key `sys:step:<dispatch_id>:<declared index>`. HTTP: `service_task_dispatches.id`; script: `script_task_dispatches.id` (a different table, same key shape; the two id spaces are UUIDv4 and `source.node_id` plus `source.instance_id` disambiguate). `attempt` is NOT in the key: at most one apply commits per dispatch id, by the `"advanced"` status plus `SERVICE_TASK_COMPLETED` key (HTTP) or the CAS `status = 'running'` (script). Rationale: 0054 D9.
* **D-C.4 Actor and subject.** The entity event `actor_id`, the instance events' actor and the audit entry's `actor_id` are `EventStore.platform_actor_id()` (there is no human completer, and the activator did not act at that time; 0054 D4). The activator is recorded in `source.activator_id` and in the audit `after_state`. The write-side field-restriction subject (D4c) is the ACTIVATOR (new `subject_id` in the port context). The sentinel proof test (C-1) gates C2.
* **D-C.5 Authority at run time is the recorded `activated_by`, re-validated as untrusted data in the plan phase** with the SAME private functions as B2 (`recorded_activator/1`: UUID user id, `EntitiesRecordsWrite` in the recorded permissions, well-formed pairs; `check_activator_active/2`: absent or inactive user row fails closed). A failure is NOT a 409 stub (nothing stays pending): it is the ERROR landing with public code `entity_write_needs_reactivation`. Rationale: F-C1; D4a.1, D4a.4.
* **D-C.6 One plan phase before the outer transaction, one descriptor key, one inline composition.** HTTP: in the head clause of `advance_after_service_task_outcome/4` (unlocked read of the dispatch row, graph, node, definition row, then `prepare/2`); script: in `apply_script_task_result/3` before `Repo.transaction`, from the claim. The plan rides in the descriptor as `entity_plan`. `SET LOCAL lock_timeout/statement_timeout` (2 s / 5 s, the B2 constants) are the FIRST statements of the OUTER transaction when a plan exists, so the dispatch-row and projection waits are bounded too. Rationale: F-C3, F-C12; D-B.11.
* **D-C.7 Values.** Field sources are the B shapes `{"var": name}` and `{"const": value}`, `var` read from the merged variables after the apply's merge (HTTP: body keys merged into variables; script: the declared output merged). No new source kind (`{"response": key}` is deferred). Run-time size caps on the service origin only, as NAMED CONFIG CONSTANTS (module attributes of `StepWrites`: `@service_value_max_bytes 65_536` per field value and `@service_line_max_bytes 262_144` per line, measured on the JSON encoding; a unit test pins the two numbers so a change is a reviewed diff): refusal `validation_failed` (no field name, INV-2). The HUMAN path is NOT widened in PR C (supervisor ruling); the follow-up is an entity-side per-record cap that replaces both origin-specific caps (section 16). `var` naming a reserved key is omitted exactly as in B (`resolve_values`), so a missing required field is the type's own `validation_failed`. Rationale: F-C8, F-C9.
* **D-C.8 Refusal and internal failure of the entity step land the instance in ERROR + DLQ, never a stall.** NEW PRODUCT BEHAVIOUR (supervisor ruling OQ-C3): a data-dependent refusal of a service task's entity write moves the instance to ERROR; it is stated as such in C2's PR body and in the operator runbook. The first transaction rolls back (nothing committed, dispatch row still `"advanced"` or CAS row still `running`); then the entry function runs a second transaction: HTTP: re-lock dispatch row (status `"advanced"` still) then projection, `ExecutionError.append_multi` with `error_type: :entity_write_refused`, `affected: {:node, node_id}`, fixed reason sentence, `variables` = the PRE-merge projection variables, `details: %{"line_index", "code", "dispatch_id"}`, idempotency key `service_task_dispatch:<id>` (mutually exclusive with the completed event); script: the engine re-enters `do_apply_script_task_result/4` with `{:failed, :script_rejected, :entity_write_refused, facts}` (the existing `script_failure/7` landing, run record and row `failed`). One best-effort tenant audit entry `entity_write.refused` (action shared with B; `resource_type "instance"`, `after_state` node, dispatch id, index, closed detail atom, no value). **The landing can itself fail (CDV M2).** (a) Contention in the landing transaction (lock wait on the dispatch or projection row, or a deadlock with a concurrent cancel) is re-run under the SAME bounded budget and deadline as D-C.9 (`SET LOCAL lock_timeout '2s'` is issued first in the landing too). (b) **An explicit key read, never a collision (CDV N1).** `ExecutionError.append_multi` does NOT fail on a claimed key: its event step calls `EventStore.append/2`, which returns the ORIGINAL event with `is_duplicate: true` as `{:ok, _}` (`event_store.ex:226-229`, `:892-911`); ExecutionError does not inspect it and would then raise on the original payload (`Map.fetch!(event.payload, "reason")`) or flip an advanced, still-ACTIVE instance to ERROR (its eligibility check refuses only completed, cancelled or error instances, `execution_error.ex:286-291`). Therefore the landing transaction performs an EXPLICIT `event_idempotency` read for the completion key, under the re-locked dispatch row and projection, BEFORE `ExecutionError.append_multi`: key present -> `{:ok, :already_final}` with no DLQ entry, no event and the instance untouched. No landing outcome relies on a collision. `instance_already_error` and `instance_terminal` from the eligibility check remain `{:ok, :already_final}` as a second line. On the script route the landing is the CAS apply (`status = 'running'`, same `FOR UPDATE`): a row already finished answers `{:ok, :stale}` and writes nothing. (c) `{:error, {:instance_not_active, _}}` at the projection lock is benign (cancel won). (d) Residual, stated: if the landing exhausts its budget, or the process crashes between the rollback and the landing commit, the dispatch row is still `"advanced"` and the instance ACTIVE with a lost token (the pre-existing F-C1 stall class); the entry function logs a classified atom and writes the `service_task.advance_failed` audit entry. Closing it needs the stuck-`"advanced"` sweeper deferred in section 16. Rationale: F-C1, F-C2, F-C6, F-C7.
* **D-C.9 Contention is re-applied by the engine, bounded, then lands as ERROR.** Contention (`55P03`, `57014`, `40P01`, connection error, the 10 s guard, `prepare/2` contention) rolls back; the entry function re-runs the whole apply (plan included) up to 3 attempts total with constant 100 ms and 300 ms backoffs (zero under the `:engine_test_seams` flag); exhausted -> D-C.8 with public code `entity_write_contention`. The same budget covers the landing transaction (D-C.8 a). **Total deadline (CDV m2, N2):** the loop has a wall-clock deadline: HTTP route 20 s from entry; script route `min(20 s, lease_expires_at - now - 2 s)` where `lease_expires_at` is read from the CAS row in P0 (set at claim, `script_task_dispatcher.ex:384`; the engine claim map carries no claim time, and `lease_ms/0` from function entry would overstate the remainder because the script already ran). The deadline is an attempt-START gate: an attempt starts only if the remaining budget is at least a stated worst-case attempt bound of 15 s (P1 <= 2 s + lock wait 2 s + statement 5 s + guard), and the 10 s wall-clock guard receives `min(10 s, deadline remaining - 8 s)` (revision 3, as implemented in `service_guard_budget_ms/1`). The 8 s is the pre-guard bound of the attempt: `prepare/2` (P1) is at most 4 s (2 s lock timeout + 2 s statement timeout) and the two row-lock waits before the guard starts (S1 dispatch/CAS row, S2 projection, each under the 2 s `lock_timeout`) are at most 4 s; the guard clock starts at `:entity_writes_started`, i.e. after both. With the attempt-start gate of 15 s the guard is therefore at least 7 s, and an attempt cannot overrun the lease by more than the one statement in flight. `script_deadline_at/2` anchors the deadline at the first P0 (before P1), so the 8 s subtraction is what keeps the guard inside it. If the remaining budget is <= 0 at entry, ONE attempt is made only when the route is HTTP (no lease); on the script route the entry goes straight to the landing. The landing runs ONCE after the deadline regardless (it is never skipped by the deadline; it has its own 2 s lock timeout and is bounded by D-C.8 (a)'s attempts only for contention). An overrun past the lease stays safe by the sweep-vs-late-apply argument below. Interaction with the lease sweep: the sweep applies `{:failed, :timeout, :lease_expired}` through the same CAS under `FOR UPDATE`; whichever of the sweep and a late re-apply commits first wins and the loser sees `{:ok, :stale}` and writes nothing, so exceeding the lease is wasteful but never a double write or a lost incident. The external call is NEVER repeated (at-most-once, ruling open point 6). There is no HTTP status on this path; the "503, retryable" of B maps to "re-applied, then incident".
* **D-C.10 A duplicate apply is detected before any other read of instance state (CDV M1).** The `event_idempotency` read for the descriptor's completion key (`service_task_dispatch:<id>`, or `script_task_dispatch:<id>:<attempt>`) is the FIRST step after the dispatch/CAS row and the projection are locked, BEFORE the graph and token reads. A first apply that committed has already moved the token (`find_token_for_service_task/2` would return `{:error, {:unknown_token_id, _}}`, `engine.ex:4443-4448`) and may have terminated the instance (`{:instance_not_active, _}` at the projection lock), so the check order matters. Results: key present (token present, token missing, or instance terminated alike) -> `{:ok, :already_final}`, nothing written, no log, no `advance_failed` audit. The projection lock is still taken first when the instance is active; when `fetch_and_lock_instance_projection/3` returns `{:instance_not_active, _}`, the entry function performs the same key read WITHOUT a lock before returning that error, and answers `{:ok, :already_final}` if the key is present, else today's `{:error, {:instance_not_active, _}}`. An `idempotency_conflict` that still occurs inside the Multi is treated as "a prior apply committed" (a `sys:step:` key cannot be claimed by a client, #2550 plus A2) and answers `:already_final` too, NEVER ERROR. The read is added only when a plan exists (a node without lines keeps today's order and today's error values). Rationale: F-C5.
* **D-C.11 Order inside the nested Multi:** existing hop-chain, timer, dispatch and child-creation steps, then `:entity_writes`, then `:sys_variables_event`, then `:entity_writes_applied_event`, then `:service_task_completed_event`, then `completion.on_advanced`, then `:projection` (its closure folds the `_sys` values with strict `put_sys/3`), then the per-line audit steps `{:entity_write_audit, i}` LAST so the tenant-wide audit chain lock is held for the least time. No snapshot is taken on this path today and none is added. Rationale: D-A1.10, D-B.10, D-B.13; 7.3.
* **D-C.12 Activation (C1):** the node-type fence accepts `:SERVICE_TASK` and keeps `:entity_writes_node_type_not_supported` for every other type. Allowed source kinds are exactly B's (`var`, `const`). No new violation code. A script-bound node (`script_key` attribute) is allowed (OQ-C2). The `check_entity_writes/3` position, the three activation paths, the activator requirement and `activated_by` recording are unchanged. The `preseeded_variable_names` rule needs no SERVICE_TASK clause (a response or script output cannot carry a `_sys` key, A1).
* **D-C.13 No new response surface; the existing shaping covers it.** Nothing new is returned to a client: the apply has no response. History shows the APPLIED event through the existing allowlist (it already carries `dispatch_id`), the SYS event stays hidden, EXECUTION_ERROR `variables` stays stripped, the DLQ entry is value-free by construction (D-C.8). Section 10.
* **D-C.14 `expected` and update/delete stay refused, create-only MVP** (B D-B.21, OQ-B5). The service path has no new op.
* **D-C.15 The B1 gate seam is gone** (`StepWrites.execution_enabled?/0` was deleted in B2, `definitions.ex` has no flag); C2 must not re-introduce one.
* **D-C.16 REQ-501 interaction (#2590), no overlap, three seams kept open.** (a) `StepSource` is the one provenance type a handler line will also build (its `handler` field is a future additive optional key, flat `source.handler`); (b) `multi_ctx.origin` is the same union a handler call needs; (c) the idempotency key derivation is a single function (`StepSource.idempotency_key/1`), so REQ-501's "per-write suffix" is one extension point. PR C adds NO handler concept, no `owner_module`, no manifest hash and no line kind other than `create`; a line naming a managed type stays `:entity_type_managed`.
* **D-C.17 Platform-actor scope ceiling is the same vacuous predicate as B** (`scoped_type?/1`, `scope_column_field?/2`, OQ-B6): a scoped type is refused on the service path exactly as on the human path, in `:process_policy`; the platform actor is tenant-wide by nature, so the node ceiling is the only bound once 0051 exists (D4b.6).

## 5. Interfaces, specs and shapes (no bodies)

### 5.1 `Letflow.Entities.StepSource` (C0 target, as reworked on `feat/GH-2627-step-source-struct`; `entities/step_source.ex`)

```
@type origin :: {:task, Ecto.UUID.t()} | {:dispatch, Ecto.UUID.t()}

%Letflow.Entities.StepSource{
  kind: String.t(),                  # always "process_step"; supplied by new/1, optional input
  instance_id: Ecto.UUID.t(),
  task_id: Ecto.UUID.t() | nil,      # exactly one of task_id / dispatch_id is non-nil
  dispatch_id: Ecto.UUID.t() | nil,
  node_id: String.t(),               # 1..1024 bytes, valid UTF-8
  definition_id: Ecto.UUID.t(),
  definition_version: String.t(),    # 1..255 bytes, valid UTF-8
  line_index: non_neg_integer(),
  activator_id: Ecto.UUID.t()
}
@enforce_keys [:kind, :instance_id, :node_id, :definition_id, :definition_version, :line_index, :activator_id]

@spec new(term()) :: {:ok, t()} | {:error, :invalid_step_source}   # atom-keyed, non-struct map only
@spec origin(t()) :: origin()
@spec idempotency_key(t()) :: String.t()                      # "sys:step:" <> origin id <> ":" <> line_index
@spec to_metadata(t()) :: %{required(String.t()) => String.t()}   # the eight flat source.* keys, integers as decimal strings
```

`new/1` is the only place the invariants live: closed atom key set (an unknown key, a string key or
a non-map is refused), `kind` optional and equal to `"process_step"`, both-or-neither origin
refused, UUIDs cast to canonical form, the byte and UTF-8 bounds above, `line_index` a non-negative
integer. There is no keyword input and no `new!/1`; tests and fixtures use `{:ok, s} = new(map)`.
`to_metadata/1` emits exactly: `source.kind`, `source.instance_id`, `source.task_id` XOR
`source.dispatch_id`, `source.node_id`, `source.definition_id`, `source.definition_version`,
`source.line_index`, `source.activator_id`: eight keys for either origin (B-11's "nine" counted one
too many; the C0 test pins the real set). C2 adds nothing to this module: it calls `new/1` with a
`dispatch_id`, which the implemented constructor already accepts.

### 5.2 `Letflow.Entities.Records` (C0 target, as reworked; `entities/records.ex`)

```
@type step_command :: %{
        required(:kind) => :create | :update | :delete,   # only :create accepted
        required(:entity_type) => String.t(),
        required(:field_values) => Validator.field_values(),
        required(:actor_id) => Ecto.UUID.t(),
        required(:source) => StepSource.t()               # the ONLY source shape
      }
# line_key and idempotency_key are no longer command fields: the namespace index is
# source.line_index and the key is StepSource.idempotency_key(source). check_line_key/1 collapses
# into that derivation (no separate equality check can fail).
@spec command_multi(step_command(), prefix :: String.t(), ManagedTypes.owner()) ::
        {:ok, Ecto.Multi.t()} | command_multi_error()
# a non-struct source, an invalid struct (re-validated through StepSource.new/1) or a foreign kind:
# {:error, :invalid_step_source}. Records.classify_step_error/1 has no clause for it, so a build
# failure reaches the engine as :internal -> {:entity_write_failed, i, :build} (see D-C.2).
```

`check_line_key/1`, `check_step_key/1`, `step_source_metadata/1`, `step_source_origin/1`,
`tagged_uuid/3` and the `@step_source_keys` list are deleted; `:invalid_step_key` stays in
`command_multi_error()` only if the derived key can still fail the charset/length check (it cannot
for UUID origins; ELIXIR-DEV removes the member and the test or keeps it as unreachable, and says
which). The step namespace, step names, `interpret_in_multi/1` and `classify_step_error/1` are
unchanged.

### 5.3 `Letflow.Engine.EntityPort` (C2 edit; `engine/entity_port.ex`)

```
@type origin :: {:task, Ecto.UUID.t()} | {:dispatch, Ecto.UUID.t()}
@type multi_ctx :: %{
        required(:prefix) => String.t(),
        required(:origin) => origin(),                         # replaces :task_id
        required(:instance_id) => Ecto.UUID.t(),
        required(:node_id) => String.t(),
        required(:definition_id) => Ecto.UUID.t(),
        required(:definition_version) => String.t(),
        required(:actor_id) => Ecto.UUID.t(),                  # event actor: completer (human) | platform sentinel (service)
        required(:subject_id) => Ecto.UUID.t(),                # restriction subject: completer | activator
        required(:activator_id) => Ecto.UUID.t(),
        required(:authorized) => [{String.t(), String.t()}],
        required(:variables) => (changes :: map() -> map()),
        required(:skip?) => (changes :: map() -> boolean()),   # service origin passes a constant-false closure
        optional(:now_fun) => (-> integer())
      }
```

`prepare/2`, `validate_lines/2`, `multi/3` (same arity), `interpret_failure/2`, `failure()`,
`refusal_code()`, `applied_line()`, `entity_writes_result()` are unchanged. The two behaviour
fixtures (`test/support/script_task_fixture.ex:421`, `test/letflow/entities/script_reads_test.exs:430`)
need no new delegate. The engine still names no `Letflow.Entities` module; `StepSource` is built
inside `StepWrites` from the context's primitives.

### 5.4 `Letflow.Entities.StepWrites` (C0 + C2)

```
@spec multi(Ecto.Multi.t(), [EntityPort.line()], EntityPort.multi_ctx()) :: Ecto.Multi.t()
# C0: build_line/4 builds a %StepSource{} through StepSource.new/1 (HUMAN origin only). A new/1
#     failure becomes the existing {:line, i, :build} error with reason :line_malformed.
# C2: origin {:dispatch, id} is accepted; subject_id replaces actor_id in check_restrictions/3;
#     value caps (D-C.7) apply only to the {:dispatch, _} origin and are checked in the same
#     {:line, i, :build} step as the restrictions (reason :value_too_large -> validation_failed).
@spec interpret_failure(term(), term()) :: EntityPort.failure()
# C2: one new reason in the {:line, i, :build} table: :value_too_large -> {:refused, i, :validation_failed, :value_too_large}.
```

### 5.5 Engine (`engine.ex`), C2, private unless stated

```
@typep service_entity_plan :: %{
         lines: [EntityPort.line()], node_id: String.t(), instance_id: Ecto.UUID.t(),
         dispatch_id: Ecto.UUID.t(), definition_id: Ecto.UUID.t(), definition_version: String.t(),
         activator_id: Ecto.UUID.t(), authorized: [{String.t(), String.t()}],
         route: :http | :script
       }

# descriptor (the existing @typep completion) gains one optional key:
#   optional(:entity_plan) => service_entity_plan()

@spec plan_service_entity_writes(route_ref, prefix) ::
        {:ok, service_entity_plan() | nil} | {:error, {:entity_write_refused, :contention, :entity_write_contention}}
        | {:error, {:entity_write_failed, 0, :prepare}} | {:error, :entity_write_needs_reactivation}
# route_ref is the unlocked dispatch row (HTTP) or the claim (script). Same read set and the same
# recorded_activator/1 + check_activator_active/2 as plan_entity_writes/3; cap > 20 refused; a read
# problem yields {:ok, nil} and the in-transaction guard (7.2 step 6) fails closed.

@spec classify_service_apply_error(term()) ::
        {:entity_write_refused, non_neg_integer() | :contention, atom()}
        | {:entity_write_failed, non_neg_integer(), atom()}
        | :entity_write_needs_reactivation | :not_entity_write
@spec land_http_entity_write_failure(dispatch_id, public_code, index, prefix) :: {:ok, :error_set} | {:error, term()}
@spec fold_service_sys_values(InstanceState.t(), %{String.t() => String.t() | non_neg_integer()}) ::
        {:ok, InstanceState.t()} | {:error, term()}      # shared with the HUMAN fold (fold_sys_values/2)
```

Public entry points keep their `@spec`: `advance_after_service_task_outcome/4` and
`apply_script_task_result/3` gain NO new return member that a dispatcher must handle (all
entity-write outcomes are folded to `{:ok, :error_set}`, `{:ok, :failed}`, `{:ok, :already_final}`,
`{:ok, :advanced}`/`{:ok, :applied}` or a generic `{:error, _}`).

`ScriptTaskDispatcher.detail()` gains `:entity_write_refused | :entity_write_contention`
(`script_task_dispatches_outcome_detail_format` allows both: `^[a-z][a-z0-9_]{0,63}$`).
`ServiceTaskDispatcher.classify_advance_failure/1` gains clauses for the entity-write error heads
(logging tags only; they are unreachable once the engine lands the failure, kept for the
function-level `rescue` residue).

## 6. Activation (C1)

`check_entity_writes/3` (`definitions.ex:2449`) and `node_entity_writes_violations/6`
(`definitions.ex:2576`): the single change is `node_type not in [:HUMAN_TASK, :SERVICE_TASK] ->
[:entity_writes_node_type_not_supported]` and the matching `node_type == :HUMAN_TASK` guard on the
line-validation branch (`:2594`) widened the same way. `validate_lines/2` already receives
`node_type` in its ctx and needs no change. Violation codes, HTTP shape (422
`entity_writes_invalid`), the activator requirement, `entity_writes_activated_by/3`, the three
activation paths and the cross-tenant promotion refusal (`check_activator_in_tenant/3`) are
unchanged and apply to SERVICE_TASK nodes identically.

Inventory (a) is NOT a C1 gate: it moved to C2's merge gate (section 1.3, CDV M3; section 14). C1's
PR body re-quotes the C2 result and adds only the node-type-specific recount at C1 time.

**Script-bound nodes (supervisor ruling OQ-C2).** Script-bound SERVICE_TASK nodes (`script_key`
attribute) are accepted by the widened fence only once C2b has merged. If C2b slips, C1 keeps the
fence CLOSED for a node that carries `script_key` (`:entity_writes_node_type_not_supported`
unchanged for that node) and opens it for HTTP-route nodes only; a later one-line PR opens it when
C2b lands. The fence therefore never admits a route whose apply path cannot compose lines.

## 7. Dispatch-time composition (C2)

### 7.1 Order (normative), HTTP route; the script route differs only where marked

```
-- before the outer transaction --------------------------------------------------------
P0  plan_service_entity_writes   (reads: dispatch row unlocked, graph, node, definition row,
                                  activated_by, activator user row)      [script: from the claim]
P1  EntityPort.impl().prepare    (its own short transaction, SET LOCAL 2 s / 2 s)
-- ONE outer Repo.transaction ---------------------------------------------------------
S0  SET LOCAL lock_timeout = '2s'; SET LOCAL statement_timeout = '5s'   (plan only)
S1  dispatch row FOR UPDATE      [script: CAS row FOR UPDATE]
S2  instance_projections row FOR UPDATE
S3  duplicate-apply read (D-C.10, plan only): event_idempotency by the completion key; present
    -> {:ok, :already_final} (also when the projection lock above returned instance_not_active)
S3a fetch_graph, tokens, find_token_for_service_task                     (unchanged)
S4  guard (plan only): "node has lines but no plan" fail-closed
S5  VariableMerge.merge(...)                                             (unchanged; every
                                  rejection lands as today BEFORE any entity step)
S6  hop chain + persist_service_task_advance prepares                    (unchanged, no lock)
-- nested Multi (do_persist_service_task_advance/10) ------------------------------------
M1  hop-chain token records, task activation, token reconcile, timer arms, dispatch rows,
    sub-process children creation                                         (unchanged)
M2  StepWrites.multi/3:  :entity_writes_started, per line in (entity_type, index) order
    {:line,i,:deadline}, {:line,i,:build}, the A2 steps (type sequence row FOR UPDATE,
    idempotency, event, projection, recheck, record latest), {:line,i,:process_policy};
    then :entity_writes
M3  :sys_variables_event, :entity_writes_applied_event
M4  :service_task_completed_event, completion.on_advanced
M5  :projection   (folds the _sys values into final_instance_state)
M6  {:entity_write_audit, i} per applied line                              (audit chain row)
-- after the outer transaction returns --------------------------------------------------
R   classify; contention -> re-apply (<= 3); refusal / failure -> second-transaction ERROR landing
```

An apply without a plan: P0/P1, S0, S3, S4, M2, M3, M6 and the descriptor key are absent;
the Multi is byte-identical to today (regression criterion C-15, golden step-name test).

### 7.2 The plan phase and the in-transaction guards

1. **P0** reads, with no lock and no write: the dispatch row (HTTP) or the claim (script); the pinned
   snapshot graph through the same `fetch_graph/2` the apply uses; the node by `node_id`
   (`find_node/2`, `engine.ex:5376`); `projection.definition_id` and the definition row
   (`Definitions.get_by_id/2`); `recorded_activator/1` and `check_activator_active/2` exactly as B2
   (D-C.5). A node with no non-empty `entity_writes` list yields `{:ok, nil}` immediately: a SERVICE
   node without lines does ONE extra read (the graph read the apply performs anyway is repeated; see
   the performance note in 9) and otherwise runs today's code.
2. **P1** `prepare/2` is unchanged (it filters by `ProcessWritable.writable?/1`, B CO-3). Its
   `{:error, :entity_write_contention}` is the contention class of D-C.9.
3. **S4 guard (fail-closed, after the graph and token reads):** inside the lock, after the graph and token are read, a node whose
   `entity_writes` attribute is a non-empty list while the descriptor has no `entity_plan` (a read
   problem in P0, or a snapshot that changed shape) -> `{:error, {:entity_write_failed, 0,
   :not_planned}}` -> ERROR landing. A plan whose `lines` differ from the locked node's lines is the
   same refusal (the snapshot is immutable, so this is defence in depth against a hand edit).
4. **S3 guard (duplicate apply):** D-C.10; runs before the graph and token reads, so a committed
   first apply (token moved, instance possibly terminal) is `already_final`, never `unknown_token_id`
   or `instance_not_active`.
5. **Run-time re-checks inside the step** are B's, unchanged: `normalize_line` on the pinned line,
   recorded `(entity_type, "create")` pair, write-side restrictions (subject = activator), the
   `:recheck_definition` step and `:process_policy` (writable flag re-read from the row under the
   type lock, append-only, scoped).

### 7.3 Lock inventory and ordering proof (service path)

| # | Lock | Taken by | Held to |
|---|---|---|---|
| 0 | `entity_type_instances` insert (unique index) | P1 `prepare/2`, own transaction | its own commit |
| 1 | dispatch row `FOR UPDATE` (HTTP) or script CAS row | S1 | commit |
| 2 | `instance_projections` row | S2 | commit |
| 3 | own-instance rows written by M1: token records, task rows, dispatch inserts, child instance streams (new rows), the instance's `instance_sequences` row via child-creation events | M1 | commit |
| 4 | per line, per type: the type's `instance_sequences` row, then the synthetic projection row | M2 | commit |
| 5 | the instance's own `instance_sequences` row | M3, M4 | commit |
| 6 | audit chain sentinel row | M6 | commit |

Compared with B 7.2: the type locks (4) now follow M1's own-instance rows (3). That is harmless: every
writer of rows in group 3 holds this instance's projection mutex (2) first, so no transaction can hold
a group-3 row and wait for a type lock while another holds the type lock and waits for a group-3 row
of THIS instance. Group-3 rows of OTHER instances are only ever NEW rows (child streams, dispatch
inserts), which no one else can hold. Two applies (or an apply and a `complete_task`) with line sets
(A,B) and (B,A) both execute A then B (sorted by `(entity_type, declared index)`), so the second waits
at A's type sequence row: no cycle. The service apply and `complete_task` cannot invert on the
instance level: `complete_task` takes tasks, projection; the apply takes dispatch (or CAS row),
projection; `cancel_instance/3` takes dispatch rows then projection (`engine.ex:4875`); none takes
`tasks` after the projection or a dispatch row after the projection.

**Cascade cycle, restated for this path (stated, not excluded).** A child instance's HUMAN_TASK
completion with lines on type A holds [child tasks, child projection, type A sequence] and its tail
cascade wants [parent token, parent projection]. A parent's SERVICE apply holds [dispatch, parent
projection] and, with lines on A, wants [type A sequence]. That is the same real `40P01` cycle as B,
with the service apply as the parent-side participant. The victim rolls back with nothing committed
and maps to contention, which on the service side is re-applied (D-C.9) and on the human side is a
503 retry. Since GH #2648 the service path has its own cascade (F-C10 resolved): a service apply that ends a
child is the cascade initiator too, locking child rows first and the parent after, the HUMAN order. Two cycles follow. (1) A child service apply holding a type's sequence row (planned) and wanting the parent token/projection, against a parent SERVICE apply in a parallel branch holding its projection and wanting the same type row: a real 40P01; the victim is classified as contention and re-applied (D-C.9), and since GH #2648 that classification applies to UNPLANNED HTTP applies too (a cascade adds parent locks to them). Limit: an UNPLANNED SCRIPT apply bypasses the re-apply driver (and its blanket rescue erases a deadlock), so a cascade deadlock there lands a terminal `script_rejected`/`apply_failed`; accepted while a script task inside a child is unreachable (GH #2694), follow-up under GH #2695/#2694; no dedicated forced-overlap test for this exact pairing, the re-apply is covered by a trigger-induced 40P01 test. (2) `cancel_instance/3` locks a parent projection before its tokens, the reverse of the cascade's token-then-projection: pre-existing on the HUMAN path, now also reachable from a service apply, NOT fixed here (GH #2695); this order is therefore not claimed deadlock-free. EE-12 gains one sentence in C2: "the service apply holds the dispatch row and the
projection while it requests entity-type locks; a deadlock with a child completion's cascade is
reported as contention and re-applied."

### 7.4 Error and tail composition, details

* **`:entity_writes` placement** is inline in `do_persist_service_task_advance/10`, before
  `:service_task_completed_event`, keyed on `completion[:entity_plan]`. `skip?` is a constant-false
  closure: this Multi exists only when the hop chain advanced (execution errors and no-matching-edge
  never reach it; the F-2 analogue of B is structural, see section 8 rows 10-12).
* **`variables`** closure returns the apply's merged variable map (`advanced_state.variables`,
  captured at build time; no need to read `changes`).
* **`:sys_variables_event`**: only when `sys_values` is non-empty; strict `put_sys/3` fold first;
  `EventStore.append/2` with `VariableMerge.sys_event_type()`, payload `%{"node_id", "cause" =>
  "entity_writes", "values"}`, actor sentinel, key `<completion key>::sys_vars`.
* **`:entity_writes_applied_event`**: always when lines applied; `EntityPort.applied_event_type()`,
  `task_id: nil`, `dispatch_id` set, `lines` ids and sequences, key `<completion key>::entity_writes`,
  actor sentinel.
* **`:projection`** closure: `fold_service_sys_values/2` on `final_instance_state` using
  `changes.entity_writes.sys_values` before `reconcile_projection/5`. The `_sys` values are never
  passed to `append_sub_process_children_creation_multi` (children are built from the prepared
  interface mapping, which refuses `_sys`, A1b).
* **Per-line audit**: `Audit.insert_entry/3` inside `Multi.run`, action `entity_write.process_step`,
  `resource_type "entity_record"`, `resource_id` record id, `actor_id` sentinel, `after_state`:
  `entity_type`, `record_id`, `dispatch_id`, `activator_id`, `instance_id`, `node_id`,
  `definition_id`, `definition_version`, `line_index`, `lines_hash` (no field value). The HUMAN
  after-state shape (B-11) is unchanged.
* **Failure step name**: with a plan, a failed nested Multi returns `{:error,
  {:entity_write_step_failed, failed_step, reason}}` only when `failed_step` is a `{:line, _, _}`
  tuple; `interpret_failure/2` runs in the entry function. Every other failed step, and every apply
  without a plan, returns today's `{:error, reason}` unchanged.

### 7.5 Return mapping (entry function, after the outer transaction)

| Outer result | Class | Outcome |
|---|---|---|
| `{:ok, :advanced}` / `{:ok, :applied}` | success | unchanged |
| `{:ok, :already_final}` | duplicate apply (D-C.10) | unchanged value, no write |
| `{:error, {:entity_write_step_failed, step, reason}}` via `interpret_failure/2` -> `{:refused, i, :entity_write_contention, _}` | contention | re-apply |
| same -> `{:refused, i, code, detail}` (any other code) | refusal | ERROR landing with public `code`, audit `detail` |
| same -> `{:failed, i, step}` | internal | ERROR landing, public code `entity_write_failed` |
| `{:error, {:transaction_failed, %Postgrex.Error{postgres: %{code: c}}}}` or a raised one, `c in [:lock_not_available, :query_canceled, :deadlock_detected]`, or `DBConnection.ConnectionError`, WITH a plan | contention | re-apply |
| P0/P1 `{:error, {:entity_write_refused, :contention, _}}` | contention | re-apply |
| P0 `{:error, :entity_write_needs_reactivation}`, or `{:error, {:entity_write_refused, 20, :validation_failed}}` (cap) | refusal | ERROR landing (public `entity_write_needs_reactivation` / `validation_failed`) |
| anything else, with or without a plan | not an entity-write class | today's `{:error, reason}` path: log + `service_task.advance_failed` audit, no ERROR (pre-existing stall class, deferred) |

The contention rescue wraps exactly the outer `repo.transaction` call and only when a plan exists
(B 7.6 rule); the post-commit stages here are only the return value, so no post-commit contention
mapping exists. A step inside `StepWrites` still never rescues a database error.

**Where the rescue sits per route (CDV m1).** HTTP: `advance_after_service_task_outcome/4` has NO
function-level rescue today (a lock wait that times out at S1/S2 raises out to the dispatcher's
poll loop), so the plan-only rescue of contention classes is NEW and wraps the outer
`repo.transaction`; it re-raises every other exception unchanged (a no-plan apply keeps today's
raise). Script: `apply_script_task_result/3` already has a blanket `rescue _ -> {:error, :raised}`
(`engine.ex:4896-4905`) that discards the exception class; the plan-only contention rescue sits
INSIDE it, around the `Repo.transaction` call, so a contention class is classified before the
blanket clause can erase it; every other exception still falls to the blanket clause.

**Landing failure rows.** The landing transaction (D-C.8) is classified with the same table: a
contention class -> re-run under the shared budget and deadline; explicit completion-key read present,
`instance_already_error`, `instance_terminal`, `instance_not_active` -> `{:ok, :already_final}` (no collision is relied on, D-C.8 b);
budget exhausted or any other error -> the residual of D-C.8 (d): log, `service_task.advance_failed`
audit, return `{:error, reason}`.

## 8. Error and refusal table (SERVICE_TASK apply)

"Public code" is what the DLQ entry's `error_detail` and the `EXECUTION_ERROR` payload carry; the
detail atom is only in the tenant audit entry and the log (INV-5). There is no HTTP response on this
path; the outcome column states what happens to the instance and the dispatch row.

| # | Cause | Internal result | Public code | Outcome | Retried |
|---|---|---|---|---|---|
| 1 | Managed type, type not process-writable, not append-only, scoped, line not authorised, field restricted for the ACTIVATOR, record not found | `{:refused, i, :write_not_permitted, detail}` | `write_not_permitted` | ERROR + DLQ; nothing committed | no |
| 2 | Field validation failure, malformed pinned line, `expected`/`record` present, value over the cap | `:validation_failed` | `validation_failed` | ERROR + DLQ | no |
| 3 | update/delete op in a pinned line | `:entity_append_only` | `entity_append_only` | ERROR + DLQ | no |
| 4 | Type inactive or definition changed between build and recheck | `:entity_type_inactive` | `entity_type_inactive` | ERROR + DLQ | no |
| 5 | Completion key already present (duplicate apply, ambiguous commit re-apply, landing key read), or a duplicate `sys:step:` key inside the Multi | treated as "prior apply committed" | none | `{:ok, :already_final}`, nothing written (D-C.10), also when the token is gone or the instance is terminal | n/a |
| 6 | `55P03`, `57014`, `40P01`, connection error, 10 s guard, `prepare/2` contention | contention | `entity_write_contention` after exhaustion | re-applied up to 3 times, then ERROR + DLQ | yes, bounded |
| 7 | Activator absent, inactive, or recorded authority malformed | `:entity_write_needs_reactivation` | `entity_write_needs_reactivation` | ERROR + DLQ; recovery is cancel plus rollback/promotion re-activation (B 7.3); the external call already happened | no |
| 8 | Internal fault in a line step, `:sys_value`, `:applied_event` | `{:failed, i, step}` | `entity_write_failed` | ERROR + DLQ; step atom logged | no |
| 9 | "Lines but no plan" (S4 guard) | `{:entity_write_failed, 0, :not_planned}` | `entity_write_failed` | ERROR + DLQ | no |
| 10 | HTTP body carries a reserved `_sys` key | existing `persist_service_task_reserved_key_error/6` | `reserved_variable_key` | ERROR (as today), NO entity step ran | n/a |
| 11 | Merge rejected otherwise (and the other non-entity-write apply failures: `transition_failed`, `unknown_token_id`, `event_append_failed`) | existing `{:error, _}` | n/a | as today (ISS-0928: log + `service_task.advance_failed` audit, instance stays ACTIVE; stall class deferred, section 16); NO entity step ran | no |
| 12 | Hop chain: no matching edge / execution error / transition failure | existing landings | n/a | as today; NO entity step ran (no records orphaned) | n/a |
| 13 | Instance cancelled or not active before the lock | `{:error, {:instance_not_active, s}}` | n/a | benign debug log; nothing written | no |
| 14 | Script route: lease sweep or a result of `{:failed, ...}` | existing `script_failure/7` | n/a | as today; NO entity step ran | n/a |

The ERROR landing of rows 1-4, 6-9 for the script route is `script_failure/7` with fail code
`script_rejected` and detail `entity_write_refused` or `entity_write_contention` (rows 6 and 7 map to
`entity_write_contention` / `entity_write_refused`).

## 9. Concurrency, transaction, retry and idempotency analysis

* **Atomicity.** Lines, SYS event, APPLIED event, audit, completed event, run record (script),
  projection and the new dispatch/task/child rows commit or roll back as one outer transaction. A
  refusal in line k rolls back lines 0..k-1 and every earlier M1 step. The ERROR landing is a
  separate, later transaction: its only writes are EXECUTION_ERROR, the DLQ row, the projection
  status and (script) the run record and row status.
* **The service call succeeded, the write refuses.** The external effect is not compensated (ruling
  open point 6: "a lost response is an incident, never a second posting"). The platform's record of
  the incident is the ERROR instance, the DLQ entry (fixed sentence, public code, `dispatch_id`,
  `line_index`) and the tenant audit entry; the response body is NOT stored anywhere (the completed
  event is not committed). There is no automatic retry of the call and no automatic re-apply after
  landing: `Dlq.retry/2` re-invokes nothing (execution_error.ex moduledoc). Persisting the body for an
  operator re-apply is deferred (16).
* **Idempotency keys.** Line key `sys:step:<dispatch_id>:<declared index>`, derived by
  `StepSource.idempotency_key/1` from the same struct that supplies `source.dispatch_id` (C0), so key
  and source cannot name different ids. The two instance-event keys are `<completion key>::sys_vars`
  and `<completion key>::entity_writes`, never colliding with `sys:step:` (refused un-namespaced by
  EventStore) or with the completion key itself.
* **Retried dispatch (transient failure of the HTTP call).** Attempts happen BEFORE `"advanced"` is
  committed and never reach the apply; the retried attempt reuses the dispatch id and `attempt_index`
  advances (`handle_retry/3`). No record can be written by a failed attempt.
* **Duplicate completion.** D-C.10. The pre-check (S3, BEFORE the graph and token reads) reads `event_idempotency` by the completion key
  under the dispatch/CAS lock; a duplicate therefore cannot race a first apply (the first holds the
  same lock to commit).
* **Replay safety.** Rebuilding never calls `StepWrites`. `INSTANCE_SYS_VARIABLES_SET` precedes
  `SERVICE_TASK_COMPLETED`/`SCRIPT_TASK_COMPLETED` and folds through `put_sys_replayed/3`; a stored
  pre-#2621 wide event replays byte-identically; APPLIED folds as a no-op. The EXECUTION_ERROR
  landing replays as today. A replayed `_sys` value is never assumed to be a UUID or int64 by a
  reader (CO-7, unchanged).
* **SET LOCAL scope.** Issued in the outer transaction before the dispatch lock, so it bounds the
  dispatch and projection waits, the nested Multi and the tail; ends with the outer transaction. The
  `prepare/2` transaction is separate. Under the SQL sandbox the B2 `reset_local_timeouts!/0` helper
  (CO-4) applies to every module that asserts the no-SET-LOCAL property.
* **Ambiguous commit.** `DBConnection.ConnectionError` mapped to contention may follow a server-side
  COMMIT whose acknowledgement was lost. The re-apply then finds the completion key present
  (D-C.10, S3) and answers `already_final`: no double write, no ERROR. P0 of the re-apply runs first
  and may itself refuse (activator deactivated meanwhile); that refusal reaches the landing, whose
  explicit completion-key read answers `already_final` (D-C.8 b), so a committed first apply is never
  turned into an ERROR.
* **Performance.** A SERVICE node without lines costs one extra graph read in P0 (the apply already
  reads the same snapshot). A node with lines holds the type sequence rows for the apply; cross-
  instance contention per type is the B consequence and is bounded by 20 lines, 2 s lock, 5 s
  statement, 10 s guard, and 3 re-applies.
* **Stale plan.** Graph and node are immutable per instance; a concurrent second apply of the same
  dispatch is serialised by the dispatch/CAS lock and caught by D-C.10; the activator status check is
  advisory (D4a.4).

## 10. API gating (INV-2, INV-5)

PR C adds no route, no response field and no event type. Surfaces that can now carry service-path
data, each checked:

| Surface | What is new | Gate |
|---|---|---|
| `GET /instances/:id`, reconstruct, `POST /tasks/:id/complete` | the projection may hold `_sys.*` after a service apply | existing `Response.public_variables/1` (B3), unchanged; the static router test already scans every `"variables"` key |
| `GET /instances/:id/history`, `/timeline` | `INSTANCE_SYS_VARIABLES_SET` and `TASK_ENTITY_WRITES_APPLIED` rows from a service apply | existing exclusion and `public_event_payload/2` reduction; the APPLIED allowlist already includes `dispatch_id`; `SERVICE_TASK_COMPLETED.decoded_body` and `SCRIPT_TASK_COMPLETED.output` are unchanged (a body with a reserved key never commits, A1) |
| `EXECUTION_ERROR` payload `variables` | the landing writes it | PRE-merge variables (no response body) passed through `public_variables/1` by the existing history shaping |
| DLQ (`GET /dlq`, `/dlq/:id`) | the landing creates one entry | `reason` fixed sentence, `error_detail` = `{"line_index", "code", "dispatch_id"}`; no record id, field name, entity type or value; asserted by C-13 |
| Audit (`GET /audit`) | per-line entries and `entity_write.refused` | ids and closed atoms only; per-line `after_state` keeps `record_id` (OQ-B4 asymmetry, same as B) |
| Lua `get_instance_state` / `read_variable`, Wasm `read_variable` | none | B3 `drop_reserved/1` unchanged |
| Outbound service request body and script input | a later SERVICE_TASK could send `_sys` values to an external endpoint | refused at activation (A1b: template placeholders and script inputs may not reference `_sys`); not re-opened |

## 11. AC -> design -> test brief

Test files are the issue's names where it gives one. "DB" = tenant fixture; composition tests run
`async: false`. All new unless marked "edit".

### 11.1 Issue Group C

| AC | PR | Design | Test brief |
|---|---|---|---|
| **C-1** Sentinel proof FIRST (0054 AC 22 / N8) | C2 (first commit) | D-C.4, F-C11 | `test/letflow/engine/service_task_entity_writes_sentinel_test.exs`: create an entity record through `Records.command_multi/3` with `actor_id = EventStore.platform_actor_id()` on a synthetic type stream; assert the event row, `entity_record_latest` row, projection and the `Records` result are accepted and readable; a read of the record through the entity API shows no user lookup failure; if any layer refuses, the test asserts the stable code and C2 stops (the fence stays). Also asserts the audit entry with the sentinel actor and `activator_id` in `after_state`. |
| **C-2** Nested Multi atomicity (AC 18) | C2 | 7.1, 7.4, 9 | `service_task_entity_writes_test.exs`: HTTP SERVICE_TASK with two lines; success commits both records, both entity events, SYS, APPLIED, `SERVICE_TASK_COMPLETED`, projection, new task/dispatch rows and audit rows; force line 2 invalid -> zero records, zero entity events, zero `sys:step:` idempotency rows, no completed event, the dispatch row still `"advanced"`, then the instance is ERROR with one DLQ entry whose `error_detail` is exactly `{"line_index", "code", "dispatch_id"}` and the refusal audit entry exists AFTER the rollback; the hop-chain no-matching-edge, reserved-key body and merge-rejection cases write NO record. |
| **C-3** Contention on the service path (AC 19) | C2 | 7.5, D-C.9 | `service_task_entity_writes_contention_test.exs` (`:auto` sandbox, zero backoff via the seam): force `55P03` (a second connection holds the type sequence row), `57014`, `40P01`, connection error and the 10 s guard (`now_fun`) -> nothing committed, re-applied, and on the first re-apply success the apply commits once; exhaustion after 3 -> ERROR + DLQ with public code `entity_write_contention`; the outbound call count is exactly 1; `SET LOCAL` statements are the first two statements of the outer transaction (CO-4 helper) and absent for an apply without a plan; a contention raised by the P1 `prepare/2` transaction is the same class. |
| **C-4** Dispatch-row idempotency and retry (AC 23 first part) | C2 | D-C.3, D-C.10, 9 | `service_task_entity_writes_retry_test.exs`: keys are `sys:step:<dispatch_id>:<i>`; a transient HTTP failure then success yields exactly one record per line and `attempt_index` advanced; **after a committed first apply the token has moved and the instance may be terminal: calling `advance_after_service_task_outcome/4` a second time for the same dispatch returns `{:ok, :already_final}` in each of three states (token moved and instance active; instance COMPLETED; instance CANCELLED after the apply), with record count unchanged, no ERROR, no `service_task.advance_failed` audit entry and no error log line emitted by the dispatcher call (`service_task_dispatcher.ex:578-679`; log capture scoped to that call, not the whole test);** a landing driven against an EXISTING completion key (apply committed, then the landing function invoked directly, and again via a racing second apply) leaves the instance and its variables untouched, writes no DLQ entry and no `EXECUTION_ERROR` event, and returns `{:ok, :already_final}`; on the script route the same drive returns `{:ok, :stale}`; a raw duplicate `sys:step:` row inserted in `event_idempotency` BEFORE the first apply -> treated as prior commit (`already_final`) not ERROR; ambiguous-commit stub -> re-apply `already_final`; deactivating the activator between the first apply and the re-apply still answers `already_final`. Script route: a second apply of the same claim returns `{:ok, :stale}`. |
| **C-5** Lock order (service cases) | C2 | 7.3 | `entity_writes_lock_order_test.exs` service cases (`:auto`): statement log of one service apply lists SET LOCAL, dispatch lock, projection lock, type sequence rows ascending, then audit chain; service (A,B) vs `complete_task` (B,A) vs service (A,B) N-parallel (N <= 4, machine load rules) finish without `40P01`; the cascade case of B-3 extended with a parent SERVICE apply as the partner: every round ends with both committed or one victim re-applied/503 with nothing partial, asserted by record counts; source-level assertion that no `FOR UPDATE` is reachable from `prepare_timer_arms/4`, `prepare_service_task_dispatch_abort_on_empty_url/6`, `prepare_sub_process_children_for_completion/8` (same grep as D-B.2). |
| **C-6** Platform-actor scope ceiling (AC 10, 21) | C2 | D-C.17 | `entity_writes_scope_test.exs` service cases: with `:entity_writes_scope_keys` set in `setup` and a fixture type carrying the key, a service line is refused in `:process_policy` with the same public code as the human path (`write_not_permitted`), ERROR + DLQ, nothing written; production list empty -> predicates false (pilot limit stated in the PR body, OQ-B6). |
| **C-7** Activation accepts SERVICE_TASK | C1 | 6, D-C.12 | edit `entity_writes_activation_test.exs`: the SERVICE_TASK refusal case flips to "activates and records `activated_by`" on all three paths; every code of B 6.2 asserted at the exact `{node_id, index}` for a SERVICE node; a non-HUMAN/non-SERVICE node type still gets `:entity_writes_node_type_not_supported`; missing activator -> `:entity_write_activator_required` for a SERVICE node; a script-bound node is accepted only when C2b has merged, else still `:entity_writes_node_type_not_supported` (section 6). |
| **C-8** Refusal lands ERROR, never stall (F-C1) | C2 | D-C.8, 8 | in `service_task_entity_writes_test.exs`: one case per row 1-4, 7-9 of section 8 asserting instance `:error`, one DLQ entry, one audit entry, the dispatch row `"advanced"`, zero records; the instance is never `:active` with a lost token; a second apply returns `already_final`; **the "lines but no plan" guard (S4): a node whose pinned `entity_writes` list is non-empty while the descriptor carries no `entity_plan` (P0 forced to `{:ok, nil}` through a read problem) lands ERROR with public code `entity_write_failed` and writes zero records; a node WITHOUT lines under the same condition applies exactly as today;** a failing ERROR landing (contention injected into the landing transaction) is re-run, and a landing whose completion key collides answers `already_final`; script route: the row is `failed` with detail `entity_write_refused`, a run record exists, no second run. |
| **C-9** Activator authority at run time (D4a) | C2 | D-C.5 | `service_task_entity_writes_activator_test.exs`: `activated_by` NULL, missing `EntitiesRecordsWrite`, malformed `authorized`, non-UUID `user_id` -> ERROR landing public `entity_write_needs_reactivation`, nothing written; activator user `:inactive` and row deleted -> same; a pair absent from `authorized` (hand-edited snapshot) -> `write_not_permitted`; the activator's field restriction is honoured and a `user_entity_grants` row for the ACTIVATOR allows it; a grant for nobody else matters (no completer exists); event `actor_id` is the sentinel and `source.activator_id` the activator. |
| **C-10** Values: typing, injection, size (F-C8, F-C9) | C2 | D-C.7 | `service_task_entity_writes_values_test.exs`: a body key mapped by `var` lands in the typed field; a wrongly typed value -> `validation_failed`; a 70 KiB string field -> `validation_failed` with no field name, nothing written; a 300 KiB line aggregate likewise; a body key not named by any line is merged but not written; a `var` naming `_sys` never activates and, hand-edited, is omitted; no value appears in event metadata, audit, DLQ or log capture. |
| **C-11** Replay (AC 15) | C2 | 9 | extend `entity_writes_replay_test.exs`: port double with zero `multi/3`, `prepare/2`, `validate_lines/2`, `interpret_failure/2` calls during `Reconstruction.reconstruct_instance/2`, projection rebuild, timer fire, escalation and cancel for an instance that went through a service apply; rebuilt variables equal live ones including `_sys.*`; wide-tier stored SYS event before a service completed event replays byte-identically. |
| **C-12** Source, event and audit shape | C0, C2 | 5.1, 7.4 | edit `records_command_multi_test.exs`, `entity_writes_gates_test.exs:236`: flat `source.*` metadata byte-identical to the pre-C0 fixture for a task origin; for a dispatch origin exactly `source.dispatch_id` replaces `source.task_id`; APPLIED event has `dispatch_id` set and `task_id` null, `lines_hash` equals `StepWrites.lines_hash/1`; one `entity_write.process_step` audit row per line, hash chain verifies (`Audit.verify_chain/2`). |
| **C-13** API gating (INV-2) | C2 | 10 | `service_task_entity_writes_surfaces_test.exs`: after a service apply, on instance read, reconstruct, history, timeline: no reserved key and no `record_id`/`event_global_seq` in history; DLQ list and get contain no record id, field name, entity type or value; `error_detail` key set asserted exactly. |
| **C-14** Script route | C2 (C2b) | D-C.8, D-C.9 | `script_task_entity_writes_test.exs`: script output feeds a line; success commits records, SYS, APPLIED, `SCRIPT_TASK_COMPLETED`, `SCRIPT_RUN_RECORDED`, row `applied`; refusal -> row `failed`, detail `entity_write_refused`, ERROR + DLQ, the dispatcher follow-up NEVER invoked (call count asserted); contention re-applied inside the engine, exhaustion -> detail `entity_write_contention`; **lease interaction (D-C.9): with the lease shortened to a few hundred ms and an injected contention longer than the deadline, the re-apply loop stops at `min(20 s, remaining lease - 2 s)`; a concurrent lease sweep and a late re-apply produce exactly one winner (the other is `{:ok, :stale}`), never two run records and never a record written after the sweep's `timeout` incident.** |
| **C-15** Regression | all | 7.1 | Full `mix test` green, quoted in each PR body; golden step-name tests: HUMAN (`__complete_task_multi_step_names__`) unchanged and a new service seam asserting a no-lines apply yields exactly today's names; `engine_concurrency_test.exs` and existing `Records`/service-task suites unedited. |
| **C-16** `%StepSource{}` (#2627) | C0 | 5.1, 5.2, D-C.2 | `test/letflow/entities/step_source_test.exs`: `new/1` accepts the full valid atom-keyed shape (with and without `kind`, with `task_id` or `dispatch_id`); refuses missing keys, both/neither origin, string keys, keyword lists, non-UUID, node_id 0/1025 bytes and invalid UTF-8, version 0/256 bytes, negative or non-integer line_index, foreign kind, unknown key; `idempotency_key/1` equals the pre-C0 `"sys:step:<id>:<index>"` for both origins; `to_metadata/1` keys and string values equal the pre-C0 golden; `command_multi/3` with a plain map source, a foreign-kind struct or a hand-built invalid struct -> `{:error, :invalid_step_source}`, and through `StepWrites` that reaches `{:entity_write_failed, i, :build}` (pins the `classify_step_error/1` fall-through); `test/letflow/entities/step_source_callers_test.exs`: git-grep/AST test that no literal source map (`kind: "process_step"`, `"source.kind"`) exists outside `step_source.ex`, with non-vacuity on a synthetic snippet; flat metadata on a real event byte-identical; replay of a stored event unchanged. |
| **C-17** `activated_by` still not forgeable | C1 | I-B11 | existing B-19 case re-run against a SERVICE definition; no new writer. |
| **C-18** REQ-501 seams unaffected | C0 | D-C.16 | `module_write_*` tests belong to #2590; PR C asserts only that `StepSource` accepts no `handler` key yet (refused as unknown) so the extension is an explicit later edit. |

### 11.2 Carry-overs from B's deferral list (section 16 of the B design)

| Carry-over | PR | Where |
|---|---|---|
| sentinel-actor proof | C2 | C-1 |
| nested-Multi composition at `do_persist_service_task_advance/10` | C2 | 7.1, 7.4 |
| dispatch-keyed `sys:step:<dispatch_id>:<i>` | C0, C2 | D-C.3, C-4 |
| service-path contention and SET LOCAL proof | C2 | C-3 |
| lock-order proof against `complete_task` | C2 | 7.3, C-5 |
| `source.dispatch_id` | C0, C2 | 5.1, C-12 |
| activator as the field-restriction subject (D4c) | C2 | D-C.4, C-9 |
| platform-actor scope ceiling | C2 | D-C.17, C-6 |
| `%StepSource{}` (#2627) first commit | C0 | D-C.2, C-16 |

## 12. Invariants

* **I-C1** A SERVICE_TASK apply with lines writes nothing unless every line, `_sys`, both events, the completed event, the projection and the audit commit in ONE transaction; every execution error, no-matching-edge and merge rejection of the apply writes no record.
* **I-C2** The entity step's refusal does not leave the instance ACTIVE with a lost token: it lands ERROR + DLQ in a separate, later transaction, or the apply was a duplicate and answers `already_final`. QUALIFIED: between the rollback and the landing commit there is a crash window (and a landing that exhausts its budget), in which the pre-existing F-C1 stall class remains; closing it needs the stuck-`"advanced"` sweeper deferred in section 16.
* **I-C3** The external call is never repeated by the entity-write machinery (at-most-once); a re-apply reuses the in-memory result only.
* **I-C4** `_sys` values are set only by strict `put_sys/3` (engine step) or `put_sys_replayed/3`; never from line data, a response body or a script output.
* **I-C5** The event actor on the service origin is the platform sentinel and the activator is recorded in `source.activator_id`; the restriction subject is the activator; no entity event is attributed to a human who did not act.
* **I-C6** Authority is the literal `:tenant`; a managed type is never a declarative target; the recorded `activated_by` is untrusted data re-validated before each apply.
* **I-C7** Entity-type locks are taken only inside `:entity_writes`, in `(entity_type, declared index)` order, after the dispatch/CAS row and the projection, and before the audit chain lock.
* **I-C8** The line idempotency key and the namespace index are derived from the same `%StepSource{}` that supplies `source.*` (`StepSource.idempotency_key/1`, `line_index`); no caller supplies a key or a `line_key`, and `command_multi/3` re-validates the struct through `StepSource.new/1`.
* **I-C9** No client-visible map, DLQ entry, audit entry, log line or event metadata carries a field value, field name, entity type name or record id beyond the allowlists of section 10.
* **I-C10** Replay never invokes the entity port; a service apply's `_sys` values replay from the SYS event before the completed event.

### 12.1 Security invariants (`security-invariants.md` numbering)

| INV | How PR C satisfies it |
|---|---|
| INV-1 | `prefix` from the dispatcher's tenant schema (a server value) everywhere; no line field selects a schema or tenant; the plan reads and the landing transaction are prefixed |
| INV-2 | No field value anywhere (events, audit, DLQ, log); B3 shaping covers history, instance and DLQ shapes (section 10); size caps bound response-sourced values |
| INV-3 | Lines are definition data; write callbacks unreachable from `lib/letflow/scripts/**` and `script_task_dispatcher.ex` (the static rule of B CO-10 is re-run; the script dispatcher only calls `Engine.apply_script_task_result/3`) |
| INV-4 | Secrets by reference only; PR C stores none; the DLQ sentence and details are fixed/closed; exception structs never leave the entry function |
| INV-5 | One public code per cause class in the DLQ entry; detail atoms only in the tenant audit entry |
| INV-6 | New data-access paths stated for SECURITY-REVIEWER: P0 reads (dispatch row, definition row, activator row), the duplicate-apply `event_idempotency` read, the second landing transaction, the per-line writes through `command_multi/3` |
| INV-7 | SET LOCAL strings are compile-time constants (the B2 attributes); no interpolation; `ScopeNodePaths.lock!/1` not called |
| INV-8 | Explicit clauses for every class in 7.5, no swallowing catch-all for entity-write errors; the pre-existing function-level `rescue` is kept and its product is classified, not ignored |
| INV-9 | N/A: no outbound URL validated or stored |
| INV-10 | No new permission, no new route; `:EntitiesRecordsWrite` is evaluated at activation (unchanged) |

0054 threats: T-1 (managed type) by 7.2 step 5 and C-8; T-2 by the per-type flag, recorded pairs and
the activator restriction subject; T-4 by C0 plus C-4; T-6 by 7.3; T-7 by D-C.8 and section 10;
T-9 by I-C4 and C-11; T-10 (service path: platform actor writes without a user, activator authority)
by D-C.4, D-C.5, C-1, C-9.

## 13. Files touched per PR

**C0**: `entities/step_source.ex` (new), `entities/records.ex` (types, `command_multi/3`, deletion of
the map checks), `entities/step_writes.ex` (`build_line/4` builds the struct), tests
`step_source_test.exs`, `step_source_callers_test.exs` (new, C0), `service_task_subprocess_cascade_probe_test.exs` (new, C2 prerequisite; became `service_task_subprocess_cascade_test.exs` under GH #2648); edits `records_command_multi_test.exs`,
`records_reserved_keys_test.exs`, `entity_writes_gates_test.exs`, `command_multi_callers_test.exs`
only if its fixture builds a source.

**C2**: `engine.ex` (plan phase, descriptor key, outer wrapper and SET LOCAL in
`advance_after_service_task_outcome/4` and `apply_script_task_result/3`, composition in
`do_persist_service_task_advance/10`, S4 guards, tagged step failure, classification, re-apply loop,
two landing functions, moduledoc EE-12 sentence), `engine/entity_port.ex` (`multi_ctx`, moduledoc),
`entities/step_writes.ex` (origin union, subject, caps, `interpret_failure/2` reason),
`engine/service_task_dispatcher.ex` and `engine/script_task_dispatcher.ex` (classification tags,
`detail()` members; no behaviour change), `event_store.ex` OR the engine's existing alias for a
read-only `event_idempotency` existence check (one function), a test-support seam for golden step
names (`:engine_test_seams`, mirroring `engine.ex:2637`), `test/support/entity_writes_fixture.ex`
(service helper), the tests of section 11.

**C1**: `definitions.ex` (two guards), `docs/guides/adding-an-application-module.md` (one sentence),
`test/letflow/definitions/entity_writes_activation_test.exs` (edit).

Docs: DOC-UPDATER bookkeeping; the REQ-499 entry notes OQ-B5 (stale `expected` unreachable).

## 14. Migration, seed and inventory pins affected

| Item | PR | Effect |
|---|---|---|
| Tenant migration | none | `activated_by` exists (B1); event types and their schemas already admit `dispatch_id`; `@expected_tenant_tables` unaffected |
| Seed counts | none | event types 22/19 unchanged |
| `Records.step_command` shape | C0 | `line_key`/`idempotency_key` removed; edits the A2 and B2 tests that pin them |
| Flat `source.*` metadata | C0 | byte-identical (test C-12/C-16); no stored event changes |
| `ScriptTaskDispatcher.detail()` | C2 | two additive atoms; DB regex already admits them |
| EE-12 moduledoc | C2 | one sentence (7.3) |
| Pre-merge inventories | C2 (gate), C1 | **C2 gate (a):** count, per tenant, of (1) `process_definitions` rows of ANY status whose graph has a node of type `SERVICE_TASK` with a non-empty `entity_writes` attribute, and (2) non-terminal instances whose PINNED snapshot (`SnapshotStore` graph) has such a node, including instances of definitions since deprecated or archived; required zero, any hit cancelled, repaired or re-versioned first; result in C2's PR body. **C1:** the same count re-run at C1 time. (b) none for `_sys` (B's CO-8 stays valid). Operator-run, read-only, constant SQL, quoted tenant schema from the registry |
| Anti-pattern check | C2 | "a validator that began refusing at activate broke already-merged tests" does not apply (C1 relaxes); the tests that hand-build ACTIVE definitions for C2 insert the row with a recorded `activated_by` directly |
| Tenant-template staleness | none | no migration |

## 15. Open questions: rulings (supervisor, 2026-10-16, binding)

* **OQ-C1 CLOSED: YES.** Merge order C0 -> C2 -> C1.
* **OQ-C2 CLOSED: YES.** Script-bound SERVICE_TASK nodes are C2b. If C2b slips, the activation fence stays closed for script-bound nodes (section 6).
* **OQ-C3 CLOSED: YES.** A refusal lands ERROR + DLQ. It is stated as NEW product behaviour in C2's PR body and in the operator runbook (D-C.8).
* **OQ-C4 CLOSED.** 64 KiB per value and 256 KiB per line as named constants with a pinning test (D-C.7). HUMAN is NOT widened in PR C; the follow-up is the entity-side per-record cap (section 16).
* **OQ-C5 CLOSED: defer.** Reason: the check would run in the dispatcher, which the boundary forbids from calling the engine, and it is advisory anyway (the D4a.4 deactivation race exists between the check and the call). The consequence (an external effect whose result cannot be applied for a deactivated activator) is the accepted incident of the 0054 open point 6 ruling.
* **OQ-C6 CLOSED.** The sentinel actor stays. Pre-approved fallback (activator id as `actor_id`, `source` unchanged) ONLY if C-1 shows a consumer resolving `actor_id` to a user; in that case C2 STOPS and this design reopens.
* **OQ-C7 CLOSED.** `StepSource` derives `line_key` and the `sys:step:` key from the struct (D-C.2).
* **OQ-C8 CLOSED, and RESOLVED by GH #2648** (the probe below was flipped into `service_task_subprocess_cascade_test.exs`; the service apply now runs the cascade). File an ISS for the missing service-path sub-process cascade, and CONFIRM it with a running test BEFORE C2 relies on 7.3: `test/letflow/engine/service_task_subprocess_cascade_probe_test.exs` (a child instance whose last node is a SERVICE_TASK; apply it; assert whether the parent token wakes). The test is a C2 prerequisite; its result and the ISS id go in C2's PR body. If the cascade turns out to exist elsewhere, 7.3 is re-derived before C2 proceeds.

## 16. Deferred (not PR C)

* **#2590 / REQ-501:** module write handlers, `owner_module` stamp, manifest hash, `PinRebind` rule, handler-sourced `source.handler`; PR C leaves the three seams of D-C.16.
* update/delete lines, `expected`/`record` from `_sys`, hook 2, script outputs as commands (#2534 7c), after-commit triggers (the outbound mirror, ruling open point 6 condition 3), org-relative assignment, the `(instance, node, attempt)` stock business key (WMS slice 5).
* Persisting the decoded response body (or a hash) for an operator re-apply from the DLQ, and a stuck-`"advanced"` sweeper (a crash between the `"advanced"` commit and the apply loses the body today; pre-existing).
* The remaining silent-stall classes of the HTTP apply (`transition_failed`, `invalid_form_schema`, `variable_merge_rejected`, `unknown_token_id`): ISS-0928 made them loud, not terminal; PR C changes only the entity-write class.
* A `{"response": key}` source kind and a declared-output-keys check for script-bound nodes at activation.
* **Entity-side per-record cap (follow-up to file with C2):** a size cap enforced inside `Records`/the entity validator that REPLACES the origin-specific service caps of D-C.7 and also covers the HUMAN path, instead of widening HUMAN in PR C.
* **Stuck-`"advanced"` sweeper** (closes the residual of D-C.8 d and I-C2): finds `"advanced"` dispatch rows whose projection is ACTIVE and whose completion key is absent, and lands them as ERROR; also the pre-existing non-entity-write stall classes of ISS-0928.
* Real `needs_reactivation` status and in-place re-activation (B follow-up), scoped types and the rule-3a lock (0051), pre-call activator check (OQ-C5).
