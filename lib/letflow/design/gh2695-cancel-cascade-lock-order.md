# GH #2695 - cancel_instance vs the sub-process cascade: one lock order

Status: design (CODE-DESIGNER). Base: origin/main bef9fe69. Owner of the build: ELIXIR-DEV.
Files read for this note: `lib/letflow/engine.ex`, `lib/letflow/engine/sub_process.ex`,
`lib/letflow/event_store.ex`, `lib/letflow/audit.ex`, `lib/letflow/engine/execution_error.ex`,
`lib/letflow/scheduler.ex`, `test/letflow/engine/service_task_entity_writes_lock_order_test.exs`.
No implementation code below; names are the contract.

Notation: `tasks_X` pending task rows of instance X; `P_X` its `instance_projections` row;
`T_X` its `tokens` rows; `S_X` its `instance_sequences` row; `E` the entity-type rows of a
completion with `entity_writes` (decision 0054 D3); `A` the tenant-wide `audit_chain_locks`
row (`audit.ex:284-300`, one row per tenant, held to commit). `c` = sub-process child,
`p` = its parent, `g` = grandparent.

## 1. Confirmed lock sequences (read, not run)

### 1.1 cancel_instance/3 (`engine.ex`, `run_cancel_instance` at :8406)

1. `tasks_p` pending, `order_by id` (`fetch_and_lock_open_tasks`, lock at :8522).
2. `timers` update_all (`cancel_pending_timers`), service dispatch rows, script dispatch rows
   (comments at :8412-8440 state "before the projection" on purpose).
3. `P_p` `FOR UPDATE` (`..._for_cancel`, :8535).
4. `eligibility` (pure).
5. `T_p` live (`:active, :waiting`), `order_by id` (`fetch_and_lock_live_tokens`, :8581).
6. `S_p` (INSTANCE_CANCELLED via `EventStore.append`, `event_store.ex:749-760`).
7. `P_p` update, then `A` (`record_instance_cancel_audit`, last step of the Multi).

Cancel never touches a child: no step reads `waiting_child_instance_id` and there is no
child-cancel step (grep of :8406-8700 for child/sub_process is empty). Cancelling a parent
leaves its child instance running; the child's later completion simply finds its parent token
`:cancelled` and does not cascade (see 4).

### 1.2 Cascade, parent side (shared by both paths)

`append_sub_process_completion_cascade_multi/6` (`engine.ex:7276`) runs
`SubProcess.find_waiting_parent_token/3` (`sub_process.ex:714`): `T_p` row selected
`FOR UPDATE` by `waiting_child_instance_id = child and status = :waiting`. It takes NO lock on
`P_p` first. Then `SubProcess.append_completion_multi/6` (:748) -> `build_completion_write_steps`
(:998): `load_parent_context` (:1215, plain unlocked `Repo.get`/`Repo.all` of `P_p`, `T_p`,
pending tasks), hop-chain token inserts, task activation inserts, timer/dispatch arm inserts,
`reconcile_parent_tokens` (updates `T_p`), `SUB_PROCESS_COMPLETED` event (`S_p`, :1395),
`reconcile_parent_projection` (:1407, `P_p` row lock taken only at the UPDATE),
`maybe_cascade_to_grandparent` (:1140-1190): the same T-then-P pattern one level up.
Inserts into `tasks`/`tokens`/`timers`/dispatches carry an FK to `instance_projections`
(migrations 20260818110002/3, 20260819045553): the FK check takes `FOR KEY SHARE` on `P_p`,
which CONFLICTS with a held `FOR UPDATE`. So the cascade is blocked by a cancel's `P_p` lock
at its first parent-side insert, not only at the projection UPDATE.
Parent-side order today: `T_p -> (P_p key-share) -> S_p -> P_p update`.

### 1.3 HUMAN completion path (`build_complete_task_tail_multi`, `engine.ex:7028-7245`)

`tasks_c` -> `P_c` (`fetch_and_lock_task/instance_projection`, :3469-3487) -> transition
(pure) -> [E, decision 0054 D3 steps 4] -> tail: escalation/reminder timers (`timers_c`),
token reconcile, task activation, timer/dispatch arms, `task_complete` (:7186), **`A`**
(`record_task_complete_audit` :7196, and `append_entity_write_tail` per-line audits) ->
`S_c` (TASK_COMPLETED, `:event`) -> `P_c` update (:7216) -> sub-process children creation ->
**cascade** (:7232, step 1.2). So here `A` is taken BEFORE the parent side.

### 1.4 Service/script apply path (`do_persist_service_task_advance`, `engine.ex:4907-5070`)

