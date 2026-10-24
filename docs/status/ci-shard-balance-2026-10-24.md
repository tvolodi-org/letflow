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

## Rebalance of `test/shard_manifest.txt` (T-0385, remainder step 1)

Rebuilt with `scripts/test_shard_plan.sh --from-logs` from the `--slowest-modules` blocks of the 20
shard job logs (4 shards each) of the five after-M=4 runs 40087843535, 40087904919, 40088375039,
40089295338 and 40090740266 (job ids in the `# source:` header lines of the manifest). The tool
averages each file's share of a run's module total and scales to the last run.

- **Planned per-shard totals:** all 16 partitions plan to 551 s; each shard plans to 551 s slowest
  partition (wall about 629 s with the tool's 1.14 factor). The plan is flat by construction on the
  fitted weights, so it is not the expected spread.
- **Leave-one-out spread (the honest figure):** plan from four runs, score on the fifth run's own
  per-file times; slowest shard (heaviest of its 4 partitions) against the median shard:

| Held-out run | New plan: shard slowest partition (s) | Slowest / median | Old manifest, same run |
|---|---|---|---|
| 40087843535 | 651 620 594 600 | +6.8 % | +4.2 % |
| 40087904919 | 508 537 545 609 | +12.5 % | +25.4 % |
| 40088375039 | 668 658 683 662 | +2.7 % | +5.4 % |
| 40089295338 | 524 558 541 560 | +1.9 % | +35.0 % |
| 40090740266 | 629 576 549 584 | +8.4 % | +15.8 % |

  Mean +6.5 %, worst +12.5 %, 4 of 5 within 10 % (old manifest: mean +17.2 %, 1 of 5). The old
  manifest scored on the runs reproduces the measured walls above (for example +25 % and +35 %),
  which supports using this model.
- **Still open:** measure five consecutive successful shard-running PR runs after this lands
  against the 10 % criterion.

## Measurement after the rebalance (#3108, merge f0cef958b), T-0411

#3108 merged 2026-10-24T14:49Z. Data: `gh api repos/tvolodi-org/letflow/actions/runs/<id>/jobs`, shard
wall = `completed_at` minus `started_at` (same definition as above; median of 4 = mean of the two middle
walls).

**Set:** the five consecutive successful pull_request runs, all with `backend=true` (all four
`Backend shard N/4` jobs ran and succeeded), created after the merge and ordered by creation time:
40112510464 (team/T-0372), 40112806948 (team/T-0395), 40115071502 (team/T-0406), 40115295981
(team/T-0381), 40117820537 (team/T-0402, PR 3122). Not counted: 40114967784 (team/T-0407, created
17:11:11Z, between the 3rd and 4th run), whose shards were skipped, so `ci_changed_paths.sh` gave
`backend=false` (docs-only). The merge_group runs (PRs 3109, 3110, 3117, 3119, 3124, 3125) were not
measured; the criterion is stated on PR runs.

| Run id | Shard walls in s: s1 / s2 / s3 / s4 | Median | Slowest (shard) | Slowest / median | Within 10 %? |
|---|---|---|---|---|---|
| 40112510464 | 841 / 868 / 561 / 855 | 848.0 | 868 (s2) | +2.4 % | yes |
| 40112806948 | 841 / 724 / 728 / 813 | 770.5 | 841 (s1) | +9.1 % | yes |
| 40115071502 | 544 / 815 / 858 / 834 | 824.5 | 858 (s3) | +4.1 % | yes |
| 40115295981 | 561 / 576 / 853 / 568 | 572.0 | 853 (s3) | +49.1 % | no |
| 40117820537 | 846 / 927 / 864 / 712 | 855.0 | 927 (s2) | +8.4 % | yes |

**Result:** 4 of 5 runs are within 10 % of their median shard wall. Criterion (c) is **not met**: the
gap is run 40115295981, where shard 3/4 took 853 s against a 572 s median (+49.1 %, +281 s). Worst of
the other four: +9.1 %. Before the rebalance 2 of 5 were within 10 % (+16.7 % pooled); this is the
4 of 5 the leave-one-out plan predicted. Median of the per-run slowest wall: 858 s (before the
rebalance: 880 s).

The outlier is one slow shard against three that finished in 561 to 576 s, the opposite of a flat plan
with a light shard (runs 3 and 1 have one light shard of 544 and 561 s instead). The balance is
better, but one shard in five can still run about 280 s over; the cause (a heavy file group moved
into one shard, or runner speed) was not isolated from wall times alone. The shard 3/4 job of
40115295981 started at 17:20:11Z, later than shard 2/4 (17:18:01Z), so queueing and runner
variance are not excluded.

### Main push run 40115295998 (Backend shard 2/4)

This is a push run on main (sha 4ab907c2b, created 17:15:31Z), not a pull_request run, so it is not in
the set. Shard 2/4 (job 120935257235) failed on **a test, not on time**: its wall was 713 s
(17:18:00Z to 17:29:53Z), in line with the other shards (829, 678 and 536 s), and the phase was 627 s.
The log shows `combined: 3818 tests, 0 properties, 1 failures` and the single failure
`test/scripts/test_parallel_shard_test.exs:281` ("shard 3 of 3 with N=4 runs global partitions 9..12
of 12", `test_parallel.sh did not finish within 120000 ms`). That test starts `test_parallel.sh` itself
with a 120 s limit, so it is sensitive to load on a shard that is running 4 partitions; it is a
flaky-under-load candidate, not a rebalance effect.

## Remainder of GH #2380 after T-0411

Criterion (c) stays open: 4 of 5 consecutive runs are within 10 %, one run is +49.1 %. A further
rebalance of `test/shard_manifest.txt` using the shard logs of run 40115295981 (shard 3/4 `--slowest`
block against the other three), or a repeat of the five-run measurement once enough new runs exist,
is the next step. The `test_parallel_shard_test.exs:281` timeout is a separate CI-health item.

## Measurement after #3135 (shard-3 test load fix), T-0431

Source: `gh run list --workflow CI --json conclusion,headSha,createdAt,event` and the job start and end
times of `gh api repos/tvolodi-org/letflow/actions/runs/<id>/jobs`, same definitions as above. PR #3135 is
merge ae07cf45e (merge-group run created 2026-10-24T20:08:37Z). Cutoff: pull_request runs created after that.

### Set selection

Only **4** runs qualify, fewer than the five asked for, so the result is partial. Counted from the run
list at the time of writing (newest run created 21:46:35Z):

- **Used (successful pull_request, 4 shard jobs ran):** 40130206638, 40132243112, 40133321565, 40134414792.
- **Not used:** 40131861891 (team/T-0423, the shard job was skipped, docs-only), 40131696297 (team/T-0424,
  conclusion failure, not examined), and every push and merge_group run.

| Run id | headSha | Branch | Shard walls in s: s1 / s2 / s3 / s4 | Median | Slowest (shard) | Slowest / median | Within 10 %? |
|---|---|---|---|---|---|---|---|
| 40130206638 | da110edc38ce | team/T-0393 | 870 / 921 / 570 / 517 | 720.0 | 921 (s2) | +27.9 % | no |
| 40132243112 | 6c55598324e7 | team/T-0422 | 840 / 891 / 891 / 861 | 876.0 | 891 (s2, s3) | +1.7 % | yes |
| 40133321565 | 3fbeb82f9283 | team/T-0424 | 841 / 616 / 921 / 602 | 728.5 | 921 (s3) | +26.4 % | no |
| 40134414792 | 459c31e31f14 | team/T-0422 | 880 / 893 / 863 / 491 | 871.5 | 893 (s2) | +2.5 % | yes |

Full shas: da110edc38ce0eb6b4b00ab3fc24bd9b907dfc11, 6c55598324e7e269efca4fcb48eabb148d533147,
3fbeb82f9283cf5ca53722c434d08bbbbd42b9f8, 459c31e31f14da9242019c5046c0a8bc5c189a32.

**Result:** criterion (c) "slowest slice within 10 % of the median" is **not met on all runs**: 2 of 4 are
within 10 %, and 2 are at +27.9 % and +26.4 %. It is not met on five consecutive runs, so GH #2380 stays
open. The earlier outlier (shard 3/4 at +49.1 %) is gone, but a different pattern has taken its place.

### Outliers

Both outlier runs have two light and two heavy shards (shard 3 and 4 at 570 and 517 s in 40130206638;
shard 2 and 4 at 616 and 602 s in 40133321565), so the median sits between the two groups. The slowest
shard is the heavy group's top, not a single runaway.

- **40130206638, outlier shard 2/4 (921 s, phase 845 s, partitions 5..8).** Dominated by
  `test/letflow/modules/exam/exam_sessions_test.exs` (`Letflow.Modules.Exam.RouterTest`, 133.7 s in
  partition 5), `test/letflow/modules/exam/exam_authoring_test.exs` (43.0 s), the single test
  `test/letflow/audit_test.exs:371` (42.2 s), `exam_stamped_tenant_test.exs` (18.0 s),
  `catalog_items/install_test.exs` (16.9 s) and `engine/module_write_failure_codes_test.exs` (17.7 s).
  Light shard 4/4 had a phase of 450 s.
- **40133321565, outlier shard 3/4 (921 s, phase 839 s, partitions 9..12).** All four partitions
  ended within the same second, so this shard is balanced inside itself; it is heavy as a whole. Largest
  files: `test/letflow/modules/exam/exam_snapshot_late_router_test.exs` (32.7 s),
  `test/letflow/modules/org/read_api_test.exs` (29.4 s), `engine/module_write_audit_test.exs` (17.3 s),
  `modules/install_activation_test.exs` (14.1 s). Light shard 2/4 had a phase of 543 s (partitions
  5..8 up to 543 s) against 765 s in shard 1/4.

The light shards are not the same shards in the two runs (s3 and s4, then s2 and s4), and the same
slice (partitions 5..8, `exam/` and `modules/` files) was light in one run and heavy in the other. The
manifest was not changed between the runs (this task did not diff it per run), so the swing looks like run variance, not a fixed heavy file
group; wall times and slowest-test blocks alone do not tell runner speed from test load apart. Runs
40132243112 and 40134414792 came out within +1.7 % and +2.5 %, except that
shard 4/4 was 491 s in the second.

### Remainder of GH #2380

Criterion (c) is open: 2 of 4 post-#3135 runs are within 10 %, and a fifth qualifying pull_request run
does not exist yet. Repeat this measurement when five qualify. Shard 4/4 is light (491 to 570 s) in 3 of 4
runs, so moving a file group (for example `exam_sessions_test.exs`, 134 s) from the heavy shards into
shard 4 is the candidate rebalance if the pattern repeats; it is not done here (measurement only).
