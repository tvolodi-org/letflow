# BilimBaga analytics reports mapped to the aggregate API (study T6d)

**Written:** 2026-10-26. Written finding only; it feeds the T6c requirement (retirement criterion 6, task T6d in
`bilimbaga-retirement-status.md`). No product code, test or requirement file is changed.
**Source:** `c:\Users\tvolo\dev\ai-dala\BilimBaga\` local checkout on `main` at `445216d` (not fetched; it may be
behind `origin/main`). Letflow side read at this worktree's base (`main`).

## 1. Files read

BilimBaga: `backend/internal/reports/{handler,model,service,repository,pdf}.go`;
`backend/internal/router/router.go` (the report routes, lines ~300-355); `backend/internal/deptscope/scope.go`
(and its tests); `backend/migrations/005_rbac.up.sql` (the `reports:read` grant); `frontend/src/pages/admin/`
(`ReportsPage.tsx`, `AdminDashboardPage.tsx`, `ExamAnalyticsPage.tsx`, `EmployeeRecordPage.tsx`);
`frontend/src/App.tsx` (routes of those pages).

Letflow: `lib/letflow/entities/query/compiler.ex` (`run_aggregate`, `compile_aggregate`,
`resolve_group_by_specs`, `build_aggregate_spec`, `check_aggregate_field_type`);
`lib/letflow/entities/query/types.ex` (`filter_op`, `join_clause`); `lib/letflow/entities/query/allowlist.ex`
(the `queried: true` rule); `lib/letflow/routers/entities.ex` (`handle_query_aggregate`,
`build_aggregate_request`); `lib/letflow/modules/exam/exam.ex` (`@answer_key_fields`);
`priv/modules/exam/entity_definitions/{session,session_question_score,session_answer,exam}.json`.

## 2. What the aggregate API can compute

`POST /entities/query/aggregate` takes `entity_type`, `aggregates`, `group_by`, `filters`, `join`.

- Functions: `count` (no field), `sum`/`avg` (integer or decimal fields), `min`/`max` (string, integer, decimal,
  date, datetime). Nothing else: no median or percentile, no count-distinct, no expressions (no `CASE`, no
  difference of two fields, no ratio), no `HAVING`, no sort, no limit on the result.
- Filters: `eq neq gt gte lt lte in not_in contains starts_with is_null is_not_null`, AND-combined.
- `group_by` takes plain fields. Every aggregate target, group-by field and filter field resolves against the
  **primary entity only** (the `join` doc in `types.ex`: a join "does not let a caller filter/sort on a joined
  entity's own fields"; `resolve_group_by_specs` loads one allowlist). So a report cannot group `session` rows by
  a field of `exam` or of a user.
- **Only fields with `queried: true` are usable** in an aggregate, group-by or filter (`allowlist.ex`: "only fields
  with `queried: true` are ever" in the allowlist). Today on the exam module:

  | Entity | `queried: true` | `queried: false` (not usable) |
  |---|---|---|
  | `session` | `exam_id`, `user_id`, `status`, `expires_at` | `score_pct`, `passed`, `submitted_at`, `started_at`, `seed`, `exam_snapshot` |
  | `session_question_score` | `session_id`, `question_id`, `grading_status` | `score`, `max_score` |
  | `session_answer` | `session_id`, `question_id` | `selected_option_ids`, `text_answer`, `saved_at`, `time_spent_seconds` |

  This is the main finding: **no score, pass flag or time can be aggregated today**, whatever the function. Only
  counts per `exam_id`/`user_id`/`status`/`grading_status` work. Promoting a field to `queried: true` adds a
  promoted column (ISS-0648 column promotion on activation), so it is a definition change with a migration path
  for existing tenants, which T6c must state.
- Access: the route is `scope: :filter` and the type gate plus restricted-field walker (`RequestAccess.check/4`,
  kind `:aggregate`) run first. A single restricted field anywhere in the request (for example
  `session.exam_snapshot`) rejects the whole request with 403. Reports do not need the snapshot, so this is not an
  obstacle, but it means a report must never group by or filter on it. Scope sets (REQ-518) apply per entity type:
  an undeclared type gives an empty result, not an error. I did not verify which scope declaration `session`
  carries; T6c must check it (see the access rule below).
- Data model gaps outside the API: the exam pack has no department entity, no assignment entity and no user
  attribute "department" (retirement status doc, criteria 1 and 5). Anything per department or per assignment
  depends on that work.

## 3. The BilimBaga reports

BilimBaga has no separate "report" module beyond `internal/reports`. Seven read endpoints, one PDF, two CSVs,
two AI summaries. Access for all of them: permission `reports:read` (`router.go`; seeded in `005_rbac.up.sql`
for the built-in admin roles, "examiner+"). **Department scope** (`deptscope`, ISS-165/218): every role except
`super_admin` (department admin, examiner, custom roles, an unknown role) sees only users in its own department
subtree; no principal fails closed; an out-of-scope target user or exam answers 404. Only submitted and
auto-submitted sessions count in scores (grading-pending is excluded from averages, included in per-question
selection counts).

| # | Report (endpoint) | Inputs | Filters | Output |
|---|---|---|---|---|
| R1 | Dashboard: completion rate by exam (`GET /admin/dashboard`) | none | active exams only; assignments resolved for user, department subtree, or all active users; department scope | per exam: assigned, completed, passed counts |
| R2 | Dashboard: overdue employees (same call) | none | assignment deadline passed and no passing session | user, exam, deadline |
| R3 | Dashboard: recent activity (same call) | none | sessions submitted, auto-submitted or grading-pending, most recent | employee, exam, score, passed, submitted time |
| R4 | Dashboard: average score by track (same call) | none | submitted/auto-submitted sessions; track from question category | average per compliance track (security, safety, loyalty) |
| R5 | Exam analytics (`GET /admin/exams/{id}/analytics`) | exam id | submitted/auto-submitted; department scope | score histogram (ten buckets of 10 points), pass rate, average, median, attempts, unique participants, per question: correct rate, average time, answer distribution per option |
| R6 | Employee record and progress (`GET /admin/users/{id}/record`, `/progress`) | user id, `page`, `per_page` (max 100) | department scope on the target user | session history with score, pass, time taken, status, certificate; per track: questions answered, last activity, required exams with pass state and attempts |
| R7 | Exam results CSV (`GET /admin/exams/{id}/results/export`) | exam id | submitted/auto-submitted/grading-pending; tenant; row cap `EXPORT_MAX_ROWS` (default 200000, 422 over it); CSV-injection guarded | one row per session: employee, department, start, submit, score, pass, time taken, score per question |
| R8 | Employee record CSV (`GET /admin/users/{id}/record/export`) | user id | all non-in-progress sessions | exam, times, score, pass, time taken, status |
| R9 | Dashboard PDF (`GET /admin/dashboard/export`) | `from`, `to` (date, default last 30 days) | date range | completion rates, five best and five worst questions by correct rate, company name and logo from tenant config |
| R10 | AI insights per exam (`GET /admin/ai/insights/{examId}`) | exam id | same permission | model-written summary of R5 data |
| R11 | AI loyalty narrative (`GET /admin/ai/loyalty-summary/{sessionId}`) | session id | same permission | model-written text for one session |

R10 and R11 are AI features, not analytics queries; they belong to the AI study (T6a/T6b) and are out of scope
for T6c.

## 4. Each report against the aggregate API

"Today" means with the exam pack as it is on `main`.

| # | Computable today? | What is missing |
|---|---|---|
| R1 | **No.** Only a count of sessions per `exam_id` and `status` is possible (`count`, `group_by exam_id`, `filter status`). | "Assigned" needs the assignment model and departments (retirement criteria 1 and 5; absent from the pack). Passed count needs `session.passed` queried. Completion rate is a ratio of two aggregates, so the client divides. Titles come from `exam` (a second call; no join-side group). |
| R2 | **No.** | Assignments with deadlines, departments, and a "no passing session" anti-join; the API has no anti-join or negation across entities. Needs a purpose-built read (or the assignment feature first). Reminder action is a separate feature. |
| R3 | **No** (not an aggregate; a sorted list). | It is a normal query (`/entities/query`) over `session` sorted by submit time; `submitted_at` is not queried so it cannot be sorted or filtered today. Employee and exam names need joins or a second read. |
| R4 | **No.** | Needs `score` queried, a join from score to question to category, and group by a field on the joined entity (not supported). Needs a track attribute on categories and a derived read model. |
| R5 histogram | **No**, then partly. | `score_pct` queried. Buckets need a `CASE`; without it the client issues one `count` per bucket with `gte`/`lt` filters (ten calls) or the API gains a bucket group-by. |
| R5 pass rate, average, attempts | **Partly after one change**: with `passed`, `score_pct` queried: pass rate = `count` where `passed = true` over `count` (two calls, client divides); average = `avg(score_pct)` with `status in (submitted, auto_submitted)`; attempts = `count`. | `queried: true` on `score_pct`, `passed`. |
| R5 median | **No.** | No percentile function. Either add `median`/`percentile` to the API or compute in the client from a row query of `score_pct` (paged; no aggregate needed). |
| R5 unique participants | **No.** | No count-distinct. Workaround: `group_by user_id` and count the rows returned (result size unbounded, no limit). Better: add `count_distinct`. |
| R5 per-question correct rate | **After changes.** `session_question_score` has `question_id`, `score`, `max_score`. Correct rate = share of rows with `score = max_score`, a comparison of two fields. | `score`, `max_score` queried, and a way to filter "score = max_score" (the filter value is a literal; no field-to-field compare). Cheapest: store a `correct` boolean on the score row at grading time, queried, then `count` where `correct = true` grouped by `question_id`. Filtering to one exam needs `session_id in (...)` (the ids of that exam's sessions, fetched first) or an `exam_id` copied onto the score row. |
| R5 per-question average time | **No.** | `session_answer.time_spent_seconds` not queried; `avg` grouped by `question_id` would work once it is, with the same exam-filter problem as above. |
| R5 answer distribution | **No.** | `selected_option_ids` is a JSON array and not queried; counting per option needs unnesting, which the API cannot do. Needs one row per selected option, or a derived read model. |
| R6 history | **Yes as a list, not an aggregate.** `/entities/query` over `session` by `user_id`. Score, pass and `submitted_at` should come back in the row's `field_values` (not verified against the query response shape); sorting or filtering by `submitted_at` needs it queried. | Certificate id (a join on `certificate.session_id`, supported as a join) and the exam title join work through `join`. |
| R6 progress | **No.** | Questions answered per track needs score, question and category joins and group by a joined field; required exams needs assignments. |
| R7 results CSV | **No (not an aggregate).** | An export, not an aggregation: needs a row export path, a row cap, CSV-injection protection, per-question columns. Letflow has no cross-session results list (decision 0031 records this as a recorded gap). Treat as "export" work, separate from the aggregate API. |
| R8 record CSV | **No (export).** | As R7. |
| R9 dashboard PDF | **No.** | Needs R1 and the question ranking, a date-range filter on `submitted_at` (not queried), and PDF rendering with tenant branding. |

Summary: of eleven reports, none is computable today. The shared blockers are, in order: (1) the score fields on
`session` and `session_question_score` are not `queried`; (2) no group-by or filter across a join; (3) no median,
count-distinct, bucket, or field-to-field comparison; (4) no department and no assignment entities.

## 5. Recommended first set of three reports for T6c

Ranked by value to the exam owner, how much of it the aggregate API can do after a small change, and independence
from the unbuilt department and assignment work.

1. **Per-exam summary (R5 without median, participants and answer distribution): attempts, pass rate, average
   score.** Reasons: it is the one report an examiner opens first after an exam; it needs only
   `session.score_pct` and `session.passed` made `queried: true` and then three `aggregate` calls on one entity
   (`count`; `count` with `passed = true`; `avg(score_pct)`, all filtered by `exam_id` and
   `status in (submitted, auto_submitted)`). No department, no join, no new API function.
2. **Score distribution for one exam (R5 histogram).** Reasons: the same fields as report 1, so it adds no new
   data-model change; it is the chart people expect on an analytics screen. It needs one of two small choices that
   T6c must make: ten filtered `count` calls from the client (no API change, ten requests) or a bucket group-by
   in the compiler (one request, an API change with a `compile_aggregate` test).
3. **Per-question difficulty (R5 per-question correct rate).** Reasons: criterion 6 names per-question statistics,
   and `session_question_score` already exists. It needs a `correct` boolean (or `score`/`max_score` queried plus
   a rule for "full marks") and a way to restrict to one exam. Chosen over R1 (completion by exam) because R1
   cannot be done without the assignment model (criterion 1), which is not built; and over R4 (average by track)
   because it needs group-by across a join.

Left for later parts: R1 and R2 (after assignments and departments), R4 and R6 progress (a joined group-by or a
read model), R7 to R9 (export work, one requirement of its own), median and distinct participants (small API
additions, can ride with report 1 as an optional second slice).

## 6. Access rule for T6c (what the requirement must say)

- BilimBaga's rule: `reports:read` for examiner and above, narrowed to the caller's department subtree for every
  role but super admin; out-of-scope target answers not-found. Letflow has no department entity yet, so the
  department narrowing cannot be reproduced; the first set can ship tenant-wide for roles that hold the new
  permission, stated as a known difference.
- A new report read permission is a tenant-scope permission: it moves the permission matrix golden and the
  tenant-auditor refused set (run `mix letflow.permission_matrix --write`).
- Reports must never name `session.exam_snapshot` or any answer-key field (one restricted field rejects the whole
  aggregate request with 403). Only submitted and auto-submitted sessions count.
- Making `score_pct`, `passed` (and, for report 3, the score row fields) `queried: true` changes entity
  definitions already installed on tenants, including QA: T6c states how existing rows are handled (column
  promotion on activation; ISS-0648).

## 7. Open points the study could not settle

- The BilimBaga checkout is behind `origin/main`; a report added after `445216d` would not appear here.
- Which scope declaration the `session` and `session_question_score` types carry in Letflow was not read. If
  undeclared for a scoped caller, the aggregate returns an empty result: T6c must check it before promising
  department-level access.
- Whether BilimBaga's production data actually uses all reports (as with T6a for AI) is not known from the code;
  the portfolio owner can confirm that the PDF and the AI summaries are used before they are ported.
