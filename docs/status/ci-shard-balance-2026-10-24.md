# Measurement for GH #2380: sharded backend gate before and after the M=4 rebalance, 2026-10-24

Measured from the CI runs of `tvolodi-org/letflow`. The M=4 change is commit f53fc6427 (merged
2026-10-24 06:51:44Z, PR #3085). Data: `gh api repos/tvolodi-org/letflow/actions/runs/<id>/jobs`
(job start and end) and the job logs (`test_parallel: phase elapsed=` and `partition N elapsed=`
lines).

## Definitions

- **Shard wall:** a shard job's `completed_at` minus `started_at`. It includes runner setup and is
  what the aggregator waits for.
- **Phase:** `test_parallel: phase elapsed=` in the shard log, the test run inside the shard.
  Setup is shard wall minus phase (66 to 93 s in every shard measured here).
- **Slowest partition:** the largest `partition N elapsed=`. Each shard runs 4 partitions in
  parallel, so the phase is the slowest partition.
- **Slowest / median:** the slowest shard wall of a run against the median shard wall of that run.
  The median of a 4-shard run is the mean of its two middle walls; for a 3-shard run it is the
  middle wall.
- **Runner minutes:** the sum of a PR run's shard job wall times.

## Set selection

- **After set (M=4):** the five consecutive shard-running pull_request runs created after
  2026-10-24T06:52Z that concluded success. Runs with skipped shards (docs-only PRs 40088518797,
  40088625802, 40089814972, 40087060043, 40087033292) and the failed run 40089510986 (shard 4/4
  failure, not examined) are not counted.
- **Excluded:** 40071926808 (created 06:52:37Z, 3 shards, team/T-0326): its branch predates
  f53fc6427, so it is neither a clean M=4 nor a clean pre-merge M=3 measurement. 40070827867
  (06:35Z, 4 shards) is a pre-merge M=4 run created before the cutoff and is in neither set.
- **Before set (M=3):** the five most recent successful shard-running pull_request runs created
  before 2026-10-24T06:51Z. Only two of them are from 2026-10-24; three are from 2026-10-23.

## Per-run shard times (seconds)

Each cell is shard wall / phase. "Slowest phase" is the slowest partition of the run.

| Set | Run id | Shards: wall / phase | Median wall | Slowest wall (shard) | Slowest / median wall | Within 10 %? | Slowest phase | Runner min (sum of walls) |
|---|---|---|---|---|---|---|---|---|
| After M=4 | 40087843535 | s1 814/738, s2 509/439, s3 895/812, s4 896/803 | 854.5 | 896 (s4) | +4.9 % | yes | 812 | 51.9 |
| After M=4 | 40087904919 | s1 530/464, s2 649/564, s3 747/669, s4 860/775 | 698 | 860 (s4) | +23.2 % | no | 775 | 46.4 |
| After M=4 | 40088375039 | s1 818/746, s2 833/757, s3 874/798, s4 853/768 | 843 | 874 (s3) | +3.7 % | yes | 798 | 56.3 |
| After M=4 | 40089295338 | s1 571/501, s2 682/602, s3 883/810, s4 658/575 | 670 | 883 (s3) | +31.8 % | no | 810 | 46.6 |
| After M=4 | 40090740266 | s1 834/754, s2 537/466, s3 880/803, s4 674/605 | 754 | 880 (s3) | +16.7 % | no | 803 | 48.8 |
| Before M=3 | 40066690940 | s1 701/632, s2 916/834, s3 1099/1011 | 916 | 1099 (s3) | +20.0 % | no | 1011 | 45.3 |
| Before M=3 | 40065234381 | s1 669/596, s2 776/708, s3 1064/986 | 776 | 1064 (s3) | +37.1 % | no | 986 | 41.8 |
| Before M=3 | 39993151730 | s1 1124/1032, s2 1016/928, s3 668/596 | 1016 | 1124 (s1) | +10.6 % | no | 1032 | 46.8 |
| Before M=3 | 39985099077 | s1 712/638, s2 869/788, s3 864/781 | 864 | 869 (s2) | +0.6 % | yes | 788 | 40.8 |
| Before M=3 | 39984274593 | s1 672/600, s2 1198/1112, s3 1036/957 | 1036 | 1198 (s2) | +15.6 % | no | 1112 | 48.4 |

## Five-run summary

| | M=3 (before, 5 runs) | M=4 (after, 5 runs) |
|---|---|---|
| Shard jobs per PR | 3 | 4 |
| Partitions per PR (4 per shard) | 12 | 16 |
| Partition method | round-robin over the sorted file list | timing manifest `test/shard_manifest.txt` |
| Median of per-run slowest shard wall | 1099 s (18.3 min) | 880 s (14.7 min) |
| Median of per-run median shard wall | 916 s | 754 s |
| Slowest / median, pooled (median of slowest vs median of medians) | +20.0 % | +16.7 % |
| Runs within 10 % of their median wall | 1 of 5 (39985099077) | 2 of 5 (40087843535, 40088375039) |
| Slowest phase, pooled against median phase | not computed | +18.2 % (803 s vs 679.5 s) |
| Runner minutes per PR (sum of shard walls), median | 45.3 min (2716 s) | 48.8 min (2925 s) |
| Runner minutes per PR, range | 40.8 to 48.4 min | 46.4 to 56.3 min |

Criterion "slowest shard within 10 % of the median": **not met**. It fails in 3 of 5 M=4 runs
(40087904919, 40089295338, 40090740266) and on the pooled wall figure (+16.7 %).

## M=3 vs M=4 comparison and recommendation

| | M=3 | M=4 |
|---|---|---|
| Shard legs per PR | 3 | 4 |
| Gate wall (critical path, median of per-run slowest) | 1099 s (18.3 min) | 880 s (14.7 min), -20 % |
| Runner minutes per PR (median) | 45.3 min | 48.8 min, +7.6 % |
| Runs within 10 % of median | 1 of 5 | 2 of 5 |

**Recommendation: keep M=4.** On measured data it shortens the critical path by about 3.6 minutes
(-20 %) for about 3.5 more runner minutes per PR (+7.6 %), on GitHub-hosted free runners only. The
rebalance is not yet balanced enough to meet the 10 % criterion, so the next step is to rebalance
the manifest, not to revert to M=3.

**Caveat.** The before and after sets differ in partition method (round-robin against timing
manifest), in suite population (the sets span 2026-10-22 to 2026-10-24, with several test-file
additions), and the before set is the three most recent runs before 06:51Z, not five same-day
runs. The M=3 vs M=4 delta therefore mixes shard count with partition method and suite growth. It
is evidence, not an isolated effect.

## Facts checked for the aggregator and runners

- Aggregator: `.github/workflows/ci.yml` line 755, `name: Backend gate (mix letflow.check)`, job
  `backend`, the only job with that name.
- Required contexts on the `main-queue` ruleset (id 25048400): `Backend gate (mix letflow.check)`
  and `Frontend gate (npm run check)`. The shard and static jobs are not required.
- f53fc6427 changes only the shard matrix (`[1,2,3]` to `[1,2,3,4]`), the `TEST_PARALLEL_MANIFEST`
  env of the shard job, the `--slowest-modules` comment and the comment text. The aggregator name
  and the required contexts are untouched.
- The manifest is `test/shard_manifest.txt`, built by `scripts/test_shard_plan.sh`. (The commit
  message of f53fc6427 names `scripts/test_shard_manifest.txt`; that path does not exist.)
- Every `runs-on` in `.github/workflows/*.yml` (8 occurrences) is `ubuntu-latest`: GitHub-hosted
  free runners, no larger or self-hosted runners.

## Remainder of GH #2380

1. Criterion (c) is not met, so the work is not done. Rebalance `test/shard_manifest.txt` from the
   per-file `--slowest` times in these logs with `scripts/test_shard_plan.sh --from-tsv` or
   `--append`, and state the leave-one-out spread of the new partition.
2. Measure five consecutive successful shard-running PR runs after that change lands, and apply the
   same wall-time test. Until then the balance criterion stays open.
