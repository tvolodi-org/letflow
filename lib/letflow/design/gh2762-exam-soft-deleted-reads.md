# GH #2762 / #2759 / #2760 design note: the exam START path and option display must not use soft-deleted content

Status: DRAFT for CODE-DESIGN-VALIDATOR and supervisor rulings (section 9). Author: CODE-DESIGNER. Base: main c309227b
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
| S4 | `session.ex:966` | `fetch_question_row/3` `query_all("answer_option")` (START, pool AND pin, #2762) | yes | must SEE them to classify key-bearing | all rows enter source/option_ids | CHANGE: partition via the shared definition (section 5) |
| S5 | `session.ex:902`, `:997` | `exam_question_rule`, `exam_manual_question` reads (START config) | yes | NO | a deleted rule / pin still applies | UNCHANGED here; follow-up issue (OQ-4) |
| S6 | `session.ex:300` | `query_all("session", exam+user)` in `create_txn` (attempts, open session) | yes | arguably yes (a soft-deleted session still counts toward attempts) | counts it | UNCHANGED; not exam content, out of scope |
| D1 | `session.ex:562-577` | `build_option_states/4` (state read of an in-progress session, #2762 part 2) | yes | yes for already-started sessions (section 4.2) | shows options in `options_order` that still exist as rows, deleted included | UNCHANGED (guard test); see 4.2 |
| D2 | `session.ex:536` | `build_question_state/3` `Latest.get(question)` | yes | yes (hard delete already errors) | deleted question still rendered | UNCHANGED (#2734 ruled OQ-4) |
| D3 | `session.ex:459`, `:1118` | `session_question` reads (state, autosave) | yes | yes | n/a | UNCHANGED |
| D4 | `session.ex:463`, `:1226`, `:1375`; `anti_cheat.ex:251`; `mix letflow.seed.exam_fixtures:619` | `session_answer`, `session_event`, `session` reads | yes | yes (history) | n/a | UNCHANGED |
| D5 | `session.ex:233` | `list_available_exams/2` via `Compiler` + `Cursor` (exam, `status = active`) | yes; router serialises `"deleted"` (`router.ex:1007,1017`) | no | a candidate is offered a soft-deleted active exam, start then refuses | UNCHANGED here; adjacent finding (OQ-5): add `deleted == false` as the same one-line predicate in a follow-up, or fold into the #2760 PR |
| D6 | `session.ex:321`, `:1090`; `anti_cheat.ex:152`, `:184` | `Latest.get` of session / exam policy | yes | yes | n/a | UNCHANGED (#2734 OQ-2..4) |
| L1 | `snapshot.ex:773`, `:821` (and the helper at `:1111`) | late build: `session_question` (filtered), `answer_option` (partitioned) | no / partitioned | partitioned on purpose | done in #2734 | UNCHANGED; `key_bearing?/2` becomes the shared definition (section 5) |
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
* Concurrency: Postgres READ COMMITTED re-evaluates the WHERE after waiting on a `FOR UPDATE` lock, so a delete that
  commits while a start waits makes the start see no row. A delete that commits after the start's snapshot write is
  equivalent to a delete just after the start; deleted is terminal, no flip-back race.
* Already-started sessions: not affected (create path only). A started session on an exam deleted afterwards keeps its
  snapshot (I-4 of #2734); anti-cheat policy reads (D6) stay as ruled.

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

### 3.3 #2762 option reads

START (S4, `fetch_question_row/3`, used by both pool and pin): read ALL option rows of the question (unchanged query so
a deleted option is visible), then apply the single shared classification (section 5) before computing `option_ids` and
`source.options`:

| Deleted option | Start result |
|---|---|
| key-bearing (per type, section 5) | the start is REFUSED: `{:error, {:grading_error, {:key_missing, question_id}}}` (existing atom, already mapped by `render_start_session` for `:grading_error`, `router.ex:~326`), nothing written |
| not key-bearing | excluded from `option_ids` (hence from `options_order`) and from `source.options` |
| none deleted | unchanged |

`question_id` in the error is the normalised UUID string (`to_string/1`), as in `load_item/2`. Live options that no longer
yield a key keep the existing `build_item`/`check_key` refusal (`{:key_missing, id}`), unchanged. The refusal is
deterministic and eager for every question in a referenced pool (OQ-2 discusses the cost and the alternative).

Mid-exam display: see 4.2.

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

## 5. Single definition of "deleted key-bearing option" (interaction with #2734)

Where it lives: `Letflow.Modules.Exam.Snapshot` (the module that owns the key semantics: `@key_types`, `build_item/2`,
`build_likert/3`, `check_key/3`). The private `key_bearing?/2` (`snapshot.ex:852-863`, including the shorttext TRIPWIRE
comment) is NOT copied into `Session`. Design: add ONE public, documented function in `Snapshot`, used by both
`load_item/2` (late) and `Session.fetch_question_row/3` (start):

* `Snapshot.live_options(question_type :: String.t() | nil, question_id :: String.t(), option_rows :: [row]) :: {:ok, [row]} | {:error, {:grading_error, {:key_missing, String.t()}}}`
  where `row` is a compiler row exposing `deleted` and `field_values` (both `Latest.t()` and promoted `entity_row()`
  shapes, as today). Returns the rows with `deleted != true`, in input order; returns the error iff any deleted row is
  key-bearing for `question_type`. `key_bearing?/2` stays private to `Snapshot`; callers cannot reach the predicate or
  re-implement it.
* Key-bearing rule is exactly #2734 4.1: `single`/`multiple`/`truefalse`: `is_correct == true`; `likert`: `likert_weight`
  non-nil OR `is_correct == true`; `shorttext` and unknown types: none (unknown types keep their own
  `{:question_type_invalid, id}` refusal in `build_item/2`, which fires after). The shorttext tripwire and its test
  ("short_text is never auto-graded") govern START too, since the function is shared.
* `load_item/2` is changed to call it (behaviour unchanged, so the whole #2734 suite stays green); this is a pure
  extraction, which is the structural guarantee that start and late cannot diverge.
* `question_source` / snapshot map / digest / version: unchanged. No new error atom.

Start-vs-late difference, stated: late refuses a deleted key-bearing option for a question that is in the session's
`order`; start refuses for every question of the referenced pools/pins (eager, since `fetch_question_row/3` builds rows
for the whole pool before drawing). OQ-2.

## 6. One note, how many PRs

Shared code: the START path only (`Session`), plus the new `Snapshot.live_options/3` used by one #2762 call site and
the existing late builder. The three issues touch different functions: `lock_exam_row/2` (#2760), `fetch_pinned_question_row/2`
(+ pool filter, #2759), `fetch_question_row/3` (#2762). Sharing: #2759 -> `fetch_question_row/3` is called after the
pin check (a pin to a live question still goes through the #2762 partition); #2762's key-bearing definition must land
before anything relies on it.

Recommendation: THREE PRs (supervisor's default of one PR per issue), in this order, each independently mergeable and green:
1. #2760 (smallest, no shared code): `lock_exam_row/2` predicate; tests T-60a..T-60e.
2. #2759: `get_live/3` in the pin check plus the pool `deleted == false`; tests T-59a..T-59e.
3. #2762: extract `Snapshot.live_options/3`, switch `load_item/2` to it, use it in `fetch_question_row/3`; tests T-62a..T-62l.
No merge-order dependency between 1 and 2; 3 is independent of both. The validator may ask for 2+3 combined if it
judges the pool filter and the option partition one "start-snapshot content" change; the design does not require it.

## 7. Failing-first test plan, mutants, acceptance mapping

Files (implementer confirms exact homes): start-path tests in `test/letflow/modules/exam/session_test.exs` and
`exam_sessions_test.exs` (HTTP mapping); extraction guard in `snapshot_late_test.exs`; fixtures `Fx.delete_record!/3`
(`test/support/exam_fixtures.ex`). RED = fails on main c309227b and must be shown red before the fix; GUARD = passes
on main and pins behaviour. Every refusal asserts: no session row, no `session_question` rows, no snapshot written.

| ID | Issue | Test | Asserts | RED/GUARD |
|---|---|---|---|---|
| T-60a | 2760 | `create/3` on an exam deleted via `Records.delete_record/2` while `status = active` | `{:error, :exam_not_active}`, no session created | RED |
| T-60b | 2760 | HTTP `POST .../exam-sessions` for the same | 422 and the same body as for a nonexistent exam id | RED |
| T-60c | 2760 | deleted AND archived exam | `:exam_not_active`, NOT `:exam_archived` | RED |
| T-60d | 2760 | live active exam, deleted-sibling exam exists | start succeeds (guard against over-filtering) | GUARD |
| T-60e | 2760 | exam deleted AFTER a session started: `get_session_for_user`, state read, autosave, submit keep working | unchanged | GUARD |
| T-59a | 2759 | manual pin to a soft-deleted active question | `{:error, {:question_not_found, qid}}`, nothing written | RED |
| T-59b | 2759 | same via HTTP | 422 constant pinned-question body, equal to the missing-question body | RED |
| T-59c | 2759 | value equality: soft-deleted pin error equals nonexistent-pin error | equal | RED |
| T-59d | 2759 | random pool containing a soft-deleted active question (others live) | deleted question never in `order` across several seeds; start succeeds | RED |
| T-59e | 2759 | live pin and live pool | unchanged | GUARD |
| T-62a | 2762 | pool question with a soft-deleted INCORRECT option (single) | start succeeds; the id is absent from `options_order`; snapshot `correct_option_ids` equals the no-deletion snapshot | RED (id in `options_order` today) |
| T-62b | 2762 | pin question with a soft-deleted INCORRECT option | same as T-62a | RED |
| T-62c | 2762 | single: soft-deleted CORRECT option, other options live and incorrect | `{:error, {:grading_error, {:key_missing, qid}}}`, nothing written | RED |
| T-62d | 2762 | truefalse: soft-deleted correct option -> refused; soft-deleted incorrect -> built | refused / built | RED / GUARD legs |
| T-62e | 2762 | multiple: soft-deleted correct option while another correct stays live | refused (not a smaller set) | RED |
| T-62f | 2762 | multiple: soft-deleted incorrect option | built, `correct_option_ids` unchanged | RED (option id in `options_order`) |
| T-62g | 2762 | likert: soft-deleted weighted option refused; nil-weight no `is_correct` excluded and started; nil-weight with `is_correct: true` refused | as stated | RED (all) |
| T-62h | 2762 | shorttext: soft-deleted option excluded, start succeeds | built | GUARD |
| T-62i | 2762 | HTTP: refused start maps to the existing `@content_invalid_detail` problem via `render_snapshot_failure`; no deleted/id content in the body | existing shape | RED |
| T-62j | 2762 | parity: for the same question rows, start (`fetch_question_row` path) and late (`build_late`) agree on refuse/exclude for every cell of the matrix | same decision | RED (start side) |
| T-62k | 2762 | `Snapshot.live_options/3` unit: matrix of type x deleted x key-bearing, order preserved, promoted-row and `Latest` shapes | per section 5 | RED (function missing) |
| T-62l | 2762 | display guard: session started with all options live, then a non-correct option soft-deleted: `get_session_state_for_user` still lists it (4.2); a session started after the deletion does not list it | as stated | GUARD |
| T-62m | 2762 | #2734 suite (T-50c..T-50c7) unchanged after the extraction | green | GUARD |

Mutants (each must turn a named test red): remove the `deleted == false` from `lock_exam_row/2` (T-60a..c);
swap `get_live` back to `get` in the pin check (T-59a..c); drop the pool filter (T-59d); make `fetch_question_row/3` skip
the partition (T-62a..g); treat every deleted option as excluded (T-62c, T-62e, T-62g); refuse on ANY deleted option
(T-62a, T-62b, T-62f, T-62g nil-weight leg, T-62h); make `live_options/3` shorttext key-bearing (T-62h); duplicate the
rule in `Session` and change one branch (T-62j); filter inside `build_option_states/4` (T-62l); a distinct error atom for
deleted (T-60c/T-59c/T-62i equality assertions).

Acceptance mapping (the three issues' "Required"): design note first = this file; failing test first = the RED rows,
run and quoted before each fix; #2760 "soft-deleted exam with status active answers `:exam_not_active`" = T-60a/b;
#2759 "pin to a soft-deleted question gives `{:question_not_found, id}` same as missing" = T-59a/c; #2762 "soft-deleted
option absent from the start snapshot and from `build_option_states`" = T-62a/b (start) and T-62l (display: absent for
post-fix sessions, deliberately retained for already-started ones, OQ-1b); #2762 "per-caller table, filter location"
= section 2; "SECURITY-REVIEWER recommended" = required here; #2760 "record in REQ-511 text once #2734 merges" = the
certificate consequence of #2734 is unchanged; add one line to the REQ-511 status/doc text that a start on a deleted
exam is refused (DOC-UPDATER, with the #2760 PR).

## 8. Invariants

* I-1 No session is created from a soft-deleted exam, and the refusal is `:exam_not_active`, identical to an absent exam.
* I-2 A start snapshot contains no data derived from a soft-deleted question or answer_option.
* I-3 A soft-deleted key-bearing option refuses the start with `{:key_missing, question_id}`; a non-key-bearing one is
  excluded; the definition exists once (`Snapshot`), shared by start and late.
* I-4 No new error atom, HTTP shape, log content or audit field distinguishes deleted from absent (INV-4/INV-5).
* I-5 Existing snapshots, `options_order`, scores and replays are never altered by these changes or by later deletes.
* I-6 Tenant scoping unchanged: every read still passes `prefix:`; `lock_exam_row/2` keeps the
  `tenant_id_for_schema_name/1` guard; `get_live/3` keeps its own.
* I-7 `Compiler.compile/2`, `Latest.get/3`, `Session.query_all/3` semantics unchanged (generic APIs keep returning deleted rows).
* No DB change, migration, index, OpenAPI change or new event.

## 9. Open questions for the supervisor (recommended default for each)

* OQ-1a (HIGH IMPACT, needs an explicit ruling): the key-bearing refusal at START makes the common authoring edit
  "delete the old correct option, create a new correct option" permanently unstartable: the deleted correct row stays
  deleted forever (no undelete), so every start of any exam whose pool/pin includes that question is refused with
  `{:key_missing, qid}` even though the live options form a complete key. At the LATE path this affected only legacy
  in-progress sessions; at START it affects every new candidate. Operator remedy: recreate the question. Recommended
  default: follow the standing ruling (refuse; single definition on both paths; fail closed) and state the consequence
  in each PR body; if the supervisor prefers, a REFINED rule (refuse only when the live options no longer form a valid
  key, otherwise exclude) must be applied to BOTH paths in one change that also revises #2734's T-50c2/T-50c3, never
  to start alone.
* OQ-1b: mid-exam display of an option deleted after the session started (4.2). Recommended default: unchanged (shown),
  guard T-62l. Alternative (hide) rejected for the display-vs-key disagreement; if wanted it needs a ruling on selected
  answers that point at a hidden option.
* OQ-2: eager vs drawn-only refusal at START for a pool question with a deleted key-bearing option. Eager (default,
  deterministic, no resolver row-shape change) blocks the whole exam while any bank question referenced by it is in
  this state. Drawn-only matches today's hard-delete behaviour but needs the refusal carried on the resolver row
  (shape change to `QuestionSetResolver.question_row`/`Session` rows) and produces candidate-dependent start failures.
  Recommended default: eager.
* OQ-3: is the pool filter (S3) in scope of the #2759 PR? Recommended default: yes, it is the same defect (a deleted
  question reaching the start snapshot) and a pin-only fix is visibly incomplete; if the supervisor declines, file a
  separate issue and add a failing-first test for it.
* OQ-4: deleted `exam_question_rule` / `exam_manual_question` rows (S5) still apply at start. Recommended default: a
  separate follow-up issue (configuration rows, not question content; semantics of "deleted rule" need a ruling).
* OQ-5: `list_available_exams/2` (D5) offers soft-deleted active exams. Recommended default: fold the one-predicate fix
  into the #2760 PR (same root cause, same user-visible effect, no new atom) unless the supervisor wants it separate.
* OQ-6: the PR bodies state the known residual (4.1): sessions started before the fix keep captured deleted options.
  Recommended default: accept; no backfill.
