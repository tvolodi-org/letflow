# REQ-519 slice 2f-b test spec: `on` becomes settable (GH #2535, decision 0051 D12/D8, SEC S-3/S-5/S-6/C-1/C-5/C-6)

Design: `lib/letflow/design/req519-enforced-writers-and-flag-on.md` r2a (section 1 2f-b row, 4.1, 4.2, 4.2a, 4.3, 4.7 to 4.10, 8.4, 9).
Scope: REQ-519 acceptance criteria 8, 12 (the docs half, T-E15), 13, 14 (flip wiring), 15 (enabled / disabled with mode `on`), 16 and 17 (the end-to-end half described below), 18 (route half), 20, 22, 24. AC 19 (amendment link) and AC 21 (gate commands) are process items, not tests.
Also covered: the SECURITY-REVIEWER 2f-b MERGE CONDITIONS (step-21), the REVIEWER step-22 notes (F-4 rename, TS-1), the 2f-a obligations that only became testable once `on` is settable (MU-22, MU-23, MU-39, MU-42 flip half, V7), and the cleanup of the stale `on` tenants of the shared local test database.
Nothing under `lib/` or `priv/` was changed by this step. Nothing is committed. Real results (counts, mutants) are in `handoffs/WF02-REQ519-ENFORCED-WRITERS-20261018/step-23-test-designer-2f-b.json`.
Resource rule followed: no `mix letflow.check.test`, no full-suite or multi-partition run; per-file `mix test`, one mix at a time, under the mixlock directory (created by this session with `mkdir`, removed by it).

## Files

| File | Tests | Ids |
|---|---|---|
| `test/letflow/scope_enforcement_transitions_test.exs` | 36 | T-X1..T-X7, T-X9..T-X13, T-A6 (AC 15), AC 14 through `flip/4`, T-G9 / T-E16 / T-G10 flip halves, V7 |
| `test/letflow/routers/tenant_scope_enforcement_on_test.exs` | 22 | T-H1..T-H7, T-H9, T-H10, T-X14, the PUT authority matrix, the live PUT flip, `GET /integrity` on a raise |
| `test/letflow/scope_enforcement_flip_authority_test.exs` | 14 | T-X8, the AC 8 and AC 24 source scans, every scan proven live on a seeded offender |
| `test/letflow/api/route_scope_on_flip_blocker_test.exs` | 8 | T-RW1..T-RW4 (AC 22, SEC C-1) |
| `test/letflow/scope_enforcement_on_e2e_test.exs` | 8 | T-Z0, T-Z1, T-Z2, T-O7, T-O8, T-Z15..T-Z17 |
| `test/letflow/docs/roles_on_flip_docs_test.exs` | 18 | T-E15, AC 23 and the docs obligations of design 4.10 (pure functions of the text, run on the real file and on seeded bad documents) |
| `test/letflow/scope_enforcement/on_flip_guards_test.exs` | 17 | RENAMED from `dormant_on_test.exs` / `DormantOnTest` (REVIEWER F-4); one new test: TS-1 |
| `test/support/on_gate_fixture.ex` | helpers | NEW: `backdate_shadow!/1`, `backdated_shadow_tenant!/1` (a tenant stored `shadow` whose evidence satisfies the gate at the REAL clock), `gap!/1`, `break_fact!/2`, `break_all_facts!/1` |
| `test/support/enforced_writers_fixture.ex` | helper | NEW: `purge_stale_enforced_tenants!/1` (the leak cleanup, below) |
| `test/letflow/identity/binding_no_row_report_test.exs` | 16 (unchanged count) | one `setup` line calling the purge helper |
| `test/specs/REQ-519-2f-a.md` | | references to the renamed file updated (lines 20 and 55) |

106 new tests in 6 new files, plus 1 new test in the renamed file.

## What 2f-a could not show, and where 2f-b shows it

