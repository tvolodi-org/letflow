# ISS-1058 / Q-1058 / GH #2406 - Pool property leaks the per-test claims map after an aborted iteration (test defect)

- Run: WF03-ISS1058-20261012, step 02 (CODE-DESIGNER). Diagnosis: `docs/issues/ISS-1058.yaml` and
  `handoffs/WF03-ISS1058-20261012/step-01-issue-fixer.json` (verdict H2, proven by instrumented run).
- Scope: ONE file changes, `test/letflow/support/tenant_fixture_pool_test.exs`. **No `lib/` change, no
  `test/support/` change** (the throwaway mutants of section 7 are never committed).
- Design only: signatures, assertion order, case lists. No implementation code.

## 0. Decision in one paragraph

The property "any set of row writers is invisible after the boundary, and never rebuilds" is correct and
the pool has no isolation hole (H2, H1 ruled out). The test is defective in two places that combine:
(a) the writer `:fk_chain` uses fixed primary keys, so a generated list with two `:fk_chain` raises 23505
inside the iteration; (b) the abort happens before the iteration's closing `recycle_pool!/0`, so the
test process's claims map keeps `{shape_a => 1}` and the next attempt (StreamData shrinking re-runs the body
in the SAME process) claims the second declared `@a` slot, then the post-recycle `fx(:a)` claims the first,
and `nonseed_rows(a.schema_name)` inspects the wrong slot. Fix: make `:fk_chain` repeatable; start every
iteration with `recycle_pool!/0`; assert the post-boundary tenant IS the schema that was written to,
before any content assertion; pin the failing sequences as deterministic fixed cases that run the SAME
assertion body as the property (extracted into one private helper). The claim is not weakened and is in
fact strengthened (section 6, 7).

## 1. Facts this design is built on (cited, re-verified in this step)

Pool side, `test/support/tenant_fixture.ex`:

- F1. `@claims_key {__MODULE__, :claims}` (L297): a per-test-process map `shape => count of claims made`.
- F2. `claim_pooled!/2` (L589-598): reads the map, takes `k = Map.get(claims, shape, 0)`, acquires slot
  `{shape, k}`, then puts `k + 1` back (L596). Slots are positional: the first `fx(:a)` of a process gets
  the first declared `@a`, the second gets the second `@a`, the third raises `ArgumentError`
  ("did not declare", L600-607).
- F3. `recycle_pool!/0` (L493-497): `Process.put(@claims_key, %{})` then `run_end_fence!/1`. It clears
  the claims and fences stragglers; it changes no data.
- F4. Reset is LAZY, at acquire: `do_acquire/2` (L1702-1720) runs fence, `prove_clean/2` (detect then
  `reset/4`), `final_guard!/3` (INV-P12). The previously written slot stays dirty (rows present) from the
  boundary until the next acquire of THAT slot; the other slot is neither touched nor reset.
- F5. `pool_dirty_report/1` (L477-485) resolves the slot by the `schema_name` it is given
  (`handle_call({:dirty_report, schema_name})`, L1392-1397); it reports only the slot of the fixture
  passed in. It is not wrong when it says "clean" for slot 1 while slot 2 holds rows.
- F6. `attach_pool!/1` (L444-469) refuses a non-empty claims map, so claims start empty in every test.

Test side, `test/letflow/support/tenant_fixture_pool_test.exs`:

- F7. `setup_all` declares `slots: [@a, @a, @b]` (L46-53). `fx(:a)` is
  `TenantFixture.provisioned_tenant!(@a)` (L98).
- F8. The property (L1402-1435) body is: `a = fx(:a)`; clean report; writes via `in_task_or_here`;
  dirty-report equality; `recycle_pool!`; `assert clean? = pool_dirty_report(fx(:a))`;
  `assert nonseed_rows(a.schema_name) == []` (L1430); `called_sequences == []`; `recycle_pool!`; after
  the check `rebuilds` unchanged. `max_runs: 12`, generators `list_of(member_of(@prop_writers),
  min_length: 1, max_length: 5)` and `member_of([:test, :task])`.
