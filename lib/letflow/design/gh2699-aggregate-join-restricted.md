# GH #2699 design: aggregate route migrates to the shared restricted-field walker (join clause closed)

Status: DESIGN (CODE-DESIGNER, 2026-10-17). Priority 1, SECURITY. Design only, no implementation code.
This is PR 2 of #2697 (PR 1 merged: `FieldPolicy`, `RequestGuard`, `Compiler.join_relations/3`, row-route integration).
Sources: GH #2699 (issue body, which carries the ACs; its comments are heartbeats only), GH #2697 body + advisor scope comment
(binding), `lib/letflow/design/gh2697-restricted-field-request-walker.md` (sections 5.3, 11, 13, T-26, T-29,
T-39), merged code read on this branch (cited below). Reads only; no mix run.

## 0. Findings from the merged code (every later section depends on these)

F1. Today's aggregate flow (`lib/letflow/routers/entities.ex` `run_query_aggregate/4`): `build_aggregate_request/1`
-> `FieldGrants.load_restrictions(user_id, request.entity_type, prefix)` (primary type only) ->
`check_aggregate_field_restrictions/2` (aggregate target `:field`, `group_by` field, `filters` field, exact
`MapSet.member?` against the PRIMARY set) -> `Compiler.run_aggregate/2`. Errors go through
`render_aggregate_error/2`.

F2. THE HOLE (presence oracle): the old check never reads `request.join`. `Compiler.compile_aggregate/2`
builds `aggregate_base_joined/4` with `add_all_hops/2`, an INNER join on each fk (`pj.join_type`), so rows whose
fk is NULL/absent are dropped. `count` over `join: [{entity_type, fk: <restricted fk>}]` therefore returns the
number of primary rows whose restricted fk is present; with a `through` join, the same through the far hop's fk.
The restricted field's value is never returned, its PRESENCE is. Closed by walking `join` (section 3).

F3. Aggregate field resolution is PRIMARY-ONLY. `compile_aggregate/2` resolves `filters`
(`build_all_filter_dynamics(filters, allowlist, ctx)`), `group_by` (`resolve_group_by_specs/2`) and aggregate
targets (`resolve_aggregate_specs/2`) all against `Allowlist.load(entity_type, prefix)` of the PRIMARY type.
There is no syntax to name a joined entity's field in any of those three positions; a name that is not a
primary field is `{:field_not_allowed, name}` -> 422. Consequence: the only joined-entity-governed fields on the
aggregate route are the join `on`/fk/through fields (each governed by the entity that DECLARES the fk,
`join_hop.owner_entity_type`). "Joined entity filter/group_by against its own restrictions" is therefore
unreachable by construction; the design states this and tests that the request is refused with 422 (name not
queryable on primary), not silently evaluated against the joined entity (section 6, A-6).

F4. The aggregate response does NOT redact values: `aggregate_result_map/1` reshapes `group__*`/`agg__*` keys
only. Every value it can contain is a group key or a measure over a field that the guard already proved
unrestricted, so there is nothing to redact. Hence NO `redact` reuse of the guard's loaded sets on this route;
the `sets` returned by `FieldPolicy.check_request/4` are intentionally unused by `run_query_aggregate/4`.
(`restriction_entity_types/2` still loads a set per join target; the extra reads are accepted, see risk R5.)

F5. `HAVING`/other clauses do not exist. `Compiler.aggregate_request` keys: `entity_type, aggregates, group_by,
filters, join` (`compiler.ex` `@type aggregate_request`); `build_aggregate_request/1` copies exactly those five;
`RequestGuard` `@registry.aggregate` is the same five. `having`, `distinct`, `search`, `order` do not exist on
this route and are inert (T-14/T-26 already pin this). Confirms the PR 1 F4 finding for #2697's "confirm
`having` is covered".

F6. What `RequestGuard.field_refs(request, :aggregate, prefix)` already produces: filters (`:filter`), group_by
(`:group_by`), measures with a `:field` (`:aggregate_measure`; `count` contributes none), and `join_refs`
(`:join_on`, one ref per hop, `owner_entity_type`/`fk_field` from `Compiler.join_relations/3`). It rejects any
key outside the registry with `:request_clause_unwalked`, and string-keyed/malformed elements likewise. All
refs for filters/group_by/measure are tagged with the PRIMARY type (matches F3). So the existing walker already
subsumes everything the old check did and the join; PR 2 is only router wiring + deletion + tests. No change to
`RequestGuard`, `FieldPolicy` or `Compiler` is required.