| Deferred from 2f-a | Test | Mutant |
|---|---|---|
| refusal audit written by `flip/4` after the rollback; `shadow_required` for `off -> on` | transitions "AC 14 a gate refusal through flip/4" (5 facts + evidence, all at once, twice, stage 1 unaudited), T-X5 | MU-23, MU-38b/c/d |
| a raise inside `OnGate.evaluate/3` INSIDE the flip transaction is `{:transaction_failed, _}`, never a refusal | transitions "T-G9 / T-H9 (flip half)" (a fact table renamed, the evidence table renamed), router "T-H9" (500, one constant line, no refusal entry) | MU-39, MU-39b |
| flush before the transaction | transitions "T-E16 (flip half)": a request counted only in memory for a window date is visible to the flip | MU-42 |
| the S lock before the six facts | transitions "T-G10 (flip half)": a holder takes ONLY lock S, the flip queues on S, the holder commits a gap, the flip sees it | MU-22a, MU-22b |
| `attrs[:now]` honoured only as a `DateTime` | transitions "V7" (a DateTime is honoured; string, integer, nil, map, atom, list are ignored and never crash); router "attrs[:now] is not reachable from the router" (a body clock does not pass the gate) | V7a, V7b, MU-S5 |
| the AC 12 sentence in `docs/roles.md` | docs "T-E15" | seeded bad documents |

## AC -> test

