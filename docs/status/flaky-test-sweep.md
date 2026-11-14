# Flaky-by-design test sweep (T-1934, 2026-11-14)

A static read of `test/` (ExUnit) and `web/` (vitest, Playwright) for tests that depend on the real clock or the
time of day, on run order or shared state, or on machine load. The trigger was T-1919 (#4444): FleetTest's
`refute inspect(r.outcomes) =~ "13:00"` also matched real timestamps. No code was changed here. The operator queues the
fixes. Earlier sweeps from CI logs: `docs/status/flaky-tests-2026-11.md`, `docs/status/flake-watchlist-2026-10-12.md`.

One fact sets the order. `capture_log/2` output starts every line with the wall-clock time. Checked on this host
(Elixir 1.20.3): `ExUnit.CaptureLog.capture_log(fn -> Logger.error("x") end)` returns `"\n06:17:25.414 [error] x\n"`.
`config/*.exs` sets no `:default_formatter` format (`grep -rn 'config :logger' config/` finds only `level: :warning`
in `config/test.exs`). So a short digit string refuted against a captured log can match the time.

Size: S = one assertion or helper, under an hour. M = a test seam or a rewrite of one describe block.

## The list, most dangerous first

| # | File : line | Test | Why it is flaky | One-line fix | Size |
|---|---|---|---|---|---|
| 1 | `test/letflow/engine/ledger_failure_mapping_test.exs:198` | "T-ERR-3 … no quantity or slot value reaches the audit entry or the log of a refusal" | `refute log =~ "37"` runs on `capture_log([level: :info], …)` text. Every captured line starts with `HH:MM:SS.mmm`, so the check fails when a line is logged in minute 37 or second 37, or when its milliseconds contain `37`. That is about 5% per captured line. I did not check whether the 409 path logs a line; if it logs none, the check never fails and proves nothing. | Strip the time prefix before the check (or check only the message part of each line), and refute `"-37"`, the value actually posted. | S |
| 2 | `test/letflow/obs/alerts_test.exs:678` and `:769` | ISS-0558 exhaustion tests (instance-stuck and DLQ-depth) | Delivery runs in a fire-and-forget task (moduledoc of `lib/letflow/obs/alerts.ex`). The test sleeps a fixed `Process.sleep(200)` and then makes a positive check, `assert log =~ "alert delivery exhausted"`. The task has to finish two HTTP calls with backoff in that 200 ms, so the test fails on a loaded runner. | Wait for the outcome instead of sleeping: poll `AlertHookEmissionState`, or attach a log handler and `assert_receive` with a bounded timeout. | M |
| 3 | `test/letflow/engine/lua/executor_test.exs:345` (file is `async: true`) | the short-vs-long `timeout_ms` test | `assert short_elapsed_ms < 400` on a 100 ms wall-clock timeout of an infinite Lua loop. This is an absolute wall-time ceiling inside an async file that runs next to CPU-heavy tests. | Drop the absolute ceiling and keep the reason check `{:wallclock_timeout, 100}` and `long > short`, or compare against the long call (`short < long_elapsed - 200`). | S |
| 4 | `test/letflow/routers/tenant_config_test.exs:523` (file is `async: true`) | "ISS-0720: oidc_authority reflects configured :keycloak_base_url …" | Changes the VM-global `Application.put_env(:letflow, :oidc, …)` in an async module. Async tests in other modules that read `:keycloak_base_url` (`Letflow.Oidc.RealmProbe`, `Letflow.Routers.TenantConfig.idp_base_url`) can see `https://iss0720-regression-test-authority.example` while it runs. | Move the describe block into an `async: false` module (the other users of this pattern, such as `auth_pipeline_configurable_verifier_test.exs`, are already `async: false`). | S |
| 5 | `test/letflow/event_store_cold_append_lock_order_test.exs:436`, `:651` | lock-timeout bound tests | `assert elapsed < 1_500` for a `lock_timeout_ms: 300` wait. The file is `async: false`, but the shared runner (CI shard or the host's sibling tasks) can still stretch it. The 1.2 s of headroom is the smallest among the DB-wait ceilings found (others: `entity_writes_lock_order_test.exs:410` `< 8_000`, `external_ref_lock_timeout_test.exs:161` `< 20_000`). | Keep the lower bound (`>= 250`, the real point). Raise the ceiling only once a CI log shows a miss (per the CI-health rule, no blind raise); otherwise leave it as is. | S |
| 6 | `test/letflow/modules/stock/documents_router_test.exs:380`, `movements_document_number_test.exs:27`, `two_side_issue_test.exs:36`, `test/letflow/modules/stock/issue_writeoff_test.exs:237`, `test/letflow/routers/number_sequences_test.exs:133`, `test/letflow/number_sequences/allocator_test.exs:75` (A1) | document and record number "PFX-<year>-000001" | The expected year comes from `Date.utc_today().year` or `DateTime.utc_now().year` in the test. The server takes it from its own `DateTime.utc_now()` (`Letflow.NumberSequences.now/0`, UTC year via `period_for/2`). A run that crosses 00:00 UTC on 1 January fails. The window is narrow, but it is a calendar date, not chance. | Pin the clock the way `allocator_test.exs` A4b already does (`:number_sequences_clock`), or read the year from the response's own `issued_at`. | S each |
| 7 | `test/letflow/scope_enforcement_on_e2e_test.exs:311`, `:424` | "under shadow both routes are counted as requests …" | `requests.()` reads counts for `Date.utc_today()` before and after the requests. If the test crosses midnight UTC, the second read looks at a new day and the delta is wrong. `tenant_scope_enforcement_integrity_test.exs:283` already guards the same race with a retry when the day changed. | Take the day once, outside the closure, and retry when `Date.utc_today()` changed (the integrity test's pattern). | S |
| 8 | `test/letflow/modules/stock/count_paperwork_router_test.exs:278` | second download unchanged after a line update | `refute second.resp_body =~ "999"` runs on an xlsx file, a compressed zip. Random compressed bytes can contain `999` (rare), and the check cannot see the cell text anyway. Weak more than flaky. | Refute on the parsed sheet (`sheets(second.resp_body)["lines"]`), as the line above already does. | S |

## Checked and left off the list

- `test/letflow/routers/tenant_settings_test.exs:576` (`refute Jason.encode!(body) =~ "22:00"`): the public
  tenant-config body carries no timestamps. Its keys are `branding`, `client_id`, `oidc_authority` and `tenant_type`
  (`@expected_keys` in `tenant_config_test.exs`), so it cannot repeat the FleetTest bug.
  `test/letflow/identity/tenant_test.exs:451` checks a changeset error text, which also has no timestamps.
- Short numeric refutes on HTTP bodies (`grading_mark_test.exs` `"1.25"`/`"1.0"`, `entities_decimal_strict_*`
  `"99"`, `"987654"`): the bodies hold only hex/UUID ids and a hex trace id, so no time or `.` is involved.
  The `"7.25"`/`"3.5"` log refutes in `ledger/tenancy_test.exs:249-250` and `ledger/read_tenancy_test.exs:246`
  can match the `SS.mmm` part of the time prefix. The chance is about 0.1-1% per captured line. Apply the same fix
  as row 1 when row 1 is fixed (size S together).
- Global test clocks (`:stock_documents_clock`, `:assets_documents_clock`, `:number_sequences_clock`,
  `:authz_deny_log_clock`): every setter is in an `async: false` file, and each file clears the clock in `on_exit`.
- `mobile_tenant_config_test.exs` (async, `System.put_env("MOBILE_OIDC_CLIENT_ID")`): the only reader is
  `lib/letflow/routers/mobile_tenant_config.ex`, and it is tested only in that file, whose tests run one after another.
  `letflow.check_boundaries_test.exs` (async, injectable seam key with no other reader) is safe for the same reason.
- `Process.sleep(N)` followed by a "nothing was written" check (`identity_reset_password_test.exs`,
  `modules/exam/notifications_test.exs`, `notifications_test.exs`): these can pass wrongly but cannot fail by chance.
  They are not flaky. The other sleeps found are polling helpers with deadlines.
- Web unit tests: dates in screen text are rendered with an explicit tenant `timeZone` (`formatDateTimeInZone` in
  `web/src/i18n/format.ts`), so they do not depend on the host time zone. Tests built on `Date.now()`
  (`TaskInboxPage.gateb.test.tsx` "3 minutes ago", `ApiConnectivityBanner.test.tsx`) build their fixtures
  per test in `beforeEach`. Under load the gap stays well below a rounding step.
- Playwright: the only specs CI runs are `gate-b-stock`, `gate-b-stock-print` and `gate-b-relogin`
  (`.github/workflows/stock-e2e.yml`). The `waitForTimeout` calls in `gate-b-relogin` are a deliberate soak or settle
  time placed after a `expect.poll`. The 28 other specs that use `waitForTimeout` (most in `f2-canvas*.e2e.spec.ts`)
  do not run in CI.
- Fixed future dates in fixtures (lot expiry `2027-03-31`, etc.): `grep -rnE 'expir[a-z_]*.*(utc_today|Date\.compare|today)' lib/letflow/modules`
  finds no check against today, so they are not time bombs. The fixtures were spot-checked, not swept one by one.

## Commands behind the list

```
grep -rnE '=~ "[^"]*[0-9]{2}:[0-9]{2}' test --include=*.exs
grep -rnE 'refute [a-z_]*log[a-z_]* =~ "[0-9.:-]{1,5}"' test --include=*.exs
grep -rnE 'refute [^=]*(resp_body|body|inspect\([^)]*\)|log)[^=]* =~ "[0-9a-f]{2,5}"' test --include=*.exs
grep -rnE 'Date\.utc_today|utc_today\(\)\.year|utc_now\(\)\.year' test --include=*.exs
grep -rnE 'assert .*(System\.monotonic_time|elapsed|took|duration)[^=]* (<|<=) *[0-9_]+' test --include=*.exs
grep -rnE '^\s*(Process\.sleep|:timer\.sleep)\(' test --include=*.exs
for f in $(grep -rlE 'async: true' test --include=*.exs); do grep -nE 'Application\.put_env|System\.put_env|:persistent_term\.put' $f; done
grep -rnE 'Application\.put_env\(:letflow, :[a-z_]*clock' test
grep -rln 'waitForTimeout' web/tests web/src
```
