# Flake watchlist, 2026-10-12

Notes on test failures seen once that are NOT filed. A note here becomes a filing only when the same
failure recurs. Whoever sees a second occurrence files it and cites this note.

## TestParallelWatchdogDiagTest: "huge partition log: diagnostics stay bounded and respect the 300-column cap"

- File: test/scripts/test_parallel_watchdog_diag_test.exs:247
- Failure: the expected "approx tests finished: 4" line is missing from the partition's DIAG lines.
- Seen in: main run 38235738863 (main 28fcc928), shard 1 of 3, partition 2, seed 181618.
- Status: first occurrence. The supervisor's later rerun could not be read from the supervisor's
  side (GitHub unreachable). The later main run 38248622813 (after PR #2407, merged 7a66381e) passed all 8 jobs.
- Action: NOT filed. If it recurs, file it as a LOW test-infrastructure flake, citing this note, the run
  id of the recurrence, and the seed.
