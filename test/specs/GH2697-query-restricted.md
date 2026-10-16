# Test Spec: GH2697 -- restricted-field request walker (PR 1: /query, join query, export)

**Requirement:** GH #2697 (+ advisor scope comment), design `lib/letflow/design/gh2697-restricted-field-request-walker.md`
(CDV PASS r4), SECURITY-REVIEWER design R1-R6 and code-gate B1. Aggregate (PR 2, #2699) is out of scope; its own check is
only pinned as "unchanged" here.
**Test tier:** unit + integration (real HTTP via `Letflow.Router`, real Postgres)

Files:
- `test/letflow/routers/entities_query_restricted_filter_test.exs` -- the 11-test reproduction (6 failed on main; all pass now).
- `test/letflow/routers/entities_query_restricted_walker_test.exs` -- HTTP-level per-clause, join, exemption, type-hidden, registry, perf, architecture tests (ids "W:" below).
- `test/letflow/entities/query_request_guard_test.exs` -- unit tests of `RequestGuard`, `Compiler.join_relations/3`, `FieldPolicy` (ids "U:" below).

## Acceptance criterion -> test map

| AC / design id | What it proves | Test |
|---|---|---|
| T-01..T-06 filter/sort restricted -> 403 on query, join, export | the leak is closed | filter file (2), (3), (4a), (4b), (5a), (5b) |
| controls (aggregate 403, no filter 200, grant 200, unrestricted field 200) | no over-blocking | filter file (1), (1b), (6) x2, (4) CONTROL |
| T-07 filter restricted/permitted twin | per-clause | W: "T-07 ..." |
| T-08 sort restricted/permitted twin | per-clause | W: "T-08 ...", multi-clause test |
| T-09/T-10 export default mode filter + sort | export clause coverage | W: "T-09/T-10 ..." |
| T-11 join `on`, declaring = primary | fk governed by primary's own set | W: "T-11 ..." |
| T-12 join `on`, declaring = join target (restriction NOT on the primary) | declaring entity's set, not the primary's | W: "T-12 ...", "T-12b ..." |
| T-13 join `on`, declaring = through entity, near and far hop | both hops walked | W: "T-13 near", "T-13 far", twin |
| export + join `on` | exporter also checks fk | W: "export with a join refuses ..." |
| T-14 unlisted body keys inert | builders whitelist; no 500 | W: "T-14 ...", "T-18a ..." |
| T-15 uniform 403 | status/type/title/detail equal across filter, sort, join on, export, aggregate; no field/entity name in body | W: "T-15 ..." and `assert_refused/2` in every refusal |
| T-16 unknown field stays 422 | restricted-vs-unknown decision (Q1) | W: "an unknown field ...", "T-16 ..." |
| T-19..T-21 likert_weight / likert_polarity / question.explanation filter+sort | restricted name wins over "not queryable" (was 422) | W: "T-19..21 ..." x3 |
| T-21b same, queried:true flipped | live-leak variant; grant makes the same request 200 (proves definition queryable) | W: "T-21b ..." x3 |
| T-22 row order | sort clause is real (C,B,A / A,B,C) and the restricted sort yields no rows | W: "T-22 ..." |
| T-23/T-35 granted caller filters/sorts (query + export) | grant respected | W: "T-35/T-23 ..." |
| T-36 other user's grant | grant is per user | W: "T-36 ..." , "T-12b ...", U: "restriction_set/2 honours ..." |
| T-24 type-denied + restricted filter/sort | byte-equal to unrestricted filter response | W: "T-24 ..." |
| T-25 cursor keys | resume with restricted sort -> 403 (also garbage cursor); permitted resend 200 | W: "T-25 ..." x2 |
| T-34a nonexistent primary with join / restricted-looking filter | same hidden 200 envelope as plain nonexistent | W: "T-34a ..." |
| T-34b type-denied + direct join | hidden 200 | W: "T-34b ..." |
| B1 nonexistent primary + THROUGH join (through entity exists) | query: == type-denied == plain nonexistent; export: == plain nonexistent (404) | W: "B1 ..." x2, U: ":entity_type_not_found" through test |
| T-17 unredacted export exemption | 200, rows, ONE audit entry, names only (keys exactly filter_fields/sort_fields/restricted_fields_used), no value in audit or info-level log | W: "T-17 ..." |
| T-37 exemption with join | audit names include the join fk; no values | W: "T-37 ..." |
| T-18a `/query` with `unredacted:true` | exemption export-only | W: "T-18a ..." |
| T-18b export without flag | exemption needs the flag | W: "T-18b ..." |
| T-18c caller without the unredacted permission | 403, no records, no audit | W: "T-18c ..." (note: TASK_WORKER also lacks base export, so the refusal may come from the route permission; only TENANT_ADMIN/PLATFORM_ADMIN hold both atoms, so a "has export, lacks unredacted" role cannot be constructed from stock roles; the permission-order itself is pinned by `entities_export_test.exs` "escalated mode") |
| T-32 audit failure | detail-free 500, no `records`, no field name | W: "T-32 ..." (audit_entries renamed in the test's sandboxed schema) |
| T-33 no audit for non-exempt export | default mode and unredacted with unrestricted fields write none; refused export and compile-422 write none (R3 ordering) | W: "T-33 ...", "a refused export ..." |
| T-38 / R4 logs | 403 paths log no field name or filter value | W: "T-38 ..." |
| T-26 registry == typespec keys | tripwire both directions, both kinds | U: "registry (T-26)" x4 |
| T-26 (R6) registry == builders' emitted key set | observed by tracing `Compiler.compile/2` / `run_aggregate/2` arguments from maximal bodies through HTTP | W: "T-26 ..." x2 |
| T-27 unlisted key -> `:request_clause_unwalked` | fail closed | U: "T-27 ..." |
| T-28 ref with no loaded set -> restricted | fail closed | U: "T-28 ..." |
| T-30 restriction loads | plain = 1, one-target join = 2 (redact does not reload) | W: "T-30 ..." |
| T-31 far-side redaction | sentinel per entity; grant shows value; keyed per entity | W: "T-31 ..." x4 |
| T-39 router architecture | no direct `load_restrictions` in run_query/run_export/redact/guard_row_request/export_redact; aggregate the single allow-listed remaining caller; only run_export passes a non-literal `exempt?` | W: "T-39 ..." x3 |
| T-40 FieldPolicy | redact_with_sets (pure, explicit sets, missing set raises), restriction_set own vs other grant, redact/3, check/redact agree, load_sets, exempt? required | U: "T-40 FieldPolicy" |
| `Compiler.join_relations/3` | hop order/ownership direct+through, errors, shape-first, empty | U: "Compiler.join_relations/3" |
| aggregate untouched | still 403 on restricted group_by/filter, permitted 200 | W: "aggregate route keeps its own check in PR 1" |

## Mutants (to be re-applied by TEST-DESIGN-VALIDATOR; NOT run by TEST-DESIGNER because the brief forbids editing lib/)

| M | Mutation | Expected killers |
|---|---|---|
| M1 | drop the `sort` walk in `RequestGuard.field_refs/3` | W: T-08, T-22, T-25, T-10; filter file (3), (4b), (5b); U: field_refs row test |
| M2 | skip the `filters` walk (or make the export call site not call `check_request/4`) | W: T-07, T-09/T-10, T-23/T-36; filter file (2), (4a), (5a) |
| M3 | skip `join_on` refs, or govern them by the PRIMARY's set | W: T-11, T-12, T-12b, T-13 x2, export+join; U: join_relations/field_refs/check_request join tests |
| M4 | exemption keyed on route permission only (pass `exempt?: true` without checking the flag / `unredacted?`) | W: T-18b, T-18c |
| M5 | exemption honoured on `/query` (pass `exempt?: true` in `guard_row_request`) | W: T-18a, T-39 architecture test |
| M6 | unlisted key ignored in `field_refs/3`, or `restricted_refs/2` passes a ref with no loaded set | U: T-27, T-28; W: T-26 |
| M7 | `FieldPolicy.redact*` and `check_request` use different sets (e.g. one ignores grants) | U: T-40 "agree on membership", "honours the caller's own grant" |
| M8 | audit written before compile / for non-exempt exports / with values | W: T-33, "a refused export ... no audit", T-17 (names only) |
| M9 | `redact` reloads sets via `load_restrictions` | W: T-30, T-39 |
| M10 | `guard_row_request` does not skip a type-denied caller (denied type returns 403) | W: T-24, T-34b, B1 |
| M11 | `join_relations/3` errors surface for a nonexistent primary (B1 regression) | W: B1 x2; U: nonexistent primary with a through join |

## Coverage check

- [x] Every acceptance criterion above has >= 1 test case listed
- [x] Closed-registry / fail-closed behaviour is covered by example + typespec tripwire (no state machine; no property test needed)
- [ ] Pre-fix failure of the 6 reproduction tests on main: recorded by the reproduction file's header (6 failed on main); the new walker tests assume the guard exists.

## Note on an adjusted existing test

`test/letflow/routers/entities_test.exs` "REQ-311 AC3 ... never the through type" restricted `topic_labels.topic_id` (a through-hop fk). Under the walker that is a join `on` reference and is refused with 403 (T-13). The test now restricts a new non-fk field `note` on the through entity; its intent (restriction row on the through type must not break response redaction keys) is unchanged.