Dispatch row -> `P_c` (before this function) -> hop-chain/task/timer/dispatch inserts ->
child creation -> C2 `maybe_service_entity_writes` (E ascending, D-C.11) ->
`S_c` (service/script completed event) -> `P_c` update (`:projection`, ~:5035-5043) -> cascade
(`append_service_sub_process_cascade`, call ~:5057, defs ~:5107-5117, step 1.2) -> `A`
(`append_service_entity_write_audits`, ~:5063, "audit chain last"). The code comment at
~:5044-5056 already records that this order is "not claimed deadlock-free".

### 1.5 Other parent/child-touching lockers

| Path | Order (parent side) | Source |
|---|---|---|
| `complete_task` of a parent's OWN task | `tasks_p -> P_p -> T_p (reconcile) -> A -> S_p -> P_p upd` | :3469-3487, :7186-7216 |
| `Scheduler.fire_timer` on a parent timer | `timers -> P_p -> T_p ...` (via `advance_after_timer_fired`) | `scheduler.ex:425`, comment :8412 |
| ExecutionError landing (`ExecutionError.append_multi`) | `P_p` (or caller's `locked_projection`) -> `S_p` -> `P_p` upd; the cascade's own error branch (`engine.ex:7310`, `sub_process.ex:1186`) calls it with NO `locked_projection`, i.e. AFTER `T_p` | `execution_error.ex:199-280` |
| Service/script apply on the parent's own node | `dispatch -> P_p -> E -> S_p -> P_p upd -> A` | :5963 comment |
| Child cancel cascade | does not exist | 1.1 |

## 2. Global lock-order table and inversions

Extension of the `engine.ex` moduledoc list (:287-337). Canonical order, per instance X,
reading top to bottom; a path takes a subsequence of it:

```
 1 timers_X / dispatch rows_X     (cancel, fire_timer, apply: before the projection)
 2 tasks_X                        (complete_task, cancel)
 3 P_X                            (every path; ALWAYS before T_X)
 4 T_X (waiting/live token rows)  (cancel, cascade, reconcile)
 5 E  entity-type rows, ascending (0054 D3; cross-instance)
 6 A  audit chain row             (see 2.2)
 7 S_X                            (EventStore.append)
 8 P_X UPDATE
 Across instances: child rows (c) strictly before parent rows (p), p before g.
```

Inversion pairs found on main:

* **I1 (the issue): `P_p` vs `T_p`.** Cancel, complete_task, fire_timer, ExecutionError take
  `P_p` then `T_p`; the cascade takes `T_p` then `P_p` (key-share at first insert, row lock at
  update). Reachable from HUMAN and service paths; also against fire_timer and a parent's own
  completion, not only cancel.
* **I2 (HUMAN only): `A` vs the parent group.** HUMAN completion takes `A` (1.3) BEFORE the
  cascade's `P_p/T_p/S_p`; cancel takes `A` LAST (1.1 step 7). A HUMAN child completion holding
  `A` and waiting for `P_p`/`T_p`/`S_p` deadlocks against a cancel holding them and waiting for
  `A`, even after I1 is fixed. The service path takes `A` after the cascade, so it is
  consistent with cancel.
* Same family, out of scope here (open question Q1): `E` vs `P_p` (a child completion, HUMAN with
  `entity_writes` or service, holds `E` then wants `P_p`; a parent completion holds `P_p` then
  wants `E`; pre-existing), and `A` vs `S_p`
  between a HUMAN completer and a service-apply sibling of the same parent.

### 2.1 Choice: the cascade takes `P_p` then `T_p` (cancel is unchanged)

Canonical rule: **on the parent side every writer locks the parent projection first, then the
waiting token, then S, then (A)**; and a transaction that will cascade must hold the whole
ancestor group BEFORE its own `A`.

Rationale. Cancel, complete_task, fire_timer and ExecutionError already agree on "P before T";
the cascade is the only outlier, so moving the cascade changes one code path and fixes I1 for
every locker, while moving cancel (token before projection) would make cancel the outlier,
contradict `complete_task`/`fire_timer`, and still leave fire_timer vs cascade inverted.
Cancel's other documented ordering rules (timers/dispatch before `P`, `tasks` before `P`, `A`
last) stay as they are, and the service path's rules (E ascending before the cascade, `A`
last) are untouched.

What this disturbs and why it is safe: the cascade gets an extra row lock (`P_p`) earlier
than today; no other path takes `T_p` before `P_p`, so no new cycle forms. The HUMAN path
gains one early step (2.2). The service path changes only inside the cascade's lookup. The
child-before-parent direction is unchanged, and cancel never goes child-ward, so
child/parent cannot form a cycle.

