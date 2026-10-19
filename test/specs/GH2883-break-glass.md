# GH #2883 test spec: the operator break-glass for an `on` tenant (REQ-519 gate, part (b) of GH #2869; decision 0051 A11)

Design: `lib/letflow/design/gh2883-scope-enforcement-break-glass.md` r1 (tests T-BG-1..T-BG-32, mutants MU-BG-1..28, AC map section 8, tests that change section 6, runbook text section 10).
SEC design gate: `handoffs/WF02-GH2883-BREAKGLASS-20261019/step-03-security-reviewer-design.json` (S-BG1..S-BG12, F-1..F-4, RA-B1 accepted as A11). ELIXIR-DEV handoff: `step-04-elixir-dev.json`.
Source under test (uncommitted, not changed by this step): `Letflow.ScopeEnforcement.flip_out_of_band/3` (+ `check_out_of_band_inputs/3`, `parse_out_of_band_target/1`, `valid_operator_label?/1`, `transaction_timeout_ms/1`), `Letflow.Release.ScopeBreakGlass`, `Mix.Tasks.Letflow.ScopeEnforcement.BreakGlass`, the runbook, `docs/roles.md`, decision 0051 A11.
Nothing under `lib/`, `priv/` or `docs/` was changed by this step. Nothing is committed. Real results (counts, mutants) are in `handoffs/WF02-GH2883-BREAKGLASS-20261019/step-05-test-designer.json`.
Resource rules followed: no `mix letflow.check.test`, no full-suite or multi-partition run; per-file `mix test`, one mix at a time, the mixlock directory was absent throughout and was never created or removed; no real tenant touched (every `on` tenant is a throwaway fixture tenant that an `on_exit` stores `off` again before the tenant teardown).

## Files

| File | Tests | Ids |
|---|---|---|
| `test/letflow/scope_enforcement_out_of_band_test.exs` | 43 | T-BG-1..T-BG-18, T-BG-28 (core `flip_out_of_band/3`); T-BG-19 is the unchanged existing flip files, re-run |
| `test/letflow/release/scope_break_glass_test.exs` | 24 | T-BG-20..T-BG-26 (`ScopeBreakGlass.run/5`, printed protocol, log lines, exit codes, the no-halt scan) |
| `test/mix/tasks/letflow_scope_enforcement_break_glass_test.exs` | 12 | T-BG-27 (`parse_args!/1` argv matrix without `app.start`, task `run/1` success path, moduledoc sentence) |
| `test/letflow/scope_enforcement_flip_authority_test.exs` | +17 (14 -> 31) | T-BG-29, T-BG-31, T-BG-32, T-BG-14c (iv)/(v): one caller, text scan over ALL of `lib/`, no HTTP surface, one changeset expression, the explicit transaction timeout, the config scans; every new scan proven live on a seeded offender |
| `test/letflow/docs/roles_on_flip_docs_test.exs` | +7 (18 -> 25) | T-BG-30: docs wording, runbook section, seven LIMIT items, decision record A11 |
| `test/support/break_glass_fixture.ex` | helpers | NEW: `on_tenant!/1`, `bare_on_tenant!/1`, self-cleaning `on` tenants, held-lock A / tenants-row holders, `queue_two!/3`, `snapshot/1`, `with_unwritable_audit/2` |

## AC -> test (design section 8)

