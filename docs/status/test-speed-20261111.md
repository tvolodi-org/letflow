# Test speed: the 20 slowest backend test files (T-1708, L-24), 2026-11-11

## Measurement

Source: the `test_parallel: partition N slowest:` module blocks ("Top 80 slowest") of the eight
`Backend shard K/8` jobs of `main` CI run 42963528478 (jobs 130335470632, 130335470654, 130335470677,
130335470686, 130335470689, 130335470690, 130335470735, 130335470777; fetched with
`gh api --allow-escape-sequences repos/tvolodi-org/letflow/actions/jobs/<id>/logs`). Module time is the sum of the
file's tests; a file appears in exactly one shard, so no averaging. One run only: runner speed varies about
+-25 % between jobs (see `ci-shard-balance-2026-10-26.md`), so read the numbers as an order of magnitude.

| # | File | CI s (before) |
|---|---|---|
| 1 | test/letflow/modules/stock/router_test.exs | 352.1 |
| 2 | test/letflow/module_upgrade/fleet_test.exs | 270.2 |
| 3 | test/letflow/modules/stock/documents_router_test.exs | 256.6 |
| 4 | test/letflow/modules/stock/voice_router_test.exs | 244.1 |
| 5 | test/letflow/modules/assets/opening_import_test.exs | 244.0 |
| 6 | test/letflow/modules/asset_stock_isolation_test.exs | 234.3 |
| 7 | test/letflow/modules/assets/documents_router_test.exs | 212.6 |
| 8 | test/scripts/demo_showroom_seed_test.exs | 210.8 |
| 9 | test/letflow/modules/assets/card_import_test.exs | 207.7 |
| 10 | test/letflow/modules/assets/opening_router_test.exs | 197.9 |
| 11 | test/letflow/modules/stock/voice_regression_test.exs | 195.0 |
| 12 | test/letflow/routers/admin_v1_test.exs | 185.9 |
| 13 | test/letflow/modules/assets/kinds_posting_test.exs | 176.1 |
| 14 | test/letflow/modules/assets/storekeeper_assets_test.exs | 166.5 |
| 15 | test/letflow/routers/onboarding_administrator_fields_test.exs | 165.9 |
| 16 | test/letflow/support/tenant_fixture_pool_test.exs | 163.3 |
| 17 | test/letflow/modules/assets/xlsx_export_test.exs | 158.8 |
| 18 | test/letflow/modules/assets/kind_change_posting_test.exs | 158.0 |
| 19 | test/letflow/modules/stock/document_volume_posting_test.exs | 152.8 |
| 20 | test/letflow/modules/stock/opening_import_test.exs | 151.5 |

## Web: 20 slowest vitest files

Measured from CI logs of `main` run 42963528478: the `Test Files ... passed` section of the frontend gate's
`npm run check` output (run under `CI=true`). File times are sorted from the JSON report included in the task
artifact (review-frontend.plain, lines 1040–1070). Time = file end minus file start, seconds, on CI runners.

| # | file | seconds | tests |
|---|------|---------|-------|
| 1 | web/src/modules/stock/__tests__/documentsErrors.test.tsx | 11.9 | 6 |
| 2 | web/src/dev/harness/__tests__/harness.build.test.ts | 9.2 | 1 |
| 3 | web/src/modules/stock/__tests__/DocumentForm.twoSides.test.tsx | 5.9 | 16 |
| 4 | web/src/components/layout/__tests__/navRoleWalk.test.tsx | 5.3 | 6 |
| 5 | web/src/hooks/__tests__/useInstanceNodeEntries.test.tsx | 4.9 | 5 |
| 6 | web/src/modules/assets/__tests__/DocumentForm.test.tsx | 4.8 | 15 |
| 7 | web/src/hooks/__tests__/useInstanceTimelineAll.test.tsx | 4.8 | 3 |
| 8 | web/src/components/instances/__tests__/InstanceReplay.test.tsx | 4.6 | 9 |
| 9 | web/src/modules/codes/__tests__/CodesPage.labels.test.tsx | 4.6 | 13 |
| 10 | web/src/modules/stock/__tests__/countsErrors.test.tsx | 4.0 | 45 |
| 11 | web/src/components/diagram/__tests__/DiagramEditPane.test.tsx | 3.9 | 15 |
| 12 | web/src/modules/stock/__tests__/DocumentForm.oneSide.test.tsx | 3.8 | 12 |
| 13 | web/src/modules/assets/__tests__/DocumentsPage.test.tsx | 3.8 | 14 |
| 14 | web/src/modules/stock/__tests__/DocumentPage.actions.test.tsx | 3.7 | 26 |
| 15 | web/src/modules/stock/__tests__/CountsPage.order.test.tsx | 3.7 | 23 |
| 16 | web/src/modules/stock/__tests__/MovementsPage.test.tsx | 3.6 | 36 |
| 17 | web/src/modules/stock/__tests__/CountsPage.posting.test.tsx | 3.3 | 20 |
| 18 | web/src/modules/stock/__tests__/DocumentPage.print.test.tsx | 2.9 | 28 |
| 19 | web/src/components/layout/__tests__/AppShell.candidate-nav.test.tsx | 2.9 | 6 |
| 20 | web/src/modules/stock/__tests__/CountsPage.sheet.test.tsx | 2.9 | 12 |