- F9. `write!(:fk_chain, s)` (L246-274) inserts `groups.id = ...0a1` and `users.id = ...0b1` as
  literals, a `group_members` row on those literals, and a `tenant_role` row; only the names/e-mails and the
  role id vary. A second call into the same schema without an intervening reset violates
  `groups_pkey` (23505).

Chain (from step 01, seeds 193355 locally and 40898 on CI run 38235738863 shard 3/3 partition 11):
writers `[:fk_chain, :fk_chain]` via `:test` -> 23505 in the iteration -> no closing recycle -> claims
`{shape_a => 1}` leaks -> shrink re-run: `fx(:a)` = slot 2, boundary clears claims, post-boundary `fx(:a)`
= slot 1 -> `nonseed_rows(a.schema_name)` reads slot 2 which still holds the writes (lazy reset, F4) ->
assertion shows `[{"groups", 1}]` while the pool's report for slot 1 is correctly clean. For seed 40898 the
shrink leaks twice and ends in the F2 `ArgumentError` for `{shape_a, 2}`.

## 2. Change 1 - repeatable `:fk_chain` writer (acceptance 3 for the root cause)

`write!(:fk_chain, schema)` keeps its contract (returns `["group_members", "groups", "tenant_role",
"users"]`, writes the same four tables, same FK shape groups <- group_members -> users, tenant_role ->
groups) but derives `group_id` and `user_id` per call from `Ecto.UUID.generate/0` (dumped to the 16-byte
form for the query parameters) instead of the literals. Names, e-mails and the role name already use
`uniq()`. The two ids are passed as parameters to all three dependent statements (no SELECT-back).

Repeatability audit of every writer in `@prop_writers` (L1389-1400) and the fixed-case users of the
fixed-PK class:

| writer | PK / unique columns | source of values | repeatable in one schema between resets |
|---|---|---|---|
| `:groups` | `id` | `gen_random_uuid()`, name `g-uniq` | yes |
| `:users` | `id`, username, email | uuid + `u-uniq` | yes |
| `:fk_chain` | `groups.id`, `users.id`, `group_members(group_id,user_id)` | **literal** `...0a1` / `...0b1` | **NO, today** -> yes after change 1 |
| `:events` | `event_id`; unique `(instance_id, sequence_number)`; idempotency_key | random uuids, `idem-uniq` | yes (instance_id is random) |
| `:process_definitions` | `id`; unique `name`, unique `(name, version)` | `pd-uniq` | yes |
| `:audit_entries` | `id` | `gen_random_uuid()` | yes |
| `:tenant_modules` | `id`, module_id | `m-uniq` | yes |
| `:correlation_cursors` | `correlation_id` | `c-uniq` | yes |
| `:definition_sequence` | `tenant_id` | `gen_random_uuid()` | yes |
| `:seq_only` | none (a `nextval`) | - | yes (writes no row) |

Fixed-case users of `write!(:fk_chain, ...)`: `mutate_everything!/2` (L409, called at L491 and L507),
M1 (L528) and M11 (L1142). Each writes it once per slot per test after an acquire that reset the slot, so
they are repeatable today and stay so; change 1 needs no edit in them, and their asserted table lists and
`dirty_tables_truncated + 4` count do not depend on the ids. The only literal-PK writer is `:fk_chain`;
no other literal id appears in `test/` or `lib/` (grep of `0000000000a1` / `0000000000b1` hits only this
file).

Rejected alternative: de-duplicating `writers` in the generator (`uniq_list_of`). It would stop the
duplicate-writer class from ever being generated, so the property would no longer claim "any multiset of
writers" - a weakening. Repeatable writers keep the generator unchanged.

## 3. Change 2 - recycle at iteration start (acceptance 2 of the task)

First statement of the check body (and of the extracted helper, section 5): `TenantFixture.recycle_pool!()`.

Why it is sound w.r.t. the claims semantics (F1-F3):

1. A claims map is a pure per-process counter used to choose a positional slot (F2). Clearing it has no
   effect on any slot's data (F3: "changes no data"), so recycling at the start never hides dirt: the
   dirty slot is reset lazily by the next acquire regardless (F4) and the property's own assertions read
   the state after that acquire.