| AC | Tests | Why it exists (what it would catch) |
|---|---|---|
| 8 `on` is settable; one entry | T-X1 (`parse_mode/1` accepts exactly `off|shadow|on`, no atom minted, `flip/4` rejects non-atom targets), T-X2..T-X7, T-X13, T-H1 (`permission_scope(required_permission(:ScopeEnforcementManage)) == :tenant`; the PUT and the service-principal route both call `Scope.require_interactive_tenant_admin/1`; the two private copies are gone), T-H2 matrix, T-H3 (GET routes keep serving tokens), T-H4 (a `scope_enforcement` key in `PATCH /tenant/settings` and `PATCH /tenants/:slug` leaves the stored mode unchanged), T-X8 + scans (only the router calls `flip/4`, only `scope_enforcement.ex` calls the changeset, `:ScopeEnforcementManage` is one PUT route) | an extra spelling of `on`, an extra writer, a token or platform admin flipping, a second flip route |
| 8 PUT authority matrix | one table: interactive tenant-wide TENANT_ADMIN allowed; an API token holding TENANT_ADMIN whose owner IS a tenant-wide admin, a token whose context carries no `credential`, a scoped-only admin, a flagged service-principal token, a non-admin, an unknown user, an OIDC admin whose group has ZERO rows, a platform-tenant PLATFORM_ADMIN without TENANT_ADMIN, and (full pipeline) a real token: ALL refused with the SAME 403 bytes for `off -> shadow`, `shadow -> on`, `on -> shadow`, `shadow -> off`, `on -> off`; the stored mode and the audit chain are unchanged | the S-3 narrowing (it also closes `off -> shadow` for tokens), the uniform body (no probe tells callers apart) |
| 9 gate through the flip | single-fact refusals for facts 1 to 5 plus evidence with the exact code, the exact counts and ONE refusal entry; all failing facts at once in read order; the zero-admin case through HTTP; S lock order; raise | the gate must run, every fact must be named, the order is stable |
| 10, 11 consumed by the flip | fact 5 (`scoped_approvers_without_task_scope`) refuses through the flip and through the PUT; the evidence fact refuses on a fresh shadow tenant; flush; the clock | the gate must read the real facts at flip time |
| 12 | docs T-E15 (the sentence occurs exactly once in `docs/roles.md`, as a paragraph of its own, equals `ShadowWindow.scope_sentence/0`, equals the AC text); `evidence_scope` in the 409 body, the audit evidence and the integrity body | the docs cannot drift from the code constant |
| 13 | T-X2 (enabled entry: six counts, evidence summary, reason, actor, trace, chain verifies), T-X3/T-X9 (`on -> shadow` needs a reason, runs no precondition, audits `disabled` with `mode` + `reason` only), T-X10 (it SUCCEEDS with facts 1 to 5 failing, while `off -> shadow` with the same seed is refused: MU-21), T-X4/T-X11 (`-> off`), T-X7 (the rank rule), T-X12 (forced audit failure rolls back both directions), router: on -> shadow with failing facts | the re-keyed gating, the mandatory reason |
| 14 (wiring) | transitions "AC 14" and router "T-H5/T-H6/T-H7": ONE `scope.enforcement_refused` entry in its own transaction after the rollback per refusal, `shadow_required` audited with `failed ["shadow_required"]`, a server fault never recorded as a refusal | MU-38, MU-39 |
| 15 | T-A6: `Audit.list_entries/1` returns enabled (mode `on`), refused and disabled (`on -> off`) entries and the chain verifies | a mode-`on` payload that breaks the reader |
| 16 | T-Z0 (the walk is green first), T-Z1 (real flip; the SAME tenant-wide route is served under `shadow` and refused 403 under `on` for a scoped TASK_WORKER; `/me/memberships` still works; a tenant-wide user and an API token are unaffected; a scoped user cannot flip; writers refuse (`upsert_role` nil -> platform is `scope_required`); IdP sync suppresses a tenant-wide group for a user with scoped rows; `on -> shadow` needs a reason; the restored answer is BYTE-IDENTICAL to the answer before the flip; `-> off` likewise), T-Z2 (a scoped-only TENANT_ADMIN is refused the admin plane and the flag route under `on`; the tenant-wide admin reaches both) | the user-visible effect of `on` and its reversibility |
| 17 | T-Z15 (zero-row binding: `{:deny, :no_grant_rows}` and the uniform 403), T-Z16 (the last scoped row cannot be deleted in `on`: 409 `last_scoped_row`, scope unchanged), T-Z17 (a referenced node cannot be retired in `on`: `:node_has_grants`, scope unchanged, nobody becomes tenant-wide) | fail closed after the flip |
| 18 (route half) | the 409 and 500 bodies carry counts, codes, booleans and dates only (no UUID, no schema name); the 500 logs ONE constant `scope_enforcement_flip_failed` line and `GET /integrity` ONE constant `scope_enforcement_integrity_failed` line (exception module only); a raise propagates as a rollback; the body can supply no clock or threshold | INV-2, INV-4, INV-8 |
| 20 | T-X8: exactly one route has the key `:ScopeEnforcementManage` (`PUT /tenant/scope-enforcement`), so the platform-scope flip route for ANOTHER tenant is not built | the follow-up cannot be built silently |
| 22 | route blocker file T-RW1..T-RW4 on the REAL route table and the REAL ruling list (no default-sourced `/me` or `/help` row, no snapshot line, no `:pending_sec_ruling`, the three rulings `0051-A7`, `SEC-518-R2-modules`, `SEC-518-R2-help`, `audit_routes/3 == []`) each proven live on a seeded offender; T-Z0 repeats the walk first in the e2e suite | SEC C-1 |
| 23 | docs file, "AC 23 the collecting section": under the heading `Known limitations of an enforced tenant` ONLY (until the next heading of the same or higher level) exactly four list items beginning with `LIMIT-IDP-SYNC-WHOLE-GROUP`, `LIMIT-POST-ROLES-409`, `LIMIT-IMPORT-UPSERT-404`, `LIMIT-ON-FLAG` (a longer token is not a match); each token exactly once in `docs/roles.md` and exactly once in `docs/runbooks/scope-enforcement-on.md`; the items contain respectively (`grant.sync_suppressed`, `binding.pending_scope`), `scope_required`, (`upsert_by`, `external_ref`, `404`), (`shadow`, `2f-b`). Live on seeded offenders: missing heading, a renamed/missing token, a duplicated token, a fifth item, an item moved under a later heading, a missing needle, a token missing from or duplicated in the runbook | a drifting or duplicated limitations list |
| 24 (process) | the runbook states "No production tenant is set to `on` until the supervisor says so" and that no test, seed, migration or script flips a production tenant (docs test); the in-tree half of the check is the AC 24 scan file; the PR-body half is a PR obligation, not testable in-tree | |
| 25 (process) | NOT testable in-tree: the 2f-b PR body must contain the literal ids `REQ-525`, `REQ-526`, `REQ-527` and the sentence "pilot tenants only until RA-6 (REQ-525, REQ-526, REQ-527) and the task scope writer exist"; before merging ORCH runs `git show origin/main:docs/requirements.yaml | grep -c '^  - id: REQ-52[567]$'` (expects 3) and greps the PR body; SEC records both results | |
| 24 (in-tree) | the scan file: no `lib/` Elixir source holds a literal `scope_enforcement` pair set to `on` (AST) except the auth pipeline's READ pattern; no SQL / bulk setter in `lib/` or `priv/`; no `priv/`, `config/`, `scripts/`, `.github/`, `mix.exs` line names the column next to an `on` value except the widened CHECK and its rollback guard (pinned to what it may contain); the add-column migration defaults `off` and names no `on`; `config/` never names the column; no seed, script or workflow drives the route | no code path, seed, migration or config sets a tenant to `on` |
| SEC C-6 | T-O7: the PLATFORM tenant stored `on` keeps its PLATFORM_ADMIN on `GET /tenants` in all three modes even through a PLATFORM_ADMIN group with ZERO rows; the flag route stays TENANT_ADMIN-only there; T-O8: in an ordinary tenant stored `on` a PLATFORM_ADMIN role gets 403 on `/tenants` and on the flag route | INV-10 |
| REVIEWER F-4 / TS-1 | the file and module rename; TS-1 compiles an in-memory copy of the router whose `flip/4` call is a stub answering a brand-new refusal tag and pins a detail-free 500 with ONE constant line `reason=unknown exception=none`, no echo of the tag or its detail | the open union cannot become a 200 or a leak |
| SEC merge: docs | docs file: the eight "what `on` means" items in order each with its load-bearing claim, an introduction naming RA-6 / REQ-525..527 / #2862, #2869, #2870, amendment PR #2871; the operator transition table, the mandatory reasons, every gate code, the thresholds' names and defaults, the integrity snapshot; the known limitations incl. the scoped `upsert_by external_ref` refusal in `import_scope_check/6` (which exists in the entities router); the platform-tenant sentence once, as item 8 | the operator-facing contract |

