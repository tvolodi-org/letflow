# REQ-518 slice 2c-i-a test spec: compiler scope argument, ScopeDeclaration, `allowed_set/2` (GH #2535, decision 0051 D1/D6)

Design: `lib/letflow/design/req518-compiler-scope-filter.md` r2a (sections 3.1 to 3.4, 3.7 to 3.9, 10.1, 11).
Scope: REQ-518 acceptance criteria 1 to 5 in full for this slice, plus the 2c-i-a share of 18, 21 and 22 (see "AC -> test").
Test ids (T-C*, T-D*) are the design's (section 10.1); the SEC code-gate conditions (step-07), the REVIEWER
notes (step-08 F-5) and the CDV r2a recheck are mapped below. AC 6 to 17 and 19 to 20 are later slices.

No route is reclassified in this slice, so no HTTP test exists here: everything is proven at the compiler,
`Scope`, `ScopeNodePaths`, `ScopeDeclaration`, `Catalog`, `ManifestHash`, `RouteScope` and `ApiPipeline.handle_errors/2`
layers, against real data of the `fixture_scoped` module.

## As-built rulings that shape the tests

| Ruling | Effect on the tests |
|---|---|
| The scope id list is ONE bound array typed `{:array, :string}`, rendered `ANY($n::varchar[])` | the SQL-shape assertions accept `(::varchar[])`; "one bound array" is asserted by the parameter list containing the id list as one element |
| `:all` adds nothing | proven by committed SQL (below), not by absence of a `where` only |
| `ScopeSetError` is mapped by `ApiPipeline.handle_errors/2` (ELIXIR-DEV deviation, SEC-accepted) | tested directly; the HTTP form (T-C13) needs a route that calls the gate: 2c-i-b |
| `Scope.allowed_set/2` has no production caller until 2c-i-b | tested directly (REVIEWER F-5 (d)) |
| `:exam_route_reclassified` ships in 2c-i-a (R-1) | walk half (pure) and scan half (AST) both here |

## Files

