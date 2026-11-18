# Standard and extended CI

Standard runs (`pull_request`, `merge_group`, push to `main`) use the bounded backend
selector described in [merge queue](../merge-queue.md#bounded-standard-ci-t-2155).
No sensitive path, large diff, kill switch, red-main fix or selector failure can opt
these events into the full suite. A failed selector fails the gate. Required check
names are unchanged.

The selector nominates tests through file/module references, explicit high-risk
families and fixed global checks, then admits them by priority into the runtime
budget. Changed heavy tests can be admitted; a selective plan is not subsequently
filtered by `TEST_PARALLEL_SKIP_HEAVY`. Files too large for the partition budget and
other overflow appear in `ci_deferred.txt` in the selection evidence artifact.

The nightly schedule (01:17 UTC on main) and `workflow_dispatch` run the entire
backend suite, including exam and `@moduletag :slow` files. They also run the full
frontend/mobile gates. Run dispatch before promotion or a phase gate. Nightly
failures return through standard CI. The nightly summary names an omitted failing
test as `selector miss` when the successful standard push plan for that exact SHA
is available, with the push base..head commit range, otherwise it states that selector
coverage is unavailable. The operator logs each miss in the defect ledger and creates
a p1 task traced to the responsible change after a lighter day. No demo or production
promotion while the last nightly is red. A green bounded push cannot clear the marker;
successful extended verification of backend, frontend and mobile is required.

The bounded selector is independent of timeout rollout. Previous job limits remain
the default until successful hosted stock-only, config-only and identity-only runs
each finish within ten minutes. Then set repository variable `CI_TIMEOUT_MINUTES=10`
to give every standard job a ten-minute execution limit; unset it for a one-step
rollback. Extended jobs explicitly use 60 minutes. Every standard run retains fixed
identity writer inventories and permission/global pins, even for a web-only change.

The first step of each long job records an absolute deadline; its long commands run through
`scripts/ci_job_deadline.py`, which stops 45 seconds early to print the job and unfinished test files before cancellation. A timeout fails
the gate without retry or rerun-to-pass: shorten/split tests or move overflow to nightly.
Manifest weights are estimates, not proof of hosted runtime. Record actual event,
selector reason, execution, queue wait, wall time and step conclusions when validating
the three rollout probes. A per-job cap does not cap dependency/queue wall time.

`scripts/ci_heavy_paths.sh` still lists heavy files for local tooling and historical
path diagnostics. Its output cannot widen a bounded standard plan into a full run.
