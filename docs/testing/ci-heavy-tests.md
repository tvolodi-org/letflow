# CI: exam and :slow tests run only when relevant (T-1139)

The heavy backend test files are the exam tests (`modules/exam` directories and test files with
`exam` in the path) and every file with `@moduletag :slow`. `scripts/ci_heavy_paths.sh files`
lists them.

**Pull request and merge queue.** The `changes` job step "Decide whether heavy tests run" runs
`scripts/ci_heavy_paths.sh` on the changed files. It answers `heavy=true` when the change touches
exam code (`lib/letflow/modules/exam/`), `test/support/`, migrations, `config/`, mix files,
`.tool-versions`, the test runner, the shard manifest, the CI workflows, or a heavy test file itself.
Otherwise `heavy=false`: the shard legs set `TEST_PARALLEL_SKIP_HEAVY=1`, `scripts/test_parallel.sh`
drops the heavy files from every partition and logs `skipped by path`, and the run summary says so.
The required checks (`Backend gate (mix letflow.check)`, `Frontend gate (npm run check)`) keep their
names and report success. Non-exam code still runs all other tests.

**Full suite.** Push to `main`, the nightly `schedule` (01:17 UTC, on main), and `workflow_dispatch`
always run everything. A failed nightly run is a red run of the `CI` workflow on main. Run
`workflow_dispatch` on main at every phase gate. Any failure of path detection also runs everything.