## Not covered here (stated, not faked)

| Gap | Why |
|---|---|
| the data-path clauses of AC 16 (query / aggregate / export / cursor totals, out-of-scope ids byte-identical to nonexistent ids on PUT / DELETE / attachment / task routes, moving a record out of scope, an import with one out-of-scope row, undeclared types, a scoped approver outside the routing role) | these are proven under stored `on` by the REQ-518 suites (`entities_scope_http_test`, `tasks_scope_http_test`, `entities_scope_*`, `attachment_link_scope_test`, `scope_gate_test`, `tasks_scope_inv5_http_test`), which set `on` through the fixture; the e2e file here adds the flip itself, the tenant-wide route class, the admin plane, the writers, the sync and the way back. If TEST-DESIGN-VALIDATOR requires them re-driven after a REAL flip, the `OnGateFixture.backdate_shadow!/1` + real flip path of T-Z16 is the harness to extend |
| the "404-equivalent answer on data routes" for a zero-row principal (AC 17, first clause) | T-Z15 asserts the principal decision (`:no_grant_rows`) and the uniform 403 on a tenant-wide route; the data-route 404 equivalence is a REQ-518 test |
| a `PUT` / `PATCH` of the column through the generic ENTITIES records API (AC 8) | tested through the two tenant APIs that can reach a tenant row (`PATCH /tenant/settings`, `PATCH /tenants/:slug`); the entities API cannot reach the `tenants` table, and `Tenant` changesets are pinned in `scope_enforcement_on_test.exs` T-O5 |
| the post-`on` lockout (SEC F-1: the last-admin guard counts token owners) | an accepted, documented follow-up; no test asserts the trap exists, to avoid pinning a defect |
| the scan tests cannot be mutated in memory (they read files from disk) | each scan is proven live on a seeded offender instead (AST pairs in every spelling, SQL and bulk setters, a temporary directory holding a seeded `UPDATE tenants SET scope_enforcement = 'on'`, seeded bad documents for the docs rules, a seeded default-sourced `/me` route and a seeded pending ruling for the walk) |