2. It gives every attempt the same precondition the first attempt already has (F6: claims empty), so
   attempt N, a shrink re-run and the first run all claim slot 1 for `fx(:a)`. This is exactly the
   property's intended model "one boundary per iteration".
3. The end fence it also runs is the same bounded straggler wait the closing recycle runs; at the start of
   an iteration there is nothing to wait for (the previous iteration either ended with its own closing
   recycle or aborted with its Tasks already awaited/linked), so it is a no-op in the green path.
4. It does not mask the leak between iterations: the closing `recycle_pool!/0` (kept, L1431) and the
   post-boundary assertions are untouched, and the boundary under test is still "write, recycle, acquire".
   The start-recycle is outside that sequence.
5. `attached_pool!/0` (L535) requires the pool attached; the `setup` block does that for every test.

## 4. Change 3 - same-schema assertion after the boundary (acceptance 3)

After the writes and the dirty-report assertions, the helper does, in this exact order:

1. `recycle_pool!()` (the boundary under test).
2. `again = fx(:a)`.
3. `assert again.schema_name == a.schema_name` with a message naming both schema names and stating "the
   post-boundary claim attached a different slot; the claims map leaked or slots were reordered".
4. `assert %{clean?: true} = pool_dirty_report(again)`.
5. `assert nonseed_rows(a.schema_name) == []`, `assert called_sequences(a.schema_name) == []`.
6. `recycle_pool!()` (closing, kept).

Step 3 is BEFORE steps 4-5 so that if the claims map ever leaks again the failure is the precise
"different slot" assertion at the first iteration, never the misleading `[{"groups", 1}]` from a
neighbouring slot. Decision record (acceptance 3 of the issue): the assertion keeps checking
`a.schema_name` (the schema that holds the writes), not `again.schema_name`, and step 3 guarantees the two
are the same slot; asserting on `again` alone would pass vacuously on the wrong slot, which is the defect.

## 5. Shape of the test file after the fix (signatures only)

Private helper in the test module (name fixed for TEST-DESIGNER, may be adjusted by agreement):

- `assert_boundary_invisible!(writers :: [atom()], via :: :test | :task) :: :ok` - the whole former body
  of the property check, with change 2 as its first statement and change 3 in the post-boundary part.
  All former assertions are retained (clean before, dirty-table equality `report.dirty_tables ==
  touched`, `dirty_sequences == ["events_global_seq_seq"]` when `:events`/`:seq_only` present, clean after,
  `nonseed_rows == []`, `called_sequences == []`).
- `abort_attempt!() :: :ok` - simulates an aborted iteration deterministically, without the generator:
  `a = fx(:a)`; write one `:groups` row into `a.schema_name`; then insert the same explicit group id twice
  and `assert_raise Postgrex.Error` with SQLSTATE 23505. Net effect: one claim made and left in the map,
  one row left in that slot, no recycle. (A raise inside the helper itself is avoided because ExUnit would
  fail the test; the assert_raise stays inside `abort_attempt!/0`.)

The property keeps its name, `max_runs: 12`, both generators and the closing `assert rebuilds` equality;
its `check all` body becomes `assert_boundary_invisible!(writers, via)`.

## 6. Change 4 - fixed regression cases (acceptance 4)

ExUnit's `--seed` is not a property parameter (it only seeds StreamData's default random state), so the
seeds are not pinned by re-running; they are pinned by encoding the failing sequences. New
`describe "ISS-1058 claims leak after an aborted iteration"` in the same module (same `setup_all` pool,
`slots: [@a, @a, @b]`, a fresh claims map per test by F6):

- C1 `[:fk_chain, :fk_chain]` via `:test` and C1b via `:task`: `assert_boundary_invisible!/2`. This is
  the first failing sequence of seeds 193355 and 40898. Via `:task` is included because the property
  generator also yields it (open question O2 on how a task-side 23505 manifests, now unreachable).