| Source | Requirement | Tests | Why the test exists (what it would catch) |
|---|---|---|---|
| #2883 Req 1 | release command or Mix task | T-BG-26, T-BG-27 | `run/5` prints exactly the protocol, never halts, `exit_code/1` maps it; the Mix wrapper parses argv strictly and is the only halting code |
| #2883 Req 1 | NO HTTP route (0051 A6) | T-BG-29 | a route, router, plug, API module, script, workflow, seed or config that references the command; ANY other `lib/` file calling it through `apply/3`, a capture or an alias |
| #2883 Req 2 | mandatory reason | T-BG-1, T-BG-2 | blank / nil / non-binary reason accepted for one target; an unvalidated reason; the wrong check order |
| #2883 Req 2 | actor = the operator | T-BG-3, T-BG-4, T-BG-12 | an unvalidated label (log / audit-reader spoofing), a label not recorded, `actor_id` read from `attrs`, `node` omitted or chosen by the caller |
| #2883 Req 2 | audited `scope.enforcement_disabled` in the SAME transaction | T-BG-4, T-BG-5, T-BG-6 | an audit written after the commit or ignored on failure (flag and entry diverge); both a RETURNED audit error and a RAISED one are exercised; chain still verifies with a NULL actor |
| #2883 Req 3 | flag only, grants no role (0046 D4) | T-BG-7 | a touched user, group, member, binding, grant, token, scope-node or registration row (md5 + count snapshot before / after) |
| #2883 Acc 1 | lock order of `flip/4` | T-BG-14a, T-BG-14b, T-BG-14c, T-BG-15 | lock A not taken; T before A (while the command waits for A the tenants row is still free: `FOR UPDATE NOWAIT` succeeds); previous read before the locks (race with `flip/4`); an unbounded wait (all three waits A, T, C expire as `:lock_conflict`, never `{:transaction_failed, _}`) |
| #2883 Acc 1 | does an emergency `on -> shadow` restart the window | T-BG-13 | a wrong action name (`enabled`) or any shortcut: T0 moves to the new entry, duration criterion false at once, `shadow -> on` refused with `:shadow_evidence_insufficient`; `on -> off` leaves `:shadow_required` |
| #2883 Acc 2 | refuses missing / blank reason | T-BG-1, T-BG-21, T-BG-23 | also through the dry run |
| #2883 Acc 2 | changes only the flag | T-BG-7 | see Req 3 |
| #2883 Acc 2 | works when no interactive admin exists | T-BG-8 | (i) zero users, (ii) the only TENANT_ADMIN is a token owner, (iii) a flagged service principal, (iv) all gate facts failing; each asserts the interactive-admin count is 0 / the gate fails first, then the command succeeds (a consulted gate fact or a read of an identity table would refuse) |
| Brief | refuses non-`on`; target `on` | T-BG-9, T-BG-10, T-BG-28 | `shadow -> off`, `off -> *`; `:on`, `"on"`, `"ON"`, strings at the core, no atom minted from a string |
| Brief | unknown tenant, platform tenant (INV-10), inactive tenant | T-BG-11, T-BG-16, T-BG-17, T-BG-20 | a raise on an unknown id; a tenants row without registration; the platform tenant's `PLATFORM_ADMIN` platform scope unchanged before / after |
| Brief | one constant log line on a fault; label only if valid | T-BG-24, T-BG-25 | a fault logged as a refusal (or the reverse), a second line, a line holding slug / id / reason / message, a hostile label (newline, CRLF, bidi, quote) injecting a forged `scope_break_glass_applied` line |
| Brief | prints no ids beyond the slug | T-BG-22 | a tenant id, schema name, reason, operator, node or exception text in the console output of success, dry run and 12 error shapes (the fixture slug itself contains a UUID, so the typed slug is stripped before the UUID scan) |
| Brief | multi-node note | T-BG-18 | the next request reads the committed mode (auth pipeline, uncached) |
| Brief | the 2f-b flip-authority scan updated | T-BG-29, T-BG-31 | see above |
| AC 23 | still exactly seven LIMIT items | T-BG-30 | an eighth item for the break-glass; the old sentence left in either document |
| AC 24 | gate sentences | existing `roles_on_flip_docs_test.exs` AC 24 test (unchanged, still green) | |
| #2883 Acc 3 / RA-B1 | A11 with the two SEC-required statements | T-BG-30 | attestation-not-authentication + host-access authority + "needs a NEW decision record"; "A10's gap only PARTLY answered, #2869 part (a) still open before any customer `on`" |
| SEC F-1 | transaction timeout 3L + 10 s | T-BG-14c (i) to (iv) | (iii) pure unit test of `transaction_timeout_ms/1` (strictly > 3L, > 15 s for the default); (iv) AST scan: the `Repo.transaction` of `flip_out_of_band/3` has a `timeout:` derived from `transaction_timeout_ms/1` |
| SEC F-2 | text scan over all of `lib/` | T-BG-29 | seeded forms: plain call, `apply/3`, `Kernel.apply/3`, capture, comment in an unlisted file, alias, import, call from an engine-path module, bare `out_of_band`, a call from a neighbouring Mix task; the three allowed files seeded alone pass |
| SEC F-3 | `node` in the entry, label in log lines only if valid | T-BG-4, T-BG-12, T-BG-24, T-BG-25 | |
| SEC F-4 | Mix form is dev and CI only | T-BG-27 (moduledoc first paragraph), T-BG-30 (runbook section) | |