F7. Nonexistent primary today (must be preserved byte-for-byte): no join -> `load_restrictions` returns an empty
set (query on `entity_record_restrictions` finds no rows) -> check passes -> `run_aggregate` -> `Allowlist.load`
`{:error, :entity_type_not_found}` -> `render_aggregate_error` fallthrough -> `render_query_error` ->
`Response.not_found/1` = 404 (pinned by `entities_aggregate_test.exs` "INV-5": nonexistent and cross-tenant
types give byte-identical 404). With a join: `compile_aggregate` runs `check_join_shape` then
`Allowlist.load(primary)` -> `:entity_type_not_found` -> the same 404. The aggregate route has NO hidden-200
envelope (that is `/query` only, REQ-394); this PR must not introduce one.
After migration: no join -> walker does no I/O for joins, `load_sets` yields an empty set for the missing
type, compile gives 404 (unchanged). With a join -> `Compiler.join_relations/3` runs `check_join_shape`, then
`ensure_primary_exists/3` (`Allowlist.fk_defs(primary, prefix)`) BEFORE any join-specific resolution, so a
missing primary yields `{:error, :entity_type_not_found}` -> same 404, never `no_through_relation` 422
(the B1 lesson, already built into `join_relations/3`; this PR relies on it and adds a test, section 6 A-8).

F8. `render_aggregate_error/2` for the guard's atoms: `:request_field_restricted` and `:request_clause_unwalked`
fall through the final `render_aggregate_error(conn, reason)` clause to `render_query_error/2`, whose merged
clause (`reason in [:request_field_restricted, :request_clause_unwalked]`) returns
`Response.forbidden(conn, "one or more requested fields are restricted for this caller")`. That is the SAME
status and the SAME detail string as the deleted `{:aggregate_field_restricted, _}` clause. So no new render
clause is needed; the dedicated clause is deleted. `Compiler.join_relations_error()` members
(`too_many_joins`, `join_depth_exceeded`, `duplicate_join_target`, `field_not_allowed`, `no_through_relation`,
`ambiguous_through_relation`, `entity_type_not_found`) are already rendered by `render_query_error/2` exactly as
`compile_aggregate` errors are today. `:invalid_schema_name` renders as it does on /query (500 class, unreachable
after `prefix!/1`); not new.

F9. TypeAccess: the aggregate route has no `TypeAccess.authorized?/3` step today (#2700 tracks adding it for
join targets, and export/aggregate type access generally; PR 1 design F10/Q6). This PR does NOT add one and does
NOT use `guard_row_request/2` (that wraps the TypeAccess-then-guard ordering for /query only). "TypeAccess
ordering" for aggregate is therefore: unchanged, no step. A type-denied caller's aggregate over a hidden type
behaves exactly as on main (still reachable; tracked by #2700, out of scope). The design records this so a
reviewer does not mistake it for an omission.

## 1. Scope

In scope: `lib/letflow/routers/entities.ex` `run_query_aggregate/4` and the deletion/rewording around it; the
T-39 allow-list; tests. Out of scope: #2700 (TypeAccess on join targets, export, aggregate), #2698 (counts/
pagination metadata, audit text), #2718 (attachment routes), any change to the walker, `FieldPolicy`,
`Compiler` or the registry.

## 2. Public interface changes

No new public function. No type changes.

Private router function (shape only):

- `run_query_aggregate(conn :: Plug.Conn.t(), body :: map(), user_id :: String.t(), prefix :: String.t()) :: Plug.Conn.t()`
  unchanged signature. New step order inside its `with`:
  1. `build_aggregate_request(body)` (unchanged; parse errors 400 as today).
  2. `FieldPolicy.check_request(%{user_id: user_id, prefix: prefix}, :aggregate, request, %{exempt?: false})`
     returning `{:ok, RequestGuard.guard_ok()}`; the ok value is discarded (F4). `exempt?` is the literal
     `false` (T-39 "only run_export passes a non-literal exempt?" keeps holding; the source-grep test already
     asserts exempt? lines).
  3. `Compiler.run_aggregate(request, prefix)` (unchanged).
  Error value domain of the `with` else: `RequestGuard.guard_error()` plus `Compiler.aggregate_compile_error()`
  plus parse errors; all rendered by `render_aggregate_error/2` -> `render_query_error/2` (F8).
