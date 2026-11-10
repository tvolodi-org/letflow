# CI minutes after the batch-4 cuts (REQ-796)

## Method

Docs only. Nothing in CI is changed; no cut is applied. Every number below comes from the GitHub Actions API of
`tvolodi-org/letflow` (`gh api repos/tvolodi-org/letflow/actions/workflows/ci.yml/runs` and
`.../actions/runs/<id>/jobs`), not from memory. The baseline is `docs/status/ci-minutes-20261110.md` (T-1614, B4#9).
The required checks "Backend gate (mix letflow.check)" and "Frontend gate (npm run check)" are never removed, renamed
or stopped by any cut in this note.

Populations (the run list was queried on 2026-11-10 at about 19:30 UTC, the job details of all 60 runs were fetched
by 19:35 UTC; `schedule` and `workflow_dispatch` runs are excluded):

| Population | Newest run (id, head commit) | Oldest run (id, head commit) |
|---|---|---|
| (a) last 30 completed CI runs, event `push`, branch `main` | 42883695529, f4dade727 | 42728307897, 6d923fe72 |
| (b) last 30 completed CI runs, event `merge_group` | 42885626622, 3926469bd | 42763939165, 4ceabf2df |

Labels. A push run is "after T-1614" when `git merge-base --is-ancestor c2aa91737 <head commit>` exits 0, else "before
T-1614": 23 runs are after, 7 before. A merge-group run is "after T-1617" when its created_at is later than the
committer time of 3df34c28f (`git show -s --format=%cI 3df34c28f` = 2026-11-10T04:28:37Z), else "before T-1617": all 30
are after (the oldest was created 2026-11-10T05:43:53Z), so **no merge-group run before T-1617 exists in the last 30**
and the T-1617 effect cannot be measured by a before/after split here.

Split of each job (from the jobs API): waiting = started_at minus created_at; tests = summed duration of the steps
named "Run static checks (mix letflow.check.static)", "Effective permission matrix (MIX_ENV=dev, production module
list)", "Run isolated tails (mix letflow.check.test --tails-only)", "Run test shard", "Run docs tests (docs-only
change)", "Run frontend gate", "Analyze", "Test", "Build debug APK", "Build web (PWA)" (steps that were skipped count
0); set-up = completed_at minus started_at, minus tests. A job with conclusion skipped counts 0 in every column and
appears in the "skipped" column. All ten step names were still present in `.github/workflows/ci.yml` at the time of
the query (the step names that ran are the ones seen in the jobs API; "Run frontend gate", "Analyze", "Test", "Build
debug APK" and "Build web (PWA)" did run in the Frontend and Mobile gate jobs). Note that in a run where the path
rules select only some tests, the Backend shard jobs still start, check out and finish in seconds with every step
skipped; they are not "skipped" jobs in the API, so they count as runs with tests = 0. Three merge-group runs also
show a job literally named `Backend shard ${{ matrix.shard }}/${{ strategy.job-total }}` with conclusion skipped
(the matrix was not expanded); those are counted under that name and not in the per-shard rows. "Selective CI markers"
is skipped in every merge-group run by design (main only).

Two kinds of run are mixed in every population: **full runs** (backend tests run in all 8 shards) and **selective runs**
(few or no backend tests, the docs-only and small changes). Medians over a population that mixes both are dominated by
the mix, not by a cut, so the section "What the batch-4 cuts moved" reads the two kinds separately.

### Raw rows

One line per job per run (seconds; `skipped=1` means the job was skipped). Every median below can be re-derived from
this block; the first block is population (a), the second population (b).

```
run_id,label,job,skipped,wait_s,setup_s,tests_s
42883695529,after,Detect changed paths,0,2,15,0
42883695529,after,Backend static checks + isolated tails,0,2,47,381
42883695529,after,Backend shard 5/8,0,3,27,0
42883695529,after,Backend shard 4/8,0,2,25,0
42883695529,after,Backend shard 3/8,0,2,22,0
42883695529,after,Backend shard 1/8,0,3,53,597
42883695529,after,Backend shard 8/8,0,3,25,0
42883695529,after,Backend shard 2/8,0,2,55,278
42883695529,after,Backend shard 6/8,0,2,21,0
42883695529,after,Backend shard 7/8,0,3,26,0
42883695529,after,Frontend gate,1,0,0,0
42883695529,after,Mobile gate,1,0,0,0
42883695529,after,Backend gate,0,2,4,0
42883695529,after,Selective CI markers,0,2,11,0
42874666357,after,Detect changed paths,0,2,85,0
42874666357,after,Backend static checks + isolated tails,0,2,46,262
42874666357,after,Backend shard 6/8,0,2,56,965
42874666357,after,Backend shard 8/8,0,2,50,886
42874666357,after,Backend shard 3/8,0,2,54,1447
42874666357,after,Backend shard 4/8,0,2,51,752
42874666357,after,Backend shard 2/8,0,2,46,1090
42874666357,after,Backend shard 5/8,0,2,45,1165
42874666357,after,Backend shard 7/8,0,2,57,724
42874666357,after,Backend shard 1/8,0,2,58,1016
42874666357,after,Frontend gate,1,0,0,0
42874666357,after,Mobile gate,1,0,0,0
42874666357,after,Backend gate,0,2,3,0
42874666357,after,Selective CI markers,0,2,14,0
42868446271,after,Detect changed paths,0,2,11,0
42868446271,after,Backend shard 2/8,0,2,47,189
42868446271,after,Backend shard 4/8,0,2,24,0
42868446271,after,Backend static checks + isolated tails,0,2,47,302
42868446271,after,Backend shard 1/8,0,2,54,545
42868446271,after,Backend shard 5/8,0,2,24,0
42868446271,after,Backend shard 8/8,0,2,23,0
42868446271,after,Backend shard 6/8,0,2,21,0
42868446271,after,Backend shard 7/8,0,2,23,0
42868446271,after,Backend shard 3/8,0,2,28,0
42868446271,after,Mobile gate,1,0,0,0
42868446271,after,Frontend gate,1,0,0,0
42868446271,after,Backend gate,0,2,3,0
42868446271,after,Selective CI markers,0,2,12,0
42859491536,after,Detect changed paths,0,2,15,0
42859491536,after,Frontend gate,0,2,37,278
42859491536,after,Backend static checks + isolated tails,0,2,49,378
42859491536,after,Backend shard 6/8,0,2,25,0
42859491536,after,Backend shard 5/8,0,2,24,0
42859491536,after,Backend shard 1/8,0,2,52,597
42859491536,after,Backend shard 2/8,0,2,48,186
42859491536,after,Backend shard 8/8,0,2,26,0
42859491536,after,Backend shard 4/8,0,2,31,0
42859491536,after,Backend shard 7/8,0,2,27,0
42859491536,after,Backend shard 3/8,0,2,22,0
42859491536,after,Mobile gate,1,0,0,0
42859491536,after,Backend gate,0,2,3,0
42859491536,after,Selective CI markers,0,3,16,0
42856472996,after,Detect changed paths,0,2,13,0
42856472996,after,Backend shard 2/8,0,2,25,0
42856472996,after,Backend shard 1/8,0,2,49,51
42856472996,after,Backend shard 6/8,0,1,32,0
42856472996,after,Backend shard 3/8,0,2,26,0
42856472996,after,Backend shard 5/8,0,2,23,0
42856472996,after,Backend shard 8/8,0,2,23,0
42856472996,after,Backend shard 4/8,0,2,26,0
42856472996,after,Backend shard 7/8,0,2,26,0
42856472996,after,Backend static checks + isolated tails,0,2,46,373
42856472996,after,Frontend gate,1,0,0,0
42856472996,after,Mobile gate,1,0,0,0
42856472996,after,Backend gate,0,2,5,0
42856472996,after,Selective CI markers,0,2,14,0
42850504012,after,Detect changed paths,0,2,16,0
42850504012,after,Backend static checks + isolated tails,0,1,56,299
42850504012,after,Backend shard 5/8,0,1,50,930
42850504012,after,Backend shard 3/8,0,2,48,1597
42850504012,after,Backend shard 8/8,0,2,46,1001
42850504012,after,Backend shard 7/8,0,2,51,676
42850504012,after,Backend shard 2/8,0,2,48,705
42850504012,after,Backend shard 1/8,0,2,47,700
42850504012,after,Backend shard 4/8,0,2,51,1020
42850504012,after,Backend shard 6/8,0,2,53,1190
42850504012,after,Mobile gate,1,0,0,0
42850504012,after,Frontend gate,1,0,0,0
42850504012,after,Backend gate,0,2,3,0
42850504012,after,Selective CI markers,0,2,16,0
42844384750,after,Detect changed paths,0,-1830,13,0
42844384750,after,Mobile gate,1,0,0,0
42844384750,after,Backend shard 7/8,0,-1815,43,534
42844384750,after,Backend shard 8/8,0,-1815,49,726
42844384750,after,Backend shard 4/8,0,-1815,45,578
42844384750,after,Backend shard 3/8,0,-1815,46,1564
42844384750,after,Backend shard 6/8,0,-1815,63,1197
42844384750,after,Backend shard 2/8,0,2,58,835
42844384750,after,Backend static checks + isolated tails,0,-1822,48,297
42844384750,after,Backend shard 1/8,0,-1823,44,1012
42844384750,after,Frontend gate,1,0,0,0
42844384750,after,Backend shard 5/8,0,-1823,50,1255
42844384750,after,Backend gate,0,2,3,0
42844384750,after,Selective CI markers,0,2,16,0
42838250197,after,Detect changed paths,0,2,14,0
42838250197,after,Backend static checks + isolated tails,0,2,54,360
42838250197,after,Backend shard 5/8,0,2,28,0
42838250197,after,Backend shard 3/8,0,2,23,0
42838250197,after,Backend shard 1/8,0,2,54,419
42838250197,after,Backend shard 4/8,0,2,22,0
42838250197,after,Backend shard 7/8,0,2,21,0
42838250197,after,Backend shard 2/8,0,2,54,244
42838250197,after,Backend shard 8/8,0,2,25,0
42838250197,after,Backend shard 6/8,0,3,29,0
42838250197,after,Frontend gate,1,0,0,0
42838250197,after,Mobile gate,1,0,0,0
42838250197,after,Backend gate,0,2,4,0
42838250197,after,Selective CI markers,0,2,15,0
42835148239,after,Detect changed paths,0,2,14,0
42835148239,after,Backend shard 3/8,0,2,24,0
42835148239,after,Backend static checks + isolated tails,0,2,42,381
42835148239,after,Backend shard 6/8,0,2,23,0
42835148239,after,Backend shard 1/8,0,2,48,354
42835148239,after,Backend shard 8/8,0,2,25,0
42835148239,after,Backend shard 7/8,0,2,23,0
42835148239,after,Backend shard 4/8,0,1,25,0
42835148239,after,Backend shard 5/8,0,2,26,0
42835148239,after,Backend shard 2/8,0,2,47,184
42835148239,after,Frontend gate,1,0,0,0
42835148239,after,Mobile gate,1,0,0,0
42835148239,after,Backend gate,0,2,2,0
42835148239,after,Selective CI markers,0,2,17,0
42826594484,after,Detect changed paths,0,2,13,0
42826594484,after,Backend static checks + isolated tails,0,2,49,300
42826594484,after,Backend shard 5/8,0,2,51,796
42826594484,after,Backend shard 3/8,0,2,47,966
42826594484,after,Backend shard 7/8,0,2,53,932
42826594484,after,Backend shard 2/8,0,2,54,833
42826594484,after,Backend shard 6/8,0,2,44,655
42826594484,after,Backend shard 4/8,0,2,44,947
42826594484,after,Backend shard 1/8,0,2,45,800
42826594484,after,Backend shard 8/8,0,2,52,726
42826594484,after,Frontend gate,0,2,35,258
42826594484,after,Mobile gate,1,0,0,0
42826594484,after,Backend gate,0,3,3,0
42826594484,after,Selective CI markers,0,2,15,0
42822724921,after,Detect changed paths,0,2,16,0
42822724921,after,Backend static checks + isolated tails,0,2,56,310
42822724921,after,Backend shard 5/8,0,2,44,1281
42822724921,after,Backend shard 6/8,0,2,52,1189
42822724921,after,Backend shard 1/8,0,2,53,1290
42822724921,after,Backend shard 3/8,0,2,55,1361
42822724921,after,Backend shard 2/8,0,2,45,1068
42822724921,after,Backend shard 8/8,0,2,55,736
42822724921,after,Backend shard 4/8,0,2,57,813
42822724921,after,Backend shard 7/8,0,2,57,722
42822724921,after,Mobile gate,1,0,0,0
42822724921,after,Frontend gate,1,0,0,0
42822724921,after,Backend gate,0,2,3,0
42822724921,after,Selective CI markers,0,2,13,0
42809600702,after,Detect changed paths,0,2,12,0
42809600702,after,Backend static checks + isolated tails,0,3,44,377
42809600702,after,Backend shard 1/8,0,3,23,0
42809600702,after,Backend shard 4/8,0,3,24,0
42809600702,after,Backend shard 3/8,0,3,23,0
42809600702,after,Backend shard 6/8,0,3,21,0
42809600702,after,Backend shard 2/8,0,3,22,0
42809600702,after,Backend shard 5/8,0,3,23,0
42809600702,after,Backend shard 8/8,0,3,25,0
42809600702,after,Backend shard 7/8,0,3,24,0
42809600702,after,Mobile gate,1,0,0,0
42809600702,after,Frontend gate,1,0,0,0
42809600702,after,Backend gate,0,3,3,0
42809600702,after,Selective CI markers,0,2,14,0
42802534350,after,Detect changed paths,0,2,15,0
42802534350,after,Backend static checks + isolated tails,0,2,45,378
42802534350,after,Backend shard 1/8,0,2,56,976
42802534350,after,Backend shard 7/8,0,2,44,961
42802534350,after,Backend shard 6/8,0,2,48,1155
42802534350,after,Backend shard 2/8,0,2,43,1085
42802534350,after,Backend shard 8/8,0,2,58,764
42802534350,after,Backend shard 4/8,0,2,45,811
42802534350,after,Backend shard 3/8,0,2,51,1105
42802534350,after,Backend shard 5/8,0,2,43,684
42802534350,after,Mobile gate,1,0,0,0
42802534350,after,Frontend gate,1,0,0,0
42802534350,after,Backend gate,0,2,4,0
42802534350,after,Selective CI markers,0,3,15,0
42798022678,after,Detect changed paths,0,3,21,0
42798022678,after,Backend static checks + isolated tails,0,3,45,386
42798022678,after,Backend shard 7/8,0,2,44,963
42798022678,after,Backend shard 1/8,0,3,51,941
42798022678,after,Backend shard 2/8,0,3,51,1054
42798022678,after,Backend shard 8/8,0,3,45,605
42798022678,after,Backend shard 3/8,0,3,51,1132
42798022678,after,Backend shard 6/8,0,3,44,1159
42798022678,after,Backend shard 4/8,0,3,52,926
42798022678,after,Backend shard 5/8,0,3,52,1229
42798022678,after,Frontend gate,1,0,0,0
42798022678,after,Mobile gate,1,0,0,0
42798022678,after,Backend gate,0,3,2,0
42798022678,after,Selective CI markers,0,2,11,0
42793596320,after,Detect changed paths,0,2,16,0
42793596320,after,Backend static checks + isolated tails,0,2,45,383
42793596320,after,Backend shard 2/8,0,2,49,305
42793596320,after,Backend shard 3/8,0,3,25,0
42793596320,after,Backend shard 7/8,0,2,23,0
42793596320,after,Backend shard 6/8,0,3,22,0
42793596320,after,Backend shard 4/8,0,3,28,0
42793596320,after,Backend shard 1/8,0,3,47,278
42793596320,after,Backend shard 5/8,0,3,24,0
42793596320,after,Backend shard 8/8,0,3,22,0
42793596320,after,Mobile gate,1,0,0,0
42793596320,after,Frontend gate,1,0,0,0
42793596320,after,Backend gate,0,3,3,0
42793596320,after,Selective CI markers,0,3,10,0
42789866293,after,Detect changed paths,0,3,16,0
42789866293,after,Backend shard 8/8,0,3,22,0
42789866293,after,Backend shard 3/8,0,2,22,0
42789866293,after,Backend static checks + isolated tails,0,3,48,288
42789866293,after,Backend shard 1/8,0,3,57,363
42789866293,after,Backend shard 2/8,0,3,46,244
42789866293,after,Backend shard 7/8,0,3,26,0
42789866293,after,Backend shard 4/8,0,3,23,0
42789866293,after,Backend shard 6/8,0,3,24,0
42789866293,after,Backend shard 5/8,0,3,29,0
42789866293,after,Frontend gate,1,0,0,0
42789866293,after,Mobile gate,1,0,0,0
42789866293,after,Backend gate,0,3,3,0
42789866293,after,Selective CI markers,0,3,13,0
42785463213,after,Detect changed paths,0,2,14,0
42785463213,after,Backend static checks + isolated tails,0,2,46,382
42785463213,after,Backend shard 5/8,0,2,51,923
42785463213,after,Backend shard 4/8,0,2,45,697
42785463213,after,Backend shard 7/8,0,2,55,713
42785463213,after,Backend shard 1/8,0,2,53,1166
42785463213,after,Backend shard 2/8,0,2,47,660
42785463213,after,Backend shard 6/8,0,2,57,1170
42785463213,after,Backend shard 8/8,0,2,56,743
42785463213,after,Backend shard 3/8,0,2,45,917
42785463213,after,Frontend gate,1,0,0,0
42785463213,after,Mobile gate,1,0,0,0
42785463213,after,Backend gate,0,3,3,0
42785463213,after,Selective CI markers,0,2,12,0
42780173200,after,Detect changed paths,0,2,15,0
42780173200,after,Backend static checks + isolated tails,0,3,51,295
42780173200,after,Backend shard 2/8,0,2,46,590
42780173200,after,Backend shard 5/8,0,3,45,718
42780173200,after,Backend shard 4/8,0,3,43,927
42780173200,after,Backend shard 7/8,0,3,44,577
42780173200,after,Backend shard 8/8,0,3,50,842
42780173200,after,Backend shard 6/8,0,3,44,1174
42780173200,after,Backend shard 1/8,0,3,47,1130
42780173200,after,Backend shard 3/8,0,3,43,1506
42780173200,after,Mobile gate,1,0,0,0
42780173200,after,Frontend gate,1,0,0,0
42780173200,after,Backend gate,0,3,3,0
42780173200,after,Selective CI markers,0,3,11,0
42777187372,after,Detect changed paths,0,2,11,0
42777187372,after,Backend shard 2/8,0,2,53,850
42777187372,after,Backend static checks + isolated tails,0,3,55,303
42777187372,after,Backend shard 6/8,0,2,42,1160
42777187372,after,Backend shard 3/8,0,2,43,1529
42777187372,after,Backend shard 5/8,0,2,42,1216
42777187372,after,Backend shard 1/8,0,2,53,991
42777187372,after,Backend shard 7/8,0,3,53,948
42777187372,after,Backend shard 4/8,0,3,52,932
42777187372,after,Backend shard 8/8,0,2,51,985
42777187372,after,Mobile gate,1,0,0,0
42777187372,after,Frontend gate,1,0,0,0
42777187372,after,Backend gate,0,2,3,0
42777187372,after,Selective CI markers,0,3,16,0
42770460283,after,Detect changed paths,0,3,15,0
42770460283,after,Mobile gate,0,3,35,294
42770460283,after,Frontend gate,0,2,31,226
42770460283,after,Backend shard 7/8,0,3,51,760
42770460283,after,Backend static checks + isolated tails,0,2,50,256
42770460283,after,Backend shard 6/8,0,2,47,771
42770460283,after,Backend shard 1/8,0,2,45,1023
42770460283,after,Backend shard 4/8,0,3,53,913
42770460283,after,Backend shard 3/8,0,3,49,1450
42770460283,after,Backend shard 8/8,0,3,52,985
42770460283,after,Backend shard 2/8,0,2,44,1088
42770460283,after,Backend shard 5/8,0,2,43,1206
42770460283,after,Backend gate,0,2,5,0
42770460283,after,Selective CI markers,0,2,11,0
42762004671,after,Detect changed paths,0,2,13,0
42762004671,after,Backend static checks + isolated tails,0,3,51,379
42762004671,after,Backend shard 3/8,0,3,24,0
42762004671,after,Backend shard 4/8,0,2,23,0
42762004671,after,Backend shard 2/8,0,3,55,312
42762004671,after,Backend shard 8/8,0,2,22,0
42762004671,after,Backend shard 7/8,0,3,20,0
42762004671,after,Backend shard 1/8,0,2,44,247
42762004671,after,Backend shard 6/8,0,3,23,0
42762004671,after,Backend shard 5/8,0,3,24,0
42762004671,after,Mobile gate,1,0,0,0
42762004671,after,Frontend gate,1,0,0,0
42762004671,after,Backend gate,0,3,3,0
42762004671,after,Selective CI markers,0,3,13,0
42761852459,after,Detect changed paths,0,3,12,0
42761852459,after,Backend shard 5/8,0,2,47,924
42761852459,after,Frontend gate,0,3,40,260
42761852459,after,Backend shard 6/8,0,2,51,835
42761852459,after,Backend static checks + isolated tails,0,2,46,294
42761852459,after,Backend shard 7/8,0,2,43,654
42761852459,after,Backend shard 8/8,0,2,51,730
42761852459,after,Backend shard 1/8,0,2,46,881
42761852459,after,Backend shard 3/8,0,2,42,924
42761852459,after,Mobile gate,0,2,35,367
42761852459,after,Backend shard 2/8,0,2,44,635
42761852459,after,Backend shard 4/8,0,2,45,909
42761852459,after,Backend gate,0,2,3,0
42761852459,after,Selective CI markers,0,3,14,0
42756566368,after,Detect changed paths,0,2,11,0
42756566368,after,Mobile gate,0,2,32,294
42756566368,after,Frontend gate,0,3,48,340
42756566368,after,Backend static checks + isolated tails,0,3,44,258
42756566368,after,Backend shard 6/8,0,3,49,810
42756566368,after,Backend shard 2/8,0,3,51,1145
42756566368,after,Backend shard 5/8,0,2,44,696
42756566368,after,Backend shard 3/8,0,3,49,1113
42756566368,after,Backend shard 4/8,0,3,51,935
42756566368,after,Backend shard 7/8,0,3,49,653
42756566368,after,Backend shard 1/8,0,3,47,971
42756566368,after,Backend shard 8/8,0,3,53,1002
42756566368,after,Backend gate,0,2,4,0
42756566368,after,Selective CI markers,0,3,13,0
42754217073,before,Detect changed paths,0,3,15,0
42754217073,before,Mobile gate,0,3,34,317
42754217073,before,Backend shard 2/8,0,3,56,829
42754217073,before,Backend shard 5/8,0,3,51,902
42754217073,before,Frontend gate,0,3,47,342
42754217073,before,Backend shard 8/8,0,3,50,1006
42754217073,before,Backend shard 7/8,0,3,47,968
42754217073,before,Backend shard 6/8,0,3,53,802
42754217073,before,Backend static checks + isolated tails,0,3,49,306
42754217073,before,Backend shard 1/8,0,3,54,844
42754217073,before,Backend shard 3/8,0,3,50,1106
42754217073,before,Backend shard 4/8,0,3,56,838
42754217073,before,Backend gate,0,2,3,0
42754217073,before,Selective CI markers,0,3,14,0
42753585428,before,Detect changed paths,0,3,11,0
42753585428,before,Backend shard 8/8,0,3,27,0
42753585428,before,Backend shard 4/8,0,2,21,0
42753585428,before,Backend shard 3/8,0,2,21,0
42753585428,before,Mobile gate,0,2,26,411
42753585428,before,Backend shard 5/8,0,2,25,0
42753585428,before,Backend static checks + isolated tails,0,2,47,406
42753585428,before,Backend shard 7/8,0,2,21,0
42753585428,before,Backend shard 1/8,0,2,49,483
42753585428,before,Frontend gate,0,2,31,243
42753585428,before,Backend shard 6/8,0,2,21,0
42753585428,before,Backend shard 2/8,0,2,45,220
42753585428,before,Backend gate,0,2,4,0
42753585428,before,Selective CI markers,0,2,14,0
42752444280,before,Detect changed paths,0,2,14,0
42752444280,before,Frontend gate,0,2,46,339
42752444280,before,Backend shard 6/8,0,2,53,1132
42752444280,before,Backend shard 3/8,0,2,48,1174
42752444280,before,Mobile gate,0,2,30,380
42752444280,before,Backend shard 2/8,0,2,55,905
42752444280,before,Backend static checks + isolated tails,0,2,53,383
42752444280,before,Backend shard 5/8,0,2,45,750
42752444280,before,Backend shard 4/8,0,2,54,654
42752444280,before,Backend shard 7/8,0,2,56,717
42752444280,before,Backend shard 1/8,0,2,42,1179
42752444280,before,Backend shard 8/8,0,2,49,601
42752444280,before,Backend gate,0,3,3,0
42752444280,before,Selective CI markers,0,2,11,0
42751371647,before,Detect changed paths,0,2,14,0
42751371647,before,Frontend gate,0,3,47,279
42751371647,before,Backend shard 4/8,0,2,27,0
42751371647,before,Backend shard 6/8,0,2,22,0
42751371647,before,Mobile gate,0,3,38,394
42751371647,before,Backend static checks + isolated tails,0,3,54,377
42751371647,before,Backend shard 2/8,0,2,49,209
42751371647,before,Backend shard 8/8,0,3,24,0
42751371647,before,Backend shard 3/8,0,3,22,0
42751371647,before,Backend shard 1/8,0,3,54,368
42751371647,before,Backend shard 5/8,0,2,23,0
42751371647,before,Backend shard 7/8,0,2,29,0
42751371647,before,Backend gate,0,2,3,0
42751371647,before,Selective CI markers,0,3,11,0
42743253998,before,Detect changed paths,0,3,14,0
42743253998,before,Backend static checks + isolated tails,0,2,53,373
42743253998,before,Frontend gate,0,2,44,257
42743253998,before,Backend shard 2/8,0,2,50,819
42743253998,before,Backend shard 4/8,0,2,58,708
42743253998,before,Backend shard 7/8,0,2,46,959
42743253998,before,Backend shard 3/8,0,2,49,1449
42743253998,before,Backend shard 8/8,0,2,43,604
42743253998,before,Backend shard 1/8,0,2,68,931
42743253998,before,Backend shard 5/8,0,2,49,1225
42743253998,before,Backend shard 6/8,0,2,51,844
42743253998,before,Mobile gate,0,2,38,404
42743253998,before,Backend gate,0,2,3,0
42743253998,before,Selective CI markers,0,2,14,0
42735265595,before,Detect changed paths,0,3,16,0
42735265595,before,Frontend gate,0,2,41,322
42735265595,before,Backend shard 1/8,0,2,51,271
42735265595,before,Backend static checks + isolated tails,0,2,53,293
42735265595,before,Backend shard 6/8,0,3,21,0
42735265595,before,Backend shard 8/8,0,2,24,0
42735265595,before,Mobile gate,0,2,26,380
42735265595,before,Backend shard 2/8,0,2,49,332
42735265595,before,Backend shard 7/8,0,2,22,0
42735265595,before,Backend shard 5/8,0,2,22,0
42735265595,before,Backend shard 4/8,0,3,23,0
42735265595,before,Backend shard 3/8,0,2,21,0
42735265595,before,Backend gate,0,3,4,0
42735265595,before,Selective CI markers,0,3,14,0
42728307897,before,Detect changed paths,0,2,12,0
42728307897,before,Mobile gate,0,3,35,386
42728307897,before,Backend shard 4/8,0,2,22,0
42728307897,before,Backend static checks + isolated tails,0,3,51,381
42728307897,before,Frontend gate,0,3,33,223
42728307897,before,Backend shard 6/8,0,2,21,0
42728307897,before,Backend shard 2/8,0,2,46,338
42728307897,before,Backend shard 3/8,0,2,23,0
42728307897,before,Backend shard 1/8,0,3,49,479
42728307897,before,Backend shard 7/8,0,2,23,0
42728307897,before,Backend shard 5/8,0,3,24,0
42728307897,before,Backend shard 8/8,0,2,21,0
42728307897,before,Backend gate,0,2,4,0
42728307897,before,Selective CI markers,0,2,12,0

run_id,label,job,skipped,wait_s,setup_s,tests_s
42885626622,after,Detect changed paths,0,2,15,0
42885626622,after,Backend gate,0,2,4,0
42885626622,after,Frontend gate,1,0,0,0
42885626622,after,Backend static checks + isolated tails,1,0,0,0
42885626622,after,Mobile gate,1,0,0,0
42885626622,after,Backend shard ${{ matrix.shard }}/${{ strategy.job-total }},1,0,0,0
42885626622,after,Selective CI markers,1,0,0,0
42881709370,after,Detect changed paths,0,2,16,0
42881709370,after,Backend static checks + isolated tails,0,2,53,303
42881709370,after,Backend shard 3/8,0,1,25,0
42881709370,after,Backend shard 2/8,0,1,46,204
42881709370,after,Backend shard 7/8,0,1,24,0
42881709370,after,Backend shard 8/8,0,2,25,0
42881709370,after,Backend shard 4/8,0,1,24,0
42881709370,after,Backend shard 6/8,0,2,22,0
42881709370,after,Backend shard 5/8,0,2,27,0
42881709370,after,Backend shard 1/8,0,2,52,603
42881709370,after,Frontend gate,1,0,0,0
42881709370,after,Mobile gate,1,0,0,0
42881709370,after,Backend gate,0,2,4,0
42881709370,after,Selective CI markers,1,0,0,0
42870480879,after,Detect changed paths,0,2,17,0
42870480879,after,Backend static checks + isolated tails,0,2,60,304
42870480879,after,Backend shard 3/8,0,2,55,1337
42870480879,after,Backend shard 5/8,0,2,53,813
42870480879,after,Backend shard 1/8,0,2,51,812
42870480879,after,Backend shard 4/8,0,1,44,879
42870480879,after,Backend shard 6/8,0,2,61,810
42870480879,after,Backend shard 8/8,0,2,44,574
42870480879,after,Backend shard 2/8,0,2,45,910
42870480879,after,Backend shard 7/8,0,2,44,562
42870480879,after,Frontend gate,1,0,0,0
42870480879,after,Mobile gate,1,0,0,0
42870480879,after,Backend gate,0,2,4,0
42870480879,after,Selective CI markers,1,0,0,0
42866299112,after,Detect changed paths,0,3,17,0
42866299112,after,Backend static checks + isolated tails,0,2,75,353
42866299112,after,Backend shard 2/8,0,2,25,0
42866299112,after,Backend shard 4/8,0,2,25,0
42866299112,after,Backend shard 7/8,0,5,25,0
42866299112,after,Backend shard 8/8,0,2,23,0
42866299112,after,Backend shard 6/8,0,3,26,0
42866299112,after,Backend shard 3/8,0,2,29,0
42866299112,after,Backend shard 5/8,0,2,27,0
42866299112,after,Backend shard 1/8,0,2,50,659
42866299112,after,Mobile gate,1,0,0,0
42866299112,after,Frontend gate,1,0,0,0
42866299112,after,Backend gate,0,2,3,0
42866299112,after,Selective CI markers,1,0,0,0
42857415939,after,Detect changed paths,0,2,17,0
42857415939,after,Frontend gate,0,2,52,358
42857415939,after,Backend static checks + isolated tails,0,2,49,263
42857415939,after,Backend shard 6/8,0,2,27,0
42857415939,after,Backend shard 2/8,0,2,59,255
42857415939,after,Backend shard 3/8,0,2,33,0
42857415939,after,Backend shard 7/8,0,2,25,0
42857415939,after,Backend shard 8/8,0,2,23,0
42857415939,after,Backend shard 4/8,0,2,24,0
42857415939,after,Backend shard 1/8,0,2,54,599
42857415939,after,Backend shard 5/8,0,2,26,0
42857415939,after,Mobile gate,1,0,0,0
42857415939,after,Backend gate,0,2,3,0
42857415939,after,Selective CI markers,1,0,0,0
42855297639,after,Detect changed paths,0,2,14,0
42855297639,after,Backend static checks + isolated tails,0,3,56,302
42855297639,after,Backend shard 7/8,0,2,27,0
42855297639,after,Backend shard 5/8,0,2,25,0
42855297639,after,Backend shard 2/8,0,2,23,0
42855297639,after,Backend shard 1/8,0,2,53,73
42855297639,after,Backend shard 8/8,0,3,22,0
42855297639,after,Backend shard 6/8,0,3,23,0
42855297639,after,Backend shard 3/8,0,2,28,0
42855297639,after,Backend shard 4/8,0,2,35,0
42855297639,after,Frontend gate,1,0,0,0
42855297639,after,Mobile gate,1,0,0,0
42855297639,after,Backend gate,0,2,4,0
42855297639,after,Selective CI markers,1,0,0,0
42846766961,after,Detect changed paths,0,2,15,0
42846766961,after,Backend static checks + isolated tails,0,2,44,256
42846766961,after,Backend shard 2/8,0,2,24,0
42846766961,after,Backend shard 6/8,0,2,34,0
42846766961,after,Backend shard 1/8,0,2,52,53
42846766961,after,Backend shard 7/8,0,2,25,0
42846766961,after,Backend shard 4/8,0,1,25,0
42846766961,after,Backend shard 5/8,0,2,24,0
42846766961,after,Backend shard 8/8,0,2,28,0
42846766961,after,Backend shard 3/8,0,2,34,0
42846766961,after,Frontend gate,1,0,0,0
42846766961,after,Mobile gate,1,0,0,0
42846766961,after,Backend gate,0,2,3,0
42846766961,after,Selective CI markers,1,0,0,0
42846361795,after,Detect changed paths,0,3,19,0
42846361795,after,Backend shard 3/8,0,30,52,1308
42846361795,after,Backend shard 4/8,0,29,49,521
42846361795,after,Backend shard 5/8,0,29,49,703
42846361795,after,Backend shard 1/8,0,29,46,709
42846361795,after,Backend shard 2/8,0,29,46,556
42846361795,after,Backend shard 7/8,0,30,47,882
42846361795,after,Backend shard 6/8,0,29,44,835
42846361795,after,Backend static checks + isolated tails,0,30,45,258
42846361795,after,Backend shard 8/8,0,30,54,703
42846361795,after,Mobile gate,1,0,0,0
42846361795,after,Frontend gate,1,0,0,0
42846361795,after,Backend gate,0,3,2,0
42846361795,after,Selective CI markers,1,0,0,0
42840310450,after,Detect changed paths,0,3,16,0
42840310450,after,Backend static checks + isolated tails,0,20,56,302
42840310450,after,Backend shard 5/8,0,19,46,1311
42840310450,after,Backend shard 4/8,0,20,54,925
42840310450,after,Backend shard 7/8,0,20,51,995
42840310450,after,Backend shard 6/8,0,20,55,863
42840310450,after,Backend shard 8/8,0,20,67,985
42840310450,after,Backend shard 3/8,0,20,47,1198
42840310450,after,Backend shard 2/8,0,20,47,984
42840310450,after,Backend shard 1/8,0,20,51,1235
42840310450,after,Frontend gate,1,0,0,0
42840310450,after,Mobile gate,1,0,0,0
42840310450,after,Backend gate,0,1,3,0
42840310450,after,Selective CI markers,1,0,0,0
42836859756,after,Detect changed paths,0,2,15,0
42836859756,after,Backend static checks + isolated tails,0,2,49,381
42836859756,after,Backend shard 5/8,0,2,25,0
42836859756,after,Backend shard 4/8,0,2,25,0
42836859756,after,Backend shard 6/8,0,2,24,0
42836859756,after,Backend shard 2/8,0,2,25,0
42836859756,after,Backend shard 1/8,0,2,49,68
42836859756,after,Backend shard 3/8,0,2,26,0
42836859756,after,Backend shard 7/8,0,2,25,0
42836859756,after,Backend shard 8/8,0,1,22,0
42836859756,after,Mobile gate,1,0,0,0
42836859756,after,Frontend gate,1,0,0,0
42836859756,after,Backend gate,0,2,3,0
42836859756,after,Selective CI markers,1,0,0,0
42833998992,after,Detect changed paths,0,2,17,0
42833998992,after,Backend static checks + isolated tails,0,2,53,301
42833998992,after,Backend shard 1/8,0,2,52,68
42833998992,after,Backend shard 6/8,0,1,27,0
42833998992,after,Backend shard 8/8,0,2,24,0
42833998992,after,Backend shard 5/8,0,2,25,0
42833998992,after,Backend shard 3/8,0,2,26,0
42833998992,after,Backend shard 2/8,0,2,22,0
42833998992,after,Backend shard 4/8,0,2,23,0
42833998992,after,Backend shard 7/8,0,2,28,0
42833998992,after,Mobile gate,1,0,0,0
42833998992,after,Frontend gate,1,0,0,0
42833998992,after,Backend gate,0,2,4,0
42833998992,after,Selective CI markers,1,0,0,0
42824718659,after,Detect changed paths,0,2,13,0
42824718659,after,Backend static checks + isolated tails,0,1,48,294
42824718659,after,Backend shard 4/8,0,2,22,0
42824718659,after,Backend shard 1/8,0,2,43,41
42824718659,after,Backend shard 8/8,0,1,22,0
42824718659,after,Backend shard 3/8,0,2,23,0
42824718659,after,Backend shard 5/8,0,1,22,0
42824718659,after,Backend shard 7/8,0,1,23,0
42824718659,after,Backend shard 2/8,0,2,24,0
42824718659,after,Backend shard 6/8,0,2,25,0
42824718659,after,Mobile gate,1,0,0,0
42824718659,after,Frontend gate,1,0,0,0
42824718659,after,Backend gate,0,2,3,0
42824718659,after,Selective CI markers,1,0,0,0
42824337495,after,Detect changed paths,0,2,17,0
42824337495,after,Frontend gate,0,2,47,340
42824337495,after,Backend gate,0,2,4,0
42824337495,after,Mobile gate,1,0,0,0
42824337495,after,Backend static checks + isolated tails,1,0,0,0
42824337495,after,Backend shard ${{ matrix.shard }}/${{ strategy.job-total }},1,0,0,0
42824337495,after,Selective CI markers,1,0,0,0
42823060393,after,Detect changed paths,0,2,13,0
42823060393,after,Backend shard 5/8,0,2,55,882
42823060393,after,Backend shard 1/8,0,3,46,1094
42823060393,after,Backend shard 4/8,0,2,47,874
42823060393,after,Backend shard 3/8,0,2,47,1294
42823060393,after,Backend shard 7/8,0,2,51,695
42823060393,after,Backend shard 2/8,0,2,48,573
42823060393,after,Backend shard 8/8,0,2,63,688
42823060393,after,Backend shard 6/8,0,2,48,714
42823060393,after,Backend static checks + isolated tails,0,3,53,378
42823060393,after,Mobile gate,1,0,0,0
42823060393,after,Frontend gate,1,0,0,0
42823060393,after,Backend gate,0,2,3,0
42823060393,after,Selective CI markers,1,0,0,0
42819323884,after,Detect changed paths,0,1,12,0
42819323884,after,Backend static checks + isolated tails,0,2,47,301
42819323884,after,Backend shard 3/8,0,2,44,1290
42819323884,after,Backend shard 2/8,0,2,48,919
42819323884,after,Backend shard 6/8,0,2,44,963
42819323884,after,Backend shard 8/8,0,2,53,692
42819323884,after,Backend shard 5/8,0,2,49,1142
42819323884,after,Backend shard 1/8,0,2,52,1037
42819323884,after,Backend shard 4/8,0,2,54,698
42819323884,after,Backend shard 7/8,0,2,52,947
42819323884,after,Mobile gate,1,0,0,0
42819323884,after,Frontend gate,1,0,0,0
42819323884,after,Backend gate,0,2,4,0
42819323884,after,Selective CI markers,1,0,0,0
42809525504,after,Detect changed paths,0,2,13,0
42809525504,after,Mobile gate,1,0,0,0
42809525504,after,Backend gate,0,2,4,0
42809525504,after,Frontend gate,1,0,0,0
42809525504,after,Backend static checks + isolated tails,1,0,0,0
42809525504,after,Backend shard ${{ matrix.shard }}/${{ strategy.job-total }},1,0,0,0
42809525504,after,Selective CI markers,1,0,0,0
42799223801,after,Detect changed paths,0,2,12,0
42799223801,after,Backend static checks + isolated tails,0,3,56,385
42799223801,after,Backend shard 7/8,0,3,50,948
42799223801,after,Backend shard 8/8,0,3,53,926
42799223801,after,Backend shard 4/8,0,3,44,522
42799223801,after,Backend shard 2/8,0,3,52,934
42799223801,after,Backend shard 3/8,0,3,53,1317
42799223801,after,Backend shard 1/8,0,3,54,809
42799223801,after,Backend shard 6/8,0,2,44,1087
42799223801,after,Backend shard 5/8,0,3,44,1091
42799223801,after,Frontend gate,1,0,0,0
42799223801,after,Mobile gate,1,0,0,0
42799223801,after,Backend gate,0,3,3,0
42799223801,after,Selective CI markers,1,0,0,0
42794845487,after,Detect changed paths,0,3,15,0
42794845487,after,Backend shard 6/8,0,3,58,927
42794845487,after,Backend shard 4/8,0,2,46,825
42794845487,after,Backend static checks + isolated tails,0,2,45,253
42794845487,after,Backend shard 5/8,0,3,58,1230
42794845487,after,Backend shard 8/8,0,2,45,1000
42794845487,after,Backend shard 7/8,0,3,50,931
42794845487,after,Backend shard 3/8,0,2,48,967
42794845487,after,Backend shard 2/8,0,3,45,1051
42794845487,after,Backend shard 1/8,0,2,50,879
42794845487,after,Frontend gate,1,0,0,0
42794845487,after,Mobile gate,1,0,0,0
42794845487,after,Backend gate,0,2,4,0
42794845487,after,Selective CI markers,1,0,0,0
42792469552,after,Detect changed paths,0,2,15,0
42792469552,after,Backend shard 6/8,0,2,22,0
42792469552,after,Backend shard 8/8,0,2,27,0
42792469552,after,Backend shard 5/8,0,2,23,0
42792469552,after,Backend static checks + isolated tails,0,3,56,377
42792469552,after,Backend shard 3/8,0,2,23,0
42792469552,after,Backend shard 4/8,0,3,29,0
42792469552,after,Backend shard 2/8,0,2,23,0
42792469552,after,Backend shard 1/8,0,2,44,42
42792469552,after,Backend shard 7/8,0,2,25,0
42792469552,after,Mobile gate,1,0,0,0
42792469552,after,Frontend gate,1,0,0,0
42792469552,after,Backend gate,0,3,4,0
42792469552,after,Selective CI markers,1,0,0,0
42788756499,after,Detect changed paths,0,2,11,0
42788756499,after,Backend static checks + isolated tails,0,3,54,302
42788756499,after,Backend shard 6/8,0,3,25,0
42788756499,after,Backend shard 7/8,0,3,23,0
42788756499,after,Backend shard 2/8,0,3,44,376
42788756499,after,Backend shard 5/8,0,3,25,0
42788756499,after,Backend shard 4/8,0,3,26,0
42788756499,after,Backend shard 8/8,0,3,25,0
42788756499,after,Backend shard 1/8,0,3,49,321
42788756499,after,Backend shard 3/8,0,3,22,0
42788756499,after,Mobile gate,1,0,0,0
42788756499,after,Frontend gate,1,0,0,0
42788756499,after,Backend gate,0,2,3,0
42788756499,after,Selective CI markers,1,0,0,0
42787001489,after,Detect changed paths,0,2,12,0
42787001489,after,Backend shard 8/8,0,2,45,20
42787001489,after,Backend static checks + isolated tails,0,2,46,61
42787001489,after,Backend shard 3/8,0,3,55,34
42787001489,after,Backend shard 5/8,0,2,43,26
42787001489,after,Backend shard 1/8,0,2,48,33
42787001489,after,Backend shard 6/8,0,2,46,34
42787001489,after,Backend shard 7/8,0,2,45,34
42787001489,after,Backend shard 4/8,0,3,51,35
42787001489,after,Backend shard 2/8,0,2,45,24
42787001489,after,Mobile gate,1,0,0,0
42787001489,after,Frontend gate,1,0,0,0
42787001489,after,Backend gate,0,3,4,0
42787001489,after,Selective CI markers,1,0,0,0
42785996198,after,Detect changed paths,0,3,14,0
42785996198,after,Backend static checks + isolated tails,0,3,51,90
42785996198,after,Backend shard 6/8,0,3,58,25
42785996198,after,Backend shard 7/8,0,3,46,33
42785996198,after,Backend shard 2/8,0,3,44,33
42785996198,after,Backend shard 3/8,0,3,48,34
42785996198,after,Backend shard 8/8,0,3,50,27
42785996198,after,Backend shard 1/8,0,3,44,23
42785996198,after,Backend shard 5/8,0,3,53,26
42785996198,after,Backend shard 4/8,0,3,41,21
42785996198,after,Mobile gate,1,0,0,0
42785996198,after,Frontend gate,1,0,0,0
42785996198,after,Backend gate,0,2,4,0
42785996198,after,Selective CI markers,1,0,0,0
42783310231,after,Detect changed paths,0,3,18,0
42783310231,after,Backend static checks + isolated tails,0,3,46,53
42783310231,after,Backend shard 4/8,0,2,46,27
42783310231,after,Backend shard 2/8,0,2,44,21
42783310231,after,Backend shard 7/8,0,3,50,28
42783310231,after,Backend shard 1/8,0,3,44,34
42783310231,after,Backend shard 8/8,0,3,49,32
42783310231,after,Backend shard 5/8,0,2,43,26
42783310231,after,Backend shard 6/8,0,2,43,33
42783310231,after,Backend shard 3/8,0,3,49,34
42783310231,after,Mobile gate,1,0,0,0
42783310231,after,Frontend gate,1,0,0,0
42783310231,after,Backend gate,0,3,2,0
42783310231,after,Selective CI markers,1,0,0,0
42782657658,after,Detect changed paths,0,2,12,0
42782657658,after,Backend shard 4/8,0,3,54,612
42782657658,after,Backend shard 6/8,0,3,58,1095
42782657658,after,Backend static checks + isolated tails,0,3,48,262
42782657658,after,Backend shard 2/8,0,3,49,634
42782657658,after,Backend shard 3/8,0,3,43,712
42782657658,after,Backend shard 8/8,0,3,46,681
42782657658,after,Backend shard 1/8,0,3,55,859
42782657658,after,Backend shard 5/8,0,3,41,594
42782657658,after,Backend shard 7/8,0,3,51,910
42782657658,after,Mobile gate,1,0,0,0
42782657658,after,Frontend gate,1,0,0,0
42782657658,after,Backend gate,0,3,3,0
42782657658,after,Selective CI markers,1,0,0,0
42782655508,after,Detect changed paths,0,8,14,0
42782655508,after,Backend shard 1/8,0,2,45,1189
42782655508,after,Backend static checks + isolated tails,0,3,48,382
42782655508,after,Backend shard 2/8,0,3,63,811
42782655508,after,Backend shard 4/8,0,3,48,925
42782655508,after,Backend shard 7/8,0,2,45,558
42782655508,after,Backend shard 8/8,0,2,46,1004
42782655508,after,Backend shard 5/8,0,2,46,913
42782655508,after,Backend shard 3/8,0,2,45,923
42782655508,after,Backend shard 6/8,0,3,50,1136
42782655508,after,Frontend gate,1,0,0,0
42782655508,after,Mobile gate,1,0,0,0
42782655508,after,Backend gate,0,3,4,0
42782655508,after,Selective CI markers,1,0,0,0
42777964575,after,Detect changed paths,0,2,15,0
42777964575,after,Backend shard 6/8,0,2,45,802
42777964575,after,Backend shard 3/8,0,2,46,951
42777964575,after,Backend static checks + isolated tails,0,2,46,295
42777964575,after,Backend shard 2/8,0,2,51,679
42777964575,after,Backend shard 4/8,0,3,48,624
42777964575,after,Backend shard 7/8,0,3,51,680
42777964575,after,Backend shard 8/8,0,3,53,916
42777964575,after,Backend shard 1/8,0,2,48,777
42777964575,after,Backend shard 5/8,0,3,54,980
42777964575,after,Frontend gate,1,0,0,0
42777964575,after,Mobile gate,1,0,0,0
42777964575,after,Backend gate,0,2,3,0
42777964575,after,Selective CI markers,1,0,0,0
42774664913,after,Detect changed paths,0,2,11,0
42774664913,after,Backend static checks + isolated tails,0,2,48,378
42774664913,after,Backend shard 7/8,0,2,56,1016
42774664913,after,Backend shard 5/8,0,2,41,599
42774664913,after,Backend shard 2/8,0,2,44,806
42774664913,after,Backend shard 8/8,0,2,45,980
42774664913,after,Backend shard 3/8,0,2,53,1068
42774664913,after,Backend shard 6/8,0,2,46,1204
42774664913,after,Backend shard 1/8,0,2,45,777
42774664913,after,Backend shard 4/8,0,2,45,516
42774664913,after,Frontend gate,1,0,0,0
42774664913,after,Mobile gate,1,0,0,0
42774664913,after,Backend gate,0,3,2,0
42774664913,after,Selective CI markers,1,0,0,0
42768093320,after,Detect changed paths,0,2,13,0
42768093320,after,Backend static checks + isolated tails,0,2,63,301
42768093320,after,Frontend gate,0,3,42,310
42768093320,after,Mobile gate,0,2,31,315
42768093320,after,Backend shard 7/8,0,2,47,947
42768093320,after,Backend shard 5/8,0,3,54,1102
42768093320,after,Backend shard 4/8,0,2,48,563
42768093320,after,Backend shard 2/8,0,3,50,955
42768093320,after,Backend shard 1/8,0,3,48,995
42768093320,after,Backend shard 6/8,0,2,43,1086
42768093320,after,Backend shard 3/8,0,2,46,816
42768093320,after,Backend shard 8/8,0,2,46,555
42768093320,after,Backend gate,0,2,3,0
42768093320,after,Selective CI markers,1,0,0,0
42767995086,after,Detect changed paths,0,2,16,0
42767995086,after,Frontend gate,0,2,46,337
42767995086,after,Backend shard 1/8,0,2,41,732
42767995086,after,Backend shard 3/8,0,2,50,1214
42767995086,after,Backend shard 6/8,0,2,44,636
42767995086,after,Backend static checks + isolated tails,0,2,57,296
42767995086,after,Backend shard 5/8,0,2,50,936
42767995086,after,Backend shard 8/8,0,2,51,711
42767995086,after,Backend shard 4/8,0,3,59,681
42767995086,after,Backend shard 2/8,0,2,64,828
42767995086,after,Backend shard 7/8,0,2,42,944
42767995086,after,Mobile gate,1,0,0,0
42767995086,after,Backend gate,0,2,3,0
42767995086,after,Selective CI markers,1,0,0,0
42763939165,after,Detect changed paths,0,2,16,0
42763939165,after,Backend static checks + isolated tails,0,2,47,25
42763939165,after,Backend shard 6/8,0,2,49,1086
42763939165,after,Backend shard 4/8,0,2,52,635
42763939165,after,Backend shard 7/8,0,2,51,930
42763939165,after,Backend shard 1/8,0,2,49,958
42763939165,after,Backend shard 8/8,0,2,48,818
42763939165,after,Backend shard 3/8,0,2,52,1198
42763939165,after,Backend shard 2/8,0,2,46,679
42763939165,after,Backend shard 5/8,0,2,59,849
42763939165,after,Mobile gate,1,0,0,0
42763939165,after,Frontend gate,1,0,0,0
42763939165,after,Backend gate,0,2,3,0
42763939165,after,Selective CI markers,1,0,0,0
```

## Push runs on main

Medians in seconds over the jobs that ran (a skipped job is not in a median). "before"/"after" = before/after T-1614.

| Job | runs before | runs after | skipped after | wait before | wait after | set-up before | set-up after | tests before | tests after |
|---|---|---|---|---|---|---|---|---|---|
| Backend gate | 7 | 23 | 0 | 2 | 2 | 3 | 3 | 0 | 0 |
| Backend static checks + isolated tails | 7 | 23 | 0 | 2 | 2 | 53 | 47 | 377 | 310 |
| Detect changed paths | 7 | 23 | 0 | 3 | 2 | 14 | 14 | 0 | 0 |
| Frontend gate | 7 | 5 | 18 | 2 | 2 | 44 | 37 | 279 | 260 |
| Mobile gate | 7 | 3 | 20 | 2 | 2 | 34 | 35 | 386 | 294 |
| Selective CI markers | 7 | 23 | 0 | 2 | 2 | 14 | 14 | 0 | 0 |
| Backend shard 1/8 | 7 | 23 | 0 | 2 | 2 | 51 | 49 | 483 | 800 |
| Backend shard 2/8 | 7 | 23 | 0 | 2 | 2 | 49 | 47 | 338 | 635 |
| Backend shard 3/8 | 7 | 23 | 0 | 2 | 2 | 23 | 43 | 0 | 924 |
| Backend shard 4/8 | 7 | 23 | 0 | 2 | 2 | 27 | 44 | 0 | 697 |
| Backend shard 5/8 | 7 | 23 | 0 | 2 | 2 | 25 | 43 | 0 | 696 |
| Backend shard 6/8 | 7 | 23 | 0 | 2 | 2 | 22 | 44 | 0 | 771 |
| Backend shard 7/8 | 7 | 23 | 0 | 2 | 2 | 29 | 43 | 0 | 577 |
| Backend shard 8/8 | 7 | 23 | 0 | 2 | 2 | 27 | 46 | 0 | 726 |

- Runs: 7 before, 23 after.
- Job-minutes per run, median: before 36.4, after 130.9.
- Wall time per run (run updated_at minus created_at), median seconds: before 1200.0, after 1055.0.

Read with the strata (job-minutes, wall seconds; medians; same 30 runs): full runs before T-1614: 3 runs, 147.3
job-min, 1263 s; full runs after: 13 runs, 143.4 job-min, 1457 s; selective runs before: 4 runs, 34.8 job-min, 570 s;
selective runs after: 10 runs, 21.1 job-min (range 10.6 to 30.2), 471 s. The 130.9 vs 36.4 in the totals above is
therefore a change of mix (13 of 23 "after" runs are full, 3 of 7 "before" runs), not a cost increase.

## Merge-group runs

All 30 runs are after T-1617, so only the "after" columns are filled ("-" = no run).

| Job | runs before | runs after | skipped after | wait before | wait after | set-up before | set-up after | tests before | tests after |
|---|---|---|---|---|---|---|---|---|---|
| Backend gate | 0 | 30 | 0 | - | 2 | - | 3 | - | 0 |
| Backend static checks + isolated tails | 0 | 27 | 3 | - | 2 | - | 49 | - | 301 |
| Detect changed paths | 0 | 30 | 0 | - | 2 | - | 15 | - | 0 |
| Frontend gate | 0 | 4 | 26 | - | 2 | - | 46 | - | 338 |
| Mobile gate | 0 | 1 | 29 | - | 2 | - | 31 | - | 315 |
| Selective CI markers | 0 | 0 | 30 | - | - | - | - | - | - |
| Backend shard ${{ matrix.shard }}/${{ strategy.job-total }} | 0 | 0 | 3 | - | - | - | - | - | - |
| Backend shard 1/8 | 0 | 27 | 0 | - | 2 | - | 49 | - | 709 |
| Backend shard 2/8 | 0 | 27 | 0 | - | 2 | - | 45 | - | 556 |
| Backend shard 3/8 | 0 | 27 | 0 | - | 2 | - | 46 | - | 712 |
| Backend shard 4/8 | 0 | 27 | 0 | - | 2 | - | 45 | - | 516 |
| Backend shard 5/8 | 0 | 27 | 0 | - | 2 | - | 43 | - | 594 |
| Backend shard 6/8 | 0 | 27 | 0 | - | 2 | - | 44 | - | 636 |
| Backend shard 7/8 | 0 | 27 | 0 | - | 2 | - | 45 | - | 558 |
| Backend shard 8/8 | 0 | 27 | 0 | - | 2 | - | 45 | - | 555 |

- Runs: 0 before, 30 after.
- Job-minutes per run, median: before -, after 27.5.
- Wall time per run (run updated_at minus created_at), median seconds: before -, after 710.0.

Strata (job-min, wall seconds; medians): full runs 17, 127.8 job-min, 1279 s; selective runs 13, 11.4 job-min, 410 s
(range 0.3 to 31.1 job-min).

Docs-only runs (step "Run docs tests (docs-only change)" of job Backend shard 1/8 has a conclusion other than
skipped): before T-1617: 0 runs; after T-1617: 6 runs. Step seconds for those: median 60, max
659 (run 42866299112; the other five took 41 to 68 s). No before-T-1617 figure exists in this
population; the baseline note recorded merge groups that timed out (`timeout 2400`), and none of the 30 runs here did.

Runs with conclusion failure (4 of 30; none ended with a timeout, exit 124):

- 42787001489: Backend shards 1/8 to 8/8 step "Run test shard", Backend static checks + isolated tails step "Run isolated
  tails (mix letflow.check.test --tails-only)", Backend gate step "Aggregate backend legs (fail closed)". Job log
  129730756435 (shard 1/8): `Ecto.MigrationError ... migration version 20261110300001 is duplicated`, then
  `Process completed with exit code 1`. Not 124.
- 42785996198: same jobs and steps; log 129727335356 shows the same duplicate migration error, exit code 1. Not 124.
- 42783310231: same jobs and steps; log 129718463696 shows the same duplicate migration error, exit code 1. Not 124.
  (These three are consecutive attempts of queue entry pr-4158; a content fault of that change, not a CI cost.)
- 42763939165: Backend static checks + isolated tails step "Run static checks (mix letflow.check.static)"; shards 1/8,
  2/8, 4/8 step "Run test shard"; Backend gate. Log 129655990445 (shard 1/8) ends `Result: 717/718 passed` at
  `test/mix/tasks/letflow_check_deferral_staleness_test.exs:1273`, exit code 1. Not 124. The log of the static-checks
  step (129655990356) shows exit code 1; its cause was not examined.

## What the batch-4 cuts moved

Baseline (`docs/status/ci-minutes-20261110.md`): full push run about 141 job-min; docs-only selective run 22-33
job-min; Frontend gate median 338 s, Mobile gate 403 s, static + tails 401 s, shards 758 to 1144 s.

**T-1614 (frontend and mobile gates follow the path rules on push to main).** Moved: after T-1614 the Frontend gate
was skipped in 18 of 23 push runs and the Mobile gate in 20 of 23 (it ran 5 and 3 times); before T-1614 both ran in
all 7 runs. A skipped gate costs 0 instead of a median of about 339 s (Frontend: 2 + 43 + 294) and 416 s (Mobile:
2 + 34 + 380) as measured in this note, together about 12.6 job-min per run that now skips both. Selective push runs
fell from 34.8 job-min (4 runs) to 21.1 (10 runs), minus 13.7 job-min, and from 570 s to 471 s wall, minus 99 s.
The "before" side of this comparison rests on 4 runs, so the saving is not settled; it is consistent in size with the
baseline's estimate of 10.6 job-min. Not moved: full runs (141 baseline, 143.4 now, 13 runs), because they run every
gate.

**T-1617 (docs-only mode runs only the selected docs tests).** Not measurable as a before/after: 0 of the 30
merge-group runs are before it. What can be said: 6 docs-only merge groups ran the step in a median of 60 s (max 659
s), and none of the 30 runs timed out. The comparison rests on 0 runs before and 6 after, so no saving is given as
settled.

**Not moved** by either cut: shard times. Full runs (30 runs: 13 push after T-1614 plus 17 merge-group; seconds,
median / max of the job duration): shard 1/8 1000 / 1343; 2/8 890 / 1196; 3/8 1214 / 1645; 4/8 830 / 1071; 5/8 972 /
1357; 6/8 1014 / 1260; 7/8 796 / 1072; 8/8 795 / 1055. Shard 3 is still the slowest (baseline median 1144 s); the
spread between slowest and fastest median is 419 s. Static + tails: set-up 49 s plus tests 302 s (baseline 401 s
job duration; 351 s here). These populations are not the same as the baseline's, so a difference of tens of seconds is
not a finding.

## Remaining cuts, ranked

Savings are per run of the kind named in the cell, derived from numbers above or from the step medians of the 60 runs
(checkout 9 s median over 630 job steps; Elixir/Rust/cache set-up steps about 6 + 8 + 8 + 1 = 23 s median per heavy
job over 359 job steps). Order is by job-minutes saved per run, largest first; the kinds of run differ, so compare
within the kind.

| Rank | Cut | Measured saving | Affects a required check | Costs money | Source |
|---|---|---|---|---|---|
| 1 | Skip the backend_static isolated tails on selective (docs-only) runs (baseline proposal 4) | Up to 5.9 job-min per selective run (49 s set-up + 302 s tests = 351 s of one job); wall: not measured (critical path not checked) | No (the Backend gate still reports); but the register checks run in this job and the baseline said they must run; not shown safe | No | baseline "Proposals not applied" 4; this note, Push runs on main |
| 2 | Share Elixir/Rust/cache set-up between the heavy jobs (baseline proposal 3) | Up to 3.5 job-min per full run (about 23 s x 9 heavy jobs = 207 s; a ceiling, the cache restore cannot go to 0); wall: about 0 s | No | No | baseline 3; step medians above |
| 3 | Shallow checkout (baseline proposal 2) | Up to 2.1 job-min per run (9 s x 14 jobs = 126 s; a ceiling, a shallow clone would save only part); wall: 0 to 9 s; unverified against history-reading tests | No | No | baseline 2; step medians above |
| 4 | Re-balance `test/shard_manifest.txt` for 8 shards (baseline proposal 1) | 0 job-min (the same tests run); wall: about 275 s per full run (slowest shard median 1214 s against 939 s, the mean of the eight shard medians; a ceiling) | No | No | baseline 1; Full-run shard figures above |
| 5 | Bigger or paid runners; more shards or parallel jobs (baseline proposal 5) | Not measured (no run exists on such a runner in the 60 runs) | No | Yes | baseline 5 |

Rule: no row removes, renames or stops reporting "Backend gate (mix letflow.check)" or "Frontend gate (npm run check)";
a cut that would is not listed. No further cut with a measured saving appeared in the new numbers: the Frontend and
Mobile gates are already skipped in most runs, and the small jobs (Detect changed paths, Backend gate, Selective CI
markers) cost 14 s of set-up or less each.

## Owner decisions

Candidate for task 2 of `docs/uat/ba-decisions/T-1631.md` item 7 (one later change): rank 1 among the cuts that cost
no money, "skip the isolated tails on selective runs", measured at up to 5.9 job-min per selective run. It is a
candidate only: the baseline said the register checks that run in this job must still run, so the change needs first a
proof of which checks the tails hold and that a selective run still runs them elsewhere; if that proof fails, the next
candidate is rank 4 (re-balance the shards, about 275 s of wall per full run, no minutes saved). This note applies
nothing and answers none of the questions.

Open owner question (costs money): bigger or paid runners, more shards or more parallel jobs (rank 5). Saving: not
measured; the cost is the owner's to weigh (T-1631 item 7).
