# GH #2707 (TIMER-FIRE) - timer fire, escalation fire, child timers, cold appenders and the dead-instance timer

Status: design (CODE-DESIGNER). Base: origin/main 4d597ba8 (includes #2695, #2704, #2708, #2709).
Owner of the build: ELIXIR-DEV. No implementation code below: names, signatures, step orders and
test shapes only. Method: code read with grep/git only; NO `mix` was run (host is memory-starved),
so every statement is "verified by reading" unless it is listed in section 12 as unverified. All
file:line anchors were re-read on 4d597ba8 (not copied from the issue).

Family context: `lib/letflow/design/gh2704-lock-order-family.md` (sections 1.5, 2, 4.4, 10a, 10b),
decision `docs/migration/decisions/0061-engine-lock-order-platform-invariant.md` and the #2706 design
on branch `design/GH-2706-cancel-open-tasks` (`lib/letflow/design/gh2706-cancel-snapshot-and-lock-timeouts.md`;
read only; this note is consistent with it, section 9 lists the dependencies).
Notation as in the family note: `P_x` projection row of instance x, `T_x` its token rows, `S_x` its
`instance_sequence` row, `A` the tenant-wide audit chain row, `E` entity-type rows, `c`/`p` child/parent.
New here: `TM` a `timers` row, `TK` a `tasks` row, `W` any writer that takes `P_x` FOR UPDATE first
(complete_task, service/script apply, cancel, ExecutionError landing, pin rebind).

## 0. Verdicts in one screen

1. **Seven REAL cycles on main** (section 2): C1 cold TIMER_FIRED append (S_x then P_x) vs any W; C2 HUMAN
   tail timer cancel (P_x then TM) vs fire (TM then S_x/P_x); C3 `complete_task` (TK then P_x) vs
   escalation fire (P_x then TK); C4 cancel (TK then TM) vs escalation fire; C5 escalation fire (P_x then
   reminder TM) vs reminder fire (TM then S_x); C6 child timer fire: second UPDATE of the child
   projection takes FK locks on the parent token and projection with no group held (the #2708/#2709
   mechanism) vs cancel(p); C7 cold appenders (attachment events, Lua `emit_event`): S_x then P_x vs any W.
   One cycle named in the CDV review is UNREACHABLE as a separate cycle (C8, reminder fire `S_x` then `A`:
   section 2.3), and several pairs are benign (2.4).
2. **The chosen order puts timer rows AFTER `P_x`, not before** (section 3). The family note (4.4) leaned
   to "timers before `P`, complete_task pre-locks its timers". Re-derived here, that is worse: it needs a
   new pre-`P` lock in the hottest path, a `SKIP LOCKED` hack for recurring reminder successors, and an
   ordering rule among timer rows. Timers after `P_x` makes every timer lock a `P_x`-protected lock (like
   tokens), so no cycle between timer rows exists at all, `complete_task`'s tail is unchanged, and
   `cancel_instance/3` moves its timer UPDATE after `P_x` (which also closes #2706's R3 window for timers).
   `Scheduler.fire_timer/2` becomes `P_x`-first: peek the timer unlocked, lock `tasks` (escalation only),
   lock `P_x`, lock the ancestor group (key share), THEN lock the timer row, then the existing TIMER_FIRED
   append and advance. Decision 0061 is amended (section 10, verbatim).
3. **Child timer fires take the group `FOR KEY SHARE` (continuing intent) for every timer type**
   (section 5). A timer fire never runs the sub-process completion cascade on main (read, 5.2), so FOR
   UPDATE is not needed; this is a refinement of the family note's recommendation (FOR UPDATE), with the
   reasoning and the one consequence (a pre-existing gap) stated.
4. **Pending timer on a dead instance (#2706 CDV finding): fix it in `fire_timer`, not by a `SKIP LOCKED`
   recheck** (section 6), and it must ship WITH the `P_x`-first change, otherwise that change turns a
   bounded failure into an endless re-claim. Correction of the CDV finding by reading: on main a pending
   timer of a CANCELLED or COMPLETED instance is not re-claimed forever (the TIMER_FIRED append is refused
   with `{:instance_terminated, _}`, which lands in the failure accounting: 3 attempts, then `failed` plus
   a `timer` DLQ row); it is re-claimed forever only for an `:error` instance. Section 6 gives the red-first
   probe that pins which.
5. **PR split (section 9):** PR-1 the `P_x`-first fire + cancel timer move + dead-instance flip + 0061
   amendment; PR-2 cold appenders (`EventStore.append/2` locks the projection in its guard); PR-3 contention
   hygiene for the scheduler loop (lock timeout, `:contended` accounting, route 503). PR-3 depends on #2706
   PR-2; PR-1 depends on #2706 PR-1 (same function). No sub-issues (supervisor ruling for #2706): the split
   reason is recorded in each PR body; PR-1 `Closes #2822`, PR-1 and PR-2 say `Refs #2707`, PR-3 `Closes #2707`.

## 1. Inventory: the real lock order of every timer-related path on main

### 1.1 `Scheduler.fire_timer/2` (`scheduler.ex:278-318`, callers `attempt_fire/2` `521-571`, route `routers/instances.ex:793`)

Claim: `claim_due_timer_ids/2` (`240-270`) is an AUTOCOMMIT `SELECT ... FOR UPDATE SKIP LOCKED LIMIT 64
ORDER BY fire_at`: the lock lasts one statement, so it excludes nothing; the real mutual exclusion is the
FOR UPDATE inside `fire_timer/2`. Each tenant's poll loop is serial (`poll_and_fire/1`, `210-231`); tenants
run in parallel (`Poller`); the `advance-timer` route and other nodes' pollers can fire concurrently.

One transaction (`Repo.transaction`), in order:

| # | Step | Locks / writes | Anchor |
|---|---|---|---|
| 1 | `fetch_and_lock_timer` | `TM` FOR UPDATE (blocking, no `lock_timeout`) | `422-427` |
| 2 | `Timer.fire_changeset` update | `TM` UPDATE `fired` | `301-304` |
| 3 | `append_timer_fired_event` (COLD `EventStore.append/2`, idempotency key `timer_fired:<id>`) | guard: plain read of `P_x`; `S_x` FOR UPDATE; event insert; `P_x` UPDATE (#1 of the row) | `400-420`, `event_store.ex:680-698`, `700-760`, `897-910` |
| 4 | `route_fire` | by `timer_type`: `escalation` -> 4a, `reminder` -> 4b, else (`deadline`, `scheduled_transition`) -> 4c | `329-344` |
| 4a | `advance_after_escalation_timer_fired` | `P_x` FOR UPDATE (`engine.ex:4090`; already write-locked by step 3), tokens/tasks reads, then a Multi (a nested `repo.transaction`, which joins the outer one; the "SAVEPOINT" wording of the engine comments is unverified): `TK` (token_id, pending) FOR UPDATE (`4219-4228`), task cancel UPDATE, reminder `TM` update_all (`4254-4264`), `A` at `task.cancel` and `task.create` audits, token inserts/reconcile, timer arms, dispatch arms, sub-process children, `P_x` UPDATE #2 (`reconcile_projection`, `4362-4364`) | `4089-4381` |
| 4b | `record_reminder_fired` | plain read of the pending task (no lock, by design, comment `3993-3994`), `A` (one `task.remind` audit, `4015-4032`) | `4003-4038` |
| 4c | `advance_after_timer_fired` | `P_x` FOR UPDATE (`3702`, no-op re-lock), Multi (nested `repo.transaction`, joins the outer one): token inserts, task activation (`A`), timer/dispatch arms, children, `P_x` UPDATE #2 (`3938-3940`) | `3701-3980` |
| 5 | `maybe_rearm_timer` | INSERT of the successor `TM` | `313`, `472-494` |

Real order today: `TM, S_x, P_x(upd #1), [TK (escalation), reminder TM], A, ..., P_x(upd #2)`. No ancestor
group is ever locked. `P_x` is first locked by the UPDATE inside the TIMER_FIRED append, AFTER `S_x`.

### 1.2 Writers that conflict with it (re-read)

* `complete_task/3` (`build_complete_task_multi`, `engine.ex:2731-2860`): `TK` by id (`2742`), `P_x`
  (`2743-2745`), ..., `:lock_ancestors` (`2841`), E, then in the tail the status-guarded `update_all` of the
  task's pending escalation and reminder timers (`engine.ex:7257-7282`; the functions are
  `task_activation.ex:563`, `597`), then `A`, then `S_x` (`:event`), `P_x` UPDATEs. Order: `TK, P_x, [group], E, TM, A, S_x`.
* `cancel_instance/3` (`run_cancel_instance`, `engine.ex:8575-8664`): all pending `TK` (`8578`), instance-wide
  timer `update_all` (`8581-8605`, `task_activation.ex:535`), dispatch rows, `P_x` (`8620`), eligibility,
  `:lock_ancestors` (`8627`), ..., `S_x`, `P_x` UPDATE, `A`. Order: `TK, TM, dispatch, P_x, [group], T_x, S_x, A`.
  The comment at `8582-8597` calls "timers before projection" load-bearing "against `Scheduler.fire_timer/2`'s
  own timers-then-instance_projections order"; a source-position test pins it (`test/letflow/engine/timer_wiring_test.exs`
  ~`622-640`, "places :timer_cancellations between :open_tasks and :instance_projection").
* Service/script apply, ExecutionError landing, pin rebind: dispatch/CAS row then `P_x` (or `P_x` first), no
  timer rows, `S_x` after `P_x`.

### 1.3 Cold appenders other than the timer

`EventStore.append/2` (`event_store.ex:238-291`) is always its own transaction with a plain, unlocked
projection read as its first step (`active_instance_guard`, `680-698`), then `S_x`, then the `P_x` UPDATE.
Call sites (grep `EventStore.append(` in `lib/`, 15): in-transaction engine steps that hold `P_x`
(`engine.ex:2339` create, `3356`, `3407`, `5235`, `5767`, `6428`, `8146`, `8846`; `execution_error.ex:333`;
`pin_rebind.ex:529` after its NOWAIT projection lock; `sub_process.ex:709`, `1504` under the group lock
and, for a child created in the same transaction, its own just-inserted row), plus the cold ones:
`Repository.Attachments` ATTACHMENT_ATTACHED (`attachments.ex:375`, after commit, "best effort, any failure
logged and swallowed") and ATTACHMENT_REMOVED (`attachments.ex:413`), `Engine.Lua.Platform.append_emitted_event`
(`lua/platform.ex:866`, a script's `emit_event`; whether a transaction is open depends on the script route,
unverified, correct either way with PR-2), and the scheduler's TIMER_FIRED (this note). `append_multi/3`
(composable, used for entity-type synthetic instances in `entities/records.ex:749`, `979`) is not touched.

## 2. Pairwise cycles (real / benign / unreachable), with the interleaving

Mechanism recap used below: a row lock queue is FIFO; a waiter holds every lock it already has;
PG detects the cycle after `deadlock_detected` (1 s default) and aborts one victim. FK mechanism
(confirmed, 0061 amended by #2709): the SECOND UPDATE of a row inside one transaction (or an UPDATE of a
row inserted in it) queues `KEY SHARE` on the referenced parent rows; the first UPDATE of a committed row
takes none.

### 2.1 REAL cycles

| Id | Pair | Interleaving (holds -> wants) | Why it is real |
|---|---|---|---|
| C1 | fire (any type) vs any W | fire: `TM, S_x` -> `P_x` (the append's UPDATE) ; W: `P_x` (held through its tail) -> `S_x` (its `:event`/append step, after the tail) | the fire takes `S_x` before `P_x`, every W the reverse. Window: the append (guard, `S_x`, insert, idempotency insert, `P_x` UPDATE) while a W is in its tail. W candidates: complete_task of another task of the instance, apply, cancel, `set_instance_error`. 0054 D3 / the family note claim "every writer of the stream holds the projection mutex first": false for the timer. |
| C2 | HUMAN completion vs fire of the completed task's escalation or reminder timer | W: `TK, P_x` -> `TM` (tail `update_all`, `7257-7282`) ; fire: `TM` -> `S_x`/`P_x` (step 3) | classic AB-BA between `TM` and `P_x`. Wide window: the fire holds `TM` from step 1 to commit, completion holds `P_x` from step 2 to its timer step. |
| C3 | `complete_task` vs escalation fire on the same task | fire: `TM, P_x` -> `TK` (`original_task_row`, `4219-4228`) ; W: `TK` (`2742`) -> `P_x` (`2743`) | `tasks` taken after `P_x` by the fire. Narrow window (completion between its two first statements); the fire's window is wide (from `P_x` to `4222`). |
| C4 | `cancel_instance` vs escalation fire | fire: `TM` (and `P_x`) -> `TK` ; cancel: `TK` (`8578`) -> `TM` (`update_all`, `8581`) | cancel takes `TK` then `TM`, fire `TM` then `TK`. #2706 §8 recorded it as "pre-existing cycle, not fixed there". |
| C5 | escalation fire vs reminder fire of the same task | esc: `TM_esc, S_x, P_x` -> `TM_rem` (`cancel_reminder_timers`, `4254`) ; reminder fire: `TM_rem` -> `S_x`/`P_x` | two timers of one task, opposite orders. Needs two concurrent fire callers: another node's poller or the `advance-timer` route (the single-node poller is serial); not reachable inside one `poll_and_fire/1`. |
| C6 | CHILD timer fire (deadline/scheduled TIMER node, escalation) vs cancel(p) / completing sibling | fire: `TM, S_c, P_c`(upd #1, no FK lock) ... `P_c` upd #2 in `reconcile_projection` -> FK `KEY SHARE` `T_p` then `P_p` (token-first schemas) ; cancel(p): `P_p` -> `T_p` FOR UPDATE | the child's projection is UPDATEd twice and no group is locked; identical shape to #2708 (C2 of its tests). A reminder fire is NOT affected: it updates `P_c` once (the append) and the audit insert touches no child row. |
| C7 | cold appender (attachment event, Lua `emit_event`) vs any W | cold: `S_x` -> `P_x` UPDATE ; W: `P_x` -> `S_x` | same as C1; the append's first step is an unlocked read. Narrow window (one append) but unbounded W tail. A deadlock victim on the cold side is swallowed by `record_attachment_*_event` (logged); a victim on the W side is a failed completion/cancel/apply. For a child instance the cold append is one UPDATE of `P_c` only: no FK lock, no group needed. |

Pre-condition for all: nothing here needs a sub-process except C6; C1-C5 and C7 are reachable on a plain instance.

### 2.2 Why a retried victim hides them

`complete_task` without a plan has no `lock_timeout` and reports a victim as `{:transaction_failed, _}` (500);
the apply re-applies; a fire victim goes to the failure accounting and is COUNTED (`attempt_fire/2` generic
`{:error, _}` clause, `569`): three deadlocks make a healthy timer `failed` plus a DLQ row (sections 8.4 and 11, PR-3
fixes the accounting). Evidence therefore comes from the Repo telemetry handler of the forced-overlap
helper, as in the family tests.

### 2.3 Unreachable

* **C8, reminder fire `S_x` then `A`** (CDV finding, family note 2.4): not a separate cycle. For another
  transaction Y to hold `A` and want `S_x` of the reminder's instance x, Y must be writing x's stream, which
  every locked writer does only after `P_x` FOR UPDATE; the fire owns `P_x` as well as `S_x` the moment its
  append returns (the append's UPDATE). The only reachable interleaving is Y holding `P_x`, which makes the
  fire block INSIDE the append at `P_x` while holding `S_x`: that is C1. After PR-1 the fire holds `P_x`
  before `S_x` and C8 cannot even be stated. An unrelated `A` holder (another instance's transaction)
  never wants x's rows except a parent cascade, which locks `P_x` first.
* Parent cascade vs fire of the parent: the child completion locks the group (`P_p`, `T_p`) before any
  write of p; the parent fire holds `P_p` and never wants `P_c` (children are only created, never
  locked): no cycle. A parent fire creating a child that completes synchronously cascades under `P_p` held.
* A cold appender vs a cold appender: both `S_x` then `P_x`, same order, serialised on `S_x`.

### 2.4 Benign (cannot cycle; reason) and corrections to the first draft

* the SAME deadline timer vs cancel on main: cancel waits on that `TM` holding only `TK`; the fire never wants `TK` (deadline path): no edge back. A timer ARMED after cancel's `update_all` ran (a cascade committing while cancel waits at `P_x`) is not benign: the fire of it is C1 with W = cancel. (The escalation variant is C4.)
* two fires of the same timer (two nodes, or poller plus route): the second blocks on `TM`, then sees a non-pending row and returns `:already_final`.
* fire vs apply: NOT benign on main (an apply is a W, so it is C1: `S_x` before `P_x` in the fire); benign only after PR-1, when both serialise on `P_x`.
* a fire queued at `P_x` behind cancel's `P_x` while holding `TK` (escalation): not a cycle (cancel does not want a task row after `P_x`, except through #2706's recheck). In #2706's `SKIP LOCKED` recheck that `TK` is a leftover: cancel aborts and retries, and converges once the fire has committed.
* `record_fire_failure/2` (`610-638`, own transaction) holds `TM` only; `claim_due_timer_ids/2` is instantaneous (both are the exceptions named in section 10).

## 3. The chosen order and why not the family note's variant

### 3.1 Option A (family note 4.4): timers BEFORE `P_x`

Fire: `TM`, then `P_x`; `complete_task` adds a pre-`P_x` lock of its task's timers between `TK` and `P_x`;
cancel keeps `TK, TM, P_x`. Rejected because:
* the recurring reminder successor `TM'` is inserted by a fire AFTER a completer's pre-lock statement ran
  (the statement's snapshot cannot see it), so the completer's tail `update_all` (post-`P_x`) can meet a
  `TM'` that another fire already holds while queued behind `P_x`: a deadlock needing a `SKIP LOCKED`
  variant of the tail update (the recurring-successor window);
* it adds a statement and a lock wait to the hottest write path (every HUMAN completion);
* cancel would keep its pre-`P_x` timer update and so still miss timers armed while it waits at `P_x`,
  whereas under B cancel sees late-armed timers.
(The earlier draft also argued a timer-row ordering problem; that argument was weak and is dropped.)

### 3.2 Option B (chosen): timers AFTER `P_x`

Rule: **every path that locks or updates `timers` rows of an instance does so while holding that
instance's `P_x` FOR UPDATE.** Then all timer locks of one instance are serialised by `P_x`, so two timer
rows can never be waited for in a cycle, a recurring successor is created under `P_x` (so no
concurrent holder can miss it), and nothing that holds a timer row can want a row of an earlier class except what GO already allows.

Resulting per-path orders (GO classes of the family note). `timers` and `tokens` are both "P_x-protected"
rows: they are touched only while `P_x` is held, and their order AMONG THEMSELVES is unconstrained (a
waiter on either already owns `P_x`, so every other holder of them is itself serialised behind it). The
only constraints on the timer class are against rows that can be waited for without `P_x`: it comes after
E where a path takes both and before `A` and `S` where a path takes them:

| Path | Order |
|---|---|
| `complete_task` (unchanged) | `TK, P_x, group, E, TM(tail), A, S_x, P_x upd` |
| cancel (timer step moved) | `TK(all pending), dispatch/CAS rows, P_x, eligibility, group, [#2706: open_tasks_recheck], TM(update_all), T_x, ..., S_x, P_x upd, A` |
| fire, deadline / scheduled_transition | `peek, P_x, group(key share), TM, [S_x, P_x upd #1 (TIMER_FIRED)], tokens, A, ..., P_x upd #2` |
| fire, escalation | `peek, TK(token pending), P_x, group, TM, [S_x...], reminder TM, A, ... P_x upd #2` |
| fire, reminder | `peek, P_x, group, TM, [S_x, P_x upd], A` |
| cold append (PR-2) | `P_x, S_x, P_x upd` |

Cross-check against every earlier cycle: C1 (fire now `P_x` before `S_x`), C2 (fire holds `P_x` before
`TM`, completion holds `P_x` before `TM`: serialised on `P_x`), C3 and C4 (`TK` is taken by the fire BEFORE
`P_x`, the same relative order as `complete_task` and cancel, so the three serialise on the task row; a
fire with no pending task serialises on `P_x`), C5 (both fires take `P_x` before any `TM`), C6 (the group
is held before the second UPDATE, section 5), C7 (PR-2). `TK` stays in class 1 because `complete_task`
and cancel are built on it; the fire is the only path moved TO it.

Position of the new class relative to E and A: the fire takes no E (a fire never writes entity records;
service apply does that), completion takes E before its timer step, so `E < TM` holds for every path that
takes both; `TM < A` holds for every path (completion: timer step before the first audit; fire: the
reminder's single audit is the last write, the escalation/deadline audits come after `TM`).

### 3.3 The S/A positions inside the fire (rule 3 of 0061: lock-only steps do not reorder writes)

The TIMER_FIRED append stays exactly where it is (after the timer UPDATE, before `route_fire`); only locks
move earlier. Inside the fire `S_x` (L8) is therefore taken before `A` (L7), the reverse of GO. This is
safe because of invariant **I-S: every writer of a WORKFLOW instance's event stream holds `P_x` before taking
`S_x`** (entity-type synthetic streams take `S` then `P` and are outside it). A transaction that holds `A` and wants `S_x(x)` must hold `P_x(x)`, which the fire owns; so no
edge from an `A` holder to the fire exists. I-S is what PR-1 (fire) and PR-2 (cold appenders) establish;
it was claimed by 0054 D3 and is stated as a rule in the 0061 amendment (section 10).

## 4. PR-1: the fire becomes `P_x`-first

### 4.1 Signatures and steps

New engine function (the engine owns the projection and the group; the scheduler owns the timer row):

* `Letflow.Engine.lock_for_timer_fire(Timer.t(), repo :: Ecto.Repo.t(), prefix :: String.t()) ::
  {:ok, InstanceProjection.t()} | {:error, :instance_not_found} | {:error, term()}`, `@doc false`, called by the scheduler
  inside its transaction, BEFORE the timer row is locked. Steps, in this order:
  1. only when `timer_type == "escalation"` and `token_id` is not nil: the pending `tasks` rows of the token
     (`token_id = ^timer.token_id AND status = :pending`, the exact predicate of `original_task_row` at
     `engine.ex:4221`, `ORDER BY id`, `FOR UPDATE`; Ecto `lock/2`, no interpolated SQL);
  2. `P_x` FOR UPDATE with NO status filter (not `fetch_and_lock_instance_projection/3`, which refuses a
     non-active row with `{:instance_not_active, _}` and would lose the status the scheduler needs to
     settle a dead instance);
  3. only when the locked projection is `:active`: `lock_parent_group(repo, instance_id, :continuing, prefix)`
     (`engine.ex:8730`, KEY SHARE immediate parent, no-op for a non-child). A non-active instance takes no group.
  `{:error, term()}` is whatever `lock_parent_group/4` returns on failure (its spec allows it). The task predicate
  is shared, not copied: one private function (name chosen by the build) builds the query for both this
  step and `original_task_row` (`engine.ex:4219-4228`), so the two sets cannot drift apart.
  Returns the projection (any status). No write. The functions it replaces nowhere: `advance_after_*`
  keep their own `P_x` lock (now a no-op re-lock) and `original_task_row` keeps its `FOR UPDATE` (a no-op
  re-lock of rows already held; same set by construction, same predicate). No behaviour change for direct
  callers of `advance_after_timer_fired/3` (tests).

`Letflow.Scheduler.fire_timer/2` (spec in PR-1 unchanged: `{:ok, :fired} | {:ok, :already_final} | {:error, term()}`; PR-3 adds `{:error, :contention}` to the spec and a matching `attempt_fire/2` clause BEFORE the generic `{:error, _}` clause):

  1. unlocked read of the timer by id (`peek`); nil -> `{:ok, :already_final}`. The columns used (`instance_id`,
     `token_id`, `node_id`, `timer_type`) are immutable (the changesets `fire`, `retry_increment`, `fail`
     cast only status/count fields, `scheduler/timer.ex`), so the peek stays valid after the later lock;
  2. `Engine.lock_for_timer_fire(peek, Repo, prefix)`; `{:error, :instance_not_found}` -> `{:error, :instance_not_found}`
     (a counted failure as before);
  3. `fetch_and_lock_timer` (unchanged, `422-427`); non-pending -> `{:ok, :already_final}`;
  4. if the projection from step 2 is not `:active`: settle (section 6) and return `{:ok, :already_final}`
     (the transaction COMMITS the settle);
  5. `do_fire` unchanged (timer UPDATE, TIMER_FIRED append, `route_fire`, re-arm).

Cancel: `run_cancel_instance/5` moves `:timer_cancellations` from between `:open_tasks` and
`:instance_projection` (`8581-8605`) to immediately after `:lock_ancestors` (`8627-8634`) and, once
#2706 PR-1 is merged (it is, by the mandated merge order), immediately after its `:open_tasks_recheck` step and before
`:task_cancellations`; the dispatch and script-CAS steps stay before `P_x` (class 1, untouched). The
comment `8582-8597` is rewritten; `test/letflow/engine/timer_wiring_test.exs` (~`622-640`, the source-position
test) is FLIPPED (timer step after `:instance_projection`, `:lock_ancestors` and `:open_tasks_recheck`, before `:task_cancellations`). Behaviour: an
ineligible cancel no longer runs a timer UPDATE that rolls back; timers armed by a cascade while cancel
waited at `P_x` are now cancelled (closes the timers part of #2706's R3 exception; dispatch/CAS rows
remain that exception).

Stale comments rewritten in PR-1: `test/letflow/scheduler_test.exs` ~`440-450` (the "no active instance to append against" comment now describes the settle/`instance_not_found` behaviour) and `timer_wiring_test.exs` ~`954` (names the `{:instance_not_active, _}` special case that `fire_timer/2` no longer returns for a dead instance).

Docs: engine moduledoc "Lock ordering" (`engine.ex:359-474`): timers move out of item (1) into the new
item after (6); "Known gaps" (`446-449`) loses the timer/cold-append/escalation entries; `record_reminder_fired`
comment `3993-3994` ("takes no lock ... would add an inversion") is rewritten (the fire now holds `P_x`
and the pending-task read is consistent: every task status change needs `P_x`).

### 4.2 Behaviour that must not change

Results of `fire_timer/2` for live instances (`{:ok, :fired}`, `{:ok, :already_final}`), the TIMER_FIRED
event content and idempotency key, audit rows and their order, the re-arm, the event/audit counts, the
`advance-timer` route body. The ONE intended change: a timer of a dead instance is settled (section 6).

## 5. Child timer fires and the FK hazard (decision 3)

### 5.1 Where and which order

Hazard sites on a CHILD instance c: the TIMER_FIRED append is UPDATE #1 of `P_c` (first UPDATE of a
committed row: no FK lock); `reconcile_projection` (`engine.ex:3938` deadline, `4362` escalation) is
UPDATE #2: the FK checks `KEY SHARE` `T_p` and `P_p` fire in the schema's trigger order. No group is held
anywhere in the fire on main, so the second UPDATE queues behind a parent cancel's `FOR UPDATE` on `P_p`
while holding `T_p` (token-first schema) and cancel(p) then wants `T_p` FOR UPDATE: the #2708 deadlock
(C6). Reminder fires are single-UPDATE and exempt; uniform treatment is still chosen (one rule, one
statement-order test, one extra indexed lookup per fire).

Fix: the group is taken in `lock_for_timer_fire` step 3: after `P_c`, before the TIMER_FIRED append (the
first write), `:continuing`, i.e. `FOR KEY SHARE` on `P_p` then `T_p` (`SubProcess.lock_waiting_parent/4`
in key-share mode, `sub_process.ex:778-799`). This is the order of #2708 (cancel) and #2709 (landing).
Cancel(p) never goes child-ward, so nothing in the parent group wants `P_c`: acyclic.

### 5.2 Why key share and not FOR UPDATE (refines family note 4.4)

The family note recommended FOR UPDATE on the immediate parent because the hop chain that says whether the
fire completes the child runs after the first append. Re-read: the timer paths never run the sub-process
completion cascade. `persist_timer_fired_advance` and `persist_escalation_timer_fired_advance`
(`engine.ex:3809`, `4169`) end with `reconcile_projection` and call neither
`append_sub_process_completion_cascade_multi` (called only at `engine.ex:5199` service and `7401` HUMAN
tail) nor `SubProcess.lock_waiting_parent_chain`; a fire cannot resume the parent. A key-share group is
sufficient and does not serialise sibling fires. **Pre-existing gap, found by reading and NOT fixed here:**
a child whose last node is a TIMER (`TIMER -> END`) completes through `reconcile_projection` without any
cascade, so the parent token stays `:waiting` forever (the `Transition` comment at
`engine.ex:3801-3808` only argues no sibling timers can coexist). If it is a bug, its own issue must switch
the fire to the `:completing` intent, decided BEFORE the group lock, which needs the hop chain (pure, read
only) to run before the group lock: possible without breaking this design because the group lock sits
after `P_x`, before any write; recorded as open question Q2.

## 6. The dead-instance timer (decision 4)

### 6.1 What happens on main (by reading)

`do_fire` appends TIMER_FIRED first. For a CANCELLED/COMPLETED instance the append's guard returns
`{:instance_terminated, status}` (`event_store.ex:680-698`, `InstanceProjection.terminal?/1` is true for
`:completed`, `:cancelled`, `event_store/instance_projection.ex:224`); `do_fire` returns the error, the
transaction rolls back, `attempt_fire/2` takes the generic `{:error, _}` clause: `fire_error_count + 1` per
tick; at 3 (`@default_max_fire_retries`, `scheduler.ex:94`) the timer becomes `failed` and a `timer` DLQ row
is written (`land_exhausted_timer`, `640-664`). For an `:error` instance the append succeeds; then
`advance_after_*` returns `{:error, {:instance_not_active, :error}}` (`engine.ex:3537`), mapped to
`:already_final` (`543-544`) AFTER the rollback, so the timer is re-claimed every tick forever. Because the
claim is `ORDER BY fire_at ASC LIMIT 64`, 64 such immortal timers would starve every younger due timer
(head-of-line blocking). The #2706 CDV statement is thus right for `:error` only; the P1 probe of section 8.2
pins this on main before anything changes.

If PR-1 only added the `P_x`-first prelude and mapped a non-active projection to `{:error, {:instance_not_active, _}}`,
the cancelled/completed case would join the `:error` case (endless re-claim): a regression. Hence the settle
step belongs to PR-1.

### 6.2 Choice: `fire_timer` settles the row (not a `SKIP LOCKED` recheck)

* The `SKIP LOCKED` recheck is #2706's tool for tasks that a cancel must not MISS. It cannot help the
  timer problem: the cause here is not a missed cancel (cancel now cancels every timer after `P_x`, 4.1)
  but that nothing terminates a pending timer whose instance is dead by any other route (completion,
  `:error` landing, races before PR-1 is deployed, rows already on disk).
* Settling in `fire_timer` is self-healing for all causes, bounded to one tick per timer, and costs
  nothing for live instances.

Settle (step 4): under the already-held `P_x` the transaction runs the existing
`TaskActivation.cancel_pending_timers(repo, instance_id, now, reason, prefix)` (`task_activation.ex:535`):
status-guarded, instance-wide, so ONE fire clears all the dead instance's pending timers; safe because all
timer locks are `P_x`-protected (3.2). `reason` is `"instance_" <> status` (`"instance_cancelled"` and
`"instance_completed"` already exist as reasons; `"instance_error"` is new). The function returns
`{:ok, :already_final}`: no TIMER_FIRED, no DLQ row, no `fire_error_count` change.

Route consequence: the `advance-timer` route calls `fire_timer/2` directly (`routers/instances.ex:793`);
for a dead instance it answered 500 (the `{:error, _}` clause) and now answers 200 with
`timer_status: "already_final"`. Intended; noted for SECURITY-REVIEWER (no new data exposed).

## 7. Cold appenders (PR-2)

Fix at the one choke point instead of at each call site: **`EventStore.append/2`'s first step locks the
projection row `FOR NO KEY UPDATE` instead of the plain read** (`active_instance_guard`, `event_store.ex:680-698`,
used only by `build_multi/1`; the composable core used by `append_multi/3` and the `{:line, i}` namespaces
keeps its unlocked guard, because there the synthetic entity-type projection must keep the order "sequence
row, then projection row", 0054 D3 / rule 5, and the E pre-lock relies on it).

Signature impact: none (`append/2` spec unchanged). Internally the guard step receives a ctx flag
(`guard_lock`, true only from `build_multi/1`). The returned struct feeds `update_projection` unchanged.

Why this is neutral for every in-transaction caller: they already hold `P_x` (section 1.3), so the
re-lock returns at once; for the scheduler's TIMER_FIRED the prelude holds it; for the cold callers
(attachments, Lua emit) it turns `S_x, P_x` into `P_x, S_x`. Rejected alternatives: an opt-in option
(`lock_projection: true`) because forgetting it re-creates the defect silently; auto-detection by
`Repo.in_transaction?/0` because the test sandbox is "in a transaction" and prod/test behaviour would
diverge. Terminal or missing instances: the locking read returns the same row/nil, same errors
(`{:instance_terminated, _}`, `:instance_not_started`); the attachment path logs and swallows as before.
For a child instance the cold append is one UPDATE of `P_c`: no FK lock, no group needed (5.1).

Verification at build time (census): `sub_process.ex:709`, `1504` and the Lua route (`platform.ex:866`)
are the call sites not proven by reading to hold `P_x`; the census test (section 8.3, case A2) asserts the
statement order for every `EventStore.append/2` caller flow, so a caller found not holding `P_x` simply
becomes correct.

## 8. Test plan (reproduce first, deterministic forced overlap)

Infrastructure: `Letflow.LockOrderHelpers` (`test/support/lock_order_helpers.ex`): `hold_row/2`,
`forced_overlap/4`, `wait_for_blocked/2`, `attach_error_handler/1`, `set_fk_order!/2`, `fk_firing_order/1`.
Additions needed (PR-1): `hold_row/2` specs `{:task, task_id}` (also added by #2706 PR-1; reuse if
merged) and `{:timer, timer_id}` (`SELECT 1 FROM timers WHERE id = $1 FOR UPDATE`). Barrier rows by
spec: `{:sequence, x}`, `{:projection, x}`, `{:task, id}`, `{:timer, id}`. All files `async: false`, Sandbox
auto, fresh committed tenant per test, barriers released in `on_exit`, red quoted on the base commit by
ELIXIR-DEV before the fix. FIFO rule of the helper: first worker parks on the barrier, second parks behind
the barrier or the first; a victim of a retried failure is still reported by the telemetry handler.
Fixtures: (a) a HUMAN task with a reminder timer (`reminder_role` node attribute) and an escalation timer;
(b) `graph_timer_end` / `graph_timer_human_task_end` style deadline timers (`test/letflow/engine/timer_wiring_test.exs`);
(c) the sub-process fixtures of `cancel_child_lock_order_test.exs` with a child graph `TIMER -> HUMAN`.
Fire is invoked as `Scheduler.fire_timer(timer_id, schema)` (the unit under test) and force-due by setting
`fire_at` in the past via the fixture.

New files: `test/letflow/scheduler_fire_lock_order_test.exs` (PR-1), `test/letflow/scheduler_dead_instance_timer_test.exs`
(PR-1), `test/letflow/event_store_cold_append_lock_order_test.exs` (PR-2), `test/letflow/scheduler_fire_contention_test.exs` (PR-3).

### 8.1 PR-1 cases

| # | Case | Method (barrier; first worker; second worker) | On main | After |
|---|---|---|---|---|
| F0 | statement order, each timer type | `capture_repo_queries` of one uncontended `fire_timer`; no concurrency | red by reading: the first `instance_projections ... FOR UPDATE` follows the first `instance_sequence` lock; no group statement for a child | order: `timers` peek (plain), [escalation: `tasks ... FOR UPDATE`], `instance_projections ... FOR UPDATE`, [child: parent projection and token `FOR KEY SHARE`], `timers ... FOR UPDATE`, `timers` UPDATE, `instance_sequence` lock, events insert |
| F1 (C1) | fire vs a non-timer W | barrier `{:sequence, x}`. First: `fire_timer` of a deadline (or reminder) timer on instance x; second: `Engine.set_instance_error(x, ...)` (takes `P_x`, then wants `S_x`, touches no timer). Release | red: fire holds `S_x` and wants `P_x`, W holds `P_x` and wants `S_x`: 40P01 reported | green: fire parks holding `P_x`; W parks at `P_x`; no deadlock; both return; the fire (first worker, so it owns `P_x` first) returns `{:ok, :fired}`, the timer row is `fired`, then W lands: instance `:error`. Fixture: `TIMER -> HUMAN_TASK`, so the instance is still active after the fire |
| F2 (C2) | HUMAN completion vs reminder fire of the same task | barrier `{:sequence, x}`. First: reminder `fire_timer` (holds `TM`, parks at `S_x` on main); second: `complete_task` of that task (takes `TK`, `P_x`, parks at its tail timer update on `TM`). Release | red: 40P01 | green: fire parks at `S_x` holding `P_x`; completion parks at `P_x`; both return; exact end state (the fire is the first worker and holds `P_x`): the fire returns `{:ok, :fired}`, the reminder row is `fired` (non-recurring fixture), one `task.remind` audit exists, then the completion succeeds and the task is `completed`; the fired row is untouched by the completion |
| F3 (C3) | completion vs escalation fire on the same task | barrier `{:task, T}`. First: `complete_task(T)` (parks on `TK`); second: escalation `fire_timer` (on main takes `TM`, `P_x`, then parks on `TK`). Release | red: completion gets `TK` then wants `P_x` held by the fire: 40P01 | green: fire peeks, parks on `TK` behind the completion; completion finishes (cancels the escalation timer); the fire then finds a cancelled timer -> `{:ok, :already_final}`; no second task created |
| F4 (C4) | cancel vs escalation fire | barrier `{:sequence, x}`. First: escalation `fire_timer` (holds `TM`, parks at `S_x` on main); second: `cancel_instance(x)` (holds all `TK`, parks at its timer `update_all`). Release | red: fire then wants `TK` held by cancel: 40P01 | green: fire holds `TK` first; cancel parks at `TK`; after the fire commits cancel runs; exact end state (merge order mandates #2706 PR-1): fire `{:ok, :fired}`, original task `cancelled`, escalation task created then `cancelled` by cancel's recheck, escalation timer `fired`, instance `:cancelled`, no pending task or timer |
| F5 (C5) | escalation fire vs reminder fire (two callers) | barrier `{:sequence, x}`. First: escalation `fire_timer`; second: reminder `fire_timer` of the same task | red: esc holds `S_x`/`P_x`, wants the reminder `TM`; reminder fire holds `TM`, wants `S_x`: 40P01 | green: serialised on `P_x`; exact end state (the escalation is the first worker): escalation `fire_timer` returns `{:ok, :fired}`; the reminder row is `cancelled` with reason `task_escalated`; the reminder `fire_timer` returns `{:ok, :already_final}`; no `task.remind` audit |
| F6 (C6) | child timer fire vs cancel(p), token-first schema | `H.set_fk_order!(schema, token_first)` (precondition asserted via `fk_firing_order/1`); child graph `TIMER -> HUMAN`; barrier `{:projection, p}`. First: `cancel_instance(p)` parks at `P_p`; second: `fire_timer(child timer)` (on main reaches UPDATE #2 and parks on the FK check). Release | red: 40P01 on the `FOR KEY SHARE OF x` RI statement, as #2708 C2 | green: the fire parks at the group lock (`FOR KEY SHARE` on `P_p`) holding only `P_c`; cancel(p) completes; the fire then sees no waiting parent token and finishes; child `:active` task created, parent `:cancelled` (documented orphan semantics) |
| F6b | same with the projection-first FK order | `set_fk_order!` the other way | green (unreachable) | green (regression) |
| F7 | lock mode | statement trace of a child fire | n/a | group statements are exactly `FOR KEY SHARE`, never `FOR UPDATE`; a sibling's completing group (FOR UPDATE on its own token) does not block a fire of another child (no cycle, pins 5.2) |
| F8 | cancel timer step moved | source-position test FLIPPED (`timer_wiring_test.exs` ~`622-640`): `:timer_cancellations` after `:instance_projection`, `:lock_ancestors` and `:open_tasks_recheck`, immediately before `:task_cancellations` (the test matches that exact adjacency); plus behaviour: a timer inserted while cancel waits at `P_x` (barrier `{:projection, x}`, insert via the fixture before release) ends `cancelled` | red: that timer stays `pending` | green |
| F10 | regression | existing `timer_wiring_test.exs`, `human_task_escalation_test.exs`, `req494_*`, `cancel_cascade_lock_order_test.exs`, `cancel_child_lock_order_test.exs` unchanged | green | green |
| F9 | SCH-03 race (#2822 acceptance criterion 2) | (a) sequential: `claim_due_timer_ids/2` returns the timer id, `cancel_instance` commits, then `attempt_fire/2`; (b) overlap: barrier `{:projection, x}`, first `cancel_instance(x)` parks at `P_x`, second `attempt_fire/2` parks at `P_x`; release | (a) and (b) green on main by reading (cancel holds `TM` first; the fire parks on `TM`, then sees `cancelled`): a regression pin, not a red | `:already_final`, `fire_error_count` 0, no `timer` DLQ row, no TIMER_FIRED event |

Margins: the paths under test have no `lock_timeout` in PR-1 (PR-3 adds one); like #2708 the
helper's 2 s yardstick is reported in the PR description, assert `margin_ms >= 500` only for the cases that
run under a plan; F1-F8 assert no-deadlock and `Task.await` bounds (`await_ms`).

### 8.2 PR-1 dead-instance cases (`scheduler_dead_instance_timer_test.exs`)

| # | Case | On main (by reading; the probe pins it) | After |
|---|---|---|---|
| P1 | pending timer inserted on a `:cancelled` instance; `poll_and_fire` x4 | ticks 1-2 `errored: 1`, tick 3 `exhausted: 1`, timer `failed`, one `timer` DLQ row | tick 1 settles: timer `cancelled`, reason `instance_cancelled`, no DLQ row, `fire_error_count` 0; tick 2 `claimed: 0` |
| P2 | same on a `:completed` instance | same as P1 | `instance_completed` |
| P3 | same on an `:error` instance (via `set_instance_error`) | every tick `claimed: 1`, timer stays `pending`, never flipped (immortal) | tick 1 settles with `instance_error`; tick 2 `claimed: 0` |
| P4 | head-of-line: 3 immortal timers with `fire_at` older than a live due timer and `max_timers_per_cycle` = 3 | live timer never fires (red) | live timer fires on tick 2 |
| P5 | instance-wide: two dead-instance timers, one fire attempt | n/a | both `cancelled` after the first |
| P6 | route | `advance-timer` on a cancelled instance's pending timer -> 500 | 200 `already_final` |

### 8.3 PR-2 cold-append cases (`event_store_cold_append_lock_order_test.exs`)

| # | Case | Method | On main | After |
|---|---|---|---|---|
| A0 | statement order | `capture_repo_queries` of `EventStore.append/2` | `instance_projections` read is not FOR UPDATE and follows nothing; sequence lock before the projection UPDATE | `instance_projections ... FOR NO KEY UPDATE` precedes `instance_sequence ... FOR UPDATE` |
| A1 (C7) | cold appender vs W | barrier `{:sequence, x}`. First: `EventStore.append` of ATTACHMENT_ATTACHED (the type registered by the fixture; via the `Attachments` post-commit helper path when the file store fixture is available, else the generic append: both go through `append/2`); second: `set_instance_error(x)`. Release | red: 40P01 reported (the cold side's failure is swallowed in the real attachments path, the telemetry handler still sees it) | green: the append parks at `P_x`; no cycle |
| A2 | census | for each flow that appends via `append/2` (create, complete, cancel, apply, landing, rebind, cascade, creation, script record, Lua emit): `capture_repo_queries`, assert the first `instance_sequence` lock for instance x is preceded by `instance_projections ... FOR UPDATE` for x in the same transaction | red only for the cold flows | green |
| A3 | semantics | append for a terminal instance returns `{:instance_terminated, _}`, for a missing one `:instance_not_started`, for a duplicate key the original event; counts of events/projection updates unchanged | green | green |

### 8.4 PR-3 cases (`scheduler_fire_contention_test.exs`)

C-L1 a barrier `{:projection, x}` held longer than the fire lock timeout (test override, 300 ms):
`fire_timer/2` returns `{:error, :contention}` within the timeout plus margin, nothing committed (timer
still `pending`, `fire_error_count` unchanged, no TIMER_FIRED event). C-L2 `poll_and_fire/1` reports
`contended: 1`, `errored: 0`, emits the `[:letflow, :scheduler, :timer_contended]` telemetry event once and a
warning log, and the timer fires on the next poll after the release (never `failed`). C-L3 three consecutive
lock-timeout polls do not exhaust the timer (red on main: raised lock errors are counted, three exhaust the
timer to `failed` plus a DLQ row). C-L4 `Contention` classifier: 55P03 -> uncounted `:contended`; 40P01 ->
the existing COUNTED failure (a deterministic deadlock is a defect that must surface through the retry cap
and the DLQ, not be retried forever uncounted); non-contention errors counted as before. C-L5 the timeout is
transaction-local and bound as a parameter (statement trace shows the `set_config` form, as #2706 T5/T6).
C-L6 route: `{:error, :contention}` -> 503 with a constant detail. C-L7 same-instance skip: two due timers of
instance x and one of instance y in one cycle, the first contended: the second of x is not attempted
(`claimed` 3, attempted 2), y fires. C-L8 cycle budget (5 s by default): with the budget forced to 0 ms the cycle returns
after the first timer, the rest stay `pending` and fire next poll. C-L9 first-poll settle burst emits one
`[:letflow, :scheduler, :timers_settled]` event per settled instance (count in measurements).

## 9. PR split, sizes, ordering, dependencies

| Order | PR | Content | Size (est.) | Depends on |
|---|---|---|---|---|
| 0 | docs | this note | 1 file | - |
| 1 | PR-1 | `lock_for_timer_fire`, scheduler restructure, settle of dead-instance timers (+ telemetry/log), cancel timer step moved, stale-comment fixes, docs/moduledoc, 0061 amendment (section 10), tests F0-F10, P1-P6, helper specs | prod ~110 lines (`engine.ex` ~60, `scheduler.ex` ~40, comments), tests ~700 | #2706 PR-1 merged first (same function `run_cancel_instance/5`, same 0061 file, `{:task,id}` spec) |
| 2 | PR-2 | `EventStore.append/2` guard lock (`FOR NO KEY UPDATE`), A0-A3, 0061 "Amended (GH #2707, PR-2)", moduledoc line | prod ~15, tests ~250 | after PR-1 |
| 3 | PR-3 | fire lock timeout, `{:error, :contention}`, `:contended` counter, telemetry + warning, same-instance skip, cycle budget, route 503 clause, C-L1..C-L9 | prod ~80, tests ~300 | #2706 PR-2 (`Letflow.Engine.Contention` and the bound `set_config` statement); PR-1 |

Strictly sequential (one functional PR in CI at a time; no docs-only merge while one is in CI). PR-1 must be
one PR: the cancel timer move and the fire's `P_x`-first order are opposite orders of the same two rows and
cannot ship apart (3.2); PR-1 also carries the settle step (6.1).

Issue handling (supervisor ruling for #2706, applied here): NO sub-issues. The reason for the split (three
independently revertable changes, each with its own red-first tests; PR-1 and PR-2 cannot be one PR
without mixing a lock-order reversal with a one-line guard change; PR-3 depends on #2706 PR-2) is recorded
in each PR body. #2707 stays open until PR-3: PR-1 and PR-2 say `Refs #2707`, PR-3 says `Closes #2707`.
PR-1 says `Closes #2822` explicitly. Because the P1 probe contradicts #2822's acceptance criterion 1
(a terminated instance's timer is not re-claimed forever; it fails 3 times and lands in the DLQ), a
corrective comment on #2822 is needed: ask the supervisor / letflow-2 to post it (this agent does not
post to GitHub).

SECURITY-REVIEWER: tenant-data path yes for all three (prefix-scoped row locks on tenant tables; PR-3 adds
a bound-parameter `set_config`, INV-7; PR-1 changes the `advance-timer` route's observable result for dead
instances; PR-3 touches `routers/instances.ex`). None of the WF-02 Step 2c trust-boundary files is touched
(no `ci.yml`, `mix.exs`, `permission_matrix.ex`, `authorization.ex`, `authorized_router.ex`,
`route_scope.ex`, `scope/enforce.ex`, `modules/catalog.ex`, config). INV-1 every new query carries the prefix;
INV-4/INV-5: the 503 detail is a constant and no exception text is returned; the settle step writes only the
timer's own status/reason. REVIEWER mandatory on all three (0061 amendment in PR-1 and PR-2). RELEASE-VALIDATOR
re-runs the new files.

PR-3 specifics (scheduler loop):

* **Lock timeout choice: ~2 s applied to EVERY lock wait of the fire transaction, PER WAIT, not cumulatively** (one bound `set_config('lock_timeout', ...)`
  as the first statement, a dedicated `:timer_fire_lock_timeout_ms`, 2000 default, 300 in the test config
  under `:engine_test_seams`; skipped when `Repo.in_transaction?()`, as #2706 3.4). A 500 ms bound over the
  whole transaction would also bound the waits on `S_x` and on the tenant-wide `A`, which are plain FIFO
  queueing behind long completions: a fire could starve. 2 s matches the entity-write plan timeouts and a
  contended timer is retried 5 s later at no penalty. Because the bound is per wait and a fire can wait
  on up to about six locks (`TK`, `P_x`, group parent projection, group token, timer row, `S_x`, `A`), a
  single fire can take several times 2 s in the worst case; the cycle bound below accounts for that. The prelude locks alone are not given a tighter bound
  (one value, one rule).
* **Per-tenant budget.** `@default_sweep_task_timeout_ms 10_000` (`scheduler.ex:112`) kills the tenant's
  task; 64 timers x 2 s per wait exceeds it. Two bounds, chosen as the LOWER-BUDGET option (not a worst-case gate): (1) after the first `:contended` result for an instance,
  the remaining timers of THAT instance in the same cycle are skipped (not attempted, left `pending`);
  (2) `poll_and_fire/1` stops starting new fires once 5 s of monotonic time have elapsed in the cycle (half the 10 s tenant task budget, leaving room for
  one in-flight fire of several times 2 s). The `on_timeout: :kill_task` of the sweep remains a rare, safe
  rollback (the killed transaction aborts whole; the timer stays `pending` and is retried next tick). Both
  bounds leave rows `pending`, so nothing is lost.
* **Observability.** `Poller` discards `poll_result` (`poller.ex:255-258`), so a `contended` key alone is
  invisible. PR-3 emits `[:letflow, :scheduler, :timer_contended]` (measurement: count 1; metadata:
  tenant schema, timer type, SQLSTATE class tag only) and a `Logger.warning` with the classified tag only
  (no exception text). PR-1 emits `[:letflow, :scheduler, :timers_settled]` (measurement: count; metadata:
  tenant schema, reason) plus an info log per settled instance, so the first-poll burst after deploy
  (up to 64 timers per tick per tenant) is visible.
* **Retry cap.** Only 55P03 is uncounted. A 40P01 stays a counted failure (existing accounting), so a
  deterministic deadlock cannot be retried forever uncounted; after three it lands as `failed` plus the
  `timer` DLQ row, which is the correct escalation for a defect.
* **Existing test that breaks:** `test/letflow/scheduler_test.exs:618-625` (ISS-0444 "returns an all-zero
  poll_result") asserts the WHOLE map with `==`; it must gain `contended: 0` in PR-3. A grep of all
  `poll_and_fire` map assertions precedes the push (the other call sites match partial maps).
* `fire_timer/2`'s `@spec` lists `{:error, :contention}`; `attempt_fire/2` gets the contended clause before the
  generic `{:error, _}` clause (`568`); `{:error, {:raised, exception}}` from a raised lock error is classified
  through `Letflow.Engine.Contention` first.

## 10. Decision 0061 amendment (PR-1 appends the first block; PR-2 appends the second; REVIEWER gate)

PR-1 follows #2706 PR-1 (mandated merge order), so this is the final text with no conditionals. It
SUPERSEDES, in the record, two statements of "Amended (GH #2706, PR-1)" and of the #2706 design note
(`gh2706-cancel-snapshot-and-lock-timeouts.md` section 2.5, which puts timers in "class 1" and lists "timers
and dispatch rows armed during cancel's wait" as an exception); the docs PR for this note adds a one-line
"Superseded in part by gh2707 section 10" pointer to that section. It also CLOSES the "## Open" bullet of 0061.

> ## Amended (GH #2707, PR-1)
> 1. **Timer rows are P-protected.** Rule 1 item 1 is amended: it is the instance's own `tasks` rows and its
>    dispatch / script-CAS rows, taken before `P_x`; `timers` rows are NOT part of it (this supersedes the
>    parenthetical "the pair cannot cycle because tasks are contended only by completers and cancel": tasks
>    are contended by completers, cancel AND the escalation fire, and the three take the task row first, so
>    they serialise on it). The instance's own `timers` rows, like its tokens, are touched ONLY while `P_x`
>    is held `FOR UPDATE`, and their order among themselves and against the live tokens is unconstrained
>    (every waiter on them already owns `P_x`). Against the other classes a path that takes them takes
>    them after the entity-type rows and before the audit chain row and the sequence rows. The paths:
>    `Scheduler.fire_timer/2` (through `Engine.lock_for_timer_fire/3`), the tail of `complete_task/3`, the
>    escalation fire's reminder cancellation, `cancel_instance/3` (its timer UPDATE moves after `P_x`, the
>    ancestor group and the open-tasks recheck). Two statements do not hold `P_x` and are the only
>    exceptions: `Scheduler.claim_due_timer_ids/2` (an autocommit `SKIP LOCKED` read; the lock lasts one
>    statement and nothing waits on it) and `Scheduler.record_fire_failure/2` (its own transaction, holds the
>    timer row alone and waits for no other lock). Consequence: timer rows of one instance can never be
>    waited for in a cycle; timers armed while a cancel waits for `P_x` are cancelled by it; dispatch and
>    script-CAS rows armed in that window remain the only cancel exception (this replaces the sentence of
>    "Amended (GH #2706, PR-1)" that lists timers and dispatch rows).
> 2. **The fire path.** A timer fire takes, in this order: the pending `tasks` rows of the timer's token
>    (escalation timers only; the same relative order as `complete_task/3` and `cancel_instance/3`), `P_x`,
>    the ancestor group `FOR KEY SHARE` of the immediate parent, then the timer row, then the existing
>    TIMER_FIRED append and advance. The mode is key share (a continuing step) because a timer fire does not
>    run the completion cascade; this closes the "## Open" bullet of this record and overrides the family
>    note's FOR UPDATE leaning. The group is taken before the first write of the child's projection, so the
>    second UPDATE of that row (`reconcile_projection`) finds its foreign-key locks already held (the
>    #2708/#2709 mechanism). A timer whose instance is not `:active` is settled (every pending timer of the
>    instance cancelled with reason `instance_<status>`) and the transaction commits; it is never re-claimed.
> 3. **Invariant I-S (workflow instances).** Every writer of a workflow instance's event stream holds
>    `P_x` before it takes that instance's `S_x`. The timer fire establishes it for TIMER_FIRED in this
>    amendment; the remaining cold appenders (attachment events, a Lua `emit_event`) stay exceptions until
>    GH #2707 PR-2. The streams of entity-type synthetic instances are outside I-S: they keep rule 5's order,
>    sequence row then projection row. Within a transaction that holds `P_x`, taking `S_x` before the audit
>    chain row `A` (the timer fire's TIMER_FIRED append precedes its audits) is permitted: a transaction
>    that holds `A` and wants `S_x` of a workflow instance must hold that instance's `P_x` first.
> 4. Rule 6 no longer lists as exceptions: the HUMAN tail's timer cancel after the projection,
>    `Scheduler.fire_timer`'s TIMER_FIRED append and reminder fire, and escalation fire's `tasks` lock after
>    the projection. It STILL lists, until GH #2707 PR-2: cold `EventStore.append/2` callers that append
>    before locking the projection (attachment events, a Lua `emit_event`). The sentence of "Amended
>    (GH #2706, PR-1)" about timers and dispatch rows armed during cancel's wait for `P_x` is replaced by:
>    "Dispatch and script-CAS rows armed during cancel's wait for `P_x` are the remaining cancel exception."
> 5. Rule 5 (new code) is unchanged and applies to the timer class: new code that locks timer rows locks
>    them under `P_x`.
> 6. The "## Open" bullet (lock mode for child timer fires) is closed by item 2.
>
> Rolling deploy: opposite orders of the same two rows now coexist in two symmetric mixed windows: an old
> `cancel_instance/3` (timers before `P_x`) against a new fire (`P_x` before the timer), and an old fire
> (timer, then `P_x`) against a new `cancel_instance/3` (timers after `P_x`). Either pair can produce a
> recoverable `deadlock_detected` (a failed cancel, or a counted fire failure); no other pair is affected.

> ## Amended (GH #2707, PR-2)
> `EventStore.append/2` takes `FOR NO KEY UPDATE` on the instance's projection row in its first step
> (before `S_x`), so I-S holds for every `append/2` caller: the cold appenders (attachment events, a Lua
> `emit_event`) are no longer exceptions in rule 6 and item 3 of "Amended (GH #2707, PR-1)" applies without
> the cold-appender qualification. `append_multi/3` callers hold `P_x` by construction (entity-type
> synthetic streams excepted, rule 5).

The Status line of 0061 is extended to say "#2707 PR-1 to PR-3" (the Related line already names #2707 on main; nothing else in the header changes). Q9 (FOR NO KEY UPDATE) is adopted:
it conflicts with every `FOR UPDATE` / `FOR NO KEY UPDATE` holder, so the I-S ordering is intact, and it
lets a child's `KEY SHARE` FK check pass during a cold append of its parent.

## 11. Risks (timers fire in a scheduler loop)

1. **Back-pressure and head-of-line.** One tenant's poll is serial within a 10 s task budget
   (`scheduler.ex:107-112`, `Task.async_stream ... on_timeout: :kill_task`). PR-1 does not bound waits; PR-3
   does (section 9, PR-3 specifics: 2 s per-wait timeout, per-wait lock timeout, same-instance skip, 5 s cycle budget).
   Persistent contention on the oldest 64 timers still delays younger timers; it indicates a stuck
   transaction and is alerted through the PR-3 telemetry.
2. **Retries and exhaustion.** Today a raised deadlock/lock-timeout in a fire is counted
   (`attempt_fire/2` -> `safe_record_fire_failure/2`). PR-3 makes 55P03 uncounted and keeps 40P01 counted.
   Until PR-3 the exposure shrinks with PR-1 (the cycles are gone) but remains.
3. **Rollout with in-flight timers.** Lock order is a per-transaction property; no migration, no persisted
   state to convert. Pending timers of live instances fire as before. The first poll after PR-1 settles
   every pending timer of a dead instance (up to 64 per tick per tenant, one instance-wide statement per
   instance); for `:error` instances this cancels timers that were previously immortal (Q3). Visibility:
   `timers_settled` telemetry and log (section 9). The two mixed old/new windows are stated in the 0061
   amendment. Rollback is a plain revert (timers settled in the meantime stay cancelled, which is correct).
4. **Throughput and index.** Fires now hold `P_x` while waiting for the timer row and the group. A child
   fire adds a key-share lookup (indexed on `tokens.waiting_child_instance_id`,
   `20260819045553_add_sub_process_parent_columns.exs:50`). `timers` has NO `instance_id` index (the
   `create_timers` migration comment, line ~60: only the partial pending index serves the claim): the settle
   statement and cancel's instance-wide update scan the pending index, as cancel's already does. Not
   blocking; ELIXIR-DEV measures the settle and cancel statements on a populated tenant and records it in
   PR-1. PR-2 adds a `P_x` lock to cold appends, which already serialised on `S_x`.
5. **Peek/lock gap.** The unlocked peek can race with completion/cancel; the locked re-check
   (`status != pending` -> `:already_final`) resolves it. A peek that finds the timer absent returns
   `:already_final`.
6. **Test load.** Forced overlaps use 3 connections; each file within the per-session cap; barriers
   released in `on_exit`; polls bounded (helper `await_ms`).

## 12. Open questions, follow-ups and unverified items

Open questions for the supervisor (defaults as ruled by the CDV / coordinator):

* **Q1 (order).** Timers AFTER `P_x` (agreed by CDV). Closed.
* **Q2 (mode and a possible bug).** Key share for all child timer fires. Closed. The bug is follow-up F-1.
* **Q3 (`:error` instances).** Settle pending timers of `:error` instances as `cancelled` with reason
  `instance_error`. No code path resumes an ERRORed instance (`Dlq.retry/2` documents that it does not,
  `dlq.ex:12-16`; grep found none); if a resume is planned it must re-arm timers. Confirm.
* **Q4 (timeout).** Decided: one ~2 s lock timeout applied per wait to every lock of the fire transaction, the same-instance skip for
  the rest of the poll cycle, and a 5 s poll-cycle budget with `:kill_task` as a rare safe rollback (section 9). Needs the #2706 helper to take the millisecond value as an
  argument; if it does not, PR-3 adapts it.
* **Q5 (route).** `advance-timer` answering 200 `already_final` instead of 500 for a dead instance, and 503
  for contention. Default yes.
* **Q6 (issues).** Decided: NO sub-issues; split reason in each PR body; #2707 closes with PR-3; PR-1
  closes #2822.
* **Q7 (coordination with #2706).** PR-1 waits for #2706 PR-1; PR-3 for #2706 PR-2. Mandated.
* **Q8 (`poll_result`).** New `contended` key; `scheduler_test.exs:618-625` updated (PR-3).
* **Q9 (cold default).** `append/2` locks by default, with `FOR NO KEY UPDATE`. Adopted (section 10).
* **Q10 (legacy corner).** An escalation timer whose token has no pending task takes no `tasks` lock and
  serialises on `P_x` only; cannot cycle (timers are P-protected). No action.

Follow-ups to file (NOT part of #2707's PRs; the supervisor / letflow-2 files them):

* **F-1.** A child whose last node is a TIMER (`TIMER -> END`) completes through `reconcile_projection`
  without any completion cascade, so the parent token stays `:waiting` forever (5.2). Needs a red test first
  (child graph `TIMER -> END`, fire the timer, assert the parent resumes). If fixed, the fire decides
  `:completing` before the group lock.
* **F-2.** The ExecutionError landing should cancel the instance's pending timers (under the `P_x` it
  already holds, so rule 1 item 1 is respected): that is the root cause of the `:error`-instance leak that
  PR-1's settle only cleans up after the fact.
* **F-3.** Index on `timers.instance_id` if the PR-1 measurement shows the settle/cancel scan is costly.

Unverified (no `mix` was run): every cycle in section 2 (reading only; section 8 are the reproductions);
that `reconcile_projection` is the second UPDATE of `P_c` in a child fire; the "SAVEPOINT" wording of the
engine comments (`engine.ex:3691`, `3793`): an Ecto nested `repo.transaction` joins the outer transaction,
so the FK "same transaction" rule applies whichever it is, and F6 measures it; that the timer fire never
cascades (grep of the two call sites); whether the Lua `emit_event` route holds a transaction; the exact
`timer_wiring_test.exs` line numbers; whether any test asserts the old 3-attempt DLQ outcome for a
terminated instance (grep `exhausted`/`timer` DLQ assertions in `scheduler_*_test.exs` before pushing
PR-1); the `margin_ms` of the green cases (measured and recorded by ELIXIR-DEV).

## 13. Acceptance-criteria map (issue #2707, its amendments and #2822)

| Criterion | Where |
|---|---|
| Real order of every timer path with file:line | 1 |
| Real vs benign vs unreachable per pair, with the interleaving | 2 |
| Fix consistent with 0061, per real cycle | 3, 4, 5, 7; amendment text 10 |
| Child timer FK hazard: where, which order | 5 (C6, F6) |
| Cold appenders (attachments, reminder, first TIMER_FIRED) | 2.1 C1/C7, 2.3 C8, 7 |
| Escalation `tasks` after `P_x` | 2.1 C3/C4, 4.1 |
| Pending timer on a dead instance: choice | 6 (settle in `fire_timer`; probes P1-P6; concurrent SCH-03 case F9; PR-1 `Closes #2822`) |
| Reproduce-first deterministic tests, exact end states | 8 |
| PR split, SECURITY-REVIEWER triggers, risks, rollout | 9, 11 |
| 0061 amendment verbatim, one appendable text, closes the Open bullet | 10 |
| 2026-10-18 residual comment on #2707 (cancel sets no `lock_timeout`; the ExecutionError landing step raises at `execution_error.ex:219` with no DLQ row) | owned by #2706 PR-2 (cancel lock timeout) and #2706 PR-3 (landing); NOT in #2707's PRs. #2707 closes with PR-3 on the condition those two have merged; referenced in each of this note's PR bodies |

## 14. As built (PR-1)

Written by ELIXIR-DEV after the build, on REVIEWER finding F1. Where this section and the sections above
disagree, this section describes what shipped. Commit `168d8409` plus its review follow-up.

1. **F6b is RED on main (the section 8.1 row F6b claim "green (unreachable)" is wrong).** With the
   projection-first foreign-key order the child timer fire still deadlocks against `cancel_instance(parent)`
   on main (Postgres reported `deadlock_detected` on the `SELECT 1 FROM ONLY instance_projections x ...
   FOR KEY SHARE OF x` statement of the foreign-key check). Why, by reading and consistent with that report
   (the cycle was not separately measured): the foreign-key order only decides whether the parent TOKEN is
   also part of the cycle. The fire already holds the tenant-wide audit chain row `A` (its `task.create`
   audit) and the child's sequence row when `reconcile_projection` issues UPDATE #2 of `P_c`, whose check
   queues `KEY SHARE` on `P_p` behind cancel(parent). Cancel(parent) holds `P_p` and wants `A` for its
   `instance.cancel` audit, so `P_p` versus `A` closes a cycle in EITHER foreign-key order; the token-first
   order adds the `T_p` cycle of F6. After the fix the group is taken before `A` and before the first write,
   so both orders are green. F6 and F6b share one body in the test file.
2. **Child fixture graph.** A child created through a SUB_PROCESS node does not arm a TIMER that directly
   follows its START. The F-tests use the child graph START -> HUMAN (h0) -> TIMER -> HUMAN (h1) -> END and
   complete h0 to arm the timer.
3. **Peek shortcut (a small extension of section 4.1 steps 1 and 3).** After the unlocked peek,
   `fire_timer/2` returns `{:ok, :already_final}` at once, taking no lock, when the peeked timer is not
   `pending`. Safe because the terminal statuses (`fired`, `cancelled`, `failed`) never revert to `pending`.
   The locked re-check of step 3 stays for the race where the status changes after the peek.
4. **F7 is a pin, not a red.** The `FOR KEY SHARE` group statements and the "a sibling's key share does not
   block the fire" case pass on main too (main takes no group at all); they pin the mode of the new lock.
   The sibling case holds `FOR KEY SHARE` on the parent projection from another connection; it does not
   build a second child with a completing `FOR UPDATE` group.
5. **Telemetry and log after the commit.** The `[:letflow, :scheduler, :timers_settled]` event and the info
   log are emitted after `Repo.transaction/1` returned, so a rolled-back settle never announces itself.
   Measurement `count` is the number of timers the instance-wide statement cancelled.
6. **Verified for the 0061 amendment, item 1** (SECURITY F6): every writer of `timers` rows holds `P_x`
   (or a row nobody else can see) except the two named exceptions. The paths read: the `complete_task/3`
   tail (`:cancel_escalation_timers`, `:cancel_reminder_timers`, after `:instance_projection`); the
   escalation fire's reminder cancellation and the arm inserts (inside the fire, after the prelude);
   `cancel_instance/3` (`:timer_cancellations`, after `:instance_projection`); the settle (after the
   prelude); and `finalize_instance_projection/5`'s `instance_completed` cancel, whose only caller is
   `create/2` and which runs on a projection row inserted by the same transaction (no other transaction can
   see it). `record_fire_failure/2` (own transaction, timer row alone, plus its DLQ insert) and
   `claim_due_timer_ids/2` are the exceptions the amendment already names.
7. **Irreversibility of the `:error` settle** (SECURITY F2) is documented on `Scheduler.fire_timer/2`: the
   reason string `instance_error` is greppable, and a future resume / reconstruct feature must re-arm the
   timers.

## 15. As built (PR-3)

Written by ELIXIR-DEV after the build. Where this section and sections 8.4 and 9 disagree, this section
describes what shipped. Decision 0061 is NOT amended by PR-3 (section 10 lists only the PR-1 and PR-2
blocks; PR-3 adds no lock, no order and no writer).

1. **Timeout source.** `Letflow.Engine.Contention.timer_fire_lock_timeout_ms/0` reads
   `config :letflow, :timer_fire_lock_timeout_ms` (default 2000, no config entry added). The test value
   is NOT a global 300 in `config/test.exs` (it would shorten every legitimate queueing wait of every
   other test's fires): a build with `:engine_test_seams` reads the process-local key
   `:timer_fire_lock_timeout_ms_override` of the calling process, the same mechanism as `lock_timeout_ms/0`.
2. **The statement.** `Letflow.Engine.set_timer_fire_lock_timeout/2` (`@doc false`, in `engine.ex`, so the
   `set_config` string stays inside the T-11 whitelist) runs one `SELECT set_config('lock_timeout', $1, true)`
   with the value as a bound parameter. `Scheduler.fire_timer/2` calls it as the first statement inside its
   `Repo.transaction/1`, before the peek, and skips it when `Repo.in_transaction?()` was true on entry.
3. **Where 55P03 is classified.** `fire_timer/2` itself rescues the raised exception and returns
   `{:error, :contention}` for `:lock_not_available`, so the route (which calls `fire_timer/2` directly)
   sees the typed error; a 40P01 and every other exception keep raising. `attempt_fire/2` maps
   `{:error, :contention}` to the new `:contended` outcome and classifies a `{:error, {:raised, exception}}`
   through `Contention.contention_code/1` as well; a deadlock victim falls through to the counted failure.
   A 55P03 on `S_x` (the later waits of the same fire) is raised from inside the event append and is
   covered by the same rescue (case C-L1, third test).
4. **Poll loop.** `poll_result` gains `contended`. The same-instance skip and the telemetry metadata need
   the contended timer's instance and type, which `attempt_fire/2` does not return, so the loop PEEKS the
   row (plain read, `rescue`-guarded, never raising) after a contended outcome and, while the skip set is
   non-empty, before each later timer. In the all-uncontended case no extra query runs. Telemetry
   `[:letflow, :scheduler, :timer_contended]`: count 1; metadata `tenant_schema`, `timer_type`,
   `code: :lock_not_available`. The warning log carries the same tag and the schema only.
5. **Cycle start gate.** `@default_cycle_budget_ms 5_000`, checked before each timer except the first (the
   first fire of a cycle always starts, so a 0 ms budget still makes progress); a test-seam build reads
   the process-local key `:timer_cycle_budget_ms_override` (non-negative integer).
6. **Route.** `advance-timer` maps `{:error, :contention}` to 503 with the constant detail of
   `render_cancel`'s `:cancel_contention` clause and no `Retry-After` header.
7. **Tests.** `test/letflow/scheduler_fire_contention_test.exs` (C-L1..C-L9). C-L4 injects the 40P01 and
   non-contention errors with a `BEFORE UPDATE` trigger on the tenant's `timers` table raising the given
   SQLSTATE only for the `fired` transition (the failure-accounting updates stay untouched), because a
   real deadlock cannot be forced deterministically in a single fire. `scheduler_test.exs`'s whole-map
   assertion gained `contended: 0`.
8. **Review follow-ups.** The `{:error, {:raised, exception}}` clause of `attempt_fire/2` was removed:
   `fire_timer/2` rescues every raise of the fire itself, so the clause was unreachable. The default cycle
   budget is a fixed 5 s (not derived from `sweep_task_timeout_ms/0`; the sweep's `:kill_task` rollback is
   the accepted backstop: the timer stays pending, nothing is counted), exposed through the `@doc false`
   `Scheduler.default_cycle_budget_ms/0`. A `:engine_test_seams` key `:timer_peek_failure` makes the
   post-fire peek raise, to pin the peek failure path.
9. **Accepted residual: starvation by uncounted contention.** Because 55P03 is never counted, a timer stuck
   behind a permanently held lock keeps its slot in the claim window (`max_timers_per_cycle`, ordered by
   `fire_at`); enough of them could starve other due timers of the tenant. Follow-up issue (to be filed by
   the supervisor / letflow-2): a retry count or a `fire_at` backoff on `:contended`. The telemetry event
   `[:letflow, :scheduler, :timer_contended]` is the alerting signal meanwhile.
10. **Accepted gaps.** A `>=` versus `>` pin on the budget comparison is not deterministic (the elapsed time of
    the first fire is never exactly the budget), so it is not tested. Also accepted (TDV survivors): the log `schema:`
    metadata is not asserted; the `:timer_fire_lock_timeout_ms` config read is not tested (only the default and the override); a nested call whose 55P03 leaves the outer transaction aborted is documented, not tested.
