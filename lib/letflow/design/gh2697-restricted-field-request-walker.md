# GH #2697 design: restricted-field request walker for entity query, join, export and aggregate

Status: DESIGN (CODE-DESIGNER, 2026-10-16). Priority 1, SECURITY. Design only, no implementation code.
Source: GH #2697 body, the evidence comment, and the advisor scope comment (binding).
Evidence test: `test/letflow/routers/entities_query_restricted_filter_test.exs` (11 tests, 6 fail on main).
Out of scope (GH #2698): counts and pagination metadata, audit text. Not touched here.

## 0. Findings from reading the code (every later section depends on these)

F1. The three row routes build their request from a fixed whitelist. `build_query_request/1`
(`lib/letflow/routers/entities.ex:2004`) and `build_export_query_request/2` (`:2442`) produce exactly
`entity_type, filters, sort, join`. `build_aggregate_request/1` (`:2203`) produces exactly
`entity_type, aggregates, group_by, filters, join`. Any other body key (`having`, `distinct`, `search`,
`unredacted` on /query, a body `entity_type` on export) is never copied, so it is inert today.

F2. `run_query/4` (`:1905`) and `run_export/5` (`:2359`) never compare `request.filters` or
`request.sort` with a restriction set. `redact/4` (`:1959-1993`) only redacts returned `field_values`.
The executed SQL in the evidence is `WHERE (e0.field_values->>$2)::boolean = $3` with `["is_correct", true]`,
so a restricted field is a live predicate and ORDER BY key before redaction. That is the oracle.

F3. Aggregate today (`run_query_aggregate/4`, `:2158-2168`, `check_aggregate_field_restrictions/2`,
`:2177-2195`) checks, on the PRIMARY entity's restriction set only: each aggregate target's `:field`,
each `group_by` field, each `filters` field. It runs BEFORE `Compiler.run_aggregate/2`. It does NOT look
at `join` at all (see F6).

F4. HAVING: CONFIRMED NOT COVERED BECAUSE IT DOES NOT EXIST. The aggregate request type is
`aggregate_request :: %{required(:entity_type), required(:aggregates), optional(:group_by),
optional(:filters), optional(:join)}` (`lib/letflow/entities/query/compiler.ex:625-631`), and
`build_aggregate_request/1` copies only those five keys. There is no `having`, `distinct`, free-text
`search`, or computed-expression clause in `Types.query_request` (`types.ex`), `Compiler.compile/2`
(`compiler.ex:153-188`), `compile_aggregate/2` (`:650-695`) or either router builder. The only text
match is the filter operators `contains` and `starts_with`, which are `filter_clause.op` values on a
filter field and are covered as filters. The 0051 D6 text "before group_by, having, count, total" is
future-tense. So: no clause is unguarded today for lack of coverage, but the router comment at
`:2136-2143` ("targets, group_by and filters") is accurate and a future `having` WOULD be unguarded.
That is exactly what the fail-closed mechanism in section 3 is for.

F5. Joined requests: `filters` and `sort` resolve against the PRIMARY entity's allowlist only
(`compile_joined/6`, `compiler.ex:1012-1036`; `Types.join_clause` docs: "does not let a caller
filter/sort on a joined entity's own fields"). So today there is NO request position that names a
far-side entity's data field. The far side's data is exposed only in the response (`redact/4`'s join
clause loads one set per exposed entity type and redacts each, `:1959-1979`, already correct).
Therefore "each joined entity's filters/sort checked against THAT entity's restrictions" is, today,
an empty set of positions; the walker is still written entity-aware (section 2) so the day a join
clause gains filters it is checked against the right set by default.

F6. Join `on` IS a live oracle (not named in the issue body, named by the advisor). `hop_on_dynamic/1`
(`compiler.ex:1093-1113`) equates the declaring side's `fk_field` column with the other side's
`record_id`. The declaring side can be the primary, the join target, or the `through` entity
(`resolve_named_relation/4`, `resolve_through_near_hop/2`, `compiler.ex:1288-1330`). If that `fk_field`
is restricted for the caller, then (a) an INNER join drops rows whose fk is null or dangling, leaking
fk presence, and (b) the joined far-side row is returned, which discloses the referenced record, i.e.
the fk VALUE, through a different field. Neither is redacted today. Aggregate has the same hole
(`aggregate_base_joined`, `compiler.ex:719`, and F3 ignores `join`).

F7. Restricted for the caller = `FieldGrants.load_restrictions(user_id, entity_type, prefix)`
(`field_grants.ex:80-100`): rows of `entity_field_restrictions` for that entity type with no
`user_entity_grants` row for that user, field and type. Roles play no part. Result is a
`MapSet` of raw field-name strings, one query per (user, entity type). Exam seeds
`answer_option.is_correct`, `likert_weight`, `likert_polarity`, `question.explanation` etc. via
`Exam.on_install/2` (`lib/letflow/modules/exam/exam.ex:92-130`, `answer_key_fields/0`).

F8. Existence of a restricted field is already disclosed to the caller: `redact_field_values/2`
(`field_grants.ex:122`) keeps the key and writes the sentinel `:__field_redacted__` ("data exists, you
may not see it", moduledoc "Redaction mechanism"). So 403-vs-422 cannot reveal anything the response
does not already show. This settles the "unknown vs restricted" question in section 4.

F9. Pack reality: `likert_weight`, `likert_polarity` and `question.explanation` are `queried: false`
in `priv/modules/exam/entity_definitions/*.json`. `queried:false` fields are not in the allowlist, so
today a filter on them is a 422 `field_not_allowed` from `Compiler`, not a 200. They are not a live
leak in the shipped pack, but they ARE restricted names, and a tenant may flip `queried` to true
(definitions are tenant-editable), at which point they would leak exactly like `is_correct`. The walker
must therefore decide on the restriction set, not on the allowlist.

F10. Observation outside scope (report, do not fix): `run_export/5` and `run_query_aggregate/4` contain no
`TypeAccess.authorized?/3` step; only `run_query/4` has one (`:1909`). Not changed by this design.

## 1. Acceptance criteria to design element map

| AC (issue body + advisor scope) | Design element |
|---|---|
| 6 failing tests pass, 5 controls stay green | Sections 2, 5 (guard wired into query, join, export before `Compiler.compile`) |
| Covers query, join query, export, nested/grouped filters | Section 2 (nested/grouped filters: none exist, see F-note in 2.3; walker recurses over any `filters` list element shape by contract) |
| Tests for likert_weight, likert_polarity, question.explanation; row-order test | Section 8 tests T-19..T-22 |
| Unredacted-export exemption explicit and tested; no other route changes | Sections 6, 8 |
| SECURITY-REVIEWER verdict, past-exposure statement | Section 10 |
| Filter and sort on all four routes | Sections 2, 5, 7 |
| Aggregate group_by, measure, having | Section 2.2 (group_by, measure walked; having does not exist, F4, fail-closed registry) |
| Join `on` fields; secondary entities' filters, sort, selected fields against THEIR OWN restrictions | Sections 2.2 (`on` refs), 2.3 (entity-aware refs), F5 |
| Cursor/pagination sort keys, distinct, search, computed expressions | Section 2.2 table (cursor keys == `request.sort`; others nonexistent, fail-closed) |
| One 403 code and body, no field name; unknown vs restricted answer identically | Section 4 |
| Exemption only for exact `:EntitiesRecordsExportUnredacted`, only export, scope filter, audit of names | Section 6 |
| For each clause: restricted 403, permitted 200, exemption export-only | Section 8 |
| Performance | Section 9 |
| #2612 SEC rule applicability | Section 10 |

## 2. The walker: one module, one allow-list, one ref list

New module `Letflow.Entities.Query.RequestGuard` in `lib/letflow/entities/query/request_guard.ex`
(pure core plus one DB-loading composite). It is deliberately NOT inside `Compiler`: `Compiler.compile/2`
has internal callers that are not HTTP and must not change behaviour (`modules/exam/anti_cheat.ex:251`,
`modules/exam/session.ex:220,1326`, `entities/script_reads.ex:196`). The router is the only HTTP caller
and the guard is composed there, mirroring how `check_aggregate_field_restrictions/2` is composed today.
The existing architecture test (`query_cursor_field_grants_test.exs`, "exactly ONE router consumer")
only constrains `Query.Cursor` / `Query.FieldGrants` mentions in routers; a router alias of
`Query.RequestGuard` does not trip it, and the new module itself may alias `FieldGrants`.

### 2.1 Types (shapes only)

- `request_kind :: :row | :aggregate`. `:row` is used by query, join query and export; `:aggregate` by the aggregate route.
- `clause :: :filter | :sort | :group_by | :aggregate_measure | :join_on`. Internal label only, used in
  tests and in the exemption audit; never put in a response body.
- `field_ref :: %{entity_type: String.t(), field: String.t(), clause: clause()}`. `entity_type` is the
  entity whose restriction set governs the ref (the primary for primary-side clauses; the declaring
  entity for `join_on`).
- `restriction_sets :: %{String.t() => MapSet.t(String.t())}`, keyed by entity type name (NOT the
  `:primary` atom used by `FieldGrants.restriction_sets`, so the same map serves refs and redaction;
  section 5 adapts it).
- (Type ownership: `RequestGuard` owns `field_ref`, `clause`, `request_kind`, `guard_ok`, `guard_error` and
  `join_relations_error`; `FieldPolicy.check_request/4` returns them as `RequestGuard.guard_ok()` /
  `RequestGuard.guard_error()` and defines no type of its own for them.)
- `guard_error :: :request_field_restricted | :request_clause_unwalked | Compiler.compile_error()` (the
  last only for the `join` relation lookup, see 2.2).

### 2.2 Public functions (signatures)

1. `field_refs(request :: map(), kind :: request_kind(), prefix :: String.t())`
   `:: {:ok, [field_ref()]} | {:error, :request_clause_unwalked} | join_relations_error()`.
   Pure except for the join lookup. Walks the whole request map by registry (section 3). Refs produced:

   | Request key | Refs produced | Governing entity |
   |---|---|---|
   | `entity_type` | none (names the primary; consumed as the governing entity) | n/a |
   | `filters` | one `:filter` ref per element's `field` | primary |
   | `sort` | one `:sort` ref per element's `field`. This IS the cursor/pagination sort key set: `Cursor.paginate/5` re-resolves only `request.sort` (`cursor.ex:149-153`), a resume key must have `length(sort)+1` components (`:300-304`) and `build_next_cursor` reads values only for those sort fields (`:440-456`). There is no second key source. | primary |
   | `group_by` (aggregate) | one `:group_by` ref per element's `field` | primary |
   | `aggregates` (aggregate) | one `:aggregate_measure` ref per target that carries `:field` (a `count` has none) | primary |
   | `join` | for each join clause, the `:join_on` refs of its resolved hops: the fk field of the DECLARING entity (primary, target or `through`), each ref governed by that declaring entity's type | declaring entity |

   Key shapes: request elements are built by the router with ATOM keys (`%{field: String.t(), op: atom,
   value?: term}` for filters, `%{field: String.t(), dir: atom}` for sort, `%{field: String.t()}` for
   group_by, `%{fn: atom, field?: String.t()}` for aggregates, `%{entity_type, fk, through?, type?}` for
   joins; see `parse_*_clause/1`, `entities.ex:2028-2082`). `field_refs/3` reads atom keys only; a
   string-keyed element (impossible from the router) fails closed as `:request_clause_unwalked`.

   `join_on` resolution reuses the compiler's own definition-derived relation resolver (no second copy
   of fk semantics). Add ONE public function
   `Compiler.join_relations(joins :: [Types.join_clause()], primary_entity_type :: String.t(), prefix ::
   String.t()) :: {:ok, [join_relation()]} | join_relations_error()`.
   - Types: `join_hop :: %{owner_entity_type :: String.t(), fk_field :: String.t()}`;
     `join_relation :: %{exposed_key :: String.t(), hops :: [join_hop()]}`. A DIRECT join has exactly one
     hop (`rel.owner_entity_type`, `rel.fk_field`). A THROUGH join has exactly two hops, in order:
     `[near_hop, far_hop]`, where `near_hop` is `near_rel` (the join entity's fk to the primary; owner =
     the `through` entity) and `far_hop` is `far_rel` (the named relation between the `through` entity and
     the far entity; owner = whichever of the two declares it). T-13 asserts a restricted fk on EITHER hop
     refuses. Each hop yields one `:join_on` ref governed by `owner_entity_type`.
   - Order (it runs the shape checks FIRST, exactly as `compile/2` does at `compiler.ex:161`):
     1. `check_join_shape/1` (`:1183-1192`; width `@max_joins` 4, nested `join` key, duplicate target), so an
        over-wide request does no definition reads and returns the same error `compile/2` would;
     2. `resolve_all_raw_relations/3` (`:1224`), definitions only (`Allowlist.fk_defs/2`), no
        `information_schema`, no query built. An empty `joins` list returns `{:ok, []}` with no I/O.
   - Exact error union `join_relations_error`: `{:error, {:too_many_joins, non_neg_integer}}`,
     `{:error, :join_depth_exceeded}`, `{:error, {:duplicate_join_target, String.t()}}`,
     `{:error, {:field_not_allowed, String.t()}}` (bad fk name, `resolve_named_relation/4`),
     `{:error, {:no_through_relation, String.t(), String.t()}}`,
     `{:error, {:ambiguous_through_relation, String.t()}}`, `{:error, :entity_type_not_found}` and
     `{:error, :invalid_schema_name}` (both from `Allowlist.fk_defs/2`). All are members of the existing
     `compile_error()` union and map through the existing `render_query_error/2` clauses; none is new.
     A request with a join error that `compile/2` would also return gets that same status, now one step
     earlier. `:entity_type_not_found` on the query route renders the hidden 200 through the existing
     `{:error, :entity_type_not_found} -> render_type_hidden` clause.

2. `restriction_entity_types(refs :: [field_ref()], request :: map()) :: [String.t()]`. The distinct set of
   entity types whose sets the guard needs: the primary, plus every ref's governing entity, plus (for the
   later redaction reuse in section 5) every join target. Pure.

3. (Owned by `FieldPolicy`, section 13.1; not a `RequestGuard` function.) `FieldPolicy.load_sets(principal ::
   FieldPolicy.principal(), entity_types :: [String.t()]) :: {:ok, restriction_sets()} | {:error,
   :invalid_schema_name}`, where `principal` carries `user_id` and `prefix`. One `FieldGrants.load_restrictions/3`
   call per distinct entity type, nothing else. Fails closed on any loader error (the error propagates;
   it is not treated as "no restrictions").

4. `check(refs :: [field_ref()], sets :: restriction_sets()) :: :ok | {:error, :request_field_restricted}`.
   Pure. `:ok` only if for EVERY ref, `ref.field` is not a member of `sets[ref.entity_type]`. A ref whose
   entity type is absent from `sets` is an error, not a pass (fail closed, see section 3.4). Exact string
   membership, same comparison `check_aggregate_field_restrictions/2` makes today (`:2180`). No
   case-folding: an allowlist lookup is also exact (`Allowlist.resolve_field/2`, `allowlist.ex:386`), so a
   differently-cased name is simply an unknown field and returns what any unknown field returns.

5. (Composite; owned by `FieldPolicy`, section 13, not by `RequestGuard`.)
   `FieldPolicy.check_request(principal :: FieldPolicy.principal(), kind :: request_kind(), request ::
   map(), opts :: %{required(:exempt?) => boolean()}) :: {:ok, guard_ok()} | {:error, guard_error()}`,
   with `guard_ok :: %{sets: restriction_sets(), exempted: [field_ref()]}`. The composite the router
   calls: `field_refs` then `load_sets` then `check`. With `exempt?: true` it still computes `exempted`
   (the refs that WOULD have been restricted, which the export route needs for the audit entry, section
   6), but returns `{:ok, ...}` instead of the error. `exempt?` is a REQUIRED key with NO default (a call
   without it is a `FunctionClauseError` at the first test, never a silent "not exempt"). It is the
   literal `false` at the query and aggregate call sites; only `run_export/5` passes the parsed
   `unredacted` flag, and only AFTER `check_unredacted_permission/2` returned `:ok` (section 6).
   `RequestGuard` keeps the pure walker only (`field_refs/3`, `restriction_entity_types/2`, `check/2`);
   `load_sets/2` lives in `FieldPolicy`. Earlier text in this document that says "guard" or "guard/5"
   means this `FieldPolicy.check_request/4`.

### 2.3 Entity-aware by construction

`field_ref.entity_type` is mandatory and the only way `check/2` finds a set. There is no "default to the
primary set" fallback. So a future join clause carrying its own filters/sort/selection adds refs governed
by the JOIN TARGET's entity type and is checked against that entity's own set; a ref with an entity type
not loaded fails closed. Nested or grouped filters: no such shape exists (filters are a flat list of
`%{field, op, value}`; the router rejects anything else with `{:query_field_invalid, "filters"}`,
`parse_filter_clause/1`, `:2045`). The walker's contract is "every element of `filters` contributes its
`field`"; if nesting is ever introduced, the registry entry for `filters` must change in the same PR or
the type-introspection test (3.3) fails.

## 3. How "new request clause => unwalked => fail closed" is enforced

Three independent layers (a design that relies on one is a design that fails once).

3.1 Runtime registry with default deny. `RequestGuard` holds ONE module attribute registry per kind:
a closed map from request key to the walk function that handles it. `:row` registry keys:
`entity_type, filters, sort, join`. `:aggregate` registry keys: `entity_type, aggregates, group_by,
filters, join`. `field_refs/3` begins by comparing the request's key set with the kind's registry key
set. ANY key not in the registry returns `{:error, :request_clause_unwalked}` BEFORE any ref is produced
and before any query is built; a registry key whose value is `nil`/absent is simply "no clause", which
is fine. There is no `_ ->` clause, no `Map.get(request, key, [])` for an unlisted key, and no
"walk what I recognise and ignore the rest".

3.2 Router maps it to the SAME 403. `:request_clause_unwalked` and `:request_field_restricted` render
through one function to the same status and the same body (section 4). A developer who adds `having` to
`build_aggregate_request/1` and forgets the guard gets a 403 on EVERY aggregate request that uses it,
loudly, in their first manual or CI test. It is never a silent pass.

3.3 CI tripwire test (type introspection). A test reads the typespecs of the two request types
(`Types.query_request` and `Compiler.aggregate_request`) with `Code.Typespec.fetch_types/1` and asserts
that every map key in each type is present in the matching registry (required AND optional keys). Adding
an `optional(:having)` to `aggregate_request` without a registry entry fails the test. The test also
asserts the reverse (a registry key that is not in the type is flagged), so the registry cannot rot
upward. This is the "test that fails when a new key appears". Companion tests: (a) the keys actually
produced by `build_query_request/1`, `build_export_query_request/2`, `build_aggregate_request/1` for a
maximal body are a subset of the registry (driven through the HTTP routes, see T-14); (b) a request
built with an extra unlisted key returns `:request_clause_unwalked`, and through HTTP the uniform 403
(unit test on `field_refs/3` plus one router-level test using a test-only registry hook is NOT used;
instead the unit test calls `field_refs/3` directly, avoiding any test-only seam in production code).

3.4 `check/2` also fails closed on a ref whose governing entity type has no loaded set, so the
"computed expression / far-side field" class cannot slip through when someone adds a ref but forgets
to load its set.

## 4. Refusal shape and the unknown-vs-restricted question

Uniform refusal: one internal error atom, `:request_field_restricted` (also used for
`:request_clause_unwalked`), rendered by ONE private router function `render_restricted_request/1` to
`Response.forbidden(conn, "one or more requested fields are restricted for this caller")` (the exact
detail string the aggregate route returns today, `entities.ex:2297`, so existing aggregate clients and
tests see no change). Same HTTP status 403, same problem `type`/`title`/`detail`, for every clause and for
all four routes. The body never contains a field name, an entity type name, or the clause name; the
internal `field_ref` list is never put into a log line either (log only the clause label and kind, no
field name, at debug level or not at all). The aggregate route's internal tuple
`{:aggregate_field_restricted, field_name}` carries the name today; it is replaced by the shared atom so
no code path holds a name next to the response. Test T-15 asserts the body string does not contain the
requested field name or the entity type.

Unknown vs restricted, checked against the aggregate route today: they DIFFER. A restricted name gets
403 (`check_aggregate_field_restrictions/2` runs first); an unknown or not-queryable name falls to
`Compiler`/`Allowlist.resolve_field/2` and gets 422 with `field is not queryable: "<name>"`
(`render_query_error/2`, `entities.ex:2597`), which also echoes the caller's own string. REPORT: aggregate
currently answers differently for restricted vs unknown.

Decision, with reason: MATCH the aggregate behaviour (restricted -> 403, unknown -> 422 unchanged), do
NOT collapse unknown into 403. Reasons: (1) F8: the existence of every restricted field is already in the
response as the sentinel key, so a 403 reveals nothing the caller cannot already see; the advisor's
condition "where the caller has no right to know the field exists" is not met for restricted fields
here; (2) collapsing unknown into 403 would change the 422 contract for every caller on every route, which
the issue forbids ("no other route changes behaviour"); (3) the guard runs BEFORE `Compiler.compile`, so a
restricted name is refused with 403 regardless of `queried` (F9), and an unknown name is refused 422 as
today, i.e. the same two answers on all four routes. OPEN QUESTION Q1 asks SECURITY-REVIEWER to confirm.
Not-queryable restricted fields (`likert_weight`, ...) move from 422 to 403 on the row routes (a
restricted name now wins over "not queryable"); that is a deliberate, tested change (T-19..T-21) and is
the same precedence aggregate already has.

## 5. Placement in the three row handlers and reuse of the loaded sets

### 5.1 Query (`run_query/4`)

New chain order (the existing architecture test requires only compile before paginate before redact;
the guard sits before all three, so it still passes):
`build_query_request` -> `build_paginate_opts` -> `guard_row_request` (calls `FieldPolicy.check_request/4`) -> `Compiler.compile` -> `TypeAccess.authorized?`
-> `Allowlist.load` -> `Cursor.paginate` -> `redact` (now fed the already-loaded sets).

Type-hidden preservation (REQ-394, 200-empty envelope for a nonexistent or type-denied entity):
`FieldPolicy.check_request/4` must not turn "type hidden" into a 403 for a caller who may not know the type exists.
`check_request/4` itself knows nothing about TypeAccess and has NO special return shape (its return stays
`{:ok, RequestGuard.guard_ok()} | {:error, RequestGuard.guard_error()}`). The skip lives in `run_query/4` as a private
helper with this signature: `guard_row_request(request :: map(), principal :: FieldPolicy.principal()) :: {:ok, {:checked, RequestGuard.guard_ok()}} | {:ok, :type_denied} | {:error,
RequestGuard.guard_error() | :invalid_schema_name}`. It calls `TypeAccess.authorized?/3` first (one
indexed `exists?`); on `{:ok, :denied}` it returns `{:ok, :type_denied}` WITHOUT calling `check_request/4`; on
`{:ok, :allowed}` it calls `FieldPolicy.check_request(principal, :row, request, %{exempt?: false})` and returns `{:ok, {:checked, ok}}`; a `TypeAccess` error is
returned as is. The `with` chain binds `{:ok, checked}` from this helper. The later, unchanged step
`{:ok, :allowed} <- TypeAccess.authorized?(...)` then receives `{:ok, :denied}` for a denied type, falls
into the existing `else` and renders the hidden 200 via `render_type_hidden/1`, exactly as today. Since
that else-branch is reached before `Cursor.paginate` and `redact`, `redact` is never called for a denied
type and never receives the `:type_denied` value; for an allowed type `redact` receives the sets from
`{:checked, %{sets: sets}}`. `RequestGuard.guard_ok :: %{sets: restriction_sets(), exempted:
[field_ref()]}`. A nonexistent type has no restriction rows, so `TypeAccess` returns `:allowed` and the
check passes trivially; `Compiler.compile` returns `:entity_type_not_found` -> hidden, as today. The
later `TypeAccess` step is kept exactly as is (its result and the REQ-394 tests are unchanged); the
cost is one duplicate indexed exists query on the query route only. Q2 default: keep both calls.
Export and aggregate have no TypeAccess step today (F10) and get none.

### 5.2 Export (`run_export/5`)

Insert `FieldPolicy.check_request/4` after `build_export_query_request` and `build_export_paginate_opts`, before
`Compiler.compile`. The existing steps before it (path/body entity match, `parse_unredacted_flag`,
`check_unredacted_permission`) are unchanged and run first, so a caller without the unredacted
permission is still refused 403 (their existing detail string) before the guard runs.

### 5.3 Aggregate (PR 2)

`run_query_aggregate/4`: replace `check_aggregate_field_restrictions/2` and its helper
`aggregate_request_field_names/1` with `FieldPolicy.check_request(principal, :aggregate, request, %{exempt?: false})`. Behaviour superset: identical
for primary-side targets, group_by, filters (same detail string), and now ALSO refuses a restricted
`join_on` field (F6). `{:aggregate_field_restricted, _}` and its `render_aggregate_error/2` clause are
deleted.

### 5.4 Redaction reuses the guard's sets (no extra load)

`redact/4` currently calls `FieldGrants.load_restrictions/3` again after pagination, once per exposed
entity type. Refactor it into `redact/3` taking the guard's `restriction_sets` (keyed by entity type) and
building the `:primary`-keyed map `FieldGrants.redact_joined_page/2` needs from it (primary -> its set;
each join target -> its set). Redaction policy stays in `FieldGrants` (the router keeps zero redaction
logic, per the `:1944-1949` comment); only the source of the sets changes. The two `redact` clauses keep
branching on `request.join` exactly as today. `export_redact/5` with `unredacted?` true still returns
the page untouched.

## 6. Unredacted-export exemption

Decision: EXEMPT, under exactly these conditions, because the code answers the grant-interaction
question without ambiguity. If any bullet below stops being true in the implementer's re-read, the
instruction in the advisor comment applies: DO NOT exempt, say so in the PR, and the export keeps
refusing (T-17/T-18 flip accordingly).

Evidence that the REQ-231 interaction is clear:
- `run_export/5` (`entities.ex:2368`) calls `export_redact(page, request, user_id, prefix, unredacted?)`,
  and the `true` clause is `defp export_redact(page, _request, _user_id, _prefix, true), do: {:ok, page}`
  (`:2482`): `FieldGrants` is not consulted at all, so every restricted field value is already in the
  response body for that caller, and per-user `user_entity_grants` rows have no effect on that branch.
- `check_unredacted_permission/2` (`:2421-2437`) builds an `AccessContext` from `user_id`, effective roles
  and the platform-tenant flag only, then `Authorization.evaluate_access(ctx, :EntitiesRecordsExportUnredacted)`;
  no field, entity-type or grant lookup is involved, and it returns `{:error, :unredacted_not_authorized}`
  (403, own detail) before any query is built.
- Therefore a filter or sort by a restricted field on an unredacted export discloses nothing the same
  response does not already contain in full (the caller can read every field of every row in the filtered
  set, and can page the whole set without any filter). Refusing it would break an existing, working
  capability of the permission holders (PLATFORM_ADMIN catch-all; TENANT_ADMIN, whose tenant-scope
  permissions include it per `entities_export_test.exs:317`) for no confidentiality gain, which the issue
  forbids ("no other route changes behaviour").

Exemption predicate, all of: (a) route is the export handler; (b) body `unredacted` is the literal
boolean `true` (`parse_unredacted_flag/1` already rejects non-booleans with 400); (c)
`check_unredacted_permission/2` returned `:ok` for the exact atom `:EntitiesRecordsExportUnredacted`. The
router passes `exempt?: unredacted?` to `check_request/4` only AFTER (c) succeeded (the `with` order already
guarantees it). Not role-name checks (`PLATFORM_ADMIN` etc.), not the route-level `:EntitiesRecordsExport`
permission, not a body field on any other route: `build_query_request/1` never reads `unredacted`, so on
`/query` it is inert and the guard runs without exemption (T-18). The other routes always call `check_request/4`
with `exempt?: false` by construction (no parameter plumbing from the body).

Scope filter (0051 D6): today `Compiler.compile/2` has no scope argument (signature
`compile(request, prefix)`, `compiler.ex:153`); the D6 scope filter belongs to REQ-497 and is still behind
`scope_enforcement` flag work (commits 12d03fdb4, 2b628b534 are adjacent, not this). So the "export's own
scope filter gates the exemption" clause is vacuous on today's code. Design obligation for the future D6
PR (record in its checklist, not implemented here): the exempt path must keep using the SAME compiled,
scope-ANDed query, so a restricted-field filter can never widen the row set beyond scope. Because the
exemption only allows more predicates and sort keys on top of the already scoped query, it cannot widen
scope by itself. OPEN QUESTION Q3 flags this for the supervisor.

Audit of the exemption (names only, never values): when `check_request/4` returns a non-empty `exempted` list,
`run_export/5` writes ONE audit entry BEFORE the query executes, via `Audit.insert_entry(Repo, attrs,
prefix)` (`audit.ex:231`), `action` e.g. `"entities.export.unredacted_restricted_clause"`,
`resource_type` `"entity_type"`, `resource_id` the path entity type, `actor_id` the caller, `before_state`
nil, `after_state` a map holding three lists of field NAMES: `filter_fields`, `sort_fields`,
`restricted_fields_used`; the `filter_fields`/`sort_fields` lists include the join fk field names that
were walked (`join_on` refs). Ordering (SEC R3): the audit insert is written AFTER `Compiler.compile`
succeeds and BEFORE `Cursor.paginate` runs (export chain: ... `build_export_paginate_opts` -> `check_request/4`
-> `Compiler.compile` -> `audit_exempted` -> `Allowlist.load` -> `Cursor.paginate` -> `export_redact`), so
a request that fails to compile (422/404) never writes an audit entry, and no query is EXECUTED without a
successful audit (compile builds an Ecto query and runs only definition/`information_schema` reads). Fail closed:
`audit_exempted(user_id, path_entity_type, prefix, exempted) :: :ok | {:error, {:export_audit_failed,
reason :: term()}}`; an `Audit.insert_entry/3` error or raise is mapped to
`{:error, {:export_audit_failed, reason}}`. It renders through a NEW clause
`render_export_error(conn, {:export_audit_failed, reason})` that logs `reason` (no field names in the log
line) and returns `Response.internal_error(conn)` (detail-free 500); the generic `render_export_error/2`
fallthrough would also 500 but logs as a query failure, so the dedicated clause is required. No records
are returned. The entry carries field NAMES only: never filter values, and never a field name that was
refused (a refusal writes no audit entry and no log line containing names or values, SEC R4). When `exempted` is empty (no restricted field named) no entry is written
(the existing unredacted export has no audit and this issue does not add one for unrelated requests).
Audit entries are hash-chained writes, so the cost applies only to the rare exemption path; its set load
for `exempted` is the only extra query on that route. The action string is new; verified: no audit-action registry or enum exists (`Audit.insert_entry/3` takes
any string, `entry_attrs` is free-form), see Q4. The audit WORDING beyond names is
GH #2698 territory and untouched.

## 7. What changes on each route (summary)

| Route | Change |
|---|---|
| `POST /entities/query` (plain and join) | guard added; redact reuses sets; 403 for any restricted filter, sort, join `on` |
| `POST /entities/records/:entity_type/export` | guard added; exemption only when unredacted permission passed; audit on exercise |
| `POST /entities/query/aggregate` (PR 2) | old check replaced by guard; adds join `on`; same 403 text |
| everything else (records CRUD, definitions, exam router, internal `Compiler.compile` callers, script reads) | no change |

## 8. Tests (per clause; extend the existing evidence file, do not duplicate its 11)

Fixtures reuse `exam_ctx!/2` (real Exam restrictions) and `join_ctx!/1` from the evidence file. Every
refusal test asserts status 403, that the body detail equals the shared string, that the body does not
contain the requested field name or the entity type name, and that no `items`/`records`/`results` key is
present. Every "permitted" twin issues the same request shape with an unrestricted field and asserts 200.

| ID | Clause / position | Route | Expect |
|---|---|---|---|
| T-01..T-06 | the 6 existing failing tests (filter, sort, join filter, join sort, export filter, export sort) | query/join/export | 403 |
| T-07 | filter restricted + permitted twin on `text` | query | 403 / 200 |
| T-08 | sort restricted + permitted twin | query | 403 / 200 |
| T-09 | filter restricted, export default mode, TENANT_ADMIN | export | 403 |
| T-10 | sort restricted, export default mode | export | 403 |
| T-11 | `join_on` fk restricted for the caller (restriction row on the declaring entity's fk field), plain direct join | query | 403; twin with unrestricted fk 200 |
| T-12 | `join_on` where the declaring entity is the JOIN TARGET (restriction row on the target's fk field, NOT the primary's) | query | 403; proves the set of the declaring entity, not the primary, is used |
| T-13 | `join_on` where the declaring entity is the `through` entity | query | 403 |
| T-14 | maximal body with extra unlisted keys (`having`, `distinct`, `search`, `unredacted` on /query) | query, export, aggregate | status equals the same body without them (inert); no 500 |
| T-15 | (SEC R4 also: no filter value and no refused field name in any log line, see T-38) refusal body contains no field name and no entity type; the decoded problem document has equal `status`, `type`, `title` and `detail` across filter, sort, join `on`, export, aggregate (compared field by field; whole-body byte equality is NOT asserted) | all | field-wise equality |
| T-16 | unknown field (`nope`) in filter and in sort | query, export, aggregate | 422 unchanged (documents the section 4 decision) |
| T-17 | exemption: `unredacted: true`, TENANT_ADMIN, filter by restricted `is_correct` | export | 200, rows filtered, audit entry present with field NAMES only, no values |
| T-18 | exemption does not leak: (a) `unredacted: true` body on `/query` with restricted filter; (b) export WITHOUT `unredacted` flag; (c) caller holding `:EntitiesRecordsExport` but not `:EntitiesRecordsExportUnredacted` sending `unredacted: true` | query, export | (a) 403 (b) 403 (c) existing unredacted 403 detail |
| T-19 | `answer_option.likert_weight` restricted: filter, sort | query | 403 (pack shape queried:false: precedence over "not queryable") |
| T-20 | `answer_option.likert_polarity`: filter, sort | query | 403 |
| T-21 | `question.explanation`: filter, sort | query | 403 |
| T-21b | same three with `queried:true` flipped in the definition | query | 403 (the live-leak variant of F9) |
| T-22 | row order: seed A,B,C; sort `text` desc permitted -> response order C,B,A and asc -> A,B,C; sort `is_correct` -> 403 with no items | query | order asserted from `items`, proving the sort clause is real and that the restricted one yields nothing |
| T-23 | granted caller: `user_entity_grants` row for `is_correct` filters and sorts | query, export | 200 (the existing control 6a extended with sort) |
| T-24 | type-hidden preserved: type-denied caller sending a restricted filter | query | 200 `{"items":[],"next_cursor":null}`, byte-equal to the same request with an unrestricted filter |
| T-25 | cursor: page 1 of a permitted sort mints `next_cursor`; resend with a different (restricted) sort | query | 403 (guard runs before cursor decode); permitted resend 200 |
| T-26 | tripwire: typespec keys of `Types.query_request` and `Compiler.aggregate_request` all present in the registry (and the reverse); AND (SEC R6) the registry key set equals the key set the three builders (`build_query_request/1`, `build_export_query_request/2`, `build_aggregate_request/1`) emit for a maximal body, observed through the HTTP routes | unit + router | pass; fails if a key is added to a type, a builder or the registry alone |
| T-27 | `field_refs/3` with an extra unlisted key returns `{:error, :request_clause_unwalked}` | unit | error |
| T-28 | `check/2` with a ref whose entity type has no loaded set returns `{:error, :request_field_restricted}` | unit | error |
| T-29 (PR 2) | aggregate: restricted in group_by, measure (`sum`/`min`/`max` on restricted), filter, join `on`; permitted twins | aggregate | 403 / 200; old behaviour preserved |
| T-31 | join response redaction (guards the `redact/3` refactor, section 5.4): a restricted field of the JOINED (far-side) entity comes back as the sentinel, not the value, while the permitted twin (caller with a `user_entity_grants` row for it) sees the value; repeat with a restriction on a field of the entity that is the join TARGET and declares the fk (declaring entity = join target), and with the primary's restricted field | query (join) | sentinel vs value, per entity |
| T-32 | audit failure: force `Audit.insert_entry/3` to fail on an exempted export (audit runs after compile, before paginate) | export | detail-free 500 via `render_export_error({:export_audit_failed, _})`, no `records` key |
| T-33 | a non-exempt export writes NO audit entry: (a) default mode with permitted fields; (b) `unredacted: true` with only unrestricted filter/sort fields | export | 200, `audit_entries` row count unchanged |
| T-34 | SEC R5: nonexistent primary type with (a) a `join`, (b) a restricted-looking filter (`is_correct`); and a type-denied caller with a `join` | query | 200 `{"items":[],"next_cursor":null}`, byte-equal to today's response for the same request; `join_relations` errors (`entity_type_not_found`, `field_not_allowed`) on a nonexistent primary render the same hidden 200 as today, never a 404/422/403 difference |
| T-35 | granted-user export: caller holding a `user_entity_grants` row for `is_correct` filters/sorts on default-mode export | export | 200 |
| T-36 | the grant belongs to a DIFFERENT user (row for user B, caller is user A) | query, export | 403 |
| T-37 | audit content: exempted export with a join; the audit entry's `after_state` holds field names only (including the join fk names), no filter values, and the response/log lines contain no value | export | assertion on `audit_entries` row and `ExUnit.CaptureLog` |
| T-38 | R4: on every 403 path capture logs; no log line contains the requested field name or any filter value | all | pass |
| T-39 | router architecture: inside `run_query`, `run_export` and `redact` restriction sets come only through `FieldPolicy` (no direct `FieldGrants.load_restrictions/3`); `run_query_aggregate/4` allow-listed until #2699 | source grep | pass |
| T-40 | FieldPolicy unit tests: `redact/3`, `redact_with_sets/3` (explicit sets-map assertion), `restriction_set/2` own-grant vs other-user grant, `check_request/4` and `redact/3` agree on membership | unit | pass |
| T-30 | performance guard: Ecto telemetry counts `entity_field_restrictions` queries for a plain query and a joined query, asserts equal to the number of distinct entity types (no second load by `redact`) | query | count equality |

Regression: the existing `entities_answer_key_field_leak_test.exs`, `entities_export_test.exs`,
`entities_aggregate_test.exs`, `query_cursor_field_grants_test.exs` (chain-order test), REQ-394 type-access
tests, and the join tests in `entities_test.exs` stay green. `mix compile --warnings-as-errors`, format
check, scoped tests (the affected `test/letflow/routers/*` and `test/letflow/entities/query_*`), quoted.

### Mutants the suite must kill (6)

| M | Mutation | Killed by |
|---|---|---|
| M1 | drop the `sort` walk (sort refs not produced) | T-02/T-08/T-10/T-22 |
| M2 | drop the `filters` walk for the export route only | T-05/T-09 |
| M3 | skip `join_on` refs, or produce them but govern them with the PRIMARY's set | T-11, T-12, T-13 |
| M4 | exemption keyed on route-level permission only (ignore the `unredacted` flag, or ignore the second permission check order) | T-18(b), T-18(c) |
| M5 | exemption honoured on `/query` when the body carries `unredacted: true` | T-18(a) |
| M6 | unlisted key silently ignored (registry default allow), or `check/2` passes a ref with no loaded set | T-27, T-28, T-26 |

Spare, also killed: refusal body includes the field name (T-15); `redact` reloads sets (T-30); guard
runs after TypeAccess skip incorrectly so a denied type returns 403 (T-24).

## 9. Performance

- Query route: restriction loads are unchanged in count. Today `redact/4` loads one set per exposed entity
  type after pagination; the guard loads those same sets before and `redact` reuses them (section 5.4),
  so net restriction queries = distinct entity types touched (primary + join targets), plus ONE for each
  `through` or declaring-only entity type that is not itself exposed (only for through joins). Added
  fixed costs: one indexed `TypeAccess` exists (query route, section 5.1) and, for requests with `join`,
  one definition read per entity involved in `Compiler.join_relations/3` (`Allowlist.fk_defs/2`, which
  `compile/2` repeats; accepted, the two are cheap compared with the paginated query and the
  `information_schema` probes `compile/2` does).
- Plain request with no filter, sort or join: zero extra queries beyond today (the primary set is still
  loaded once, now before instead of after, and reused). No ref work.
- Export: same; the exempt path loads sets only to build `exempted` when filters or sort are present.
- Aggregate: unchanged count (one set load today and after).
- Pure work is O(number of clauses), bounded by the request size and `@max_joins` (4).

## 10. Invariants, gates and the #2612 SEC rule

- INV-1: no new data access path; `prefix` stays `prefix!(conn)`; `user_id` stays the auth context's; the
  guard takes both as arguments and reads neither from the body. INV-2 (server-side field authorisation)
  is the invariant this fixes: restricted data must not influence the response by any request position.
  INV-5-style uniformity: one refusal for every clause. INV-8: an unwalked clause or loader error is an
  explicit refusal or the detail-free 500, never a silent pass.
- SECURITY-REVIEWER: MANDATORY (tenant-data path, response shaping). It must also (a) assess whether
  production-like data could already have been inferred through this path: yes in principle for any
  tenant where a restricted field is `queried:true` (the shipped Exam `is_correct` is), reachable by
  `:EntitiesQuery` holders (TASK_WORKER, TENANT_AUDITOR, PROCESS_DESIGNER/OPERATOR) and, for export, by
  `:EntitiesRecordsExport` holders; (b) state plainly that audit events record mutations only (`Audit` is
  written at mutation boundaries, `audit.ex` moduledoc "Capture mechanism"), so reads through this path
  were never recorded and past exposure cannot be established from audit data.
- #2612 (the permission-matrix trust-boundary rule, merged as REQ-498 in PR #2612; mandatory
  SECURITY-REVIEWER trigger paragraph in `.claude/agents/security-reviewer.md` and WF-02 Step 2c): NOT
  triggered by this design. The fix touches none of `ci.yml`, `cd.yml`, `scripts/ci_changed_paths.sh`,
  `scripts/cd_qa_decide.sh`, `mix.exs`, any `config :letflow, :modules`, `lib/mix/tasks/letflow.permission_matrix.ex`,
  `lib/letflow/api/permission_matrix.ex`, `lib/letflow/api/authorization.ex`, `lib/letflow/modules/catalog.ex`,
  or `priv/permission_matrix/`. It adds no permission atom (the exemption reuses the existing
  `:EntitiesRecordsExportUnredacted`, called through the unchanged `Authorization.evaluate_access/2`) and
  no `role_grants`. If the implementer finds a need to edit `authorization.ex` or the golden file, the rule
  becomes triggered and the PR must say so. The SECURITY-REVIEWER gate applies anyway on the tenant-data
  path ground above.
- REVIEWER: mandatory (idiom, scope creep). Decision-record consistency: 0051 D6 (scope filter, section 6),
  0050/0057 not touched.
- Migrations: none. New module: one file. No new table.

## 11. PR size and split

Estimate for the whole change: about 1,650 lines (guard module about 220, `FieldPolicy` about 150 including its tests, `Compiler.join_relations/3`
about 35, router wiring and `redact` refactor about 140 changed, tests about 1,000). That is over a
comfortable single-review size for a priority-1 security fix, so split:

- PR 1 (ships first): `RequestGuard` (both registries and `request_kind` types), `Compiler.join_relations/3`,
  guard wired into `run_query/4` and `run_export/5` (including join `on`, the exemption and its audit,
  the `redact/3` set reuse), tests T-01..T-28 and T-30..T-40. Aggregate route untouched in PR 1 (still its
  own check). Roughly 1,250 lines with tests (includes the ~150 FieldPolicy lines of section 13.3). This closes the 6 failing tests and the oracle the issue
  proves.
- PR 2: aggregate migration (guard with `:aggregate` kind, delete `check_aggregate_field_restrictions/2`
  and `{:aggregate_field_restricted, _}`), aggregate `join_on`, T-29 and the aggregate half of T-26.
  Roughly 400 lines. Must follow PR 1 immediately (same priority) because until it lands the aggregate
  join `on` hole (F6) stays open.
- If PR 1 review shows it is still too big, split `join_on` (Compiler wrapper, T-11..T-13) into a PR 1b;
  but then the `join` registry key MUST stay fail-closed for any request with a non-empty `join` until 1b
  merges, which would make joined queries 403 for everyone; so do not split that way unless 1b follows
  within the same day. Preferred: keep `join_on` in PR 1.
- Branch and merge discipline per core-directives: PR 1 says "Refs #2697", NOT "Closes #2697" (the issue
  stays open until the aggregate hole is closed). PR 2 is issue #2699, filed at EQUAL priority (prio 1)
  BEFORE PR 1 merges. PR 1's description must state plainly that the
  aggregate join `on` PRESENCE ORACLE (F6: an inner join on a restricted fk drops rows by fk presence,
  and the aggregate route's check ignores `join`) stays open until PR 2 merges, and must name PR 2's
  tracking issue number (SEC R1). The PR 2 issue is filed before PR 1 merges.
- PR body must also state past exposure (SEC condition b): any tenant with a restricted `queried:true`
  field (the shipped Exam `is_correct`) was exploitable by every `:EntitiesQuery` and
  `:EntitiesRecordsExport` holder via filter or sort on `/query`, join and export; join `on` disclosed
  the fk value; audit records mutations only, so past reads cannot be established.
- #2612 would trigger if the implementation edits `lib/letflow/api/authorization.ex` or
  `priv/permission_matrix/effective.golden` (SEC review must then be re-run); the design needs neither.

## 12. Open questions (none is a silent assumption; each has the design default)

Q1. DECISION pending SECURITY-REVIEWER confirmation. Default (applied by the design): restricted -> 403,
unknown -> 422, matching the aggregate route today (F8). Alternative (collapse to one answer) changes the
422 contract on every route and is not recommended.
Q2. DECIDED (default): keep both TypeAccess calls in `run_query/4` (signature in section 5.1). Alternative
(thread the first result, delete the later step) needs REQ-394 chain/test edits and is not taken.
Q3. DECIDED, supervisor to confirm in the PR: the exemption ships WITHOUT a scope-filter gate because no
0051 D6 scope filter exists in `Compiler.compile/2` today (signature `compile(request, prefix)`,
`compiler.ex:153`). The D6 PR must keep the exempt path on the scope-ANDed compiled query (checklist item).
Q4. CLOSED: no audit-action registry, enum or golden file exists (`entry_attrs.action` is a free-form
string). This is the first read-path audit entry in the codebase; SECURITY-REVIEWER must accept that
(audit is otherwise mutation-oriented).
Q5. CLOSED into section 11: PR 2 is #2699, filed at prio 1 before PR 1 merges; PR 1 uses "Refs #2697".
Q6. F10 is its OWN issue, #2700 (not this PR, not PR 2): `run_export/5` and `run_query_aggregate/4` have no
`TypeAccess` step, so a type-denied caller can export or aggregate a type `/query` hides. Tracked in #2700.
Q8. Pre-existing, separate issues (recorded, not fixed here): (a) `TypeAccess` checks only the PRIMARY type,
so rows of a type-denied JOIN TARGET can come back through `/query` joins; (b) export and aggregate have no
`TypeAccess` step (Q6). Both tracked in #2700.
Q7. Restricted+`queried:false` fields change from 422 to 403 on the row routes (tested). A grep of `test/`
for the exam pack fields found no test asserting the 422, but the implementer must re-run the full
entities test set.


## 13. Shared policy module: `Letflow.Entities.FieldPolicy` (supervisor/advisor addition)

Goal: a field is restricted by ONE rule everywhere (request side now; event payloads, record reads and
exports later). Today the rule is spread across `FieldGrants.load_restrictions/3` (the set), the aggregate
check, `redact/4` in `entities.ex`, and two more direct `load_restrictions` callers
(`entities/handler_writes.ex:265`, `entities/step_writes.ex:786`).

### 13.1 Module spec (signatures and shapes only)

New file `lib/letflow/entities/field_policy.ex`.
- `principal :: %{user_id :: String.t(), prefix :: String.t()}`. Built only from the auth context and
  `prefix!(conn)`; never from a body (INV-1). No role names inside: restriction is by grant rows (F7).
- `restriction_set(principal, entity_type) :: {:ok, MapSet.t(String.t())} | {:error, :invalid_schema_name}`.
  The single entry point to the rule; delegates to `FieldGrants.load_restrictions/3` unchanged (the anti-join
  stays where REQ-231 put it; FieldPolicy does not copy SQL).
- `load_sets(principal, entity_types :: [String.t()]) :: {:ok, %{String.t() => MapSet.t(String.t())}} |
  {:error, :invalid_schema_name}`. One `restriction_set` per distinct entity type; this is the
  `load_sets` of section 2.2 item 3 (same function; the `(user_id, entity_types, prefix)` form of earlier drafts is gone).
- `check_request(principal, kind :: :row | :aggregate, request :: map(), opts :: %{required(:exempt?) =>
  boolean()}) :: {:ok, %{sets: map(), exempted: [RequestGuard.field_ref()]}} | {:error,
  :request_field_restricted | :request_clause_unwalked | RequestGuard.join_relations_error()}`.
  This is the composite named `guard/5` in earlier drafts; it calls `RequestGuard.field_refs/3`, `restriction_entity_types/2`, `load_sets/2`,
  `RequestGuard.check/2`. `RequestGuard` stays as the pure walker (no DB except the definition read in
  `Compiler.join_relations/3`).
- `redact(principal, entity_type, field_values :: map()) :: {:ok, map()} | {:error,
  :invalid_schema_name}`. Loads the set via `restriction_set/2` and applies `FieldGrants.redact_field_values/2`
  (sentinel semantics unchanged). This is the function PR-0b and the later read-time redaction PR (event
  payloads, record reads, exports) call.
- `redact_with_sets(sets :: map(), entity_type :: String.t(), field_values :: map()) :: map()`. Pure; the
  form `entities.ex` `redact/3` uses with the sets already loaded by `check_request/4`.

### 13.2 How guard and redact share the restriction set loading

One loader (`restriction_set/2`) feeds both. On the query route `check_request/4` loads the sets once
(keyed by entity type); the router's `redact/3` (section 5.4) passes the SAME map to the PAGE functions
`FieldGrants.redact_page/2` (plain shape) and `FieldGrants.redact_joined_page/2` (join shape, after
re-keying the primary under `:primary`). Page shaping stays in `FieldGrants`, which already has the
plain/promoted/joined item clauses and the raise-rather-than-pass-through behaviour; FieldPolicy does not
duplicate it. The router does NOT call `redact_with_sets/3` or `FieldPolicy.redact/3` in PR 1 (they are
per-record functions for later callers, see 13.3). So a request is refused or its response redacted from
one consistent snapshot of the grants, not two loads that could straddle a grant change.

### 13.3 What moves in PR 1 vs later (PR 1 size stays bounded)

PR 1 (in addition to section 11): create `FieldPolicy` with `restriction_set/2`, `load_sets/2`,
`check_request/4`, `redact_with_sets/3` and `redact/3`; the router `redact/4` -> `redact/3` refactor
(behaviour-preserving: same sentinel, same per-entity sets) takes its sets from `check_request/4` and
passes them to `FieldGrants.redact_page/2` / `redact_joined_page/2`. `FieldPolicy.redact/3` and
`redact_with_sets/3` are UNIT-TESTED ONLY in PR 1 and have no production caller until PR-0b / the
read-time redaction PR (they are kept in PR 1 so the one rule has both faces from day one; if PR 1 review
finds it too large they are the first thing to drop, with T-40's redact assertions). Net
added size is about 90 lines of module plus about 60 lines of tests, because the walker and loader code
already counted in section 11 simply live under a different module name.
NOT in PR 1: migrating `handler_writes.ex:265` / `step_writes.ex:786` callers, event-payload redaction,
record-read redaction, the `FieldGrants` internals, and the aggregate route (PR 2 swaps its call to
`FieldPolicy.check_request/4` with `:aggregate`).
PR-0b and a later read-time redaction PR reuse `FieldPolicy.redact/3` and `restriction_set/2` unchanged;
any new redaction site must call FieldPolicy, and a test (T-39, in PR 1, router architecture only) greps `lib/letflow/routers/entities.ex` and asserts that, inside `run_query`,
`run_export` and `redact`, restriction sets are obtained only through `FieldPolicy` (no direct
`FieldGrants.load_restrictions/3` call). The aggregate call site `run_query_aggregate/4`
(`entities.ex:2161`) is explicitly ALLOW-LISTED in PR 1, because it keeps its own check until PR 2
(#2699) swaps it to `FieldPolicy.check_request/4`; PR 2 removes the allow-list entry and widens the
assertion to the whole router. The existing "one router consumer" architecture test keeps its
Cursor/FieldGrants constraint and is updated to allow the `FieldPolicy` alias.

### 13.4 Added test and mutant

T-39 (router architecture only): the grep assertion of 13.3 (no direct `FieldGrants.load_restrictions/3` in
`run_query`, `run_export`, `redact`; aggregate call site allow-listed until #2699).
T-40 (FieldPolicy unit tests): `redact/3` sentinels exactly the restricted keys and passes others;
`redact_with_sets/3` given an explicit sets map sentinels exactly the keys in the set for that entity type
and passes others (explicit assertion); `restriction_set/2` honours a grant for the caller and not for a
different user; `check_request/4` and `redact/3` agree on membership for the same principal and entity
type (a field refused as restricted in a request is redacted in a response, and vice versa).
Mutant M7: `redact/3` / `redact_with_sets/3` and `check_request/4` use different sets (e.g. one ignores
grants) -> killed by T-40.
