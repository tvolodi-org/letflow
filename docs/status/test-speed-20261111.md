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
| 16 | test/letflow/modules/assets/xlsx_export_test.exs | 158.8 |
| 17 | test/letflow/modules/assets/kind_change_posting_test.exs | 158.0 |
| 18 | test/letflow/modules/stock/document_volume_posting_test.exs | 152.8 |
| 19 | test/letflow/modules/stock/opening_import_test.exs | 151.5 |
| 20 | test/letflow/modules/exam/session_test.exs | 151.3 |

Web: not measured per file, and this note does not claim a web ranking. The frontend gate runs the whole vitest suite
inside one `npm run check` job (median 338 s, see `ci-minutes-20261110.md`); the CI log prints per-file vitest times
only for failing files, and the machine rule forbids running the whole web suite by hand during a task. To get the
missing half, a follow-up task should add `--reporter=json --outputFile=<path>` (or the `verbose` reporter) to the
frontend gate's vitest call and upload the file as a CI artifact; the 20 slowest web files can then be ranked from
the next green run. No web cut is made here.

## What the files have in common

All 20 are `async: false` (checked with `grep -c "async: false"`; `DataCase` then puts the sandbox in shared mode).
Of the other 19 files, 10 call `setup_oidc!` (an OIDC fixture) and 18 call `setup_auto_mode!` or `:auto` (which
switches the sandbox from shared to `:auto` mode so committed tenants are visible to other connections); the others have their own tenant setup
(`voice_regression_test.exs` has no explicit auto switch). All provision committed tenants per test or
per describe (for example `stock/router_test.exs`: `S.setup_oidc!` + two `S.tenant!` per test, 31 tests). Their cost is
tenant provisioning, not waiting. `session_test.exs` is different: it has no OIDC setup (two `setup` blocks using
`ExamFixtures` only) and is the only one of the 20 with `Process.sleep` of real duration.

## Cuts applied (safe, one file)

`test/letflow/modules/exam/session_test.exs` slept for wall-clock time so the session's `started_at` was old enough for
the elapsed-seconds bound on `time_spent_seconds` (`bounded_time_spent/4` in `Letflow.Modules.Exam.Session`):
`Process.sleep(11_000)` + 2 x `Process.sleep(2_100)` = 15.2 s of pure sleeping per run. They now call
`backdate_session!/2`, which moves the session record's `started_at` into the past through
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
