# REQ-513 / GH #2688: stuck-`advanced` dispatch sweeper (design record)

Author: designer (T-0366), 2026-10-24 (revision 2, after design_gate attempt 1).
Base: `main` at `b7ada7eba`. Scope: design only. No product code. Entity-write class only (task
rule; the other ISS-0928 classes stay deferred, section 10).

## 0. What this slice delivers

This task (design-only slice of GH #2688) commits exactly one file: this record, at
`lib/letflow/design/gh2688-req513-stuck-advance-sweeper.md` (same directory as
`service_task_dispatcher.md`, the design record of the dispatcher it extends). No other file changes,
no migration, no test. The PR says `Refs #2688` and names the build (section 12) as the remainder.
The issue stays open until the build lands. `docs/requirements.yaml` status is not touched.

## 1. Problem

On the HTTP SERVICE_TASK route the dispatch row is committed `"advanced"` in its own transaction
(`handle_success/3`, `service_task_dispatcher.ex:1231-1235`, which also sets `dispatched_at`) before
`Letflow.Engine.advance_after_service_task_outcome/4` runs the completion. Nothing re-claims an
`"advanced"` row (`claim_due_dispatch_ids/2` selects `status == :pending` only, `:420-455`). If the
process crashes after the `"advanced"` commit and before the ERROR landing commits, or the landing
exhausts its contention budget (D-C.8 (d), `docs/runbooks/service-task-entity-write-refusal.md`
"Known residual"), the instance stays `ACTIVE` with a lost token. The sweeper finds those rows and
lands them as ERROR, once.

## 2. Approach

A plain, unsupervised sweep module, called from the existing `ServiceTaskDispatcher.Poller` tick (no
new process, no new boot gate). Per tenant it walks the stuck candidates with a keyset cursor, and for
each in-class candidate runs one landing transaction that re-locks and re-checks everything. The
landing reuses the lock order and the completion-key read of the D-C.8 landing already on `main`
(`Letflow.Engine` `http_landing_multi/4`, `engine.ex:6448-6488`), with a new public code and error
type. Default mode is `:off`.

## 3. Decisions

**D1. Selection rule and walk (HTTP route only).** A row is a candidate when all hold:
- `service_task_dispatches.status = 'advanced'`;
- `dispatched_at <= now - stuck_advance_min_age` (age from the `advanced` commit, `:1235`);
- the instance projection is `ACTIVE` (`instance_projections.status = 'active'`, join on
  `instance_id`, the join shape of `claim_due_dispatch_ids/2`);
- no `event_idempotency` row with key `'service_task_dispatch:' || d.id` (`NOT EXISTS`);
- the node is in the entity-write class (D5), checked in Elixir on the pinned snapshot.

The class filter cannot be a SQL predicate (the graph lives in the snapshot, not in a column), so the
walk must not let out-of-class rows fill the batch. The walk is therefore a **keyset cursor over
`(dispatched_at, id)` ascending**. This is the fix for the starvation found in design_gate attempt 1:

- One page = `stuck_advance_scan_page_size` rows (default 100) after the cursor, `ORDER BY dispatched_at,
  id LIMIT page`, with the same filters. Each row of the page is classified (D5); in-class rows are
  landed (D8).
- Per tenant per sweep the walk stops after `stuck_advance_scan_limit` rows (default 1000, i.e. 10
  pages), after `stuck_advance_batch_size` in-class landing attempts (default 20), at the end of the
  candidate list, or when the sweep budget is spent (D8). The cursor is the `(dispatched_at, id)` of
  the last row scanned.
- At the end of the candidate list (a short page) the cursor resets to `nil`, so the next sweep starts
  from the oldest again. A reset is never followed by a re-scan in the same sweep.
- The cursor is kept in the Poller's state, one entry per tenant schema, in memory. A restart resets it
  to `nil`, which is harmless (landed rows are no longer candidates).

Starvation bound: every row older than the cutoff is scanned once per cycle, and a cycle takes
`ceil(N / scan_limit)` sweeps, where `N` is the number of old stuck rows of that tenant. An in-class row
behind any number of out-of-class rows is therefore reached within one cycle, not never. `:shadow` walks
the same way and writes nothing.

A row whose landing was skipped for contention (D8) keeps its place behind the cursor and is retried on
the next cycle, not the next sweep. Stuck rows are rare by design (only after a crash or an exhausted
landing budget), so one cycle is an acceptable latency; stated here, not hidden.

Script route rows (`script_task_dispatches`) are NOT selected: the runbook says the script route has no
such window (its lease sweep turns an expired `running` row into a `timeout` incident).

**D2. Config (new keys under `config :letflow, :service_task_dispatcher`, read per call like the
accessors at `service_task_dispatcher.ex:251-276`).**

| key | default | meaning |
|---|---|---|
| `stuck_advance_mode` | `:off` | `:off` (no query), `:shadow` (walk and log candidates, write nothing), `:on` (land) |
| `stuck_advance_min_age_seconds` | `600` | candidate age; a value below the floor 120 is raised to 120 |
| `stuck_advance_sweep_interval_ms` | `60_000` | minimum gap between two sweeps (the Poller ticks every `poll_interval_ms`, 5 s by default) |
| `stuck_advance_batch_size` | `20` | in-class landing attempts per tenant per sweep |
| `stuck_advance_scan_page_size` | `100` | rows per keyset page |
| `stuck_advance_scan_limit` | `1000` | rows scanned per tenant per sweep (the class-filter walk bound) |
| `stuck_advance_sweep_budget_ms` | `1000` | wall-clock budget for one sweep across all tenants |

Reason for the mode flag (required): the landing turns a live instance ACTIVE into ERROR, which is NEW
product behaviour for that class (the same ruling as OQ-C3). `:off` is the default because the project's
rule is that new feature flags default off; `:shadow` lets an operator on QA see the candidate list
before anything is written. The other keys are tunables, not flags; no other flag is added.

**D3. Race exclusion and lock order.**
- The landing takes the dispatch row `FOR UPDATE` first, then the projection `FOR UPDATE`, then does the
  explicit `event_idempotency` read, then calls `ExecutionError.append_multi` with `locked_projection:`.
  This is the order of the apply path (`fetch_and_lock_service_task_dispatch/3` at `engine.ex:5132`, then
  `fetch_and_lock_instance_projection/3` at `:3842`), so no inversion.
- Under the dispatch lock the landing re-checks: `status == "advanced"`, the age (`dispatched_at`), the
  projection `ACTIVE`, and the class (D5, from the pinned snapshot).
- Return values of `Letflow.Engine.land_stuck_service_dispatch/2` (one value per case):
  - no row with that id in that prefix (absent, or belonging to another tenant): `{:error, :not_found}`.
    Both cases return the identical value, so a foreign id is indistinguishable from an unknown one
    (INV-5). `{:ok, :already_final}` is NOT used for a missing row;
  - row not `advanced` (already landed or completed): `{:ok, :already_final}`;
  - projection not `ACTIVE` (cancelled, ERROR, or any other status): `{:ok, :instance_moved_on}`;
  - row `advanced` and ACTIVE but the completion key already present: `{:ok, :already_final}`;
  - out of class: `{:ok, :not_in_class}`; too young: `{:ok, :too_young}`; no write in either case;
  - landed: `{:ok, :landed}`; lock timeout or contention: `{:error, :contention}`, no write.
- The completion key is the same as the apply's, `service_task_dispatch:<id>`. The apply path and the
  landing both take the dispatch row lock, so they serialise on it:
  - A late apply still inside its transaction holds the dispatch row `FOR UPDATE`. The sweeper waits on
    that lock (up to its 2 s timeout). If the apply commits first, the sweeper then sees the key and
    returns `{:ok, :already_final}`. If the sweeper times out, the candidate is skipped and retried on the
    next cycle (D1). Either way exactly one writer lands.
  - The age margin protects the two windows that lie OUTSIDE a transaction: (i) between the `advanced`
    commit and the apply's first lock, and (ii) between a rolled-back apply and its D-C.8 landing. In
    window (ii) the sweeper's landing wins, and the D-C.8 landing then answers `already_final`, so the
    event records `dispatch_apply_lost` (the sweeper's code), not `entity_write_refused`. This is the
    intended outcome: one event, and it names the lost result. ST-2 (c) tests this claim.
- The apply's deadline is 20 s from its entry (D-C.9), plus the landing's own budget (`lock_timeout 2 s`,
  3 attempts). Its entry is after the `advanced` commit, so a row younger than about 60 s can still have a
  live apply in window (i). The default 600 s, with the floor of 120 s, is well above that bound. The
  floor is a hard rule, not a tunable.
- The sweeper never changes `service_task_dispatches.status` (it stays `"advanced"`, as in D-C.8). A
  second sweep finds the key and skips the row.

**D4. Landing contents.**
- Error type: `:service_task_apply_lost` (new atom; `ExecutionError`'s `error_type()` is an open union,
  `execution_error.ex:106-114`).
- Public code (in `details["code"]` and in the audit): `dispatch_apply_lost`. Why a new code and not
  `entity_write_refused`: the sweeper has no body, no plan and no line index, and cannot know why the
  write failed. Reusing `entity_write_refused` would state a cause that is unknown.
- `affected: {:node, node_id}`; `reason: "service task dispatch apply lost: result not recorded"` (fixed
  sentence, no values).
- `variables`: the PRE-merge projection variables, as D-C.8.
- `details: %{"dispatch_id" => id, "code" => "dispatch_apply_lost"}` (no `line_index`).
- `idempotency_key: "service_task_dispatch:<id>"`.
- DLQ: the existing `:execution_error_dlq_landing` step writes one `dlq_entries` row (`dlq.ex`,
  `execution_error.ex:190`); no DLQ code is added.
- Audit: one best-effort tenant entry, action `service_task.stuck_advance_landed`, `resource_type
  "instance"`, `after_state` `%{"node_id", "dispatch_id", "code" => "dispatch_apply_lost"}` (no values).
  Written after the landing transaction returns, like `record_service_task_advance_failure_audit/5`
  (`engine.ex:8620`), not inside it (ISS-0784 rollback note). The action name is new; `entity_write.refused`
  is not reused, because it carries a line index and a closed detail atom the sweeper does not have.
- Nothing secret or value-bearing is written. No response body is in the row or in any landing input (the
  body was never persisted; REQ-499 PR-C design, section 16).

**D5. Entity-write class (scope), exact predicate.** An instance's node is in the class when its pinned
graph node (`SnapshotStore.get_by_instance_id/2`, `lib/letflow/definitions/snapshot_store.ex:139`, then
the node with the dispatch's `node_id`) satisfies `declared_writes(attributes) != {:ok, [], []}`, the SAME
predicate the plan uses at `engine.ex:3195` (`plan_entity_writes/3`). `declared_writes/1` (`engine.ex:3209`,
private) is reused, not a second predicate. Consequences, all deliberate:
- `entity_writes` or `module_writes` non-empty: in class;
- a malformed (non-list) attribute: `{:malformed, _}` is `!= {:ok, [], []}`, so IN class. This matches the
  plan, which refuses it fail-closed (`engine.ex:3207-3235`), so the landing answers the stall the plan would
  have refused;
- neither attribute, or both `[]`: out of class (`:other_class`).

The class helper is exposed for the sweep as `@doc false def stuck_entity_write_class?(instance_id, node_id,
prefix)` in `Letflow.Engine`, next to `declared_writes/1`, so the sweep module never calls a private
function. It returns `:in_class | :other_class | :unreadable`. A missing snapshot or a missing node returns
`:unreadable`, which is treated as out of class (fail closed: no write without a proven class).

Known residual, stated: a node that has lines can also stall for another ISS-0928 reason (`transition_failed`,
`unknown_token_id`, ...). The sweeper cannot tell those apart, so such a row is landed too. Its outcome is
loud (ERROR + DLQ), better than a silent stall, but the code says "apply lost", not "entity write refused".
Flagged for the owner (section 9.1).

**D6. Home.** New module `Letflow.Engine.ServiceTaskDispatcher.StuckSweep` (a plain module, no process, under
`lib/letflow/engine/service_task_dispatcher/`). `ServiceTaskDispatcher.Poller.handle_info(:tick, ...)` calls
`StuckSweep.run/4` after `poll_and_dispatch/1`, once per tenant schema, and only when `now - last_sweep_at >=
stuck_advance_sweep_interval_ms`. The Poller state (`init/1` at `poller.ex:54`; the `%{last_tick_started_at:
nil}` state at `:50`) gains two fields: `last_sweep_at` (nil at start) and `stuck_cursors` (a map of tenant
schema to cursor, default `%{}`). `run/4` takes the tenant schema, the cursor, the sweep deadline and the mode,
and returns `{summary, next_cursor}`; the Poller stores `next_cursor`. The landing function lives in
`Letflow.Engine` next to `http_landing_multi/4`, because it uses the private lock helpers there
(`fetch_and_lock_service_task_dispatch/3`, `fetch_and_lock_instance_projection/3`,
`service_completion_key_present?/3`, `set_service_entity_write_timeouts/1`). Public entry:
`Letflow.Engine.land_stuck_service_dispatch(dispatch_id, prefix)` (D3 return values). No new supervised child,
so `Letflow.Supervisor.Pollers` (`lib/letflow/supervisor/pollers.ex`) and its boot gates are not touched. The
existing `:start_service_task_dispatcher` gate (false in `config/test.exs:73`) also turns the sweep off in tests.

**D7. Tenant iteration (INV-1).** Same as the Poller: `Registration` rows with `migrations_applied_at IS NOT
NULL` (`poller.ex` `tenant_schemas/0`), one prefix per call. Every query in the sweep uses `prefix:
tenant_schema`; no query runs without a prefix, and no cross-tenant join exists. A failing tenant does not stop
the others: each tenant call is wrapped in the `rescue` pattern of `fetch_tenant_schemas/0`. The cross-tenant
negative test is ST-7 (section 6).

**D8. Bounds (per tenant and per sweep).**
- Per tenant per sweep: at most `stuck_advance_scan_limit` rows scanned and at most `stuck_advance_batch_size`
  in-class landing attempts (D1, D2).
- Per sweep across all tenants: a wall-clock budget `stuck_advance_sweep_budget_ms` (default 1000 ms). It is
  checked before each page and before each candidate landing. When it is spent, the walk stops; the cursors of
  the tenants reached so far are kept, and the next sweep resumes them. Tenants not reached this sweep keep
  their cursors. Worst case for one sweep: the budget plus one candidate's lock wait (2 s) plus one statement,
  about 3 s, once per `stuck_advance_sweep_interval_ms`. The total does not grow with the tenant count. This is
  the total cap the gate asked for.
- Each candidate is its own transaction. Lock wait 2 s and statement timeout as
  `set_service_entity_write_timeouts/1`. A contention error skips the candidate (classified tag `contention`,
  no audit). No retry loop inside a sweep. Nothing is held between candidates.

**D9. Logging.** Log content is dispatch id, tenant schema and a classified atom only, the same rule as
`call_advance_after_service_task_outcome/3` (`service_task_dispatcher.ex:631-648`). No `inspect(reason)`. Shadow
logs `stuck_advance candidate` with dispatch id and tenant, plus the classified skips (`:other_class`,
`:unreadable`, `:no_timestamp`).

**D10. Modes.**
- `:off`: `run/4` returns `:skipped` before any query.
- `:shadow`: walks the cursor, runs the selection and the class check, logs candidates, performs no write and no
  audit. Read-only.
- `:on`: lands each in-class candidate.

**D11. Index (the cost of the selection query).** `advanced` rows are never removed, so the walk reads the oldest
rows of a table that grows with every successful HTTP dispatch. The only index on `service_task_dispatches` is the
partial index on `pending`/`next_attempt_at` (migration `20260902010001`). A full scan per page is not accepted.
Build B2 adds a tenant-scoped migration `CREATE INDEX ... ON service_task_dispatches (dispatched_at, id) WHERE status
= 'advanced'`. It is guarded with `if prefix()` and registered in `Letflow.TenantProvisioning.@tenant_scoped_migration_manifest`
(both halves are mandatory, as in `20260902010001`). Auto-CD deploys it to QA; the migration is additive (no data
change). It is written as a plain index like its predecessor.

## 4. Files

| file | change | build |
|---|---|---|
| `lib/letflow/design/gh2688-req513-stuck-advance-sweeper.md` | this record | this slice |
| `lib/letflow/engine.ex` | public `land_stuck_service_dispatch/2` next to `http_landing_multi/4` (`:6448`); private `stuck_landing_multi/3` (shape of `http_landing_multi/4`, different error args, D4); `@doc false` `stuck_entity_write_class?/3` next to `declared_writes/1` (`:3209`); audit helper `record_stuck_advance_landed_audit/…` next to `record_service_task_advance_failure_audit/5` (`:8620`) | B1 |
| `test/letflow/engine/service_task_stuck_landing_test.exs` | new: ST-1 (landing part), ST-2 (a)/(b)/(c), ST-3, ST-7 (landing return value) | B1 |
| `lib/letflow/engine/service_task_dispatcher/stuck_sweep.ex` | new: keyset walk (D1), budget (D8), modes (D10), logging (D9) | B2 |
| `lib/letflow/engine/service_task_dispatcher/poller.ex` | state gains `last_sweep_at` and `stuck_cursors`; `handle_info(:tick)` calls `StuckSweep.run/4` per schema when the interval has passed | B2 |
| `lib/letflow/engine/service_task_dispatcher.ex` | accessors `stuck_advance_mode/0`, `stuck_advance_min_age_seconds/0` (floored at 120), `stuck_advance_sweep_interval_ms/0`, `stuck_advance_batch_size/0`, `stuck_advance_scan_page_size/0`, `stuck_advance_scan_limit/0`, `stuck_advance_sweep_budget_ms/0` (same shape as `:251-276`) | B2 |
| `priv/repo/migrations/<ts>_add_stuck_advance_index.exs` | tenant-scoped index (D11) | B2 |
| `lib/letflow/tenant_provisioning.ex` | one entry in `@tenant_scoped_migration_manifest` for the index migration | B2 |
| `test/letflow/engine/service_task_stuck_sweep_test.exs` | new: ST-1 (sweep part), ST-4, ST-5, ST-6, ST-6b (starvation), ST-7 (sweep part) | B2 |
| `docs/runbooks/service-task-entity-write-refusal.md` | "Known residual" rewritten: the sweeper, its mode, scope ruling (D5), `dispatch_apply_lost`, the D5 residual | B2 |
| `lib/letflow/design/gh2587-req499-pr-c-service-task-writes.md` | section 16 entry for the sweeper marked delivered by REQ-513 (one line) | B2 |
| `docs/requirements.yaml` | NOT touched (no status flip; the team's rule) | none |

Response shaping and `Letflow.Api` are unchanged; the sweeper has no HTTP surface. `entity_write.refused` and the
existing landing are unchanged. No change to any existing public signature.

## 5. Data and API

- Reads: `service_task_dispatches`, `instance_projections`, `event_idempotency`, the instance snapshot
  (`SnapshotStore`), `registrations`. Writes (mode `:on` only): the ExecutionError event, its `dlq_entries` row, the
  instance projection (ERROR), one audit row.
- New public: `Letflow.Engine.land_stuck_service_dispatch(dispatch_id :: Ecto.UUID.t(), prefix :: String.t()) ::
  {:ok, :landed | :already_final | :instance_moved_on | :not_in_class | :too_young} | {:error, :not_found | :contention}`.
- New `@doc false` public: `Letflow.Engine.stuck_entity_write_class?/3` (`:in_class | :other_class | :unreadable`).
- New public: `Letflow.Engine.ServiceTaskDispatcher.StuckSweep.run(tenant_schema, now, cursor, mode)` returning
  `{%{tenant_schema, scanned, candidates, landed, already_final, skipped, reason_counts}, next_cursor}`; the sweep
  deadline is read from the config accessor at entry.
- Poller state gains two keys. Its state map is private to the Poller and read only by its own `handle_info`.
  Build-time grep to confirm: `grep -rn "last_tick_started_at" test lib` (on `main` only `poller.ex` uses it).
- Callers of `declared_writes/1` on `main` (the new helper adds no signature change): `grep -n "declared_writes(" lib/letflow/engine.ex` gives `:3195, :3209, :5804, :5930`.

## 6. Tests (the issue's four, plus the gate's starvation test and three more)

Two test files, `async: false`, Ecto sandbox, fixtures from the service-task fixtures used by
`service_task_entity_writes_test.exs`. Each stuck row is seeded with `dispatched_at` older than the configured
minimum age (set with `Application.put_env` in `setup`, restored on exit), an ACTIVE projection, and a node with
one `entity_writes` line unless the test says otherwise.

- **ST-1 (exactly once when the sweeper runs twice).** Seed one stuck row. Run the sweep twice with mode `:on`,
  carrying the cursor forward. Assert: one ERROR projection, one `service_task_dispatch:<id>` key, one `dlq_entries`
  row, one `service_task.stuck_advance_landed` audit row, dispatch row still `"advanced"`. The second run lands
  nothing: the key is present, so the row is not selected (`candidates: 0` for it) and nothing is written.
- **ST-2 (late applier racing the sweeper gives one landing).** Orders, all asserted:
  (a) the landing commits first, then `advance_after_service_task_outcome/4` runs with the same id: it returns
  `{:ok, :already_final}` (D-C.10 key read) and writes no second event;
  (b) the apply's completion commits first (key present), then `land_stuck_service_dispatch/2` returns
  `{:ok, :already_final}` and writes no ERROR and no DLQ row;
  (c) window (ii) of D3: a rolled-back apply, then the landing, then the D-C.8 landing answers `already_final`:
  exactly one ERROR event, whose code is `dispatch_apply_lost`.
  A forced concurrent interleaving (a `Task.async` apply against a landing, with a pause between the dispatch
  lock and the key read) is attempted only if `:engine_test_seams` (D-C.9) has a pause point there. If it has
  none, the race is NOT forced: the test covers (a), (b) and (c), and the race is argued from the lock order (D3).
  Section 8 states this.
- **ST-3 (instance moved on leaves the row untouched).** Two variants: the instance cancelled (projection
  `:cancelled`; the cancel path has already set `pending` rows `given_up`, and the `advanced` row stays), and the
  instance already ERROR. Assert: `land_stuck_service_dispatch/2` returns `{:ok, :instance_moved_on}`, no event, no
  DLQ row, no audit, projection status unchanged, dispatch row unchanged.
- **ST-4 (young row is untouched).** A row with `dispatched_at` within the minimum age, and one at exactly
  `now - min_age + 1 s`: not selected, nothing written, `candidates: 0`. Also the floor: setting
  `stuck_advance_min_age_seconds: 10` gives an effective age of 120 s, so a row 60 s old is not selected.
- **ST-5 (modes).** `:off`: `run/4` returns `:skipped` and a telemetry handler counts zero reads of
  `service_task_dispatches`. `:shadow`: candidate logged, zero writes (row, projection, events, DLQ, audit unchanged),
  cursor advances.
- **ST-6 (out-of-class row is never landed).** A stuck row whose node has no `entity_writes` and no `module_writes`:
  not landed, reported as `skipped` with `:other_class`, zero writes. A second variant: a malformed `entity_writes`
  (a string) IS landed as in class, which pins the D5 rule.
- **ST-6b (starvation, the design_gate finding).** Seed 21 OLDER out-of-class stuck rows (batch size + 1) and one
  NEWER in-class stuck row. Set `stuck_advance_scan_page_size: 5` and `stuck_advance_scan_limit: 10`. Run sweeps,
  carrying the cursor, for at most `ceil(22 / 10) = 3` sweeps. Assert: the in-class row is ERROR within those sweeps,
  exactly once, and the 21 out-of-class rows are unchanged. A second variant with the defaults (page 100, limit
  1000) lands it in the first sweep.
- **ST-7 (tenant isolation, INV-1).** Two tenant schemas, a stuck row in tenant A. `run(tenant_b, ...)` returns
  `candidates: 0` and does not change tenant A's row, projection or event store; `run(tenant_a, ...)` lands it. Also
  `land_stuck_service_dispatch(id_from_a, tenant_b)` returns `{:error, :not_found}`, the same tuple as
  `land_stuck_service_dispatch(Ecto.UUID.generate(), tenant_b)` (an unknown id), with no write. The two are asserted
  equal.

ST-1 (landing part), ST-2, ST-3 and ST-7 (landing part) live in `service_task_stuck_landing_test.exs` (B1); the
rest in `service_task_stuck_sweep_test.exs` (B2). Test IDs are checked against this list at build time with
`grep -n "ST-[0-9]" test/letflow/engine/service_task_stuck_*_test.exs`.

## 7. Edge cases

- `dispatched_at` NULL on an `advanced` row (should not occur; `terminal_changeset/2` requires it): not selected by
  the SQL (`IS NOT NULL`), logged in shadow as `:no_timestamp`.
- Snapshot or graph node missing: `:unreadable` (D5), skipped, no write.
- Contention or a deadlock with a concurrent cancel: skipped and retried on the next cycle (D1, D8).
- Two sweepers (a second node in a multi-node deploy): both run the same landing; the dispatch row lock serialises
  them and the second sees the key. ST-1 covers the single-process case.
- Cursor after a restart: `nil`, so the walk restarts at the oldest row. Safe: landed rows are excluded by the key.
- Upgrade: rows stuck before the deploy are landed by the first `:on` sweep. The deploy default is `:off`, so nothing
  lands until the owner or operator switches the mode.

## 8. Not forced by tests (stated)

- The exact interleaving of ST-2 needs a pause between the lock and the key read. The `:engine_test_seams` flag exists
  (D-C.9) but has not been checked for a pause point at this lock. The build confirms this; if none exists, ST-2 covers
  orders (a), (b), (c) and argues the race from the lock order.
- `:shadow` is read-only by construction; the test asserts no writes but cannot prove the absence of other side effects
  beyond the query log.
- The starvation bound (D1) is proven by ST-6b for the stated page and limit values, not for every distribution of stuck
  rows. With `N` old out-of-class rows, an in-class row can take up to `ceil(N / scan_limit)` sweeps to be reached; the
  cycle length is the price of the bound.

## 9. Owner rulings needed (not blocking the build of the chosen scope)

1. **Scope of the sweeper (D5).** Chosen: entity-write class only, the lines predicate of the plan. The residual (a
   lines node that stalls for another reason is landed as `dispatch_apply_lost`) is stated, not avoided. Options: (a)
   accept the residual; (b) land all `advanced` stuck rows (changes all ISS-0928 classes, needs its own ruling); (c)
   record the failing class on the row at apply time (a migration; out of this slice).
2. **Min age default (600 s).** Chosen for operator slack; the hard floor is 120 s.

## 10. Out of scope (deliberately)

- The other ISS-0928 classes (`transition_failed`, `variable_merge_rejected`, `unknown_token_id`, `event_append_failed`,
  `invalid_form_schema`): unchanged; their stall stays until the owner rules (9.1).
- The script route (no window, D1).
- Persisting the response body for a re-apply from the DLQ (REQ-499 PR-C section 16, separate item).
- A `needs_reactivation` path (REQ-515). The per-record size cap (REQ-514).
- Any change to `docs/requirements.yaml` status, run history, or the issue.

## 11. Verification of the claims (grep and read, on `main` at `b7ada7eba`)

- Advanced commit and `dispatched_at`: `service_task_dispatcher.ex:1231-1235` (`handle_success/3`).
- No re-claim of `advanced`: `claim_due_dispatch_ids/2` filters `d.status == :pending` (`:420-455`).
- Existing landing and its lock order: `engine.ex:6448-6488` (`http_landing_multi/4`: dispatch lock, projection lock,
  `service_completion_key_present?`, `ExecutionError.append_multi`).
- Lock helpers: `fetch_and_lock_service_task_dispatch/3` (`engine.ex:5132`), `fetch_and_lock_instance_projection/3`
  (`:3842`), `service_completion_key_present?/3` (`:6351`).
- Completion key: `grep -n "service_task_dispatch:" lib/letflow/engine.ex` gives `:5061, :5114, :5175, :6449`.
- Graph source: `fetch_graph_with_raw/2` (`engine.ex:3899`) reads `SnapshotStore.get_by_instance_id/2`.
- The class predicate and its plan use: `grep -n "declared_writes(" lib/letflow/engine.ex` gives `:3195, :3209, :5804,
  :5930`; the plan refuses `{:malformed, _}` (`engine.ex:3207-3235`).
- Error type is open: `execution_error.ex:106-114`. Audit helper pattern: `engine.ex:8620`.
- Tenant iteration: `poller.ex` `tenant_schemas/0`, `fetch_tenant_schemas/0`. Poller state: `poller.ex:46-73`.
- Index: the only `service_task_dispatches` index is migration `20260902010001` (partial, pending). Build-time check:
  `grep -rn "dispatched_at" priv/repo/migrations` must show no index on `dispatched_at` before B2 adds one.
- Flag: `config/test.exs:73` sets `start_service_task_dispatcher: false`.
- Names not yet used: `grep -rn "StuckSweep\|stuck_advance\|dispatch_apply_lost" lib test docs` returns no match on `main`.
- Delivery check: `git log origin/main --grep "2688"` and `--grep "REQ-513"` return only the register commit `570e051db`
  (requirement registration), no delivery.

## 12. Build split (recommendation)

Two PRs, serial, each a few hundred lines. **B1** the landing (`land_stuck_service_dispatch/2`, the
`stuck_entity_write_class?/3` helper, error type, code, audit, and the landing tests ST-1 (landing part), ST-2 (a)/(b)/(c),
ST-3, ST-7 (landing part)). B1 has no migration and is safe to merge with the mode unused. **B2** the sweep module, Poller
hook and cursors, config keys, the index migration with its manifest entry, the modes, ST-4, ST-5, ST-6, ST-6b, ST-7 (sweep
part), the runbook text and the section-16 line.
