# GH #2706 (CANCEL-SNAPSHOT) and its two tracked residuals - cancel's open-tasks snapshot, the cancel lock timeout, the ExecutionError landing contention

Status: design (CODE-DESIGNER). Base: origin/main 4d597ba8 (includes #2695, #2704, #2708, #2709).
Owner of the build: ELIXIR-DEV. No implementation code below: names, signatures, step orders and
test shapes only. Method: code read with grep/git only; NO `mix` was run (host is memory-starved),
so every statement is "verified by reading" unless it is listed in section 9 as unverified. All
file:line anchors were re-read on 4d597ba8 (not copied from the issue).

Family context: `lib/letflow/design/gh2704-lock-order-family.md` (sections 1.3, 2, 3, 4.3, 6 note
on #2706, 10a, 10b) and decision `docs/migration/decisions/0061-engine-lock-order-platform-invariant.md`.
Notation as in the family note: `P_x` projection row of instance x, `T_x` its token rows, `A` the
tenant-wide audit chain row, `S_x` its `instance_sequences` row; GO = the global order of 0061
rule 1 (class 1 = own timer/dispatch/CAS rows and own `tasks` rows, then `P_x`, ancestor group,
own live tokens, entity-type rows, `A`, sequence rows, projection UPDATEs).

## 0. Verdicts in one screen

1. **The stale snapshot is REAL on main**, and it is wider than the issue says. It is not limited
   to a sub-process cascade: a plain HUMAN completion of the same instance, a service/script apply,
   a timer fire and an escalation fire can all insert a task that cancel's snapshot misses
   (section 1). Reproduced by reading; it needs the red-first test of section 6 to be CONFIRMED.
2. **Fix: keep the existing locking read where it is (GO class 1, before `P_x`), and add a second,
   NON-WAITING re-read of the open tasks after `P_x` (and after the ancestor group), using
   `FOR UPDATE SKIP LOCKED`.** A straggler that nobody holds is cancelled in this transaction. A
   straggler that an in-flight completer holds cannot be taken without waiting (a wait would be a
   deadlock with that completer), so the cancel rolls back and is retried (bounded); on exhaustion
   it reports a typed, retryable contention error (section 2). GO is not changed for any other
   path; 0061 gets a small amendment.
3. **Residual (1):** a transaction-local lock timeout (bound `set_config`, constant
   `:contention_lock_timeout_ms`, skipped when nested) on the cancel transaction (first statement), a typed
   `{:error, :cancel_contention}` for 55P03 and 40P01 (that mapping and the lock timeout are PR-2; PR-1 adds the atom and the 503 clause for the leftover exhaustion only, and its `rescue` still returns `{:transaction_failed, exception}`, a generic 500), HTTP 503 from `render_cancel/2` (section 3).
4. **Residual (2):** the ExecutionError landing step stays as it is (it raises, and every
   in-transaction caller already classifies a raise); the unprotected caller is
   `Engine.set_instance_error/2`, whose raise from the service-task GIVE_UP path leaves the
   instance ACTIVE forever with a terminal dispatch row and no DLQ row. Fix it there: lock timeout,
   bounded retry, typed error, and a standalone DLQ row when the retries are exhausted (section 4).
5. **PR split:** PR-1 snapshot fix (red-first, includes the typed error and the 503 route clause
   because the leftover case needs them), PR-2 cancel lock timeout, PR-3 `set_instance_error/2`
   landing. Not proof-only (section 7).

## 1. Is the stale snapshot real? (decision 1)

### 1.1 The exact order of `run_cancel_instance/5` on main (`engine.ex:8575-8664`)

| # | Step (Multi key) | Anchor | Lock / effect |
|---|---|---|---|
| 1 | `:open_tasks` | `8577-8579`, helper `8695-8703` | one statement: `tasks` WHERE `instance_id = x AND status = pending` ORDER BY id **FOR UPDATE** (class 1) |
| 2 | `:timer_cancellations` | `8580-8601` | `timers` UPDATE (all pending of x) |
| 3 | `:service_task_dispatch_cancellations` | `8602-8606` | dispatch rows UPDATE |
| 4 | `:script_task_dispatch_cancellations` | `8607-8611` | script dispatch rows UPDATE |
| 5 | `:instance_projection` | `8617-8620`, helper `8740-8754` | `P_x` **FOR UPDATE** |
| 6 | `:eligibility` | `8621-8623` | pure |
| 7 | `:lock_ancestors` | `8624-8632` | child's immediate parent group `FOR KEY SHARE` (#2708) |
| 8 | `:task_cancellations` | `8633-8635`, helper `8766-8783` | UPDATE of exactly the rows step 1 returned (no new read) |
| 9 | `:live_tokens`, `:token_cancellations` | `8636-8641` | `T_x` FOR UPDATE by id (a read AFTER `P_x`, hence fresh), UPDATE |
| 10 | `:event`, `:projection`, audit | rest | `S_x`, `P_x` UPDATEs, `A` last |

Answer to "is the open-tasks read before the child's own projection lock?": **yes**, step 1 is the
first statement of the transaction and `P_x` is step 5. The #2708 trace is right that the cancel
takes the child's own `P_x` before the ancestor group; the open-tasks read precedes both.
`cancelled_task_ids` in the result is `Enum.map(open_tasks, & &1.id)` (`interpret_cancel_result`,
`8868-8880`), i.e. also the step-1 snapshot.

### 1.2 Why a Postgres `SELECT ... FOR UPDATE` snapshot misses a concurrent insert

Under READ COMMITTED a `SELECT ... FOR UPDATE` evaluates its scan against the snapshot taken at
statement start. When it blocks on a row held by another transaction it re-checks THAT row's new
version after the holder commits (`EvalPlanQual`), but it never adds rows that the holder (or any
other transaction) INSERTED, either before or after the wait. So whatever a writer inserts while
cancel is blocked (or merely before cancel's step 5) is invisible to step 1, and nothing in steps
2-9 reads `tasks` again. Step 9 re-reads tokens after `P_x`; tasks have no such second read.

### 1.3 Every writer that INSERTS a task for instance x, and what it holds at the insert

All of them take `P_x FOR UPDATE` before inserting and hold it to commit (this is also what makes
the fix of section 2 sound). Checked by reading:

| Writer | Where the tasks are inserted | `P_x` taken | Eligibility after cancel |
|---|---|---|---|
| HUMAN completion of x, `complete_task/3` | tail, `maybe_append_task_activation_multi/7` (`engine.ex:7592-7601`) | `:instance_projection` step, `engine.ex:2744`, `3529-3540` (FOR UPDATE; refuses a non-`:active` row with `{:instance_not_active, _}`) | refused |
| Sub-process cascade, parent p continues after its child completes | `SubProcess` cascade, `TaskActivation.append_multi_from_existing_records/7` (`sub_process.ex:1166`), under `append_sub_process_completion_cascade_multi/*` (`engine.ex:7445`) | `SubProcess.lock_waiting_parent/4` (`sub_process.ex:778-799`): `P_p` FOR UPDATE, then the waiting token re-selected FOR UPDATE; a cancelled parent has a cancelled token, so the re-select returns nil and the cascade stops | refused (token gone) |
| Service-task / script apply | `do_persist_service_task_advance/10` (`engine.ex:4953`, task activation at `5033`) | dispatch row, then `fetch_and_lock_instance_projection/3` (`engine.ex:5838`, `5970`, `6237`) | refused (`{:instance_not_active, _}`, `5839`) |
| Timer fire | `persist_timer_fired_advance/7` (`engine.ex:3809`, activation `3880`) | `advance_after_timer_fired/3`, `engine.ex:3702` | `Scheduler` maps it to `:already_final` (`scheduler.ex:543`) |
| Escalation fire | `persist_escalation_timer_fired_advance/*` (`engine.ex:4169`, activation `4307`) | `engine.ex:4090` | same |
| `Engine.create/2` (start) | `engine.ex:2054` | n/a: the instance does not exist before commit, so no cancel can target it | cannot occur |

(Reminder fire and attachments insert no tasks. A task insert also takes `KEY SHARE` on `P_x`
through the `tasks.instance_id` foreign key, `priv/repo/migrations/20260818110003_create_tasks.exs:57-62`,
which a held `P_x FOR UPDATE` blocks: no task can be inserted for x while cancel holds `P_x`.)

### 1.4 The concrete interleavings (all reachable on main)

* **R1, same-instance HUMAN completion (no sub-process at all).** The completer holds task A
  (`tasks` lock) and `P_x`, inserts the next task B, and has not committed. Cancel's step 1
  sees A pending, blocks on A. The completer commits: A is now completed (cancel skips it on the
  re-check), B was inserted after cancel's snapshot (never seen). Cancel's step 2-4 (fresh
  statements) run, step 5 gets `P_x`, the row is still `:active`, eligibility passes, step 8
  cancels nothing, step 9 re-reads tokens (fresh) and cancels B's token. Result: instance
  `:cancelled`, token cancelled, **B left `:pending`**, and `cancelled_task_ids` omits it. This is
  the same ordering the existing documentation promises to serialise (engine.ex moduledoc "exactly one of the two commits");
  the guarantee holds for task A only.
* **R2, sub-process cascade (the issue's case).** Child c completes; its cascade holds `P_p`,
  inserts the parent's next task B. Cancel(p) runs step 1 (B uncommitted, nothing pending),
  then blocks on `P_p` at step 5. The cascade commits. Cancel gets `P_p`, eligibility passes
  (the parent is still active; it just moved on), nothing is cancelled: B pending on a cancelled
  parent. Same shape for a service-task apply, a timer fire, an escalation fire.
* **R3 (same class, not in the issue): timers and dispatch rows.** Steps 2-4 also run before
  `P_x`, so a timer, service dispatch row or script dispatch row armed by a cascade/apply that
  commits between step 2-4 and step 5 is missed too. Their consequence is benign by existing
  handling for correctness (a dispatch advance logs `instance_not_active` at debug,
  `service_task_dispatcher.ex:621`), unlike a pending task, which is user-visible and completable.
  **Timers are a log/CPU leak, found by CDV:** `Scheduler.fire_timer/2` maps
  `{:instance_not_active, _}` to `:already_final` (`scheduler.ex:543`) but that result comes out of
  a rolled-back transaction, so the timer row is never flipped and is re-polled on every tick
  forever. DECISION (Q2): a follow-up issue is filed BEFORE PR-1 merges; PR-1 does not touch timers.
  A plain second `update_all` after `P_x` is rejected (it waits on a timer row held by an in-flight
  fire, which holds the timer then wants `P_x`: a deadlock). The two candidate fixes for the
  follow-up are a `SKIP LOCKED` recheck of timers after `P_x` (same rule as tasks) or making
  `fire_timer` flip the row on `instance_not_active`; the choice belongs to that issue.

The problem therefore CAN occur; the proof that nothing else protects it is that no step between
1 and 9 reads `tasks` again and every inserter is serialised only through `P_x`, which cancel takes
after the read.

## 2. The fix (decision 2)

### 2.1 What the lock order allows

GO class 1 puts `tasks` BEFORE `P_x` because `complete_task/3` is built on it (`tasks` then `P_x` at
`engine.ex:2742-2744`). Consequences for the options:

| Option | Verdict |
|---|---|
| (a) re-read open tasks after `P_x` with a plain `FOR UPDATE` | **Rejected.** Cancel then holds `P_x` and waits for task row B; a completer of B holds B and waits for `P_x` (its step 2): an AB-BA cycle. This is exactly why the family note said the fix "cannot re-lock `tasks` after `P`". |
| (b) lock `tasks` first, then `P_x` (today's order) and nothing else | Today's bug. |
| (c) take `P_x` first, then tasks | **Rejected.** Inverts `complete_task/3`'s order (tasks, `P_x`); every HUMAN completion would deadlock against cancel. |
| (d) move the whole read under `P_x` and drop the early locking read | **Rejected as the only read.** Every task held by a concurrent completer would then be a straggler, i.e. the common, designed case ("exactly one of the two commits, the other observes a distinct, typed conflict") would turn into rollback-and-retry. |
| **(e) keep the class-1 locking read, add a non-waiting re-read after `P_x` (`FOR UPDATE SKIP LOCKED`)** | **Chosen.** |

### 2.2 Why (e) is acyclic and complete

* **No new wait edge.** `SKIP LOCKED` never blocks, so the second read cannot take part in a
  deadlock cycle regardless of where it sits. The only new lock is on rows nobody else holds; a
  later transaction that wants such a row (a completer of the straggler) waits for cancel, and
  cancel never waits on a task-row holder after step 5. The remaining waits (ancestor group,
  `T_x`, `S_x`, `A`) are not held by any transaction that also holds a task row and wants `P_x`:
  a completer takes its task row first and then parks at `P_x` behind cancel, holding none of
  those. The new edge is "completer -> cancel", the same direction as the
  existing "completer queued behind cancel at `P_x`".
* **Complete.** Cancel holds `P_x FOR UPDATE` from step 5 to commit, and no task can be inserted
  for x meanwhile (section 1.3: every inserter needs `P_x`, including through the foreign-key
  `KEY SHARE`). Every task committed before cancel got `P_x` is visible to a statement that STARTS
  after that point (READ COMMITTED: each statement takes a fresh snapshot). So a re-read after
  step 5 returns the complete set of pending tasks, and that set cannot grow afterwards.
* **Any inserter that arrives later is refused.** A writer that has not yet taken `P_x` when
  cancel commits finds the row `:cancelled` (table in 1.3), unchanged behaviour.
* **Position.** After `:lock_ancestors` (step 7), so the straggler rows are held for the shortest
  time and before `:task_cancellations` (step 8). It must not be before `:eligibility`.

### 2.3 The straggler that is held by someone else (the "leftover")

A straggler B can be locked by a completer W that inserted-and-committed nothing but simply fetched
B (`complete_task/3` step 1) after the cascade committed B and then parked on `P_x` behind cancel.
`SKIP LOCKED` skips B. Cancel cannot cancel B without waiting for W, and W cannot proceed without
`P_x`. Decision: **abort the attempt, release `P_x`, let W commit, retry.** Leaving B pending (the
family note's open item) is rejected: W would then get `{:instance_not_active, :cancelled}` and B
would stay pending on a cancelled instance forever, the very defect being fixed.

Detection (no extra lock): after the `SKIP LOCKED` read, compare it with a plain (non-locking)
read of `tasks` WHERE `instance_id = x AND status = pending`. Rows in the plain set and not in the
`SKIP LOCKED` set are held by another transaction. The pending set cannot grow (section 2.2), so the
two reads need no further guard. A non-empty difference is the leftover.

On a leftover the step `:open_tasks_recheck` returns the named error atom
`:cancel_task_held_by_other`, so `Repo.transaction/1` yields exactly
`{:error, :open_tasks_recheck, :cancel_task_held_by_other, changes_so_far}` and rolls back (nothing
committed, `P_x` released, W proceeds). That 4-tuple is the ONLY shape the retry loop acts on: it
matches the failed step name AND the reason atom, so a step failure of any other step (event
append, changeset, ineligible) keeps going through `interpret_cancel_result/3` unchanged.
`run_cancel_instance/5` then re-runs the whole Multi, at most 3
attempts in total and only while less than `:contention_lock_timeout_ms` (the section 3.1
constant, not a literal 5000) has elapsed since the START of the first attempt on a monotonic
clock (the elapsed time includes time spent blocked; see section 8). A cap that is exhausted
before a new attempt would start returns `{:error, :cancel_contention}`. The loop runs only when `Repo.in_transaction?()` is false (a caller that wraps cancel in its own
transaction cannot retry a rolled-back Multi: it returns the error at once). No backoff: the retry
starts with the class-1 locking read, which blocks on B until W commits, so it paces itself. If the
third attempt still finds a leftover (a sustained stream of completers; practically unreachable)
the result is `{:error, :cancel_contention}` (section 3.2). Nothing is committed on any aborted
attempt; the INSTANCE_CANCELLED idempotency key is only written by the attempt that commits, so a
retry is safe.

### 2.4 Behavioural deltas (all intended)

* `cancelled_task_ids` in the result is the re-read set (a superset of the class-1 set: the class-1
  rows are still pending and still ours). `open_tasks` stays in the Multi (it is what takes the
  class-1 locks); the new change key `:open_tasks_recheck` (the list, ordered by id) feeds ALL
  THREE readers: `:task_cancellations`, the `:event` step (the INSTANCE_CANCELLED payload's
  `cancelled_task_ids`, `append_instance_cancelled_event/5` at `engine.ex:8825-8836`, which
  pattern-matches `open_tasks` today and is changed to match the recheck) and
  `interpret_cancel_result/3` (`8868-8880`). The persisted event therefore lists exactly the tasks
  cancelled, stragglers included; this is a content change to the event payload (shape unchanged),
  pinned by the payload test of section 6 and by `engine_cancel_instance_test.exs:223`.
* New outcome `{:error, :cancel_contention}` (also used by section 3).
* An ineligible cancel (already terminal) still returns before the re-read: no extra lock, no
  extra statement (the existing test "an ineligible cancel takes no group lock" pattern applies).
* Event, audit, sequence numbers: unchanged in count and position (the re-read adds no write); the
  event's `cancelled_task_ids` content now includes the stragglers (above).

### 2.5 Decision 0061 and the moduledoc

*Superseded in part by gh2707 section 10:* timers are no longer class 1 (they are P-protected, taken after `P_x`), and "timers and dispatch rows armed during cancel's wait" is reduced to dispatch and script-CAS rows.

Append this section to `docs/migration/decisions/0061-engine-lock-order-platform-invariant.md`
VERBATIM (PR-1; REVIEWER gate), and edit rule 6 as stated in its last paragraph:

> ## Amended (GH #2706, PR-1)
> Rule 1 gains one exception, stated precisely: class 1 (the instance's own `tasks`, timer and
> dispatch rows) is normally taken before `P_x` and never after it. `cancel_instance/3` takes the
> `tasks` rows of class 1 before `P_x` as before, and ADDITIONALLY reads the instance's pending
> `tasks` a second time after `P_x` and the ancestor group, with `SELECT ... FOR UPDATE SKIP
> LOCKED`. This second read is a non-waiting read of class 1 after `P_x` and is the only such read
> allowed: it cannot create a wait edge, and it is complete because every task insert needs
> `KEY SHARE` on `P_x` through the immediate foreign key `tasks.instance_id ->
> instance_projections`, which a held `P_x FOR UPDATE` blocks. A pending task row that the
> second read must have but cannot lock (it is held by another transaction, necessarily one that
> is queued behind `P_x`, such as a completer) is never waited for: the transaction aborts, rolls
> back and is retried a bounded number of times (3 attempts, within one lock-timeout constant of the first attempt's start), after which
> it reports a typed retryable contention error. Any other path that must read class 1 after `P_x`
> follows the same rule (non-waiting, abort and retry on a skipped row) or amends this record.
> Rule 2 (modes) is unchanged. Rule 6 no longer lists "cancel's open-tasks snapshot taken before
> the projection lock" as an exception. Timers and dispatch rows armed between cancel's class-1
> UPDATEs and its `P_x` lock remain an exception, tracked by a separate issue (they are benign
> for correctness and cost only repeated no-op polls).

Rule 6 edit: delete the phrase "; cancel's open-tasks snapshot taken before the projection lock"
and add the sentence "Timers and dispatch rows armed during cancel's wait for `P_x` are the
remaining cancel exception." Also update the record's header "Implementation" line to mention
#2706. Engine moduledoc: delete the "cancel's open-tasks snapshot taken before
the projection lock (GH #2706)" item from "Known gaps" (`engine.ex:446-449`), add the re-read to the
`cancel_instance/3` bullet (`engine.ex:411-417`), update the `cancel_instance/3` `@doc` (the
"tasks locked before instance_projections" paragraph at `8500-8506`).

## 3. Residual (1): the cancel lock timeout (decision 3)

### 3.1 The timeout

* New FIRST step of the Multi (before `:open_tasks`), one statement. SQL construction (INV-7): the
  entity-write timeouts use compile-time literal strings (`engine.ex:2885-2888`); a runtime value
  must never be interpolated into SQL text. So the statement is the parameterised
  `SELECT set_config('lock_timeout', $1, true)` (third argument `true` = transaction-local, the
  equivalent of `SET LOCAL`), with ONE bound text argument built from a compile-time integer
  constant of milliseconds (for example `"5000ms"`). `maybe_entity_write_timeouts/2` is left as it
  is. Value **5 s**. Name of the constant and of the test override: `:contention_lock_timeout_ms`
  (not cancel-specific; the same constant and statement serve section 4 / PR-3). Rationale: longer
  than one lock wait of a plan-completion (2 s) so an ordinary completer that holds a task or
  `P_x` for one bounded wait does not fail the cancel; short enough that a stuck holder surfaces as
  a retryable 503 instead of an open-ended hang. No `statement_timeout` (not asked, cancel's
  statements are short; adding one changes error classes beyond this issue).
* It bounds every wait of the transaction: the class-1 locking read, timers/dispatch UPDATEs,
  `P_x`, the ancestor group, `T_x`, `S_x` and the tenant-wide `A` (taken last). Accepted
  consequence: under extreme audit-chain contention a cancel can now fail with 503 where it
  previously queued; the caller retries.

### 3.2 Error mapping

* **PR-2 (not PR-1):** in `run_cancel_instance/5`'s existing `rescue` (`engine.ex:8661-8662`, which today turns every
  raise into `{:error, {:transaction_failed, exception}}`) add a clause BEFORE it: a
  `Postgrex.Error` whose `postgres.code` is `:lock_not_available` (55P03) or `:deadlock_detected`
  (40P01) -> `{:error, :cancel_contention}`. Other raises are unchanged. Log one warning with the
  classified tag only (no exception text, no ids beyond the instance id: SEC S3 style used at
  `engine.ex:6212`). `:query_canceled` is not mapped (no statement timeout is set).
* (PR-1) Add `{:error, :cancel_contention}` to `cancel_error()` (`engine.ex:8476-8486`) and to the
  `@spec` of `cancel_instance/3`.
* Shared classifier: new tiny pure module `Letflow.Engine.Contention` with
  `contention_code(term()) :: {:ok, :lock_not_available | :deadlock_detected} | :error`
  (a `Postgrex.Error` with exactly those two codes; everything else `:error`). Used by the new
  code only (cancel, section 4); the three existing copies (`engine.ex:3208`, `5581`, `5610`) are
  NOT touched here (Q5).
* Router: `render_cancel/2` (`routers/instances.ex:697-721`) gets a clause before the catch-all:
  `{:error, :cancel_contention}` -> `Response.service_unavailable(conn, <constant detail>)`,
  i.e. **HTTP 503**, matching how the HUMAN completion maps contention (`entity_write_contention`
  -> 503, `response.ex:302`, `routers/tasks.ex:434-436`). 409 is rejected: the existing 409s mean
  "the instance is already terminal"; a contention failure is retryable and has not changed state.
  The detail is a literal ("the instance is being modified concurrently; retry"), nothing from the
  exception (INV-4/INV-5). Update the moduledoc table row for cancel (`instances.ex:15`) and the
  "No 503 branch" comment line for cancel.

### 3.3 Idempotency of a retried cancel

Every contention failure rolls the whole transaction back (a raise out of `Repo.transaction/1`
rolls back; a deadlock victim is rolled back by Postgres). No event, projection, task, token,
timer or audit write survives, so a client retry with the same `idempotency-key` header starts from
the unchanged state and can succeed once; a retry after a SUCCESS gets today's
`{:instance_already_terminal, :cancelled}` (409). `Idempotency.from_header/4` is a pure key
derivation (`idempotency.ex:160-172`), it records nothing, so a rejected attempt does not poison
the key.

### 3.4 Configuration

**No runtime key.** The value is the compile-time constant of 3.1. A fast 55P03 test uses the
existing compile-time switch `Application.compile_env(:letflow, :engine_test_seams, false)`
(`config/test.exs`, the same one the service backoffs use at `engine.ex` ~5530). **The test config
keeps the 5 s default; it is NOT lowered globally** (the barrier tests R1, R2, L1, L1b and the
existing `cancel_child_lock_order_test.exs` deliberately park a cancel on a held row for as long
as they need, and a global 300 ms would turn those into 55P03). Instead, under
`engine_test_seams` ONLY (compiled out of a production build), the step reads a PROCESS-LOCAL
override, `Process.get(:contention_lock_timeout_ms_override)`, in the calling process (the Multi
step runs in the process that called `cancel_instance/3` / `set_instance_error/2`, so a worker
started by the test sets it with `Process.put/2` as the first line of its own function). It must
be a positive integer; otherwise it is ignored and the constant applies. **How T1 and E1 reach a
real 55P03 within bounded time:** the worker function does `Process.put(:contention_lock_timeout_ms_override, 300)`
and then calls the engine; a third connection holds the barrier row; Postgres raises a genuine
55P03 after about 300 ms; the test awaits the worker with the usual `H.await_ms/0` bound. Other
tests, and other processes, keep 5 s. A production build has no such read and can only have 5 s.
(The rejected alternatives: a per-cancel `Application.get_env`, which would force a runtime
integer into the statement and is what the CDV review ruled out; a global test-config value.)

**Nested transactions (F6).** Ecto nested transactions use no savepoint, so a `SET LOCAL`/
`set_config(..., true)` issued inside a caller's transaction lasts until the OUTER transaction
ends and would leak a 5 s timeout to the caller's later statements. Rule: when
`Repo.in_transaction?()` is true at entry, the step is SKIPPED (no timeout, no leak), the leftover
retry loop is not used (the typed error is returned at once, section 2.3), and the contention
`rescue` mapping still applies. A failure inside the nested call (a leftover, or a contention
error) makes `Repo.transaction/1` roll back, which marks the OUTER transaction rollback-only: the
outer `Repo.transaction/1` then returns `{:error, :rollback}` even if the caller handled the
typed error. T4 pins both the typed error of the call and this outer result. A nested cancel therefore has no wait bound; it is
not a production path (the only caller is the route), only tests and future callers.

### 3.5 As built (PR-2)

* `Letflow.Engine.Contention` holds `lock_timeout_ms/0` (5 s; under `engine_test_seams` only, the
  process-local override of 3.4), `lock_timeout_setting/0` (the text bound to `set_config`) and
  `contention_code/1`. The `Letflow.Engine.contention_lock_timeout_ms/0` of PR-1 is removed; the
  retry loop's time cap (`run_cancel_attempts/5`) reads the same function as the DB timeout.
* The `:lock_timeout` Multi step is first; its nested-skip is decided once at entry
  (`Repo.in_transaction?()` before the first attempt) and passed down, not re-read inside the
  transaction (which is always true there).
* The contention clause sits in `cancel_attempt/6`'s `rescue` and logs the code and the instance id only.
* T1b (leftover path, real permanent holder) uses a 4 s override (setup bounded to 2 s, explicit slow-start failure): the first attempt also waits
  on task A while the test arranges the straggler, which a 300 ms bound would cut short.
  T4b covers a nested cancel hitting a real 55P03 (the caller sets its own `lock_timeout`, since a
  nested cancel sets none): typed error, the caller's transaction is rolling back, and the outer
  `Repo.transaction/1` returns `{:error, :rollback}`.
  T3 (deadlock victim) is deterministic: the cancel is the first waiter, so it detects the cycle.

## 4. Residual (2): the ExecutionError landing step (decision 4)

### 4.1 Facts (re-read)

`ExecutionError.append_multi/3` (`execution_error.ex:192-212`; the step is at `:219` of the issue
text, `Multi.run(:execution_error_lock_ancestors, ...)` calling
`SubProcess.lock_waiting_parent(repo, instance_id, prefix, :key_share)`) raises on 55P03/40P01 (a
statement error out of `repo.one/2`); it returns no error tuple. A 40P01/55P03 aborts the Postgres
transaction, so NO row (DLQ or otherwise) can be written in the same transaction after the failure:
the "no DLQ row" is structural, not a missing insert. A DLQ row can only be written in a LATER
transaction.

Callers, and what each does with the raise today:

| Caller | Anchor | On a raise from the step |
|---|---|---|
| HUMAN completion (hop-chain error branch, tail, cascade) | `engine.ex:7187`, `7481`, and the complete branch | inside `complete_task/3`'s Multi: whole completion rolls back, task stays `:pending`; with a plan it maps to `entity_write_contention` (503, `3199-3217`), without one `{:transaction_failed, _}` (500). Nothing stuck; the user retries. |
| Service apply: no matching edge, reserved key | `persist_service_task_no_matching_edge/7`, `persist_service_task_reserved_key_error/6` (`engine.ex:4855`, `4890`) | propagates out of the apply; HTTP and planned-script applies classify `{:transaction_failed, %Postgrex.Error{}}` as contention and re-apply (3 attempts, `5610-5614`); then `land_service_failure/5`. Bounded, handled. |
| Service entity-write refusal landing | `http_landing_multi/4` (`5955-5994`) | `rescue_service_contention/1` + 3 attempts (`5897`, `5920-5925`); exhaustion logged as the documented residual D-C.8(d). Handled. |
| Script failure | `script_failure/7` (`6370-6394`) | planned: mapped and re-applied; unplanned: blanket rescue `{:error, :raised}` and the dispatcher's follow-up re-evaluates the CAS (`6212-6215`). Handled by design. |
| **`Engine.set_instance_error/2`** | `engine.ex:8957-8982`; called by `give_up_service_task_dispatch/3` (`5252`) and `land_service_task_exhaustion/2` (`9178`) | **Unprotected.** It has no rescue, no lock timeout and no retry. From the GIVE_UP path the raise surfaces in `ServiceTaskDispatcher.attempt_dispatch/2`'s outer `rescue` as `{:error, {:raised, exception}}` (`service_task_dispatcher.ex:788-790`), after `handle_give_up` already committed the dispatch row as given up. Result: instance **ACTIVE forever**, dispatch row terminal, no ERROR event, no DLQ row, nothing re-arms it. |

So the stuck-instance risk is real, but only for `set_instance_error/2`. (`land_service_task_exhaustion/2`
writes its DLQ row first in its own committed insert, then calls `set_instance_error/2`, so there a
DLQ row exists but the instance stays ACTIVE.)

### 4.2 Decision

* **Do not change the step.** Its contract is "raises on the contention class", which the
  classifiers above depend on (`engine.ex:5610-5614`); catching it there would silently stop those
  clauses matching. Document the contract in `ExecutionError`'s moduledoc and pin it with a test.
* **Fix `set_instance_error/2` itself** (it is documented as the entry point "for a caller with no
  other Multi of its own open"):
  1. Its transaction starts with the lock timeout set exactly as in section 3.1 (the same
     bound-parameter `set_config` statement and shared constant; skipped when
     `Repo.in_transaction?()`). It cannot go inside `ExecutionError.append_multi/3`, which is shared with
     transactions that set their own (2 s) timeouts.
  2. A contention-class raise (via `Letflow.Engine.Contention`) is retried with a fresh transaction,
     at most 3 attempts total, constant backoffs 100 ms / 300 ms (the existing `@service_backoffs_ms`
     values, none under `:engine_test_seams`), only when `Repo.in_transaction?()` is false (a
     nested call returns the typed error at once).
  3. After the last failure it returns `{:error, {:execution_error_contention, code}}` (new member of
     `set_error_error()`, `engine.ex:8941-8950`), never raising.
  4. When the call did not pass `dlq_landed_externally: true`, it ALSO writes a standalone
     best-effort DLQ row in a separate transaction, rescue-wrapped (it must never raise or mask the
     typed error): `entry_type: "event"` (the type `ExecutionError` already lands; the DLQ page's source
     filter, `web/src/pages/dlq/DlqPage.tsx` ~365-368, lists only event/timer/webhook, so a new type
     would be invisible in the UI), marked by `context_json` `{"landing": "contention"}` (the key is
     in `Dlq.enqueue/2`'s attribute whitelist, `dlq.ex:87-100`), `instance_id`, `reason` a fixed
     sentence, `error_detail` carrying only
     `error_type`, the `affected` descriptor, the SQLSTATE class tag and the attempt count. The
     variables, the original reason text and the details map are NOT copied (they can carry tenant
     data; same INV as `script_failure_sentence`). It takes no ancestor lock and no instance lock.
     When `dlq_landed_externally` is true the caller already wrote the DLQ row (`9178`), so none
     is added.
* `give_up_service_task_dispatch/3` already forwards `{:error, reason}`; it needs no change except
  that its `@spec` and the dispatcher's `call_advance_after_service_task_outcome/3` log clause
  (`service_task_dispatcher.ex:~640`, the "previously a silent swallow" branch) must treat the new
  tag as a classified, logged failure. The instance stays ACTIVE, but it now has an operator-visible
  DLQ row; recovery is the operator's (same class as the documented D-C.8(d) residual). It is NOT
  moved to ERROR without the group lock: that would reintroduce the second-UPDATE foreign-key
  hazard #2709 closed.
* Not changed (listed so nobody assumes otherwise): `complete_task/3` without a plan still maps a
  raised deadlock to `{:transaction_failed, _}` / 500 (family note, `engine.ex:391`); changing that
  is a separate issue (Q4).

## 5. Invariants this design preserves (INV list for the validator)

* GO is unchanged: class 1 (tasks, timers, dispatch) before `P_x`; the new read adds no waiting
  lock after `P_x`.
* Authorization and eligibility order are unchanged: the route's policy check (`InstancesCancel`)
  and `check_cancel_eligibility/1` precede every new step; the new steps add no read of tenant data
  beyond the instance's own `tasks`, and no response field.
* The result's and the INSTANCE_CANCELLED event's `cancelled_task_ids` gain the stragglers (a
  superset; same shape) and one error atom is added. 0061 rule 1 gets the one precisely stated
  exception of section 2.5; rule 2 is unchanged.
* No migration, no persisted-schema change, no new event or audit type; replay is unaffected (the
  event payload of a cancel that missed a task on main was incomplete; replay never read it back
  to cancel tasks, tasks are rows).

## 6. Test plan (reproduce first, deterministic forced overlap)

Files: `test/letflow/engine/cancel_open_tasks_recheck_test.exs` (PR-1),
`test/letflow/engine/cancel_lock_timeout_test.exs` (PR-2),
`test/letflow/engine/set_instance_error_contention_test.exs` (PR-3); router assertions in the
existing cancel route test file. All `async: false`, Sandbox `:auto`, fixtures as in
`test/letflow/engine/cancel_child_lock_order_test.exs` (`Letflow.EntityWritesFixture`,
`Letflow.LockOrderHelpers` as `H`, `H.attach_error_handler/1`).

Helper addition (PR-1, `test/support/lock_order_helpers.ex`): `hold_row/2` spec `{:task, task_id}`
(`SELECT 1 FROM tasks WHERE id = $1 FOR UPDATE`, mirror of the projection/sequence specs).

PR-1 (red on main, green after):

* **R1** (same-instance HUMAN completion). Two sequential HUMAN nodes A then B. Barrier
  `H.hold_row(schema, {:sequence, x})`. Worker 1 = `complete_task(A)`: it inserts B, then parks at
  `S_x` (the event append). Worker 2 = `cancel_instance(x)`: its step 1 blocks on A (held by
  worker 1). `H.wait_for_blocked` both, release. Assert: the cancel returns `{:ok, ...}`, **task B is
  `:cancelled`**, no pending task of x remains, B's id is in `cancelled_task_ids`, no
  `deadlock_detected` message. Red on main: B `:pending`.
* **R2** (cascade). Parent p waits on child c; after the sub-process the parent has a HUMAN node.
  Barrier `{:sequence, p}`. Worker 1 = `complete_task` of c's last task: holds `P_c`, the group
  `P_p`/`T_p` FOR UPDATE, inserts p's next task B, parks at `S_p`. Worker 2 = `cancel_instance(p)`:
  step 1 sees nothing, parks at `P_p`. Release. Assert B `:cancelled`, parent `:cancelled`, p's
  tokens cancelled. Red on main: B `:pending`.
* **R3** (optional, same fix): the same shape with a service-task apply or a timer fire as the
  inserter. Cost/benefit is the supervisor's call; R1+R2 pin the mechanism.
* **Payload test (F1).** For R1, R2 and the existing fixtures of `engine_cancel_instance_test.exs`
  (`:206` result ids, `:223` event payload): the persisted INSTANCE_CANCELLED event's
  `cancelled_task_ids` (sorted) equals the sorted ids of the tasks that are `:cancelled` with this
  `cancelled_at`, AND the result's `cancelled_task_ids`, and B is in all three. The `:event` step
  (`append_instance_cancelled_event/5`, `engine.ex:8825-8836`, which pattern-matches
  `%{open_tasks: _, live_tokens: _}` today), `:task_cancellations` and `interpret_cancel_result/3`
  (`8868-8880`) ALL read `:open_tasks_recheck`; no step reads the class-1 `:open_tasks` except the
  recheck itself. Corollary for section 5: the event payload content changes only by including the
  stragglers; its shape is unchanged.
* **L1** (the leftover; proves no deadlock and the retry), pinned order. Fixture: nodes A, then B,
  then another HUMAN node C. Steps: (1) hold task A of x with `{:task, A}`; (2) start cancel: it
  does its class-1 work and blocks on A at step 1; (3) INSERT task B for x directly (fixture; `P_x`
  is free) with its token; (4) take a second barrier on `{:projection, x}`; (5) release the A
  barrier: cancel advances and QUEUES at `P_x` (first in line); (6) start `complete_task(B)` (W): it
  locks B and queues at `P_x` AFTER cancel; wait until both are blocked; (7) release the `P_x`
  barrier. FIFO gives `P_x` to cancel: its `SKIP LOCKED` read skips B, the plain read shows B, the
  attempt aborts and rolls back; W gets `P_x`, completes B (activates C) and commits; cancel's second
  attempt finds C either in its class-1 read or, if that statement started before W committed,
  in the `SKIP LOCKED` recheck after `P_x` (both are correct; the test must not depend on which),
  takes `P_x`, cancels C, commits. Assert: W's completion
  returns `{:ok, _}`; C is `:cancelled`; B is `:completed`; the instance is `:cancelled`; the cancel
  returns `{:ok, _}` with C in `cancelled_task_ids`; no `40P01`/`55P03` through the telemetry
  handler. Separately, the attempt count is exactly 2, asserted from a statement trace on the
  cancel's backend (count of its class-1 `tasks ... FOR UPDATE` statements; the trace helper
  pattern is C1's in `cancel_child_lock_order_test.exs`).
* **L1b** (B final). Same steps but B leads to END: W's completion completes the instance; cancel's
  retry finds it terminal and returns `{:error, {:instance_already_terminal, :completed}}` (HTTP
  409 on the route). Assert exactly that, no `40P01`, and no pending task EXCEPT task A: A is only
  barrier-held in this fixture and stays `:pending` on the completed instance (completion does not
  cancel it), so the assertions are on B (`:completed`) and the instance (`:completed`) only; or
  the fixture completes/cancels A before step 3.
  (If the ordering of steps 5-6 proves fragile in CI, the fallback is a pause seam on the pattern
  of `ScriptTaskDispatcher.pause/2`, honoured only under `Runtime.test_hooks?`: `cancel_instance`
  pauses once after `:lock_ancestors`.)
* **O1 statement order** (like C1 of `cancel_child_lock_order_test.exs`): the re-read follows the
  `P_x` FOR UPDATE and the ancestor group lock, uses `SKIP LOCKED`, and no statement against `tasks`
  after the `P_x` lock takes a non-skip `FOR UPDATE` (guards the "never wait on tasks after `P_x`"
  rule against a refactor). An ineligible cancel issues no re-read.
* **C-existing**: `engine_cancel_instance_test.exs` and `cancel_child_lock_order_test.exs` stay green
  unchanged.
* Router: `{:error, :cancel_contention}` -> 503 with the constant body (no exception text).

PR-2: **T1** with the per-test process-local override of section 3.4 (`Process.put` of 300 in the
worker, `engine_test_seams` builds only; the test config default stays 5 s), barrier `{:projection, x}` held by a third
connection: `cancel_instance(x)` returns `{:error, :cancel_contention}` within about 300 ms plus
margin (a REAL 55P03), nothing committed (instance still `:active`, all tasks pending, no
INSTANCE_CANCELLED event), then succeeds after the barrier is released. **T2** unit test of
`Letflow.Engine.Contention.contention_code/1` for 55P03, 40P01 (hand-built `Postgrex.Error`
structs), and a non-contention code, a `DBConnection.ConnectionError`, a non-error term. **T3** a
deadlock victim maps to `:cancel_contention`: only if a deterministic victim can be arranged
(the test worker takes `P_x` then asks for a task row that cancel's step 1 already holds, started
FIRST so cancel is the second waiter and therefore the detector); otherwise left to T2 plus the
`rescue` clause test through a stubbed raise. **T4** a cancel wrapped in an outer transaction does
not retry and does NOT set the lock timeout (section 3.1 nested rule): `SHOW lock_timeout` inside
the outer transaction after the call is still the default, and a leftover returns
`{:error, :cancel_contention}` at once; AND the OUTER `Repo.transaction/1` that wrapped the call
returns `{:error, :rollback}` (the nested failure marked it rollback-only). **T5** (non-nested only) the lock timeout is
transaction-local: `SHOW lock_timeout` on the same pinned connection after the cancel returns the
default. **T6** the statement trace shows the timeout is set with the bound `set_config` form (one
parameter, no interpolated number in the SQL text).

PR-3: **E1** `set_instance_error(child)` (worker sets the process-local override of section 3.4 to 300 ms) with the parent projection held by a barrier and the
timeout lowered: typed `{:error, {:execution_error_contention, :lock_not_available}}`, the child
projection unchanged, and a `dlq_entries` row of `entry_type "event"` with `context_json`
`{"landing": "contention"}` exists with none of the variables in it. **E2** with `dlq_landed_externally: true` no DLQ row is added. **E3**
the same call succeeds once the barrier is released within the retry window (second attempt).
**E4** moduledoc contract test: `ExecutionError.append_multi/3` still raises (does not return an
error tuple) on a contention class (pins section 4.2's "do not change the step").

## 7. PR split, sizes, SECURITY-REVIEWER, rollout

| PR | Content | lib | tests | Notes |
|---|---|---|---|---|
| PR-1 | `:open_tasks_recheck` step (SKIP LOCKED re-read, leftover detection, bounded re-run), `:event`, `:task_cancellations` and `interpret_cancel_result/3` all read it, `cancel_contention` atom in `cancel_error()`, router 503 clause, `{:task, id}` helper spec, 0061 "Amended (GH #2706)", moduledoc and `@doc` edits | about 70 lines in `engine.ex`, 8 in `routers/instances.ex` | R1, R2, L1/L1b, O1, payload test, router; about 300 lines | Red-first: R1/R2 merged red-then-green in the same PR. SECURITY-REVIEWER: the router file is touched (`render_cancel/2`); trigger it. REVIEWER: 0061 amendment. Not proof-only. The follow-up issues of F4/Q7 are filed before it merges. |
| PR-2 | lock-timeout step (bound `set_config`), nested-skip rule, `rescue` clause, constant, `Letflow.Engine.Contention`, T1-T5 | about 40 lines | about 150 lines | Depends on PR-1 (same function, same error atom). **SECURITY-REVIEWER (INV-7: SQL construction, even though the value is a bound parameter).** |
| PR-3 | `set_instance_error/2` lock timeout, bounded retry, typed error, standalone DLQ row, dispatcher log clause, E1-E4 | about 80 lines | about 150 lines | Depends on PR-2 (module and constant). SECURITY-REVIEWER: a new DLQ write path with tenant-adjacent fields (what is NOT copied) and the same SQL-construction point. |

**Authorisation of the split.** The #2706 comment ("track under this issue; decide when this issue
is designed") makes the residuals part of this issue's scope, but core-directives says one PR per
issue and a comment is not an authorisation to split. Recommendation: ORCH files two sub-issues via
letflow-2 (PR-2 "cancel lock timeout", PR-3 "set_instance_error landing contention"), each linking
#2706; if the supervisor prefers, the reason (this design, section 0) is recorded in each PR body
instead (Q8).

Merge discipline: no docs-only merge while a functional PR is in
CI; run the whole-repo format check and grep the test suite for callers of `cancel_instance/3`
and `set_instance_error/2` whose assertions pin `cancelled_task_ids` or the exact error shapes before
pushing (`engine_cancel_instance_test.exs:206`, `223`, `292` pin them today).

Rollout: no migration, no persisted state, rolling deploy safe (old nodes keep the old behaviour; a
new node can only turn a missed task into a cancelled task, or a hang/500 into a 503). The only
client-visible change: a new 503 on `POST /instances/:id/cancel`, and `cancelled_task_ids`
(engine-internal; the route does not return it) may list more ids.

## 8. Risks

* Rare cancel aborts (leftover path) cost a retry; capped at 3, never commits partial state.
* A 5 s lock timeout can fail a cancel behind a very long holder (a completion with many entity
  lines can hold `P_x` longer than 5 s across several waits); the failure is a retryable 503, not
  data loss. Q1 asks whether 5 s is right.
* The `SKIP LOCKED` re-read relies on "no task insert is possible while `P_x` is held FOR UPDATE"
  (foreign-key `KEY SHARE`). That is verified by reading the migration; the O1/R2 tests exercise it,
  and a future task path that inserts without the FK would break it (guarded by the 0061 text).
* `set_instance_error/2` retry doubles the time a dispatcher poll can spend on a give-up (about 0.4 s
  of backoff plus up to three lock waits); acceptable, polls are batch background work.
* **Pre-existing cycle, not fixed here (#2707's):** escalation fire takes `P_x` and then the task
  row (`engine.ex:4090`, `4222-4252`), the inverse of cancel's class-1 order (task rows, then
  `P_x`). A cancel racing an escalation fire on the same task can deadlock; with this design the
  outcome for the cancel is a 40P01 mapped to `:cancel_contention` (503, retryable) instead of an
  unbounded wait, and nothing commits. The `SKIP LOCKED` re-read does not add to it.
* **Cancel latency.** Only the leftover path retries (a lock timeout or deadlock is NOT retried
  inside the engine; it is returned as 503). The leftover retry loop starts a new attempt only
  while less than `:contention_lock_timeout_ms` (one lock timeout, blocked time included) has elapsed on a monotonic clock since the start of the first attempt
  began, so the worst case is about two attempts of at most one lock timeout per wait each, well
  below an HTTP request budget in practice, and never three back-to-back full timeouts.
* **Orphan/timer follow-ups** (section 1.4 notes): timers armed in the R3 window are re-polled
  forever; the orphaned child instance of a cancelled parent. Both are filed as follow-up issues,
  not fixed here.

## 9. Not verified (no `mix`, reading only)

* The Postgres behaviours in 1.2 (statement snapshot never adds inserted rows; `SKIP LOCKED` skips a
  row locked by another transaction but not one locked by the same transaction) are standard
  documented READ COMMITTED semantics, not measured here; R1 is the measurement.
* That an escalation fire creates a new task (`engine.ex:4307` calls task activation) was read from
  the call site only.
* The pre-existing cycle recorded in section 8 (escalation fire) was read, not reproduced.

## 10. Open questions for the supervisor

Answers below are the coordinator's defaults after CDV, pending the supervisor's confirmation.

1. **Lock timeout value**: 5 s, one shared constant, applied through the bound parameter of
   section 3.1 (no runtime config interpolation into SQL). Confirm.
2. **Timers/dispatch rows armed between steps 2-4 and step 5 (R3)**: DECIDED, a follow-up issue,
   filed BEFORE PR-1 merges (section 1.4 F4 note). PR-1 does not touch timers.
3. **DLQ entry type**: DECIDED, reuse `"event"` (the type `ExecutionError` already writes) with
   `context_json` marker `{"landing": "contention"}`. No new type, no UI filter change.
4. **`complete_task/3` without a plan** answering a raised deadlock with a generic 500: separate
   issue, out of scope.
5. **Shared classifier**: `Letflow.Engine.Contention` for NEW code only; folding the three
   existing copies (`engine.ex:3208`, `5581`, `5610`) is a separate refactor PR.
6. **HTTP status**: 503, no `Retry-After`.
7. The orphaned CHILD instance of a cancelled parent (cancel never goes child-ward): out of scope;
   a follow-up issue is filed for it (same class as the follow-up of Q2).
8. **Sub-issues** (section 7): confirm that ORCH files sub-issues for PR-2 and PR-3 (via
   letflow-2), since core-directives says one PR per issue; the alternative is to record the
   reason in each PR body.