### 2.2 Making I2 consistent without moving `A`

Moving the HUMAN audit after the cascade would reorder decision 0054 D3 rules 5/6 and the
per-line audit steps; rejected as larger and out of scope. Instead, add a prelock step to the
HUMAN tail, **before** the first audit step (`A`):

* When the transition result's final status is `:completed`, run `SubProcess.lock_waiting_parent_chain`
  (new, below) as the FIRST `Multi.run` of the advanced-clause tail in `build_complete_task_tail_multi`
  (key `:lock_ancestors`), BEFORE `:cancel_escalation_timers` and `:cancel_reminder_timers`
  (`engine.ex` ~:7088-7113), so no tail write precedes it. `P_c` (complete_task step 2) and `E`
  (steps run before the tail) are already held; the HUMAN order becomes
  `tasks_c -> P_c -> E -> P_p -> T_p [-> P_g -> T_g ...] -> (timers_c ... A) -> S_c ...`. A `[]`
  result (not a child, or no waiting parent) is a no-op. A non-`:completed` final status adds no step.
* Service path: no prelock step needed (`A` is already after the cascade); the cascade's own
  lookup calls the same function.

## 3. Public/internal shapes (signatures only)

New in `Letflow.Engine.SubProcess` (`@doc false`, called from `engine.ex`):

```
lock_waiting_parent(repo :: Ecto.Repo.t(), child_instance_id :: Ecto.UUID.t(), prefix :: String.t() | nil)
  :: {:ok, TokenRecord.t() | nil}
```
`find_waiting_parent_token/3` stays, with its name and `@spec`, as a thin delegate to
`lock_waiting_parent/3` (callers `engine.ex` ~:7288 and `sub_process.ex` ~:1169, and every existing
test, keep compiling unchanged). Semantics of `lock_waiting_parent/3`, in order:
(1) unlocked read of the `:waiting` token naming `child_instance_id` to learn `parent_instance_id`
(none -> `{:ok, nil}`); (2) `P_parent` `FOR UPDATE`; if that projection row is MISSING, skip the
projection lock and go on to (3) (the existing `:parent_projection_not_found` path in
`load_parent_context` stays the one that reports it, unchanged); (3) re-select the token `FOR UPDATE` with
the same predicate (`status = :waiting and waiting_child_instance_id = child`), the re-check
decides the result: a cancelled/advanced token returns `{:ok, nil}`. `P_parent` stays locked
when (3) yields nil (harmless, released at commit). Fixed order: P then T; one token per child
(existing assumption, unchanged).

```
lock_waiting_parent_chain(repo, child_instance_id, prefix) :: {:ok, [TokenRecord.t()]}
```
Calls `lock_waiting_parent/3` repeatedly, using the previous token's `instance_id` as the next
`child_instance_id`, until `nil`; returns the locked tokens nearest-first. It is speculative for
levels above the parent (the parent may not complete): it over-locks `P_g/T_g` for the
transaction's life, never under-locks. Used only by the HUMAN prelock step; idempotent with
the later cascade lookup (same transaction re-locks held rows without waiting).

Engine change: `build_complete_task_tail_multi` (advanced clause) gains the prelock `Multi.run`
step (key `:lock_ancestors`), conditional on the final status being `:completed`;
`append_sub_process_completion_cascade_multi` and `maybe_cascade_to_grandparent` are otherwise
unchanged (they already call `find_waiting_parent_token/3`). The cascade's ExecutionError branch (`engine.ex` ~:7310, `sub_process.ex` ~:1186-1193), which
calls `ExecutionError.append_multi` without `locked_projection`, becomes consistent for free: `P_p`
is already held by then. Error shapes unchanged. No schema,
migration, or API change. No new `{:error, _}`.

Timeout note: a completion with lines issues `SET LOCAL lock_timeout = '2s'` first, which bounds the
new early `P_p` wait too; a timeout there is classified as contention exactly as the later
cascade waits already are (no new error shape).

Behaviour that must not change: result values of `complete_task`, `cancel_instance`,
`apply_*_result`; event/audit contents and counts; a cancelled parent is never resumed
(token `:cancelled` -> nil), a still-`:waiting` parent resumes exactly once.

## 4. Outcomes after the fix (what the tests assert)

* Cancel first, cascade second: parent `:cancelled`, parent token `:cancelled`, child
  `:completed`, zero `SUB_PROCESS_COMPLETED`, no `EXECUTION_ERROR`/DLQ row. This is the "no
  double landing": the child completes, the parent is not resurrected.
