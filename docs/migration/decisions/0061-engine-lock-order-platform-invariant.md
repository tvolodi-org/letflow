# 0061 -- Engine row-lock order is a platform invariant: one global order for every write path

Status: Accepted: ruled by the supervisor (2026-10-18, rev 4 of the GH #2704 design); drafted by CODE-DESIGNER. Implementation: GH #2704 (PR-1), #2709, #2708, #2705 (proof), #2706 (PR-1: cancel's post-`P_x` open-tasks re-read; see "Amended (GH #2706, PR-1)" below), then #2707 PR-1 to PR-3 under its own note (PR-1: the timer fire and cancel's timer step; see "Amended (GH #2707, PR-1)" below).

Date: 2026-10-18

Related: 0054 D3 (entity-write lock order; amended by this record), 0004 (humanless pipeline), GH #2695 (cancel vs the sub-process cascade; merged), GH #2704, #2705, #2706, #2707, #2708, #2709. Design: `lib/letflow/design/gh2704-lock-order-family.md` (the file:line inventory of every path, the pairwise inversions and the test plan live there; this record states only the rule).

## Problem
The engine serialises concurrent writers with Postgres row locks, not with processes (REQ-045). Each write path was designed with a local lock order, and the orders disagree across paths. Found by reading on origin/main e6dc2419: a HUMAN child completion with `entity_writes` takes the entity-type rows and then its parent's projection and token, while a service-task child takes the parent group first and then the entity-type rows (and a parent's own completion takes its projection first), so siblings and parent/child can deadlock; the service path takes the tenant-wide audit chain row (task activation) before the entity-type rows while a HUMAN completion takes them in the opposite order, with no parent involved; direct child cancel and the ExecutionError landing UPDATE a child's projection without holding the parent group (suspected foreign-key lock hazard, mechanism unconfirmed). A deadlock is recoverable (contention 503 or a re-applied apply) but it is a defect, not a design.