- The principal map is built ONLY from `conn.assigns.auth_context.user_id` and `prefix!(conn)` as today (INV-1);
  the body is never read for either.

Deleted (private, no external callers; verified by repo grep: only `lib/letflow/routers/entities.ex` and the
`lib/letflow/design/*` docs and one test-file doc comment reference them):

- `check_aggregate_field_restrictions/2` and `aggregate_request_field_names/1`: fully subsumed by
  `FieldPolicy.check_request/4` with `:aggregate` (F6): same three positions, same exact-string membership
  against the primary set, plus join `on`/fk/through hops.
- The `render_aggregate_error(conn, {:aggregate_field_restricted, _})` clause: replaced by the merged guard
  clause in `render_query_error/2` (F8). The atom `:aggregate_field_restricted` must no longer appear in `lib/`.

What the ISS-0647 tests rely on (all behaviour, none of the deleted names):
`test/letflow/routers/entities_answer_key_field_leak_test.exs` (the "reachable via aggregate" fact-finding at
~240 and "aggregate route now rejects filtering by is_correct with 403" at ~318, plus an unrestricted `count` on
the same type that must stay 200), `entities_query_restricted_filter_test.exs` control "(1) aggregate filtered
by the restricted field -> 403", `entities_aggregate_test.exs` "INV-2 ..." (restricted target/group_by/filter,
sum+filter, and the grant-holder-not-restricted case at ~343), `exam_snapshot_leak_test.exs` T-30(2). They
assert HTTP status 403 and the problem detail only; they reference `check_aggregate_field_restrictions/2` in
doc comments only (`entities_query_restricted_filter_test.exs` line ~6 comment). Comment text referencing the
deleted function is updated (docs only), not behaviour.

## 3. Walk coverage per acceptance clause (every GH #2697/#2699 aggregate clause maps to an element)

| Clause (aggregate) | Walker element | Governing set | Result |
|---|---|---|---|
| aggregate measure (`sum`/`avg`/`min`/`max` `field`) | `measure_refs` `:aggregate_measure` | primary | 403 if restricted |
| `count` (no field) | no ref | n/a | allowed |
| `group_by` | `:group_by` | primary | 403 |
| `filters` | `:filter` | primary | 403 |
| join `fk` (direct) | `join_refs` hop `{owner_entity_type, fk_field}` `:join_on` | declaring entity's own set | 403 |
| join `through` near hop and far hop | two hops, each `{owner, fk_field}` | each hop's owner entity's own set | 403 |
| joined entity "filters/group_by" | not expressible (F3) | n/a | 422 `field_not_allowed` (primary allowlist) |
| `having`, `distinct`, `search`, ordering | do not exist (F5) | n/a | inert (extra body keys never copied) |
| any future key added to the builder but not the registry | `:request_clause_unwalked` | n/a | 403 same detail |

Refusal shape: status 403 and detail `"one or more requested fields are restricted for this caller"`, no field
name, entity type or clause in body or logs (T-15, T-38 pin this for all routes; extend T-15 to a join case).
Unknown vs restricted: unchanged from the aggregate behaviour (PR 1 section 4 decision): a restricted name is 403
(the guard runs first), an unknown or not-queryable name is 422 echoing the caller's own string via
`render_query_error/2`'s `{:field_not_allowed, field}` clause. No change; the statement in #2697 "answer
identically where the caller has no right to know the field exists" is matched against aggregate-today as
instructed (documented in the PR 1 design section 4; REPORT in PR: aggregate distinguishes the two, as before).

