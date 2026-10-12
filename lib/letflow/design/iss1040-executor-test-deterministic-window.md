# ISS-1040 design: deterministic in-flight-child window in executor_test.exs

Run: WF03-ISS1040-20261012, step 02. Issue: `docs/issues/ISS-1040.yaml` (Q-1040 / GH #2379).
Scope: TEST-ONLY. One file changes: `test/letflow/engine/lua/executor_test.exs`.
Owner of the change: TEST-DESIGNER / ELIXIR-DEV (test file only). No `lib/` change.

## 1. Problem (restated, verified against the sources)

Two tests, both `@tag :lua_wallclock_race`, observe the supervised Lua child of
`Letflow.Engine.Lua.TaskSupervisor` while a `while true do end` script is in flight:

- T-A: "AC-5: the running script is a child of Letflow.Engine.Lua.TaskSupervisor while in flight" (~L518)
- T-B: "a nil max_heap_words leaves the REQ-155 TaskSupervisor-based path unchanged" (~L817)

Each calls `execute_with_manifest/3` inside `Task.async` with `timeout_ms: 300`, waits for
`:started`, then polls `Task.Supervisor.children/1` (`Enum.reduce_while(1..20)`,
`Process.sleep(10)`, ~200 ms). The child exists only between `async_nolink`
(`lib/letflow/engine/lua/executor.ex:367`) and the caller's own `Task.yield(300)` expiry plus
`Task.shutdown(:brutal_kill)` (`handle_yield_result(nil, ...)`). Both ends of the overlap are
wall-clock, so host load can close the window before the test looks, or delay the spawn past all
20 polls. Secondary weakness: the lookup is global, so under `async: true` another test's child
satisfies `children != []` (false pass).

## 2. Design: replace the poll in both tests (acceptance criterion 1)

### 2.1 Mechanism

For each of T-A and T-B:

1. Raise THIS call's own `timeout_ms` from 300 to a large per-call value (`30_000`). The script's
   life is then bounded by the test, not by a 300 ms timer. No global config is touched
   (`:lua_wallclock_timeout_ms` is not read here; `timeout_ms` is passed per call).
2. Keep `Task.async` + `send(test_pid, :started)` + `assert_receive :started, 1_000` unchanged
   (the `task.pid` is the caller of `execute_with_manifest/3`).
3. Replace the fixed 20x10 ms loop with a call to a shared private helper that locates the
   test's OWN child (section 2.2), bounded by a monotonic deadline of 5_000 ms.
4. Assert the helper returned a pid (not `nil`), keeping each test's existing failure message.
5. Release the script deterministically: `Process.exit(child, :kill)`.
6. Assert the exact return of the awaited task:
   `{:error, "Letflow.Engine.Lua.Executor task crashed: :killed"}`
   (the `handle_yield_result({:exit, reason}, ...)` clause with `format_exit_reason(:killed)`;
   observed in ISSUE-FIXER's probe), with `Task.await(task, 5_000)`.
   The earlier assertion `{:error, {:wallclock_timeout, 300}}` is dropped: that value is already
   covered by the REQ-155 tests AC-1..AC-4 and the other `:lua_wallclock_race` tests; asserting it
   here would re-introduce the dependency on the 300 ms timer.

### 2.2 Shared private helper

One private function in the test module (both tests live in `Letflow.Engine.Lua.ExecutorTest`,
in different `describe` blocks, so it sits at module scope):

    await_own_child(caller_pid :: pid(), deadline_ms :: pos_integer()) :: pid() | nil

Contract:
- Input: `caller_pid` = `task.pid` of the `Task.async` that invoked `execute_with_manifest/3`;
  `deadline_ms` = 5_000.
- Computes the deadline once from `System.monotonic_time(:millisecond)`, then loops: enumerate
  `Task.Supervisor.children(Letflow.Engine.Lua.TaskSupervisor)`, return the first pid whose
  `Process.info(pid, :dictionary)` dictionary has a `:"$callers"` entry containing `caller_pid`.
  `Process.info/2` may return `nil` for a pid that died between enumeration and inspection;
  that is "no match", not an error. If no match and the clock is before the deadline,
  `Process.sleep(5)` and retry; at/after the deadline return `nil`.
- Terminates on first match; only a missing child ever waits out the deadline.
- Matching on `$callers` (recorded by `Task.Supervisor.async_nolink/2`) proves THIS call's child
  exists. ISSUE-FIXER's probe confirmed it returns the right pid.

The helper stays private to the test file (one consumer file, two callers).

### 2.3 Why no Lua-level handshake

A script-blocks-on-message handshake needs a host hook (capabilities `[]` exposes no `send`) and
therefore a `lib/` change. Kill-on-observation gives the same determinism: the script cannot end
before the test looks, because only the test (kill) or the 30 s ceiling ends it.

## 3. Mutation proof (acceptance criterion 2)

Mutant M1, in `lib/letflow/engine/lua/executor.ex` at the `nil` max_heap_words arm (L367):
replace `Task.Supervisor.async_nolink(Letflow.Engine.Lua.TaskSupervisor, <fun>)` with
`Task.async(<same fun>)`, so the child is never under the named supervisor.

Both tests use `max_heap_words: nil`, so both traverse this single arm; one mutant covers both.
Expected: `await_own_child/2` returns `nil` at the 5 s deadline and the "child found" assertion
fails in BOTH T-A and T-B (two failures, ~5 s each). Failure is by assertion, not by hang: the
test process exits and the linked unsupervised task dies with it.

Application by TEST-DESIGN-VALIDATOR in a throwaway worktree (never on the branch):
1. `git worktree add <scratch dir outside repo>/iss1040-mutant HEAD`.
2. In that worktree apply M1 to `lib/letflow/engine/lua/executor.ex` only.
3. Run `mix test --only lua_wallclock_race test/letflow/engine/lua/executor_test.exs` there.
4. Require: exactly the two target tests fail; any other failure among the 11 is reported.
5. `git worktree remove --force` the throwaway tree; confirm the branch's `git status` is clean.
Control: the same command on the unmutated fix must pass all 11.

## 4. 100-run stress (acceptance criterion 3)

Fact shaping the command: ExUnit runs tests inside ONE module serially; `--max-cases` only
parallelises across modules. The file is a single module, so `--max-cases` on `executor_test.exs`
alone adds no load. Concurrency must come from sibling async modules, so the stress target is the
whole Lua test directory with the tag included:

    for i in $(seq 1 100); do
      mix test --include lua_wallclock_race test/letflow/engine/lua --max-cases 32 --seed "$i" \
        || { echo "FAIL on seed $i"; exit 1; }
    done

Executed through the machine mutex wrapper (one BEAM at a time): the whole loop runs under the
wrapper. Environment: `MIX_ENV=test`, default `TEST_POOL_SIZE`.

"Green" means: all 100 iterations exit 0 with 0 failures; the two target tests are actually run
(not excluded) - confirm via the first and last iteration's output; the evidence quoted is the
exact command, the count 100/100, and the final exit code.

Supplementary (run once): `mix test --only lua_wallclock_race test/letflow/engine/lua/executor_test.exs`
must report exactly 11 tests, 0 failures.

## 5. Invariants

- Same two test names verbatim; the same single `@tag :lua_wallclock_race` on each; no tag added
  or removed. The file keeps exactly 11 `:lua_wallclock_race` AST nodes and the isolated
  partition reports 11 tests (property tests at ~L1450 and ~L1541 stay unchanged).
- No `lib/` change. No `config/` change. No global timing change (`timeout_ms: 30_000` is a
  per-call option of these two tests only).
- `use ExUnit.Case, async: true` (L11) unchanged; the helper needs no change to it.
- The async-true global-supervisor false-positive class is closed: a sibling module's child has a
  different `$callers` entry and cannot satisfy the lookup.
- No sleep determines the outcome: the only sleep is a 5 ms retry interval inside a 5 s monotonic
  deadline.
- Happy path is bounded by spawn latency (faster than the old 300 ms wait); a failing run costs
  at most ~5 s per test.
- The existing "ISS-0426 design 2.2" comments stay; add a one-line ISS-1040 note.

## 6. Open questions (explicit; none block the build)

1. OQ-1: The "machine mutex wrapper" is not documented in the repo (no match under
   `docs/agents`, `scripts`, `CLAUDE.md`). The executor of section 4 uses whichever wrapper ORCH
   names; this design does not invent one.
2. OQ-2: Whether the whole `test/letflow/engine/lua` directory is a suitable stress surface (it
   may include DB-touching modules needing a larger `TEST_POOL_SIZE`). The implementer records
   the value used. Fallback: run the single-file partition command 100 times alongside a
   separate CPU-burner process for load.
3. OQ-3: The crash string `"Letflow.Engine.Lua.Executor task crashed: :killed"` is taken from
   ISSUE-FIXER's probe, not re-derived (no mix runs in this step). The implementer confirms it on
   the first local run; if it differs, assert the observed string and report it, never loosen to
   a bare `{:error, _}`.
4. OQ-4: The 30_000 ms per-call timeout and 5_000 ms deadline are chosen constants (large against
   spawn latency, small against ExUnit's 60 s per-test timeout); no empirical tuning.
5. OQ-5: `Process.exit(child, :kill)` on a supervisor-owned `:temporary` child should be an
   ordinary child exit with no restart; not run in this step, confirm during implementation.
