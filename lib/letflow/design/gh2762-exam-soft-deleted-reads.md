# GH #2762 / #2759 / #2760 design note: the exam START path and option display must not use soft-deleted content

Status: RULED (supervisor rulings applied, section 9), subject to CODE-DESIGN-VALIDATOR and SECURITY-REVIEWER. Author: CODE-DESIGNER. Base: main c309227b
(includes #2734 / PR #2766). Design only: no implementation code in this file.
Links: #2734 (`lib/letflow/design/gh2734-latest-get-soft-deleted.md`, RULED), #2682 (REQ-511), PRs #2730 / #2732 / #2766.
SECURITY-REVIEWER: REQUIRED (tenant-data read path, exam scoring integrity: a deleted option with `is_correct` can still be scored).

## 1. Problem restated (re-read on main c309227b)

#2734 made the LATE snapshot (`Snapshot.build_late/3`, `build_certificate_only/3`) read live-only: `Latest.get_live/3`
(exam, question), `deleted == false` on `session_question`, and a partition of `answer_option` rows on their `deleted`
flag (`snapshot.ex:818-846`, `key_bearing?/2` at `:852-863`). It left three START-path reads untouched; they build the
snapshot a session is scored by from the same soft-deleted content:

* #2760: `lock_exam_row/2` (`session.ex:743-752`) selects `entity_record_latest` by `entity_type` + `record_id` with
  `FOR UPDATE` and no `deleted` condition; `check_exam_status/1` (`:757`) reads `status` only. A soft-deleted exam with
  `status = "active"` starts a session.
* #2759: `fetch_pinned_question_row/2` (`session.ex:1020-1039`) uses `Latest.get/3` and checks only `status == "active"`.
  A manual pin to a soft-deleted question is accepted and pinned into the new snapshot.
* #2762: `fetch_question_row/3` (`session.ex:965-985`) reads every `answer_option` row of a question through
  `query_all/3` (`:1476`, `Compiler.compile` + `Repo.all`), then builds `option_ids` and `source.options` (with
  `is_correct`, `likert_weight`, `likert_polarity`) from ALL rows, deleted included. A deleted correct option is in the
  start snapshot's `correct_option_ids`; a deleted incorrect option is in `options_order` and shown. `build_option_states/4`
  (`:562-577`) reads the same rows and keeps those whose id is in the session's stored `options_order`.

Finding beyond the three issues (same class, same START path; see 2.1 rows S3-S5 and OQ-3): the pool query
`query_all("question", [category_id, status active])` (`session.ex:947`) also returns soft-deleted questions, so a
deleted question with `status = "active"` is drawn from a pool; fixing only #2759 (manual pins) would leave the pool
door open. `exam_question_rule` (`:902`) and `exam_manual_question` (`:997`) rows are read unfiltered too.

Soft-delete facts are as in #2734 section 2 and are not repeated: `deleted` is terminal (no undelete), the compiler rows
carry the `deleted` column, `eq("deleted", false)` is a valid allowlisted filter (exercised in
`test/letflow/entities/query_test.exs:511-515`), `Latest.get_live/3` exists (`latest.ex`) and returns `{:error, :not_found}`
for a deleted row.

## 2. Per-caller table (re-read on main c309227b)

### 2.1 Every reader of exam-domain rows in `lib/` through `Compiler.compile` / `query_all` / `Latest`

"Sees deleted?" = does the caller today receive soft-deleted rows. "Relies" = does correct behaviour depend on that.

| # | file:line | what | Sees deleted today | Relies on seeing deleted | Today | Target |
|---|---|---|---|---|---|---|
| S1 | `session.ex:743` | `lock_exam_row/2` (START, #2760) | yes | NO | deleted + active exam starts | CHANGE: add `deleted == false` to the locked query; nil -> `:exam_not_active` (existing) |
| S2 | `session.ex:1024` | `fetch_pinned_question_row/2` (START, #2759) | yes | NO | deleted pinned question accepted | CHANGE: `Latest.get_live/3`; `:not_found` -> `{:question_not_found, id}` (existing clause) |
| S3 | `session.ex:947` | `fetch_pool_questions/2` `query_all("question", category_id + status active)` (START pool) | yes | NO | deleted active question enters the pool | CHANGE (in the #2759 PR, OQ-3): add `eq("deleted", false)`; a deleted question is simply not in the pool (no error) |
| S4 | `session.ex:966` | `fetch_question_row/3` `query_all("answer_option")` (START, pool AND pin, #2762) | yes | must SEE them (the shared function takes all rows) | all rows enter source/option_ids | CHANGE: exclude deleted via `Snapshot.live_options(.., :start)`; the refusal is carried and raised only for DRAWN questions (section 3.3) |
| S5 | `session.ex:902`, `:997` | `exam_question_rule`, `exam_manual_question` reads (START config) | yes | NO | a deleted rule / pin still applies | UNCHANGED here; separate follow-up issue filed by letflow-2 (accepted, OQ-4) |
| S6 | `session.ex:300` | `query_all("session", exam+user)` in `create_txn` (attempts, open session) | yes | arguably yes (a soft-deleted session still counts toward attempts) | counts it | UNCHANGED; not exam content, out of scope |
| D1 | `session.ex:562-577` | `build_option_states/4` (state read of an in-progress session, #2762 part 2) | yes | yes for already-started sessions (section 4.2) | shows options in `options_order` that still exist as rows, deleted included | UNCHANGED (guard test); see 4.2 |
| D2 | `session.ex:536` | `build_question_state/3` `Latest.get(question)` | yes | yes (hard delete already errors) | deleted question still rendered | UNCHANGED (#2734 ruled OQ-4) |
| D3 | `session.ex:459`, `:1118` | `session_question` reads (state, autosave) | yes | yes | n/a | UNCHANGED |
| D4 | `session.ex:463`, `:1226`, `:1375`; `anti_cheat.ex:251`; `mix letflow.seed.exam_fixtures:619` | `session_answer`, `session_event`, `session` reads | yes | yes (history) | n/a | UNCHANGED |
| D5 | `session.ex:233` | `list_available_exams/2` via `Compiler` + `Cursor` (exam, `status = active`) | yes; router serialises `"deleted"` (`router.ex:1007,1017`) | no | a candidate is offered a soft-deleted active exam, start then refuses | CHANGE in the #2760 PR (accepted, OQ-5): add `eq("deleted", false)` to the hardcoded filters so a soft-deleted active exam is not offered |
| D6 | `session.ex:321`, `:1090`; `anti_cheat.ex:152`, `:184` | `Latest.get` of session / exam policy | yes | yes | n/a | UNCHANGED (#2734 OQ-2..4) |
| L1 | `snapshot.ex:773`, `:821` (and the `query_all` helper at `:1110`) | late build: `session_question` (filtered), `answer_option` (partitioned) | no / partitioned | partitioned on purpose | done in #2734 | UNCHANGED; `key_bearing?/2` becomes the shared definition (section 5) |
| L2 | `snapshot.ex:870` | `fetch_live/3` -> `Latest.get_live/3` | no | no | done | UNCHANGED |
| G1 | `entities/script_reads.ex:199`, `:175` | script `read` of any entity type | no (post-filters `deleted == false`) | no | convention precedent | UNCHANGED |
| G2 | `routers/entities.ex:1958`, `:2394` (query, export) | generic query/export API for every entity type | yes, by contract (clients see the `deleted` flag) | YES | n/a | UNCHANGED; this is why the filter must NOT go into `Compiler.compile/2` |
| G3 | `entities/query/request_guard.ex`, `allowlist.ex`, `cursor.ex`, `field_grants.ex` | compiler support code | n/a | n/a | n/a | UNCHANGED |

No other `lib/` file reads `answer_option`, `session_question`, `question` or `exam` rows (grep of `lib/` for the
entity-type strings and for `Compiler.compile`/`compile_plain`; managed-type stamp and tamper-inventory only count
definitions). Seed task `letflow.seed.exam_fixtures` creates options but reads only `session`.

### 2.2 Why the filter is at the call sites, not in the compiler or in `query_all/3`

* `Compiler.compile/2` (G2): the generic query and export APIs expose deleted rows with their flag; a default filter
  would change a public contract for every entity type. Rejected.
* `Session.query_all/3` (shared by session, session_answer, session_question, rule, pin, option reads): a blanket
  `deleted == false` changes history/replay reads (D3, D4) and, for options, would hide exactly the rows needed to
  decide key-bearing (a deleted correct option must be SEEN to refuse). Rejected.
* Per call site, with the explicit `eq("deleted", false)` predicate (#2734 convention) where deleted must look absent
  (S3), `Latest.get_live/3` (S2), a `where` predicate (S1), and a read-then-partition for options (S4). Recommended.

## 3. Per-issue behaviour

### 3.1 #2760 `lock_exam_row/2`

* Current: a soft-deleted exam is locked and returned; `check_exam_status/1` passes on `status = active`.
* Target: the `from(r in Latest, where: ...)` gains `r.deleted == false` (predicate in SQL, the row is not loaded).
  `FOR UPDATE` stays on the same statement. A deleted exam returns `nil` -> `{:error, :exam_not_active}` (existing clause
  `:748`), HTTP 422 "this exam is not currently active" (`router.ex:291`), byte-identical to a nonexistent exam. A
  deleted AND archived exam is also `:exam_not_active`, not `:exam_archived` (no leak of the row's existence).
* Signature impact: none. `@spec` of `create_with_seed/4` already lists `eligibility_error()` (contains `:exam_not_active`).
* Concurrency: Postgres READ COMMITTED re-evaluates the WHERE after waiting on a `FOR UPDATE` lock, so (no isolation override found on this path in `lib/` or `config/`, grep for isolation: the only hit is the unrelated retention operation, `event_store/retention_operations.ex`; the implementer re-confirms) a delete that
  commits while a start waits makes the start see no row. A delete that commits after the start's snapshot write is
  equivalent to a delete just after the start; deleted is terminal, no flip-back race.
* Already-started sessions: not affected (create path only). A started session on an exam deleted afterwards keeps its
  snapshot (I-4 of #2734); anti-cheat policy reads (D6) stay as ruled.
* `list_available_exams/2` (D5, same PR, accepted): the hardcoded filter list gains `eq("deleted", false)` next to
  `status = active`, so the offer list and the start agree. Response shape unchanged.
* PR-body semantics to state: "a soft-deleted exam cannot start sessions; it answers `:exam_not_active` exactly like a
  nonexistent exam and is no longer listed as available. Sessions already started are unaffected. Swapping options is
  not touched by this PR."

### 3.2 #2759 `fetch_pinned_question_row/2`

* Current: `Latest.get/3` then `status == "active"`.
* Target: `Latest.get_live/3`. `{:error, :not_found}` (absent OR deleted) -> `{:error, {:question_not_found, question_id}}`
  (existing clause `:1030`); the `status != "active"` branch and the malformed-id branch already return the same tuple.
  The router renders all three with one constant body (`router.ex:316-331`: no id, no reason text, id logged only), so a
  deleted pin is indistinguishable from a missing or inactive one. The `Latest.get/3` comment at `:1021` is updated to
  `get_live/3` (it raises on a non-UUID id too; the existing `Ecto.UUID.cast` guard stays).
* Pool sibling (S3): `fetch_pool_questions/2` adds `eq("deleted", false)` to its filters. A deleted pool question is not
  drawn; no error (a pool is a selection; refusing the start because of one removed bank question would be wrong, and
  excluding it matches how the pool already excludes `status != active`). If the pool then has fewer than `count`
  questions, the existing resolver error applies unchanged (no new behaviour).
* Idempotency: start is not retried idempotently (a second start with an open session is `{:session_already_open, id}`);
  sessions already created are untouched.
* PR-body semantics to state: "a manual pin to a soft-deleted question fails the start with the same constant 422 as a
  missing or inactive pin; soft-deleted questions are not drawn from random pools. A pin or pool question whose OPTIONS
  were swapped (old correct option deleted, new correct option added) is unaffected by this PR; option handling is
  #2762's."

### 3.3 #2762 option reads

START (S4, `fetch_question_row/3`, used by both pool and pin). Rulings: authors swap options (delete the old correct
option, add a new one) as a normal edit, so a deleted correct option must NOT block a start that has a live key; and a
broken question must block only the sessions that actually DRAW it.

Pipeline (where the read and the refusal happen):
1. `fetch_question_row/3` (runs for every active, live pool question and every pin, BEFORE the draw) reads ALL option
   rows (query unchanged, so deleted rows are visible), calls `Snapshot.live_options(option_rows, question, :start)`
   (section 5) and builds `option_ids` from the live rows only. It does NOT fail the start. If `live_options` returned
   `{:error, reason}` the row is kept, with `option_ids: []`, and its Session-private source wrapper is
   `{:refused, reason}`; otherwise `{:usable, source}` with `source.options` built from the live rows only.
   The wrapper is internal to `Session` (the `sources` map of `materialize_session/5`); the resolver and `Snapshot`
   signatures and the `question_source` type are unchanged (the resolver reads `question_id`/`option_ids`; the
   implementer confirms it treats `source` as opaque, as it does today).
2. `QuestionSetResolver.resolve/5` draws from the rows (a refused row has no options but may still be drawn: it is
   not hidden from the pool, because hiding it would silently change pool size and draw probabilities).
3. In `materialize_session/5`, after `order` is computed and BEFORE `Snapshot.build_from_resolved/4`, the drawn
   question ids (`Map.take(sources, order)`, in `order` sequence) are checked: the first `{:refused, reason}` makes the
   start fail with `{:error, reason}` = `{:error, {:grading_error, {:key_missing, question_id}}}`; otherwise the wrappers
   are unwrapped to plain `question_source` maps and `build_from_resolved/4` runs as today (its `build_item`/`check_key`
   checks remain the last line of defence). Nothing is written on refusal (the transaction rolls back via
   `create_txn`'s `Repo.rollback/1`).
4. Pins are always drawn (every pin is in `order`), so a broken pinned question refuses every start. A broken question
   in a random pool refuses a start only when this seed draws it; an undrawn broken question does not block the exam.
   This is deliberate and is the stated behaviour of a pool draw that includes a broken question: the drawn question is
   part of the session, so it is refused (fail closed); candidates whose draw misses it start normally. The
   randomness of the failure is accepted and recorded in the PR body (operators see a `key_missing` start refusal whose
   question id is in the log).

Start outcomes (per question, :start mode):

| Option rows of the question | Result |
|---|---|
| all live | unchanged |
| some deleted, live set has a valid key (single/multiple/truefalse: at least one live `is_correct == true`; likert: at least one live option; shorttext: always) | deleted rows excluded from `option_ids` and `source.options`; start proceeds. SWAP: old correct deleted + new correct live => starts, `correct_option_ids` = the new option only |
| some deleted, and the live set has NO live correct option (key types) | refused if drawn: `{:key_missing, question_id}` |
| no live option at all (key types, likert) | refused if drawn: `{:key_missing, question_id}` (same atom; the "no options" case is `key_missing` today via `build_likert`/`check_key`, no new atom) |
| shorttext with any/no deleted options | deleted excluded; never refused (tripwire in section 5) |

Mid-exam display: see 4.2.

PR-body semantics to state (#2762 PR): "soft-deleted options are excluded from the start snapshot and from the shown
option list of NEW sessions. A deleted option never blocks a start by itself: swapping the correct option (delete old,
add new) works and the new option is the key. A start is refused with `key_missing` only when a DRAWN question is left
with no live correct option (or no live options). The late (legacy) snapshot keeps the stricter #2734 rule: a
soft-deleted key-bearing option refuses. Sessions started before this fix keep what they captured."

## 4. Display, replay and already-started sessions

### 4.1 Snapshot immutability

A session's snapshot (`session.exam_snapshot`) holds, per question, `type`, `correct_option_ids` and `likert_options`
only (`snapshot.ex:212`); the displayed option ids are in `session_question.options_order` (written at start,
`session.ex:1067`); `check_options_belong/2` (`:1181`) validates answers against `options_order`. Nothing the
three fixes do rewrites an existing snapshot or `options_order`: they change only what a NEW start (or a late build) reads.
A snapshotted session is never rebuilt (#2734 I-4). Therefore sessions started before this fix keep their snapshot and
`options_order`, including any deleted option they captured; that is accepted (replay is byte-identical, scoring
unchanged, no migration or backfill; recorded as a known residual in the PR body).

### 4.2 `build_option_states/4` for an in-progress session (D1)

Question: should a deleted option be hidden from a candidate who is mid-exam?

Recommended target: NO change to `build_option_states/4`. Reasons:
1. After the START fix, a session started on the fixed code never has a deleted-at-start option in `options_order`; the
   only deleted options the display can meet are ones deleted AFTER the session started.
2. For those, the snapshot already holds the option in `correct_option_ids` (if correct) and `options_order` still lists
   it. Hiding it would make the candidate's screen disagree with the key they are scored by (a candidate could be
   unable to select a correct answer that scoring still expects, or lose a previously saved selection from view) and
   would make the same session render differently on two reads. That is the "display vs scoring disagree" failure
   REQ-511 5.2 exists to prevent. Authoring deletes must not alter an in-progress attempt.
3. #2734 OQ-4 ruled display reads (C5/A3, now D1/D2) out of scope and pinned them with guard P3.
4. The text shown is the retained `field_values` text of the row (a soft delete keeps `field_values`); no new leak
   beyond what the candidate already saw (the id is in their own `options_order`; INV-4/INV-5 unchanged).

Residual (stated, accepted): a deleted option stays visible for sessions that began before deletion. The issue text's
"deleted option is absent from `build_option_states`" is satisfied for every session started after the fix by the START
change alone (their `options_order` omits it); the guard test pins both halves (OQ-1b).

Edge: legacy snapshotless session (late path): `build_late` excludes a deleted non-key-bearing option from its snapshot
while `options_order` (written by the old start) may still list it; the display shows it, an answer selecting it
passes `check_options_belong` and scores as incorrect. Consistent with #2734; no change.

## 5. The single shared function: `Snapshot.live_options/3` with an explicit mode (interaction with #2734)

Where it lives: `Letflow.Modules.Exam.Snapshot` (owns `@key_types`, `build_item/2`, `build_likert/3`, `check_key/3`).
ONE public function, mode-parameterised, so the two rules sit side by side and cannot drift apart without a test
failing. The private `key_bearing?/2` (`snapshot.ex:852-863`, with its shorttext TRIPWIRE comment) stays private to
`Snapshot`; `Session` never sees or re-implements it.

* Exact name/spec:
  `Snapshot.live_options(option_rows :: [option_row], question :: %{required(:type) => String.t() | nil, required(:question_id) => String.t()}, mode :: :start | :late) :: {:ok, [option_row]} | {:error, {:grading_error, {:key_missing, String.t()}}}`
  where `option_row` is a compiler row exposing `deleted` and `field_values` (both `Latest.t()` and promoted
  `entity_row()` shapes). `question_id` is the normalised UUID string, the id carried in the error. An unknown `mode`
  is a `FunctionClauseError` (no catch-all). The returned list is the live rows in input order.
* Both modes first split rows into live (`deleted != true`) and deleted. Returned rows are always live rows only.
* `:late` (reconstructing what an already-started candidate could have seen; behaviour is EXACTLY today's `load_item/2`
  partition): if any deleted row is key-bearing for the type => `{:error, {:grading_error, {:key_missing, id}}}`;
  otherwise `{:ok, live}`. Key-bearing is #2734 4.1: `single`/`multiple`/`truefalse`: `is_correct == true`; `likert`:
  `likert_weight` non-nil OR `is_correct == true`; `shorttext` and unknown types: none.
* `:start` (content as authored now; deleted rows are ignored for key purposes): never looks at whether a deleted row
  was key-bearing. It refuses only when the LIVE set cannot form a key: for `single`/`multiple`/`truefalse` when no live
  row has `is_correct == true` (this includes an empty live set); for `likert` when the live set is empty;
  `shorttext` and unknown types: never refuse here (unknown types keep `{:question_type_invalid, id}` from
  `build_item/2`). Refusal atom: `{:key_missing, question_id}` (reused, covers both "no live correct option" and "no live
  options at all"). The check mirrors `check_key/3`/`build_likert/3`; it is a typed early signal, not a second
  authority: `build_from_resolved/4` still validates the unwrapped source.
* `load_item/2` (late) calls `live_options(rows, q, :late)` (pure extraction; the #2734 T-50* suite stays green
  unchanged). `Session.fetch_question_row/3` calls `live_options(rows, q, :start)` (section 3.3).
* The shorttext tripwire applies to both modes: if accepted-answer grading is ever added, `:late` must refuse a deleted
  accepted answer and `:start` must require a live one; the test "short_text is never auto-graded" guards both.
* `question_source` / snapshot map / digest / version: unchanged. No new error atom.

Start-vs-late difference, stated: `:late` refuses on a deleted key-bearing option (the candidate may have seen it, and
dropping it silently changes who scores correct); `:start` ignores deleted rows because the new session will only ever
show and score the live content. Different questions, different rules; one function and a test per mode (section 7).

## 6. One note, how many PRs

Shared code: the START path only (`Session`), plus the new `Snapshot.live_options/3` used by one #2762 call site and
the existing late builder. The three issues touch different functions: `lock_exam_row/2` (+ `list_available_exams/2`,
#2760), `fetch_pinned_question_row/2` (+ pool filter, #2759), `fetch_question_row/3` and `materialize_session/5` (#2762).
Sharing: a live pin goes through the #2762 partition afterwards; nothing in #2760/#2759 depends on #2762.

RULED: THREE PRs (one per issue), in this order, each independently mergeable and green: (1) #2760, (2) #2759, (3) #2762.
Each PR body carries the "PR-body semantics" paragraph given in 3.1, 3.2 and 3.3 respectively (including, for #2759 and
#2762, the swap-an-option behaviour). The validator may ask for 2+3 combined; the design does not require it.

## 7. Failing-first test plan, mutants, acceptance mapping

Files (implementer confirms exact homes): start-path tests in `test/letflow/modules/exam/session_test.exs` and
`exam_sessions_test.exs` (HTTP mapping); `live_options/3` unit and extraction guard in `snapshot_test.exs` /
`snapshot_late_test.exs`; fixtures `Fx.delete_record!/3` (`test/support/exam_fixtures.ex`). RED = fails on main c309227b
and must be shown red before the fix; GUARD = passes on main and pins behaviour. Every refusal asserts: no session row,
no `session_question` rows, no snapshot written.

| ID | Issue | Test | Asserts | RED/GUARD |
|---|---|---|---|---|
| T-60a | 2760 | `create/3` on an exam deleted via `Records.delete_record/2` while `status = active` | `{:error, :exam_not_active}`, no session created | RED |
| T-60b | 2760 | HTTP `POST .../exam-sessions` for the same | 422 and the same body as for a nonexistent exam id | RED |
| T-60c | 2760 | deleted AND archived exam | `:exam_not_active`, NOT `:exam_archived` | RED |
| T-60d | 2760 | live active exam, deleted-sibling exam exists | start succeeds (over-filtering guard) | GUARD |
| T-60e | 2760 | exam deleted AFTER a session started: `get_session_for_user`, state read, autosave, submit keep working | unchanged | GUARD |
| T-60f | 2760 | `list_available_exams/2`: soft-deleted active exam absent, live active present | as stated | RED |
| T-59a | 2759 | manual pin to a soft-deleted active question | `{:error, {:question_not_found, qid}}`, nothing written | RED |
| T-59b | 2759 | same via HTTP | 422 constant pinned-question body, equal to the missing-question body | RED |
| T-59c | 2759 | soft-deleted pin error equals nonexistent-pin error | equal | RED |
| T-59d | 2759 | random pool whose size equals the rule `count` and contains a soft-deleted active question (others live), so on main the deleted question is always drawn | the deleted question is never in `order`; the pool is now one question short of `count`, so the assertion is the resolver's existing outcome for an undersized pool (the implementer reads it from `QuestionSetResolver` and pins it) | RED |
| T-59e | 2759 | live pin and live pool | unchanged | GUARD |
| T-62k1 | 2762 | `live_options/3` mode `:start`, table-driven over type x (deleted/live, correct/incorrect) | deleted always excluded; refuse iff live set has no correct option (single/multiple/truefalse) or is empty (likert); shorttext never; swap case returns only the new correct row; input order kept; both row shapes | RED (function missing) |
| T-62k2 | 2762 | `live_options/3` mode `:late`, same table | refuse iff a deleted row is key-bearing per type (incl. likert weight / `is_correct`, shorttext exempt); else live rows | RED (function missing) |
| T-62k3 | 2762 | MODE-DIVERGENCE test on the input where the modes differ (single: deleted correct + live new correct) | `:start` -> `{:ok, live rows}`; `:late` -> `{:error, {:grading_error, {:key_missing, id}}}`; and (deleted correct, no live correct): both refuse | RED |
| T-62k4 | 2762 | unknown mode | `FunctionClauseError` | RED |
| T-62a | 2762 | pool question with a soft-deleted INCORRECT option (single) | start succeeds; id absent from `options_order`; `correct_option_ids` equals the no-deletion snapshot | RED |
| T-62b | 2762 | pin question with a soft-deleted INCORRECT option | same as T-62a | RED |
| T-62c | 2762 | SWAP, pin: old correct option soft-deleted, new correct option live | start succeeds; snapshot `correct_option_ids` = [new id]; `options_order` has no old id; answering the new option scores correct | RED |
| T-62c2 | 2762 | SWAP, pool (one drawn question), multiple: one of two correct options swapped | start succeeds; correct set = live correct ids | RED |
| T-62d | 2762 | pin, single: soft-deleted correct option and NO live correct option | `{:error, {:grading_error, {:key_missing, qid}}}`, nothing written | RED |
| T-62d2 | 2762 | pin: every option soft-deleted (single, likert) | `{:key_missing, qid}`, nothing written | RED |
| T-62e | 2762 | truefalse: soft-deleted correct, no live correct -> refused; soft-deleted incorrect -> built | refused / built | RED / GUARD legs |
| T-62g | 2762 | likert: soft-deleted weighted option excluded and start proceeds if live options remain; a nil-weight live option still refused by existing `build_likert` | as stated | RED (first leg) |
| T-62h | 2762 | shorttext: soft-deleted option excluded; asserts the start SUCCEEDS (passes on main) | start succeeds, snapshot built | GUARD |
| T-62h2 | 2762 | same shorttext start | the deleted option id is absent from `options_order` | RED |
| T-62m | 2762 | UNDRAWN broken pool question: pool where one question has no live correct option, `count` smaller than the pool, seed chosen so it is not drawn | start succeeds | RED on a naive eager implementation (mutant below); on main it starts, so this is a GUARD of ruling OQ-2 |
| T-62n | 2762 | DRAWN broken pool question: `count` = pool size so it is always drawn | `{:key_missing, broken_qid}`, nothing written; with two broken drawn questions the first in `order` is reported | RED |
| T-62o | 2762 | HTTP: the refused start maps through the existing `{:grading_error, _}` clause of `render_start_session` -> `render_snapshot_failure` (`router.ex:333-340`) problem (`@content_invalid_detail`); no deleted/id text in the body | existing shape | RED |
| T-62j | 2762 | parity table: for each matrix cell, real `create` and real late build on the same rows behave as the two modes specify | per mode | RED (start side) |
| T-62l | 2762 | display guard: session started with all options live, then a non-correct option soft-deleted: `get_session_state_for_user` still lists it (4.2); a session started after the deletion does not list it | as stated | GUARD for the first half; the second half (post-deletion start does not list it) is RED on main |
| T-62p | 2762 | #2734 suite (T-50c..T-50c7, T-49*) unchanged after the extraction | green | GUARD |

Mutants (each must turn a named test red): remove `deleted == false` from `lock_exam_row/2` (T-60a..c); drop the
`list_available_exams` predicate (T-60f); `get_live` back to `get` in the pin check (T-59a..c); drop the pool filter
(T-59d); `fetch_question_row/3` skips `live_options` (T-62a..d); MODES SWAPPED at the two call sites (T-62c, T-62p, T-62k3);
START USING THE LATE RULE, i.e. refuse on a deleted key-bearing option (T-62c, T-62c2, T-62k1, T-62k3); LATE USING THE
START RULE (T-50c2/T-50c3, T-62k2, T-62k3); FILTER ON ALL POOL QUESTIONS, i.e. raise the refusal inside
`fetch_question_row/3` instead of after the draw (T-62m); skip the post-draw check so a drawn refused row is built
(T-62n); drop a refused row from the pool instead of carrying it (T-62n, pool-size arithmetic); refuse on ANY deleted
option (T-62a, T-62c, T-62g, T-62h2); `:start` refusing an empty live shorttext set (T-62h); a distinct error atom for
deleted (equality assertions T-60c/T-59c/T-62o); filtering inside `build_option_states/4` (T-62l).

Acceptance mapping (the three issues' "Required"): design note first = this file; failing test first = the RED rows,
run and quoted before each fix; #2760 "soft-deleted exam with status active answers `:exam_not_active`" = T-60a/b;
#2759 "pin to a soft-deleted question gives `{:question_not_found, id}` same as missing" = T-59a/c; #2762 "soft-deleted
option absent from the start snapshot and from `build_option_states`" = T-62a/b/c (start) and T-62l (display: absent for
post-fix sessions, deliberately retained for already-started ones, OQ-1b); swap-an-option = T-62c/c2; "refuse only when
left without a live key" = T-62d/d2/e; "only drawn questions" = T-62m/n; per-caller table and filter location = section
2; "SECURITY-REVIEWER recommended" = required; #2760 "record in REQ-511 text once #2734 merges" = DOC-UPDATER adds one
line that a start on a deleted exam is refused (with the #2760 PR); the #2734 certificate consequence is unchanged.

## 8. Invariants

* I-1 No session is created from a soft-deleted exam, and the refusal is `:exam_not_active`, identical to an absent exam.
* I-2 A start snapshot contains no data derived from a soft-deleted question or answer_option.
* I-3 At START a soft-deleted option is excluded and never blocks by itself; a DRAWN question left without a live
  correct option (key types) or without live options (likert) refuses with `{:key_missing, question_id}`; an undrawn
  question never blocks. At LATE a soft-deleted key-bearing option refuses (#2734, unchanged). Both rules live in
  `Snapshot.live_options/3`, one clause set per mode, each with its own tests.
* I-4 No new error atom, HTTP shape, log content or audit field distinguishes deleted from absent (INV-4/INV-5).
* I-5 Existing snapshots, `options_order`, scores and replays are never altered by these changes or by later deletes.
* I-6 Tenant scoping unchanged: every read still passes `prefix:`; `lock_exam_row/2` keeps the
  `tenant_id_for_schema_name/1` guard; `get_live/3` keeps its own.
* I-7 `Compiler.compile/2`, `Latest.get/3`, `Session.query_all/3` semantics unchanged (generic APIs keep returning deleted rows).
* I-8 A refused row is never unwrapped into a `question_source`: the post-draw check is the only place a `{:refused, _}`
  wrapper is consumed, and it consumes it before `build_from_resolved/4`.
* No DB change, migration, index, OpenAPI change or new event.

## 9. Supervisor rulings and remaining notes (binding)

* OQ-1a (RULED, changed): authors must be able to swap options. One shared public function with an explicit mode
  (section 5): `:start` excludes deleted options and refuses only when no live correct option (key types) or no live
  options (likert) remains, atom `{:key_missing, id}`; `:late` keeps the #2734 rule unchanged. A test per mode (T-62k1,
  T-62k2, T-62k3).
* OQ-2 (RULED, changed): at START the refusal applies only to questions actually drawn (3.3 pipeline: carry the
  refusal on the row, check after the draw, before `build_from_resolved/4`). A drawn broken question refuses the start
  with that question's `key_missing`. An undrawn broken question does not block. Known consequence for the PR body: a
  broken pool question makes starts fail for the candidates whose draw includes it.
* OQ-1b (accepted default): mid-exam display of an option deleted after the session started is UNCHANGED (4.2).
* OQ-3 (accepted): the pool `deleted == false` filter is folded into the #2759 PR.
* OQ-4 (accepted): deleted `exam_question_rule` / `exam_manual_question` rows still applying at start (`session.ex:902`,
  `:997`) is the separate follow-up GH #2779, filed by letflow-2 (cite it in the PR bodies; not in scope here).
* OQ-5 (accepted): the `list_available_exams/2` filter is in the #2760 PR.
* OQ-6 (accepted): sessions started before the fix keep what they captured; no backfill; stated in the PR bodies.
* Implementer verification notes: (a) confirm `QuestionSetResolver` treats a row's `source` as opaque (it already
  receives it today); if it pattern-matches on `source`, carry the wrapper in a Session-side map keyed by question id
  instead of inside the row; (b) confirm the promoted-table option rows expose `deleted` (the late builder already
  relies on it, `snapshot.ex:818-846`).