## Test ids that changed shape against the design text (recorded, not hidden)

* **T-BG-6 / T-BG-24, `{:audit_failed, _}`.** A database trigger that RAISES inside the audit insert gives `{:error, {:transaction_failed, %Postgrex.Error{}}}` (`exception=Postgrex.Error`), exactly like the `flip/4` C-5 test, NOT `{:audit_failed, _}`. `{:audit_failed, _}` is reachable only when `Audit.insert_entry/3` RETURNS an error. Both are tested: the raise through the existing `SyncScopeFixture.create_audit_fault!/3` trigger; the returned error through `BreakGlassFixture.with_unwritable_audit/2` (the tenant schema is renamed to a non `tenant_<32 hex>` name and the registration row is pointed at it, committed DDL restored in an `after` AND an `on_exit`; `Audit.insert_entry/3` then answers `{:error, :invalid_schema_name}`).
* **T-BG-24, a fault line with an INVALID label.** Unreachable through the public API: a label that fails the rule is refused before any transaction, so a fault line always carries a valid label. The conditional `operator_suffix/1` is exercised through the refusal lines (T-BG-25: absent for `invalid_operator` / `operator_required`, present otherwise), which share the helper. Mutant `MU-BG-11b` (suffix always appended) is killed there.
* **T-BG-29 / design section 6 (2b), `ScopeBreakGlass`.** The design allows the text `ScopeBreakGlass` only in the release module and the Mix task, but its own section 10.3 requires the `ScopeEnforcement` moduledoc to name `Letflow.Release.ScopeBreakGlass` as the sole caller (and the implementation does). The scan therefore allows that one mention in `lib/letflow/scope_enforcement.ex`; the AST call scan (2) still forbids any CALL from there. `flip_out_of_band` and `out_of_band` stay limited to the files the design lists (`out_of_band` additionally allowed in the Mix task file by superset; it holds none today).
* **T-BG-29 (2), `files_calling == [release]`.** The definition file itself matches a local-call AST pattern, so (as the existing changeset test does) the definition file is excluded and the rest of `lib/` must yield exactly the release module.
* **T-BG-30.** The item 7 claims in `roles_on_flip_docs_test.exs` were already switched by ELIXIR-DEV (forced by the old pinned claim); this step adds the heading, section, gate-paragraph, LIMIT and decision-record rules as one pure `bg_violations/3` function run on the real files and on 14 seeded bad documents.
* **T-BG-30, a path literal.** The decision record path is built with `Path.join/1`: a string literal naming `docs/migration/...` is treated by `ci_backend_path_filter_test` as a path the backend gate READS, and `docs/migration/` is not in `BACKEND_PATHS_RE`, so the literal failed that guard (2 failures, seen and fixed). Reported as a CI-filter gap: a change confined to a decision record would not trigger the backend job although a test now reads it.
* **T-BG-27, a repeated switch.** `OptionParser` without `:keep` keeps the LAST value of a repeated switch; the task does not reject it (`--operator a --operator b` uses `b`). Not a security issue (the value is validated by `run/5` afterwards); pinned as a test so a change is visible.
* **T-BG-14c (ii), the key check of the audit chain lock.** `LockOrderHelpers.hold_row(schema, :audit_chain)` needs the `audit_chain_locks` row to exist; the fixture tenant has one because `on_tenant!/1` goes through a real `flip/4` first.

## Lessons applied

