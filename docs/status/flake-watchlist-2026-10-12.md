# Flake watchlist, 2026-10-12

Notes on test failures seen once that are NOT filed. A note here becomes a filing only when the same
failure recurs. Whoever sees a second occurrence files it and cites this note.

## TestParallelWatchdogDiagTest: "huge partition log: diagnostics stay bounded and respect the 300-column cap"

- File: test/scripts/test_parallel_watchdog_diag_test.exs:247
- Failure: the expected "approx tests finished: 4" line is missing from the partition's DIAG lines.
- Seen in: main run 38235738863 (main 28fcc928), shard 1 of 3, partition 2, seed 181618.
- Status: first occurrence. The supervisor's later rerun could not be read from the supervisor's
  side (GitHub unreachable). The later main run 38248622813 (after PR #2407, merged 7a66381e) passed all 8 jobs.
- Action (updated): NO LONGER "filed only on recurrence". It is covered by the family scope of ISS-1053 /
  Q-1053 / GH #2399, owner letflow-16 (in progress): all wall-clock-dependent tests in
  test/scripts/test_parallel_*_test.exs. Do not file it separately.

## Family: wall-clock-dependent tests in test/scripts/test_parallel_*_test.exs (covered by ISS-1053 / Q-1053 / GH #2399)

- test/scripts/test_parallel_watchdog_orphan_test.exs:339, "hung partition: the watchdog still TERMs it after the timeout": PR #2413 run 38265950635, shard 1 of 3, partition 3, load 11.1 on 4 cores; reran by letflow-16 and passed. First occurrence by name for this test.
- test/scripts/test_parallel_shard_test.exs:274 (recorded on ISS-1053): PR #2383 run 38263915020, shard 2 of 3; green on rerun.
- test/scripts/test_parallel_watchdog_diag_test.exs:247 (above): main run 38235738863.

## Refresh, 2026-11-11 (T-1747)

Scope: the three entries above, checked against the family fix `3a4ca1200` (merged 2026-10-13,
`fix(ISS-1053 / Q-1053, GH #2399): test_parallel_* timing-flake family ... (#2440)`). The entries above
still say "in progress" and "first occurrence"; they are stale: the family fix has merged and GH #2399 is
delivered by it. Method: `git log origin/main` over `test/scripts/test_parallel_*` since the fix, the
merge commit messages (which quote the CI evidence), and the flake sweep `flaky-tests-2026-11.md`. I did
not re-scan the job logs of every CI run since 2026-10-13, so "not seen" below means "no later commit,
issue-fix or sweep row cites it", not "proved absent in N runs".

| Entry | Recurred after `3a4ca1200`? | Evidence |
|---|---|---|
| `test_parallel_watchdog_diag_test.exs` "huge partition log: diagnostics stay bounded and respect the 300-column cap" (was :247, now :422) | Not seen under this name. A different test of the same file failed on 2026-11-09: "RC-E stale emit lock" (`mkdir-denied 150` vs 120, host DIAG block emitted twice on a starved runner), fixed in test only by b522d06bc (#4093). The 399-column interleave that the diag family showed was fixed by 7eea3e7ae (#2456). | `git log origin/main -- test/scripts/test_parallel_watchdog_diag_test.exs` |
| `test_parallel_watchdog_orphan_test.exs` "hung partition: the watchdog still TERMs it after the timeout" (now :533) | Not seen under this name. The same file's EXIT-trap test (then :321) failed at 40000 ms after the fix and took GH #2457: script fixes 9ec051373 (#2940, 2026-10-21) and 526838dc9 (#2983, 2026-10-21), the latter after six attempts; orphaned watchdog `sleep` was the cause. | `git log origin/main -- test/scripts/test_parallel_watchdog_orphan_test.exs`, commit bodies |
| `test_parallel_shard_test.exs` shard 2 of 3 (:274 then; the ready-file case, now "shard 2 of 3 under admission control cap 1 pairs the ready-file with the global index") | The test itself: not seen. The family recurred in the sibling "shard 3 of 3 with N=4 runs global partitions 9..12 of 12": main push run 40115295998 took 120 s against its 0.2 s siblings (one hang, cause not found), made diagnostic and limit-tightened by ae07cf45e (#3135, 2026-10-24, GH #2380). | commit body of ae07cf45e |

Reading: the watchlist's three exact tests did not recur by name, but the family (wall-clock-dependent
`test_parallel_*` tests) did, in three sibling tests, each already fixed or instrumented. The hang in the
shard 3 of 3 case has no found cause; a new occurrence there is a second one and is filed with a
citation of #3135. The three entries are closed as watchlist items.

### Flaky tests of November (from `flaky-tests-2026-11.md`, T-1735 and T-1743)

Window: 60 push runs on main, 2026-11-10 09:47 to 2026-11-11 07:59 UTC. Each is a test seen failing and
passing again; status as that note records it. A second occurrence is filed with a citation of this note.

| Test | File | Count | Cause (short) | Status |
|---|---|---|---|---|
| `C3-a/b/c create per kind > write off: reason code, text required for other, exact body` | `web/src/modules/stock/__tests__/DocumentForm.oneSide.test.tsx` | 3 | assertion after a save that navigates away | fixed by a42871bae (#4205) |
| `Letflow.SignupProvisioningTest` "P1 verify over the real router starts the step ..." | `test/letflow/signup_provisioning_test.exs` | 1 | `await_mail/1` cap 3 s, test takes about 4 s | helper cap raised to 30 s |
| `Letflow.IdentityTest` "returns {:error, :expired} ..." | `test/letflow/identity_test.exs` | 1 | token expiry one second ahead | fixed by 688833da2 (#4176), then test no longer uses an expiry window |
| `Letflow.Routers.EntitiesImportXlsxTest` "R4c: a row error is reported on its line ..." (schedule run) | `test/letflow/routers/entities_import_xlsx_test.exs` | 1 | random record id contained `abc` | assertion fixed |
| `Letflow.Engine.CancelLockTimeoutTest` T6 "set_config is the first statement after BEGIN" | `test/letflow/engine/cancel_lock_timeout_test.exs` | 1 | random tenant schema name contained `5000` | fixed in #4272 (round 2) |
| `XlsxStyleTest` X3 | not named in the sweep | not counted | not investigated | open, no failing log pulled; a second occurrence is filed |

### CI runner crash, not a test flake (T-1843, 2026-11-13)

| Item | Where | Count | Cause (short) | Status |
|---|---|---|---|---|
| `mix letflow.check test` aborted with `(ArgumentError)` in `:io.put_chars` while echoing the runner's output; shard 4/8 failed with 0 test failures (merge-group run 43376454978, PR #4364) | `lib/mix/tasks/letflow.check.test.ex`, `collect/2` | 1 | the echo used `IO.write/1`, which raises on a non-UTF-8 byte in the captured chunk; reproduced with a fake runner printing bytes 255 254 (`:no_translation`) | fixed in T-1843: `echo_chunk/1` uses `IO.binwrite/1` and swallows write errors; the captured bytes and exit status still decide the verdict (test "T-1843" in `letflow_check_test_test.exs`). A second occurrence is filed with a citation of this entry. |
