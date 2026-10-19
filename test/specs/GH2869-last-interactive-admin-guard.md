# GH #2869 test spec: the last-interactive-admin guard of an `on` tenant (parts (a) and (c); REQ-519 gate)

Design: `lib/letflow/design/gh2869-last-interactive-admin-guard.md` r4 (tests T-LA-*, mutants MU-LA-*, AC map section 8, tests that change section 6, docs text sections 10 and 13).
ELIXIR-DEV handoff: `handoffs/WF02-GH2869-LASTADMIN-20261019/step-04-elixir-dev.json` (deviations D1-D6). TEST-DESIGNER handoff with real counts and mutants: `step-05-test-designer.json` in the same folder.
Source under test (uncommitted, not changed by this step): `Letflow.Identity.TenantAdminGuard.ensure_interactive_admin_remains!/4` and `interactive_admin_check/2`, the six guarded call sites (`Identity.update_locked_user`, `Identity.do_remove_group_member`, `RoleRegistry` unbind and rebind, `ScopedGrants.delete/3`, `ServicePrincipal.do_set_flag/5`), `Letflow.Identity.LastAdminPaths`, the router mappings, decision 0051 A12, `docs/roles.md`, the runbook.
Nothing under `lib/`, `priv/` or `docs/` was changed by this step. Nothing is committed.
Resource rules followed: no `mix letflow.check.test`, no full-suite or multi-partition run (the supervisor instruction overrides the role default; hosted CI is the suite); per-file `mix test`, one mix at a time; every `on` tenant is a throwaway fixture tenant that an `on_exit` stores `off` again before the tenant teardown; mutants applied in place from a byte-exact backup and restored (sha256 of every `lib/` file compared with the starting state after each mutant).

## Fixture property (why the per-path tests are not vacuous)

`Letflow.Support.LastInteractiveAdminFixture.on_tenant!/1` builds a real tenant stored `on` with EXACTLY ONE interactive explicit admin A1 (member of the admin group, which holds the tenant-wide row) PLUS a second active user T1 who owns a live `TENANT_ADMIN` token and is in no group. The OLD counted guard therefore sees TWO admins after A1 is removed and would let every removal through; only the new guard can refuse. `assert_last_interactive!/2` asserts exactly that premise (stored mode, interactive count 1, counted count at least 2). The P4 test proves the premise for the rebind separately (see below).

## Files

| File | Tests | Ids |
|---|---|---|
| `test/letflow/identity/last_interactive_admin_guard_test.exs` | 63 | T-LA-P1..P6, T-LA-19, 20, 21, 22, 23 (function half), 27, 28 |
| `test/letflow/identity/last_interactive_admin_controls_test.exs` | 19 | T-LA-P7..P17, T-LA-17, T-LA-29 |
| `test/letflow/identity/last_interactive_admin_race_test.exs` | 10 | T-LA-24, T-LA-25, T-LA-26 |
| `test/letflow/identity/last_admin_paths_test.exs` | 10 | T-LA-18, T-LA-30 |
| `test/letflow/routers/last_interactive_admin_routes_test.exs` | 28 | T-LA-H1..H7, T-LA-23 (HTTP half) |
| `test/letflow/docs/roles_on_flip_docs_test.exs` | +4 (27 -> 31) | T-LA-31 |
| `test/letflow/identity/enforced_writers_lock_test.exs` | +2 (18 -> 20) | bounded T-L8 |
| `test/support/last_interactive_admin_fixture.ex` | helpers | NEW |
| four existing guard test files | comment only | the `reason_code` assertions of the old paths are the DEFAULT value (design section 6); no assertion changed |

## AC -> test (design section 8)

