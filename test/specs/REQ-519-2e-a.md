# REQ-519 slice 2e-a test spec: enforced-tenant binding writers (GH #2535, decision 0051 D1, SEC C-1/C-2, F-1/F-2)

Design: `lib/letflow/design/req519-enforced-writers-and-flag-on.md` r2a (sections 3.2 to 3.6a, 3.7, 3.10, 8.1, 9; AC map section 7).
Scope: REQ-519 acceptance criteria 1, 5, 6 and 7 (the `binding.refused` half) for PR 2e-a; AC 21 is the PR gate (commands, not tests). ACs 2, 3, 4 and the other AC 7 actions are slice 2e-b; 8 to 20 and 22 are 2f.
Also covered: the SEC code gate (step-06) MERGE CONDITIONS F-1 and F-2 and the C-2 test, and the REVIEWER (step-07) notes (rows_state, lenient key, registry).
Nothing under `lib/` or `priv/` was changed by this step. Nothing is committed. Real results (including mutants) are in `handoffs/WF02-REQ519-ENFORCED-WRITERS-20261018/step-08-test-designer-2e-a.json`.
Resource rule followed: no `mix letflow.check.test`, no full-suite or multi-partition run; per-file `mix test`, one mix at a time under the shared mixlock.

## Files

| File | Tests | Ids |
|---|---|---|
| `test/support/enforced_writers_fixture.ex` | helpers | provisioned tenant stored in a given mode, seeded tenant, direct `Routers.Identity` dispatch, audit readers |
| `test/letflow/identity/binding_writers_modes_test.exs` | 50 | T-B1..T-B14, each row in `off`, `shadow` and `on` |
| `test/letflow/identity/binding_refusal_test.exs` | 10 | T-R1..T-R6 (+ `binding_policy` cannot come from HTTP) |
| `test/letflow/identity/binding_no_row_report_test.exs` | 16 | T-N1..T-N6 |
| `test/letflow/identity/binding_writers_scan_test.exs` | 15, async | T-C1, T-C2 (SEC F-2), `binding_policy` text scan |
| `test/letflow/identity/enforced_writers_lock_test.exs` | 18 | T-L1, T-L2..T-L8 (SEC F-1, C-2) |
| `test/letflow/identity/enforced_writers_invariant_test.exs` | 5 (1 property) | T-I1, T-I2 |
| `test/letflow/identity/enforced_audit_actions_test.exs` | 2 | T-A1, T-A2 (2e-a part) |

Forced edits to existing tests were made by ELIXIR-DEV (exact report maps gained `skipped_enforced` / `rows`); none by this step.

## AC -> test

