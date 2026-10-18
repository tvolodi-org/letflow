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
| 4 | `maybe_entity_writes` -> `EntityPort.multi` -> `StepWrites.multi` | `E`, per line sorted by `(entity_type, index)`: first command of a type takes its sequence row (`lock_and_increment_sequence`, `event_store.ex:749-763`), then its projection; with `module_writes` an explicit `{:type_lock, type}` per type first (`step_writes.ex:581` (call), `622-634` (definition); `handler_writes.ex:426-439`) | `engine.ex:2859`, `3174-3195` |
| 5 | tail clause 1, execution error | `ExecutionError.append_multi` with the held `P_c`: `S_c`, DLQ row, `P_c` UPDATE | `7133-7147` |
| 5 | tail clause 2, advanced: `:lock_ancestors` FIRST | parent group of `c`: whole chain FOR UPDATE if the final status is `:completed`, else immediate parent FOR KEY SHARE | `7214-7217`, `8671-8678` |
| 6 | timers_c cancel (escalation, reminder), token reconcile, task activation | `timers_c` UPDATE (after `P_c`), `tokens_c`, `tasks_c` inserts, **`A`** at each `task.create` audit (`task_activation.ex:483-495`) | `7218-7251` |
| 7 | timer/dispatch arms, `:task_complete`, `record_task_complete_audit`, per-line entity audits, SYS/APPLIED events | **`A`**, then `S_c` (events) | `7252-7336` |
| 8 | `:event` (TASK_COMPLETED) | `S_c`, then `P_c` UPDATE (every event append updates the projection: `event_store.ex:606-618`, `897-910`) | `7337-7345` |
| 9 | `:projection`, children creation, `append_sub_process_completion_cascade_multi` | `P_c` UPDATE; cascade re-locks the parent group (no wait, already held), then `S_p`, `P_p` UPDATE | `7346-7368`, `7396-7452` |

So the HUMAN child order on main is `tasks_c, P_c, E, [P_p, T_p (, P_g, T_g ...)], timers_c, A, S_c, P_c upd, S_p, P_p upd`.
The existing statement-trace test pins exactly this E-before-parent-group order
(`test/letflow/engine/cancel_cascade_lock_order_test.exs:649-723`, the assertion is at `721`:
`first_type_row < first_parent_lock`).

### 1.2 Service / script apply, `do_persist_service_task_advance/10` (`engine.ex:4960-5162`)

Before the Multi (callers, `engine.ex:4600-4640`): dispatch (or script CAS) row, then `P_c`
(`lock_projection_for_service_apply`), then plain reads. Then one Multi (plan: SET LOCAL first):