| Source | Requirement | Tests | Why the test exists (what it would catch) |
|---|---|---|---|
| #2869 (a) | in an `on` tenant refuse removing the last interactive explicit tenant-wide TENANT_ADMIN | T-LA-P1..P6, T-LA-20 (on refuses, shadow and off allow) | a guard that counts tokens, flagged principals or zero-row members (T-LA-19); a guard that also fires in shadow/off (T-LA-20); a guard skipped on one path (one mutant per path) |
| #2869 (a) | removing | P2 (membership), P5 (grant row), P1 | P2 refuses with a token owner present; P5 refuses on A1's USER row in a zero-row admin group, and the older `last_admin_binding_row` still wins for a group's sole row |
| #2869 (a) | demoting | P3 (unbind), P4 (rebind) | P3 stays refused even with two admins (an unbind removes every member-admin at once); P4 proves first that the OLD counted guard WOULD pass (members of the new group, no tenant-wide row, token owner removed so only G2's members are counted) and the interactive count is 0, then that the new guard refuses |
| #2869 (a) | deactivating | P1, P1b (profile + status) | the refused deactivation must NOT revoke the user's tokens and must leave the user active (content snapshot equality) |
| #2869 (a) | scoping | T-LA-P11a (four shapes), P11b | the design claims scoping cannot lower the interactive count; the invariance test guards the claim, including a member of the admin group scoped while the group holds the row |
| #2869 (a) | flagging as a service principal | P6 | refused; flag stays false; NO `service_principal.flagged` entry; unflag and flagging a non-admin allowed; a missing, blank or invalid reason answers `:reason_required` / `:invalid_reason` and writes no guard entry (existence-oracle order, MU-LA-20) |
| #2869 (a) | typed 409 in the style of `last_admin_binding_row` | T-LA-H1..H7, T-LA-27 | seven routes: status 409, `detail` the new code, the body names no id of any principal, group, binding, token owner and carries no count; nothing changed; one event with the six keys and `counted_admins` 0; the service-principal route is a 409 not a 500 (clause before the catch-all) |
| #2869 (a) | cover EVERY write path that takes lock A | T-LA-30 + one test per path | the inventory (23 sites) equals the AST scan of `lib/`; every guarded row's `:guard` function exists and calls its `:guard_call`; no N or X row calls a guard; the guard-calling functions in `lib/` are exactly the guarded rows' guards; seeded offenders prove each detector |
| #2869 (a) | one test per path | T-LA-P1..P17 for P1 to P17; P18 by T-LA-26; P19 (5 class-X sites) by the T-LA-30 scan only | P7 add (and the transition rule at zero), P8 delete_group, P9 role-claim sync, P10a/b token mint/create, P11 scoping, P12 token revoke, P13/P14 pending grant revoke/bind, P15 seeding, P16 TenantAdminMigration, P17 Backfill: each allowed, count not lowered |
| issue body | same interactive-explicit definition as gate fact 4 (one predicate, not a copy) | T-LA-17, T-LA-18 | divergence matrix of eight shapes (gate input equals the guard's before-count equals the expected number); the guard module has no query of its own; exactly ONE function in `lib/` builds a query for the `:interactive_explicit` mode (tenant_wide_admins_query/3), defined by a query that reads the flag field and mentions the mode |
| issue body | lock order | T-LA-24, T-LA-25 | queue order fixed by `BreakGlassFixture.queue_two!/3` (barrier connection holds lock A, first worker parks, second parks, release): two concurrent removals of the last two admins, exactly one commits; no deadlock/lock-timeout telemetry |
| issue body | token paths, role-claim sync | P9, P10, P12 | none lowers the interactive count |
| issue body | interplay with break-glass | T-LA-26, T-LA-29 | after `flip_out_of_band(on -> shadow)` the same removal succeeds; the break-glass changes no admin row (snapshot); a removal racing the break-glass serialises on lock A in both orders; recovery at zero: a token adds a member (count restored), cannot flip (403), the break-glass flips down |
| #2869 (c) | a decision record says whether A7 covers this | T-LA-31 | A12 exactly once, Amendment 4, after A11, last paragraph; A11 byte-checked by SHA-256 of its whole paragraph (not edited); A10 text; no A13; every A12 claim of design section 13 (incl. "Does A7 cover this case? Partly.") fires when removed; the Gate paragraph of BOTH documents keeps `is delivered by GH #2883`, drops `(still open)`, names `last_interactive_tenant_wide_admin` and "the guard cannot see an administrator who exists in Letflow", and the two documents are identical |
| REQ-519 AC 23 | seven `LIMIT-*` items unchanged | existing T-BG-30 test (unchanged, green) | |
| REQ-519 AC 24 | process gate sentences | existing AC 24 test (unchanged, green) | |

## Per-path expectations that differ from the design text (recorded, not hidden)

* **P4 fixture.** The design says that in an `on` tenant a rebind "skips the move of grant rows". The code (`RoleScopeGrants.move_rows!`) clears the target group's own rows and MOVES the old group's rows; only when ZERO rows move (and the tenant is `on`) is the move skipped. So the F3 shape (members of the new group, no tenant-wide row) arises only when the admin group holds NO grant row (A1's basis is a user row): `userize_admin_row!/1` builds that shape. With a group row the row follows the binding and the new group's member becomes an interactive admin (pinned as the allowed control and as T-LA-21's first step).
* **P4 and the unreadable mode.** `RoleScopeGrants.reconcile_binding!` already reads the mode under lock for a platform-to-platform move, so a rebind in an unreadable tenant fails closed independently of the new guard, and the "second admin never reads the mode" claim of the bounded T-L8 cannot hold for a rebind. T-LA-23's second-admin variants therefore cover P1, P2, P5, P6 only; P4's fail-closed half is the table test (it passes because reconcile raises, and the new guard's own read after it is unobservable).
* **P8.** Deleting the POPULATED admin group answers `:not_found_or_has_members`; `:bound_to_role` is the answer for a MEMBERLESS group bound to a role. Both are asserted; neither changes the count.
* **T-LA-23 HTTP half.** Renaming only the schema makes a request fail on a missing table BEFORE the guard (a vacuous 500), because the router derives its prefix from the auth_context tenant id (`schema_name_for_tenant/1` is a pure derivation). `with_unreadable_mode/2` therefore renames the schema to a well-formed `tenant_<32 hex>` name with no `tenants` row AND moves the fixture's `tenant_id` to the id that name encodes; every table read then works and ONLY the mode read raises. Proven non-vacuous by mutant MU-LA-8 (fail open): 6 of the 7 HTTP routes fail (h4 excluded, see the P4 note above).
* **T-LA-25 fixtures.** The flip race tenants have no token owner (a token exceeding its owner fails gate fact 3) and one flagged service principal in the admin group, so the OLD counted guard still sees the principal and only the new guard decides the post-flip removal.
* **Log assertions.** The refusal-event write failure logs `tenant_admin.guard_refused audit write failed`; the test asserts exactly one such line and that THAT line carries no id (other lines of the captured log are SQL with ids).

## Mutants

Measured counts are in the TEST-DESIGNER handoff (`result.mutants`). MU-LA-15 (unflag guarded) is an equivalent mutant: an unflag only raises the count, so a guard on it can never refuse; T-LA-P6 still pins that unflagging is allowed.

## Coverage check

- [x] Every acceptance criterion above has at least one test case listed
- [x] The six guarded paths each have: refusal, nothing-changed snapshot, one six-key event with the new reason code, a second-admin success, a mode matrix, a fail-closed case, an HTTP 409 and an HTTP 500
- [x] The completeness of "every path" is a standing scan, not a list
- [x] No wall-clock dependence; no unseeded randomness; queue order by construction (barrier), not by sleeps
