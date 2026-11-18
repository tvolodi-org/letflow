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

## Bounded standard CI (T-2155)

`pull_request`, `merge_group` and push to `main` always use an explicit bounded backend
test plan. Only the nightly schedule (01:17 UTC) and `workflow_dispatch` run the full
suite, including exam and slow tests. Required check names stay
`Backend gate (mix letflow.check)` and `Frontend gate (npm run check)`.

- `scripts/ci_select_tests.py` maps changed files to conventional tests, the two-hop
  module-reference graph, source scanners and tests mentioning config-selected modules.
  Module changes also nominate that module's own tests. Identity/permission changes
  nominate identity, API and scope-enforcement tests; ledger/event-store/migration
  changes nominate ledger, event-store and migration tests. Config changes nominate
  configured modules plus identity, engine and ledger coverage.
- Admission priority is fixed global pins, directly changed tests and conventional
  pairs, high-risk tests, the changed module's tests, then at most three related test
  families. The plan holds at most 160 files and 120 seconds of manifest weight per
  partition (32 partitions, four per shard). Unknown files cost 15 seconds. Overflow
  is listed in `ci_deferred.txt`, never silently changed to a full suite. These are
  estimates; runtime deadlines remain authoritative.
- Every standard run, including web/mobile/docs-only changes, reserves the permission
  golden, route inventories, install boundaries, previous-pack compatibility, ledger
  registrations and two identity writer inventories (`binding_writers_scan_test` and
  `tenant_update_changeset_removed_test`). Backend path filtering cannot skip them.
  Static checks, boundary checks
  and the production permission golden check still run in `backend_static`. A fixed
  pin that cannot fit fails selection rather than disappearing from the gate.
- Former full fallbacks (large diffs, sensitive paths, missing diff/manifest, deleted
  sources, config atoms, selection errors) use bounded safety coverage. `CI_SELECTIVE=off`
  now requests that safety coverage, not a full standard run. A selector process failure
  or malformed output fails the gate; standard shards refuse to start without a plan.
  Docs tests use the same planner and budget, with no separate long-running bypass.
  The legacy `selective-probe/` PR prefix still ignores `CI_SELECTIVE=off`; both
  ordinary and probe PRs remain bounded.
- Rollout order: bounded selection ships with the previous job limits (changes 10,
  static 30, shards 45, aggregator 15, marker 10, frontend 30, mobile 45 minutes).
  Measure successful hosted stock-only, config-only and identity-only standard runs,
  recording execution and queue times separately. Only after all three finish within
  ten minutes, set repository variable `CI_TIMEOUT_MINUTES=10`. This activates
  `timeout-minutes: 10` for **every** standard job. Unsetting the variable restores
  the rollout defaults in one step; it never enables full standard selection.
  Schedule/dispatch explicitly use 60 minutes, independently of the variable.
- The four long jobs (static, shard, frontend, mobile) record a deadline in their first step.
  Their long commands (mix, npm, flutter) run through `scripts/ci_job_deadline.py -- <command>`,
  which stops the command 45 seconds before the job limit,
  prints the job and unfinished shard files (running or pending without a partition
  `Result:`), and fails with exit 124. The reserve allows diagnostics and cleanup;
  GitHub's job timeout is the backstop, including for hung actions. Actions cancelled
  before a wrapped command cannot emit the watchdog's diagnostic. A timeout stays red:
  no retry or rerun-to-pass; shorten/split the selected tests or move overflow to nightly.
  A failed/cancelled shard makes the required backend aggregator fail. A merge-group
  failure ejects that entry and cannot write the main-only marker, so other queue
  entries are not held by its timeout. Queue wait is measured separately from job
  execution; a per-job cap does not cap total workflow wall time across dependencies.
- Successful standard push plans are retained for 14 days as
  `standard-backend-selection`. Each nightly shard compares its actual ExUnit failure
  headings with the successful standard push plan at the **same SHA**. An omitted
  failing file is reported as `selector miss` with its test name in the nightly
  summary, with the compared push's base..head commit range from `ci_range.txt`.
  Missing/expired evidence is reported as coverage unavailable, not zero
  misses. Crashes and timeouts are not classified as missed tests. The operator counts
  these findings as `selector miss` in the defect ledger and creates a p1 task traced
  to the responsible change after a lighter day; fixes return through standard CI.
- A failing backend run on main sets `ci-main-red`. The merge queue stops with
  "main full CI red" until a `fix(...)` or `[main-fix]` entry lands. Repair entries also
  use bounded high-risk coverage. Only successful schedule/dispatch verification
  (backend, frontend and mobile) of a descendant clears the marker; a green bounded
  push preserves it. A nightly failure and fix never force a full standard run.

Accepted risk: bounded coverage can miss a cross-module regression until extended CI.
No demo or production promotion is allowed while the last nightly is red. At
promotion/phase gates run `workflow_dispatch` to verify the fix with extended coverage.