* `with_log` captures the Ecto debug QUERY lines (ids, the slug): every log assertion looks only at lines carrying the `scope_break_glass_` marker and reduces them to the constant part.
* No wall clock: no assertion compares a duration, an ordering of two `DateTime.utc_now()` calls is asserted only as a strict `:gt` against an entry written earlier in the same test, the window checks use the entry's own timestamp, and the lock-timeout cases hold a lock until the test releases it (the 300 ms bound is only ever too SHORT for the held lock, never racing it). No second-boundary or UTC-midnight dependency (#2729): the only date-dependent seeding (`seed_requests!` for the window of `now`) feeds an assertion that is false whatever the dates are.
* Committed `on` tenants: `BreakGlassFixture.on_tenant!/1` / `bare_on_tenant!/1` register an `on_exit` that stores the tenant `off` again BEFORE the tenant teardown, and every test file calls `purge_stale!/0` (the `EnforcedWritersFixture.purge_stale_enforced_tenants!/1` pattern, slug prefix `gh2883-`) in `setup`. Nothing in this step migrates down.
* The CI path-filter guard: no new path-like string literal under a gate root; the `.github` glob comes from `ci_dir_glob/0` (a sigil-style builder already in the file) and the decision record from `Path.join/1`.
* Unicode in test source: control, format and bidi characters are written as escapes (`mix format` and the compiler reject a raw bidi character in a string).

## Mutants (applied in memory only: the shipped source is read, one textual mutation compiled into the running VM through `Code.compile_string/2`, the two main test files run in that VM; nothing is written to disk; the revert is "start a fresh VM", verified by the green re-runs listed in the handoff)

Twelve mutants measured in memory (see below); the rest is left to TEST-DESIGN-VALIDATOR.

