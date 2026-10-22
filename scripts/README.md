# scripts/

Standalone helper scripts, not part of the `mix` build. Each is documented in its own
header comment; this file is the index plus the one entry (`mutate.py`) whose calling
convention downstream agents need without re-deriving it.

| Script | Purpose |
|---|---|
| `test_parallel.sh` | Runs the suite as N parallel `mix test --partitions N` processes. Q-1037: `TEST_PARALLEL_SHARD=K/M` (or `TEST_PARALLEL_TOTAL`/`TEST_PARALLEL_OFFSET`) runs only slice K of a TOTAL=N*M partition space (global partition numbers; N must match on every shard); default unchanged. See its header. |
| `timed_test.sh` | Times a `mix test` run. |
| `check_pr_gates.sh` | Read-only: exit 1 if a PR touching lib/ web/ apps/ priv/ test/ lacks a valid `## Gates` block (`<PR>` or `--body-file F --files F`); run by the supervisor before a merge slot; not wired into CI. `test_check_pr_gates.sh` is its self-test. |
| `uat_preflight.sh` | WF-05 Step 0: read-only preflight of a target environment against the UAT scenario corpus's PRECONDITIONS manifest; prints a scenario x check gap table; exit 1 means `ENV_NOT_READY`. Usage in its header comment. |
| `seed_uat_email_verified.sh` | UAT-only (GH #2503): sets `emailVerified` on the named seeded UAT test accounts via the Keycloak admin API, idempotent; `false` is the rollback. Refuses any non-QA IdP or non-UAT realm before a request. Credentials and the account list come from the environment (`.env.uat`), never from this file. See its header. |
| `seed_uat_email_verified_for_group.sh` | Acceptance seed step (GH #2503): reads the realm:username pairs a group's scenarios name under `UAT_EMAIL_VERIFIED_USERS), are exactly:` and runs the seed above with `true`. No pairs: no-op. Pairs but no `UAT_KC_ADMIN_CLIENT_ID/SECRET`: fails with one message. Called by `project/scripts/uat.sh seed`. |
| `mutate.py` | Single-occurrence substitution mutation-testing helper (apply mutant, run tests, report kill/survive, always revert). See below. |
| `seed_meridian_definition.sh`, `seed_vortex_definition.sh`, `seed_swiftroute_definition.sh` | Seed the QA ProcessDefinitions from `test/fixtures/qa/*.json` (create + activate). Sources `lib/seed_service_task_base.sh`. See "QA seed scripts" below. |

## QA seed scripts (`seed_*_definition.sh`)

Service-task endpoints (ISS-0930): the engine needs an absolute public `https://` URL that
returns a 2xx JSON object, so the QA fixtures point every SERVICE_TASK at
`https://httpbin.org/anything/<path>` with an explicit `"method": "POST"`. Set
`SERVICE_TASK_MOCK_BASE_URL` (https only, no whitespace; one trailing `/` is stripped) to
substitute another echo host at seed time without editing the fixtures; the chosen base is
printed in the script banner. `http://` is refused before any network call.

Re-seed rule (version-aware, compared by `sort -V`): ACTIVE == fixture version -> skip;
ACTIVE older -> create the fixture version and activate it (the platform deprecates the
prior ACTIVE one); ACTIVE newer -> warn and do not downgrade. A 409 on create means
`(name, version)` already exists as DRAFT/DEPRECATED/ARCHIVED: bump the fixture `version`,
never delete. Requires `curl`, `jq` and GNU `sort -V`.

**Data egress / safety.**
1. The default `SERVICE_TASK_MOCK_BASE_URL` (`https://httpbin.org/anything`) is a third-party public echo
   service: it receives the HTTP method, the URL path with rendered IDs (`application_id`, `review_id`,
   `shipment_id`, `order_id`, `batch_ref`, `deviation_id`) and the QA server's source IP, and may log them.
2. QA data used with these fixtures must be synthetic, with no PII.
3. Any QA environment holding non-synthetic data must set `SERVICE_TASK_MOCK_BASE_URL` to a self-hosted echo endpoint.
4. Never seed production with these fixtures.

## `mutate.py`

```
python scripts/mutate.py <file> <old> <new> -- <test-command...>
```

Applies exactly one textual substitution to `<file>` (refuses unless `<old>` occurs
exactly once — exit 2 otherwise, nothing written), runs `<test-command>` against the
mutated file, reports `MUTANT_KILLED` (tests caught it, exit 0) or `MUTANT_SURVIVED`
(nothing caught it — a coverage gap, exit 1), then **always** reverts the file to its
original bytes and verifies the revert before exiting — including if the test command
itself errors or the process is interrupted.

Full usage, exit codes, mutant taxonomy, and design rationale are in the script's own
header comment (`scripts/mutate.py`, top of file) — read that before use rather than
re-deriving the calling convention.

### Origin

Built for ISS-0261, a follow-up from `WF03-ISS0258-20260822`: that run's
TEST-DESIGN-VALIDATOR wrote a throwaway `tdv_mutate.py` to verify mutation-kill claims
for `lib/mix/tasks/letflow.check_deferral_staleness.ex`, then deleted it as
out-of-remit for a validator to promote, and recommended a follow-up (see
`docs/issues/ISS-0258.yaml`, `handoffs/WF03-ISS0258-20260822/step-04b-test-design-validator.md`
§7). `mutate.py` generalises that script: same single-occurrence guard, plus it now
runs the test command and reverts automatically instead of leaving both steps to the
calling agent's own shell commands.

### Worked example (real, not synthetic — reproduces `WF03-ISS0258-20260822`'s own MS3 mutant)

```
$ mix test test/mix/tasks/letflow_check_deferral_staleness_test.exs
Result: 57 passed

$ python scripts/mutate.py \
    lib/mix/tasks/letflow.check_deferral_staleness.ex \
    "@active_statuses [:done, :in_progress, :blocked]" \
    "@active_statuses [:in_progress, :blocked]" \
    -- mix test test/mix/tasks/letflow_check_deferral_staleness_test.exs
...
Result: 43/57 passed
Failed: 14 tests
MUTATE-APPLIED lib/mix/tasks/letflow.check_deferral_staleness.ex
MUTATE-REVERTED lib/mix/tasks/letflow.check_deferral_staleness.ex (verified byte-identical)
MUTANT_KILLED

$ echo $?
0

$ git status --porcelain lib/ test/
(empty)

$ mix test test/mix/tasks/letflow_check_deferral_staleness_test.exs
Result: 57 passed
```

14 tests failed for the mutant — the same 14-test red set `WF03-ISS0258-20260822`
recorded by hand for this exact mutant (that run's suite had 55 tests at the time,
41/55 passed; the suite has since grown to 57 by an unrelated later change, still
14 red). The revert was verified byte-identical and the suite is green again
afterward, with no manual cleanup step.

The single-occurrence guard was also demonstrated directly: passing a string with 0
occurrences refuses with exit 2 and writes nothing (`git status --porcelain lib/`
empty both before and after).

### When to use vs. the throwaway-worktree technique

`mutate.py`'s revert is verified and automatic, which is adequate for **one mutant at a
time** against a file you're not otherwise editing. For a **multi-mutant pass** against
a branch under active development (the common WF-03 Step 4b/4c case), still prefer the
throwaway `git worktree` isolation technique described in
`docs/agents/workflows/WF-03_issue_resolving.md` ("Isolation technique worth
copying") — it guarantees the working checkout is never touched at all, which matters
more than a fast revert when several mutants are queued back to back. `mutate.py` works
identically from inside such a worktree.