Ordering (preserved and pinned): body parse (400) -> guard (join_relations errors, or 403) -> compile (422 field/
type errors, 404 type). Behaviour change in ordering only for requests that combine two errors: a request with
BOTH a restricted field AND an invalid join (`too_many_joins`, `duplicate_join_target`, `no_through_relation`,
nonexistent join target) now returns the join error (4xx via `render_query_error/2`) instead of 403, because
`join_relations/3` runs inside the walk before restriction comparison. This leaks nothing about grants (join
errors are functions of definitions, not of the caller's grants); it matches PR 1's row routes. Recorded as a
known, accepted reorder (R2). A request with a restricted field and an invalid aggregate target (e.g. `sum`
over a text field) still returns 403 first, as today.

## 4. Data model

No tables, columns, indexes, migrations or constraints change. No new modules. No gen_statem. Reads only the
existing `entity_field_restrictions`/`user_entity_grants` (through `FieldGrants.load_restrictions/3` inside
`FieldPolicy.restriction_set/2`) and entity definitions (through `Compiler.join_relations/3`).

## 5. Cross-module dependencies

`Letflow.Routers.Entities` -> `Letflow.Entities.FieldPolicy.check_request/4` (already aliased from PR 1) ->
`Letflow.Entities.Query.RequestGuard.field_refs/3` -> `Letflow.Entities.Query.Compiler.join_relations/3`.
After this PR the router has ZERO direct `FieldGrants.load_restrictions/3` calls (it still calls
`FieldGrants.redact_page/2`/`redact_joined_page/2` for row-route response shaping, unchanged). Moduledoc edits
(docs only): route table row for `query_aggregate` (line ~64) names `FieldPolicy.check_request/4` instead of the
raw `load_restrictions/3`; the section comment above `handle_query_aggregate/1` and the `Compiler.compile_aggregate`
doc paragraph ("The caller is responsible for the section 4 INV-2 field-restriction check ... against
`load_restrictions/3`") are reworded to name `FieldPolicy.check_request/4` with kind `:aggregate`.

## 6. Invariants

- INV-2: no restricted field, as a position or as a join fk, is reachable on the aggregate route for a caller
  without a grant for it; counted presence (the F2 oracle) is closed.
- INV-1: principal built from `auth_context`/resolved prefix only; body keys `tenant_id`/`schema`/`prefix`/
  `user_id` stay inert (existing INV-1 aggregate test stays green).
- INV-5: nonexistent and cross-tenant primary types answer a byte-identical 404, with or without a join (F7).
- Fail closed: an unwalked clause or a reference with no loaded set is refused (walker property, unchanged).
- Walker-before-compiler: no SQL for an aggregate request is built or run before the guard returns `{:ok, _}`.
- Single owner within the router: `lib/letflow/routers/entities.ex` has ZERO direct `FieldGrants.load_restrictions/3`
  callers after this PR (T-39 widened, scoped to that file). Other callers exist and are out of scope: the
  write-path field checks in `handler_writes.ex` (~270) and `step_writes.ex` (~795).

## 7. Acceptance criteria -> design elements

| # | Criterion | Element |
|---|---|---|
| AC-1 | restricted fk / through / on field in an aggregate join -> same 403 as a restricted filter field | section 2 step 2, section 3 rows join fk/through; tests A-1..A-3 |
| AC-2 | permitted fk join still succeeds | A-4 |
| AC-3 | measure, group_by, filter still refused (no regression) | A-5 and the existing ISS-0647 aggregate tests |
| AC-4 | joined entity's fields checked against that entity's own restrictions | section 3 (hops governed by `owner_entity_type`); A-6 (far-side), A-7 (not expressible: 422) |
| AC-5 | same 403 detail string; no field name in body | F8; A-14 (T-15 extension) |
| AC-6 | unknown field stays 422 echoing the caller's string | section 3 "Unknown vs restricted"; A-10 |
| AC-7 | nonexistent primary + join stays 404 (not 422); no-join nonexistent stays 404 | F7; A-8 |
| AC-8 | TypeAccess ordering unchanged (aggregate has no TypeAccess step) | F9 (documented only; A-11 dropped, Q2 closed) |
| AC-9 | `check_aggregate_field_restrictions/2`, `aggregate_request_field_names/1`, `{:aggregate_field_restricted, _}` removed | section 2; A-12 grep |
| AC-10 | T-39 allow-list removed; no direct load_restrictions in routers/entities.ex | section 6; A-12 |
| AC-11 | aggregate builder keys equal registry for a maximal body | A-13 (existing T-26 test stays, extended with a join in the body) |
| AC-12 | presence oracle closed | A-9 | presence oracle. Fixture: N primary rows with a NULLABLE restricted fk, K of them non-null (0 < K < N); and a `through` join where ONLY the far hop is restricted. Both requests use `count` | both 403 with no number anywhere in the response; the unjoined `count` on the same type still returns N (unaffected) |
| AC-13 | `having`/other keys: do not exist, inert | F5; A-13/T-14 existing |
| AC-14 | no redaction reuse needed (aggregate returns no restricted values) | F4; A-15 asserts the response carries only group/value keys |

## 8. Tests

All in existing files; new tests extend `test/letflow/routers/entities_query_restricted_walker_test.exs`
(reuses its `exam_ctx!/3`, `aggregate/2`, `@fk_join`, `assert_refused/2`, `traced_request/…` helpers). Fixture:
the existing walker-test setup with a restricted fk field on a primary type (the PR 1 fk-join tests already
restrict `answer_option.question_id`-style fks; reuse that tenant seeding, no new fixture module).

| ID | Test | Expected |
|---|---|---|
| A-1 | aggregate `count` with `join` on a RESTRICTED direct fk (declared on the primary) | 403, same status/type/title/detail as a restricted filter |
| A-2 | restricted fk declared on the JOINED entity (reverse direction; hop owner = joined type) | 403 |
| A-3 | `through` join where the near hop's fk is restricted; separate case where only the far hop's fk is restricted | 403 each |
| A-4 | permitted-twin: same shapes with the fk unrestricted (or the caller holds a `user_entity_grants` row) | 200 with the expected count |
| A-5 | PR 1 controls: restricted measure (`sum` on restricted), group_by, filter; `count` + unrestricted group_by | 403 / 403 / 403 / 200 |
| A-6 | owner governs, near and far hops. Fixture (four entity types created in the test tenant): primary `P` with a plain text field `p_ref`; `J` declares fk `p_ref` -> `P` (hop owner = `J`); `T` declares fk `p_id` -> `P` and fk `f_id` -> `F`; `F` has a text field `f_id`. Variants, each `count` with the stated join: (a) restriction on `J.p_ref` only, `join [{J, fk: p_ref}]` -> 403; (b) restriction on `P.p_ref` only (same name, other side), same join -> 200 (hop governed by owner `J`, not the primary), while a FILTER on `P.p_ref` -> 403; (c) restriction on `T.f_id` only, `join [{F, through: T}]` -> 403 (far hop); (d) restriction on `F.f_id` only (same name on the non-owner), same join -> 200; (e) restriction on `T.p_id` only, same join -> 403 (near hop) | as listed |
| A-7 | a filter/group_by naming a field that exists only on the joined entity | 422 `field is not queryable: "<caller string>"` (primary allowlist), never evaluated against the joined entity |
| A-8 | nonexistent primary type with (a) no join, (b) a direct join, (c) a `through` join; plus (d) a cross-tenant primary, same trace id on all | 404 each, and the FULL response bodies (not only status) byte-identical across (a)-(d) and to the existing INV-5 body; never 422 |
| A-9 | presence oracle: tenant with N primary rows where K have the restricted fk set; `count` + restricted-fk join | 403 and no number anywhere in the response; unjoined `count` still returns N (existence of the route unaffected) |
| A-10 | unknown field `nope` in filter / group_by / measure with and without join | 422 echoing the string (documents unchanged behaviour) |
| A-10b | parse order (concrete, kills M7): (i) a malformed `aggregates` element (`{"fn":"bogus"}`), (ii) a malformed `group_by` element (`{"nofield":1}`), (iii) a malformed `join` element (`{"entity_type":1}`), each TOGETHER WITH a restricted filter field; (iv) a non-object body (a JSON array) | 400 for (i)-(iii) (parse error, not 403); 400 for (iv) ("request body must be a JSON object") |
| A-11 | DROPPED. The aggregate path has no TypeAccess step (F9), so a type-denied caller gets exactly what any caller holding the aggregate permission gets (200 for permitted fields); documented in F9 and owned by #2700, not asserted by a new test (it would pin the defect #2700 intends to fix). Numbering kept so references stay stable | n/a |
| A-12 | T-39 rewritten, scoped to the single file `lib/letflow/routers/entities.ex`, CODE LINES ONLY (comment lines stripped as the existing `function_code/2` and code-line helpers do; comment wording is not asserted): zero `FieldGrants.load_restrictions(`; `run_query_aggregate` source contains `FieldPolicy.check_request`, `exempt?: false`, binds the guard result as `{:ok, _}`, and has no catch-all `else` clause turning an error into success (only `{:error, reason} -> render_aggregate_error(conn, reason)`); the file's code lines contain none of `check_aggregate_field_restrictions`, `aggregate_request_field_names`, `aggregate_field_restricted` | pass (replaces the "ONLY remaining direct caller" test) |
| A-13 | T-26 aggregate: body with ALL keys including a `join` and extra unlisted keys (`having`, `distinct`, `search`, `unredacted`): observed request map keys (via the existing `traced_request`) equal `RequestGuard.registry_keys(:aggregate)`; status equals the same body without the extras | pass |
| A-14 | T-15 extension: aggregate with a restricted join fk compared field by field with filter/sort/join `on`/export refusals | equal status/type/title/detail; body contains neither the fk name nor the entity type |
| A-15 | aggregate response contains only `values` and optional `group` envelopes, no `:__field_redacted__` sentinel anywhere, for an exam type with restricted fields | pass; documents F4 |
| A-16 | rename the "aggregate route keeps its own check in PR 1" describe to "aggregate route uses the shared walker (PR 2)" and keep its assertions | pass |
| A-17 | all PR 1 row-route tests (T-1..T-40 of the walker test file), `entities_aggregate_test.exs`, `entities_answer_key_field_leak_test.exs`, `exam_snapshot_leak_test.exs`, `query_request_guard_test.exs` | unchanged and green |

## 9. Mutants the suite must kill (>= 5; each is a plausible implementation slip)

M1. Omit the guard call from `run_query_aggregate/4` (or place it after `run_aggregate`): killed by A-1/A-9
(count returned instead of 403) and A-12.
M2. Keep the old `check_aggregate_field_restrictions` and add the guard only for `join`: killed by A-12
(forbidden symbol) and nothing else; therefore A-12 is mandatory.
M3. Pass `exempt?: true` or an unlisted variable: killed by A-12's `exempt?: false` assertion and the T-39
exempt? line test.
M4. Evaluate hops against the PRIMARY set instead of the declaring entity's set (replace `owner_entity_type`
tag): killed by A-2 and A-6 (restriction on the joined entity's fk only).
M5. Check only the near hop of a `through` join: killed by A-3 (far-hop-only case).
M6. Run the guard but ignore `{:error, :request_clause_unwalked}` (treat as ok) or map it to 422: killed ONLY by the
existing unit tests T-27/T-14 (the guard refuses unwalked keys) plus the A-12 source assertion on the `with` clause
(guard result bound as `{:ok, _}`, no catch-all converting an error to success). A router-level HTTP test is not
possible: the builder emits only registry keys, so `:request_clause_unwalked` is unreachable over HTTP.
M7. Guard before parse so a malformed body becomes 403: killed by A-10b (no 400 assertion exists for the aggregate route today, so A-10b is new).
M8. Let a nonexistent primary with a join surface `no_through_relation` 422 (drop `ensure_primary_exists`
precedence): killed by A-8(c).
M9. Fold the refusal into a different detail string or add the field name to it: killed by A-14 and T-15.
M10. Restore a redaction step that rewrites aggregate values: killed by A-15 (no sentinel) and the exact
response shape tests in `entities_aggregate_test.exs`.

## 10. PR size and shape

One PR, "Closes #2699" and the closing PR for #2697 only if #2697's other conditions are met (the #2697 thread
says do not close #2697 until #2699 lands; PR 2 body states "Closes #2699, completes #2697" and the
orchestrator closes #2697 after merge). Estimated: ~30 lines of router change (replace the `with` steps, delete
two functions and one render clause, comment/moduledoc rewording about +/-40), ~12 lines of Compiler/moduledoc
comment rewording (docs only), tests ~220 lines. Total roughly 250-350 changed lines, under PR 1's 400
estimate. One commit; no migration; no frontend; no `web/`.

## 11. Gates and the #2612 rule

- Required: SECURITY-REVIEWER (tenant-data-path, INV-2/INV-5), REVIEWER, TEST-DESIGNER/VALIDATOR,
  RELEASE-VALIDATOR as the workflow defines. Run the CI-shaped local checks before push.
- #2612 (permission-matrix trust boundary, REQ-498): NOT triggered. The change touches none of `ci.yml`,
  `cd.yml`, `scripts/ci_changed_paths.sh`, `scripts/cd_qa_decide.sh`, `mix.exs`, `config :letflow, :modules`,
  `lib/mix/tasks/letflow.permission_matrix.ex`, `lib/letflow/api/permission_matrix.ex`,
  `lib/letflow/api/authorization.ex`, `lib/letflow/modules/catalog.ex` or `priv/permission_matrix/`. It adds no
  permission atom and no role grant. If implementation finds it must edit any of those, the rule triggers and
  SEC review must be re-run.
- PR body must list: (1) #2700 stays open (type access on the aggregate route and its join targets); (2) the accepted 403/422 split (restricted 403, unknown 422 echoing the string); (3) the join-error-before-403 reorder; (4) Q2 resolved by dropping A-11; and must also state: past exposure (a restricted `queried: true` fk on a primary type allowed a presence count
  through the aggregate join to every `EntitiesAggregate` holder; audit records mutations only so past reads
  cannot be established), and that #2700 (TypeAccess on join targets / export / aggregate) remains open.