## Decision
1. **One global order.** Every engine transaction that takes several of these row classes takes them in this order, nothing is taken out of order, and a path takes a subsequence:
   1. the instance's own timer / dispatch / script-CAS rows and its `tasks` rows (one unordered class; the pair cannot cycle because tasks are contended only by completers and cancel);
   2. the instance's own projection row `P_x`, always first among the rest;
   3. the ancestor group of a sub-process child, nearest first: parent projection, then the parent's waiting token, then the grandparent's, and so on;
   4. the instance's own live tokens;
   5. entity-type rows, ascending by entity type (the type's sequence row, then its synthetic projection row), preceded by the `scope_node_paths` table lock (0054 D3 rule 3a) when it applies;
   6. the tenant-wide audit chain row (from the first audit write of the transaction);
   7. sequence rows: the instance's own, then the ancestors' (the cascade);
   8. projection UPDATEs.
   Across instances a child's rows come strictly before its ancestors' rows and no path goes child-ward.
2. **Modes.** The ancestor group is taken `FOR UPDATE`, whole chain, when the instance completes in this transaction (its cascade follows); otherwise `FOR KEY SHARE` on the immediate parent (a continuing step, a direct cancel, an ExecutionError landing). The mode is decided from the pure transition BEFORE the first lock of step 3 and is never upgraded within a transaction (two siblings upgrading would deadlock). Key-share is compatible between siblings and still queues ahead of a parent cancel's `FOR UPDATE`.
3. **Lock-only steps do not reorder writes.** Where a path must take a lock earlier than its natural write (the service path's entity-type rows before its task-activation audit), it adds a lock-only step; no event, audit or sequence number changes position or content.
4. **Entity-port guard.** The engine reaches the entities side only through `Letflow.Engine.EntityPort` (0039 D3). The pre-lock is an OPTIONAL callback `lock_types/4`; test doubles keep the optional default (no-op), but the PRODUCTION adapter must implement it: `@impl true` on the adapter function, a boot-time check (`EntityPort.verify_adapter!/0` from `Letflow.Application.start/2`, raising when the configured adapter lacks it) and a wiring test that fails if the production adapter lacks it or the service Multi has no `{:pre_type_lock, type}` step between `:lock_ancestors` and the token inserts. The guarantee cannot be bypassed by omission.
5. **Rule for new code.** New engine code that takes more than one of these row classes takes them in this order, or amends this record in the same pull request with the justification and the deadlock test that motivates the change. A new path needs a forced-overlap test (a barrier row held by a third connection plus lock-queue FIFO, deadlock and lock-timeout errors reported through the Repo telemetry event, so a retried victim cannot hide it) before it merges.
6. **Scope of the guarantee.** The no-cycle argument covers the paths named in the design note. Known exceptions, tracked as GH #2706 and #2707 and not hidden by this record: the HUMAN tail's timer cancel after the projection; cold `EventStore.append` callers that append before locking the projection (TIMER_FIRED, reminder fire, attachment events); escalation fire's `tasks` lock after the projection. Timers and dispatch rows armed during cancel's wait for `P_x` are the remaining cancel exception. A cold append takes the sequence row and then updates the projection, the reverse of rule 2 above; the fix for each is to lock the projection (and the ancestor group) first.

## Consequences
* A completing sub-process child holds the parent group `FOR UPDATE` while it waits for entity-type rows (before: after). Sibling completions with `entity_writes` on one type already serialised on the type row and the audit chain row; the group is now held longer. A parent cancel waits behind them longer.
* A service apply holds entity-type rows before its task-activation audit; they are held slightly longer. Event and audit contents, counts and sequence numbers are unchanged, replay is unaffected, there is no migration and no persisted state to convert. A rolling deploy can only reproduce deadlocks that exist today.
* The entity-write plan transactions keep `lock_timeout` 2 s / `statement_timeout` 5 s (0054 D3 timeouts); the new early waits fall under them and map to the existing `entity_write_contention`. Transactions without lines have no timeout and surface a deadlock as `{:transaction_failed, _}`, as today.
* The decision to key-share continuing children and cancel/error landings rests on an observed but unconfirmed foreign-key mechanism (the UPDATE of a child's projection appears to take foreign-key locks on the parent token and projection in a per-tenant-schema order). The prelock is harmless if the mechanism is absent; #2708 and #2709 start with a probe and may end as proof-only.
* The engine moduledoc "Lock ordering" text is rewritten to this order and a cross-reference to this record; 0054 D3 carries a pointer "Amended by 0061".
* Rejected: entity-type rows before the ancestor group (a parent's own completion takes its projection second, so child-versus-parent-completion would stay inverted for good); a global audit-last rule (would move 0054 D3 rules 5 and 6 and every audit position for no gain, since the audit row and the type rows are ordered by this record).

## Open
* The lock mode for child timer fires (FOR UPDATE on the immediate parent is recommended, because the hop chain that says whether the timer completes the child runs after the first event append): to be settled in the #2707 note, which then amends this record only if it must. CLOSED by "Amended (GH #2707, PR-1)" item 2 (key share).

## Amended (GH #2709, PR-2)
The foreign-key mechanism named above as unconfirmed is CONFIRMED by the GH #2709 probe: the FK check on an UPDATE of the referencing row runs when the old row version was written by the current transaction (xmin equal to the current xid; `RI_FKey_fk_upd_check_required`), so the SECOND UPDATE of a row within one transaction (or an UPDATE of a row inserted in the same transaction) queues `KEY SHARE` on the parent token and the parent projection; the first UPDATE of a previously committed row takes none. GH #2709 therefore shipped a lib change (the ExecutionError landing locks the group `FOR KEY SHARE`). Rule 2 is unchanged. The group is found through the WAITING parent token, so the guarantee covers a waiting parent only.

## Amended (GH #2708, PR-3)
The direct cancel of a child is two-UPDATE shaped (the INSTANCE_CANCELLED append bumps `last_event_seq`, then the status goes to `:cancelled`; probe C0 by statement trace), so the mechanism applies and GH #2708 shipped a lib change: `cancel_instance/3` takes `:lock_ancestors` (immediate parent, `FOR KEY SHARE`, intent `:continuing`) after its eligibility check and before its first projection write. Rule 2 is unchanged. Cancelling a parent does not go child-ward, so the cascade children of a parent cancel do not exist and need no lock.

## Amended (GH #2706, PR-1)
Rule 1 gains one exception, stated precisely: class 1 (the instance's own `tasks`, timer and dispatch rows) is normally taken before `P_x` and never after it. `cancel_instance/3` takes the `tasks` rows of class 1 before `P_x` as before, and ADDITIONALLY reads the instance's pending `tasks` a second time after `P_x` and the ancestor group, with `SELECT ... FOR UPDATE SKIP LOCKED`. This second read is a non-waiting read of class 1 after `P_x` and is the only such read allowed: it cannot create a wait edge, and it is complete because every task insert needs `KEY SHARE` on `P_x` through the immediate foreign key `tasks.instance_id -> instance_projections`, which a held `P_x FOR UPDATE` blocks. A pending task row that the second read must have but cannot lock (it is held by another transaction, usually one that is queued behind `P_x`, such as a completer; a row held only by `FOR KEY SHARE`, e.g. by a concurrent foreign-key insert, is also skipped and costs one extra bounded retry) is never waited for: the transaction aborts, rolls back and is retried a bounded number of times (3 attempts, within one lock-timeout constant of the first attempt's start), after which it reports a typed retryable contention error. Any other path that must read class 1 after `P_x` follows the same rule (non-waiting, abort and retry on a skipped row) or amends this record. Rule 2 (modes) is unchanged. Rule 6 no longer lists "cancel's open-tasks snapshot taken before the projection lock" as an exception. Timers and dispatch rows armed between cancel's class-1 UPDATEs and its `P_x` lock remain an exception, tracked by a separate issue (they are benign for correctness and cost only repeated no-op polls).

## Amended (GH #2707, PR-1)
1. **Timer rows are P-protected.** Rule 1 item 1 is amended: it is the instance's own `tasks` rows and its
   dispatch / script-CAS rows, taken before `P_x`; `timers` rows are NOT part of it (this supersedes the
   parenthetical "the pair cannot cycle because tasks are contended only by completers and cancel": tasks
   are contended by completers, cancel AND the escalation fire, and the three take the task row first, so
   they serialise on it). The instance's own `timers` rows, like its tokens, are touched ONLY while `P_x`
   is held `FOR UPDATE`, and their order among themselves and against the live tokens is unconstrained
   (every waiter on them already owns `P_x`). Against the other classes a path that takes them takes
   them after the entity-type rows and before the audit chain row and the sequence rows. The paths:
   `Scheduler.fire_timer/2` (through `Engine.lock_for_timer_fire/3`), the tail of `complete_task/3`, the
   escalation fire's reminder cancellation, `cancel_instance/3` (its timer UPDATE moves after `P_x`, the
   ancestor group and the open-tasks recheck). Two statements do not hold `P_x` and are the only
   exceptions: `Scheduler.claim_due_timer_ids/2` (an autocommit `SKIP LOCKED` read; the lock lasts one
   statement and nothing waits on it) and `Scheduler.record_fire_failure/2` (its own transaction, holds the
   timer row alone and waits for no other lock). Consequence: timer rows of one instance can never be
   waited for in a cycle; timers armed while a cancel waits for `P_x` are cancelled by it; dispatch and
   script-CAS rows armed in that window remain the only cancel exception (this replaces the sentence of
   "Amended (GH #2706, PR-1)" that lists timers and dispatch rows).
2. **The fire path.** A timer fire takes, in this order: the pending `tasks` rows of the timer's token
   (escalation timers only; the same relative order as `complete_task/3` and `cancel_instance/3`), `P_x`,
   the ancestor group `FOR KEY SHARE` of the immediate parent, then the timer row, then the existing
   TIMER_FIRED append and advance. The mode is key share (a continuing step) because a timer fire does not
   run the completion cascade; this closes the "## Open" bullet of this record and overrides the family
   note's FOR UPDATE leaning. The group is taken before the first write of the child's projection, so the
   second UPDATE of that row (`reconcile_projection`) finds its foreign-key locks already held (the
   #2708/#2709 mechanism). A timer whose instance is not `:active` is settled (every pending timer of the
   instance cancelled with reason `instance_<status>`) and the transaction commits; it is never re-claimed.
3. **Invariant I-S (workflow instances).** Every writer of a workflow instance's event stream holds
   `P_x` before it takes that instance's `S_x`. The timer fire establishes it for TIMER_FIRED in this
   amendment; the remaining cold appenders (attachment events, a Lua `emit_event`) stay exceptions until
   GH #2707 PR-2. The streams of entity-type synthetic instances are outside I-S: they keep rule 5's order,
   sequence row then projection row. Within a transaction that holds `P_x`, taking `S_x` before the audit
   chain row `A` (the timer fire's TIMER_FIRED append precedes its audits) is permitted: a transaction
   that holds `A` and wants `S_x` of a workflow instance must hold that instance's `P_x` first.
4. Rule 6 no longer lists as exceptions: the HUMAN tail's timer cancel after the projection,
   `Scheduler.fire_timer`'s TIMER_FIRED append and reminder fire, and escalation fire's `tasks` lock after
   the projection. It STILL lists, until GH #2707 PR-2: cold `EventStore.append/2` callers that append
   before locking the projection (attachment events, a Lua `emit_event`). The sentence of "Amended
   (GH #2706, PR-1)" about timers and dispatch rows armed during cancel's wait for `P_x` is replaced by:
   "Dispatch and script-CAS rows armed during cancel's wait for `P_x` are the remaining cancel exception."
5. Rule 5 (new code) is unchanged and applies to the timer class: new code that locks timer rows locks
   them under `P_x`.
6. The "## Open" bullet (lock mode for child timer fires) is closed by item 2.

Rolling deploy: opposite orders of the same two rows now coexist in two symmetric mixed windows: an old
`cancel_instance/3` (timers before `P_x`) against a new fire (`P_x` before the timer), and an old fire
(timer, then `P_x`) against a new `cancel_instance/3` (timers after `P_x`). Either pair can produce a
recoverable `deadlock_detected` (a failed cancel, or a counted fire failure); no other pair is affected.