| AC | Tests | Why it exists (what it would catch) |
|---|---|---|
| 1 REFUSED (a), (b) | T-B1, T-B2, T-B14 (HTTP), T-R1, T-R2 | `nil -> platform` and `routing -> platform` must write no binding, no row, and answer 409 in `on`; in `off`/`shadow` they must still succeed exactly as before (guards against refusing everywhere) |
| 1 UNCHANGED (b2), (f1), (f2), (d1) | T-B3 (incl. the N1 last-admin guard still running), T-B10, T-B11, T-B7, T-L8 | removal and moves never widen and never depend on the mode; T-L8 proves a removal passes even when the mode cannot be read |
| 1 NO-ROW (c1), (c2), (c3), (d2), (e), (g1), (g2) | T-B4, T-B5, T-B6, T-B8, T-B9, T-B12, T-B13; T-N1..T-N6 | the write succeeds without a tenant-wide row AND is reported three ways (explicit result, one constant log line with no ids, T9/integrity showing the gap); the `has its row` and `scoped-row-only` variants prove it is not simply always skipping |
| 1 audit key | T-N3, T-A2 | seeding in `on` marks the binding audit with the fixed key `rows = skipped_enforced`; the key is absent in every other mode |
| 1 completeness | T-C1 (scan equals SCANNED rows as a multiset; scanner proven live on seeded unregistered, aliased, piped, captured and `apply/3` sources; look-alikes do not match), T-C2 (every INDIRECT row names an existing function that still reaches a scanned site; the registry entry points reach `reconcile_binding!`) | a new writer cannot be added unclassified; a rename or a dropped call cannot orphan an indirect row |
| 1 `binding.refused` | T-R3 (written AFTER the rollback, exact key set `{actor, role, group, case, trace_id}`, nothing else survived), T-R4 (raising and non-raising audit failure still return the refusal, constant lines), T-R5 (inside a transaction: nothing written, constant line) | the audit must outlive the rolled-back write; the tenant fixture runs in `:auto`, so an entry written inside the rolled-back transaction would not exist |
| 1 HTTP body | T-R1 (fixed body bytes and key set, no id, no role name), T-R6 (remedy string pinned), T-N1/T-N2 (`grant_rows` only when skipped; otherwise keys exactly `created_at group_id id kind name`) | INV-2: fixed remedy, no existence oracle; additive field only when true |
| 5 | T-I1 property over the writer set in `on` (upsert every kind/group, rebind, seeding, backfill, direct `reconcile_binding!` with every shape, the two low-level inserters, a `drop_rows` gap-maker): the `tenant_wide = true` count never increases; controls: the sanctioned `insert_tenant_wide/4` DOES move it, and each writer alone on a gap leaves it unchanged. T-I2: `off`/`shadow` legacy writers still insert | by-construction guard; the control keeps the property from being vacuous |
| 6 | T-L2 (writer queued first under a REAL held lock A: its binding and row commit before the flip, which sees them), T-L3 (flip queued first: the writer sees `on`, refuses), T-L1 (`mode_under_lock!/1` is transaction-only), T-L7 (C-2) | queue order is detected through `pg_locks`, not sleeps; "flip" is a transaction doing flip/4's core in flip/4's order because no route can set `on` yet |
| 6 / C-1, C-2 | T-L1 (failed read raises, key set or not), T-L4 (production shape: key unset, malformed and unregistered prefixes RAISE), T-L6 (key set: `:off` plus the constant line `scope_mode_read_lenient`, no prefix, registered tenants never lenient), T-L7 (a raised mode read leaves no binding, row or audit entry for the writer, the repair, rebind, seeding and `Backfill.run_tenant`) | INV-8: no fail-open default on a flag read |
| SEC F-1 | T-L4 (Config.Reader evaluation of config.exs + prod.exs + runtime.exs with env `:prod`, and dev: key unset; test: exactly `true`), T-L5 (text only in `config/test.exs`; lib reads it once, sets it never) | the test-only key cannot reach production |
| 7 (2e-a action) | T-A1 (`binding.refused` listed through `Audit.list_entries` resource filters, action on the item, chain verifies), T-A2 (no token plaintext, hash, e-mail, user name or password text in `binding.refused` or the NO-ROW `role_binding.created`; key sets) | the audit must be readable and secret-free |
| Backfill (design 3.6a) | T-B9, T-N5a (exact report map, no audit entry, no row, T9 unchanged), T-N5b (dry run via `get_mode/1`, unreadable/absent mode reports false, never errors), T-N5c (sweep continues past an `on` tenant), T-N5 mix task lines (counts only, no role name or group id) | the gap check must not error an enforced tenant; one `on` tenant must not halt the sweep |
| TAM, RoleBackfill (design 3.6) | T-B6, T-B13, T-N4 (real and dry run, snapshot equal), T-N3 (`skipped_enforced` list; the sweep carries on and seeds the other tenants) | the whole legacy plan is skipped in `on`, including the legacy removal and token rewrite |

## Hard facts that shape the tests (found by running, not assumed)

| Fact | Effect |
|---|---|
| `BindingRefusal` and `TenantAdminGuard` both guard "inside a transaction"; the tenant fixture leaves the sandbox in `:auto` | refusal tests are real commits; T-R5 opens an explicit `Repo.transaction` |
| `mode = unquote(mode)` in generated tests made the compiler infer a literal and warn on `mode == :on` | per-mode tests pass the mode through an `@tag` context instead |
| `bindings_without_row` also counts the legacy PLATFORM_ADMIN binding built raw by `Mig.legacy!/2` | the TAM tests give it a raw row so the count isolates the TENANT_ADMIN gap |
| `Audit.insert_entry/3` validates `tenant_<32 hex>`; an unregistered but well-formed schema name gives "no tenants row" | T-L7/T-L8 rename the fixture schema (committed DDL, restored in `after`) to exercise the unregistered path across connections |
| `lock_tenant_admins!/1` has no timeout | held-lock tests release within one poll deadline |
| the property macro of this `stream_data` emits a `register_test/4` deprecation warning | pre-existing, same for every property in the repo |

## Mutants

Applied in memory only (the edited source compiled into the test VM through `mix do run --no-start -r mut.exs + test <the 7 files>`; nothing on disk changed). Counts are in the handoff JSON (`result.mutants`).

## Not covered here (by design)

2e-b: sync suppression, `grant.sync_suppressed`, `binding.pending_scope`, `scope_delta`, `membership_rows/0`, `MembershipScope`, `SyncScopeGuard`. 2f: the flag value `on`, the gate, the flip route.
