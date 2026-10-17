# GH #2700 design: TypeAccess on the primary type AND every join target, on /query, export and aggregate

Status: DESIGN (CODE-DESIGNER, 2026-10-17). Priority 2, SECURITY. Design only, no implementation code.
Sources: GH #2700 (body carries the ACs; its only comment is a heartbeat), merged code on main a26d04fa9 read for this
design (cited below), `lib/letflow/design/req394-per-entity-type-authorization.md` (2.1, 2.2, 3.1, 3.2),
`lib/letflow/design/gh2697-restricted-field-request-walker.md`, `lib/letflow/design/gh2699-aggregate-join-restricted.md`
(B1 lesson: existence precedence), `docs/agents/instructions/security-invariants.md` (INV-2, INV-5).
Reads only; no mix run. Decision 0050 D7 (managed_by write lock) was read and does NOT apply: it governs write routes,
this change touches read routes only.

## 0. Findings from the merged code (every later section depends on these)

F1. TypeAccess is applied exactly twice on read paths in `lib/letflow/routers/entities.ex`: `run_query/4` (the
`guard_row_request/2` pre-read at ~1961 and the later `{:ok, :allowed} <- TypeAccess.authorized?(...)` step at ~1923,
both on `request.entity_type` ONLY) and `render_get_definition/3` (~915). `run_export/5` (~2376) and
`run_query_aggregate/4` (~2201) have no TypeAccess step. Correction to the issue text: the call at ~913 is the
definitions-read route, not a "single-record route"; the entities router has no single-record READ route (the table
lists only attachments, which are #2718).

F2. The hole on /query: a join target the caller is type-denied for is joined and returned. The response shaper
(`redact/3` -> `FieldGrants.redact_joined_page/2`) redacts FIELDS, never types. For a `through` join the through entity
is not exposed as a row but its fk column is the inner-join condition, so a denied through type leaks fk PRESENCE
(the same oracle class as #2699 F2).

F3. The hole on aggregate: `count` over `join: [{denied_type, fk}]` returns the number of primary rows that have a
matching row in the denied type. No TypeAccess step exists on this route at all, so even the PRIMARY type is
unchecked: a type-denied caller aggregates a hidden type directly (gh2699 F9 recorded this as owned by this issue).

F4. The hole on export: `run_export` returns full records (default-redacted fields) of a type-denied primary type,
and of any denied join target. No TypeAccess step.

F5. What an UNKNOWN join target returns today (read from `Compiler.join_relations/3`, `resolve_raw_one/4`,
`resolve_named_relation/4`, `resolve_through_near_hop/3`, `Allowlist.fk_defs/2`):
- direct join: `resolve_named_relation(primary, T, fk)` looks in `fk_defs(primary)`; no match -> `fk_defs(T)` ->
  `{:error, :entity_type_not_found}` for a nonexistent T. (If the primary itself declares a matching fk to the
  nonexistent name, the relation resolves and the failure surfaces later in `Compiler.compile/2`; rare, covered by
  the existence step below.)
- through join: `resolve_through_near_hop` -> `fk_defs(through)` -> `{:error, :entity_type_not_found}`; far hop via
  `resolve_named_relation(through, far, fk)`.
- rendering: `:entity_type_not_found` reaches `render_query_error/2` as a 404 (`Response.not_found/1`) on aggregate
  and export (their fallthrough clauses), and is converted LOCALLY by `run_query/4`'s `else` into the hidden 200
  envelope `{"items": [], "next_cursor": null}` (`render_type_hidden/1`, REQ-394 2.2). So today an unknown join
  target on /query already answers 200-empty, and on aggregate/export answers 404.
- An existing but wrong-fk target answers `{:error, {:field_not_allowed, fk_name}}` -> 422 echoing the caller's
  string, a DIFFERENT response from unknown. Therefore a naive "check denied targets after relation resolution"
  design leaks: denied+valid-fk succeeds/is refused one way, denied+wrong-fk 422, unknown not-found. See section 3.

F6. Error ordering inside `Compiler.join_relations/3`: `check_join_shape/1` (too_many_joins, join_depth_exceeded,
duplicate_join_target; caller-structure facts, independent of any type's existence or grants) -> `ensure_primary_exists/3`
(missing primary is `:entity_type_not_found` before any join-specific error, B1) -> per-join resolution. `compile/2`
runs `check_join_shape` first as well.

F7. `TypeAccess.authorized?/3` is documented as NOT an existence oracle (it answers "denied if restricted", never "does
it exist") and does one `TenantProvisioning.tenant_id_for_schema_name/1` lookup plus one `Repo.exists?` per call. A
restricted type is denied to everyone without a `user_entity_type_grants` row; there is no role dimension.

F8. Other callers that compile a request WITHOUT TypeAccess (checked by grep of `Compiler.compile(`,
`Compiler.run_aggregate(`, `join_relations`): `lib/letflow/entities/script_reads.ex` (~196, definition-authored script
reads with an allowlisted field and a single eq filter, no join), `lib/letflow/modules/exam/{anti_cheat,session,snapshot}.ex`
and `lib/mix/tasks/letflow.seed.exam_fixtures.ex` (server-authored requests). None accepts a caller-written join/
filter body; they are not caller-query routes. Recorded, out of scope (Q5).

F9. Adjacent hole found while reading, OUT of scope (file a follow-up, Q6): `GET /entities/definitions`
(`handle_list_definitions/1`, ~934) lists all definitions with no TypeAccess filter, so denied type names and field
schemas appear in the list although the three single-definition GETs hide them. The attachments routes also have no
TypeAccess (#2718).

F10. Web/script callers: `grep` over `web/src` (non-test) and `scripts/` finds NO caller of `query/aggregate`, of the
`records/<type>/export` route, or any request carrying `join`/`through`. `web/src/api/entities.ts` uses the plain
/query only. Exam and BA flows do not use joins over restricted types (implementer re-greps `lib/`, `web/src`,
`test/fixtures`, `scripts/` and records the result in the PR).

## 1. Scope

In scope: one shared request-level gate applied to `POST /entities/query`, the join form of /query (same route),
`POST /entities/records/:entity_type/export` (with and without `unredacted`), `POST /entities/query/aggregate`; the
batch TypeAccess read; the pure request entity-type extraction; deletion of the two scattered TypeAccess uses on
/query; tests.
Out of scope: definitions list leak (F9), attachments (#2718), internal compile callers (F8), counts/pagination
metadata (#2698), any change to the field-restriction walker's own rules, any migration, any `web/` change.

## 2. Decisions (with evidence)

### D1. One gate over the whole compiled-request entity set, in one new module, used by every route

New module `Letflow.Entities.RequestAccess` (lib/letflow/entities/request_access.ex). It is the ONLY thing the router
calls for a caller's query-shaped request; it composes the type gate and then the existing field guard. This keeps
`FieldPolicy` unchanged (its moduledoc: it knows nothing about TypeAccess) and makes "new clause covered by default"
structural:

- Every router site that today calls `FieldPolicy.check_request/4` (run_query via guard_row_request, run_export,
  run_query_aggregate) is replaced by `RequestAccess.check/4`. A source test (same style as T-39) asserts the router's
  code lines contain `FieldPolicy.check_request(` zero times and `TypeAccess.authorized?(` only inside the
  definitions-read function (`render_get_definition/3`). A future route that wants the field guard must therefore go
  through the type gate.
- The entity-type set comes from ONE pure function, `RequestGuard.request_entity_types/2`, which reads the request
  through the same closed registry as `field_refs/3`: it returns the primary plus, for each join clause, its
  `entity_type` and its `through` (if present). Any key outside `registry_keys(kind)` or any malformed join element
  fails closed as `{:error, :request_clause_unwalked}`. The registry gains a second closed table classifying every
  registry key as `:carries_entity_types` (`entity_type`, `join`) or `:no_entity_types` (`filters`, `sort`,
  `group_by`, `aggregates`); a tripwire test fails if a key is in the registry but in neither class, so adding a
  request clause forces an explicit decision on whether it can name another entity type.

Public signatures (types only):

- `RequestAccess.check(principal :: FieldPolicy.principal(), kind :: RequestGuard.request_kind(), request :: map(), opts :: %{required(:exempt?) => boolean()}) :: {:ok, RequestGuard.guard_ok()} | {:error, access_error()}`
  where `access_error() :: :entity_type_not_found | RequestGuard.guard_error()`. `opts.exempt?` is required exactly as
  in `FieldPolicy.check_request/4` and passed through unchanged; it affects only the field step (D6).
- `RequestGuard.request_entity_types(request :: map(), kind :: request_kind()) :: {:ok, [String.t()]} | {:error, :request_clause_unwalked} | Compiler.join_shape_error()` (distinct, primary first, order stable).
  ORDER INSIDE (explicit, because `check_join_shape/1` does `Map.fetch!(:entity_type)` and would crash on a malformed
  element, while `field_refs/3` today returns `:request_clause_unwalked` before any shape check): (1) walk first: an
  unknown top-level key, a non-list `join`, a join element that is not a map or lacks a binary `entity_type`, or one
  with a non-binary `through`, returns `{:error, :request_clause_unwalked}`; (2) only then call
  `Compiler.join_entity_types/1` for the shape errors. The function never raises on any input.
- NEW exported type `Compiler.join_shape_error() :: {:error, {:too_many_joins, pos_integer()}} | {:error, :join_depth_exceeded} | {:error, {:duplicate_join_target, String.t()}}`
  (members exactly these three reasons, wrapped in `{:error, _}` consistently with `Compiler.compile_error()`; no bare
  forms anywhere). `Compiler.join_relations_error()` already contains these three members and is unchanged.
- `Compiler.join_entity_types(joins :: [Types.join_clause()]) :: {:ok, [String.t()]} | Compiler.join_shape_error()`
  (pure; runs the existing `check_join_shape/1` and then lists each clause's `through` and `entity_type`; no I/O;
  callers must pass well-formed elements, which `request_entity_types/2` guarantees by step (1)). It is the only new
  Compiler function, so the shape check stays single-sourced and the gate can run after it (D3).
- `TypeAccess.denied_types(user_id :: String.t(), entity_types :: [String.t()], prefix :: String.t()) :: {:ok, MapSet.t(String.t())} | {:error, :invalid_schema_name}` -
  ONE tenant-id lookup and ONE query (restriction rows for the given names left-joined to this user's grant rows,
  keeping rows with no grant). The names are bound as a typed array parameter (`type(^names, {:array, :string})`,
  never interpolated; INV-7), de-duplicated first, and the user id keeps the `type(^user_id, Ecto.UUID)` cast
  `authorized?/3` uses. `[]` input returns an empty set with NO I/O (not even the tenant lookup). `authorized?/3`
  keeps its signature and semantics; a test asserts the two agree for every type in a mixed fixture.

Behaviour of `check/4` (sequence, each step's failure is final):
1. `RequestGuard.request_entity_types(request, kind)`; errors propagate (`too_many_joins`, `join_depth_exceeded`,
   `duplicate_join_target`, `request_clause_unwalked`).
2. `TypeAccess.denied_types` over the whole set (an error from it refuses; never default-allow).
3. CONSTANT WORK (SECURITY ruling R1): an existence read via `Allowlist.fk_defs/2` (the primitive
   `ensure_primary_exists/3` uses; maps a missing definition to `:entity_type_not_found`) for EVERY distinct type in
   the set, unconditionally, including when step 2 already found denied types, with no short-circuit on the first
   absent or denied type. Only after all reads finish is one decision made: any denied or any absent type ->
   `{:error, :entity_type_not_found}`; `{:error, :invalid_schema_name}` from any read propagates (unreachable via
   `prefix!/1`). The extra cost falls only on the refusal path.
4. `FieldPolicy.check_request(principal, kind, request, opts)` unchanged, run only when steps 2-3 found nothing.

"Denied" and "absent" are the SAME atom produced by the SAME function exit, so the two cannot be distinguished by any
later code or by any renderer (D2).

### D2. Refusal shape PER ROUTE: reuse each route's existing not-found rendering; invent no shape (RECOMMENDED, needs SECURITY-REVIEWER ruling)

`:entity_type_not_found` is the refusal for primary-denied, primary-absent, join-target-denied, join-target-absent,
through-denied and through-absent alike. Each route renders it exactly as it renders a nonexistent primary today:

| Route | Denied / absent primary or any denied / absent join target | Evidence |
|---|---|---|
| `POST /entities/query` (plain and join) | 200 `{"items": [], "next_cursor": null}` via `render_type_hidden/1` | REQ-394 2.2; `run_query/4` `else` clause |
| `POST /entities/records/:entity_type/export` | 404 `Response.not_found/1` (zero-detail) | `render_export_error/2` -> `render_query_error(:entity_type_not_found)`; INV-5 test at `entities_export_test.exs` ~502 |
| `POST /entities/query/aggregate` | 404 `Response.not_found/1` | `render_aggregate_error/2` -> same clause; INV-5 test in `entities_aggregate_test.exs` |

Why this and not the alternatives:
- Indistinguishability is then structural: the denied outcome is not a new response, it IS the nonexistent-type
  response of that route. No new byte-for-byte equality to maintain beyond the existing INV-5 tests.
- 403 for a denied type (rejected): confirms the type exists, an existence oracle (INV-5). Also contradicts REQ-394.
- 200-empty on export/aggregate (rejected as default): aggregate has no empty-envelope precedent (`count` over zero rows
  is a legitimate one-row `[{count: 0}]`; `results: []` would be a new, distinguishable-from-legit shape) and export's
  envelope carries `exported_at`, schema version and the path entity_type, so a denied export would need a new
  hand-built success body that must stay byte-identical to a nonexistent one. It would also CHANGE today's shipped 404
  for nonexistent types on both routes (breaking the existing INV-5 tests for no security gain). Cost of the
  recommended shape: the 200-vs-404 status split between /query and export/aggregate is already how the product
  behaves for nonexistent types today; it is not a new inconsistency.
- A denied join target on /query hides the WHOLE request (200-empty), identical to an unknown join target today (F5).
  Silently dropping a denied LEFT join and returning primary rows would answer differently from an unknown target,
  an oracle; rejected (Q2 default).
- Logging: the refusal logs nothing type-identifying (no Logger call on the denied branch); a debug line naming the
  denied type would be an operator-side oracle in shared logs.

### D3. Ordering relative to the field-restriction guard, and why existence precedes both

Final per-route order (parse stays first and type-independent):
build/parse (400) -> [export only: path/body match 422, unredacted flag 400, unredacted permission 403, all
type-independent and unchanged] -> `RequestAccess.check/4`: (1) shape errors, (2) denied-set, (3) existence, (4) field
guard (403 restricted / join_relations 422 errors) -> `Compiler.compile` or `run_aggregate` (422/404) -> paginate ->
redact.

Reasons, each from evidence:
- The type gate must precede the field guard: a restricted-field 403 on a denied type would confirm the type exists
  and has restrictions. This is the same reason `guard_row_request/2` read TypeAccess first for the primary; the new
  gate generalises that and DELETES the `{:ok, :type_denied}` special result.
- The type gate must precede `join_relations` resolution (F5): resolving a denied target's fk first would answer
  `field_not_allowed` (422, echoing the fk) for a wrong fk on an existing denied type but not-found for an unknown
  type. Gating all targets before any relation is resolved makes denied == absent for every fk value.
- Shape checks (too_many/depth/duplicate) stay BEFORE the gate (step 1), preserving today's order for absent targets
  (F6: shape first, existence second). They depend only on the request structure, so they are identical for denied and
  absent targets; no oracle.
- Step 3 existence for ALL targets before ANY relation resolution closes the multi-join combination oracle: absent
  target at join[1] plus a wrong-fk join[0] must answer exactly what denied target at join[1] plus the same wrong-fk
  join[0] answers (both not-found now; before, the wrong-fk error would have won for the absent one only).
  Behaviour change recorded in section 6.
- After step 3 passes, every type is visible and exists, so errors from `join_relations`, field-not-allowed and
  restricted-field 403 can only echo things about types the caller may see.

### D4. Cursor and pagination interplay (no new surface)

Gate runs on every request including cursor continuations, so a type that becomes restricted between pages yields the
hidden 200-empty (query) or 404 (export) on the next page. `Cursor.paginate/5` errors (expired, invalid cursor,
wrong_endpoint, arity) are produced only after the gate, so a denied type never reaches them.

### D5. Performance (extra reads) and reuse

Added per request: `denied_types/3` = 1 tenant lookup + 1 query regardless of join count (single-type calls via
`authorized?/3` were up to 2 per request on /query before: the pre-read and the later step; both are deleted, so
/query is net neutral on TypeAccess reads). Existence step: up to 1 + 2*4 = 9 `Allowlist.fk_defs` definition reads
worst case (max 4 joins, each with a through); typical 1-3. These definitions are reloaded later by `join_relations`
(walker) and `compile`; no cache is introduced (matches gh2699 R3/R5 acceptance of repeated definition reads). Reuse of
the loaded sets: unchanged (`check/4` returns the field guard's `guard_ok` so /query and export redaction still use the
one consistent snapshot). A possible later optimisation (single `entity_definitions` name query) is Q4, not in this PR.
Requests with no `join` incur one `fk_defs` read for the primary that `compile/2` makes anyway (net +1 read on aggregate
and export, 0 extra DB round trips on /query beyond that read).

### D6. Exempt (unredacted) export: type denial is NOT exempted

`opts.exempt?` (the `:EntitiesRecordsExportUnredacted` permission) governs only whether restricted FIELD references
are refused or audited (gh2697 design 6). It does not lift type denial: `RequestAccess.check/4` receives `exempt?` and
forwards it only to step 4. An unredacted exporter denied a type gets the export 404, and an exempt export with a
restricted field on an allowed type still works unchanged (audited as before). Q3 asks SECURITY-REVIEWER to confirm.

## 3. Data model

No tables, columns, indexes, migrations or constraints change. Reads existing `entity_type_restrictions` and
`user_entity_type_grants` (no Ecto schema modules, queried by table name as in `authorized?/3`) and entity definitions.
No gen_statem. New modules: `Letflow.Entities.RequestAccess` only. New functions: `TypeAccess.denied_types/3`,
`RequestGuard.request_entity_types/2` (+ the entity-type classification table), `Compiler.join_entity_types/1`.
Router: delete `guard_row_request/2`, the `TypeAccess.authorized?` step in `run_query/4`, and the `redact/3`
`FunctionClauseError` comment about `:type_denied`; the `{:ok, :denied}` `else` clause in `run_query/4` becomes dead
and is deleted (denial arrives as `{:error, :entity_type_not_found}`); `render_type_hidden/1` stays.
### 3.1 Existing tests this design BREAKS (EDITED, with replacement assertions) and stale comments to reword

Edited tests (they pin the structure being replaced; they are not "unaffected"):
- `test/letflow/entities/query_cursor_field_grants_test.exs` chain-order extraction of `run_query/4`: new steps are
  build, paginate-opts, `RequestAccess.check`, compile, allowlist, paginate, redact; `RequestAccess.check` stays ahead
  of `Compiler.compile` and of any SQL.
- `test/letflow/routers/entities_query_restricted_walker_test.exs` T-39 (~1375-1430) and A-12 (~1432-1468). They now
  assert that `guard_row_request` exists, that `run_export` and the aggregate function contain
  `FieldPolicy.check_request`, and that the aggregate binds `{:ok, _x} <- FieldPolicy.check_request`. All contradict
  the single gate (T-18). Replacement assertions (code lines only, comments stripped as the existing helpers do):
  `run_query`, `run_export` and `run_query_aggregate` each contain `RequestAccess.check(`; the router file contains
  zero `FieldPolicy.check_request(`, zero `guard_row_request`, zero direct `FieldGrants.load_restrictions(`; in each
  of the three functions `RequestAccess.check(` precedes `Compiler.compile(` / `Compiler.run_aggregate(`; only
  `run_export` passes a non-literal `exempt?` (the other two pass the literal `false`); the aggregate function binds
  the result as `{:ok, _..}` and its `else` is only `{:error, reason} -> render_aggregate_error(conn, reason)` (no
  catch-all turning an error into success).
- `test/specs/GH2697-query-restricted.md` T-39/M5/M10 wording is updated to match (docs only).
- The REQ-394 tests in `test/letflow/routers/entities_test.exs` keep their HTTP assertions (200-empty); only a
  source-shape assertion mentioning the old `{:ok, :denied}` branch, if any, is edited. Any combined-error test hit by
  R2 (section 6) is edited.

Stale comments/docs to reword (docs only): the `redact/3` comment about `:type_denied` and `FunctionClauseError`
(~1999-2006); the `guard_row_request/2` comment block (~1949-1956, deleted with the function); the
`render_query_error/2` comment at ~2643-2647 describing `{:ok, :denied}` (denial now arrives as
`:entity_type_not_found`); the `run_query/4` `else` comments (~1932-1942); the moduledoc route-table rows for `query`
(add `RequestAccess.check`), `query_aggregate` (row 64) and `export_records`; the aggregate INV-2 comment (~2178-2186).

## 4. Invariants

- INV-5 (existence): for every route, a type-denied and a nonexistent entity type, as primary, as direct join target,
  as far target, or as `through`, in any join position and combination with other join errors, yield the same status
  and byte-identical body.
- INV-2: no row, count or fk presence derived from a type the caller is denied is returned on any route.
- INV-1: the principal is built only from `auth_context.user_id` and the resolved prefix; body keys `tenant_id`,
  `schema`, `prefix`, `user_id` remain inert.
- Fail closed: an unwalked clause, an unclassified registry key, or an unexpected error from the denied-set read refuses
  the request; the existence/denied results never default to "allowed" on error.
- Single gate: a router source test pins that no query-shaped route reaches `FieldPolicy.check_request` except through
  `RequestAccess.check`.
- Gate-before-SQL: no query is built or run before `RequestAccess.check/4` returns `{:ok, _}`.

## 5. Cross-module dependencies

`Letflow.Routers.Entities` -> `RequestAccess` -> {`RequestGuard.request_entity_types/2` -> `Compiler.join_entity_types/1`,
`TypeAccess.denied_types/3`, `Allowlist.fk_defs/2`, `FieldPolicy.check_request/4`}. No new dependency edge from
`TypeAccess` to `Compiler`; `TypeAccess` stays a pure grants reader (its existence-oracle rule is kept: existence is
resolved by `RequestAccess`, the caller of record).

## 6. Behaviour change and risk for existing callers

R1. Intended: callers that join a type-denied target, aggregate or export a denied type now get the route's
not-found response. Because `entity_type_restrictions` is default-allow, a tenant with no restriction rows sees no
change at all (the existing REQ-394 "never inserts a row" test is extended to the new routes).
R2. Reorder: an absent join target combined with another join error in an EARLIER join clause (for example a wrong fk)
now answers not-found instead of the earlier clause's 422 (the existence step runs before any relation is resolved).
Reveals nothing; strictly more private. Existing tests asserting such a combined case (grep
`entities_*test.exs` for `field_not_allowed` with a join) are updated; expected few.
R3. /query with a denied or absent join target already answered 200-empty for absent targets; denied targets move from
"data returned" to the same 200-empty. Aggregate/export gain the 404 for denied primaries, matching their nonexistent
behaviour.
R4. Callers: F10 found no web or script caller of aggregate/export/join; seed fixtures and the Exam module do not
join type-restricted types (implementer confirms by re-grep and records it in the PR). Past exposure: audit records
mutations only, so earlier reads of denied types through these routes cannot be established; the PR body states this
(same wording class as #2699 R/11).
R5. Extra reads (D5): bounded, no schema change.
R6. DB-work equality (SECURITY ruling, INV-5): a denied and an absent request of the same shape issue the same number
of definition reads and the same single denied-set query (D1 step 3, constant work); asserted by T-22. The only
remaining difference (fetching an existing versus a missing definition by the same single `fk_defs` read) is the
accepted residual; the earlier "timing accepted" wording is withdrawn.

## 7. Acceptance criteria -> design elements

| AC (GH #2700) | Element |
|---|---|
| a join to a type-denied target returns no rows of that type on /query | D1 step 2 on the join set; section 2 table; tests T-1..T-4 |
| export and aggregate on a denied type are refused (or empty by the ruled shape) | D1/D2: 404 on both; T-8, T-9, T-10 |
| the permitted case still works | T-5, T-11, T-12 |
| unknown and denied join targets are indistinguishable | D1 steps 2-3 share one exit; D3 ordering; T-6, T-7, T-13 byte-equality matrix |
| refusal shape defined per route and SEC ruling | D2 table; Q1 awaits the SECURITY-REVIEWER ruling (mandatory gate) |
| SECURITY-REVIEWER and REVIEWER verdicts; scoped tests; warnings-as-errors compile; format check quoted | section 10 gates and the PR checklist |
| primary AND every join target including `through` on /query, join query, export, aggregate | D1 `request_entity_types/2` (primary + entity_type + through); T-1..T-4, T-8..T-10 |

## 8. Tests

New file `test/letflow/routers/entities_type_access_request_test.exs` (router-level, real Postgres tenant, reuses the
walker-test tenant seeding helpers `exam_ctx!/3`-style and the REQ-394 test's restriction/grant insert helpers in
`entities_test.exs`), plus `test/letflow/entities/request_access_test.exs` (unit) and edits to
`type_access_test.exs`, `query_request_guard_test.exs`, `query_cursor_field_grants_test.exs`.

Fixture: five entity types in one tenant: primary `P`; `J` (declares fk to `P`, direct); `T` (through; fk to `P`
and fk `f_id` to `F`); `F` (far); `N` (allowed unrelated). A caller `U` with the route permissions. `entity_type_restrictions`
rows are inserted per case; `U` holds no `user_entity_type_grants` row for the restricted type unless the case says
"granted".

| ID | Test | Expected |
|---|---|---|
| T-1 | /query, `P` allowed, direct join to `J` restricted for `U` | 200 `{"items": [], "next_cursor": null}`; no row of `J` or of `P` in the body |
| T-2 | /query, `through: T` restricted (near hop type), far `F` allowed | same 200-empty; no `P` rows, no fk presence |
| T-3 | /query, `through: T` allowed but far target `F` restricted | same 200-empty |
| T-4 | /query, primary `P` restricted, join allowed | same 200-empty (existing REQ-394 primary case still byte-identical to an absent primary) |
| T-5 | permitted twins: the same T-1..T-3 shapes with `U` holding a grant row (and with no restriction rows at all) | 200 with the expected joined rows; field redaction unchanged |
| T-6 | indistinguishability matrix on /query: for each position (direct target, far target, through) compare the response for a DENIED existing type against an ABSENT type name, with a valid fk, with a wrong fk, and combined with a wrong-fk earlier join clause and with a duplicate-target clause; also a case where the PRIMARY itself declares the fk to a denied far type (the existence step, not relation resolution, produces the refusal) | status, content-type header and FULL body bytes identical within each pair |
| T-7 | same matrix on aggregate and export (404 bodies) for denied vs absent primary and denied vs absent join/through | status, content-type and FULL body bytes identical, denied vs absent; includes `unredacted: true` export, a `through` hop and a far hop; same trace-less body as the existing INV-5 tests |
| T-8 | aggregate, primary `P` restricted, no join; and with a join | 404; `count` over the hidden type returns no number |
| T-9 | aggregate, primary allowed, direct join / through to a restricted target (presence oracle: N rows, K with the fk set, 0<K<N) | 404, no number anywhere |
| T-10 | export default-mode and `unredacted: true` (holder of the unredacted permission), primary restricted; and with a restricted join target | 404 both; no audit row written for the denied request |
| T-11 | aggregate and export permitted (unrestricted, and granted) incl. joins | 200 unchanged counts/records |
| T-12 | exempt export on an allowed type with a restricted FIELD in filter | still 200 and still audited (type gate does not disturb the exemption) |
| T-13 | restricted field AND denied target in one request on every route | not-found shape, never 403 (type gate precedes field guard); with the type visible the 403 still appears |
| T-14 | `RequestGuard.request_entity_types/2` unit: primary only, direct, through (both names), duplicates removed, order stable; join element missing `entity_type` or non-map; extra top-level key; a malformed join element TOGETHER WITH more than 4 joins (and with a duplicate target) -> `:request_clause_unwalked`, no crash (walk precedes the shape check) | `{:ok, ...}` / `:request_clause_unwalked` |
| T-15 | registry classification tripwire: every key of `registry_keys(:row)` and `(:aggregate)` is classified; a synthetic extra key fails | pass / fail as stated |
| T-16 | `TypeAccess.denied_types/3`: empty input, mixed types, granted vs ungranted, other user's grant, agrees with `authorized?/3` for every fixture type; ANOTHER user holds the grant (still denied for U); duplicate type names in the input (deduped); `[]` makes zero queries; names are a bound typed array | as stated; one query (query-count assertion) |
| T-17 | `RequestAccess.check/4` order unit: shape error beats denied; denied beats existence; denied beats restricted field; `exempt?` forwarded only to the field step; error from `denied_types` refuses (no default-allow); step 3 runs a read for EVERY distinct type even when step 2 found a denied type or an earlier type is absent | as stated |
| T-18 | route walk completeness (source test): router code lines call `RequestAccess.check(` in `run_query`, `run_export`, `run_query_aggregate` and nowhere call `FieldPolicy.check_request(`; `TypeAccess.authorized?(` appears only in `render_get_definition`; the source test FAILS if any handler in the router calls `Compiler.compile(` or `Compiler.run_aggregate(` without `RequestAccess.check(` ahead of it (a new handler cannot skip the gate); it replaces the T-39/A-12 assertions of section 3.1 | pass |
| T-19 | a tenant with no `entity_type_restrictions` rows: every route (query plain/join, aggregate, export) byte-identical to main for a fixed request set | pass (no-change guarantee) |
| T-20 | log capture on a denied request: no log line contains the type name, fk name or the word restricted/denied; also no audit row is written and no telemetry event metadata carries the type name | pass |
| T-21 | existing suites unchanged and green EXCEPT the tests listed as edited in section 3.1 (chain-order test, walker-test T-39/A-12, the GH2697 spec wording, any R2 combined-error case) | pass |
| T-22 | equal DB work (R1): for each route, a denied request and an absent request of the same shape (primary, direct join, far, through) issue EQUAL numbers of DB queries. Use the `measure_pair/4` second-boundary retry pattern from `test/letflow/routers/instances_synthetic_hidden_test.exs` (or context-level calls without tokens) so the #2729 wall-clock-second flake cannot occur | equal counts |

## 9. Mutants the suite must kill (>= 6)

M1. Gate only the primary type (the current bug): killed by T-1, T-2, T-3, T-9.
M2. Gate `entity_type` of joins but skip `through`: killed by T-2 (near hop denied) and T-3 variants.
M3. Gate after relation resolution or after the field guard (order swap): killed by T-6 (wrong-fk pair), T-13.
M4. Map denied to 403/422/different body instead of the shared not-found atom: killed by T-6/T-7 byte equality and T-8.
M5. Skip the gate on the unredacted export path or on aggregate: killed by T-10 and T-8/T-9.
M6. Return the type-denied set but treat an error from `denied_types` as empty (default-allow): killed by T-17.
M7. Existence step only for the primary (join targets unchecked): absent far target + wrong earlier fk differs from denied:
killed by T-6 combined case.
M8. Router calls `FieldPolicy.check_request` directly on a new/changed route, bypassing the gate: killed by T-18.
M9. Add a request key to the registry without classifying it: killed by T-15.
M10. Denial logged with the type name: killed by T-20.
M11. `authorized?/3` and `denied_types/3` diverge (grant join condition dropped): killed by T-16.
M12. Step 3 short-circuits on the first absent type or is skipped when step 2 found a denied type (DB-work oracle): killed by T-22 and T-17.
M13. `request_entity_types/2` runs the shape check before the walk (crash on a malformed element): killed by the T-14 malformed-plus-too-many case.
M14. `denied_types/3` interpolates names or drops the user-id cast: killed by T-16.

## 10. PR size, shape, gates

One PR, "Closes #2700". Estimate: `request_access.ex` ~70 lines; `type_access.ex` +25; `request_guard.ex` +35;
`compiler.ex` +15; router net -30 (three call sites replaced, `guard_row_request/2` and the old step deleted, moduledoc
route-table rows and four comment blocks reworded); tests ~450 across the files above. Roughly 650-750 changed lines
including tests, no migration, no `web/`. If REVIEWER prefers a split, the natural seam is PR a (shared helper,
`/query` migrated, deletes the two old sites) and PR b (aggregate and export wired plus their tests); each is
independently correct and each strictly narrows exposure.
Gates: SECURITY-REVIEWER (mandatory per the issue; INV-2, INV-5; ruling on D2/D6), REVIEWER, TEST-DESIGNER/VALIDATOR,
RELEASE-VALIDATOR per the workflow; run CI-shaped checks locally (warnings-as-errors compile, `mix format --check-formatted`,
the scoped suites) before push.
#2612 (permission-matrix trust boundary): NOT triggered. No change touches `ci.yml`, `cd.yml`,
`scripts/ci_changed_paths.sh`, `scripts/cd_qa_decide.sh`, `mix.exs`, `config :letflow, :modules`,
`lib/mix/tasks/letflow.permission_matrix.ex`, `lib/letflow/api/permission_matrix.ex`, `lib/letflow/api/authorization.ex`,
`lib/letflow/modules/catalog.ex` or `priv/permission_matrix/`, and adds no permission atom or role grant. If
implementation finds it must, the rule triggers and SECURITY-REVIEWER re-runs.
PR body must state (SECURITY R3): past exposure (section 6 R4); the R2 reorder; and cite the definitions-list leak issue
(F9; number pending from letflow-2, filed before this PR merges) and #2718 as still open.

## 11. Open questions (each has a default; none is silently assumed)

Q1. (APPROVED by SECURITY) Per-route refusal shape. RECOMMENDED and defaulted: reuse each route's existing
not-found response (200-empty on /query, 404 on export and aggregate), D2. Alternatives rejected above (403 =
existence oracle; 200-empty everywhere = new shapes and breaks shipped 404 contract).
Q2. (RULED) A denied target on a left or inner join: refuse the whole request (dropping the join is distinguishable
from an absent target).
Q3. (RULED) The unredacted-export permission never lifts type denial (D6).
Q4. (RULED) Existence check mechanism: `Allowlist.fk_defs/2` per distinct type (reuses a proven primitive, up to 9
reads worst case). Alternative: one `entity_definitions` name query. Default now, optimise only if measured.
Q5. (RULED out of scope by SECURITY) Internal callers that compile requests without TypeAccess (`script_reads.ex`,
Exam server paths, seed task, F8).
Q6. Follow-up (not this PR, see rulings below): `GET /entities/definitions` returns denied definitions (F9, own issue,
filed before this PR merges); attachment routes are #2718.
Q7. CLOSED by SECURITY (R1): constant work, D1 step 3; timing is not accepted as residual.
Q8. CLOSED: no audit row and no log line for denied reads.

SECURITY-REVIEWER design rulings recorded (handoff step-03): Q1 shapes approved (D2); Q2 whole request refused, left or
inner; Q3 the unredacted permission never lifts type denial; Q4 one `fk_defs` read per distinct type (bounded at 9);
Q5 out of scope (script_reads and scripts/policy.ex already refuse any restricted type; exam paths are
server-authored); Q6 CONFIRMED MEDIUM leak: `GET /entities/definitions` has no TypeAccess filter (schema/metadata
disclosure and a type-name existence oracle). It is filed as its own priority-2 issue (number pending from letflow-2,
to be cited in the PR body; the filter belongs inside the cursor-paginated query, not after the page). Until it lands
the byte-identical guarantee on these routes is only as strong as that route. Attachments remain #2718.
