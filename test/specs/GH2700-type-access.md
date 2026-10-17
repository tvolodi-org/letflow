# GH #2700 -- TypeAccess on the primary type and every join target (/query, export, aggregate)

Design: `lib/letflow/design/gh2700-type-access-joins-export-aggregate.md`.
Branch `feature/WF02-GH2700-TYPEACCESS-20261017`. Tests written by TEST-DESIGNER against the
implemented code (ELIXIR-DEV, step 04).

## Files

| File | Kind | New / edited |
|---|---|---|
| `test/letflow/routers/entities_type_access_joins_test.exs` | HTTP (Plug.Test, real Postgres tenant) | new, 26 tests (the per-route `for` blocks expand to 4 each) |
| `test/letflow/entities/request_access_test.exs` | unit, `RequestAccess.check/4` | new, 11 tests |
| `test/letflow/entities/type_access_test.exs` | unit, `TypeAccess.denied_types/3` | edited, +7 tests (T-16) |
| `test/letflow/entities/query_request_guard_test.exs` | unit, `request_entity_types/2`, `Compiler.join_entity_types/1`, tripwire | edited, +10 tests (T-14, T-15) |
| `test/letflow/routers/entities_query_restricted_walker_test.exs` | source test | edited: T-39 / A-12 replaced by T-18 (5 tests) |
| `test/letflow/entities/query_cursor_field_grants_test.exs` | source test | edited: chain-order test extended |
| `test/specs/GH2697-query-restricted.md`, `GH2699-aggregate-join-restricted.md`, `REQ-394.md` | docs | wording updated (3.1) |

Fixture (router file): tenant with `p_ent` (primary, `p_ref`), `j_ent` (declares `j_p_fk` -> P, direct
join), `t_ent` (through; `t_p_fk` -> P, `t_f_fk` -> F), `f_ent` (far), `n_ent` (allowed, unrelated),
`dangling_ent` (declares `d_fk` -> the NONEXISTENT `ghost_ent`). Two P rows: p1 has a J and a T row, p2
has neither, so `count` is 2 plain and 1 joined (the presence oracle). Caller is `TENANT_ADMIN` (holds the
unredacted-export permission); type denial has no role dimension. A type is restricted by inserting an
`entity_type_restrictions` row; the caller holds no `user_entity_type_grants` row unless a test says so.
"Absent" types are `ghost_ent`, `ghost_f`, `ghost_t`.

## AC -> test map

