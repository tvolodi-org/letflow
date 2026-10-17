# GH #2739 -- `GET /entities/definitions` list honours TypeAccess

Design: `lib/letflow/design/gh2739-definitions-list-type-access.md` (T-1..T-17, mutants M1..M10).
Branch `feature/WF02-GH2739-DEFS-LIST-20261017`. Tests written by TEST-DESIGNER against the implemented code
(ELIXIR-DEV, step 04). The design is the AC source; the GH issue's ACs are mapped through design section 9.

## Files

| File | Kind | New / edited |
|---|---|---|
| `test/letflow/routers/entities_definitions_list_type_access_test.exs` | HTTP (Plug.Test, real Postgres tenants) | new: T-1, T-2 (2 tests), T-3, T-6, T-7, T-8, T-10, T-11, T-16, T-17 = 10 tests |
| `test/letflow/entities/definitions_list_type_access_test.exs` | context, real Postgres tenants | new: T-4, T-5, T-9, T-12 (2 tests), T-13, T-14, T-15 (2 tests) = 9 tests |
| `test/support/definitions_list_fixture.ex` | shared fixture | new: fixed-uuid / fixed-timestamp row table, restriction/grant/user helpers, cursor decode/craft |
| `test/support/query_count.ex` | shared helper | new: `Letflow.TestSupport.QueryCount.count_statements/1` (T-9) |
| `test/letflow/entities/definitions_test.exs` | context | edited: the 12 `list_definitions/2` calls (AC5 block) migrated to `/3` with `@unrestricted_viewer` (a binary uuid with no restriction or grant); assertions unchanged |

Existing `type_access_test.exs`, `entities_type_access_joins_test.exs`, `request_access_test.exs`, the REQ-394 blocks of
`entities_test.exs` are NOT modified.

## Determinism (design section 10)

Fixture rows (`Letflow.TestSupport.DefinitionsListFixture`) have fixed uuids `00000000-0000-4000-8000-0000000000NN` and fixed
distinct `inserted_at` (2026-03-01 + N minutes). Oldest to newest: `x0 a1 x1 a2 x2 a3 b1 x3` (x = `x_ent`, 4 versions, one active;
a = `a_ent`, 3 versions; b = `b_ent`). Raw list order (newest first): `x3 b1 a3 x2 a2 x1 a1 x0` -- a denied row leads (x3), is
interleaved (x2, x1) and trails (x0). Visible for a caller denied `x_ent`: `b1 a3 a2 a1`. "World without X" is a second real tenant
seeded with the same rows minus the `x_ent` versions. `next_cursor` carries its mint time, so where non-null the tests compare the
DECODED last-row position and null-ness; raw bytes are compared only where `next_cursor` is null. The only textual masking is the
world-specific `artifact_version_id` uuid in the body and the volatile headers `date`, `x-request-id`. Crafted cursors use a FIXED
unknown uuid, never a random one.

## AC -> test map

