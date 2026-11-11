# CI cut rank 1, proof first: what the "isolated tails" step holds

Task A of `docs/uat/ba-decisions/T-1665.md` item 6 (T-1671). It answers one question from
`docs/status/ci-minutes-after-batch4.md` ("Remaining cuts, ranked", rank 1): the baseline said the register checks run
in the job "Backend static checks + isolated tails", so is it safe to skip the step "Run isolated tails" on selective
runs? This note changes no workflow, no required check name and no test. Task B decides from it.

## 1. What the step "Run isolated tails" holds

Step (`.github/workflows/ci.yml`, job `backend_static`): `mix letflow.check.test --tails-only`, condition
`needs.changes.outputs.backend != 'false'`. In `lib/mix/tasks/letflow.check.test.ex`, `run/1` with `tails_only?` calls
exactly two functions and nothing else:

| Check | What runs | Where it is excluded from the normal suite |
|---|---|---|
| `run_wasm_hang_tests/0` | `mix test --only wasm_hang` (first a dry-run listing, then each test in its own subprocess) | `test/test_helper.exs`, `ExUnit.start(exclude: [... :wasm_hang ...])` |
| `run_lua_wallclock_race_tests/0` | `mix test --only lua_wallclock_race` | same `exclude:` list, `:lua_wallclock_race` |

Files carrying these tags (`grep -rln "wasm_hang\|lua_wallclock_race" test --include=*.exs`):
`test/letflow/engine/lua/executor_test.exs`, `test/letflow/engine/wasm/plugin_handler_test.exs`,
`host_api_write_test.exs`, `call_timeout_test.exs`, `invocation_lease_test.exs`, and
`test/letflow/scripts/form_validation_run_test.exs`.

**The tails hold no register check.** They are ExUnit tests of the Lua and WASM runtimes only. The tags are excluded
from every shard directly (`--shard K/M` runs `run_main_suite` only), so the tails step is the only *direct* run of the
`wasm_hang` tests and of the `lua_wallclock_race` tests in `form_validation_run_test.exs`. One indirect run exists: the
untagged test "the isolated --only lua_wallclock_race partition runs and passes exactly 11 tests"
(`test/letflow/engine/lua/executor_test.exs`, shard 32 in `test/shard_manifest.txt`) launches
`mix test --only lua_wallclock_race test/letflow/engine/lua/executor_test.exs` through `Letflow.Test.NestedMix.cmd`.
So the 11 Lua tests of `executor_test.exs` also run, nested, inside every full shard run. No such nested run exists
for the `wasm_hang` tests (grep of `test/` for `--only wasm_hang` finds only `letflow_check_test_test.exs`, which uses
a scripted runner) nor for the `lua_wallclock_race` test in `form_validation_run_test.exs`.

## 2. Where the register checks run

The register checks are the steps of `@check_static_steps` in `mix.exs`, run by the separate step
"Run static checks (mix letflow.check.static)" (`ci.yml`, job `backend_static`, same job, same condition):
`letflow.check_toolchain`, `check_requirements_registration`, `check_req_id_collision`, `check_deferral_staleness`,
`lint_handoffs`, `check_async_sandbox_reachability`, `check_issue_refs`, `check_uat_scenario_schema`,
`check_scope_node_paths_writers`, `check_role_scope_grants_writers`, `check_engine_test_seams_config`, then
`format --check-formatted`, `compile --warnings-as-errors`, `letflow.check_boundaries`. The permission matrix is a third
step of the same job ("Effective permission matrix"). None of these is inside `--tails-only`.

The `ci.yml` comments say the same: the docs-only paragraph (rule 5) and the comment above "Run docs tests" both state
that the register checks "run in `backend_static`, which is not skipped by docs_only".

## 3. Where a selective run still runs the register checks

A selective run (docs-only or path-selected) leaves the `backend_static` job running while `needs.changes.outputs.backend
!= 'false'` (job-level `if`). Inside it, the step "Run static checks" has the same condition as the tails step, so
**both run or both skip together; skipping only the tails step leaves the register checks untouched.** Verified from the
workflow text: the two steps differ only in `run:` and `env:`. A change that sets `backend=false` skips the whole job
already today, with or without a tails cut.

## 4. What this proves, and what it does not

- Proven: a `if:` on the single step "Run isolated tails" cannot stop any register check. The baseline's worry (register
  checks are in this job) is about the job, not the step.
- Not proven (it is task B's to settle, with its own proof): that the tails can be skipped *safely*. They are the only
  CI run of the `wasm_hang` tests (the four tagged files under `test/letflow/engine/wasm/`) and of the
  `lua_wallclock_race` test in `form_validation_run_test.exs`; the `executor_test.exs` Lua tests also run nested in
  shard 32 of a full run, but a selective run may not include that shard. So a skip is safe only on a run whose changed files cannot
  affect them. Docs-only runs (every file under `docs/`) satisfy that, since no tail test reads `docs/` (grep of the six
  files above for `docs/` paths is task B's first check). A path-selected run that touches `lib/letflow/engine/` or
  `lib/letflow/scripts/` must keep the tails. The nightly run on main keeps running them regardless.
- Saving unchanged from the batch-4 note: median 281 s (4.7 job-min) per selective run, step only.

## 5. Verdict for task B

Rank 1 is not blocked by the register checks. Task B may add a condition to the tails step only, using the existing
`docs_only` output (or a narrower runtime-path rule), keep the step name and both required check names, and must re-prove
that no tail test reads a path the skipped runs change. If task B cannot show that last point, it falls back to rank 4.
