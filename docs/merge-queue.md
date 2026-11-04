# Merge queue on tvolodi-org/letflow

The repository moved to `tvolodi-org/letflow` on 2026-10-14 (T-0165). The old
`tvolodi/letflow` name redirects.

`main` is governed by the ruleset `main-queue` with a merge queue:

- merge method: squash;
- no bypass actors: direct pushes to `main` are refused for everyone;
- required checks: `Backend gate (mix letflow.check)` and `Frontend gate (npm run check)`.

## How to land a change

1. Open a pull request against `main` and wait for the required checks to pass.
2. Enqueue it: use "Merge when ready" in the pull request UI, or the GraphQL
   mutation `enqueuePullRequest`.
3. GitHub runs the same checks on a temporary `gh-readonly-queue/main/...` branch
   and squash-merges the pull request when they pass.

## Emergency

If the queue itself is broken, a repository admin can disable the ruleset
temporarily. See the infrastructure runbook for the procedure.

## Selective backend tests (T-1297, item L-24)

A pull-request, merge-group or push run executes only the backend test files related to the
change; the whole suite runs on sensitive changes, every 10th merge and nightly. The required
check names (`Backend gate (mix letflow.check)`, `Frontend gate (npm run check)`), the 8-shard
matrix and the docs-only rule are unchanged; the run summary prints `Backend tests: selective|full`
and the reason.

- **Selection**: `scripts/ci_select_tests.py` (job `changes`, step "Select backend tests"). It maps
  changed lib files to tests through a textual module-reference graph (dependents of the file and
  their dependents), source-scanning tests by file name, and tests that scan all of `lib/`.
  The plan is split over the shards with the manifest weights (`test/shard_manifest.txt`); shards
  with nothing to do report success without work. `scripts/test_parallel.sh` reads the plan from
  `TEST_PARALLEL_PLAN`.
- **Full suite** when: a sensitive path changes (migrations, `priv/`, `config/`, `mix.exs`,
  `mix.lock`, `test/support`, `.github/`, `scripts/`, the shard manifest, permission, ledger,
  event-store and storage code), more than 40 files change, the lib closure is over 300 files or
  the selection covers over 55% of the tests, a lib file is removed, the selection errors, the
  repository variable `CI_SELECTIVE` is `off` (kill switch), the event is the nightly schedule or
  `workflow_dispatch`, or 10 or more commits came in since the last green full run.
- **Counter** (no database): the tag `ci-full-green` points at the last main commit whose full
  backend run was green; job `full_run_marker` moves it forward after a green full run on main
  (push, nightly, dispatch). The runs count `git rev-list --count ci-full-green..HEAD`; a missing
  or non-ancestor tag counts as unknown and runs everything.
- **Red main**: a failing backend run on main sets the tag `ci-main-red`. Merge-group runs then
  fail fast with "main full CI red" until a fix lands. A queue entry whose commit subject starts
  with `fix` (or carries `[main-fix]`) runs the full suite and may land; the next green run of a
  descendant commit deletes the tag. Operator escape: `git push origin :refs/tags/ci-main-red`.
- **Accepted risk**: two modules can break each other and stay hidden until the next full run
  (at most 10 merges). Not visible to the map: Postgres triggers, migrations, pins, config-selected
  modules, docs checks, hence the sensitive list and the periodic full run.