- C2 aborted attempt then `[:groups]` via `:test`: `abort_attempt!()` once (claims `{shape_a => 1}`, a row
  left in slot 1), then `assert_boundary_invisible!([:groups], :test)`. This is the shrunk failing case
  of seed 193355 (`writers [:groups], via :test` failing after an earlier abort). Without change 2 the
  helper's `fx(:a)` claims slot 2 and change 3 fails with the "different slot" message; with it the row of
  the aborted attempt is also proven gone (slot 1 is reset at the helper's acquire).
- C3 aborted attempt twice then `[:groups]` via `:test`: `abort_attempt!()` twice (claims
  `{shape_a => 2}`, the second abort writes into slot 2), then the helper. This is the seed-40898 tail
  (`ArgumentError` for `{shape_a, 2}`): without change 2 the helper's first `fx(:a)` raises the F2
  `ArgumentError`; with it, both polluted slots are acquired and proven clean in turn (an extra
  `assert_pristine!(fx(:a))` after a second boundary is NOT added; C3 only runs the helper).
- C4 pool fact, documented not assumed: after `abort_attempt!()`, `fx(:a).schema_name` differs from the
  aborted slot's `schema_name` (the claims map is positional), and after `recycle_pool!()` `fx(:a)` is the
  first slot again. This records the F2/F3 semantics the helper relies on in a test that would break if
  the pool ever changes them, instead of in a comment.

Comment above the describe (no code): names seed 193355 (local reproduction, 56/57) and seed 40898 (CI run
38235738863, shard 3/3 partition 11), the root cause in two lines and `docs/issues/ISS-1058.yaml`.
Verification in the step-04+ handoffs: TEST-RUNNER runs the whole file with `--seed 193355` and with
`--seed 40898` (real output quoted); those runs are corroboration, the fixed cases C1-C4 are the pin.

## 7. The claim is not weakened, and a mutant proves it (acceptance 5, 6)

Unchanged: the writer set `@prop_writers`, both generators, `max_runs: 12`, every former assertion, the
final `rebuilds` equality, the pool, the support module. Added: iteration-start recycle (no data effect,
section 3), same-schema assertion (strictly stronger), repeatable `:fk_chain` (the generator can now reach
duplicate writers without aborting, so the property covers MORE writer multisets than before, not fewer).

"Not weakened" is shown by mutation, not asserted. TEST-DESIGN-VALIDATOR / TEST-RUNNER, in a throwaway
git worktree OUTSIDE the repo (never committed), with the fixed test file in place and ONE mutant applied at
a time to `test/support/tenant_fixture.ex`, runs the property and C1-C3 under seeds 193355 and 40898
(plus one random seed). Every mutant below must make the property FAIL (non-zero exit, failing assertion or
pool error quoted); the unmutated tree must PASS the same run. Record the observed failing assertion per
mutant in the handoff.

- Mutant MU1 "skip the reset of a dirty slot": in `prove_clean/2` (L1740-1759), in the
  `{:ok, diff, public, st}` branch, make the `else` arm return `{state, :clean}` instead of calling
  `reset(state, key, diff, public)`. Expected: the next acquire hands out a slot that still holds the
  iteration's rows; the property fails at the `final_guard!/3` raise (pool error surfaced through
  `fx(:a)`) or, if the guard passes, at `assert %{clean?: true} = pool_dirty_report(again)` /
  `nonseed_rows == []`. Either way FAIL; if the property PASSES under MU1 the property is blind to
  non-reset and the design is rejected.
- Mutant MU2 "reset is reported but truncates nothing": in `reset/4` (L1765-1810), replace the
  `TenantTemplate.reset_clone_schema!/3` call by a stub result `{:ok, report}` with empty
  `truncated`, `closure_added`, `sequences_restarted` and zero timings (the `extra:` public reset not run
  either). Expected: `public_clean?` passes, the slot is declared `:reset`, but rows and sequence state
  remain; FAIL at the guard or at `nonseed_rows`/`called_sequences`. This one specifically proves the
  row/sequence assertions at L1430-1431 still carry weight and are not subsumed by the pool's own report.
