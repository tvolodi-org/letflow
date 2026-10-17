# GH #2734 design note: a late exam snapshot must not be built from soft-deleted content

Status: DRAFT for CODE-DESIGN-VALIDATOR. Author: CODE-DESIGNER. Base: main 78200a07.
Links: #2682 (REQ-511), PRs #2730 / #2732, `test/specs/GH2682-exam-snapshot-pr-b.md` (Observations),
`test/specs/GH2682-exam-snapshot-pr-a.md` (Observation 2), `lib/letflow/design/req511-exam-content-snapshot.md`
(3.4, 17.2). Design only: no implementation code in this file.

## 1. Problem restated (re-read on main)

`Letflow.Entities.Record.Latest.get/3` (`lib/letflow/entities/record/latest.ex:87`) selects on
`entity_type` and `record_id` only; there is no `deleted` condition. The late snapshot builder
`Snapshot.build_late/3` and `Snapshot.build_certificate_only/3` (`lib/letflow/modules/exam/snapshot.ex:768`,
`:950`) read the exam and each question through the private `fetch_live/3` (`snapshot.ex:838`), which calls
`Latest.get/3`. Options and `session_question` rows are read through `query_all/3` (`snapshot.ex:1081`) ->
`Letflow.Entities.Query.Compiler`, which also returns `deleted = true` rows (the compiler selects the `deleted`
column and applies no default filter; confirmed by PR a Observation 2). So three kinds of soft-deleted row feed a
late snapshot today: exam, question, and (via the compiler, not `get/3`) answer_option and session_question.

Important scoping fact: the flaw reaches the option and `session_question` rows through `query_all/3`, NOT through
`Latest.get/3`. A fix confined to `get/3` would leave options unfixed. The issue title names only `get/3`; this
note widens the fix to the late-snapshot read set and says so explicitly.

## 2. How soft delete is represented

* Column: `entity_record_latest.deleted` (boolean, default false, `latest.ex` schema; set true only by
  `Records.delete_record/2`, the `ENTITY_RECORD_DELETED` event; `field_values` of the row are retained).
* Tenant scoping: the table lives in each tenant's schema; every read passes `prefix:`; `get/3` first validates the
  prefix with `TenantProvisioning.tenant_id_for_schema_name/1` (`{:error, :invalid_schema_name}`).
* Promoted per-entity-type tables carry a `deleted` column too (`records.ex:134`, `:982`); the compiler selects it
  (`compiler.ex:1100`, `:1251`, `:1265`). The query allowlist resolves a filter on field `"deleted"` to the typed
  column (`allowlist.ex:17-21`, `:94`).
* Deleted is terminal: the projector's `apply_event` only transitions from `deleted: false` (`projector.ex:473-494`);
  there is no undelete. So a row that read as deleted stays deleted (no TOCTOU flip back).
* Existing convention for "live only" reads: an explicit `deleted == false` predicate in the query itself, not a
  post-filter: `script_reads.ex:175,200`, `scheduler/record_deadline_sweep.ex:239`, `tenant_provisioning.ex:2394`,
  `modules/exam/snapshot.ex:1044`; `certificate_public_projection.ex:60` skips `%Latest{deleted: true}`. A raw
  `Latest.get/3` is the "any row, deleted or not" primitive (used by `Records` precisely because it must see deleted
  rows, see table below).

## 3. Per-caller table (re-read on main 78200a07)

Production callers of `Latest.get/3` (grep over all of `lib/`; comment/docstring-only mentions listed after).

