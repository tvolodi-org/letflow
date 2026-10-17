# GH #2704 / #2708 / #2709 (family with #2705, #2706, #2707) - one global lock order for both child kinds

Status: design (CODE-DESIGNER). Base: origin/main e6dc2419 (includes #2695 / PR #2713, #2694).
Owner of the build: ELIXIR-DEV. No implementation code below: names, signatures, step orders and
test shapes only. Method: code read with grep/git only; NO `mix` was run (host is memory-starved),
so everything below is "verified by reading" unless it is listed in section 9 as unverified. Where
the issues quote lines from an older base, the lines below are re-read on e6dc2419.

Notation (extends the #2695 note): `P_x` projection row of instance x; `T_x` its token rows;
`S_x` its `instance_sequences` row; `E` the entity-type rows of a completion with `entity_writes`
(per type: the type's synthetic-instance `instance_sequences` row, then its synthetic projection
row; decision 0054 D3 step 4a); `A` the tenant-wide `audit_chain_locks` row (`audit.ex:284-300`,
held to commit, ONE row per tenant, so any two audit writers in a tenant contend on it); `c` a
sub-process child, `p` its parent, `g` the grandparent. "Parent group" = `P_p` then the waiting
token `T_p` (`SubProcess.lock_waiting_parent/4`, `sub_process.ex:778-799`), ancestors nearest first.

## 1. Lock orders on main, per code path (re-read, file:line on e6dc2419)

### 1.1 HUMAN completion, `Engine.complete_task/3` (`build_complete_task_multi`, `engine.ex:2754-2871`)

Step order of the one Multi (a plan = the node has `entity_writes`):

| # | Step | Locks / writes | Anchor |
|---|---|---|---|
| 0 | `SET LOCAL lock_timeout 2s`, `statement_timeout 5s` (plan only) | - | `engine.ex:2764`, `3164-3172`, consts `2893-2894` |
| 1 | `:task` | `tasks_c` row FOR UPDATE | `2765`, `3521` |
| 2 | `:instance_projection` | `P_c` FOR UPDATE | `2766-2768`, `3536` |
| 3 | `:snapshot_and_state`, `:completion_guards`, `:form_expression_reevaluation`, `:merge`, `:transition` | reads and pure computation; no lock, no audit (grep of `check_completion_guards`, `merge_output_variables`: none) | `2769-2856` |
| 4 | `maybe_entity_writes` -> `EntityPort.multi` -> `StepWrites.multi` | `E`, per line sorted by `(entity_type, index)`: first command of a type takes its sequence row (`lock_and_increment_sequence`, `event_store.ex:749-763`), then its projection; with `module_writes` an explicit `{:type_lock, type}` per type first (`step_writes.ex:566-581`, `622-634`; `handler_writes.ex:426-439`) | `engine.ex:2859`, `3174-3195` |
| 5 | tail clause 1, execution error | `ExecutionError.append_multi` with the held `P_c`: `S_c`, DLQ row, `P_c` UPDATE | `7133-7147` |
| 5 | tail clause 2, advanced: `:lock_ancestors` FIRST | parent group of `c`: whole chain FOR UPDATE if the final status is `:completed`, else immediate parent FOR KEY SHARE | `7214-7217`, `8671-8678` |
| 6 | timers_c cancel (escalation, reminder), token reconcile, task activation | `timers_c` UPDATE (after `P_c`), `tokens_c`, `tasks_c` inserts, **`A`** at each `task.create` audit (`task_activation.ex:482-495`) | `7218-7251` |
| 7 | timer/dispatch arms, `:task_complete`, `record_task_complete_audit`, per-line entity audits, SYS/APPLIED events | **`A`**, then `S_c` (events) | `7252-7336` |
| 8 | `:event` (TASK_COMPLETED) | `S_c`, then `P_c` UPDATE (every event append updates the projection: `event_store.ex:606-618`, `897-910`) | `7337-7345` |
| 9 | `:projection`, children creation, `append_sub_process_completion_cascade_multi` | `P_c` UPDATE; cascade re-locks the parent group (no wait, already held), then `S_p`, `P_p` UPDATE | `7346-7368`, `7396-7452` |

So the HUMAN child order on main is `tasks_c, P_c, E, [P_p, T_p (, P_g, T_g ...)], timers_c, A, S_c, P_c upd, S_p, P_p upd`.
The existing statement-trace test pins exactly this E-before-parent-group order
(`test/letflow/engine/cancel_cascade_lock_order_test.exs:649-690`, asserts
`first_type_row < first_parent_lock`).

### 1.2 Service / script apply, `do_persist_service_task_advance/10` (`engine.ex:4960-5162`)

Before the Multi (callers, `engine.ex:4600-4640`): dispatch (or script CAS) row, then `P_c`
(`lock_projection_for_service_apply`), then plain reads. Then one Multi (plan: SET LOCAL first):

| # | Step | Locks / writes | Anchor |
|---|---|---|---|
| 1 | `:lock_ancestors` (GH #2695, first step) | parent group, mode as in 1.1 | `5008-5010` |
| 2 | hop-chain token inserts, `TaskActivation.append_multi_from_existing_records` | `tokens_c`, `tasks_c` inserts; **`A` at each `task.create` audit** (`task_activation.ex:403-421`, `468`, `482`) | `5011-5044` |
| 3 | timer arms, dispatch arms, sub-process children creation (new child instances: events, their own task activation, hence `A` again) | `timers_c`, dispatch rows, `S_new`, `A` | `5045-5084` |
| 4 | `maybe_service_entity_writes` | `E` ascending (same `StepWrites.multi`), then SYS/APPLIED events (`S_c`) | `5088`, `5645-5690` |
| 5 | `:service_task_completed_event`, `on_advanced`, `:projection` | `S_c`, `P_c` UPDATE | `5089-5104` |
| 6 | `append_service_sub_process_cascade` | parent group re-lock (no wait), `S_p`, `P_p` UPDATE | `5117-5122`, `5167-5202` |
| 7 | `append_service_entity_write_audits` | `A` (last, D-C.11) | `5123` |

Service child order on main: `dispatch, P_c, P_p, T_p (, P_g, T_g), [A if a task is activated], E, S_c, P_c upd, S_p, P_p upd, A`.

### 1.3 `cancel_instance/3` (`run_cancel_instance`, `engine.ex:8536-8617`)

`tasks` pending of x FOR UPDATE by id (`8539`, `8648-8657`) -> `timers` update_all (`8559`) ->
service dispatch rows (`8573`) -> script dispatch rows (`8579`) -> `P_x` FOR UPDATE (`8581-8584`,
`8680-8692`) -> eligibility (pure) -> task cancel UPDATEs -> live `T_x` FOR UPDATE by id (`8591`) ->
INSTANCE_CANCELLED (`S_x`, then `P_x` UPDATE) -> `P_x` UPDATE (`8606`) -> `A` (`8609`, last).
It never touches an ancestor (`grep` for `lock_parent_group`/`lock_waiting_parent` in
`8536-8760`: empty) and never goes child-ward. On the parent side that is the order every other
writer is meant to follow: `P_p, T_p, S_p, P_p upd, A`.

### 1.4 ExecutionError landing, `ExecutionError.append_multi/3` (`execution_error.ex:192-212`)

`P_x` FOR UPDATE (own step, or the caller's `locked_projection`; `199`, `260-283`) -> eligibility
(pure) -> `EXECUTION_ERROR` event (`S_x`, then `P_x` UPDATE inside the append, `298-320`) -> DLQ row
(`Dlq.enqueue`; no audit write: grep of `dlq.ex` empty) -> `P_x` UPDATE to `:error` (`326-338`).
No ancestor lock anywhere in it. Callers (all pass through this one function):
`engine.ex:4883` (service no-matching-edge), `4917` (service reserved key), `5950` (service
entity-write refusal, second transaction), `6350` (script failure), `7143` (HUMAN execution-error
tail), `7442` (cascade error branch, instance = parent, no `locked_projection`),
`sub_process.ex:554` and `1302` (child-creation and grandparent error branches),
`engine.ex:8915` (public `set_instance_error/2`, instance = any).

### 1.5 Timer paths (context for #2707, not changed here)

`Scheduler.fire_timer/2` (`scheduler.ex:278-295`): timer row FOR UPDATE (`422-427`) -> timer
UPDATE `fired` -> `append_timer_fired_event` (`400-420`, a COLD `EventStore.append`: `S_x`, then the
`P_x` UPDATE inside the append, BEFORE any explicit projection lock) -> `route_fire` ->
`advance_after_timer_fired` (`engine.ex:3706-3725`): `P_x` FOR UPDATE -> ... Escalation fire
(`4091-4300`) additionally updates the original `tasks` row AFTER `P_x` (`4237-4252`).

### 1.6 Pairwise result on main (what can actually cycle)

| Pair | Order A | Order B | Cycle? |
|---|---|---|---|
| HUMAN child (plan) vs service child (plan), siblings, same type | `E -> parent group` | `parent group -> E` | YES (#2704, the sibling inversion). Continuing children too (key-share group still waits behind the completer's FOR UPDATE group or is held while E is awaited) |
| HUMAN child (plan) vs parent's own completion (plan) | child `E -> P_p` | parent `P_p -> E` | YES (#2704 Q1 proper) |
| HUMAN (plan) vs service (plan, activates a HUMAN task) of ANY two instances sharing a type, no parent needed | `E -> A` (task activation is in the tail, after E) | `A -> E` (task activation is step 2, E is step 4) | YES, **new finding I4**; this is the real content of #2705 (the instance_sequences row in "audit vs sequence" IS the type's sequence row `E`) |
| cancel(c) vs cancel(p), cancel(c) vs parent completion | no ancestor lock; `UPDATE` of `P_c` takes FK locks on parent token and parent projection in a per-schema fixed order (#2695 T5, observed, mechanism unconfirmed) | `P_p -> T_p` | YES in tenant schemas whose FK-check order is token first (#2708) |
| ExecutionError landing on c vs cancel(p) | same hidden FK locks | `P_p -> T_p` | YES, same condition (#2709) |
| fire_timer vs any `P_x`-first writer | `timer, S_x, P_x upd, P_x lock` | `P_x, ..., S_x` | YES by reading (S before P on a cold append), not in the issues; see 6.3 |
| HUMAN tail vs fire_timer | `P_x -> timers_x` (tail cancel) | `timers_x -> P_x` | YES (#2707 as filed) |

## 2. The chosen single global order (GO)

One order for every path and both child kinds. A path takes a subsequence. Across instances:
a child's rows strictly before its ancestors', ancestors nearest first; nothing goes child-ward.

```
 L1  own pre-projection rows   timer rows / dispatch / CAS rows (cancel, apply, fire_timer)
 L2  own tasks rows            (complete_task, cancel)   [L1 and L2 are one unordered class: cancel
                               takes tasks then timers/dispatch, apply takes dispatch only,
                               fire_timer timers only; tasks are contended only by completers and
                               cancel, which serialise on them, so the pair cannot cycle]
 L3  own projection P_x        (every path; ALWAYS before everything below)
 L4  ANCESTOR GROUP            P_p, T_p, then P_g, T_g ...   (mode: FOR UPDATE chain if x completes,
                               else FOR KEY SHARE immediate parent; decided BEFORE any write)
 L5  own live tokens T_x       (cancel; reconcile in HUMAN/service tails)
 L6  ENTITY-TYPE rows E        ascending by entity_type; scope_node_paths (0054 D3 rule 3a) first
                               when it applies
 L7  AUDIT CHAIN ROW A         first audit write of the transaction (task.create, task.complete,
                               entity audits, instance.cancel); held to commit
 L8  sequence rows             own S_x, then S_p, S_g (cascade) -- the event appends
 L9  projection UPDATEs        P_x upd, P_p upd
```

The two changes versus the code on main, everything else already conforms:

* **C-P (HUMAN):** the ancestor group (L4) is taken immediately after the pure `:transition` step
  and BEFORE the entity-write steps (L6). Today it is the first tail step, after E.
* **C-E (service):** the entity-type rows (L6) are taken immediately after `:lock_ancestors` and
  BEFORE the token inserts / task activation (the first `A`, L7). Today they come after the task
  activation and children creation.

With C-P and C-E both child kinds read `P_c, ancestors, E, A, S_c, P_c upd, S_p, P_p upd`, the
same string, and a parent's own completion reads `tasks_p, P_p, [its ancestors], E, A, S_p ...`:
the same string again.

### 2.1 Why this order and not E-first

The supervisor's question is E versus the parent group. Two candidates:

* **P-first (chosen): ancestors, then E, for children.** A parent completion with
  `entity_writes` already takes `tasks_p, P_p` (`complete_task` steps 1-2, decision 0054 D3 rules
  1-2) and only then E. For a child to be consistent with its parent's own completion, a child
  must also take the parent group before E. The service path already does (since #2695); the
  HUMAN path moves one step earlier. One change to one path, and it removes the inversion against
  the parent's own completion (the "Q1 proper" row in 1.6), which an E-first rule can never fix.
* **E-first (rejected).** It would make the service child the one that changes (hoist the parent
  group after E), but #2695 measured that the parent group must precede the first `A`
  (`task.create` audit at `engine.ex:5030`) and the child's first projection UPDATE, and E-first
  would put E before both, so it needs the same E hoist as C-E anyway. Worse, the parent's own
  completion takes `P_p` before E by construction (it cannot take E first: `P_p` is its second
  step), so E-first for children leaves child-vs-parent-completion inverted forever.

### 2.2 Why A after E (L6 before L7) and why this retires #2705

`E` rows are `instance_sequences` rows. In 0054 D3 (rules 4 then 5) the HUMAN path already takes E
before A. The service path breaks it: task activation (A) precedes the entity writes (E) in
`do_persist_service_task_advance`. C-E fixes that by one lock-only step, not by reordering any
write: every write, event and audit keeps its position, so event and audit content, counts and
sequence numbers are byte-identical. Cancel keeps `A` last (it has one audit write and no E), which
is consistent: the only S rows that two DIFFERENT transactions of this family can both want after
holding `A` are `S_p`/`S_g` (acquired only under the exclusive ancestor group, L4, which both
sides already hold before `A`) and the type rows (L6, before `A` in both). `S_c` itself is only
contended by transactions that already hold `P_c` (L3), except the cold appender of 1.5 (#2707).
That is the proof sketch for #2705: with GO there is no pair that takes `A` and an
`instance_sequences` row in opposite orders; #2705 becomes a proof plus regression test (section 5).

### 2.3 Lock modes and why no upgrade exists

Mode is decided from the pure transition BEFORE any lock of L4: `FOR UPDATE` on the whole chain
when the final status is `:completed` (its cascade follows), `FOR KEY SHARE` on the immediate
parent otherwise (compatible between siblings, still queued ahead of a parent cancel's FOR UPDATE).
No path takes key-share and later upgrades the same rows (two sibling upgraders would deadlock).
The new users inherit this rule: cancel(c) and the ExecutionError landing are "continuing" shaped
(they never complete the child), so key-share immediate parent; both decide before their first
write. fire_timer (#2707) must respect it too (section 6.3).

### 2.4 Acyclicity argument (family scope)

Order the lock classes `L1 < L2 < L3 < L4 < L5 < L6 < L7 < L8 < L9` and check each path's
sequence in 1.1-1.4 after C-P and C-E, #2708 and #2709 (below): HUMAN child
`L2 L3 L4 L6 L1' L7 L8 L9` (its tail timer cancel is the L1/L3 outlier, #2707); service child
`L1 L3 L4 L6 L7 L8 L9`; cancel `L2/L1 L3 L4 L5 L8 L9 L7` (its `A` is its last statement and its only
audit; by 2.2 that cannot meet a different `A`-then-`S` holder on a shared S row, but note this
is the one place where "A last" and "A before S" coexist, resolved by the S-row argument above and
to be re-checked by the #2705 regression test); ExecutionError landing `L3 L4 L8 L9`. Cross-instance
edges only go ancestor-ward and only inside L4. Therefore, for the paths of this family, a
wait-for edge from a transaction holding class k to one holding class j<k cannot exist, so no cycle.
The residual exceptions are exactly the four items marked "follow-on" in section 6.

## 3. Findings beyond the issue texts (all by reading; unverified by a run)

* **I4, A before E on the service path** (1.2 step 2 vs 4; `task_activation.ex:468`): deadlock with
  a HUMAN completion with `entity_writes` of the same type, parent not required. C2's design table
  line 380 puts "task activation" in M1 before the entity writes (M2); its C-5 lock-order case used a
  service node followed by END, so it never exercised an activated task.
* **S before P on cold appends** (`event_store.ex:606-618`, `680-697`, `897-910`): inside one
  `EventStore.append` the order is guard read, `S_x` lock, event insert, `P_x` UPDATE. Every locked
  writer takes `P_x` FOR UPDATE first, so it is safe; `fire_timer` appends TIMER_FIRED before it
  locks `P_x` (1.5). Decision 0054 D3's "every writer of that instance stream holds the projection
  mutex" claim is therefore not true for timers.
* **Escalation fire updates `tasks` after `P_x`** (`engine.ex:4237-4252`) while `complete_task` and
  `cancel` take `tasks` before `P_x`. Whether the preceding `original_task_row` read locks the row is
  not verified. Input for #2707, not designed here.
* **The `engine.ex` moduledoc is corrupted at lines 402-403** ("foreign-key locks on the p  while
  cancel takes it last. I3 (fixed for ..."): a bad edit merged text. PR-1 must repair it while
  rewriting the paragraph.
* **FK mechanism is unconfirmed.** Postgres queues an FK check on UPDATE of the referencing row
  only when a key column changes; `InstanceProjection.update_changeset` does not cast
  `parent_instance_id`/`parent_token_id` (the #2695 build note says so). #2695 observed the
  behaviour (T5, intermittent 40P01, the parent token's `xmax` was the child apply) but could not
  name the mechanism. #2708 and #2709 exist only if the hazard is real, so each starts with a
  mechanism probe (T0 below) and may end as a proof-and-regression PR with no lib change.
  Per-schema order: Postgres fires same-event triggers alphabetically by name and FK triggers are
  named `RI_ConstraintTrigger_c_<oid>`, so the order follows the triggers' OID strings (a
  lexicographic comparison), which differs between freshly provisioned tenant schemas. That
  explains "tenant-schema dependent" and means the AB-BA is reachable only where the token check
  fires first. (Postgres documentation, not verified against this server.)

## 4. Per issue

Common test infrastructure (reuse, do not duplicate): `Letflow.EntityWritesFixture` (`Fx`),
`Letflow.Support.PlatformTenantFixture.capture_repo_queries/1`, the barrier row held by a
third connection `Z`, the pid-scoped `wait_for_blocked(pids, n)` and the telemetry handler that
reports every `deadlock_detected` and `lock_not_available` Repo error even when the engine retries
(`cancel_cascade_lock_order_test.exs:10-18`, `45-75`, `300-330`). PR-1 extracts these into
`test/support/lock_order_helpers.ex` (module `Letflow.LockOrderHelpers`, unverified that nothing
equivalent exists) so the three new test files share them. All new files `async: false`, sandbox
auto mode, fresh committed tenant per test. Reproduction method is always: write the test, run it
on the base commit and quote the failure, then quote green after the change. A red that does not
reproduce means the harness is wrong, not the assertion.

Two kinds of reproduction are used, because a retried victim hides a deadlock:

* **Statement-order test (deterministic, no concurrency):** one uncontended operation under
  `capture_repo_queries`, assert the index order of the lock statements. Red on main by reading.
* **Forced-overlap test (AB-BA):** a barrier held by `Z` plus lock-queue FIFO. Lock waiters of one
  row are granted in arrival order, so "start worker 1, wait until it is blocked, start worker 2,
  wait until both are blocked, release `Z`" fixes who gets the contended row first. Assert:
  telemetry saw zero `40P01`/`55P03`, both workers return, and the end state.
  Entity-write fixtures run with the 2 s `lock_timeout` (compile-time constants,
  `engine.ex:2893-2894`, no seam), so both workers must be parked within one second: poll in 10 ms
  steps with a cap of 80 steps and fail with a named assertion otherwise (the C2 file polls under
  1.5 s for the same reason, `service_task_entity_writes_lock_order_test.exs:360-380`).

### 4.1 #2704 - E vs the parent group (HUMAN child with entity_writes, service child, continuing children)

**Fix (two changes, C-P and C-E; section 2).**

C-P, HUMAN: in `build_complete_task_multi` (`engine.ex:2754`) add one step `:lock_ancestors`
between `:transition` (`2841`) and `maybe_entity_writes` (`2859`), reading the transition result:
for `{:advanced, state, ...}` it calls `lock_parent_group(repo, task.instance_id, state, prefix)`
(`8671-8678`, unchanged, same chain/key-share rule); for any other transition outcome (execution
error) it returns `{:ok, []}`. Remove the `:lock_ancestors` step from the tail clause 2
(`7214-7217`) and the comment above it; the lock mode needs only `state.status`, which entity-write
`_sys` folding does not change (`7167-7177`). Step key stays `:lock_ancestors`, no reader of its
result exists (grep). `SET LOCAL lock_timeout` (step 0) already precedes it, so a plan completion
bounds the new early wait exactly as it bounds the later ones; the classification is unchanged
(`engine.ex:3206-3224`).

C-E, service/script: add a lock-only step `:lock_entity_types` right after `:lock_ancestors`
(`engine.ex:5010`) and before the `Multi.merge` that inserts tokens (`5011`). It locks, ascending by
`entity_type`, the sequence row of every declared line type that has a synthetic instance
(`EventStore.lock_instance_sequence/3`, `event_store.ex:739-747`, via `HandlerWrites.lock_types/3`),
the same filter `StepWrites.lock_types/4` already applies (`step_writes.ex:624-634`). Skipped when the
completion has no `:entity_plan`. The lines' own later lock steps become no-op re-locks. The engine
must not name `Letflow.Entities` (0039 D3 boundary), so the step goes through the entity port.

Public/internal shapes (signatures only):

* `Letflow.Engine.EntityPort` (`entity_port.ex`): new OPTIONAL callback
  `lock_types(Ecto.Multi.t(), lines :: [line()], lock_ctx :: %{prefix: String.t()}) :: Ecto.Multi.t()`
  plus a wrapper `EntityPort.lock_types/3` that returns the multi unchanged when the configured
  implementation does not export it (test doubles that `@behaviour` the port keep compiling; an
  optional callback produces no warning under `--warnings-as-errors`).
* `Letflow.Entities.EntityPortImpl.lock_types/3` -> new `Letflow.Entities.StepWrites.lock_declared_types/3`
  (`Multi.t(), [line()], prefix`) :: `Multi.t()`; it is the lines-only specialisation of the private
  `lock_types/4`. Appends zero or more `{:type_lock, type}` steps. No new error shape: a type without
  a synthetic instance is skipped, as today.
* `Letflow.Engine` private: `:lock_entity_types` step in `do_persist_service_task_advance/10`; no
  public function, `@spec` or return value changes. No schema, migration or API change.

Behaviour that must not change: results of `complete_task/3`, `advance_after_service_task_outcome/4`,
`apply_script_task_result/3`; all event and audit contents and counts; the contention result
`entity_write_contention` (503) and the service retry driver; refusals never commit.

**Reproduction (test file `test/letflow/engine/entity_parent_lock_order_test.exs`).**
Fixture: parent `start -> split(PARALLEL) -> {sp_h, sp_s} -> join -> end`; child H = HUMAN node
carrying `entity_writes` on type X then END; child S = HUMAN gate node then HTTP SERVICE node
carrying `entity_writes` on type X then END (a child SERVICE node must follow a HUMAN node, per the
#2695 note); `Fx.warm_up` the type's synthetic instance first (the first creation is not part of
the race, C2 does the same).

| # | Case | Forced interleaving | On main | After |
|---|---|---|---|---|
| E0 | statement order, HUMAN (plan) | none | red: `first_type_row < first_parent_lock` is today's assertion (`cancel_cascade_lock_order_test.exs:649-690`); the NEW assertion is the reverse | green; the old test is FLIPPED in this PR |
| E0s | statement order, service (plan) | none | red when the service node is followed by a HUMAN node: `A` (`audit_chain_locks`) precedes the first type-row lock | green: parent group, then type rows, then `A` |
| E1 | sibling completing H and S | `Z` holds X's sequence row. Start H, wait 1 blocked, start S, wait 2 blocked, release. H queued first at E on main, S holds the group and queues second | red: 40P01 (H holds E, wants group; S holds group, wants E) | green: H holds the group (FOR UPDATE), S parks at the group, no E cycle |
| E2 | sibling continuing H' and S' (each moves on to another HUMAN node; mode key-share) | same barrier | red on main (same cycle; for S' also the I4 cycle) | green; both hold key-share on the group and serialise only on E |
| E3 | child completion vs the parent's OWN completion with entity_writes on X (parent has a second parallel HUMAN branch with lines) | `Z` on X, parent completion first, child second | red on main (`P_p -> E` vs `E -> P_p`) | green |
| E4 | cancel safety, re-run T1-T9 of `cancel_cascade_lock_order_test.exs` unchanged | as written | green | green (regression) |

Assertions per forced test: zero telemetry deadlock/lock-timeout reports; both workers return within
the await bound; record count equals declared lines (no partial or duplicate write); the audit chain
verifies; `SUB_PROCESS_COMPLETED` exactly once for completing cases. The expected red on main is
the 40P01 reaching the telemetry handler (the service side is re-applied by the engine and the HUMAN
side maps to `entity_write_contention`, so the result alone is not the evidence).

**Blast radius.** Production lines about 70 (engine step move, service pre-lock, port callback and
impl, one `StepWrites` function). Hot-path effect: a completing HUMAN or service child now holds the
parent group FOR UPDATE while it waits for E (previously the group came after E); throughput of
sibling completions with `entity_writes` on one parent drops no further than today (they already
serialise on E and on `A`), but the group is held longer. A continuing child holds a key-share lock
longer (harmless to siblings). Tests changed: the flip of the existing statement-trace test
(E0), and any assertion in `service_task_entity_writes_lock_order_test.exs` that reads the position
of type-row locks relative to `tokens`/`tasks` inserts (C-5 statement log; re-read at build).
Docs: engine moduledoc "Lock ordering" through the GH #2648 paragraph (`engine.ex:359-474`)
rewritten to GO (repair `402-403`, drop "NOT closed ... Q1"), the comment `5003-5007`, the comment
`7209-7213` removed with the step, and an Amendment paragraph in
`docs/migration/decisions/0054-process-step-writes-entity.md` D3 stating rule "2b: the ancestor
group of a sub-process child is taken after step 2 and before step 3a/4" (open question Q5).

### 4.2 #2709 - ExecutionError landing

**Fix.** One choke point. In `ExecutionError.append_multi/3` (`execution_error.ex:192-212`) add a step
`:execution_error_lock_ancestors` AFTER `:execution_error_eligibility` and BEFORE
`:execution_error_event`: it calls `SubProcess.lock_waiting_parent(repo, error_args.instance_id,
prefix, :key_share)` and returns its result (`{:ok, TokenRecord.t() | nil}`; nil for a non-child).
After eligibility so an ineligible landing (terminal or already error) takes no extra lock. Every
caller listed in 1.4 is covered at once; `append_multi/3`'s `@spec`, options and error shapes do not
change, and no caller changes. The step is a no-op re-lock when the group is already held (the
cascade error branches `engine.ex:7442`, `sub_process.ex:554`, `1302`, where the instance is the
parent and the completing chain was locked FOR UPDATE; HUMAN tail `7143` after C-P holds nothing
since the execution-error clause has no ancestor step). Key-share is correct: an ERROR landing never
completes the child. Dependency note: `execution_error.ex` already is called from `sub_process.ex`;
the new call is the reverse edge `ExecutionError -> SubProcess` (runtime call, no macro or struct,
so no compile-time cycle; REVIEWER to confirm the layering).

Preconditions to re-verify at build time, because the fix is only sound if no write to the child's
projection precedes the new step in any caller: `4883`/`4917` (reads only before, `4600-4835`),
`5950` (second transaction: dispatch, projection, key read, then the landing), `6350` (script),
`7143` (pure steps before), `8915` (first step). The grep results above support it; not run.

**Reproduction (file `test/letflow/engine/execution_error_lock_order_test.exs`).**

| # | Case | Method | On main | After |
|---|---|---|---|---|
| X0 | mechanism probe | transaction A UPDATEs the child's projection row; connection B tries `FOR UPDATE NOWAIT` on the parent's waiting token and on the parent projection | tells whether key-share FK locks are taken at all; if B is NOT refused, #2708 and #2709 cannot occur and both end as proof-and-regression (no lib change) | n/a |
| X1 | statement order | `set_instance_error/2` on a child under `capture_repo_queries`: parent projection lock and waiting-token lock precede the EXECUTION_ERROR insert and the child projection UPDATE | red | green |
| X2 | forced AB-BA | read the tenant's FK trigger order (`pg_trigger` names for the two FKs); if token-first: `Z` holds the parent projection row, `cancel_instance(p)` parks first on it, then the landing arrives (it locks the token through the FK check and parks on the projection), release | red: 40P01 (this is #2695's T5 for a landing) | green |
| X3 | other FK order | barrier variant is moot (cycle unreachable); assert only X1 | green | green |
| X4 | callers | the same X2 through the HUMAN execution-error tail (a completion whose gateway has no matching edge), the service no-matching-edge landing, and the cascade error branch | red where reachable | green |

**Blast radius.** About 25 lines in one module plus moduledoc. All error landings of children take
one more (key-share) row lock; non-children pay one indexed lookup on `tokens.waiting_child_instance_id`
(`20260819045553_add_sub_process_parent_columns.exs:50`). A landing may now wait on a running parent
operation earlier than before (it waited at the projection UPDATE anyway). DLQ and event contents
unchanged.

### 4.3 #2708 - direct cancel of a sub-process child

**Fix.** In `run_cancel_instance` (`engine.ex:8536`) add a step `:lock_ancestors` immediately after
`:eligibility` (`8585`) and before `:task_cancellations` (`8588`), running `lock_parent_group/4` in
its key-share shape (`8674-8678`) for the cancelled instance: parent projection, then the waiting
token, FOR KEY SHARE, no-op for a non-child. Position: after `P_c` (L3), before the first write that
UPDATEs the child's projection (the INSTANCE_CANCELLED append, `8597`) and before `A` (`8609`).
`lock_parent_group/4` currently pattern-matches an `InstanceState` status; cancel has no state, so
the signature is generalised to take the lock intent (`:completing | :continuing`, or the state as
today) - ELIXIR-DEV chooses, no behaviour change for the two existing callers. Cancel's other rules
stay (tasks, timers, dispatch before `P`; `A` last). Result values and error shapes of
`cancel_instance/3` unchanged; a cancel of a child never resumes or cancels the parent (the parent
token stays `:waiting`, existing behaviour, not decided here, cf. #2695 Q5).

**Reproduction (file `test/letflow/engine/cancel_child_lock_order_test.exs`).**

| # | Case | Method | On main | After |
|---|---|---|---|---|
| C0 | mechanism probe | same as X0, on the cancel's projection UPDATE | decides go/no-go | n/a |
| C1 | statement order | `cancel_instance/3` of a child under `capture_repo_queries` | red: no parent-side lock statement at all | green: parent projection, token, then the INSTANCE_CANCELLED insert |
| C2 | forced AB-BA, token-first schemas | `Z` on the parent projection row, `cancel_instance(p)` parks first, `cancel_instance(c)` second, release | red 40P01 | green; `cancel(c)` blocks at the group, `cancel(p)` completes, then `cancel(c)` |
| C3 | cancel(c) vs cascade of a sibling | as C2 with a completing sibling as the second worker | red or green by reading (group is FOR UPDATE for the completer) | green |
| C4 | fixture sanity | child cancelled, parent token `:waiting`, parent still `:active`; no `SUB_PROCESS_COMPLETED` | green | green (documents the existing semantics) |

**Blast radius.** About 12 lines plus the `lock_parent_group` signature; one new early (key-share)
wait for direct cancels of children while the parent is mid-operation. API contracts (`cancel_instance/3`
router callers) untouched.

### 4.4 What the global order implies for the follow-on issues (not designed here)

* **#2705 (AUDIT-SEQ).** Reduces to I4 (section 2.2). With C-E in PR-1, there is no `A` / S-row
  inversion left among the family's paths. #2705 becomes: forced-overlap test (service step that
  activates a HUMAN task and has lines on X, versus a HUMAN completion with lines on X; start
  order service first, `Z` holds `A`; release) which is RED on main (A -> E vs E -> A) and must be
  GREEN after PR-1; plus a statement-order test for the continuing service step. If PR-1 already
  carries both tests and they pass, #2705 closes with "fixed by C-E, proof in tests". Decide at PR
  time whether the test belongs to PR-1 or PR-4 (below).
* **#2706 (CANCEL-SNAPSHOT).** The order keeps `tasks` (L2) before `P` (L3) because
  `complete_task` is built on it, so the fix cannot re-lock `tasks` after `P`. Not a cycle but a
  correctness gap: tasks inserted by a cascade that commits while cancel waits at `P_p` are missed.
  Implication: after `P_x` cancel may select the stragglers with `FOR UPDATE SKIP LOCKED` (rows
  nobody holds), and a straggler that is held by an in-flight completer is refused by that
  completer afterwards because it finds the projection not `:active`; the leftover pending row for
  that case needs its own decision. Prove-first: the race test needs the barrier on `P_p` with the
  cascade holding the task insert.
* **#2707 (TIMER-FIRE).** GO puts timers before `P` (L1 before L3, as cancel and `fire_timer`
  already do), so the outliers are the HUMAN tail (cancels the task's timers after `P_c`) and the
  cold TIMER_FIRED append. Implied fix: (a) `fire_timer` locks `P_x` and the ancestor group right
  after the timer row and before the TIMER_FIRED append (this also closes the S-before-P gap), (b)
  `complete_task` locks the task's pending timers (escalation, reminder) between `tasks` and `P`.
  Lock mode must be decided before the first write (2.3): the hop chain that says whether the timer
  completes the child runs after the append, so the safe choice is FOR UPDATE on the immediate
  parent for every child timer fire (timer fires are rare) rather than key-share followed by an
  upgrade. Escalation's `tasks`-after-`P` update (section 3) needs the same look.

## 5. Pull-request split (one PR per issue, strictly sequential)

Core-directives merge discipline: one functional PR in CI at a time; no docs/chore merges while a
functional PR is in CI; run the CI-shaped checks locally before each push. This design note itself
lands first as a docs-only PR (GH #2704 branch `design/GH-2704-lock-order`) when no functional PR
is in CI.

| Order | PR | Issue | Content | Size (est.) | Depends on |
|---|---|---|---|---|---|
| 0 | docs | - | this design note | 1 file | - |
| 1 | PR-1 | #2704 | C-P, C-E, port callback, `Letflow.LockOrderHelpers` extraction, tests E0-E4, moduledoc rewrite, 0054 D3 amendment | prod ~70 lines, tests ~450, docs ~120 | note merged; owns the moduledoc rewrite, so it goes first |
| 2 | PR-2 | #2709 | `ExecutionError` step, tests X0-X4, one moduledoc line | prod ~25, tests ~250 | PR-1 (shared helpers, moduledoc) |
| 3 | PR-3 | #2708 | cancel step, `lock_parent_group` generalisation, tests C0-C4, one moduledoc line | prod ~15, tests ~220 | PR-1; independent of PR-2 (either order) |
| 4 | PR-4 | #2705 | proof and regression tests (and a fix only if a test is red after PR-1) | tests ~200 | PR-1 |
| later | - | #2706, #2707 | own design notes after PR-1/PR-3 are on main (they inherit GO, section 4.4) | - | PR-1 |

If a mechanism probe (X0/C0) shows no FK locks, PR-2 and PR-3 shrink to tests plus a moduledoc line
and are filed as "cannot occur, proof attached" (allowed by their acceptance criteria).

## 6. Risks

1. **`lock_timeout`.** Only completions and applies WITH lines issue `SET LOCAL lock_timeout 2s`.
   C-P and C-E add early waits to those transactions, bounded by the same 2 s, mapped to
   `entity_write_contention` (HUMAN) or re-applied (service, bounded). For completions WITHOUT lines
   there is no timeout and a deadlock surfaces as `{:transaction_failed, _}` (existing behaviour);
   they are not changed by C-E and C-P only moves a lock that was already taken. Tests with lines
   must park both workers inside the window (section 4); the 2 s value is a compile-time constant
   and this note does not add a seam.
2. **Hot parent.** C-P holds the parent group (FOR UPDATE for a completing child) across the E wait;
   a parent with many children completing with lines on one type has no more serialisation than
   today (E and `A` already serialise them) but each holds the parent longer. A cancel of the parent
   waits behind them for longer. Accepted; mitigated because FOR UPDATE is only for completing
   children.
3. **Rollout.** No migration, no persisted data, no event/audit change, replay unaffected, no config.
   Lock order is a per-transaction property, so there is no in-flight state to convert: in-flight
   instances and tenants with running sub-process children simply use the new order for the next
   transaction. During a rolling deploy old and new nodes coexist for seconds; the mixed window can
   only reproduce deadlocks that exist on main today (never a new class), and they are recoverable
   (contention 503 / re-applied apply). Nothing is backfilled. Rollback is a plain revert.
4. **Unconfirmed FK mechanism** (section 3): #2708/#2709 may be unreachable; mitigated by the probe
   first. The reds are schema-order dependent, hence the explicit detect-and-branch in X2/C2.
5. **Test flakiness and load.** Forced-overlap tests use 2-3 connections and real commits; each file
   stays within the per-session cap (<= 4 heavy processes) and the ten-minute experiment bound;
   barriers are always released in `on_exit`; polls are bounded.
6. **Decision-record consistency.** GO changes where a child's ancestor group sits relative to 0054
   D3 steps; REVIEWER to confirm the amendment route (Q5).
7. **Residual after this family:** the four follow-on items (HUMAN tail timers, cold TIMER_FIRED
   append, escalation `tasks`-after-`P`, cancel's stale snapshot) remain until #2706/#2707.

## 7. SECURITY-REVIEWER

None of the four PRs touches the permission-matrix trust-boundary list in WF-02 Step 2c
(`docs/agents/workflows/WF-02_requirement_implementation.md` ~:265-295: `ci.yml`,
`ci_changed_paths.sh`, `cd.yml`, `cd_qa_decide.sh`, `mix.exs` aliases, `config :letflow, :modules`,
`permission_matrix.ex`, `authorization.ex`, `authorized_router.ex`, `route_scope.ex`,
`scope/enforce.ex`, `modules/catalog.ex`, `priv/permission_matrix/`): no API, router, auth, config
or CI file is in any diff. The second criterion, "touches a tenant-data path", is YES for PR-1,
PR-2 and PR-3 (they add row-lock queries on tenant tables inside the engine's write transactions,
all prefix-scoped; #2695 also went through the reviewer and produced SEC F1): INV-1 (every new query
carries the tenant prefix) and INV-7 (locks composed with Ecto `lock/2`, no interpolated SQL; test
helpers that use raw SQL on tenant schemas must quote the schema name as the existing helpers do) apply.
PR-1 additionally widens the entity-port seam (a new optional callback on the boundary that holds
the write authorization checks), so INV-4/INV-5 (no authorization step moves; the lock-only step
performs no read of record data and no authorization) are to be stated in its diff summary.
PR-4 is test-only: out of scope unless it changes `lib/`. REVIEWER is mandatory on all four.
RELEASE-VALIDATOR re-runs the new files.

## 8. Acceptance-criteria map

| Criterion (all three issues) | Where |
|---|---|
| Design note first, order on main with file:line, chosen global order | 1, 2 |
| Reproducing test or proof before the fix, real output quoted | 4.1-4.3 tables (red on base commit, quoted by ELIXIR-DEV), X0/C0 probes, 4.4 for #2705 |
| Fix keeps the #2695 order | 2 (GO extends the #2695 table; changes only C-P, C-E, #2708, #2709) |
| REVIEWER verdict; SECURITY-REVIEWER only on a listed path | 7 |
| Compile with warnings as errors, format check (whole repo, read the rc), scoped tests quoted | each PR's build step; also grep ALL tests for the changed contracts (the flipped E0 assertion, C-5 statement logs) before pushing |
| #2704: sibling inversion with a reproducing test, continuing children | E1, E2 |
| #2704 amendment: HUMAN-vs-service sibling inversion covered, both child kinds one order | 2, 4.1 |
| #2708 deadlock or lock-wait order test | C1, C2 |
| #2709 deadlock or lock-wait order test | X1, X2, X4 |

## 9. Open questions and unverified items

1. **FK-lock mechanism (blocking for #2708/#2709 scope).** Run probes X0/C0 first. If no FK lock is
   taken, both issues become proof-only; if it is taken for some tenant schemas only, the tests must
   keep the detect-and-branch.
2. **Entity-port seam (Q2).** Optional callback plus wrapper (chosen) versus a flag in `multi_ctx`.
   The flag would change what every existing test double of `multi/3` does; rejected, but REVIEWER
   may prefer a required callback and updating the doubles listed by
   `grep -rl "@behaviour Letflow.Engine.EntityPort" test` (9 files).
3. **Synthetic projection row of a type.** C-E locks only the type's sequence row; the synthetic
   projection row is then taken by the event append (S before P within one append). Whether any path
   locks a type's synthetic projection row without the sequence row first (activator `ensure`,
   `EntityTypeInstance`) is not verified; if one does, E has an internal order to define.
4. **`scope_node_paths` (0054 D3 rule 3a)** is not taken today (no scoped type). When it is, the
   service pre-lock must take it before the type rows. Not applicable now.
5. **Decision-record route (Q5).** Amendment paragraph to 0054 D3 (proposed) versus a new decision
   record; REVIEWER to rule. The engine moduledoc is rewritten either way.
6. **Pre-lock when the ancestors do not exist yet.** `lock_waiting_parent` reads the waiting token
   unlocked and re-selects it after locking the parent projection (`sub_process.ex:778-799`);
   unchanged. A child whose parent token moved between the read and the lock yields `nil` and the
   cascade is a no-op, as in #2695.
7. **Unverified by any run (no `mix` was run):** every pairwise cycle in 1.6, the I4 cycle, the
   fire_timer S-before-P cycle, the OID-ordering explanation of the FK order, that no caller of
   `ExecutionError.append_multi/3` writes the child's projection before the landing, that
   `build_snapshot_and_state` and `check_completion_guards` take no lock (grep only), that no
   existing test beyond the ones named pins the old order, the PG version needed for any
   `pg_stat` use (not used: telemetry is the deadlock evidence).
8. **#2705 test placement.** Keep E1/E2 and the I4 test in PR-1 (PR-1 then closes #2705's substance)
   or leave the I4 test to PR-4. Recommended: I4 test written first inside PR-1 because C-E is its
   fix; PR-4 then only adds the "cannot occur" proof for the remaining `A` vs `S_x` pairs.
9. **fire_timer lock mode** (4.4): FOR UPDATE on the immediate parent for every child timer fire is
   the recommendation; to be settled in the #2707 note.