- Mutant MU3 "recycle does not clear claims" (extra, pins change 3): delete the
  `Process.put(@claims_key, %{})` at L495 inside `recycle_pool!/0`. Expected: C1/C2 and the property FAIL at
  the new `again.schema_name == a.schema_name` assertion (message "different slot"), at the FIRST iteration,
  not at `nonseed_rows`. This proves the assertion order of section 4 and that change 3 detects the exact
  defect class that went unnoticed.

Fail-first for the test changes themselves (acceptance 6 of the task), each in a throwaway worktree, each
reverting ONE change in the fixed test file and running C1-C3 with a fixed ExUnit seed:

- Revert change 1 only (literal PKs again): C1/C1b FAIL with 23505 `groups_pkey` on the second
  `:fk_chain` (and the property can fail the same way on some seeds).
- Revert change 2 only (no start recycle): C2 FAILS at the "different slot" assertion; C3 FAILS with the
  `ArgumentError` "asked a pooled module for slot {shape, 2}".
- Revert change 3 only (no same-schema assertion), keep 1 and 2: C1-C3 PASS (no longer reachable) - this
  is expected and stated: change 3 is a guard, its own fail-first is MU3 above, not a revert.
- All three reverted: C1, C2, C3 all FAIL; this is the current `main` behaviour reproduced deterministically.

## 8. Invariants

- INV-1058-A: every iteration of the property, and every fixed case, starts from an empty claims map
  (`recycle_pool!/0` first), so `fx(:a)` is always the first declared `@a` slot.
- INV-1058-B: the schema asserted on after the boundary is the schema written to; the same-schema
  assertion precedes every content assertion.
- INV-1058-C: no writer in `@prop_writers` fails when drawn more than once in one iteration.
- INV-1058-D: the property and the fixed cases share one assertion body (`assert_boundary_invisible!/2`),
  so they cannot drift apart.

## 9. Open questions (not silently resolved)

- O1. The helper extraction means the property's `check all` body is a single call; if TEST-DESIGN-VALIDATOR
  prefers the body inline for readability, the fixed cases must then duplicate the assertions (violates
  INV-1058-D). Recommendation: keep the helper.
- O2. A 23505 raised inside a `Task.async` (via `:task`) crashes the linked test process rather than raising
  in the body; the CI evidence only shows `:test`. After change 1 this path is unreachable for `:fk_chain`;
  C1b only asserts the green path. Whether a crash-in-task should itself be survivable is out of scope.
- O3. `abort_attempt!/0` forces the duplicate with an explicit repeated group id. If the `groups` table ever
  loses its PK the simulation silently stops raising; `assert_raise` makes that a loud failure, which is
  the intended behaviour (O3 only records the dependency).
- O4. The two seeds cannot be pinned through ExUnit; the fixed cases encode the sequences instead. If the
  project later wants a property-level seed pin, StreamData `initial_seed` handling is a separate change.
- O5. Whether to additionally document "reset is lazy, a previously written slot stays dirty until its next
  acquire" in the pool's moduledoc is NOT done here (no `test/support` change); C4 records it as a test.

## 10. Acceptance-criteria mapping

| acceptance | element |
|---|---|
| 1 root cause with seed evidence | section 1 chain, seeds 193355 and 40898 |
| 2 (H1 only) | not applicable, H1 ruled out in step 01 |
| 3 assertion checks the schema holding the writes, decision recorded | section 4 |
| 4 both seeds as fixed regression cases | section 6, C1-C3 (+C4) |
| 5 passes on failing and fresh seeds | section 6 verification note and section 7 run protocol |
| 6 claim not weakened | section 7 (unchanged list, strengthened assertion, mutants MU1-MU3) |
| task: repeatable fk_chain, audit of other writers | section 2 |
| task: iteration-start recycle, soundness with line cites | section 3 |
| task: same-schema assertion before content assertions | section 4 |
| task: fail-first for TEST-DESIGN-VALIDATOR | section 7 |
| task: no lib/ or test/support change, no implementation code | header, section 0 |