| AC (design section 9 / issue #2739) | Test(s) | Why it exists |
|---|---|---|
| Failing test: denied X absent for a page size that would include it | router T-1 (page sizes 1,2,3,4,5,6,7,200; no x id, no `x_ent` text in body; granted caller in the same tenant DOES see all 8 rows) | red on main (list returns every row); the granted-caller control proves the fixture really contains X |
| Page contents and `next_cursor` equal the world without X | router T-2 (walk every page at all 8 sizes in both worlds; names, ids, null-ness, decoded position equal; each cursor names the page's last VISIBLE row), T-2b (explicit: size 4 -> one page, `next_cursor` nil because only a denied row trails; size 3 -> `b1 a3 a2` + cursor at a2, then `a1`; size 1 -> 4 pages), T-11 | the page-size/ending-exactly-on-a-denied-row/trailing-denied-tail cases of SECURITY R4; kills post-filter (M1) and over-fetch-row cursor (M6) |
| Cursor from an unfiltered view cannot enumerate | context T-4 (cursor minted by a granted user whose last row is the denied x2, replayed by a denied user: exactly `a2 a1`, no error, equals a never-existing tuple in the world without X), T-5 (cursor naming denied x1 / x3 vs a cursor naming an unknown id at the same timestamp, sizes 1,2,200: items, null-ness, position equal) | design D4 items 3-5; kills the cursor-branch-unfiltered mutant (M2) |
| Cursor error statuses independent of visibility | router T-6 (expired 410, wrong-endpoint 400, garbage 400, identical in denied and absent worlds) | no new oracle through error paths |
| Envelope has no count/total | router T-3 | `Page.count` must never be rendered unfiltered |
| Response unchanged for a caller with no denied type | router T-7 (golden derived from the fixture row table: full item shape for all 8 rows unrestricted, for a granted user after the restriction, and cursor position of a size-3 page; denied user gets golden minus x), context T-15b (`/3` with an unrestricted user returns all versions) and the migrated AC5 block of `definitions_test.exs` | non-regression; kills inverted EXISTS (M3) |
| name / entity_type / status params are not a confirmation channel | router T-8 | the router reads only `cursor`/`page_size`; the response with those params equals the response without |
| Three single-definition GETs unchanged | router T-10 (real created+activated `k_ent`: active, by-name and by-id answer 200 unrestricted, a denied caller gets exactly the bytes of an absent name/id, a granted caller 200) | regression for the already-gated routes |
| Denied == absent over HTTP | router T-11 (every page of every size: status, headers minus date/request-id, items, cursor position, raw bytes where `next_cursor` is null; asserts a null-`next_cursor` page was compared) | INV-5 |
| All denied | router T-17 (denied every type vs an empty tenant: status, headers, bytes; body is `{"items":[],"next_cursor":null}`) | kills post-filter with short pages (M1) |
| One statement regardless of denial | context T-9 (`QueryCount.count_statements/1` over `list_definitions/3`: denied user in the denied world == bystander in the world without X == granted user) | INV-5 / gh2700 Q7 equal work |
| Tenant prefix gate, both directions (SECURITY R1, blocking) | context T-12a (restriction in A hides in A, not in B), T-12b (restriction only in B does not hide in A), two real tenant schemas | kills unprefixed subquery (M9) |
| Rule inputs (SECURITY R2) | context T-13 (restriction for another name, other user's grant, caller's grant for a different type, then caller's own grant) | kills grant-ignores-user (M4) |
| One rule in three consumers (SECURITY R2) | context T-14 (3 steps: restricted+no grant with duplicate-name versions and a grant for a different type; restricted+granted; restricted with another user's grant only; plus an absent name; `authorized?/3`, `denied_types/3` and list visibility agree, explicit expected visible sets) | kills divergence (M10) |
| No unscoped sibling; fail closed | context T-15 (`function_exported?(Definitions, :list_definitions, 2)` is false, `/3` is exported; `nil`, atom, integer viewer raise `FunctionClauseError` from `list_definitions/3` and `TypeAccess.visible_to/2`; non-atom binding raises) | kills `/2` kept (M8); guards never allow-all |
| No admin bypass | router T-16 (TENANT_ADMIN token, no grant: `x_ent` absent). Every router test uses a TENANT_ADMIN caller, so the denial is exercised for the highest tenant role | kills a role bypass (M7) |

## Mutants (for TEST-DESIGN-VALIDATOR; killing test named per mutant)

Not measured locally: free memory was 3.48 GB (< the 4 GB gate), so no `mix test` was run by TEST-DESIGNER and no mutant was
applied. The table is the predicted kill map from reading the tests; TEST-DESIGN-VALIDATOR should apply at least M1, M3 and M9.

| Mutant | Edit | Killed by |
|---|---|---|
| M1 post-filter | read the page, then drop denied rows in Elixir | router T-2 (size 4 expects 4 visible rows), T-17, T-11 |
| M2 cursor branch unfiltered | apply `visible_to` only when no cursor | context T-4, T-5 |
| M3 `exists` instead of `not exists` | invert `visible_to/2` | router T-1, T-7, context T-13/T-14 |
| M4 grant ignores `user_id` | drop the `g.user_id` condition in `denial_query/1` | context T-13 (another user grant), T-14 step 3 |
| M5 restriction match only on active rows / wrong column | filter `status` in the subquery | router T-1 (x0, x1, x3 are inactive) |
| M6 cursor from the over-fetch row | mint from the unfiltered extra row | router T-2 |
| M7 role bypass | skip the predicate for TENANT_ADMIN | router T-16 and every router test |
| M8 `/2` kept | re-add `list_definitions/2` | context T-15 |
| M9 predicate not tenant-prefixed | explicit wrong prefix in the subquery | context T-12a/T-12b |
| M10 `authorized?/3` or `denied_types/3` diverges | edit one consumer | context T-14 |

## Run results

NOT RUN by TEST-DESIGNER (memory gate). Verified only: `mix format` on all touched files (rc=0) and
`MIX_ENV=test mix compile --warnings-as-errors` (compiles `test/support/*.ex`, including the two new support modules; clean:
"Compiling 2 files (.ex) / Generated letflow app"). The `.exs` files are not compiled by that command. Hosted CI / TEST-RUNNER
runs them.