## Cleanup of the stale `on` tenants in the shared local test database

Found: three tenants stored `on` (slugs `req519-n5-mix*`) made the two T-O1 migration-down tests of `scope_enforcement_on_test.exs` fail locally ("rollback refused: 3 tenant(s) are stored as on"). Measured before: 14 of 16 passed.

Cause: `test/letflow/identity/binding_no_row_report_test.exs` T-N5 ("the mix task output") commits an `on` tenant and runs `Mix.Tasks.Letflow.BackfillRoleScopeGrants.run/1`, which calls `System.halt(1)` when a tenant fails. A halt kills the VM before any `on_exit` runs, so the tenant stays `on`; and `TenantAdminMigrationFixture.isolate_registrations!/1` had deleted the registrations of the other tenants (put back only in an `on_exit`), so the suite-boundary reaper (`TenantSchemaReaper.sweep_orphans/2`, which works from `tenant_schemas` rows) could not reclaim them. No other test commits an `on` tenant without the fixture teardown (all other `set_stored_mode!(..., :on)` callers sit on `TenantFixture.provisioned_tenant!/1` tenants whose `on_exit` drops the schema and deletes the row; the thread that matters is a killed VM).

Fix: `EnforcedWritersFixture.purge_stale_enforced_tenants!/1` (drops the schema, the registration and the `tenants` row of every tenant whose slug starts with the prefix, is stored `on` and was last touched more than ten minutes ago; total over what a kill can leave: per-tenant try/rescue with a logged skip, per the anti-pattern "a self-heal wired into setup that is not total"), called from the `setup` of the T-N5 describe. The existing `on_exit` cleanup of the fixture stays.

Local database healed by the project's own test path (no manual SQL): running the file purged the three rows (3 `DROP SCHEMA` + 3 `DELETE FROM tenants`), and `scope_enforcement_on_test.exs` then passed 16 of 16.

## Hard facts that shape the tests (found by running, not assumed)

