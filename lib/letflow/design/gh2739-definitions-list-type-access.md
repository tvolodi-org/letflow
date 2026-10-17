# GH #2739 -- `GET /entities/definitions` list ignores TypeAccess

Status: DESIGN (CODE-DESIGNER, 2026-10-17). No implementation code in this file. Base: main `7af02f014`.
Related: `lib/letflow/design/gh2700-type-access-joins-export-aggregate.md` (refusal shapes, Q6/Q7 rulings),
`lib/letflow/design/req394-per-entity-type-authorization.md`, `docs/agents/instructions/security-invariants.md`
(INV-2, INV-5, INV-7).

## 0. Decisions in one paragraph

Filter inside the one cursor-paginated statement with a correlated `NOT EXISTS` subquery on the same
restriction + user-grant rule as `TypeAccess.authorized?/3` / `denied_types/3`. That rule is built by ONE shared
function in `TypeAccess` (the denial base query), which all three call. The keyset cursor stays `(inserted_at, id)`;
the denial predicate is ANDed into the WHERE before `ORDER BY ... LIMIT page_size + 1`, so pages, the over-fetch row
and `next_cursor` are computed over visible rows only. No admin exemption (none exists in TypeAccess). The three
single-definition GETs are not touched. #2718 goes in a separate PR (section 11).

## 1. Verified current behaviour (code evidence)

- Route: `lib/letflow/routers/entities.ex` `authz_get "/definitions", :EntitiesDefinitionsRead` (~:299) ->
  `handle_list_definitions/1` (~:934). It reads only `cursor` and `page_size` from the query string
  (`Pagination.parse_page_size_param`), calls `Definitions.list_definitions(filters, prefix)` and renders
  `definition_map/1` for every row. It never reads `conn.assigns.auth_context.user_id`. Envelope is exactly
  `{"items", "next_cursor"}`; `Page.count` exists in `Pagination.Page` but is NOT rendered.
- `definition_map/1` (~:2765) exposes id, name, display_name, the full `definition_json`, hashes,
  artifact_version_id, status, inserted_at. This is the leak (schema plus name existence oracle).
- `Letflow.Entities.Definitions.list_definitions/2` (`lib/letflow/entities/definitions.ex` :358): WHERE
  `tenant_id`, optional keyset `{inserted_at, id} < {cursor_inserted_at, cursor_id}`, `ORDER BY inserted_at desc,
  id desc`, `LIMIT page_size + 1`; `split_list_definitions_page/2` drops the extra row and mints `next_cursor` from
  the last kept row (`"ED:<mint_time_us>:<id>:<inserted_at_us>"`, expiry via `Pagination.decode_cursor`). It returns
  EVERY version of EVERY name, any status. There are NO filters (no name, status or type parameter): unknown query
  params are ignored.
- Only caller of `list_definitions/2` in `lib/`: the router (grep). Tests call it directly in
  `test/letflow/entities/definitions_test.exs` (AC5 block ~:305-430) and through HTTP in
  `test/letflow/routers/entities_test.exs` (~:988-1001, error mapping only).
- Single-definition routes (verified, all three): `handle_get_active_definition_by_name` (:855),
  `handle_get_definition_by_name` (:865), `handle_get_definition` (:885, after `Ecto.UUID.cast`) each pass
  `conn.assigns.auth_context.user_id` and the fetch result to `render_get_definition/3` (:914), which calls
  `TypeAccess.authorized?/3`; `{:ok, :denied}` renders `Response.not_found/1`, the same as `{:error, :not_found}`.
  The relayed claim holds. These stay untouched.
- `TypeAccess` (`lib/letflow/entities/type_access.ex`): rule = a row exists in `entity_type_restrictions` for the
  type AND no `user_entity_type_grants` row for `(user_id, entity_type)`. `authorized?/3` (:73) and
  `denied_types/3` (:111) each hand-build that left-join query. There is NO role, TENANT_ADMIN or platform exemption
  anywhere in the module; `RequestAccess` only forwards `exempt?` to `FieldPolicy` (fields), never to types
  (gh2700 Q3). Both tables carry a unique index (`entity_type`; `user_id, entity_type`), so the join cannot
  duplicate and a correlated EXISTS is index-served.
