# Performance check of the reads added since B2#10 (T-1692)

Same style as `pilot-volume-2026-11.md`: measure first, fix only what is clearly slow. Nothing was clearly slow, so
no `lib/` or migration change was made.

Test: `test/letflow/performance/new_reads_test.exs` (`@moduletag :new_reads_perf`, excluded by default in
`test/test_helper.exs`). Run on demand, local test stack only, never QA:

    MIX_TEST_PARTITION=<n> mix test --only new_reads_perf test/letflow/performance/new_reads_test.exs

Every read goes through the full `Letflow.Router` with a real bearer token (the platform operator's for the rollout
list, a `TENANT_ADMIN` token of an ordinary tenant for the rest). One run takes about 5 s. Each figure is the median / max
of 5 timed runs after one warm-up; milliseconds. Host: shared (12 CPU, 62 GB), PostgreSQL in docker compose
(`letflow-team`), 2026-11-11. Read the numbers as a bound, not a benchmark. The limits are this task's own assumptions
(no owner limit exists for these reads); the test prints OVER for a miss and asserts nothing about them.

## Data set (fixed, no randomness)

- Rollouts: 50 (the list cap, `@list_limit` in `Letflow.ModuleUpgrade.Fleet`), 3 outcomes each (three provisioned tenants),
  mixed statuses. This is the cap case; a real fleet has more tenants per rollout (see "Not covered").
- Replay: one real instance (definition START -> HUMAN_TASK -> END, created through `Engine.create/2`) plus 1000
  `NODE_ENTERED` events inserted straight into the tenant `events` table with consecutive sequence numbers. They are not
  written by the engine, so the append path is not measured, only the reads.
- Users import: an xlsx of 200 rows (`username`, `display_name`, `email`), posted to `/api/v1/identity/users/import`.
- Notifications: 200 stored for the caller (the per-user cap), list asked with `limit=100` (the maximum); the test asserts
  that 100 come back.

## Results

| id | read | what is timed | median / max ms | limit ms | verdict |
|---|---|---|---|---|---|
| R1 | `GET /platform-module-rollouts` | one request, 50 rollouts with 3 outcomes each | 3.8 / 4.4 | 500 | ok |
| T1 | `GET /instances/:id/timeline` | all pages of 200 until `next_cursor` is null (6 requests, as `useInstanceTimelineAll` does) | 39.8 / 50.1 | 2000 | ok |
| T2 | `GET /instances/:id/history?event_type=NODE_ENTERED` | all pages of 200 (as `useInstanceNodeEntries` does) | 40.0 / 42.7 | 2000 | ok |
| N1 | `GET /me/notifications?limit=100` | one request, 200 stored | 3.0 / 3.4 | 300 | ok |
| U1 | `POST /identity/users/import?dry_run=true` | 200 rows | 13.7 / 27.8 | 5000 | ok |
| U2 | `POST /identity/users/import` | 200 rows, all created (one run, not repeatable) | 500 / 500 | 15000 | ok |
| U3 | `POST /identity/users/import` again | same file, 200 rows `unchanged` | 24.4 / 33.1 | 15000 | ok |

A first run (before an assertion was added) gave the same picture: R1 3.4, T1 35.9, T2 38.2, N1 3.2, U1 12.6, U2 550, U3 19.5.

## Reading

- Every measured value is below its assumed limit. The margin differs: the real import is about 30x below (500 vs 15000 ms),
  the timeline walk about 50x (median 39.8 vs 2000 ms), the single-request reads 100x or more. The slowest is the real import (about 2.5 ms per created
  user, which includes the user insert, the login-directory entry and the audit entry of `Identity.create_user/2`).
- The replay reads are linear in the number of pages (about 6.5 ms per page of 200). The web hooks cap the walk at
  `MAX_TIMELINE_PAGES` (25) pages; the fixture holds 1003 events (`Engine.create/2` writes INSTANCE_STARTED and NODE_ENTERED for START and HUMAN_TASK, then the test adds 1000), which is 6 requests (5 full pages of 200 and a last page of 3).
- The notification list is bounded by design (cap 200 per user, limit at most 100) and its unread count is one aggregate.

## Not covered (what this does not say)

- Browser time of the replay screen (rendering 1000 entries, polling while the instance is ACTIVE: every 2 s, or every 5 s once more than three pages are loaded, as in `web/src/hooks/useInstances.ts`, which applies to this six-page set) is not measured
  here; this is the server side over HTTP-shaped calls through the router, without a socket.
- Rollout list with a large fleet: the outcome count per rollout is one row per tenant, and creating hundreds of
  provisioned tenants is too heavy for this test. The query is one grouped count over `rollout_id IN (50 ids)` with a
  plain index on `rollout_id` (migration `20261110100002`), so it grows with the sum of outcomes of the 50 newest rollouts only.
- Event append while an instance is running (the engine writing NODE_ENTERED) is not measured.
- Users import beyond 200 rows, and with an existing user base of many thousands: the one existing-users read is by the
  usernames of the file (`username IN (...)`, `existing_users/2` in `Letflow.Identity.UserImport`), not a scan of the table.