| Fact | Effect |
|---|---|
| the HTTP route cannot inject `now` | the HTTP flip tests use `OnGateFixture.backdate_shadow!/1`: stored `shadow`, a RAW "entered shadow" entry eight days old, `requests` counters for every date from nine days ago to TOMORROW (so a run across UTC midnight still has its window covered); the flip-level tests use the injected clock `fx.now` = `t0 + 7 days` of a genuine flip entry |
| `Scope.require_tenant_wide` runs inside the PUT / GET handlers and reads `role_scope_grants` | a gate raise over HTTP must come from a table only the gate reads (`api_tokens`, fact 3); renaming `role_scope_grants` raises in the authority check first (a `Plug.Conn.WrapperError`, not the 500 under test) |
| a role-less OIDC user has no permission for any route, not even `/me/memberships` | the e2e JIT-provisions users through `AuthPipeline.call/2` alone |
| the four checks of `require_interactive_tenant_admin/1` overlap | a token is stopped by the credential check AND by `effective_scope` (`grants: :token` is `:deny`); a scoped-only admin by `require_tenant_wide` AND `effective_scope`; a platform admin by the role check AND `effective_scope`. Single-check mutants survive by design; the PAIR mutants are killed (see the mutants) |
| building a tenant through `OnGateFixture.admin_tenant!/1` (or `PlatformTenantFixture.unpin!/0`) CLEARS the platform pin | the platform-tenant row of the matrix first built its reference tenant AFTER the pin, so the "platform admin" was an ordinary caller and the row was vacuous (found by mutant MU-37bc surviving); the reference is now built first and the pin is asserted |
| `PlatformTenantFixture.pin!/1` registers its own `on_exit` and refuses to run from another `on_exit` | the tests call `Fixture.unpin!()` only in `setup` |
| a gate-raise rename must be committed DDL restored in an `after` | `OnGateFixture.with_renamed_table!/3` (2f-a) is reused |
| `ExUnit.CaptureLog.with_log/1` captures Ecto debug QUERY lines (bound ids) | every log assertion is made on the constant line extracted by marker, never on ids over the whole capture |
| `Audit.list_entries/1` has no action filter | T-A6 filters by resource and groups by action in the test |
| the 409 problem body carries the extensions at the top level | key sets are pinned as `base problem keys ++ extension keys`, the base derived from a plain 409 |

## Mutants

Applied in memory only: the edited source of ONE lib file is compiled into the test VM (`Code.compile_string`, ignore_module_conflict) through `mix do run --no-start -r mut.exs + test <files>`; the anchor must occur exactly once (CRLF normalised); the loader and the runner live in the session scratchpad, not in the repository; nothing on disk changed, so there is nothing to revert (`git status` checked). Counts are failed tests of the files named. A run with a compile error or an anchor miss is recorded INVALID and was fixed, never counted as a kill (the first batch was INVALID for that reason and was re-run).

Flip level (`scope_enforcement_transitions_test.exs`, 36 tests):

| Id | Mutation | Killed by (failed / run) |
|---|---|---|
| MU-22a | `on_checks!/3` does not take lock S | T-G10 flip half (1 / 36) |
| MU-22b | the facts are read BEFORE lock S is taken | T-G10 flip half (1 / 36) |
| MU-23 | `off -> on` allowed (the `shadow_required` clause removed) | T-X5 x3 (3 / 36) |
| MU-39 | a raised gate is recorded as a refusal | T-G9 flip half x3 (3 / 36) |
| MU-39b | the `rescue` narrowed so the transaction no longer encloses a Postgrex raise | (4 / 36) |
| MU-42 | `flush_evidence/0` dropped from `flip/4` | T-E16 flip half (1 / 36) |
| V7a | `clock/1` returns any non-nil `:now` | V7b test (1 / 36) |
| V7b | `clock/1` ignores `:now` | every injected-clock test (22 / 36) |
| MU-21 | `enable_checks!` also runs for `on -> shadow` | T-X10 (3 / 36) |
| MU-24 | the audit action keyed on `target == :shadow` | T-X7 (7 / 36) |
| MU-rank | `rank(:on)` = 1 | T-X7 (5 / 36) |
| MU-13a | the mandatory `on -> shadow` reason removed | T-X9 (1 / 36) |
| MU-13b | `check_reason(:off, nil)` accepted | T-X4 / T-X13 (3 / 36) |
| MU-gate-bypass | `shadow -> on` runs no gate | (15 / 36) |
| MU-gate-ignored | gate failures ignored (no rollback) | (12 / 36) |
| MU-20a | `parse_mode("ON")` accepted | T-X1 (1 / 36) |
| MU-20b | `parse_mode/1` mints atoms | T-X1 (1 / 36) |
| MU-same | the same-mode no-op removed | T-X6 (2 / 36) |
| MU-38b | the refusal audit never written | (10 / 36) |
| MU-38c | `shadow_required` not audited | T-X5 (1 / 36) |
| MU-38d | the refusal records the wrong previous mode | (5 / 36) |
| MU-payload | the success entry drops the gate payload | T-X2 (1 / 36) |