* Cascade first, cancel second: parent token advanced, `SUB_PROCESS_COMPLETED` exactly once,
  cancel returns `{:error, {:instance_already_terminal, :completed}}` (parent graph is
  `start -> sp -> end`). This is the "no lost wakeup": the child's completion reaches the parent
  and cancel does not silently overwrite it.
* In every interleaving: no `40P01`/`{:transaction_failed, _}` on either side.

## 5. Tests (new file `test/letflow/engine/cancel_cascade_lock_order_test.exs`)

Technique (no sleep-coupled timing; same family as #2686's fix and the C2 cascade race test,
`service_task_entity_writes_lock_order_test.exs:195-260,368-384`): a **barrier row** held by a
third connection `Z` (`BEGIN; SELECT ... FOR UPDATE` on one `instance_sequences` row, kept open
by a process that waits for a `:release` message), two worker Tasks on their own connections
(sandbox mode as in that file's setup), and a bounded poll to learn that a worker is parked.
The helper counts DISTINCT blocked backends, not raw lock rows: join `pg_locks` (`NOT granted`) to
`pg_stat_activity` with `wait_event_type = 'Lock'`, restricted to the backend pids of the test's own
worker connections (each worker reports `pg_backend_pid()` before it starts), and waits for
`count(DISTINCT pid) >= n`; 10 ms steps, cap 500 iterations, failing with a named assertion. Order is therefore forced
by lock state, not by a delay. Fixtures use nodes WITHOUT `entity_writes` so no `SET LOCAL
lock_timeout` is issued and the waits are not bounded by the 2 s timeout. The module is `async: false`
(real concurrent connections, manual/shared checkout as in the C2 file's setup, fixtures created
per test with unique names). Every Task is `Task.await`ed with a 15 s bound; `Z` is always released in `on_exit`.

Parent graph: `start -> sp(SUB_PROCESS) -> end`; child: HUMAN node (path H) or an HTTP
SERVICE node (path S). The `Fx` fixture helpers (`Fx.activate!`, `Fx.service_graph`,
`Fx.legacy_activate!`, ...) are private to `service_task_entity_writes_lock_order_test.exs`: extract
them to `test/support/` (preferred, keeps that file's tests unchanged) or duplicate them. `D` = the child's completion (`complete_task/3` for path H; for path S the HTTP service apply
`advance_after_service_task_outcome/4` ONLY; script is excluded, a script task in a child is
unreachable until #2694),
`C` = `cancel_instance/3` on the parent.

| # | Path | Barrier held by Z | Start order | Forced interleaving | Pre-fix on main |
|---|---|---|---|---|---|
| T1 | H | `S_c` (child's sequence row) | D, wait 1 blocked, C, wait 2 blocked, release | D parked after `A` (pre-fix) / after `P_p,T_p` (post-fix); C runs up to its `A` (pre-fix) / blocks at `P_p` (post-fix) | red: 40P01 (I2 + I1) |
| T2 | H | `S_p` (parent sequence row) | C, wait 1 blocked, D, wait 2 blocked, release | C holds `P_p,T_p` parked at `S_p`; D arrives | red: 40P01 (D holds `A`, wants `T_p`) |
| T3 | S | `S_p` | D, wait 1, C, wait 2, release | D holds `T_p` (pre) / `P_p,T_p` (post) parked at `S_p`; C parks | red: 40P01 (I1) |
| T4 | S | `S_p` | C, wait 1, D, wait 2, release | cancel-first, service cascade arrives | green pre-fix is acceptable; must stay green |

T1 and T3 are "cascade first" (assert the first outcome of section 4's second bullet); T2 and
T4 are "cancel first" (first bullet). T1/T2 together satisfy the issue's two interleavings on
the HUMAN path, T3/T4 on the service path. Required red/green evidence: ELIXIR-DEV writes the
tests first, runs T1-T3 on bef9fe69 and quotes the 40P01 (or the `{:transaction_failed, _}`
wrapper), then quotes green after the change. If a pre-fix run does not go red, the barrier is
wrong: stop and fix the harness, do not weaken the assertion.

Per-test assertions: both Tasks return (no exit/timeout); neither result contains a
Postgrex `40P01` or `:deadlock_detected`; the end-state of section 4; the child is `:completed`
with exactly one `INSTANCE_COMPLETED`-class event; `SUB_PROCESS_COMPLETED` count (0 or 1 per
the case); `audit_log` has exactly one `instance.cancel` row iff C returned `{:ok, _}`; the
audit chain verifies (existing `Audit` chain verification helper) so `A` was not forked; no
rows in the instance-error/DLQ tables.

Plus a plain unit test of `lock_waiting_parent/3` (no concurrency): returns nil for a
non-child, nil for a cancelled parent token, the token for a waiting one; and of
`lock_waiting_parent_chain/3` on a 3-level fixture (returns two tokens, nearest first).

Existing suites that must stay green unchanged: `cancel_instance` tests, the sub-process
runtime/cascade tests (req062, ISS-0392/0975, GH #2648), `service_task_entity_writes_lock_order_test.exs`,
scheduler fire tests, `mix format --check-formatted` (full repo, read the rc),
`mix compile --warnings-as-errors`. CI-shaped local run before push per core-directives.

## 6. Moduledoc and comment updates (AC 1)

* `engine.ex` moduledoc "Lock ordering" paragraph (`Lock ordering` paragraph ~:359-372; GH #2587/C2/#2648 paragraphs ~:385-430): append the canonical table of 2
  (rows 1-8 and the child-before-parent rule) and the I1/I2 statement; replace "same-instance
  ... not a cross-instance one" with the cross-instance parent-side rule.
* Moduledoc ~:385 ("a sub-process child's completion cascade takes the parent token and projection
  after its entity-type locks") becomes "the parent projection, then the parent token, after its
  entity-type locks".
* Rewrite the GH #2648 paragraph (~:417-430): drop "NOT deadlock-free ... tracked as GH #2695";
  state the order `dispatch/CAS row, child projection, E, parent projection, parent token (and
  ancestors, same pair order), audit chain row`; state that the cancel/cascade and
  timer/cascade inversions are fixed, and what remains: the `E` vs `P_p` inversion (Q1; a
  deadlock there is classified as contention and re-applied for HTTP and planned script applies).
  Reword the unplanned-script sentence to say only that such an apply bypasses the retry driver, a
  deadlock lands `script_rejected`/`apply_failed`, accepted because a script task in a child is
  not reachable until GH #2694; no reference to #2695.
* Delete the "Not claimed deadlock-free ... tracked as GH #2695" sentence in the comment at
  `engine.ex` ~:5044-5056; replace it with a pointer to the table.
* `sub_process.ex`: `find_waiting_parent_token/3` `@doc` states "P_parent, then the token".
* Cancel's own code comments at :8412-8440 gain one line: "parent-side order: P then T, same as
  the cascade".

## 7. Risks and open questions

* **Q1 (out of scope, file a follow-up).** Two more inversions of the same family remain: `E`
  vs `P_p` (a child completion, HUMAN with `entity_writes` or service, holds `E` then cascades
  into `P_p`; a parent completion with
  entity_writes holds `P_p` then wants `E`), and `A` vs `S_p` between a HUMAN completer and a
  service-apply sibling of one parent (HUMAN: `A` then `S_p`; service: `S_p` then `A`).
  Deciding "A last everywhere" would change decision 0054 D3 rules 5/6; needs REVIEWER and
  SECURITY-REVIEWER input. Not fixed here; the table in section 2 makes them visible.
* **Q2 (stale open-tasks snapshot, pre-existing).** Cancel selects `tasks_p` BEFORE `P_p`. If a
  cascade (or any completer) commits while cancel waits and inserts a NEW pending parent task
  (e.g. the node after the sub-process is a HUMAN_TASK), `FOR UPDATE` in READ COMMITTED does not
  see it, so the cancelled parent can keep a pending task. The tests use `sp -> end` and do not
  hit it. Do not "fix" by re-locking tasks after `P_p` (that is a `tasks`-after-`P` inversion
  against `complete_task`). Recommended: separate issue (re-select tasks of the cancelled
  instance after `P_p`, locking only rows nobody else holds, or cancel by `update_all`).
* **Q3.** Over-locking: `lock_waiting_parent_chain` locks ancestors that may not complete.
  Cost is lock duration on `P_g/T_g` only for a completing sub-process child; accepted. If
  REVIEWER prefers precision, the alternative is prelock of the immediate parent only and
  accepting I2 for the grandparent level; not recommended.
* **Q4.** After `P_p` is locked and the token re-check passes, a parent whose projection is
  `:error` (not cancelled) is still resumed as today; this note deliberately adds no terminal
  check so behaviour stays identical. Confirm with REVIEWER that no behaviour change is wanted.
* **Q5.** A cancelled parent leaves its child running (1.1). Its completion becomes a no-op
  cascade. Cancelling children with the parent is a product decision, out of scope.
* **Risk.** The prelock changes the HUMAN path's first-wait point for a completing child
  (it may now wait on `P_p` before writing anything), which is the intended serialisation.
  Throughput impact is limited to sub-process child completions. SECURITY-REVIEWER: no
  tenant-data path, API, or response shape changes; all locks are prefix-scoped queries.
