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