| Mutant | Mutation | Result (core + release files, 67 tests) |
|---|---|---|
| MU-BG-1 (M1) | blank reason accepted (`{:ok, ""}`) | KILLED: 5 failed / 62 passed |
| MU-BG-2 (M2) | audit failure ignored, flag kept | KILLED: 3 failed / 64 passed |
| MU-BG-3 (M3) | `operator` not recorded in `after_state` | KILLED: 5 failed / 62 passed |
| MU-BG-4 (M4) | `shadow -> off` allowed | KILLED: 4 failed / 63 passed |
| MU-BG-23 (M23) | `changed: true` -> `false` in the shared write helper | KILLED: nearly every test of the core file failed (the fixture's own real `flip!` breaks), first run only, counts not summarised |
| MU-BG-6 (M6) | lock A not taken | KILLED: 6 failed / 38 passed (14a, 14b, 14c(i), three T-BG-15) |
| MU-BG-7 (M7) | tenants row locked before lock A | KILLED: 1 failed / 43 passed (T-BG-14b only) |
| MU-BG-8 (M8) | `previous` read before the locks | KILLED: 2 failed / 42 passed (T-BG-15 flip-first and two-runs) |
| MU-BG-12 (M12) | operator label rule always true | KILLED: 6 failed / 65 passed (T-BG-3 x2, 21, 23, 25 x2) |
| MU-BG-22 (M22) | no `set_config` lock timeout | KILLED: 4 failed / 40 passed (14c i, ii x2, vi) |
| MU-BG-27b (M27b) | transaction timeout formula `L + 10 s` | KILLED: 1 failed / 43 passed (14c iii unit) |
| R5 F3 (M30) | lock-timeout cap removed | KILLED: 1 failed / 43 passed (14c vi) |
| R5 F3 option removed | `timeout:` dropped from the `set_config` query | static AST scan (`set_config_timeouts/1`), live on a missing option, a constant and another query; also dropped with the whole query in M22 |
| not measured | MU-BG-10, 11a/b, 13..15, 17..19, 21, 24, 26, 28, 29 | prepared in an earlier harness, not run (TDV is measuring them); the harness file `gh2883_mutate.exs` holds only the seven run here |

Static-scan mutants (MU-BG-9 second changeset expression, MU-BG-16 a reference from a router / script / `apply/3`, MU-BG-20 a `System.halt` in the release function, MU-BG-22b the key in `runtime.exs`, MU-BG-27a no `timeout:` option) cannot be measured by an in-memory mutation of the module because the tests READ THE FILE ON DISK. They are proven by the seeded-offender tests (each scan is fed a source with exactly that offence and must report it, and the real file must be clean): T-BG-26 (`halt_calls/1` on seven halting spellings), T-BG-29 (ten call forms), T-BG-31 (`call_count/2` and `functions_calling/2` on two-call and misplaced-call sources), T-BG-14c (iv) (`transaction_options/1` on a missing option, a constant timeout and a timeout in another function), T-BG-32 (`key_files/1` on a seeded `runtime.exs`). `MU-BG-9` is also measured as an in-memory mutant (a second `Tenant.scope_enforcement_changeset` call in `write_flag_and_audit!`): it is NOT killed by the dynamic suite (the second update is a no-op) and is killed only by the on-disk scan T-BG-31, whose live-ness is shown on the seeded source.

## What is NOT tested and why

* The PR-body obligations of design section 12 / AC 24 (the two gate sentences in the PR body): process items, not testable in-tree. The docs test pins the same sentences in the runbook.
* `mix letflow.permission_matrix --check`, `check_requirements_registration`, `letflow.check.test`, the full suite: not run (supervisor resource rule); TEST-RUNNER's job.
* The break-glass against any real or pilot tenant: never run.
* A stuck-for-more-than-15-s end-to-end scenario for SEC F-1: the 40 s derived timeout is pinned by the unit test, the AST scan and the three bounded-wait cases; a real 30 s wait is not run (10 minute / machine-load rule, and it would add nothing the three-wait test does not show: each wait is the lock-timeout bound).

## R5 follow-up (ELIXIR-DEV findings F1 to F4 on top of f46ae8c80)

| Finding | Tests |
|---|---|
| F1 ticket id as reason PREFIX | `roles_on_flip_docs_test.exs`: runbook section claims (`MUST start with the incident ticket id`, `<ticket id>: <short reason>`), a dedicated test on the Before-you-start paragraph, the Mix task moduledoc and the `run/5` doc string via `Code.fetch_docs` (docs only, no code check); seeded: claim removed fires |
| F2 dry run log line | `scope_break_glass_test.exs`: the old "dry run logs nothing" assertion is now `scope_break_glass_dry_run operator=<label>` (no slug, id, reason); a refused dry run logs the refusal line; unknown tenant, confirm mismatch and invalid reason each leave exactly one `scope_break_glass_refused` line |
| F3 cap and timeout | core file (vi): telemetry on the bound `set_config` parameter: 300 stays, 14_000 stays, 14_001 / 60_000 / 10^9 clamp to "14000", 0 / negative / non-integer / unset give "10000"; flip_authority: AST check that the `set_config` query carries `timeout:` derived from `transaction_timeout_ms/1` (+ seeded offenders); the existing 300 ms held-lock cases still end as `:lock_conflict` |
| F4 audit-chain fault (switched by R10 to option (b), an accepted limitation) | `roles_on_flip_docs_test.exs`: positive pins `Audit-chain fault (accepted limitation)`, `There is NO sanctioned SQL path`, `Escalate to the platform owner`, `needs its own decision record`, the absolute `Never write the column with SQL` + `that skips the audit entry and the locks`; A11: `audit-chain fault`, `makes the command fail and roll back`, `enforcement then stays as it is`, `ACCEPTED LIMITATION`, `option (b)`, `there is no sanctioned SQL path`, `needs its own decision`. NEGATIVE pins (a re-introduced SQL path fails and goes to the auditor): `last resort`/`last-resort` in the break-glass section, `last resort` in A11, `sign-off` in the section or A11 paragraph, any `INSERT INTO` / `UPDATE tenants` snippet in the section or A11, and the weakening `as a routine step`. Each rule has a seeded offender that must fire. The old pins (`last resort`, `ONE transaction`, `WRITTEN sign-off`) are gone. |

Per-file runs after the follow-up: docs 26 (after R10), flip_authority 33, release 27, core 44 (all passed). NOTE: the scratchpad is shared with sibling sessions; `m.sh` and `mutate.exs` there were overwritten by another session, so this step's harness lives in `gh2883_mutate.exs` / `gh_m.sh`.