Router level (`tenant_scope_enforcement_on_test.exs` + `routers/service_principal_route_test.exs` = 40, or + `on_flip_guards_test.exs` = 39):

| Id | Mutation | Result |
|---|---|---|
| MU-37e | the PUT uses `with_tenant_wide` (tokens and platform admins pass) | KILLED (4 / 40) |
| MU-37ac | the credential check AND the `effective_scope` check dropped | KILLED (5 / 40; 4 of them in the router file) |
| MU-37bc | the TENANT_ADMIN role check AND the `effective_scope` check dropped | KILLED (1 / 22 by the router file alone: the platform-tenant row; the pre-existing T-P2 of the service-principal test also kills it). It SURVIVED the first form of the test, see Hard facts |
| MU-37cd | the tenant-wide check AND the `effective_scope` check dropped | KILLED (4 / 40) |
| MU-37a / b / c / d | ONE check of `require_interactive_tenant_admin/1` dropped (credential; role; effective scope; tenant-wide) | VALIDATOR RULING: a, b, d are EQUIVALENT (a token principal has `grants: :token` so `effective_scope/2` is `:deny`, any other credential has no principal; `effective_scope/2` is `:deny` for a role not held, so the role check is subsumed; the tenant-wide permission check passes for every caller that passes the role and effective-scope checks). c is NOT equivalent: only a platform-tenant user holding PLATFORM_ADMIN plus a SCOPED TENANT_ADMIN row passes the other three; the validator added the test "platform tenant: PLATFORM_ADMIN with only a SCOPED TENANT_ADMIN row is refused every transition" (kills MU-37c, 1 of 42) and a role-less-context pin |
| MU-S5 | the router passes a body `now` to `flip/4` | KILLED (1 / 39): the body-clock test (and the literal-attrs AST scan) |
| MU-52a / b / c | the 500 path logs nothing / logs the fault term / answers 200 | KILLED (2 / 39 each) |
| MU-int-a / b / c | the integrity rescue logs nothing / logs the exception message / answers 200 | KILLED (1 / 39 each) |
| MU-modes | `available_modes` lists two modes | KILLED (2 / 39) |
| MU-curmode | `current_mode` is not the constant `off` | KILLED (1 / 39) |
| MU-evid | the 409 drops the evidence summary | KILLED (1 / 39) |
| MU-report | the 409 `report` drops the informational worker count | KILLED (1 / 39) |
| MU-og-counts | `OnGate.counts_state/1` zeroes `scoped_approvers` | KILLED (1 / 39) |

Platform tenant and route walk:

| Id | Mutation | Result |
|---|---|---|
| MU-53b | a platform-scope permission is decided by the grants (both the platform clause and the PLATFORM_ADMIN shortcut of `tenant_effective`) | KILLED (1 / 8): T-O7 |
| MU-53 | only the platform clause of `allowed?/3` | SURVIVED: `tenant_effective` has its own PLATFORM_ADMIN shortcut; MU-53b removes both |
| MU-T-O8 / b / c | `effective_roles/2` keeps PLATFORM_ADMIN outside the platform tenant / plus `has_permission_in_scope?/3` ignores the platform flag / plus `evaluate_access/2` keeps the role | SURVIVED (0 / 8) even with three layers removed: the inertness is enforced by further layers (the auth pipeline's role resolution and the router handlers); the test pins the observable outcome (403), killing it needs every layer gone |
| MU-RW | the `/help/resolved` ruling is `:pending_sec_ruling` | KILLED (3 / 8): T-RW2, T-RW3, T-RW4 |

48 mutants: 40 killed, 8 survived (MU-37a/b/c/d, MU-53, MU-T-O8/b/c), each a single removal from a defence-in-depth stack and analysed above.
