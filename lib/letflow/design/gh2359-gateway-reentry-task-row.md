# WF-03 Fix Design -- GH #2359 / ISS-1035 / Q-1035

Run-id: WF03-GH2359-GATEWAYBACK-20261014
Branch: feature/WF03-GH2359-GATEWAY-BACK-20261014
Type: backend bug fix (engine task activation), no schema change.
Source of truth for root cause: `handoffs/WF03-GH2359-GATEWAYBACK-20261014/step-01-issue-fixer.json`
(reproduced by execution there; code references below were re-read on this branch).
Binding decisions (supervisor): Fix A only (engine strip of the completing token's own pair,
applied to the seed state before Transition; a `previous`-only strip is insufficient, section 1);
no validator rule in this PR; PR must test the escalation-timer interaction; the throwaway repro
becomes the permanent regression test.

## 1. Problem

A token that completes a HUMAN_TASK at node A and, within the same hop chain, is routed
(`A -> EXCLUSIVE_GATEWAY -default-> A`) back to A gets **no new `tasks` row**. The instance
stays `:active`, the token is `:active` at A, and there is zero pending task: unrecoverable
except by `cancel_instance`. The graph validator accepts the shape (the cycle passes through a
gateway, `cycle_without_gateway` is satisfied), so definitions publish and activate cleanly.

Mechanism (confirmed): `TaskActivation.newly_pending_tokens/2` (`task_activation.ex` 119-125)
is a set difference keyed on `{token_id, node_id}`. The engine passes
`previous = seed_state.pending_task_nodes`, read BEFORE the completion, so it still contains
`{T, A}` (the task being completed is still `:pending` at seed time). The hop chain re-appends
the same token at the same node (`Transition.dispatch_human_task/3`, `transition.ex` 438-452:
`pending_task_nodes ++ [token]`), the final pair `{T, A}` equals the previous pair, and the
diff drops it. ISS-0057's pair-keyed fix handled A -> B but not same-node re-entry. `Transition` never removes the stale entry: the `:complete_task` and
`:escalation_timer_fired` dispatches do not touch `pending_task_nodes` (`transition.ex`
439-440 appends only; 459 "Never appends"), and `dispatch_task_completion_hop_chain/8`
passes the seed unchanged (`engine.ex` ~4186-4187). So the final list is
`[{T,A} stale, {T,A} appended]`: TWO entries for one token at one node. Stripping only the
diff's `previous` would make BOTH pass `newly_pending_tokens/2` (it filters the new list with
no dedupe) and insert two pending rows. The stale entry must be removed from the list handed
to `Transition`. The control
`A -> B -> gw -> A` works because B's completion is a different transaction whose seed no longer
holds `{T, A}`.

Not a DB constraint (`tasks` has only `idx_task_instance`, `idx_task_token`; no unique index)
and not an idempotency key.

Second, latent defect this fix would expose (section 5): `complete_task`'s
`:cancel_escalation_timers` step runs AFTER the escalation-timer arm step and is scoped by
`(instance, token, node, "escalation", "pending")`, so on a same-node re-entry it would cancel the
timer just armed for the new task row. Today this is invisible because no new row exists, but
the timer arm already happens (arming is driven by `pending_events`, not by the diff): today a
re-entry arms a timer and immediately cancels it.

## 2. Public surface

No change to any public function signature of the diff/activation functions, HTTP route, event
shape, or schema.

### Choice: strip the seed before Transition (not `previous` only, not dedupe the new list)

1. **Chosen: derive a "post-completion seed" -- the seed `InstanceState` with the stale
   `{completing_token_id, completed_node_id}` entry removed from `pending_task_nodes` -- and use
   it BOTH as the `Transition.transition/3` input AND as the source of `previous` for the
   activation diff.** The hop chain then appends exactly one `{T,A}`; `previous` lacks `{T,A}`;
   the diff yields exactly one new entry. Consistency (INV-3b) holds because `previous` and the
   pre-transition list are the same value. The unstripped `seed_instance_state` stays exactly as
   it is for every other reader (notably `maybe_snapshot_after_complete_task/2`, engine.ex ~2487,
   which snapshots the seed on the `:execution_error` path where the task stays `:pending`).