| File | Ids |
|---|---|
| `test/letflow/entities/query_scope_test.exs` (35 tests, `async: false`) | T-C1 (arity; committed pre-change SQL of 8 shapes; no scope statement under `:all`), T-C3 (argument guard, message, `{:nodes, []}`), T-C4 (rows, count, sum, `group_by`, cursor page 1/2/3, page 2 under a narrower current set, filters that try to reach out-of-scope rows), T-C5 (one extra WHERE per query, bound array in data / cursor / aggregate / joined statements, position before GROUP BY / ORDER BY / LIMIT, hostile id), T-C7 (LEFT keeps the primary with a NULL target, INNER drops, `through` NULLs the far hop, ON-clause SQL shape of every hop, `:none` joins, aggregate over a join), T-C8 + T-D2 (undeclared primary and undeclared joined target), T-D5 (`:tenant_wide` master, `:none`), T-D6 (declared type on `:latest`, declared column absent, joined target column absent), T-C9 + T-C10 (cost) |
| `test/letflow/entities/scope_declaration_test.exs` (16, `async: false`) | T-D1 (four declared types, zero queries for an undeclared type, one installed-modules read per call), declaring module must be installed, T-D8 `for_type` half (allowlist emptied, another module id on it, end to end through the compiler, owner stamp of another module), T-D3 (`definition_json` scope keys on an undeclared and on a declared type; AST proof the module reads no definition), T-D4 (definitions API cannot take a declared managed name) |
| `test/letflow/api/scope_allowed_set_test.exs` (21, `async: false`) | every row of the decision table, T-C12 (agreement with `allowed?/3` for 4 scoped principals x 9 nodes, plus `:all` and `:none` principals), C-2 (retired intermediate `a2` with live `a2x`, retired leaf `a3`), T-C13 `Scope`-level half (`ScopeSetError` for `:invalid_node_id`, `:invalid_schema_name`, one constant log line per occurrence, no id / schema in the log, Postgrex error propagates), T-C14 (lowered cap, exactly at the cap, retired nodes do not use the budget), statement counts |
| `test/letflow/scope_node_paths_allowed_ids_test.exs` (16, `async: false`) | `allowed_node_ids/2`: expansion, retired root / leaf, dedupe and sort, `[]`, unknown root, two statements; T-C6 (`_`, `%`, `\` literal; hostile id is a bound value); errors as values; cap node half; chunking (500 roots = 2 statements, 501 = 4, cap across chunks) |
| `test/letflow/modules/catalog_scope_declarations_test.exs` (25, `async: false`) | T-D7 Catalog rule 11 (absent, valid, non-map, bad key, bad value, unmanaged type, allowlist is by module id, duplicate, non-map manifest of another module (REVIEWER F-4), every registered module validates), `ManifestHash` (pinned pre-change hash, covered parts, order independence), T-D8 config half (prod config evaluation, no fixture module in prod, test value, dev, text scan of config files, AST scan of `lib/` for writers of the key) |
| `test/letflow/entities/scope_all_scan_test.exs` (17, `async: true`) | T-C2 + T-C15 scan half: AST scanner with seeded sources, the real `lib/` tree, the five-site ledger, no two-argument call survives, router literals only while the three routes are `:tenant_wide`, R-1 lapse guard, `list_available_exams/2` required `:scope` |
| `test/letflow/api/route_scope_exam_guard_test.exs` (11, `async: true`) | T-C15 walk half: `{:exam_route_reclassified, row}` for the real table, each class, every exam route, a route added later, the bare prefix, exact prefix |
| `test/letflow/plugs/api_pipeline_scope_set_error_test.exs` (9, `async: true`) | `handle_errors/2` branch for `ScopeSetError`, untouched conn for everything else, exception contract |
| `test/support/scope_set_fixture.ex` (new) | tree, items, children, principals, SQL shapes, DDL helpers |
| `test/fixtures/scope/compiler_all_pre_change_sql.json` (new) | text and parameters of 8 request shapes, produced by the pre-change `Compiler` source of `main` (see T-C1) |
| `test/letflow/routers/entities_query_restricted_walker_test.exs` (edited, 3 tokens) | forced edit ELIXIR-DEV missed: `traced_request(Compiler, :compile, 2/…` and `:run_aggregate, 2` became arity 3 |

Support used as the brief says: `ScopedGrantsFixture` (tenant, `principal/2`), `RoleScopeGrantsFixture` (raw user rows),
`TokenMintFixture` (role holders), `PlatformTenantFixture.capture_repo_queries/1`, `RouteInventory`, `RuntimeConfigEval`.

## T-C1: how the pre-change SQL was obtained (stated, not hidden)

`git show HEAD:lib/letflow/entities/query/compiler.ex` (the `main` source, uncommitted work excluded) was copied with the
module renamed to `PreChange.Compiler`, compiled in a scratch test run against the fixture tenant, and the SQL and parameters
of `ScopeSetFixture.sql_shapes/0` (plain, plain with filter and sort, `:latest`, inner join, left join, `through`, grouped
aggregate, aggregate over a join) were written to `test/fixtures/scope/compiler_all_pre_change_sql.json`. The scratch test and
the renamed copy are not committed. The test compares `compile(r, p, :all)` to those strings, so a `:all` query that gained
a `where` fails. The same file's pinned `ManifestHash` value for a literal manifest was produced the same way.

## AC -> test

| AC | Tests | Why it exists (what it would catch) |
|---|---|---|
| 1 compiler contract | T-C1 (`function_exported?/3` true and `/2` false for the three functions; committed SQL equality; no `tenant_modules` read under `:all`), T-C3 (13 bad scopes raise `ArgumentError` before any query, constant message, `{:nodes, [1]}`, `{:nodes, ["x", 1]}`), scan T-C2 (AST: bare `:all` without comment fails, each justification form, strings / docs / unrelated aliases do not trip or justify, ledger of the five non-router literal sites each with its rule, no two-argument call, the three router literals consistent with the route classes), `list_available_exams/2` required `:scope` | a fail-open default (`normalize_scope!` returning `:all`), a leftover two-argument form, a new literal `:all` site without a ruling, a scoped route reaching a literal-`:all` handler. The build gate (`mix compile --warnings-as-errors`) is a CI step |
| 2 predicate placement | T-C4, T-C5 | a post-filter, a predicate inside the user filter, a predicate missing from the aggregate statement, a set holding grant roots only, retired nodes in the set, a live descendant of a retired intermediate node dropped, a user filter (`IN`, `scope_node = other`, `IS NULL`) that reaches an out-of-scope or NULL-scope row, a cursor that keeps a revoked subtree |
| 3 joins | T-C7, T-C8 | the target predicate in WHERE instead of ON (a LEFT join turned INNER), the `through` entity or a hop not filtered, an undeclared or column-less target readable, `TypeAccess` untouched (its own suites, unedited and green) |
| 4 declaration | T-D1 to T-D8 (see Files) | an undeclared type treated as tenant-wide, a declaration read from `definition_json`, an unmanaged declaration accepted for a production module, a stamp of another module accepted, a module that is not installed accepted, a bad shape accepted by rule 11, a hash change for manifests without the key |
| 5 cost | T-C9 (a scoped plain compile adds exactly 3 statements: installed-modules read, owner read, column check; a joined compile reads the installed modules ONCE; `allowed_set/2`: 0 statements for token / tenant-wide / zero-row, 2 for a scoped principal, 2 more per 500 roots), T-C10 (a page costs one statement for page sizes 1, 2, 3; none touches `scope_node_paths` or `tenant_modules`) | a per-row or per-page set recomputation, a scope statement on the `:all` path, an unbounded number of tree reads |
| 18 filter reclassification | not in this slice (deliberately no route is reclassified). The 517 walk (`route_scope_walk_test.exs`, unedited, 18 tests green) still fails if one appears; the scan test ties the router literals to the route classes so the 2c-i-b flip cannot leave a literal `:all` behind a `:filter` route | n/a |
| 21 `:self_service` | not in this slice (no route class, list or walk rule changes). 517's "no `:filter` / `:self_service` route" walk assertion is green and must be edited by 2c-i-b | n/a |
| 22 gates | CI steps (`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix letflow.check`, `mix letflow.check_boundaries`); locally `mix format --check-formatted` over every file of this slice exited 0 | n/a |

## SEC / REVIEWER conditions

| Source | Where |
|---|---|
| step-07 merge condition 1: T-C15 scan + `:exam_route_reclassified` walk test | `scope_all_scan_test.exs` (parsing, ledger, R-1 guard), `route_scope_exam_guard_test.exs` |
| step-07 merge condition 2: `handle_errors` branch directly; T-C14 cap test (lowered cap, exactly at the cap) | `api_pipeline_scope_set_error_test.exs`; `scope_allowed_set_test.exs` and `scope_node_paths_allowed_ids_test.exs` |
| step-07 merge condition 3: C-2 retired intermediate `a2` / `a2x`, ACs 1 to 5 tests, not ELIXIR-DEV's scratch ones | `scope_allowed_set_test.exs`, `scope_node_paths_allowed_ids_test.exs`, `query_scope_test.exs` |
| step-07 merge condition 4: T-D8 config checks | `catalog_scope_declarations_test.exs` (prod evaluation, text scan, AST scan) |
| step-07 F-1 (DB error is not a `ScopeSetError`) | `api_pipeline_scope_set_error_test.exs` pins that a `Postgrex.Error` is left alone today; 2c-i-b must flip that test together with the gate fix |
| step-07 F-2 (bare prefix) | `route_scope_exam_guard_test.exs` "bare prefix" test: FAILS until the one-line fix (see Findings) |
| step-08 F-5 (a) parse call sites, not grep | `scope_all_scan_test.exs` (seeded moduledoc / string / comment cases pass and fail correctly) |
| step-08 F-5 (c) `normalize_scope!` incl. `{:nodes, [1]}` | `query_scope_test.exs` T-C3 |
| step-08 F-5 (d) `allowed_set/2` directly | `scope_allowed_set_test.exs` |
| step-08 F-4 (non-map manifest of another module) | `catalog_scope_declarations_test.exs` |

## Mutants (design section 11, plus extras), MEASURED

Method: the mutated source is compiled into the test VM (`Code.compile_string` of the file with one textual replacement,
applied through `mix do run --no-start -r <apply> + test <files>` so it is in place before any test starts); nothing on disk was
changed, so there is nothing to revert (`git status` of `lib/` and `priv/` was identical before and after). A first attempt that applied
the mutant from a loader inside the test run raced with `async: true` modules (M19 passed by accident); it was discarded and
M18/M19 re-measured with the deterministic method. "Failed x of y" counts the tests of the files run together.

| Id | Mutant | Files run | Measured | First killers |
|---|---|---|---|---|
| MU1 (M3) | primary scope predicate not applied | query_scope | failed 23 of 35 | T-C4 rows / aggregates, T-C5, T-C7, T-D5 |
| MU2 (M4) | plain aggregate base not scoped | query_scope | failed 9 of 35 | T-C4 aggregate count / sum / buckets, T-C5 wheres |
| MU3 (M7) | set holds grant roots only, no descendants | node_ids, allowed_set, query_scope | failed 24 of 72 | `allowed_node_ids` expansion, `allowed_set` decision table, T-C4 |
| MU4 (M8) | retired nodes stay in the set | same | failed 24 of 72 | C-2 `a2` / `a3` assertions, T-C4 |
| MU4 (M9) | live descendant of a retired INTERMEDIATE node dropped | same | failed 21 of 72 | C-2 `a2x` assertions, T-C12 agreement |
| MU5 + MU6 (M1) | hop predicate dropped from every ON clause | query_scope | failed 7 of 35 | T-C7 LEFT / INNER / through / ON shape, T-C8, T-D6 |
| MU7 (M5) | undeclared type treated as tenant-wide | query_scope | failed 2 of 35 | T-C8 undeclared primary and joined target |
| MU10 (M6) | `:none` allows (no primary predicate) | query_scope | failed 7 of 35 | T-C3 `{:nodes, []}`, T-C4 zero rows and aggregate / group_by, T-C5 wheres, T-C7 `:none` joins, T-D5 |
| MU34 (M14) | `:all` compile reads the declarations (a scope statement) | query_scope | failed 2 of 35 | T-C1 "no tenant_modules read", T-C9 delta |
| MU37 (M15) | unmanaged allowlist ignored in `ScopeDeclaration` | scope_declaration | failed 4 of 16 (3 net of the BUG-1 test that also fails unmutated) | the three T-D8 tests (emptied allowlist, other module id, end to end) |
| MU37 (M16) | Catalog rule 11 unmanaged-type check dropped | catalog_scope_declarations | failed 2 of 25 | rule 11 unmanaged tests |
| MU40 (M10) | expansion error becomes `{:ok, :none}` | allowed_set | failed 5 of 21 | C-1 raise tests |
| MU40 (M11) | expansion error becomes `{:ok, :all}` | allowed_set | failed 5 of 21 | C-1 raise tests |
| MU41 (M12) | cap truncates instead of failing closed | node_ids, allowed_set | failed 3 of 37 | T-C14 |
| extra (M13) | cap off by one (`>=`) | node_ids, allowed_set | failed 3 of 37 | T-C14 "exactly at the cap" |
| extra (M17) | `ManifestHash` always includes the key | catalog_scope_declarations | failed 1 of 25 | pinned pre-change hash |
| extra (M18) | `exam_route_reclassified` rule disabled | exam_guard | failed 8 of 11 | each class, each exam route, added route |
| extra (M19) | `handle_errors` ScopeSetError branch disabled | api_pipeline_scope_set_error | failed 3 of 9 | 500 bytes, state `:set`, body |
| extra (M20) | token principal not `:all` in `allowed_set` | allowed_set | failed 2 of 21 | decision table, T-C12 |
| extra (M21) | "no live node" expansion gives `:all` | allowed_set | failed 1 of 21 | retired leaf / ghost node |
| extra (M22, M30, M31) | `_`, `%`, `\` not escaped in the LIKE pattern | node_ids | failed 1 of 16 each | T-C6, one test per character |
| extra (M23) | owner stamp of another module accepted | scope_declaration | failed 2 of 16 (1 net of BUG-1) | stamp test |
| extra (M24) | declaring module need not be installed | scope_declaration | failed 2 of 16 (1 net of BUG-1) | not-installed test |
| extra (M25) | invalid scope argument fails open (`:all`) | query_scope | failed 2 of 35 | T-C3 |
| extra (M26) | non-binary id inside `{:nodes, ...}` accepted | query_scope | failed 2 of 35 | T-C3 |
| extra (M27) | declared column assumed present | query_scope | failed 3 of 35 | T-D6 column tests |
| extra (M28) | catch-all kind is `:open` (undeclared / `:latest` / column absent fail open) | query_scope | failed 3 of 35 | T-D6, T-C8 |
| extra (M29) | PLATFORM_ADMIN `:all` ignores the platform tenant | allowed_set | failed 1 of 21 | decision table |

Every mutant was killed. Not mutated (predicted, with the killing test):

| Id | Mutant | Predicted killer |
|---|---|---|
| MU8 | declared column not promoted falls back to the JSON document | T-D6 "type read from `:latest`" and "column not present" (a JSON fallback would show `item-a`, `item-a1`, `item-a2x`); M28 is the closest measured fail-open |
| MU9 | declaration read from `definition_json` | T-D3 first two tests (keys injected into the stored definition), plus the AST test that `ScopeDeclaration` aliases no definition module (a raw-SQL reader would escape the AST test and be caught only by T-D3) |
| MU11 | set recomputed per row / per page | T-C10 (statement count per page size); there is no such path in the code today, so there is nothing to mutate cheaply |
| MU12 and later | `ScopeGate`, 2c-ii, 2d mutants | later slices |

## Not derivable by a test in this slice (stated, not hidden)

* AC 2 "export reuses the compiled query" and "one allowed-node-set read per request" (the `ScopeGate` memo): the gate and the
  derivation in the router are 2c-i-b. In this slice the scan pins that each of the three router handlers has exactly one compile site.
* AC 4 "the same undeclared type gives a scoped principal 404 on by-id and an empty page on query / aggregate / export" over HTTP:
  the routes stay `:tenant_wide` (a scoped caller is refused 403 before the handler); the empty result is proven at the compiler.
* AC 5 "the API-token path keeps its single-query shape, the OIDC path loads grants once": no pipeline code changed in this
  slice; the REQ-497 / 517 query-count suites (unedited) cover it, and `allowed_set/2` is shown to read nothing for a token.
* AC 18 and AC 21 (and T-C13 over HTTP, T-C11, T-S*): 2c-i-b by design.
* The AST scan sees a literal `:all` third argument. A scope that is `:all` but travels through a variable, a function result or a
  module attribute is not seen (residual for SECURITY-REVIEWER; the fail-closed guard still refuses any value that is not
  `:all` / `:none` / `{:nodes, [binary]}`).
* `mix compile --warnings-as-errors` (AC 1 build gate) and the full suite: CI.
* Races (a grant revoked mid-request): 2c-ii.

## Findings against the implementation (no `lib/` or `priv/` change was made)

| Id | Severity | Finding | Failing test |
|---|---|---|---|
| BUG-1 | LOW | `ScopeDeclaration.for_type/2` with a malformed prefix does NOT return `:undeclared` as design 3.2 and the module's own text say: for a type some installed manifest names it raises (`""`, `"not a schema"`, `"tenant_xyz"`: `Postgrex.Error` from a query on a missing schema; a prefix containing `"`: `ArgumentError` from Ecto). Fail closed by exception, no data; callers validate the prefix. Fix: check the prefix with `TenantProvisioning.tenant_id_for_schema_name/1` in `for_types/2` and return `:undeclared` for every type on `{:error, _}` | `scope_declaration_test.exs` "a malformed prefix is :undeclared" |
| BUG-2 | MINOR (SEC step-07 F-2) | `exam_route?/1` matches the prefix `"/modules/exam/"`, so a route at exactly `/modules/exam` is not covered by the R-1 guard. No such route exists today. Fix: `path == "/modules/exam" or String.starts_with?(path, "/modules/exam/")` | `route_scope_exam_guard_test.exs` "bare prefix" |
| FORCED-1 | n/a | `entities_query_restricted_walker_test.exs` traced `Compiler.compile/2` and `run_aggregate/2` by arity: 2 tests failed after the arity change. ELIXIR-DEV counted only source-string hits. Fixed here (3 tokens, test file) | was `T-26` (2 tests) |
| OBS-1 | note | the id list is typed `varchar[]` (`{:array, :string}`), not `text[]`: one bound array either way | n/a |
| OBS-2 | note | `permission_matrix_test.exs` T24 fails on this Windows checkout because the CI yaml has CRLF line endings (`core.autocrlf`): unrelated to this slice, fails identically without it | n/a |

Both failing tests are the correct expectation of the design; they stay red until the two small `lib/` fixes land (or the
design text is relaxed). They are the only two failures of the 150 tests of this slice.

## Execution status

RUN, per file, one `mix` at a time, with the `mixlock` directory taken and released around each run (the directory was created by this
session; no foreign lock was removed), `LOG_LEVEL=warning` to keep the output small. No full-suite, no multi-partition run, no
`mix letflow.check.test`, no `mix letflow.check` (supervisor rule): the dead-default-argument grep of `letflow.check.test` was
replaced by a manual check (no `\\` default argument in any new file or helper) and by the fact that `mix test` compiled every file with no
warning from the new files.

| Run | Result |
|---|---|
| `query_scope_test.exs` | 35 passed |
| `scope_declaration_test.exs` | 15 passed, 1 failed (BUG-1) |
| `scope_allowed_set_test.exs` | 21 passed |
| `scope_node_paths_allowed_ids_test.exs` | 16 passed |
| `catalog_scope_declarations_test.exs` | 25 passed |
| `scope_all_scan_test.exs` | 17 passed |
| `route_scope_exam_guard_test.exs` | 10 passed, 1 failed (BUG-2) |
| `api_pipeline_scope_set_error_test.exs` | 9 passed |
| forced-edit and neighbouring existing files, one by one: `query_test` 35, `query_joins_test` 13, `query_aggregate_test` 17, `query_cursor_field_grants_test` 16, `query_self_join_test` 3, `entities_query_restricted_walker_test` 55 (after FORCED-1), `catalog_test` 22, `scope_test` 16, `service_task_entity_writes_sentinel_test` 2, `exam/certificate_test` 9, `exam/pack_install_test` 5, `exam/session_test` 61, `route_scope_walk_test` 18, `route_scope_test` 30, `authorization_enforcement_test` 22, `platform_scope_inventory_test` 33, `handler_writes_callers_test` 10, `install_activation_test` 14 | all passed |
| `permission_matrix_test.exs` | 59 passed, 1 failed (OBS-2, unrelated, CRLF) |
| `mix format --check-formatted` over the 9 new files and the edited walker test | exit 0 |

Pre-existing unused-variable warnings in `query_joins_test`, `query_cursor_field_grants_test` and `query_self_join_test` are not from this
slice's edits (their lines are outside the diff).
