# Measurement for GH #2380 criterion (c): shard balance after the #3171 manifest rebuild, 2026-10-25

Follow-up to `ci-shard-balance-2026-10-24.md` (remainder step 2: measure shard-running runs after the
manifest rebuild lands). The rebuild is commit d40917a5b (PR #3171, merged 2026-10-25 01:29:31Z, run
40150826845, which already contains the new `test/shard_manifest.txt`).

## Method

- **Run list:** `gh run list --branch main --workflow CI --limit 60`, keeping runs created at or after
  2026-10-25T01:29:31Z (the d40917a5b push run). 33 runs, the last one 40175157174 (08:03:53Z, head 943d1d95d).
- **Per-shard data:** `gh api repos/tvolodi-org/letflow/actions/runs/<id>/jobs` for each `Backend shard N/4`
  job (`completed_at` minus `started_at` = shard wall) and the job log line
  `test_parallel: phase elapsed=<s>s` (the test phase inside the shard; 132 job logs read, one per cell).
- **Population:** main push runs, as the task asked. The 2026-10-24 note stated the criterion on `pull_request`
  runs and excluded push runs, so the two notes do not measure the same population.
- **Statistic:** as in the 2026-10-24 note. Slowest shard wall against the median shard wall of the same run
  (mean of the two middle walls of 4). The criterion "slowest shard within 10 % of the median" passes for a
  run when that ratio is at most +10 %.

## Runs used and excluded

- **Used:** all 33 main CI runs from d40917a5b onward. Every one ran all four backend shard legs
  (`Backend shard 1/4` to `4/4`) to a `success` conclusion, so none is excluded for a skipped or failed shard.
- **Excluded:** none. Main runs before d40917a5b (for example 40149852516, 2e4029c74) are not counted: they
  ran the old manifest.
- **Note on 40166332501** (created 05:39:36Z): the run concluded `failure`, but its four shard legs all
  succeeded and have valid timings, so it is counted. The failing job was not examined and is not a shard job.
- The runs are push runs on `main`, so each follows one merged PR; the content under test differs run to run.

## Per-run results (seconds)

Shard cells are wall / phase. Verdict is on the wall figure; the last column is the same ratio on the phase.