| # | Step | Locks / writes | Anchor |
|---|---|---|---|
| 1 | `:lock_ancestors` (GH #2695, first step) | parent group, mode as in 1.1 | `5008-5010` |
| 2 | hop-chain token inserts, `TaskActivation.append_multi_from_existing_records` | `tokens_c`, `tasks_c` inserts; **`A` at each `task.create` audit** (`task_activation.ex:403-421`, `468`, `483`) | `5011-5044` |
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
Key-share compatibility holds for the group itself, but it does not make two continuing siblings deadlock-free on main: E2c was measured RED on main through the I4 inversion (the continuing service sibling's activated HUMAN task takes `A` before the type rows), not through the group. No path takes key-share and later upgrades the same rows (two sibling upgraders would deadlock).
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
edges only go ancestor-ward and only inside L4; that is what carries the argument. L5 (live tokens `T_x`, `tokens_c`) is touched by the HUMAN/service tails but only under `P_c` (L3), so it is serialised by `P_c`. Therefore, for the paths of this family, a
wait-for edge from a transaction holding class k to one holding class j<k cannot exist, so no cycle.
This holds for the family's paths only, NOT tenant-wide. Residual exceptions (all #2707 scope, not fixed here): the HUMAN tail's timer cancel after `P_c`; the cold TIMER_FIRED append; escalation fire's `tasks` lock after `P_x`; cancel's stale snapshot (#2706); and further COLD appenders found in CDV review: `Repository.Attachments` appends ATTACHMENT_ATTACHED/REMOVED after commit with a cold `EventStore.append` (`attachments.ex:374`, `412`: `S_x`, then the `P_x` UPDATE, no prior `P_x` lock), and a reminder fire appends TIMER_FIRED and then takes `A` with no `P` lock. Any cold appender has the same shape as the timer case.

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
* **Escalation fire takes `tasks` FOR UPDATE after `P_x`** (`:original_task_row`, `engine.ex:4229`,
  update `4237-4252`): order `timer, P_x, tasks`, inverted against `complete_task` (`tasks, P_x,
  timers`). Recorded as fact (the lock is explicit in the query); input for #2707, not designed here.
* **The `engine.ex` moduledoc is corrupted at lines 402-403** ("foreign-key locks on the p  while
  cancel takes it last. I3 (fixed for ..."): a bad edit merged text. PR-1 must repair it while
  rewriting the paragraph.
* **FK mechanism: CONFIRMED by the GH #2709 probe (PR-2, section 10a), refined.** An UPDATE of a
  child's projection row takes the FK `KEY SHARE` locks on the parent token and the parent
  projection only when the old row version was written by the SAME transaction (Postgres skips the
  check for an unchanged key otherwise); the first UPDATE takes none, the second does. The
  ExecutionError landing UPDATEs the row twice (event append, then `:error`), so it does. The
  original text of this bullet follows, kept for the record. (Was: FK mechanism is unconfirmed.) Postgres queues an FK check on UPDATE of the referencing row
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
  1.5 s for the same reason, `service_task_entity_writes_lock_order_test.exs:360-380`). Margin: the
  green cases need park time plus post-release work to stay under 2 s per waiter. This was NOT
  measured here (no run). ELIXIR-DEV records the measured park time and the slowest green wait in each
  PR description; if the margin is under 0.5 s the PR adds a test-env-only runtime read of the two
  timeout strings (validated integer milliseconds from config, never interpolated input) in place of
  the compile-time constants, otherwise no seam.

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

C-E, service/script: append, through the entity port, a group of lock-only `{:pre_type_lock, type}` steps (one per type; no single named step) right after `:lock_ancestors`
(`engine.ex:5010`) and before the `Multi.merge` that inserts tokens (`5011`). It locks, ascending by
`entity_type`, the sequence row of every type in the UNION of the declared line types and the
registered target types of the plan's `module_writes` handlers
(`HandlerWrites.registered_targets(module_lines)`), filtered to types that have a synthetic
instance: exactly the set `StepWrites.lock_types/4` computes for a HUMAN node (`step_writes.ex:624-634`;
a service plan carries `module_writes` since GH #2590 R5, `engine.ex:5336-5355`). A lines-only set
would leave a handler-only target type locked after the task-activation `A`, so I4 would survive for
such a node. Each lock is `EventStore.lock_instance_sequence/3` (`event_store.ex:739-747`). Skipped when the
completion has no `:entity_plan`. The lines' own later lock steps (and the `{:type_lock}` steps) become no-op re-locks. The engine
must not name `Letflow.Entities` (0039 D3 boundary), so the step goes through the entity port.

Public/internal shapes (signatures only):

* `Letflow.Engine.EntityPort` (`entity_port.ex`): new OPTIONAL callback
  `lock_types(Ecto.Multi.t(), lines :: [line()], module_lines :: [module_write_line()], lock_ctx :: %{prefix: String.t()}) :: Ecto.Multi.t()`
  plus a wrapper `EntityPort.lock_types/4` that returns the multi unchanged when the configured
  implementation does not export it (test doubles that `@behaviour` the port keep compiling; an
  optional callback produces no warning under `--warnings-as-errors`).
  **Supervisor ruling (rev 4): optional for doubles, mandatory for the production adapter.** An
  optional callback cannot make the compiler flag an omission, so the guarantee is three explicit
  pieces: (1) `@optional_callbacks [lock_types: 4]` in the port, and `Letflow.Entities.EntityPortImpl`
  declares `@impl true` on its `lock_types/4` (the compiler then rejects a wrong arity or a function
  that is not a callback); (2) a boot-time check, `EntityPort.verify_adapter!/0`, called from
  `Letflow.Application.start/2` before the supervision tree, which raises with a named message when
  the configured adapter (`config :letflow, :entity_port`, `config/config.exs:127`) does not export
  `lock_types/4` (test doubles are installed with `Application.put_env` after boot, so they keep the
  no-op default and never reach this check); (3) a test, `test/letflow/engine/entity_port_prelock_wired_test.exs`,
  of this shape: it fails if the production adapter lacks the pre-lock, either by (a) asserting
  `function_exported?(Letflow.Entities.EntityPortImpl, :lock_types, 4)` and that `verify_adapter!/0`
  returns `:ok` for it and raises for a stub module without the function, and (b) behaviourally:
  building the service Multi for a plan with lines on type X through the production adapter and
  asserting (via `Multi.to_list/1` names, the introspection helper at `engine.ex:2735-2750`
  generalised or a sibling for the service build) that a `{:pre_type_lock, "X"}` step exists
  between `:lock_ancestors` and the token-insert step; the same assertion for a handler-only target Y
  (E6). Omitting the adapter function therefore fails at boot AND in CI; the wrapper's silent
  fallback applies only to doubles.
* `Letflow.Entities.EntityPortImpl.lock_types/4` -> new public `Letflow.Entities.StepWrites.lock_planned_types/4`
  (`Multi.t(), [line()], [module_write_line()], prefix`) :: `Multi.t()`; it is the private
  `lock_types/4` without its "no module_writes -> identity" first clause (that clause stays for the
  in-`multi/3` locks). Step keys: the pre-lock must NOT reuse `{:type_lock, type}`, because for a node
  with `module_writes` `build_lines` emits the same keys later and Ecto.Multi rejects duplicate names.
  `HandlerWrites.lock_types/3` therefore gains a key-tag argument (`HandlerWrites.lock_types/4`, tag
  `:type_lock` for the existing call, `:pre_type_lock` for the pre-lock); the later `{:type_lock, type}`
  steps become no-op re-locks. A failed `{:pre_type_lock, _}` step (only `{:sequence_conflict, ...}` is possible) is returned on the service path as the generic `{:error, reason}` because only `{:line, _, _}` steps keep their name (`engine.ex:5132`); this is the same as a failed `{:type_lock}` today. Accepted, not to be "fixed". No new error shape: a type without
  a synthetic instance is skipped, as today.
* `Letflow.Engine` private: the group of `{:pre_type_lock, type}` steps appended in `do_persist_service_task_advance/10`; no
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
| E0 | statement order, HUMAN (plan) | none | red: `first_type_row < first_parent_lock` is today's assertion (`cancel_cascade_lock_order_test.exs:649-723`, assertion `721`); the NEW assertion is the reverse | green; the old test is FLIPPED in this PR |
| E0s | statement order, service (plan) | none | red when the service node is followed by a HUMAN node: `A` (`audit_chain_locks`) precedes the first type-row lock, and (as built) the first `tasks` INSERT precedes the type row | green: parent group, then type rows, then `A`; the type row also precedes the first `tasks` INSERT (the pre-lock sits before the first merge after `:lock_ancestors`) |
| E0c | statement order, completing service CHILD (plan, as built in PR-1) | none: `capture_repo_queries` of the apply of a service child that ends the child (`ct` -> svc(lines X) -> END) | trace: parent projection `FOR UPDATE`, waiting token `FOR UPDATE`, type-row sequence `FOR UPDATE`, `audit_chain_locks`, in that index order. Green on main by reading (a completing child activates no task, so no `A` before E; the group already preceded E on the service path since #2695): it pins that both child kinds read the same string, it is not a red | green (same trace) |
| E2d | lock MODE of a continuing child, by statement trace (as built in PR-1) | none: `capture_repo_queries` of a continuing HUMAN child's completion and of a continuing service child's apply | trace: the group statements are exactly parent projection `FOR KEY SHARE` and waiting token `FOR KEY SHARE`, no `FOR UPDATE` among them. Expected green on main for both by reading; it exists because E2c cannot see a wrongly strong mode (same order, no deadlock) | green (same trace) |
| E4x | execution-error transition inside a child completion (as built in PR-1) | none: a HUMAN child completion with lines whose gateway has no matching edge (the `:transition` step ends in an execution error) | no raise; child `:error`; no records written. Trace at PR-1: no group statement at all (the `:lock_ancestors` step returned `{:ok, []}`). Trace after PR-2: the only group statements are the landing's own `FOR KEY SHARE` pair (E4x asserts key share, never `FOR UPDATE`) | green |
| E1 | sibling completing H and S (pins the sibling inversion of the amendment) | `Z` holds X's sequence row. Start H, wait 1 blocked, start S, wait 2 blocked, release. H queued first at E on main, S holds the group and queues second | red: 40P01 (H holds E, wants group; S holds group, wants E) | green: H holds the group (FOR UPDATE), S parks at the group, no E cycle |
| E2a | continuing H' (HUMAN node to another HUMAN node, key-share group) vs the parent's OWN completion with lines on X | `Z` on X. Start H' FIRST, wait 1 blocked (main: queued at E, no group yet), start the parent completion (takes `tasks_p`, `P_p` FOR UPDATE, queues at E second), wait 2 blocked, release | red on main: H' gets E first, then wants the key-share group held FOR UPDATE by the parent, which waits for E | green: H' (started first) holds the key-share group and E; the parent parks at `P_p` |
| E2b | continuing H' vs a COMPLETING sibling S (group FOR UPDATE) | same barrier; H' first, S second | red on main: H' holds E and wants the group S holds; S holds the group and wants E | green |
| E2c | two continuing siblings H' and S' | same barrier | **RED on main (measured, as built)**: the continuing service sibling S' activates a HUMAN task (`h2`), so on main it takes `A` before the type rows while H' takes the type rows before `A`, the I4 inversion (a 40P01 on `instance_sequence`), not a group cycle. Key-share is still compatible between siblings (section 2.3), so the GROUP itself never blocks them | green after PR-1. E2c cannot detect a continuing child wrongly taking the group FOR UPDATE (same order, no deadlock), so E2d pins the MODE by statement trace |
| E3 | child completion (HUMAN, lines on X) vs the parent's OWN completion with lines on X (parent has a second parallel HUMAN branch with lines) | `Z` on X. Start the CHILD FIRST, wait 1 blocked, start the parent completion second, wait 2 blocked, release. FIFO: the child gets E, then wants `P_p` (held by the parent, which waits for E) | red on main: 40P01 (`E -> P_p` vs `P_p -> E`). With the opposite start order it would be green on main, so the order is part of the test | green |
| E5 | I4, service vs HUMAN, no parent needed: S' = service node WITH lines on X whose NEXT node is a HUMAN_TASK (the apply activates that task, so it writes `task.create` and takes `A` before E on main) vs a HUMAN completion with lines on X | The fixture first performs one audit write so the `audit_chain_locks` row exists (`lock_chain_tail!` creates it lazily, `audit.ex:284-300`); `Z` then holds it. Start S' first, wait 1 blocked (on main it is parked at `A`), start H, wait 2 blocked (H holds E, parked at `A`), release: S' is granted `A`, wants E | red on main: 40P01 (`A -> E` vs `E -> A`); green after (S' takes E before `A`, H queues behind it) |
| E6 | C-E for a handler-only target: service node with `module_writes` whose handler's registered target type Y is NOT a declared line type (fixtures of `test/letflow/engine/module_write_service_task_test.exs`), next node HUMAN, vs a HUMAN completion with `module_writes` to Y | as E5 (including the warm-up audit write), barrier `Z` on `A` | red on main AND red with a lines-only pre-lock (this case proves the union is needed) | green with the union |
| E4 | cancel safety, re-run T1-T9 of `cancel_cascade_lock_order_test.exs` unchanged | as written | green | green (regression) |

Assertions per forced test: zero telemetry deadlock/lock-timeout reports; both workers return within
the await bound; record count equals declared lines (no partial or duplicate write); the audit chain
verifies; `SUB_PROCESS_COMPLETED` exactly once for completing cases. The expected red on main is
the 40P01 reaching the telemetry handler (40P01 rather than 55P03 only because the server's
`deadlock_timeout`, default 1 s, is shorter than the 2 s `lock_timeout`; with a larger setting the same
red shows as 55P03, which the handler also reports, so the assertion covers both codes) (the service side is re-applied by the engine and the HUMAN
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
`7209-7213` removed with the step, and a NEW decision record,
`docs/migration/decisions/0061-engine-lock-order-platform-invariant.md` (decision 0061), stating GO (section 2)
as a platform invariant, plus one pointer line in `0054-process-step-writes-entity.md` D3,
"Amended by 0061" (rule 2b: the ancestor group of a sub-process child is taken after step 2
and before step 3a/4). Ruling: new record, not an in-place amendment of D3.

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
| X0 | mechanism probe | transaction A UPDATEs the child's projection row; connection B tries `FOR UPDATE NOWAIT` on the parent's waiting token and on the parent projection | tells whether key-share FK locks are taken at all; if B is NOT refused, #2708 and #2709 cannot occur and both end as proof-and-regression (no lib change). MEASURED (PR-2): ONE UPDATE does not refuse B, TWO UPDATEs of the row in the same transaction refuse B on both parent rows (section 10a); the hazard is real | n/a |
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
`lock_parent_group/4` currently pattern-matches an `InstanceState` status (`engine.ex:8671-8678`);
cancel has no state. Decision: the third argument becomes `intent :: :completing | :continuing`
(`lock_parent_group(Ecto.Repo.t(), Ecto.UUID.t(), intent, prefix :: String.t() | nil) :: {:ok, [TokenRecord.t()]}`);
`:completing` = `SubProcess.lock_waiting_parent_chain/3` (FOR UPDATE chain), `:continuing` =
`SubProcess.lock_waiting_parent/4` with `:key_share`. A private `lock_intent(InstanceState.t())`
maps `%{status: :completed}` to `:completing` and everything else to `:continuing`; the two existing
call sites (the service step, `engine.ex:5009`, and the C-P step) call it, the cancel step passes
`:continuing` literally. No behaviour change for the existing callers. Cancel's other rules
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

* **#2705 (AUDIT-SEQ).** Reduces to I4 (section 2.2). Ruling (rev 4): this is a service-vs-HUMAN
  inversion proven by reading, not a "possible, not demonstrated" item. PR-1 MUST include its
  demonstrating test (E5, red on main, quoted) and #2705 is to be relabelled accordingly (it is no
  longer "possible, not demonstrated"; its fix is C-E in PR-1, PR-4 keeps only the residual proof). With C-E in PR-1, there is no `A` / S-row
  inversion left among the family's paths. #2705 becomes: forced-overlap test (service step that
  activates a HUMAN task and has lines on X, versus a HUMAN completion with lines on X; start
  order service first, `Z` holds `A`; release) which is RED on main (A -> E vs E -> A) and must be
  GREEN after PR-1; plus a statement-order test for the continuing service step. If PR-1 already
  carries both tests and they pass, #2705 closes with "fixed by C-E, proof in tests". Placement is decided: the
  I4 tests (E5, E6) live in PR-1, because C-E is their fix and a fix ships with its red-first test;
  PR-4 only adds the "cannot occur" proof for the remaining `A` vs `S_x` pairs.
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
  upgrade. Escalation's `tasks`-after-`P` lock (section 3, fact) needs the same look.

## 5. Pull-request split (one PR per issue, strictly sequential)

Core-directives merge discipline: one functional PR in CI at a time; no docs/chore merges while a
functional PR is in CI; run the CI-shaped checks locally before each push. This design note itself
lands first as a docs-only PR (GH #2704 branch `design/GH-2704-lock-order`) when no functional PR
is in CI.

| Order | PR | Issue | Content | Size (est.) | Depends on |
|---|---|---|---|---|---|
| 0 | docs | - | this design note | 1 file | - |
| 1 | PR-1 | #2704 | C-P, C-E, port callback, `Letflow.LockOrderHelpers` extraction, tests E0-E6 (E5 and E6 are the I4 / #2705 cases), moduledoc rewrite, new decision record 0061 + the 0054 D3 "Amended by" pointer line, boot-time adapter check + wiring test | prod ~70 lines, tests ~450, docs ~120 | note merged; owns the moduledoc rewrite, so it goes first |
| 2 | PR-2 | #2709 | `ExecutionError` step, tests X0-X4, one moduledoc line. STATUS: built (section 10a): probe positive, lib change made, X1/X2/X4 red on the unmodified landing and green after | prod ~25, tests ~250 | PR-1 (shared helpers, moduledoc) |
| 3 | PR-3 | #2708 | cancel step, `lock_parent_group` generalisation, tests C0-C4, one moduledoc line | prod ~15, tests ~220 | PR-1; independent of PR-2 (either order) |
| 4 | PR-4 | #2705 (relabelled: proven service-vs-HUMAN inversion; demonstrating test E5 is in PR-1) | proof for the remaining `A` vs `S_x` pairs and regression tests (and a fix only if a test is red after PR-1) | tests ~200 | PR-1 |
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
   D3 steps; settled: a new decision record (0061) with an
   "Amended by" pointer in 0054 D3, both in PR-1.
7. **Residual after this family:** HUMAN tail timers, cold appenders (TIMER_FIRED, attachment events, reminder fire; section 2.4), escalation `tasks`-after-`P`, and cancel's stale snapshot remain until #2706/#2707. The no-cycle claim is for the family's paths only.

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
| REVIEWER verdict; SECURITY-REVIEWER where required | 7: PR-1, PR-2, PR-3 ARE security-reviewer scope (tenant-data path); no listed trust-boundary file is touched; PR-4 only if it changes `lib/` |
| Compile with warnings as errors, format check (whole repo, read the rc), scoped tests quoted | each PR's build step; also grep ALL tests for the changed contracts (the flipped E0 assertion, C-5 statement logs) before pushing |
| #2704: sibling inversion with a reproducing test, continuing children | E1, E2a, E2b, E3 |
| #2704 amendment: HUMAN-vs-service sibling inversion covered, both child kinds one order | 2, 4.1 |
| #2708 deadlock or lock-wait order test | C1, C2 |
| #2709 deadlock or lock-wait order test | X1, X2, X4 |

## 9. Open questions and unverified items

1. **FK-lock mechanism (blocking for #2708/#2709 scope).** Run probes X0/C0 first. If no FK lock is
   taken, both issues become proof-only; if it is taken for some tenant schemas only, the tests must
   keep the detect-and-branch.
2. **Entity-port seam (Q2): settled** (supervisor, rev 4): optional callback, production adapter mandatory via `@impl`, boot check and wiring test (section 4.1). The alternatives below are kept for the record. Optional callback plus wrapper (chosen) versus a flag in `multi_ctx`.
   The flag would change what every existing test double of `multi/3` does; rejected, but REVIEWER
   may prefer a required callback and updating the doubles listed by
   `grep -rl "@behaviour Letflow.Engine.EntityPort" test` (10 files, including `test/support/chaos_entity_port.ex` and `test/support/script_task_fixture.ex:421`).
3. **Synthetic projection row of a type: settled by grep.** `entity_type_instance.ex` has no
   `FOR UPDATE`/`lock(`; its only projection write is the pre-transaction insert in
   `ensure_instance_projection` (`:147`, reached from `get_or_create/2` `:94`, outside the race;
   `StepWrites.prepare` runs it before the transaction). The synthetic projection row is therefore
   locked only by the `update_projection` of an event append, which always follows the sequence-row
   lock (`event_store.ex:609-618`). Locking the type's sequence row is sufficient; E has no internal
   order beyond "ascending type".
4. **`scope_node_paths` (0054 D3 rule 3a)** is not taken today (no scoped type). When it is, the
   service pre-lock must take it before the type rows. Not applicable now.
5. **Decision-record route: settled** (supervisor, rev 4): new record 0061, plus the pointer in 0054 D3; both in PR-1.
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
8. **#2705 test placement: settled.** E5/E6 are in PR-1; PR-4 holds the remaining proof only.
9. **fire_timer lock mode** (4.4): FOR UPDATE on the immediate parent for every child timer fire is
   the recommendation; to be settled in the #2707 note.

## 10. As built (PR-1, ELIXIR-DEV)

* Added fixture definition `fxl_svc_then_human` in `priv/module_fixtures/ledger_foundation.json`
  (SERVICE_TASK with `module_writes` `post_balance_only`, then a HUMAN task): E6 needs a service
  node with a handler-only target followed by a HUMAN task, which no existing pack definition had.
* Test seam `probe_service_multi/1` in `engine.ex` (compiled only with `config :letflow,
  :engine_test_seams`; sends the step names of the service Multi to the pid in the
  `:service_multi_probe` env key): used by `entity_port_prelock_wired_test.exs`.
* Three existing tests edited for the changed contracts: `complete_task_entity_writes_test.exs`
  (the B-15 step names now contain `:lock_ancestors` after `:transition`), `entity_port_boundary_test.exs`
  (seven port callbacks, the seventh optional) and `module_write_owner_path_test.exs` (`HandlerWrites`
  exports `lock_types/4`).
* Failed pre-lock step: `StepWrites.interpret_failure({:pre_type_lock, _}, _)` is `{:failed, 0, :type_lock}`
  and the service apply names that step so the port interprets it (security review L1).
* E2c is red on main (see its row); E2d (lock mode) and E0c (service child statement trace) were added.
  The harness duplication in `cancel_cascade_lock_order_test.exs` stays (follow-up).

* Asymmetry, stated (security-review delta): on the service apply a failed in-Multi
  `{:type_lock, _}` step (the lock a node with `module_writes` still emits inside `StepWrites.multi`)
  is not named by the engine failure clause, which names `{:line, _, _}` and `{:pre_type_lock, _}`
  only, so it would surface as the generic `{:error, reason}`. After PR-1 it is a no-op re-lock of a
  row the pre-lock already holds in the same transaction, so it cannot be the step that waits or
  fails; accepted, not to be "fixed". The HUMAN path names no step by key and is unaffected.

## 10a. As built (PR-2, GH #2709, ELIXIR-DEV)

* **Probe first (X0), result.** Transaction A UPDATEd a child's projection row; a second connection
  then tried `FOR UPDATE NOWAIT` on the child's own row (positive control), the parent's waiting
  token and the parent projection:
  `one_update=%{control: {:refused, :lock_not_available}, token: {:granted, 1}, parent_projection: {:granted, 1}}`,
  `two_updates=%{control: {:refused, :lock_not_available}, token: {:refused, :lock_not_available}, parent_projection: {:refused, :lock_not_available}}`.
  A single UPDATE takes no FK lock; the second UPDATE of the same row in one transaction takes both.
  The landing is exactly such a pair (the EXECUTION_ERROR append updates `last_event_seq`, then the
  projection goes to `:error`), so the hazard is real and the "unconfirmed" caveat of sections 3
  and 9.1 is closed for #2709. (It also explains the schema dependence: the check order is the FK
  constraint-trigger order, and the first UPDATE of any transaction is lock-free.)
* **Red on the unmodified landing** (X2, X4a, X4b, token-first schema): `ERROR 40P01
  (deadlock_detected)`: reported through the telemetry handler for the HUMAN tail (the RI statement
  `SELECT 1 FROM ONLY ...instance_projections x WHERE "instance_id" = $1 FOR KEY SHARE OF x`) and as
  the worker exit for X2 and X4b; X1 red: no `FOR KEY SHARE` statement before the EXECUTION_ERROR
  insert. X3 (projection-first schema) is green before and after.
* **The fix** is the one choke point of 4.2: step `:execution_error_lock_ancestors` in
  `ExecutionError.append_multi/3`, after `:execution_error_eligibility`, calling
  `SubProcess.lock_waiting_parent(repo, instance_id, prefix, :key_share)`. All nine callers are
  covered; no caller changed. Runtime call `ExecutionError -> SubProcess` only (no struct, no macro).
* **Test control of the FK order.** X2/X3 re-create the two parent FKs of `instance_projections` in
  the wanted order inside their own fresh tenant and assert the resulting constraint-trigger firing
  order as a precondition, so the red does not depend on the OID luck of provisioning (4.2 had a
  detect-and-branch; this is deterministic instead).
* **Margin.** The paths have no `lock_timeout`; the PR-1 yardstick (2000 ms minus the worst
  park-plus-finish time) measured 1920-1941 ms in the green runs, against the 500 ms floor.
* **Existing test edited:** `entity_parent_lock_order_test.exs` E4x asserted no group statement at
  all for an execution-error transition; since PR-2 the landing's own `FOR KEY SHARE` pair is the
  only group lock (asserted as key share, never `FOR UPDATE`).
* **Not covered by a separate case:** the cascade error branch (`engine.ex:7442`,
  `sub_process.ex:554`, `1302`): there the instance is the parent and the completing chain is already
  held `FOR UPDATE`, so the landing's key share is a no-op re-lock. The engine moduledoc "Known gaps"
  no longer lists #2709.