2. Rejected: dedupe the new list by `{token_id, node_id}` inside `newly_pending_tokens/2` and
   strip `previous` per call site. It changes the shared pure diff used by `create/2` and would
   silently mask any future genuine double-append bug instead of surfacing it.

### New helper (pure, in `Letflow.Engine.TaskActivation`)

    @spec consume_completed_position(
            instance_state :: InstanceState.t(),
            completing_token_id :: String.t(),
            completed_node_id :: String.t()
          ) :: InstanceState.t()

Semantics: returns `instance_state` with every `pending_task_nodes` entry whose
`{token_id, node_id}` equals `{completing_token_id, completed_node_id}` removed. All other
entries (including sibling tokens pending at the SAME `node_id` with a different `token_id`) are
kept in order; every other `InstanceState` field is untouched. Pure, total (absent pair -> state
returned unchanged). `completing_token_id` is the string form used for `Token.token_id`
(`own_token_id`).

`newly_pending_tokens/2`, `append_multi/6` and `append_multi_from_existing_records/7` are
UNCHANGED (signatures and behavior). `create/2` is unchanged. `Transition` is unchanged.

## 3. Exact change per call site

Every site that computes `previous` for `append_multi_from_existing_records` / `append_multi`.
Line numbers are for `lib/letflow/engine.ex` on this branch.

| # | Site | Completing token / node | Is `{T, completed_node}` in `previous`? | Change |
|---|---|---|---|---|
| 1 | `build_snapshot_and_state/4` (engine.ex ~2537) plus its two consumers for `complete_task/3`: `dispatch_task_completion_hop_chain/8` (~4173-4187, `Transition.transition` input) and `build_task_activation_and_reconciliation_multi/4` (~4753/4793, `previous`) | `own_token.token_id`, `task.node_id` (a HUMAN_TASK) | YES in the seed (the task being completed is `:pending` at seed time) | **REQUIRED.** `build_snapshot_and_state/4` returns one additional map key, `post_completion_seed :: InstanceState.t()` = `consume_completed_position(seed_instance_state, own_token.token_id, task.node_id)`; `seed_instance_state` is left unstripped. `dispatch_task_completion_hop_chain/8` builds `state_with_merged_variables` from `post_completion_seed` (variables merged onto it). `build_task_activation_and_reconciliation_multi/4` passes `post_completion_seed.pending_task_nodes` as `previous` (replacing `seed_state.pending_task_nodes`). Both read the same key, so INV-3b holds. |
| 2 | `advance_after_escalation_timer_fired/3` (~2965), consumers `dispatch_escalation_timer_fired_hop_chain/1` (~3005, `Transition.transition`) and `persist_escalation_timer_fired_advance/7` (`previous` ~3155) | `own_token_id` (= `timer.token_id`), `timer.node_id` (a HUMAN_TASK) | YES. `escalation_timer_stale?/2` already guarantees the token is at `timer.node_id`; the original task is cancelled by `:cancel_original_task` in the same transaction | **REQUIRED.** In the non-stale branch only, before `dispatch_escalation_timer_fired_hop_chain/1`, replace `snapshot_and_state.seed_instance_state` with `consume_completed_position(seed_instance_state, own_token_id, timer.node_id)`. This path has no error-snapshot consumer of the seed (snapshots are taken only by `complete_task`), so replacing in place is safe and keeps one value for Transition and `previous`. Do NOT change `build_snapshot_and_state_for_timer/4` (plain timer-fired shares it and needs no strip). The escalation hop chain follows the default edge and can reach `A -> gw -> A` exactly like site 1. |
| 3 | `persist_timer_fired_advance/7` (~2851), TIMER node completion | `own_token_id`, `timer.node_id` (a TIMER node) | NO. A TIMER node never has a `tasks` row; the token is not in `pending_task_nodes` | **No change.** Adding the strip would be a provable no-op; leaving it out keeps the diff minimal. The re-entered pair `{T, A}` is new relative to `previous` so a row is created today. Covered by an assertion in the matrix (T-10), not a code change. |
| 4 | service-task outcome re-entry, `persist_service_task_advance/10` -> `do_persist_service_task_advance` (~3729) | `dispatch.token_id`, SERVICE_TASK node | NO. SERVICE_TASK tokens are in `pending_service_task_nodes`, a disjoint list; no `tasks` row | **No change.** Same reasoning as 3. `A -> svc -> gw -> A` is a completion of A (site 1) followed by a service completion; at the service completion `{T, A}` is absent from `previous` (A's row already `:completed`), so the new A row is created. |
| 5 | `SubProcess.build_completion_write_steps/13` (`sub_process.ex` ~1027), parent-token continuation / synchronous child | `parent_token.id`, SUB_PROCESS node | NO. `load_parent_context/2` runs inside a `Multi.merge` (`maybe_chain_synchronous_completion/6`, sub_process.ex 484-492, which calls `append_completion_multi/5` at def 735; the `load_parent_context/2` call is at 762; the asynchronous-child cascade is the `Multi.merge` at engine.ex 4692) that executes AFTER `:task_complete` is persisted in the same transaction (engine.ex 4584; children creation 4627), so its re-read already sees the human task row `:completed` and `{T,A}` is not in its `previous` | **No change.** Verified from step ordering. T-11 is a regression guard. |
| 6 | `create/2` -> `TaskActivation.append_multi/6` (~1714) | none | `previous = []` | **No change.** Must stay `[]`; asserted by T-4. |

Plumbing: the values are already in hand (`own_token.token_id`, `task.node_id` / `timer.node_id`).
The only structural addition is the `post_completion_seed` key in the map
`build_snapshot_and_state/4` returns (a plain map, not a struct). Apart from the Transition input
and the three `previous` arguments, nothing in `engine.ex` reads `seed_state.pending_task_nodes`
(grep confirmed), so no other behavior moves.

Only the completing token's own pair is stripped. Join counters are untouched (a join mints a
new token id, which is never in `previous`). Parallel-split siblings pending at the same node
keep `{S, A}` in `previous` and are therefore not re-inserted (T-5).