| Run id | Shards: wall / phase | Median wall | Slowest wall | Slowest / median wall | Within 10 %? | Slowest / median phase |
|---|---|---|---|---|---|---|
| 40150826845 | s1 672/588, s2 749/668, s3 638/563, s4 776/689 | 710.5 | 776 | +9.2 % | pass | +9.7 % |
| 40151856206 | s1 686/606, s2 914/830, s3 676/597, s4 633/556 | 681.0 | 914 | +34.2 % | fail | +38.0 % |
| 40152002041 | s1 820/737, s2 880/798, s3 854/775, s4 724/642 | 837.0 | 880 | +5.1 % | pass | +5.6 % |
| 40154393028 | s1 832/746, s2 895/810, s3 902/820, s4 696/620 | 863.5 | 902 | +4.5 % | pass | +5.4 % |
| 40154556513 | s1 868/791, s2 576/508, s3 847/767, s4 698/617 | 772.5 | 868 | +12.4 % | fail | +14.3 % |
| 40155235763 | s1 899/819, s2 538/467, s3 837/759, s4 607/534 | 722.0 | 899 | +24.5 % | fail | +26.7 % |
| 40156162403 | s1 855/770, s2 525/458, s3 651/571, s4 738/649 | 694.5 | 855 | +23.1 % | fail | +26.2 % |
| 40156271864 | s1 568/505, s2 620/549, s3 621/546, s4 706/621 | 620.5 | 706 | +13.8 % | fail | +13.4 % |
| 40157782913 | s1 892/814, s2 923/841, s3 563/500, s4 529/465 | 727.5 | 923 | +26.9 % | fail | +28.0 % |
| 40158258311 | s1 895/812, s2 782/704, s3 897/814, s4 717/644 | 838.5 | 897 | +7.0 % | pass | +7.4 % |
| 40158710691 | s1 893/801, s2 925/849, s3 698/616, s4 584/514 | 795.5 | 925 | +16.3 % | fail | +19.8 % |
| 40158820251 | s1 731/645, s2 965/872, s3 588/514, s4 706/627 | 718.5 | 965 | +34.3 % | fail | +37.1 % |
| 40160352637 | s1 930/841, s2 909/833, s3 549/479, s4 936/856 | 919.5 | 936 | +1.8 % | pass | +2.3 % |
| 40161311345 | s1 904/822, s2 594/523, s3 537/473, s4 943/859 | 749.0 | 943 | +25.9 % | fail | +27.7 % |
| 40163031563 | s1 911/832, s2 775/678, s3 693/604, s4 983/903 | 843.0 | 983 | +16.6 % | fail | +19.6 % |
| 40163275152 | s1 913/838, s2 622/554, s3 919/839, s4 938/860 | 916.0 | 938 | +2.4 % | pass | +2.6 % |
| 40163462187 | s1 909/833, s2 958/881, s3 707/624, s4 942/853 | 925.5 | 958 | +3.5 % | pass | +4.5 % |
| 40165369113 | s1 872/796, s2 760/678, s3 680/598, s4 617/551 | 720.0 | 872 | +21.1 % | fail | +24.8 % |
| 40165904278 | s1 883/807, s2 954/867, s3 593/526, s4 938/850 | 910.5 | 954 | +4.8 % | pass | +4.6 % |
| 40166332501 | s1 710/641, s2 699/621, s3 903/811, s4 928/852 | 806.5 | 928 | +15.1 % | fail | +17.4 % |
| 40166887766 | s1 520/449, s2 583/510, s3 959/871, s4 962/878 | 771.0 | 962 | +24.8 % | fail | +27.2 % |
| 40167092076 | s1 543/472, s2 944/867, s3 896/816, s4 599/529 | 747.5 | 944 | +26.3 % | fail | +28.9 % |
| 40167403554 | s1 910/833, s2 923/848, s3 901/827, s4 701/622 | 905.5 | 923 | +1.9 % | pass | +2.2 % |
| 40168761462 | s1 879/802, s2 937/853, s3 741/654, s4 582/512 | 810.0 | 937 | +15.7 % | fail | +17.2 % |
| 40170077655 | s1 631/555, s2 888/808, s3 553/492, s4 951/877 | 759.5 | 951 | +25.2 % | fail | +28.7 % |
| 40170239720 | s1 925/837, s2 954/877, s3 742/658, s4 749/668 | 837.0 | 954 | +14.0 % | fail | +16.5 % |
| 40170998803 | s1 655/577, s2 938/857, s3 914/824, s4 766/685 | 840.0 | 938 | +11.7 % | fail | +13.6 % |
| 40172476577 | s1 709/623, s2 615/547, s3 908/825, s4 937/860 | 808.5 | 937 | +15.9 % | fail | +18.8 % |
| 40173199923 | s1 677/608, s2 949/863, s3 892/814, s4 622/554 | 784.5 | 949 | +21.0 % | fail | +21.4 % |
| 40173472223 | s1 902/811, s2 945/865, s3 532/463, s4 778/693 | 840.0 | 945 | +12.5 % | fail | +15.0 % |
| 40173583336 | s1 750/660, s2 596/533, s3 703/624, s4 984/893 | 726.5 | 984 | +35.4 % | fail | +39.1 % |
| 40173599398 | s1 892/809, s2 738/650, s3 562/501, s4 980/892 | 815.0 | 980 | +20.2 % | fail | +22.3 % |
| 40175157174 | s1 911/827, s2 562/494, s3 904/828, s4 734/659 | 819.0 | 911 | +11.2 % | fail | +11.4 % |

## Summary

| | Value |
|---|---|
| Runs measured | 33 |
| Runs within 10 % of the median wall | 9 of 33 (40150826845, 40152002041, 40154393028, 40158258311, 40160352637, 40163275152, 40163462187, 40165904278, 40167403554) |
| Per-run slowest / median wall, median over runs | +15.7 % (range +1.8 % to +35.4 %) |
| Pooled: median of per-run slowest wall vs median of per-run median wall | 937 s vs 806.5 s = +16.2 % |
| Runs above +20 % | 13 of 33 |

(For comparison, the manifest that #3171 replaced was last measured in the T-0447 section of the 2026-10-24
note: 4 of 7 runs within 10 %, worst +27.9 %; the #3108 rebalance before it measured 4 of 5. Those sets are
`pull_request` runs and this note uses main push runs, so the comparison is indicative only: 9 of 33 (27 %) here
against 4 of 7 (57 %) there. This note does not claim the rebuild changed the pass rate.)

## Verdict

Criterion (c), "slowest shard within 10 % of the median", is **not met**: it fails in 24 of 33 runs and on the pooled
figure (+16.2 %). The slowest shard changes from run to run (s1, s2, s3 and s4 each appear as slowest in the table), and a shard that is
slow in one run is fast in another. That pattern is run-to-run variation in what each shard actually executes
(which files run, and per-file time), not one fixed overloaded shard. This note names no cause beyond that: the
sibling shard durations of the same logs are in the table above. Whether the manifest can do better than this spread,
or whether the criterion needs a looser bound or a different statistic (for example the slowest partition against the median
partition), is a decision for #2380, not settled here.

## Remainder of GH #2380

Criterion (c) stays open. The measured gap: pooled slowest / median wall +16.2 % against a 10 % target, 9 of 33 runs
passing. Options for the next step: a per-file balance that is robust to run-to-run variation (dynamic claiming of
files instead of a static manifest), or an owner decision to restate (c).
