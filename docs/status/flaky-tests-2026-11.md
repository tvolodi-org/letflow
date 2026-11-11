# Flaky test sweep, 2026-11 (T-1735)

Scope: the last 60 `CI` workflow runs on `main` with event `push`
(`gh run list --branch main --event push --workflow CI --limit 60`), run ids 42983525653 down to the
oldest of the 60 (created 2026-11-10 09:47 UTC; newest 2026-11-11 07:59 UTC, so the window is about 22 h).
A run counts when its first attempt failed and a later attempt (or the next commit) passed. Failed jobs
were read with `gh api --allow-escape-sequences repos/tvolodi-org/letflow/actions/runs/<id>/attempts/1/jobs`
and `.../actions/jobs/<job>/logs`.

Runs in the window that are not green on attempt 1: 42979214619, 42935335935, 42920238113, 42912905618,
42844384750 (five of 60). Run 42981773906 named in the task is an event `schedule` run, not a push run, so
it is listed below as an extra and not counted in the push window.

## Table (push runs)

| Test | File | Count | Run / job | Failure | Status |
|---|---|---|---|---|---|
| `C3-a/b/c create per kind > write off: reason code, text required for other, exact body` | `web/src/modules/stock/__tests__/DocumentForm.oneSide.test.tsx` | 3 | 42912905618 (130168013478), 42920238113 (130193124279), 42935335935 (130244015231) | `Unable to find an element by [data-testid="document-form"]`, thrown by `form()` | already fixed on main before this sweep: a42871bae (#4205) moved the `form()` assertion before the final `save()`; a successful save navigates away. No failure in runs after it. |
| `Letflow.SignupProvisioningTest` "P1 verify over the real router starts the step ..." | `test/letflow/signup_provisioning_test.exs:82` | 1 | 42979214619 attempt 1 (130385518098) | `assert await_mail() == :ok` got `:timeout` | fixed here (test helper) |
| `Letflow.IdentityTest` "returns {:error, :expired} for a token whose expires_at has already passed" | `test/letflow/identity_test.exs:1095` | 1 | 42844384750 attempt 1 (129927966531, shard 2/8), head c9d1f6200 | the test minted the token with `expires_at` = now + 1 s (line 1098 of c9d1f6200); on a slow shard `create_token/3` saw it already in the past and returned `{:error, :expires_at_in_past}` (MatchError at the setup line) | already fixed on main by 688833da2 (T-1646, #4176: margin 1 s to 3600 s); this change goes further (see below) |
| `Letflow.Routers.EntitiesImportXlsxTest` "R4c: a row error is reported on its line while the other rows are written" | `test/letflow/routers/entities_import_xlsx_test.exs:178` | 1 (schedule run) | 42981773906 (130393723614, shard 3/8) | `refute conn.resp_body =~ "abc"` matched a random record id `f23c99fa-abc2-...` in the body | fixed here (test) |

The top 3 by count are tied after the first row (all 1), so this change fixes the one with count 3
(already fixed on main, nothing to add) and the three singletons named in the task.

## Causes and what changed

- **DocumentForm.oneSide write off (3):** test bug, fixed by a42871bae before this task. Nothing changed here.
- **SignupProvisioningTest P1 (1):** not a product race. `await_mail/1` waits for the mail task supervisor
  to be idle. Since B8#1a the verify step creates the Letflow tenant in-process, and the whole test takes
  3.8 to 4.1 s in passing runs (log lines `P1 verify over the real router ... (4073.5ms)` in the failed
  attempt and `(3823.0ms)` in the green attempt 2, job 130395357643), more than the helper's 3 s default
  cap. The helper returns as soon as the supervisor is idle, so the default cap is now 30 s; it only bounds
  a real hang. No sleep was added.
- **IdentityTest expired token (1):** a short-expiry race in the test, not product code. At the failing
  revision (c9d1f6200) the test used `DateTime.add(DateTime.utc_now(), 1, :second)` as `expires_at`.
  `validate_expires_at/1` in `lib/letflow/identity.ex` compares with `DateTime.utc_now()` at call time and
  the value was truncated to whole seconds, so on a slow shard the one-second window had already closed when
  `create_token/3` ran and it returned `:expires_at_in_past`. Commit 688833da2 (T-1646) widened the margin
  to 3600 s, after run 42844384750 (16:30 vs 15:26 UTC on 2026-11-10). This change removes the dependency
  entirely: the test mints the token without an expiry and forces the row into the past, so no expiry
  window is involved (the check itself has its own tests).
- **EntitiesImportXlsxTest R4c (1):** test bug. The response body carries random v4 record ids,
  and an id can contain the hex substring `abc`. The assertion now checks the error entry itself, not the whole body.
  The product behaviour (the rejected cell value is not echoed) is still checked.

## Not a flake in this window

Run 42935335935's backend part was green; only the frontend job failed (the DocumentForm row above).
The retries of 42920238113 and 42912905618 were also the DocumentForm test.

## Round 2 (T-1743): tests that "fail only on the shards"

Trigger: run 43001782266, Backend shard 2/8, `test/letflow/engine/cancel_lock_timeout_test.exs:392`
(T6, "set_config is the first statement after BEGIN"). Merge-group cycle lost on [main-fix] PR #4262.

**Finding: not cross-test interference.** The task text suspected an interleaved statement from another
async test or a background process. The failing job log (`gh api --allow-escape-sequences
repos/tvolodi-org/letflow/actions/jobs/130459527676/logs`) shows the captured list is exactly this
transaction's own statements: `begin`, `SELECT set_config('lock_timeout', $1, true)`, then the cancel
statements. The first-statement and bound-parameter assertions passed. The failing line was
`refute Enum.any?(stmts, &(&1 =~ "5000" or &1 =~ ~r/5s/))`: the committed tenant's schema name is random
hex, and this run's was `tenant_e4a9e5000d854599a66ebf090236700b`, which contains `5000`. Probability per run
is small (the 4-character substring `5000` appearing in a 32-char hex name; `5s` cannot occur in hex, it is a separate timeout-literal check) but not zero, which is why
it appears once and then "passes on re-run".

`PlatformTenantFixture.capture_repo_queries/1` already keeps only the calling process's events
(`handle_query_event/4` checks `self() == test_pid`, since telemetry runs the handler in the issuing process),
and the file is `async: false`, so there is nothing to filter further.

| file | change |
|---|---|
| `test/letflow/engine/cancel_lock_timeout_test.exs` | T6 now inspects the SQL with quoted identifiers removed (`value_in_sql?/1`, word-bounded `5s`); new test pins that a schema name containing `5000` is ignored while a spliced `'5000ms'` is still caught. |

Red proof: the old assertion fails on exactly the statement list above (CI log lines for run 43001782266);
the unit test of `value_in_sql?/1` uses that schema name. Product code: no race found.

**Other files named in the task:** identity_test expires_at, EntitiesImportXlsxTest R4c and
SignupProvisioningTest were fixed or diagnosed in the first section above; not touched again here.
XlsxStyleTest X3 was NOT investigated in this task (no failing log pulled, no cause verified, no change made);
it remains open for a follow-up.

**Telemetry/shared-name audit, not changed:** `Letflow.LockOrderHelpers.attach_error_handler/1` forwards
55P03/40P01 from any process in the VM to the attaching test; every user of it is `async: false`, so no
foreign test can run beside it. Left as is.