| # | file:line | function | entity | Deleted row expected/needed? | Today on a deleted row | Should do (this issue) |
|---|---|---|---|---|---|---|
| C1 | `lib/letflow/entities/records.ex:1426` | `fetch_existing_record/3` (update at ~418, delete at ~477) | any | YES. `ensure_not_deleted/2` (`:1446`) turns it into `{:record_already_deleted, id}` (409), and `delete_record/2` treats an already-deleted record as a no-op success. Both need to SEE the deleted row. | returns it; correct | UNCHANGED. Must keep `get/3` semantics. |
| C2 | `lib/letflow/modules/exam/anti_cheat.ex:152` | `fetch_session/2` | session | Not needed, not relied on. | A signal against a soft-deleted session is processed. | UNCHANGED here (out of scope); flagged OQ-3. |
| C3 | `lib/letflow/modules/exam/anti_cheat.ex:184` | `fetch_action_taken/2` | exam | No. Reads only `on_tab_switch` policy; builds no content. | Soft-deleted exam still supplies the policy. | UNCHANGED (see OQ-4: refusing would make a candidate's signals 404 mid-exam for an authoring delete). |
| C4 | `lib/letflow/modules/exam/session.ex:321` | `get_session_for_user/3` | session | Not needed. | A soft-deleted session is returned to its owner. | UNCHANGED; flagged OQ-3. |
| C5 | `lib/letflow/modules/exam/session.ex:536` | `build_question_state/3` (state read) | question | Arguably yes: REQ-511 3.4 accepts live display text; an in-progress candidate keeps seeing the question rendered. Hard delete already yields `{:question_not_found, id}`. | Soft-deleted question still rendered. | UNCHANGED; flagged OQ-4 (changing it turns an authoring soft delete into a mid-exam state-read failure). |
| C6 | `lib/letflow/modules/exam/session.ex:1024` | `fetch_pinned_question_row/2` (START path, manual pin) | question | No. A pin to a deleted question should be a start failure. | Accepted if `status == "active"` (PR a Observation 2). | Same defect class on the START path, not the late path. NOT changed in this issue; flagged OQ-2 (recommend a follow-up issue using the new live read). |
| C7 | `lib/letflow/modules/exam/session.ex:1090` | `fetch_session/2` (autosave, submit, etc.) | session | Not needed. | Soft-deleted session is operable. | UNCHANGED; flagged OQ-3. |
| C8 | `lib/letflow/modules/exam/snapshot.ex:841` | `fetch_live/3` <- `live_exam/2` (`:790`), `load_item/2` (`:810`) | exam, question | NO. This is the issue. | Builds snapshot from deleted exam/question. | CHANGE: read live-only; deleted == gone. |

Adjacent reads with the same flaw that do NOT go through `get/3` (found while re-reading; not in the issue's list):

| # | file:line | what | note |
|---|---|---|---|
| A1 | `snapshot.ex:773` | `query_all("session_question", ...)` in `build_late` | soft-deleted session_question rows still enter `order`. CHANGE (late path). |
| A2 | `snapshot.ex:813` | `query_all("answer_option", ...)` in `load_item` | soft-deleted options still enter the key/correct set. CHANGE (late path). |
| A3 | `session.ex:563` | `query_all("answer_option")` in `build_option_states` | display only; UNCHANGED (OQ-4). |
| A4 | `session.ex:738-749` | `lock_exam_row/2` (create) selects the exam row with `FOR UPDATE`, no `deleted` condition | a soft-deleted but `active` exam may still start a session. Same class, START path. OQ-2. |

Docstring/comment-only mentions (no behaviour): `record/projector.ex:51`, `modules/exam/router.ex:90`,
`routers/entities.ex:1185`, `snapshot.ex:837`, `session.ex:735,737,1018,1021`.

Test callers (all use `get/3` to read back a row; none depend on filtering): ~60 call sites in 33 files, e.g.
`test/letflow/entities/record/projector_test.exs`, `records_test.exs:788`, `routers/entities_test.exs:3115,3442,3592-3605`,
`scope_node_paths/write_test.exs:193,400,418`, `modules/exam/*` (`snapshot_late_test.exs:194,199,489,510,616`,
`session_test.exs:1034,1398`, `pack_install_test.exs:417-612`), `test/support/exam_fixtures.ex:330,375,415,443`,
`scheduler/record_deadline_sweep*_test.exs`. Because `get/3` is left unchanged (section 4) none of them can break.
Call out `test/letflow/modules/exam/snapshot_late_test.exs:313-321` (`hard_delete!/3`): its comment says the soft
delete "leaves it readable by `Latest.get/3`"; that comment stays true.

## 4. Option space and recommendation

A. Filter inside `get/3`. Rejected. C1 needs deleted rows (409 / idempotent delete); ~60 test call sites and the
   projector/stamp tests read rows irrespective of deletion; a silent semantic change to a shared primitive with an
   "any row" contract is exactly the wrong blast radius. Would force a compensating `get_any/3` anyway.

B. A flag (opts) on `get/3`. Rejected. A boolean/option on the primitive invites the wrong default at the next call
   site and hides the intent behind an argument; the exam code already shows this exact mistake (`fetch_live` was
   written assuming `get/3` meant "live").

C. Filter at the snapshot builder only (post-check `row.deleted` in `fetch_live/3`). Smallest diff, but it leaves a
   reusable footgun (`get/3` looks live), and the next consumer (C6/A4 follow-ups) reimplements it. It also cannot
   cover options/session_questions, which come from `query_all/3` anyway.

D. RECOMMENDED: add `Latest.get_live/3`, leave `get/3` unchanged, and switch the late-snapshot read set to
   live-only reads.

   Rationale:
   * Security: the deleted condition is in the SQL predicate (`deleted == false`), matching the existing
     convention (section 2). A deleted row is never loaded into the process, so no snapshot content can be built
     from it by a later code edit that forgets a post-check.
   * No information leak: `get_live/3` returns the same `{:error, :not_found}` as an absent row. The builder maps it
     to the same `{:grading_error, ...}` atoms a hard delete produces (T-49/T-50), so a soft-deleted and a
     nonexistent exam/question are indistinguishable to every consumer of the typed error (no new error atom, no
     `:deleted` or `:gone` variant, no distinct HTTP shape).
   * Callers that must see deleted rows (C1 and the 60 test sites) are untouched by construction.
   * Idempotency / replay: `build_late` runs only when the locked session has NO snapshot
     (`ensure_locked/2` returns `:existing` for a present, verified snapshot; tests T-24 / M4, T-18b). An
     already-built snapshot is never rebuilt, so a later soft delete cannot invalidate or alter it, and the
     certificate path reads the snapshot (T-11). The change therefore affects only sessions still snapshotless at
     touch time; replays of submit/finalize on a snapshotted session are byte-identical.
   * Concurrency: build runs inside the session-row-locked transaction. An authoring delete committing after the
     read is equivalent to a delete just after the snapshot; deleted is terminal, so there is no flip-back race.
   * Options/session_questions: add an explicit `deleted == false` filter to the two `query_all/3` calls in the late
     path (A1, A2) using the allowlisted `"deleted"` filter field, not a new function.

### 4.1 Signatures and shapes (no bodies)

* New: `Letflow.Entities.Record.Latest.get_live(record_id :: Ecto.UUID.t(), entity_type :: String.t(), prefix :: String.t()) :: {:ok, t()} | {:error, :not_found} | {:error, :invalid_schema_name}`.
  Same guards, same prefix validation, same `Repo.one(..., prefix: prefix)`, same raise-on-non-UUID behaviour as
  `get/3` (callers keep casting first, as `fetch_live/3` does). Only difference: the query adds `deleted == false`.
  A soft-deleted row is `{:error, :not_found}`.
* `Letflow.Entities.Record.Latest.get/3`: signature, behaviour and docs unchanged except a docstring sentence
  stating it returns soft-deleted rows and pointing to `get_live/3`.
* `Snapshot.fetch_live/3` (private): calls `get_live/3`; return shape unchanged (`{:ok, row} | :not_found |
  {:error, :invalid_schema_name}`).
* `Snapshot.build_late/3` filter sets: `session_question` query gains `deleted == false`; `answer_option` query in
  `load_item/2` gains `deleted == false`. No change to `build_from_resolved/4`, the snapshot map, digest, or version.
* No DB change, no migration, no new index, no new error atom, no new event/audit field, no API/OpenAPI change.

## 5. Behaviour on the late-snapshot path: refuse vs exclude

Existing evidence: PR b spec states a hard delete of the live exam/question is a typed refusal (T-49 -> `{:grading_error,
:exam_section_missing}`; T-50 -> `{:grading_error, {:question_item_missing, id}}`), writing nothing, leaving the
session `in_progress` (`assert_late_build_fails!`). The spec's Observations record the soft delete as "not asserted
either way". For options, a hard delete today simply drops the row from `query_all` (no error): the key is built
from the remaining rows, and the existing fail-closed checks (`build_item` -> `{:key_missing, id}`, T-51) fire only
when no correct option remains.

Recommendation (single rule: a soft delete behaves exactly like the already-tested hard delete):

| Soft-deleted row | Late `build_late` | Late `build_certificate_only` |
|---|---|---|
| exam | REFUSE: `{:error, {:grading_error, :exam_section_missing}}`, nothing written, no audit entry | REFUSE: same atom, nothing written, no audit |
| question of a session_question | REFUSE: `{:error, {:grading_error, {:question_item_missing, id}}}` | n/a (certificate-only reads the exam only) |
| answer_option | EXCLUDE (as a hard delete does). If the exclusion leaves a single-choice/likert question without its key, existing `{:key_missing, id}` refuses it. | n/a |
| session_question | EXCLUDE (as a hard delete does) | n/a |

Why refuse the exam/question rather than exclude: excluding a question changes the maximum score and pass
threshold arithmetic and silently drops a graded item for a real candidate; the exam row carries the pass
threshold and certificate facts which cannot be invented. Refusal is the only fail-closed choice and reuses the
existing, already-mapped typed errors (no new surface).

Known cost of refusing (state for the supervisor, OQ-1): the legacy `in_progress` session then cannot be scored
(submit, deadline auto-submit and state read all return the typed error until an operator restores content, which
undelete cannot do because deleted is terminal). That is identical to the hard-delete behaviour that PR b already
accepted.

## 6. Acceptance criteria -> design/test mapping

AC1 "design note first with per-caller table": sections 3 and 4 of this file.

AC2 "failing test first ... callers that need deleted rows keep working": tests below, written and shown FAILING on
main before the fix (ELIXIR-DEV/TEST-DESIGNER quote the red run).

| ID | Test (file) | Asserts | Fails on main today |
|---|---|---|---|
| G1 | `test/letflow/entities/record/latest_test.exs` (new or extend existing latest test) | `get_live/3`: live row -> `{:ok, row}`; soft-deleted row (via `Records.delete_record/2`) -> `{:error, :not_found}`; absent -> `{:error, :not_found}`; unregistered prefix -> `{:error, :invalid_schema_name}`; other tenant's schema cannot see the row | yes (function missing) |
| G2 | same file | `get/3` STILL returns the soft-deleted row with `deleted: true` (regression guard for C1 and the 60 test sites) | passes (guard) |
| T-49b | `test/letflow/modules/exam/snapshot_late_test.exs`, describe "T-48 .. T-51" | soft-deleted exam (`Fx.delete_record!/3`) on a legacy session: `ensure` and `submit` both `{:error, {:grading_error, :exam_section_missing}}`, snapshot field and scores unchanged, status `in_progress` (reuse `assert_late_build_fails!/2`) | yes |
| T-50b | same | soft-deleted question: `{:grading_error, {:question_item_missing, q_id}}`, nothing written | yes |
| T-50c | same | soft-deleted answer_option: late snapshot is built and its option/correct set does NOT contain the deleted id; a single-choice question whose only correct option is deleted -> `{:key_missing, q_id}` | yes |
| T-50d | same | soft-deleted session_question: excluded from snapshot `order`/`questions` | yes |
| T-49c | same file or `certificate_snapshot_test.exs` | `Snapshot.ensure_certificate_facts/3` on a submitted legacy session with a soft-deleted exam: `{:error, {:grading_error, :exam_section_missing}}`, no write, no `exam.session_snapshot_late` audit entry | yes |
| T-49d | same | indistinguishability: error value for a soft-deleted exam equals the value for a hard-deleted exam (T-49) | yes |
| R1 | same | replay: a legacy session that already has a late snapshot, then exam/question soft-deleted: `ensure`, state read, submit return the existing snapshot untouched (no rebuild, no new audit) | passes (guard, pins D) |
| P1 | `records_test.exs` / existing | C1 per-caller: `update_record` on a deleted record -> `{:record_already_deleted, id}`; second `delete_record` is a no-op success (name the existing tests; add only if none exists) | passes (guard) |
| P2 | `anti_cheat_test.exs` | C3: a signal on an in-progress session whose exam is soft-deleted still records with the stored policy (pins UNCHANGED) | passes (guard) |
| P3 | `session_test.exs` | C5/A3: state read of an in-progress snapshotted session with a soft-deleted question/option still renders (pins UNCHANGED) | passes (guard) |
| M | mutation | revert the `deleted == false` predicate in `get_live/3`: G1, T-49b fail; remove the option/session_question filter: T-50c/T-50d fail; point `fetch_live/3` back at `get/3`: T-49b, T-50b, T-49c fail | n/a |

AC3 "SECURITY-REVIEWER verdict (recommended); REVIEWER verdict; scoped tests one file at a time, compile and format
check quoted": this touches a tenant-data read path (INV prefix scoping preserved: `get_live/3` keeps the
`tenant_id_for_schema_name/1` guard and `prefix:`); route to SECURITY-REVIEWER. Run `mix test` per file for
`latest_test.exs`, `snapshot_late_test.exs`, `certificate_snapshot_test.exs`, `records_test.exs`,
`anti_cheat_test.exs`, `session_test.exs`, plus `mix compile --warnings-as-errors` and `mix format --check-formatted`.

## 7. Invariants

* I-1 `get/3` returns the row regardless of `deleted` (unchanged contract).
* I-2 `get_live/3` never returns a row with `deleted = true`; its not-found result is byte-identical to an absent
  row.
* I-3 No late snapshot (`late`, `late_certificate`) contains data derived from a soft-deleted exam, question,
  answer_option or session_question.
* I-4 A present snapshot is never rebuilt or altered by a later delete.
* I-5 No new error atom, audit field or log line carries content of a deleted row (INV-4/INV-5 unchanged).

## 8. Open questions for the supervisor (not guessed)

* OQ-1 Refuse vs exclude for exam/question (section 5). I recommend refuse (== hard delete). Operational cost: a
  snapshotless in_progress session whose exam/question was soft-deleted cannot be scored or auto-submitted, and
  deleted is terminal, so the only recovery is operator action (re-create content / fixture). Confirm, or rule
  "exclude question" (which changes max score) instead.
* OQ-2 Scope of START path: C6 (`session.ex:1024` pin to a soft-deleted active question) and A4 (`lock_exam_row/2`
  lets a soft-deleted active exam start a session) are the same defect class but are not the late-snapshot path.
  Recommend a separate follow-up issue (they change create/start behaviour and error mapping); confirm not to
  include them here. A start snapshot built from a soft-deleted question is arguably also in "snapshot built from
  deleted content", so this is the supervisor's call.
* OQ-3 Soft-deleted SESSION (C2, C4, C7): all three keep serving a deleted session (autosave/submit/signals work).
  Not in this issue's scope; separate issue?
* OQ-4 Display/policy reads (C3 anti-cheat policy, C5/A3 state read): recommended UNCHANGED so an authoring delete
  does not break candidates mid-exam. Confirm; the alternative (refuse) is a behaviour change visible to
  candidates.
* OQ-5 Multi-choice silent drift: excluding a soft-deleted CORRECT option from a multiple-choice question builds a
  valid-looking key with a smaller correct set (no `key_missing`), changing who scores correct. A hard delete
  already does this today. Accept (consistency), or refuse any late build that touches a soft-deleted option?
  I recommend accept with this note, since refusing is cheap to add later but exclusion matches existing behaviour;
  it is the weakest point of the recommendation.
* OQ-6 `build_certificate_only` with a soft-deleted exam refuses certificate facts for a legacy submitted session
  that previously (on main) would have been issued. Intended per "no building content from deleted rows"; confirm.
* OQ-7 Implementer to verify, not assume: that the compiler accepts `eq` on field `"deleted"` with boolean `false`
  for both the generic and the promoted per-type table paths (allowlist maps it, but no existing caller uses it).
  If not, fall back to a post-filter on the `deleted` select field in the builder (still before any content use).