## 4. Invariants

* INV-1 (re-entry gets a row): a token re-entering the node it just completed (or was escalated
  off) within the same hop chain gets exactly ONE new `:pending` `tasks` row.
* INV-2 (no duplicate for unchanged entries): a token pending at the same node before and after,
  whose own task is NOT the one completed/cancelled here, gets no new row (its pair stays in
  both `previous` and the final list, so the diff drops it).
* INV-3 (single pending row per token/node): after commit there is at most one `:pending` row
  per `(instance_id, token_id)`, hence no two `:pending` rows share `(token_id, node_id)`. Holds
  because (a) the list handed to `Transition` no longer carries the stale entry so the hop
  chain's `pending_task_nodes` holds exactly one `{T,A}`, and (b) the old row becomes
  `:completed` (`:task_complete`) / `:cancelled` (`:cancel_original_task`) in the same
  transaction. The escalation fire path's `where token_id == ^timer.token_id and status ==
  :pending |> one` relies on this.
* INV-3b (consistency): the `pending_task_nodes` handed to `Transition` and the `previous`
  handed to the diff are the same list (`post_completion_seed.pending_task_nodes`).
* INV-4 (timer/task pairing): after the transaction a `:pending` escalation timer exists for
  `(token, node)` iff a `:pending` task row exists for `(token, node)` and the node carries a
  non-empty `escalation_timer_duration`.
* INV-5 (tenant isolation unchanged): no new data-access path; writes stay in the existing
  prefix-scoped Multi steps (INV-1/INV-6 of `security-invariants.md` untouched; INV-8 is the
  invariant being restored).
* INV-6 (error path untouched): on an execution error (internal `{:execution_error, _}`, surfaced to the caller as `{:error, {:instance_execution_error, ...}}`) nothing is persisted for the task or tokens, because the error branch reads the unstripped `seed_instance_state` and never reaches the activation steps. Guarded behaviourally by T-14 (assertions (i)-(iii)); no snapshot read is involved.

## 5. Escalation-timer interaction (create-then-cancel ordering)

Current step order inside `complete_task`'s tail Multi (`build_complete_task_tail_multi/6`,
engine.ex ~4506-4645):

    1  {:hop_chain_token_records, id}          (join-minted tokens)
    2  {:task_records, id}                     (exactly one new tasks row for the re-entering token, via post_completion_seed)
    3  token reconciliation
    4  timer arms: {:scheduler_escalation_timer, token_record_id}   (Multi.merge ~4520)
    5  service-task dispatch rows              (Multi.merge ~4551)
    6  :task_complete                          (old row -> :completed, ~4584)
    7  :cancel_escalation_timers               (~4594)  <-- scoped (instance, token, node, "escalation", "pending")
    8  audit, :event, :projection, sub-process children, cascade, :complete_task_outcome

For a same-node re-entry steps 4 and 7 target the same `(instance, token, node)` key. Step 4
inserts a NEW `pending` timer row; step 7, running later, is status-guarded only
(`status == "pending"`), so it would cancel BOTH the old row and the one just inserted. Result
with Fix A alone: a new task row but no live escalation timer (the new task never escalates);
the old stale timer is cancelled correctly, the new one wrongly.

### Required change (complete_task only; orthogonal to the seed strip)

Move the escalation-timer cancellation BEFORE the timer-arm step, i.e. run it ahead of the
`build_task_activation_and_reconciliation_multi` tail (before step 2), by prepending the existing
step to the Multi that is returned (compose with `Ecto.Multi.append/2` or construct the cancel
Multi first and append the activation tail to it). Contract of the moved step:

* Same step name `:cancel_escalation_timers`, same call
  `TaskActivation.cancel_pending_escalation_timers/6` with `task.instance_id`, `task.token_id`,
  `task.node_id`, `completed_at`, `prefix`. No signature change to that function.
* It no longer depends on `:task_complete`; it reads only `normalized_changes.task`, so the
  move is dependency-safe. Nothing downstream reads `changes[:cancel_escalation_timers]`
  (verified by grep: the only reference is the step definition itself).
* Failure semantics unchanged: any step error rolls back the whole transaction, so "old
  cancelled, new not armed" cannot commit partially.

Rejected alternative: keep the position and add an `except_timer_ids` filter to
`cancel_pending_escalation_timers/6` (needs the new ids threaded out of
`build_timer_arms_multi/4`, changing a public function and coupling two steps). Reordering is
smaller and keeps the function signature stable. If REVIEWER prefers it, it is an equivalent
substitute provided T-9 passes.

### Timer rows after a re-entry (the exact end state)

Starting state: instance with token T pending at A; A has `escalation_timer_duration`; one
`timers` row `E1 (token T, node A, escalation, pending)`.

After `complete_task(A_row1)` with A -> gw -> A:

| Row | State | Why |
|---|---|---|
| `tasks`: A_row1 | `:completed` | `:task_complete` |
| `tasks`: A_row2 | `:pending` | new row from section 3 site 1 |
| `timers`: E1 | `cancelled`, `cancel_reason = "task_completed"` | moved cancel step runs first and sees only E1 pending |
| `timers`: E2 (token T, node A, escalation, fire_at = now + duration) | `pending` | armed after the cancel; not visible to it |

Exactly one pending escalation timer remains and it belongs to A_row2 (INV-4). No unique index
exists on `timers`, so two rows with the same `(instance, token, node, type)` do not conflict
(checked in `20260829020001_create_timers.exs`).

Other paths: the escalation-fire path (site 2) marks the fired timer `fired` before advancing
(`do_fire`, `scheduler.ex` ~297) and has no cancel step, so the re-entry there arms a fresh
timer with nothing to cancel. The sub-process cascade arms its timers in step 8, after the
cancel, so it was never affected. Adjacent issue GH #2325 (escalation timer cancel
semantics) touches the same step; the PR must not change `cancel_pending_escalation_timers/6`
itself, so the two stay composable. Sequence the PRs; do not combine.

## 6. Idempotent replay

`complete_task/3` replays are rejected before activation: `fetch_and_lock_task/3` (M1) returns
`{:error, {:task_not_pending, :completed}}` when the same `task_id` is delivered again, and the
Multi aborts at the first step with zero writes. After a re-entry the replayed id is the OLD
row (`A_row1`, `:completed`); the NEW row has a different id, so a replay can never complete
the new task or insert another row. Concurrent double-submit of A_row1 is serialized by the
`FOR UPDATE` on the task row and the projection row: the loser sees `:completed` and returns the
same error. Therefore at most one new row per completion (INV-1/INV-3), asserted by T-6. `post_completion_seed` is built inside M3, after the task/projection row locks, so a replay (which aborts at M1) never reaches it. The
event-store idempotency key is unaffected (it is claimed in the `:event` step, inside the same
transaction as the new row, so a rollback discards both).

## 7. Failure modes

| Failure | Behavior |
|---|---|
| Insert of new row fails (e.g. unknown node id, non-UUID token id) | Existing `{:error, reason}` from `insert_newly_pending_from_existing_records/5`; transaction rolls back; old task stays `:pending`; no half state. Unchanged. |
| Hop limit exceeded by a gateway-only loop that never reaches a task (e.g. `gw -> gw`) | Unchanged existing `{:transition_failed, ...}` path; not touched by this fix. |
| Re-entry loops forever through a gateway whose condition never turns true | Not a stall: each loop is a human decision, a new task per iteration (intended). |
| Definition authored before this fix, instance stalled in production | Not repaired by this PR (no data migration). `cancel_instance` remains the only recovery; the PR description must say so. |
| Strip helper handed a pair that is absent | Returns the list unchanged (total); behavior equals today's. |

## 8. Test matrix

Permanent regression test file: rename
`test/letflow/engine/gh2359_gateway_back_repro_test.exs` ->
`test/letflow/engine/gh2359_gateway_reentry_task_row_test.exs`, module
`Letflow.Engine.Gh2359GatewayReentryTaskRowTest`, remove the "THROWAWAY / Do not commit"
header, remove `IO.puts`/`IO.inspect` diagnostics. `use Letflow.DataCase, async: false`
(keeps the existing file's setting). Pure helper tests go in
`test/letflow/engine/task_activation_test.exs` (extend, do not fork).

| ID | Covers | Test name (describe / test) | Assertion summary |
|---|---|---|---|
| T-1 | Case: A -> gw -> A direct loop; issue AC1 "reproduced with exact steps" | "gateway re-entry / direct loop A -> gw -> A creates a new pending task for A" | after completing A with `approved = false`: exactly ONE new row inserted (total rows at `a` == 2, not 3), exactly 1 `:pending` at `a`, 1 `:completed` at `a`, no two rows share `(token_id, node_id)` while `:pending`, projection `:active`, token `:active` at `a`; complete the new row with `approved = true` -> instance `:completed`, no pending tasks |
| T-2 | Case: A -> B -> gw -> A control | "gateway re-entry / control A -> B -> gw -> A still creates a new A row" | completing A then B yields `[a completed, b completed, a pending]` (guards against regressing ISS-0057) |
| T-3 | WITHDRAWN | n/a | The standing fixture scan is dropped (it asserted an inventory, not behavior). Issue AC3 is satisfied by the step-01 scan (0 of 13 shipped graphs loop this way, recorded in the handoff and section 9) plus T-1, which proves the engine handles the shape for any definition |
| T-4 | Case: `create/2` with `previous = []` | "gateway re-entry / create/2 still materializes exactly one row per initial HUMAN_TASK" | start `START -> a` creates one pending row; start `START -> gw -> a` same; the `create/2` code path is untouched |
| T-5 | Case: parallel cohort, sibling at same node not re-inserted | "gateway re-entry / parallel sibling pending at same node is not re-inserted" | Definition: `START -> PARALLEL_GATEWAY split`; `split -> gw1 -> a` and `split -> gw2 -> a` (two tokens S1, S2 reach HUMAN_TASK `a` through different gateways; permitted because CHK-04, graph.ex 664-689, only enforces a minimum incoming-edge count); `a -> gwr`; `gwr -[approved==true]-> end`; `gwr -[default]-> a`. Initially 2 `:pending` rows at `a`. Complete S1's row with `approved=false`: exactly ONE new row (token S1, `a`); S2's row id unchanged and still `:pending`; rows at `a` total exactly 3 (S1 `:completed`, S1 new `:pending`, S2 `:pending`; not 4); no two `:pending` rows share `(token_id, node_id)` |
| T-6 | Case: idempotent `complete_task` replay | "gateway re-entry / replaying complete_task on the old row creates no duplicate" | after T-1's first completion, call `complete_task(A_row1.id, same attrs)` again: returns `{:error, {:task_not_pending, :completed}}`, pending A rows still 1, total A rows still 2, event count unchanged |
| T-7 | Escalation-fire path (site 2) | "gateway re-entry / escalation fire with default edge back to A creates a new A task" | A has `escalation_timer_duration`, default edge `a -> gw`, `gw -> a`; fire escalation via `Scheduler.fire_timer/2`: original task `:cancelled`, a new `:pending` A row exists, fresh escalation timer `pending` for the new row |
| T-8 | Timer case part 1: re-entry arms a FRESH escalation timer | "gateway re-entry / re-entry arms a fresh escalation timer" | after T-1-shaped completion with escalation: exactly one new `:pending` task row (no two `:pending` rows share token+node) and exactly one new `timers` row with `timer_type "escalation"`, `status "pending"`, same `token_id`/`node_id`, `fire_at` strictly later than the cancelled one's `created_at`, and its id differs from E1 |
| T-9 | Timer case part 2: cancel does not cancel the new one | "gateway re-entry / cancel_pending_escalation_timers does not cancel the new timer" | same scenario: E1 `cancelled` with `cancel_reason "task_completed"`; E2 `pending`; total pending escalation timers for the token = 1; total `:pending` task rows for `(token, a)` = 1; then advance E2 (fire) and assert it escalates the NEW task (not stale-consumed). Also a negative check: a plain non-looping completion (A -> B) still cancels A's timer (ISS-0925 regression) |
| T-10 | Site 3 no-op claim | "gateway re-entry / timer completion TIMER -> gw -> A still creates the A row" | `TIMER -> gw -> A` activation; timer fire creates exactly one pending A row (documents why site 3 is unchanged) |
| T-11 | Site 5 verification | "gateway re-entry / A -> SUB_PROCESS(sync child) -> gw -> A creates a new A row" | a trivially-completing child; after completing A, exactly one pending A row (regression guard; site 5 is a source-verified no-op) |
| T-12 | Issue interaction (b): distinct_from / REQ-463 (pins the real semantics read from `separation_of_duties.ex`: per named node the NEWEST `:completed` row wins, `DISTINCT ON node_id ORDER BY completed_at desc, inserted_at desc, id desc`; refusal = `{:error, {:separation_of_duties, ids}}` internally, public `{:error, :separation_of_duties}` from `Engine.complete_task/3`) | "gateway re-entry / distinct_from compares against the re-entered (newest) completion" | Graph: `start -> first-review` (HUMAN_TASK, role-a, no `distinct_from`); `first-review -> gw1` (EXCLUSIVE_GATEWAY); `gw1 -[variables.again == "yes"]-> first-review` (the direct loop); `gw1 -[is_default]-> second-review`; `second-review` (HUMAN_TASK, role-b, `attributes.distinct_from = ["first-review"]`); `second-review -> end`. Users U1 and U2 distinct. Steps: (1) U1 completes first-review row R1 with `again="yes"` -> a NEW pending first-review row R2 exists (the fix; without it the instance stalls). (2) U2 completes R2 with `again="no"` -> second-review row S1 pending. (3) U2 attempts to complete S1: ASSERT `{:error, :separation_of_duties}` (newest first-review completer is U2; the OLDEST completer U1 would wrongly be blocked if the semantics used the first completion), S1 still `:pending`. (4) U1 completes S1: ASSERT `{:ok, %{instance_status: :completed}}`. Pins both the refusal and the success. `separation_of_duties.ex` is not modified; a comment-only update of the `rework_graph` doc note in `test/support/sod_support.ex` (~L174-181) is optional. Use the existing `S.complete/4` helper style of `test/letflow/engine_distinct_from_test.exs` |
| T-13 | Pure helper | "TaskActivation.consume_completed_position/3" unit tests | removes exactly the matching pair; keeps same-node different-token; keeps same-token different-node; empty list; order preserved; absent pair returns state unchanged; other `InstanceState` fields unchanged. Plus pure end-to-end: stripped state -> `Transition.transition(.., {:complete_task, t})` on `a -> gw -[default]-> a` + hop chain; `newly_pending_tokens(stripped.pending_task_nodes, final.pending_task_nodes)` has length 1 and `final.pending_task_nodes` has exactly one `{t, a}` |
| T-14 | INV-6 / error path | "gateway re-entry / execution_error leaves the task pending and untouched" | Graph: `start -> a` (HUMAN_TASK); `a -> gw` (EXCLUSIVE_GATEWAY) with ONE conditional edge `gw -[variables.ok == true]-> end` and NO default edge. Complete `a` with `ok=false`: ASSERT the caller-visible shape `{:error, {:instance_execution_error, :no_matching_gateway_edge, {:node, "gw"}}}` (`interpret_complete_result/3`, engine.ex ~5483-5488; same assertion at `test/letflow/engine_execution_error_test.exs:467-470`; spec union engine.ex:2177). The internal hop-chain tag `{:execution_error, _}` at engine.ex 4250-4278 is NOT what the caller sees. Then assert (i) the `tasks` row for `a` is still `:pending` and the instance has no new `tasks` row; (ii) the projection reads `status == :error` with `error_detail["error_type"] == "no_matching_gateway_edge"`, and `current_nodes` unchanged (`["a"]`): `ExecutionError.update_projection_to_error/4` (execution_error.ex ~336) writes only `status` and `error_detail`; (iii) re-calling `complete_task/3` on the same task id returns `{:error, {:instance_not_active, :error}}` (the already-shipped M2 conflict, execution_error.ex moduledoc "ERROR is explicitly NOT terminal"; asserted today by `test/letflow/engine_execution_error_test.exs` ~424) and leaves the task row `:pending`. Note: the task is NOT completable while the instance is `:error`; (iii) pins that the refusal is the typed conflict and that nothing was consumed by the failed attempt. No snapshot is read |

Issue AC mapping: AC1 (diagnosis states reproduced + steps) -> T-1 + the step-01 handoff;
AC2 (recommended fix + affected definitions list) -> this document, sections 2, 3 and 9 (affected shipped definitions: none);
AC3 (no shipped definition left stalled) -> step-01 scan plus T-1 (engine now handles the shape for any
definition, shipped or not).

Run command (CI-shaped, local): `LETFLOW_DEV_DB_CONFIRMED=1 MIX_ENV=test mix test
test/letflow/engine/gh2359_gateway_reentry_task_row_test.exs
test/letflow/engine/task_activation_test.exs`, then the full engine/sub_process/scheduler test
directories, since the reordered cancel step is shared by every `complete_task` caller.

## 9. Blast radius

* Files: `lib/letflow/engine/task_activation.ex` (+1 pure public function),
  `lib/letflow/engine.ex` (`build_snapshot_and_state/4` new key and its two consumers; the
  escalation non-stale branch; the cancel-step move in section 5), tests as above.
  `sub_process.ex`, `transition.ex` and `newly_pending_tokens/2` are NOT touched.
* Behavior change is confined to: a token whose own completed/cancelled pair equals a pair it
  re-enters in the same hop chain. For every other transition the strip is a no-op (the diff
  input is unchanged). The cancel-step reorder changes behavior only when an escalation timer
  for the same `(token, node)` is armed in the same transaction, which today can only be a
  same-node re-entry.
* No migration, no new index, no schema or event-shape change, no API change, no config.
* No shipped definition changes behavior (diagnosis: 0 of 13 scanned graphs loop this way).
* Existing stalled instances are not repaired (section 7).
* SECURITY-REVIEWER not required (no tenant-data path change); REVIEWER required.

## 10. Recommendation only (not in this PR)

A validator check rejecting `gateway -> own predecessor HUMAN_TASK` (option B in step 01) is
NOT included per the binding decision. It would forbid a natural rework model, and cannot help
already-activated, immutable definitions. If wanted later, file separately as an authoring
lint (warning), not an error.

## 11. Open questions / ambiguities

* OQ-1 (resolved here, flag for REVIEWER): the cancel-before-arm reorder in section 5 is a
  step-order change in a shared tail not named in the supervisor's decision text; the id-filter
  alternative is described and equivalent in outcome.
* OQ-2 (CLOSED by source): the sub-process path is a no-op (section 3 row 5).
* OQ-3 (CLOSED): standing fixture scan withdrawn (T-3).
* OQ-4 (CLOSED): two tokens at one node is reachable via `split -> gw1 -> a` and
  `split -> gw2 -> a`; named in T-5.
* No open questions remain that block the build.
