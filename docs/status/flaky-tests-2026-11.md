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
| `Letflow.IdentityTest` "returns {:error, :expired} for a token whose expires_at has already passed" | `test/letflow/identity_test.exs:1095` | 1 | 42844384750 attempt 1 (129927966531, shard 2/8) | `create_token/3` with `expires_at` now + 1 h returned `{:error, :expires_at_in_past}` (MatchError at the setup line) | fixed here (test no longer depends on that check) |
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
- **IdentityTest expired token (1):** the test minted a token with `expires_at` +3600 s and then moved the
  row into the past. `validate_expires_at/1` in `lib/letflow/identity.ex` compares with `DateTime.utc_now()`,
  so the only way to get `:expires_at_in_past` for +1 h is a clock jump of an hour or more on the runner between
  two adjacent lines. Not reproducible here. The test now mints without an expiry and forces the row into the
  past, so it no longer depends on that check (which has its own tests). If this recurs, the cause is the
  runner clock, not product code.
- **EntitiesImportXlsxTest R4c (1):** test bug. The response body carries random v4 record ids,
  and an id can contain the hex substring `abc`. The assertion now checks the error entry itself, not the whole body.
  The product behaviour (the rejected cell value is not echoed) is still checked.

## Not a flake in this window

Run 42935335935's backend part was green; only the frontend job failed (the DocumentForm row above).
The retries of 42920238113 and 42912905618 were also the DocumentForm test.