Safe-cut assessment: the web suite is flat. The slowest file is 11.9 s and from rank 7 on every file is under 5 s, so
no single file is worth a risky edit. The two largest are real work, not waiting: `documentsErrors.test.tsx` renders the full document screen per error case, and `harness.build.test.ts` runs a real `vite build` in a child process to prove the harness is absent from production output (cutting it would remove the check). `useInstanceNodeEntries` has `waitFor` timeouts of 4-5 s and a 2.5 s `setTimeout` at line 97 (a real wait inside the test); replacing it needs fake timers in a hook test that also covers the truncation path, a change with more risk than its 2.5 s gain. No web cut is made here; the real saving on the web side is in the shared setup of the stock and assets screen tests, which is a separate refactor.

## What the files have in common

The 20 slowest backend files: 19 call `setup_auto_mode!` or `:auto` (which switches the sandbox from shared to `:auto`
mode so committed tenants are visible to other connections) or have their own tenant setup; the new entrant
`tenant_fixture_pool_test.exs` does both (it powers the `TenantFixture` test building blocks and runs under `:auto`
mode). All 20 are `async: false` (checked with `grep -c "async: false"`; `DataCase` then puts the sandbox in shared mode). All provision committed tenants per test or per describe (for example `stock/router_test.exs`: `S.setup_oidc!` +
two `S.tenant!` per test, 31 tests). Their cost is tenant provisioning, not waiting. `session_test.exs` (rank 21,
now out of the top 20) was the only one with `Process.sleep` of real duration; that sleep is now replaced by record
backdating in this task.

## Cuts applied (safe, one file)

`test/letflow/modules/exam/session_test.exs` (rank 21, now out of top 20) slept for wall-clock time so the session's
`started_at` was old enough for the elapsed-seconds bound on `time_spent_seconds` (`bounded_time_spent/4` in
`Letflow.Modules.Exam.Session`): `Process.sleep(11_000)` + 2 x `Process.sleep(2_100)` = 15.2 s of pure sleeping per run. They now call `backdate_session!/2`, which moves the session record's `started_at` into the past through
`ExamFixtures.update_record!` (the ordinary `Records.update_record` path). The assertions are unchanged
(upsert not duplicate; stored value clamped to elapsed time, `>= 2`, `<= elapsed_now`, `< 999_999`; a later lower report
never lowers the stored value). No test deleted or weakened.

| | before | after |
|---|---|---|
| sleeping in the 3 tests (lower bound of their time) | >= 15.2 s | 0 s |
| the 3 tests, local run (`mix test ...:997` and the Q-1075 describe) | not run on the old code | 2.5 s + 3.7 s (includes tenant setup) |
| whole file, local, `MIX_TEST_PARTITION=1708` | CI 151.3 s (other machine) | 98.9 s, 83 passed |

The file itself saves at least 15.2 s of its own run time. The effect on a shard was not measured: a shard runs several
partitions and files, and only a before/after of the partition holding this file would show it, so no shard figure is
claimed.

## Not applied, and why

- `async: true` for the 19 other files: they start in shared sandbox mode (`async: false`), then their fixtures switch to `:auto`
  mode (`setup_auto_mode!`) and create committed tenants (`TenantFixture`); `letflow.check_async_sandbox_reachability` and the cluster-wide `pg_stat_activity` guards
  (TenantSchemaReaper) make this unsafe to flip blind. Proposal: flip one file per task and run it 3 times.
- Shared setup (`setup_all` for the OIDC fixture and tenants): tests in these files write into the tenant (documents,
  stock keys) and assert on totals, so sharing one tenant needs per-test cleanup design. Proposal: start with
  `stock/router_test.exs` (352 s, 31 tests, two tenants per test), where read-only tests can share a `setup_all` tenant.
- Remaining `Process.sleep` in `test/` (182 lines, mostly poller, notifications and worker tests): short waits on real
  processes, not safe to remove without a deterministic hook per case.

## Commands

- Ranking: the python reader in the task folder (`top20.tsv`, logs in `logs/`) over the module blocks above.
- Sleep count: `grep -rn "Process.sleep\|:timer.sleep" test | wc -l` (182).