## 12. Risks

R1. Behaviour change (intended): aggregate callers that join on a restricted fk now get 403 instead of 200.
Legitimate dashboards joining on a restricted fk break; the fix is a `user_entity_grants` row for the field,
not an exemption. In shipped code only the Exam module restricts fields (`is_correct` and snapshot fields); no
shipped aggregate query joins on a restricted fk (implementer to grep `lib/`, `web/src`, `test/fixtures` for
`query/aggregate` callers with `join`, and record the result in the PR).
R2. Error-ordering reorder (section 3): restricted-field + invalid-join now yields the join error first. No
grant information leaks; accepted, matches the row routes.
R3. `Compiler.join_relations/3` does definition reads (`Allowlist.fk_defs`, relation resolution) that
`compile_aggregate/2` repeats: one extra read per join request (PR 1 accepted the same cost for /query).
R4. Cannot lose coverage on a future aggregate key: the registry fails the request closed with 403 and the
T-26 typespec tripwire fails CI; no new risk.
R5. `restriction_entity_types/2` loads a set for every join target even though aggregate redacts nothing: up to
4 extra tiny queries per join request. Accepted for a single code path; an optimisation would need a walker/
policy signature change, deliberately out of scope.
R6. Stale comment sites to reword (docs only; none is asserted by A-12): router moduledoc route row (~line 64); INV-2 block comment above `handle_query_aggregate/1` (~2178-2185); comment above the two helpers (~2212-2218, deleted with them); `render_aggregate_error/2` comment (~2330-2337); `lib/letflow/entities/query/compiler.ex` `compile_aggregate/2` doc (~713); doc comment at line 6 of `test/letflow/routers/entities_query_restricted_filter_test.exs`. The walker-test describe "aggregate route keeps its own check in PR 1" is renamed (A-16).
R6b. Docs drift: three comment blocks and the moduledoc route row name `load_restrictions/3`; they must be
updated or the existing moduledoc test ("the route table names POST /entities/query/aggregate and
:EntitiesAggregate") stays green while text lies. Implementer greps `load_restrictions` in `lib/letflow/routers/`
to confirm no stale mention.

## 13. Open questions (each has a design default; none is a silent assumption)

Q1. Should the aggregate route get a TypeAccess step here? Default NO (F9, #2700 owns it); adding it would
change aggregate behaviour for denied types (status/shape not decided by any requirement).
Q2. CLOSED: A-11 is dropped (F9 documents that a type-denied caller is treated like any other aggregate caller); nothing is pinned and no observation of main is needed. #2700 owns the behaviour.
Q3. Is the unknown-vs-restricted distinction on the aggregate route acceptable under #2697's "answer
identically" wording? Default: yes, matches aggregate-today (instructed); the PR reports it. Alternative
(collapse unknown to 403 when the type has any restriction) would change T-16 on all routes and is a separate
decision.
Q4. CLOSED: the #2699 issue body was read. Its ACs (join fk/through/on restricted -> same 403 and permitted
twin succeeds; #2697 controls green and /query + export joins unchanged; SECURITY-REVIEWER and REVIEWER verdicts
and scoped tests, warnings-as-errors compile and format check quoted; #2697 not closed before this lands) map to
AC-1, AC-2, A-17 and section 11. The body's "every field of the joined entities' filters ... against that
joined entity's own restrictions" cannot be expressed on the aggregate route (F3); the design satisfies it
vacuously and pins that with A-7. SECURITY-REVIEWER should confirm that reading.