| AC (GH #2700) | Test(s) | Why it exists |
|---|---|---|
| join to a type-denied target returns no rows of that type on /query | router T-1 (direct), T-2 (through near hop), T-3 (far), T-4 (primary) | the three join positions plus the primary each hide the WHOLE request as `{"items": [], "next_cursor": null}`; asserts the body has no `r1`/`j_ent`, so a "denied target dropped, primary rows returned" implementation fails |
| export and aggregate on a denied type refused (ruled shape: 404) | router T-8 (aggregate, primary, with and without join), T-9 (aggregate presence oracle, 3 restricted targets), T-10 (export default and `unredacted`, primary and join targets, no audit row) | T-9 first proves the oracle is real (joined count 1 vs plain 2) and then that a restricted target answers 404 with no `count_none` |
| permitted case still works | router T-5 (grant on j/t/f; query, aggregate, export with 1 row), T-11 (granted primary on all 4 routes), T-12 (exempt export on an allowed type with a restricted FIELD still 200 and audited, and still 404 when the type is denied), unrelated-type restriction changes nothing | proves the gate is not over-blocking (kills "refuse everything" mutants) |
| no-restriction tenant unchanged | router T-19 (all routes, joins incl.; `entity_type_restrictions` stays empty) | REQ-394 default-allow guarantee extended to the new routes |
| unknown and denied join targets indistinguishable | router T-6/T-7 matrix x 4 routes (query, aggregate, export, export_unredacted): 12 cases -- primary, direct valid/wrong fk, far valid/wrong fk, through valid/wrong fk, far/through combined with a wrong-fk EARLIER join, primary-declares-fk-to-denied-far (vs `dangling_ent` -> `ghost_ent`), duplicate target, too many joins. Status, FULL body bytes and headers (request id and date masked) identical | the multi-join combination is the oracle D3 closes (M7); the duplicate/too-many cases pin that shape errors (422) precede the gate for both sides, comparing bodies after normalising the echoed type name |
| another user's grant does not help (R2) | router "ANOTHER user's grant" (all 4 routes), unit `type_access_test` and `request_access_test` | a grant row for user B on the restricted type must not lift the denial for the caller; kills a dropped user-id condition (M11) |
| refusal shape defined per route | router `assert_not_found_shape`: /query 200 `@hidden`, export/aggregate 404 with no `results`/`records`/`items` | D2 |
| type gate precedes the field guard | router T-13; unit T-17 ("denied beats restricted field") | a restricted field plus a denied target must be not-found, never 403; with the type visible 403 still appears |
| nothing leaks via logs/audit/telemetry | router T-20 (log at :info on all 4 routes has no type, fk, `restricted`, `denied`; audit count unchanged; `[:letflow,:http,:request]` metadata has no type name) | Q8 / M10 |
| equal gate work (SECURITY R1) | router T-22 (denied vs absent, all 4 routes, all `:hidden` cases) + "every distinct type gets an existence read even when the first is denied"; unit T-17 constant-work tests | see the T-22 note below |
| malformed element + too many joins -> unwalked, no crash | unit T-14 (`request_entity_types/2`: 7 tests), `request_access_test` malformed table | M13: the walk must precede the shape check |
| registry classification tripwire | unit T-15 (3 tests) | M9 |
| `denied_types/3` correctness | unit T-16 (7 tests): `[]` makes ZERO queries, mixed fixture agrees with `authorized?/3` for every type (incl. a type granted to another user only), duplicates deduped, constant query count in the number of types, quotes/SQL metacharacters bound as data, unresolvable prefix error | M11, M14 |
| single gate, no handler skips it (T-18) | walker file "T-39 router architecture": zero `FieldPolicy.check_request(` / `load_restrictions(` / `guard_row_request` in code lines; `TypeAccess.authorized?(` only in `render_get_definition`; every function that calls `Compiler.compile(` or `Compiler.run_aggregate(` has `RequestAccess.check(` ahead of it (non-vacuous: the three handlers must be among them); aggregate binding/else-shape assertions; `exempt?` literals; `query_cursor_field_grants_test` chain order build < paginate-opts < `RequestAccess.check(` < compile < allowlist < paginate < redact | M8 |
| existing suites unchanged (T-21) | no existing test failed: `entities_test`, `entities_export_test`, `entities_aggregate_test`, `entities_aggregate_restricted_join_test` all pass unedited | no R2 combined-error test existed to edit |

### T-22 note (design tension, reported to ORCH)

Design T-22 / R6 text says "EQUAL numbers of DB queries" for denied vs absent. The implementation (correctly,
per R6's own "accepted residual") does the same *gate work* but the TOTAL query count is NOT equal: one
`fk_defs/2` read costs 3 queries for a type that exists (`artifact_activations`, `artifact_versions`,
`entity_definitions`) and 1 for a missing type. Measured on the first matrix case with
`MIX_ENV=test mix test` before the rewrite: `{"primary", 7}` (denied) vs `{"primary", 5}` (absent) on query,
aggregate, export and export_unredacted. The tests therefore assert equality of the gate's own reads:
`entity_type_restrictions` queries (the single denied-set read) and `artifact_activations` queries (exactly one
per distinct type, found or not). That is the property that SECURITY ruling R1 actually requires and it kills
the short-circuit mutant (M12). It also makes the test independent of the once-per-second
`api_tokens.last_used_at` UPDATE (#2729), so no `measure_pair/4` retry is needed. If SECURITY wants TOTAL
equality, `Allowlist.fk_defs/2` for an absent type would have to do the same two extra reads: an implementation
change, not a test change.

## Mutants (M1..M14), local results

Run with `MIX_ENV=test mix test` over: `entities_type_access_joins_test.exs`, `request_access_test.exs`,
`type_access_test.exs`, `query_request_guard_test.exs` (104 tests in the baseline run unless noted). Each mutant
was applied to a copy-backed file and reverted byte-for-byte; `git diff -- lib` was empty after each.

| Mutant | Mutation | Result |
|---|---|---|
| M1 | `request_entity_types/2` returns the primary only (gate the primary type only: the original bug) | KILLED, 26 failed (T-1, T-2, T-3, T-9, matrix, T-10, ...) |
| M2 | `Compiler.join_entity_types/1` drops `through` | KILLED, 19 failed (T-2, matrix, T-14, ...) |
| M3 | field guard runs before the type gate in `RequestAccess.check/4` | KILLED, 16 failed (T-13, T-17 ordering, matrix) |
| M4 | denied mapped to `:request_field_restricted` instead of the shared atom | KILLED, 28 failed |
| M5 | exempt (unredacted) export skips `denied_types` | KILLED, 8 failed (T-10, T-12, export_unredacted matrix, T-17 exempt) |
| M6 | an error from `denied_types` treated as an empty set | SURVIVES: equivalent mutant. The existence step reads the same tenant id (`fk_defs/2` also returns `{:error, :invalid_schema_name}`), so with an unresolvable prefix the request is still refused; there is no input on which `denied_types` errors and `fk_defs` does not. The refuse-on-error test (`request_access_test`) documents the observable behaviour. |
| M7 | existence step reads only the primary | KILLED, 12 failed (matrix combined-earlier-wrong-fk, T-17 constant work, T-22) |
| M8 | a direct `FieldPolicy.check_request(` string in a router code line | KILLED, 1 failed (T-18 source test); run on the walker file only (55 tests) |
| M9 | a key added to the `:row` registry with no classification | KILLED, 6 failed (T-15 + the existing registry tests); guard test file only (51 tests) |
| M10 | `Logger.info` naming the denied types | KILLED, 1 failed (T-20); router file only (26 tests) |
| M11 | the per-user condition dropped from the `denied_types/3` grant join | KILLED, 4 failed (R2 in router, request_access, type_access x2). A first attempt (condition dropped in `authorized?/3` instead) was caught by only 1 existing test; the T-16 mixed fixture was strengthened with a type granted to another user only |
| M12 | existence reads skipped when a type is already denied | KILLED, 7 failed (T-17 constant work x2, T-22 x5) |
| M13 | shape check before the walk in `request_entity_types/2` | KILLED, 3 failed (T-14 malformed + too many, request_access malformed table, T-14 malformed shapes); guard + request_access files (62 tests) |
| M14 | user-id cast dropped in `denied_types/3` | KILLED, 39 failed (every granted-user path errors) |

Final scoped run, `MIX_ENV=test mix test --warnings-as-errors` over the 10 files above (the 6 written/edited
plus `entities_aggregate_restricted_join_test`, `entities_aggregate_test`, `entities_export_test`,
`entities_test`): `Result: 357 passed`; `grep -c "default values for the optional arguments"` on that output: 0;
`mix format --check-formatted` on the 6 touched test files: exit 0.
`mix letflow.check.test` runs the whole suite (via `scripts/test_parallel.sh`) and was NOT run (instruction:
never run the full suite; hosted CI runs it).