- Web: no `web/src` caller of the list route (grep: only `GET /entities/definitions/active/:name` in
  `web/src/api/entities.ts` and its comments). No script or module caller (`modules/exam/router.ex:390` only cites
  the route's pagination shape in a comment).

## 2. Decision D1: how denial is expressed in the paginated query

Options:

A. `denied_types/3` first, then bind its names as an array (`name NOT IN ^names`).
   - Needs the candidate names up front: `denied_types/3` is "subset of the names you give". To use it the list
     would first have to read all names (unbounded) or a new "all denied names for this user" function.
   - Two statements: a restriction/grant change between them makes the page inconsistent with the rule (TOCTOU).
   - Array size is bounded only by number of restricted types (small, but unbounded in principle); bound as a typed
     array so INV-7 holds.
B. (RECOMMENDED) Correlated `NOT EXISTS` against the denial base query inside the list statement.
   - One statement, one snapshot: the visibility decision and the page read cannot disagree.
   - Constant bind count (user_id only), no array growth, planner uses the two unique indexes.
   - Cost: the rule is expressed as a query fragment instead of a name set, so it must be shared (D2) to stay one rule.

Ruling: B. The denial predicate sits in the WHERE together with `tenant_id` and the keyset comparison; `ORDER BY` and
`LIMIT page_size + 1` come after. Semantics of the predicate for row `e`: keep `e` iff there is NO row `r` in
`entity_type_restrictions` with `r.entity_type = e.name` that lacks a `user_entity_type_grants` row for
`(user_id, r.entity_type)`. This is identical to `authorized?/3` returning `:allowed` for `e.name`. It applies to
every version/status of the name (the restriction is keyed on name).

Schema prefix: the tenant prefix is passed via `Repo.all(prefix: prefix)` as today and the schemaless sources inside
the subquery must resolve to the same tenant schema. T-12 (cross-tenant fixture: restriction row only in tenant B,
list as tenant A user) proves it; if Ecto does not propagate the repo prefix into the EXISTS subquery, the fragment
takes the prefix explicitly (Q2).

Q2 is ANSWERED (yes): Ecto 3.14.1 `plan_subquery` falls back to `query.prefix`, so `Repo.all(prefix: prefix)` reaches
the EXISTS subquery. `visible_to` therefore stays `/2` (no prefix argument, no `/3` fallback). T-12 remains as a
blocking regression gate (SECURITY R1), not as discovery.

## 3. Decision D2: one rule, three consumers

Refactor `TypeAccess` to expose a single denial base query, `denial_query(user_id)` (private helper plus one public
fragment function), from which all three derive:

- `authorized?/3`: `EXISTS(denial_query where entity_type = ^entity_type)` (behaviour unchanged).
- `denied_types/3`: `denial_query where entity_type in ^names` selecting entity_type (behaviour unchanged).
- NEW `TypeAccess.visible_to/2` (PINNED, arity 2 only): returns an `Ecto.Query.dynamic` boolean over a named parent binding's `name`
  column meaning "not denied", built as `NOT EXISTS(denial_query where entity_type = parent_as(binding).name)`.

Public additions (signatures only):

- `@spec visible_to(user_id :: String.t(), name_binding :: atom()) :: Ecto.Query.dynamic_expr()` -- pure query
  construction, no I/O, no tenant lookup (the caller's `list_definitions` already resolves the tenant via
  `TenantProvisioning.tenant_id_for_schema_name/1`).
- Guard: `is_binary(user_id)` and `is_atom(name_binding)`; the user id keeps the `type(^user_id, Ecto.UUID)` cast the
  existing queries use; no `nil` form; any other input is a FunctionClauseError at the call site,
  never a silent "allow all". There is deliberately no zero-argument or `nil`-user form.

SECURITY R2: `authorized?/3`, `denied_types/3` and `visible_to/2` are all built from the ONE shared denial query (no
second hand-written copy of the join). The existing TypeAccess and #2700 tests stay green UNMODIFIED.

Binding contract (PINNED): `Definitions.list_definitions/3` declares the parent binding on the `EntityDefinition`
source with a named binding `as: :def` and passes `:def` to `visible_to/2`; the fragment refers to the parent's
`name` through `parent_as(^binding)`. The resulting dynamic is placed exactly in the WHERE, ANDed with the
`tenant_id` clause and the keyset comparison, BEFORE `ORDER BY inserted_at desc, id desc` and `LIMIT page_size + 1`
(order of construction: tenant_id, keyset, visible_to, order_by, limit).

Cross-module dependencies: `Letflow.Routers.Entities` -> `Letflow.Entities.Definitions.list_definitions/3` ->
`Letflow.Entities.TypeAccess.visible_to/2` (new edge Definitions -> TypeAccess; TypeAccess depends only on Repo and
TenantProvisioning, so no cycle). Router additionally reads `auth_context.user_id`.

Parity is enforced by a test (T-14), not by convention: a table-driven test over {unrestricted, restricted+no grant,
restricted+granted, restricted for other user, absent} asserts `authorized?/3`, `denied_types/3` and the list
agree for every row; T-14 adds duplicate-name versions and a user holding a grant for a DIFFERENT type (SECURITY R2).

## 4. Decision D3: `Definitions.list_definitions` signature (fail closed)

Replace `list_definitions(filters, prefix)` with:

- `@spec list_definitions(user_id :: String.t(), list_definitions_filters(), prefix :: String.t())` returning the
  same `{:ok, Pagination.Page.t(EntityDefinition.t())} | {:error, :invalid_schema_name | :page_size_too_large |
  :wrong_endpoint | :expired | :invalid_cursor}` union as today. Errors keep their current order (tenant, page size,
  cursor).
- `list_definitions/2` is REMOVED (not kept as an unscoped sibling) so a future caller cannot list without naming a
  viewer; compile-time arity error is the fail-closed mechanism. Existing unit tests in
  `test/letflow/entities/definitions_test.exs` migrate to /3 with a user that has no restrictions (same assertions).
- Router: `handle_list_definitions/1` reads `conn.assigns.auth_context.user_id` exactly as the three single GETs do and
  passes it. A non-binary user id is not special-cased beyond what the single GETs do (it fails the same way,
  500 via the framework); see Q3.
- No change to `definition_map/1`, the envelope, the cursor encoding, the prefix `"ED:"` or the ordering.

## 5. Decision D4: cursor semantics (no enumeration, no reveal)

Cursor key: `(inserted_at, id)` pair, a POSITION in the total order, not a reference to a row. `decode` only parses the
tuple; no row lookup. Consequences, with the denial predicate in the same WHERE:

1. Page size: `LIMIT page_size + 1` is applied over visible rows, so a page is full whenever `page_size` visible rows
   remain. With X denied, a page of N contains N visible rows (X never occupies a slot). Page contents equal the
   world in which X does not exist.
2. `next_cursor`: minted from the last kept VISIBLE row, and present iff at least one more visible row exists. It
   never encodes a denied row's `(inserted_at, id)`, and its presence/absence matches the world without X.
3. Cursor from an unfiltered view (minted before X was restricted, or for another user) naming X's position: treated as
   a plain position. Result = visible rows strictly older than that tuple, identical to what a never-existing tuple at
   the same position returns. No error, no "cursor row denied" signal (a signalling error would be an oracle).
4. Crafted cursor naming a denied row: same as 3. The attacker must already know X's id and timestamp to craft it, and
   learns nothing (response is the same as for a random tuple). Wrong-endpoint/expired/invalid cursors keep today's
   400 / cursor-expired problem document; those are independent of type visibility.
5. Walking the whole list with any starting cursor never yields a denied row, so enumeration is impossible.
6. Residual (accepted, equals every keyset pagination): the gap between consecutive `inserted_at` values of visible
   rows is visible only if `inserted_at` is shown; a gap does not identify a denied row (other hidden causes: none, the
   list has no other filter).

Consistency across pages: a restriction added between page 1 and page 2 simply hides rows from page 2 onward; no cursor
invalidation is needed.

## 6. Decision D5: other parameters, counts, filters

- No `name`, `status`, `entity_type` filter exists today and none is added. `?name=X`, `?status=active`, `?entity_type=X`
  are ignored by the router (only `cursor` and `page_size` are read), so the response to a denied name equals the
  response with no filter; there is no filter path that could confirm a denied name. T-8 pins this (response equal to
  the unfiltered request per the section 10 determinism rule (compare decoded last-row position and null-ness; raw bytes only on a page where `next_cursor` is nil)).
- Rule for any future filter: it composes with AND AFTER the denial predicate and must never run before or instead of
  it (document in the function doc; REVIEWER checklist item).
- Totals: the envelope carries no `count` or `total`; `Page.count` is not rendered. T-3 asserts the top-level key set
  is exactly `["items","next_cursor"]`. If `count` is ever rendered it must be `length(visible items)` (same fragment);
  noted, not built.
- Refusal shape: the list has no per-type refusal. A denied type is silently absent, which is the list-collection
  analogue of the 200-empty rule that /query uses (gh2700 D2). No 403/404 on the list for denial, and a caller denied
  everything gets `{"items": [], "next_cursor": null}` like an empty tenant.

## 7. Decision D6: admin / platform exemption

None. `authorized?/3` and `denied_types/3` do not consult roles; the grant model is per-user rows only; the
single-definition routes apply it to every caller holding `EntitiesDefinitionsRead`. The list matches exactly: no
TENANT_ADMIN or platform bypass, no `exempt?` flag. A tenant admin who lacks a `user_entity_type_grants` row for a
restricted type does not see its definitions on the list, same as on the single GETs. (Whether admin SHOULD bypass is
a product question for the REQ-394 line, out of scope; Q4.)

## 8. INV-5 / timing

The list issues ONE statement regardless of how many types are denied; denied versus absent rows differ only inside
that statement (an extra index probe per candidate row), with no extra round trips, no logging and no audit row
(gh2700 Q8). This is within the gh2700 Q7 ruling (constant database work per request shape; no early exit).
T-9 asserts the statement count for a list with denied rows equals the count without (using
`Letflow.TestSupport.QueryCount.count_statements/1`, T-9).

## 9. Acceptance criteria -> design elements

| AC (issue #2739) | Element |
|---|---|
| Design note: how TypeAccess is expressed in the paginated query | sections 2, 3 (NOT EXISTS via `TypeAccess.visible_to/2`) |
| Design note: cursor from unfiltered view cannot enumerate | section 5 items 3-5, tests T-4, T-5, T-6 |
| Failing test: denied X absent for a page size that would include it; page contents and next_cursor equal the world without X | T-1, T-2 (written first, red on main) |
| Three single-definition GETs unchanged | section 1 verified; T-10 regression, no diff in those handlers |
| Response unchanged for a caller with no denied types | T-7 (golden from main compared per the section 10 determinism rule (compare decoded last-row position and null-ness; raw bytes only on a page where `next_cursor` is nil); the fixture/page size is chosen so at least one page has `next_cursor` nil) |
| SECURITY-REVIEWER mandatory, REVIEWER | gates, section 12 |
| Scoped tests one file at a time; warnings-as-errors compile; format check quoted | section 12 |

## 10. Tests (failing-first; file: new `test/letflow/routers/entities_definitions_list_type_access_test.exs`, plus edits to `definitions_test.exs` and a TypeAccess parity file)

Determinism rules (apply to every test below): both worlds use FIXED uuids and FIXED, pairwise-distinct `inserted_at`
values for every fixture row (no wall clock). `next_cursor` embeds the mint time (`System.system_time`), so a non-null
`next_cursor` is never byte-equal across calls. Per-test rule: where `next_cursor` is non-null compare its DECODED
last-row position (`inserted_at`, `id`) and null-ness; compare raw bytes only on pages where `next_cursor` is null.
Fixture: one tenant, definitions with distinct `inserted_at` (explicit, deterministic) interleaved: A1, X1, A2, X2
(second version of X), A3, B1, with `entity_type_restrictions` on X and a user_a without grant, user_b with grant,
user_c unrestricted tenant variant. "World without X" = a second tenant seeded with the same rows minus X versions,
same relative ordering.

- T-1 (RED on main) user_a, `page_size` that includes X rows: no item has name X; no X `id` anywhere in the body.
- T-2 (RED on main, SECURITY R4) pagination equality against a real second world without X (explicit inserted_at); sizes must include one ending EXACTLY on a denied row and a fixture with a trailing denied tail where `next_cursor` must be nil: walking every page with sizes 1, 2, 3, 5, 200 yields page lists (names and
  order) and `next_cursor` presence/absence pattern identical to the world without X; the item sequence is equal when
  compared by name/status/order. Cursors themselves may differ (mint time), so compare decoded position of the
  last visible row, not raw strings.
- T-3 body key set is exactly `items`, `next_cursor`; no `count`.
- T-4 old cursor: mint a cursor as user_b (granted) whose last row is X2; present it as user_a: result equals the
  visible rows older than X2, no 400, no X.
- T-5 (every fixture row has a distinct inserted_at) crafted cursor naming X1's exact `(inserted_at, id)` for user_a versus a cursor naming a random tuple at the same
  `inserted_at`: `items` equal and `next_cursor` null-ness equal, per the section 10 determinism rule (compare decoded last-row position and null-ness; raw bytes only on a page where `next_cursor` is nil).
- T-6 expired / wrong-endpoint / garbage cursor statuses unchanged (400 / problem document) regardless of denial.
- T-7 unrestricted tenant and a restricted tenant but user_b with the grant: response unchanged from baseline
  (golden captured pre-change, compared per the section 10 determinism rule (compare decoded last-row position and null-ness; raw bytes only on a page where `next_cursor` is nil); granted user sees X rows).
- T-8 `?name=X`, `?entity_type=X`, `?status=active` are ignored: response equal to the same request without them per the section 10 determinism rule (compare decoded last-row position and null-ness; raw bytes only on a page where `next_cursor` is nil), for
  user_a (and X never present).
- T-9 statement count equal with and without denied rows, measured with a NEW shared helper `Letflow.TestSupport.QueryCount.count_statements/1` in `test/support/query_count.ex` (the existing `measure_pair/4` is a private defp in `instances_synthetic_hidden_test.exs:343`, not reusable); the test calls `Definitions.list_definitions/3` at CONTEXT level (no api_tokens write), so the #2729 second-boundary retry is not needed; if an HTTP-level variant is added it must use that retry pattern(statements counted for the same request shape in both worlds).
- T-17 all-denied: a user denied every definition in the tenant gets `{"items": [], "next_cursor": null}`, equal to an
  empty-tenant response (status, content-type and full body; `next_cursor` is null so raw bytes are compared).
- T-10 single GETs unchanged: for user_a, `/definitions/active/X`, `/definitions/by-name/X`, `/definitions/<X id>`
  each answer exactly the bytes of the same call for a nonexistent name/id (existing REQ-394 tests stay green);
  granted user_b gets 200.
- T-11 HTTP-level denied-vs-absent: list for user_a in the tenant WITH X (denied) is equal to the list
  in the world WITHOUT X (status, every response header except date/request-id, body): byte-for-byte on a page where `next_cursor` is nil (the fixture must include such a page size); on pages with a non-null `next_cursor` compare items bytes plus decoded `next_cursor` position and null-ness; the comparison helper asserts
  header sets equal after excluding only volatile headers (listed in the test).
- T-12 BLOCKING GATE, both directions, on a second REAL tenant schema (SECURITY R1): (a) restriction in tenant A hides the type in A's list; (b) restriction only in tenant B must NOT hide the type in A.
- T-13 mutation of rule inputs: a grant row for a different user, or a restriction for a different name, does not
  change visibility.
- T-14 parity table (section 3): for each case, `authorized?/3`, `denied_types/3` membership and list visibility agree.
- T-15 `list_definitions/2` no longer exists (`function_exported?(Definitions, :list_definitions, 2)` is false) and
  /3 with an unrestricted user returns what /2 returned (migrated AC5 tests).
- T-16 non-granted TENANT_ADMIN user does not see X (no admin bypass).

### Mutants (each must be killed by at least one named test)

M1 filter applied after the page is read (post-filter): killed by T-2 (short pages), T-17 and T-1 with small page sizes.
M2 predicate dropped from the cursor-bearing branch only (cursor path unfiltered): killed by T-4, T-5.
M3 `NOT EXISTS` replaced with `EXISTS` / inverted grant test: killed by T-1, T-7.
M4 grant match ignores `user_id` (any user's grant lifts denial): killed by T-13.
M5 restriction match on `entity_type = id`/wrong column or only `status = :active` rows: killed by T-1 (X1/X2 inactive
versions present).
M6 `next_cursor` minted from the unfiltered extra row: killed by T-2.
M7 an admin/role bypass added to the list only: killed by T-16.
M8 list_definitions/2 kept as an unscoped sibling: killed by T-15.
M9 predicate not tenant-prefixed (hides across tenants): killed by T-12.
M10 `denied_types/3` or `authorized?/3` diverges from the fragment: killed by T-14.

## 11. Scope, size, #2718, #2612

- PR size: ~1 context change (`type_access.ex` +~25 lines refactor-neutral, `definitions.ex` ~+10/-5, router ~+6) and
  one new test file (~250 lines) plus migration of the AC5 tests. One PR, one issue.
- #2718 (instance attachment routes lack an existence check) is a DIFFERENT oracle: instance existence, predicate
  `InstanceVisibility.exclude_synthetic`, different module, tests and reviewers. RECOMMENDATION: separate PR. Taking
  it together would couple an INV-5 existence fix on instances to a TypeAccess query change and widen the
  SECURITY-REVIEWER surface; it is not trivially small. Supervisor may reassign it; this design does not depend on it.
- #2612 (permission-matrix trust boundary): NOT triggered. No change to `ci.yml`, `cd.yml`, `mix.exs`, module config,
  `authorization.ex`, `permission_matrix`, no new permission atom or role grant (route stays `:EntitiesDefinitionsRead`;
  AC1 route-table test unchanged). If implementation finds it must touch those, the rule triggers and
  SECURITY-REVIEWER re-runs.
- Migration: none. Index review: existing `entity_type_restrictions` and `user_entity_type_grants` unique indexes
  serve the correlated probe; no new index.
- Stale `/2` references to update to `/3`: `definitions_test.exs` lines ~312-429 (migration), `entities.ex:59` route-table
  row, and the comments in `lib/letflow/entities/query/cursor.ex` (lines ~5, 19, 27, 115, 196).
- OPEN, NOT FIXED HERE (SECURITY R3, own issue, ORCH files it): solution-pack export (`solution_pack.ex`) reads
  definitions via `Definitions.get_definition_by_name` with no TypeAccess check, so a caller with the pack-export
  permission can read a denied type's definition and distinguish denied from absent. Record in the PR body as open
  together with #2718.
- Pre-existing follow-up (do NOT widen this PR; INV-8): `decode_list_definitions_seek/1` uses bare matches plus
  `String.to_integer` / `DateTime.from_unix!`, so a validly prefixed cursor with a malformed tail could raise. Own
  follow-up issue.
- Docs: update the route-table comment (`entities.ex` :59 mentions `list_definitions/2`) to /3, add an INV-2/INV-5
  comment on the list handler, and record in the PR body: past exposure cannot be established (audit records mutations
  only; same wording as gh2700 R4), and that #2718 remains open.

## 12. Risks

R1. Behaviour change: restricted-type callers now see fewer rows. No `web/src` consumer of the list exists
    (grep), so no UI regresses; operators using curl/scripts against the list as a restricted user will see fewer
    rows (intended). Implementer re-greps `web/`, `scripts/`, `lib/letflow/modules/` and records it in the PR.
R2. Repo prefix propagation into a schemaless subquery (T-12 is the guard; Q2).
R3. Mixed-snapshot flake: seeding timestamps must be explicit; T-2 must not rely on wall-clock ordering (anti-pattern
    seen in #2729).
R4. Removing `/2` breaks external callers: grep shows none in `lib/`; tests migrated.
R5. Cursor presence differences by one page when the LAST visible row is followed only by denied rows: by design
    `next_cursor` is nil then (over-fetch happens inside the filtered statement), equal to the world without X.

Gates: SECURITY-REVIEWER (mandatory; INV-2, INV-5, INV-7), REVIEWER, TEST-DESIGNER/VALIDATOR, then WF-02 downstream.
Run CI-shaped locally: `mix compile --warnings-as-errors`, `mix format --check-formatted`, the new test file, then
`definitions_test.exs`, `entities_test.exs`, the TypeAccess parity file, each as its own scoped run, outputs quoted.

## 13. Open questions (each with a default)

Q1. Subquery (B) vs name array (A)? Default: B (section 2). SECURITY may overrule; A needs a new
    `denied_names/2` (all denied names for a user) and accepts the two-statement TOCTOU.
Q2. CLOSED: yes (Ecto 3.14.1 `plan_subquery` falls back to `query.prefix`); `visible_to/2` pinned; T-12 is a regression gate.
Q3. Non-binary `user_id` in `auth_context` (service principals?): default mirror the single GETs (same failure
    mode); REVIEWER to confirm no principal type reaches this route without a binary user id.
Q4. Should TENANT_ADMIN bypass type restrictions? Default: no, matching `authorized?/3` and every other path;
    changing it is a REQ-394-line product decision, not this fix.
Q5. Remove `list_definitions/2` (default) versus keep it as an explicitly named unscoped internal function. Default
    removes it; no internal caller needs the unscoped list.
Q6. Should the denied-vs-absent byte-identity test compare headers except date/request-id? Default yes; the exact
    exclusion list is fixed in the test and reviewed.
