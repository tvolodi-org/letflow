# GH #2380 criterion (c): can a per-file manifest hold "slowest shard within 10 % of the median"? 2026-10-26

Follow-up to `ci-shard-balance-2026-10-25.md` (pooled slowest / median wall +16.2 %, 9 of 33 runs within 10 %).
This note builds the manifest from CI runs that already exist and models it on the same runs. It waits for no future run.

## Data

- **Runs:** `gh run list --branch main --workflow CI --limit 70`, keeping runs created at or after 2026-10-25T01:29:31Z
  (the #3171 manifest rebuild): 67 runs, 40150826845 to 40238121211, 261 successful `Backend shard K/4` jobs
  (`gh api repos/tvolodi-org/letflow/actions/runs/<id>/jobs`).
- **Per-file times:** the job logs (`gh api repos/tvolodi-org/letflow/actions/jobs/<id>/logs`), the
  `test_parallel: partition N slowest:` module blocks (top 80 modules per partition, 62,210 module rows, 965 files).
  Files below the top 80 of their partition are not logged and count as 0 (small).
- Analysis scripts and inputs are in the task folder (`factor.awk`, `model.awk`, `all.tsv`, `jobs.tsv`).

## Finding: the spread is the runner, not the assignment

The same file takes very different time on different jobs. Example: `OnboardingAdministratorFieldsTest` ran 121.7 s in
run 40151856206 shard 2 and 75.9 s in run 40155235763 shard 2, and the whole partition's module total fell from 690 s
to 390 s. Per job, a speed factor f = (sum of the job's module times) / (sum of those files' mean times over all jobs)
has median 0.97, p10 0.73, p90 1.23, range 0.63 to 1.36. All four partitions of one job move together.
The assignment cannot change f: each shard leg lands on a different runner.

| Model (63 runs with four usable legs, shard time = f(run, shard) x slowest partition load) | Runs within 10 % | Median slowest / median | Max |
|---|---|---|---|
| Manifest on main before this change (loads 625.0 / 627.2 / 570.7 / 638.0 s per shard) | 18 | +16.3 % | +69.8 % |
| Rebuilt manifest of this change (loads 620.5 / 621.1 / 621.0 / 620.3 s) | 17 | +18.2 % | +66.0 % |
| Perfect balance (all shard loads equal, only f varies): the floor for ANY manifest | 17 | +18.1 % | +65.9 % |

Measured (not modelled) on the same runs: pooled slowest wall 954 s vs median wall 819 s = +16.5 %, 17 runs within 10 %.

## Change

`test/shard_manifest.txt` rebuilt with `scripts/test_shard_plan.sh --from-tsv` on all 261 job logs and then `--append`
(968 files, each in exactly one partition; the busiest partition has 63 files, under `--slowest-modules 80`).
It evens the modelled load from a 67 s spread to under 1 s (2.7 % less on the slowest shard), but the pass rate does not
move beyond noise, because f dominates.

## Verdict

Criterion (c) as worded ("slowest shard within 10 % of the median") is **not met and cannot be met by any static or
per-file assignment** on this data: even perfect balance passes 17 of 63 runs with a median of +18 %. #2380 stays `Refs`.

## Proposed restatement of (c)

Judge balance on the work, not on the wall: "the modelled slowest shard load (per-file times, speed-normalised) is within
10 % of the median shard load on the existing runs", which the rebuilt manifest meets (all four loads within 0.2 %).
If a wall-clock target is wanted, the floor says roughly "slowest shard wall within +25 % of the median in the pooled
figure", or reduce runner variance (same runner class, fewer co-tenants), which is an infra decision for the owner.
