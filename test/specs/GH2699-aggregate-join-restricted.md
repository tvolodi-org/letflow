# GH #2699 test spec: aggregate route uses the shared restricted-field walker (join clause closed)

Design: `lib/letflow/design/gh2699-aggregate-join-restricted.md` (tests A-1..A-17, mutants M1..M10).
Status of execution at authoring time: NOT RUN locally (free memory 1.9 GB < 4 GB gate); hosted CI runs them.

New file: `test/letflow/routers/entities_aggregate_restricted_join_test.exs` (EntRJ).
Changed files: `test/letflow/routers/entities_query_restricted_walker_test.exs` (W),
`test/letflow/routers/entities_query_restricted_filter_test.exs` (doc comment only).

## Acceptance criterion -> test

| AC / design id | Test | Why it exists |
|---|---|---|
| AC-1, A-1, AC-12/A-9 | EntRJ "A-1/A-9 direct fk declared on the PRIMARY, nullable fk ..." | Fixture: 3 answer_options, 1 with NULL fk. Asserts 403 with no `count_none` in the body, body byte-equal to a restricted FILTER refusal, and the permitted twin returns 2 while the unjoined count is 3 (proves the oracle was real: joined count != N). |
| A-2 | EntRJ "A-2 fk declared on the JOINED entity ..." | Hop owner is the joined entity; also unrelated-field restriction -> 200, and a `user_entity_grants` row -> 200. Kills M4 (primary-set evaluation). |
| A-3 near | EntRJ "A-3 through join, NEAR hop restricted" | Near hop of a through join. |
| A-3 far, A-9 | EntRJ "A-3/A-9 ... ONLY the FAR hop restricted" | Kills M5 (near-hop-only); twin 1 vs unjoined 2. |
| AC-2, A-4 | EntRJ "A-4 permitted keys ..." | Permitted fk joins still succeed (direct, reverse, through). |
| AC-3, A-5 | EntRJ "A-5 ..." plus existing `entities_aggregate_test.exs` INV-2 and W "aggregate route uses the shared walker (PR 2)" | No regression for measure / group_by / filter. |
| AC-4, A-6 (a)-(e) | EntRJ "A-6 each hop is governed by the entity that declares the fk" | Four-type fixture; same-named fields on both sides prove owner (not primary / not far-side) governs. |
| A-7 | EntRJ "A-7 ..." | Joined-only field names are 422 `field is not queryable: "text"`, never evaluated on the joined entity. |
| AC-6, A-10 | EntRJ "A-10 ..." | Unknown field in filter/group_by/measure, with and without join: 422 echoing the string. |
| AC-7, A-8 | EntRJ "A-8 nonexistent primary ..." | Full-response (status, body, headers) equality of 404 across: no join, direct join, through join, cross-tenant primary (plain and joined), and restricted filter + through join; restrictions on every hop present. Kills M8. |
| R2 | EntRJ "ordering: restricted field TOGETHER WITH an invalid join" | Join error equals the invalid-join-alone response (not 403); documents the accepted reorder. |
| A-10b | EntRJ "A-10b ..." | Malformed aggregates / group_by / join element plus a restricted filter -> 400; well-formed control -> 403; JSON array body -> 400 "request body must be a JSON object". Kills M7. |
| AC-5, A-14 | EntRJ "A-14 ..." | Aggregate join refusals (both directions) equal /query filter, /query join, export join refusals field by field; body leaks neither `question_id`, `question_fk` nor `answer_option`. Kills M9. |
| AC-14, A-15 | EntRJ "A-15 ..." | Aggregate response only `group`/`values`, no redaction sentinel, no `is_correct`. Kills M10. |
| AC-9, AC-10, A-12 | W "GH #2699 A-12: routers/entities.ex has ZERO direct load_restrictions calls ..." (rewritten T-39 test) | Code-line source assertions: 0 `FieldGrants.load_restrictions(`; deleted names absent; `run_query_aggregate` contains `FieldPolicy.check_request`, `:aggregate`, `exempt?: false`, binds `{:ok, _x} <-`, only `{:error, reason} ->` else, guard precedes compile. Kills M2, M3, M6. |
| AC-11, A-13 | W "the aggregate builder emits exactly the :aggregate registry for a maximal body" (extended: join + having/distinct/search/unredacted; bare-body status equal) | Registry equality and inertness of unlisted keys. |
| A-16 | W describe renamed to "aggregate route uses the shared walker (PR 2)" | Naming only; assertions kept. |
| A-17 | existing T-1..T-40 in W, `entities_aggregate_test.exs`, `entities_answer_key_field_leak_test.exs`, `exam_snapshot_leak_test.exs`, `query_request_guard_test.exs` | Unchanged; must stay green. |
| REQ-511 validator | EntRJ "no generic GET /records/:entity_type/:record_id" (2 tests) | Route inventory via `__authz_routes__/0` has no GET for exactly that path (message demands a redaction + probe test); HTTP probe as TASK_WORKER/TENANT_AUDITOR/TENANT_ADMIN: GET records/session/<id> and records/answer_option/<id> give the same status+body as a random uuid, status in 403/404/405 (the catch-all `authz_unmatched(:ordinary)` answers 403 to non-platform callers), no field value in the body. |
| A-11 | dropped by design (no TypeAccess step on aggregate; #2700) | n/a |
| R6 | `entities_query_restricted_filter_test.exs` moduledoc no longer names the deleted function | docs only |

## Mutants for TEST-DESIGN-VALIDATOR

| Mutant | Edit in `run_query_aggregate/4` (lib/letflow/routers/entities.ex) | Expected killers |
|---|---|---|
| M1 | remove the `FieldPolicy.check_request` step | EntRJ A-1/A-9, A-2, A-3, A-6 (count returned, not 403); W A-12 |
| M3 | `exempt?: true` | W A-12 (`exempt?: false`), W exempt-lines test |
| M6 | bind `{:ok, _}` replaced by a catch-all that continues on error | W A-12 (regex and `else` assertions) |
| M4/M5 | not router-level (walker / RequestGuard hop owner); apply in `RequestGuard.join_refs` | EntRJ A-2, A-6 (owner), A-3 far |
| M7 | run guard before parse | EntRJ A-10b |
| M8 | drop precedence of primary existence for joins (in `Compiler.join_relations/3`) | EntRJ A-8 |
| M9 | add field name to the 403 detail | EntRJ A-14, assert_refused leaks, W T-15 |
| M10 | restore redaction on aggregate values | EntRJ A-15 |

Mutant measurements: none were applied (no local mix run permitted, memory gate). Counts to be measured by TEST-DESIGN-VALIDATOR / CI.
