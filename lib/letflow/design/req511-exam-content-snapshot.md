# REQ-511 / GH #2682: exam content snapshot at session start; scoring and certificate read only the snapshot

Status: design (CODE-DESIGNER, 2026-10-16). Design only: no implementation code, no mix, reads only.
Verified against `main` at `828d9d1be` (re-verified 2026-10-17: `lib/letflow/modules/exam/*`, `stamp.ex`, `lib/letflow/release/managed_types.ex`, `lib/mix/tasks/letflow.stamp_managed_types.ex`, `priv/modules/exam/**` and `config/` are byte-unchanged since `efdd83ce1`, so every cited line of those files still holds; `routers/entities.ex` and `routers/instances.ex` changed with PR-0 and PR-0b, and references to them are by function name, not line; the GH #2596 code PR is merged: the six runtime types are in
`Exam.manifest().manages_entity_types`, `Stamp`, the tamper inventory and the Owner calls exist on main).
AMENDED 2026-10-16 (round 3: SECURITY-REVIEWER design verdict, section 18, also binding) after CODE-DESIGN-VALIDATOR round 1 (G1-G5) and supervisor rulings: section 17 is the
binding amendment and SUPERSEDES any conflicting statement in sections 1-16 (conflicts are also fixed in place
where short). Key changes: the filter/sort fix is a separate first PR (PR-0); PR sequence is PR-0 (#2697, MERGED), PR-0b (#2702, MERGED), (a), (b);
terminal sessions never need a snapshot to be read; one error shape for `:snapshot_missing`; late snapshots are
audited.
Binding inputs: the GH #2682 body including "Corrections after REQ-VALIDATOR round 1/2", and design
`lib/letflow/design/gh2596-exam-managed-types.md` section 17 (17.1 sketch, 17.5 ruling: lazy snapshot at
first touch, `snapshot_origin` start|late). Section 17.1's sketch is revised where the code showed a better
shape; every revision is listed in section 2 with its reason.

## 0. Findings that shape the design (all read in code at `828d9d1be (exam, Stamp, release and mix files unchanged since efdd83ce1)`)

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| F1 | Live reads of authoring rows that decide an outcome: `question.type`, `answer_option.is_correct`, `likert_weight`, `likert_polarity` (all in `build_question_row/2`), `exam.passing_score_pct` (`passing_threshold_for/2`), `exam.certificate_enabled` and `exam.title` (`Certificate.fetch_exam/2` + `check_certificate_enabled/1` + `issue_or_fetch/4`). | `session.ex:1194-1233`, `certificate.ex:292-335` | Two windows: scoring and certificate issuance (a separate call after scoring). |
| F2 | Live reads that are NOT scoring but decide behaviour: `question.type` in `fetch_question_for_autosave/2` -> `check_answer_shape/3` (shape validation of every autosave) and in `build_question_state/2` (type shown to the candidate); `question.stem` and `answer_option.text` in `build_question_state/2` / `build_option_states/4`. | `session.ex:428-472, 968-1007` | `question.type` is a snapshot class (a type edited mid-session would make display, shape check and scoring disagree). Stem/option text decided in section 3.4. |
| F3 | `passing_threshold_for/2`: row lookup error -> `60.0`; row present with `passing_score_pct` nil -> `to_float(nil)` raises FunctionClauseError (no `to_float/1` clause for nil; also none for a string). | `session.ex:1228-1233, 1408-1410` | Both become typed grading errors (section 7); the function is deleted, scoring no longer reads the exam row at all. |
| F4 | `session` fields today: `exam_id`, `user_id`, `status`, `seed`, `started_at`, `expires_at`, `submitted_at`, `score_pct`, `passed` (`passed` is `required: true`, written `false` at create; `submitted_at`, `score_pct` optional). `session_question`: `session_id`, `question_id`, `sort_order`, `options_order`, `question_version_id` (declared optional string, no `lib/` writer or reader; only `web/src/config/__tests__/bilimbagaEntities.test.ts` names it). | `session.json`, `session_question.json`, `session.ex:750-757, 902-907` | The real field list; `additionalProperties: false` in the record validator (`record/validator.ex:76`) means a NEW field needs a new definition version (section 9). |
| F5 | Record updates are FULL REPLACEMENT of `field_values` (`Records.update_record`, moduledoc). `update_session_after_submit/4` rebuilds the attribute map by hand from nine named fields. | `session.ex:1252-1278` | Any new session field is silently dropped at submit unless carried forward. The certificate path reads the session AFTER submit, so a dropped snapshot is a functional bug, not a cosmetic one (section 5.4, mutant M3). |
| F6 | Generic READ surfaces: `POST /entities/query`, `POST /entities/query/aggregate`, `POST /entities/records/:type/export`. There is NO generic record GET route (route table in `routers/entities.ex` moduledoc and the `authz_get` list: only definitions and attachments). Restrictions apply by FIELD to every caller without a `user_entity_grants` row, regardless of role (`FieldGrants.load_restrictions/3`). `query` and `export` redact the returned `field_values`; `aggregate` additionally rejects a restricted field named anywhere in the request (403). | `routers/entities.ex:1905-1932, 1957-1995, 2170-2190, 2296` | Section 8. |
| F7 | **The row-query route does not apply the restricted-field refusal that the aggregate route applies.** `run_query/4` redacts returned values but, unlike `check_aggregate_field_restrictions/2` on the aggregate route, does not refuse a request that filters or sorts on a restricted field, so such a request returns restricted data the aggregate route already refuses. Class only; no exploit detail is recorded here (supervisor ruling). The fix was a SEPARATE first prio-1 security PR, PR-0 (#2697), now MERGED, so the dependency is satisfied. | `routers/entities.ex` (`run_query/4`, `run_query_aggregate`) | Scope 4 cannot be "decided and tested" without PR-0 merged; section 8.3 is a dependency statement. |
| F8 | CANDIDATE's permissions are a closed set of six exam permissions (`core_role_allows?(:CANDIDATE, _) -> false`; grants come from the exam manifest only). It holds no `EntitiesQuery`/`EntitiesAggregate`/`EntitiesRecordsExport`. Roles that read generically: PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, TENANT_AUDITOR (query + aggregate), PLATFORM_ADMIN, TENANT_ADMIN. `EntitiesRecordsExportUnredacted` is held ONLY by PLATFORM_ADMIN and TENANT_ADMIN (`priv/permission_matrix/effective.golden:122, 318`). | `authorization.ex`, golden | A pure CANDIDATE cannot read via generic routes; a user with TASK_WORKER (or any generic reader) role can. Restrictions are per user, not per role: admins are redacted too unless granted. |
| F9 | `Exam.on_install/2` seeds four `entity_field_restrictions` rows (`question.explanation`, `answer_option.is_correct`, `likert_weight`, `likert_polarity`), once per install, `on_conflict: :nothing`. Tenants installed before REQ-411 may have none; `Stamp` (GH #2596) never looks at restrictions. | `exam.ex:33-130` | Reconcile step + test for every exam-installed tenant (section 8.5). |
| F10 | `Stamp` judges compatibility against EVERY `entity_definitions` row of a name (every version) and stamps all `managed_by IS NULL` rows. Adding a field creates a NEW definition version and leaves the old row; any old row lacking a pack field makes the name a permanent `shape_not_compatible` conflict. | `stamp.ex:fetch_rows/4, classify_name/4, compatible?/2` | The stamp must judge the ACTIVE row (section 10). |
| F11 | Existing grading failure mode: `Scoring.score_session` returns `{:error, :question_without_correct_option}` and `build_question_row` returns `{:error, {:question_not_found, id}}`; `render_submit/2` maps any unknown error to a logged 500 (`router.ex:512-515`). `render_issue_certificate/2` and `render_download_certificate/2` have the same catch-all. | `scoring.ex:176-195`, `router.ex` | Typed error + its own render clauses (section 7). |
| F12 | Event payloads carry the full new `field_values` for create and update (so the snapshot is in the events row); a delete event carries no field values (`records.ex`, section 17.2 of the 2596 design). The event store moves oversized payloads to `event_payload_store` (INV-EV-5). | `event_store.ex` moduledoc, `records.ex` | Section 11 (what the tamper inventory and a "late" snapshot can and cannot prove). |
| F13 | `create_txn/4` holds `FOR UPDATE` on the `exam` row for the whole eligibility-plus-materialization sequence, so all candidates starting the same exam serialize. `fetch_pool_questions/2` already loads every pool question and all option rows (and discards everything but ids). | `session.ex:281-295, 819-844` | Snapshot data for random-pool questions is free (already loaded); only manual pins need extra reads (section 4.3). |
| F14 | CORRECTED (SECURITY-REVIEWER B1/R1; the earlier claim that no tenant route reads event payloads was WRONG). Record create and update events carry the full `field_values` under a synthetic per-entity-type event instance that `Instances` list, get, history and timeline do not hide, so any caller holding `InstancesRead` (TASK_WORKER, TENANT_AUDITOR and others) can read record content, including the answer key and `exam_snapshot`, through instance history; field redaction does not apply on that path. Class only; no exploit detail. Fix: a separate prio-1 security PR-0b (#2702), now MERGED; it chose option (A), HIDE: synthetic entity-type instances are a 404 on every `Instances` read. The dependency is satisfied. | `Letflow.Instances`, `routers/instances.ex` (changed by merged #2702) | Section 8.4 events row, section 18.1. |

## 1. Acceptance criteria map

| AC (GH #2682 + corrections) | Where satisfied | Tests |
|---|---|---|
| AC1 Edit of exam / question / option correctness / likert weight / likert polarity / passing threshold / certificate flag after start does not change that session's score or certificate; one test per field class | sections 4, 5, 6; field-class list in section 12.1 | T-01..T-14 |
| AC1 correction 1: certificate path is a second live window; issuance reads only the snapshot | section 6 | T-09, T-10, T-11 |
| AC2 Missing threshold or missing answer-key item -> grading error, not 60.0; old fallback removed; BOTH row-error and nil-field cases, each tested | section 7 | T-15..T-20 |
| AC3 In-flight policy implemented and tested for a session created before deploy (conditional on the policy; policy chosen: lazy snapshot at first touch, "late" marker, fail closed on corrupt or unsupported) | section 9 | T-21..T-25 |
| AC4 (PR-0 filter/sort refusal and PR-0b event-payload hiding are MERGED dependencies) Answer-key field restrictions tested; who may read exam/session fields via generic routes decided; record GET routes covered (there are none, F6); event/instance routes covered (F14, 18.1) | section 8 | T-26..T-35, T-30 |
| AC5 Gate: infra stamp does NOT run before this is merged; the PR records the ordering | section 10 | T-36..T-40 |
| AC6 Design validated, SECURITY-REVIEWER and REVIEWER verdicts, standard gates quoted | section 15 | process |
| Correction 2 real session fields | F4, section 4.1 | T-04 (carry-forward) |
| Correction 5 `question_version_id` reuse decision | section 3.5 | n/a (decision) |
| Correction 6 PR split (a) storage + scoring read, (b) certificate + in-flight | section 13 | - |

Section numbering used in this document: 1 AC map, 2 decisions, 3 where it lives, 4 snapshot content and
creation, 5 reads (scoring, autosave, state), 6 certificate path, 7 grading error, 8 answer-key
restrictions, 9 in-flight policy, 10 ordering gate and stamp changes, 11 concurrency, idempotency, events,
12 tests, 13 PR split and files, 14 mutants, 15 gates, 16 open questions and risks.

## 2. Decisions (with reasons; each is binding for ELIXIR-DEV unless an open question says otherwise)

| # | Decision | Reason (short) |
|---|---|---|
| D1 | FULL snapshot of the scoring-relevant data, stored in ONE new optional JSON field `session.exam_snapshot`. No new managed type, no change to `session_question`'s definition. | A hash cannot restore content: authoring rows are edited in place, so hash-plus-versioned-rows would only DETECT a change (fail closed) and never keep the original score. Full snapshot is ~15 KB per 100-question exam (3.3). One field means one definition rollout (one type), one restriction row, one atomic write, and a one-row late snapshot. |
| D2 | Snapshot also carries a SHA-256 digest with a per-snapshot random nonce (rationale restated honestly in 17.3: accident detection only); the digest is verified on every scoring and certificate read. A mismatch is a grading error, never a re-snapshot. | Detects ACCIDENTS only: a partial write, a carry-forward bug, a serializer difference. It does NOT detect a writer who recomputes it (17.3 withdrew the earlier "out-of-band edit" claim). The nonce is defence in depth: if the field's redaction were ever relaxed, the digest would still not be a brute-forceable oracle for the 2^k correct-sets. |
| D3 | `question.stem`, `answer_option.text` stay LIVE (display-only class). `question.type` is snapshotted and read from the snapshot in scoring, autosave and state. | Stem/text do not change any score or certificate; they are legitimately corrected (typos) and snapshotting them per session costs 5-10x the key (3 locales). Stated residual in 3.4. |
| D4 | Late snapshot (in-flight sessions) is built under the session row lock at first touch, `origin: "late"`, only for `in_progress` sessions with NO snapshot. A present-but-bad snapshot is never replaced. | 2596 section 17.5 ruling, confirmed (9). |
| D5 | A submitted session with no snapshot that requests a certificate gets certificate facts taken live ONCE, persisted as `origin: "late_certificate"` (no question items), then served from the snapshot. | Fail-closed would deny certificates to candidates who already passed before the ship day (regression); live-without-marker is untraceable. |
| D6 | Typed grading error `{:grading_error, reason}`; HTTP 500 problem with a stable detail and no reason in the body; transaction rolls back, session stays `in_progress`. | 3.7 / 7. |
| D7 | Ordering gate: BOTH (i) `config :letflow, :exam_snapshot_complete` fail-closed flag with the Stamp refusal, `false` in PR (a), `true` in PR (b), and (ii) per-tenant prerequisites inside `Stamp` (active `session` definition carries `exam_snapshot`; the snapshot restriction rows exist), shipped in PR (b). Stamp dry-run is allowed before. | Section 10. |
| D8 | The row-query restricted-field refusal is a separate first PR (PR-0, ruling); this requirement reconciles restriction rows for every exam-installed tenant. | F7, F9. |
| D9 | Restrict `session.exam_snapshot` by field (new row). Do not add type-level restrictions on `session`/`session_question` in this requirement. | 8.2, open question OQ-5. |

## 3. Where the snapshot lives, and what it costs

### 3.1 Alternatives considered

| Option | Verdict | Reason |
|---|---|---|
| A. New JSON field on `session` (chosen) | chosen | One atomic write at start (the session create already is one `Records` call); late snapshot is one update; one restriction row; the only definition change is on `session`. |
| B. New fields on `session` AND `session_question` (2596 17.1 sketch) | rejected | Needs a definition rollout on two types; a late snapshot would be 1 + N updates (N = questions) under one lock; two places to digest-verify. The key fits in one row. |
| C. New 7th managed runtime type (e.g. `session_snapshot`) | rejected | `Stamp.@stamp_names` and the migration's literal array are frozen at six (`AllowExamManagedByStamp`, test T-10 of 2596); a seventh name means a new migration, new pack entry, new FK/promotion, tamper-inventory change, and still a definition rollout. No gain over A. |
| D. Hash/version only, rows versioned | rejected | Cannot preserve the original outcome (authoring edits replace the Latest row; old content exists only in events). Would convert silent change into fail-closed, not AC1. |
| E. Pack the key into the existing `question_version_id` string | rejected | Encodes structured data in an unvalidated string, still leaves the session-level data (threshold, flags) with no home, and does not remove the need to upgrade `session`. |

### 3.2 Why not "just use the events"

The event for the record at start would reproduce live content, but reading content back from events inside
scoring is a new read path with no index by question, and events may be archived (2596 OQ-7). Rejected.

### 3.3 Size and storage cost

Per question the snapshot holds the question id, the stored type string, the sorted list of correct option
ids, and (likert only) a map option id -> weight (decimal string) and polarity. Option ids that are not
correct are NOT stored. Rough size: a single-choice question with one correct option is about 120-150 bytes
of JSON; a likert question with five options about 450 bytes. A 100-question exam is about 15 KB; a
500-question exam is about 75 KB. The session row is written twice at most (create, then submit; plus one
late snapshot update for in-flight sessions) and each write creates an `events` row with the full payload,
so storage is about 3x the snapshot per session: roughly 45 KB per session for a 100-question exam, about 450
MB for 10 000 sessions. Autosave does NOT write the session row, so autosave cost is unchanged. A hard cap
`Snapshot.max_questions` is NOT added (exam size is already bounded by the authoring side); the build
fails closed with `{:snapshot_error, :too_large}` if the canonical encoding exceeds 2 MB (guards the event
inline limit and row bloat). Payloads over the event store's inline threshold are moved to
`event_payload_store` transparently (INV-EV-5); ELIXIR-DEV quotes the threshold in the PR.

### 3.4 Stem and option text stay live: stated residual

A stem or option text edit during a session is visible mid-exam (it was before; unchanged). Effects are
display only: score, pass/fail and certificate are unaffected because they use ids and the snapshot. An
answer option DELETED after start disappears from the candidate's rendered options (`build_option_states/4`
filters ids missing from the live rows) while its id stays in `options_order` and in the snapshot's correct
set; an option ADDED after start is never shown (not in `options_order`) and never scored. These are
accepted residuals, covered by T-12/T-13, and open question OQ-4 asks whether to snapshot text too (cost
estimate 5-10x the snapshot; default no).

### 3.5 `question_version_id` and `question.version`: not reused

`session_question.question_version_id` stays declared and unused (F4). Reuse as a per-question digest was
considered and rejected: a late snapshot would then need N `session_question` updates, and a second source of
truth would have to agree with the session digest. `question.version` is an author-maintained integer that
is not bumped when an `answer_option` changes, so it cannot version the key. The reuse question of
correction 5 is answered: NOT reused; a follow-up may remove the dead field.

### 3.6 Exam module records not snapshotted (consumed once at start)

`exam_question_rule`, `exam_question_rule_tag`, `exam_manual_question`, `exam_section`, `category`, `tag`,
`question_tag`, `shuffle_questions`, `shuffle_options`, `max_attempts`, `available_from/until`,
`time_limit_minutes` (already frozen into `expires_at`), `status`: read only inside `create_txn` and never
read again for an existing session. The resolved result (which questions, in which order) is frozen by
`session_question` rows plus the snapshot's question set. `exam_manual_question` has no `exam_id`: it names
its exam only through `rule_id` -> `exam_question_rule.exam_id`; the start path already resolves pins through
the rules of THIS exam (`fetch_manual_rules/2`), so a pin on another exam's rule can never enter the set.
Edits to these after start are irrelevant by construction; T-14 documents it with a control test.

## 4. Snapshot content and creation

### 4.1 Stored shape: `session.exam_snapshot` (JSON object, schema version 1)

| Key | Type | Meaning |
|---|---|---|
| `v` | integer | Snapshot format version, `1`. |
| `origin` | string | `"start"` (taken in the create transaction), `"late"` (in-flight session, first touch), `"late_certificate"` (submitted legacy session, certificate facts only). |
| `taken_at` | ISO 8601 string | UTC time the snapshot was built. For `"start"` equal to `session.started_at`. |
| `nonce` | string | 32 hex chars from 16 random bytes (`:crypto.strong_rand_bytes`). Inside the digest. |
| `exam` | object | `exam_id` (string); `passing_score_pct` (DECIMAL STRING in the normalised form of 17.2, such as `"60"` or `"72.5"`); `certificate_enabled` (boolean); `title` (exactly the stored value, a localized-text map or a string); `time_limit_minutes` (integer, informational). |
| `order` | list of strings | Question ids in `sort_order` (random rules first, then manual pins, as materialized). Absent for `"late_certificate"`. |
| `questions` | object | question id -> item. Absent for `"late_certificate"`. |
| `digest` | string | `"sha256:" <> lowercase hex` of the canonical encoding (below) of the object WITHOUT the `digest` key. |

Item (per question): `type` (the stored string: `single`, `multiple`, `truefalse`, `likert`, `shorttext`);
`correct_option_ids` (sorted list of option ids whose `is_correct` is true; empty only for `shorttext`);
`likert_options` (object option id -> `{weight: decimal string, polarity: "positive"|"negative"}`; present
and non-empty only when `type` is `likert`, otherwise `{}`).

Numbers are stored as decimal STRINGS (not JSON numbers) so the digest does not depend on a float or jsonb
numeric round trip. Parsing to float happens at read time with a total parser (a non-parsable string is a
grading error, never a crash).

Canonical encoding (for the digest): objects with keys sorted lexicographically at every level, lists in
stored order, UTF-8, no insignificant whitespace; computed over the DECODED value read back from the row
(jsonb reorders keys, so the digest cannot be taken over the stored text). `Records.canonical_json/1` is
private and is not a canonicalizer; this design adds `Snapshot.canonical_encode/1` (signature below). A
property test round-trips random snapshots through a real jsonb column and re-verifies the digest (T-41).

### 4.2 Public interface: new module `Letflow.Modules.Exam.Snapshot` (pure plus two Repo-reading builders)

| Function | Input | Output | Notes |
|---|---|---|---|
| `build_from_resolved/4` | `exam_fv :: map()`, `items :: %{question_id => question_item_source}`, `order :: [question_id]`, `opts :: %{origin: :start, exam_id: String.t(), taken_at: DateTime.t()}` (D-1) | `{:ok, snapshot()} \| {:error, {:grading_error, reason}}` | Pure. `question_item_source` carries the already-loaded question type and option rows (id, `is_correct`, `likert_weight`, `likert_polarity`). Validates the threshold and each item (7.2) so a bad authoring row fails the START, not the scoring. |
| `build_late/3` | `session :: Latest row` (locked), `prefix`, `now` | `{:ok, snapshot()} \| {:error, {:grading_error, reason}}` | Reads live `exam`, each `question` of the session's `session_question` rows and its `answer_option` rows, `origin: "late"`. Only called by `ensure/3`. |
| `build_certificate_only/3` | `session`, `prefix`, `now` | `{:ok, snapshot()} \| {:error, {:grading_error, :exam_section_missing \| :certificate_facts_missing \| :snapshot_too_large}}` | Live `exam` read, `origin: "late_certificate"`, no `order`/`questions` (full spec in 17.2). |
| `fetch_verified/1` | `session_field_values :: map()` | `{:ok, snapshot()} \| {:error, {:grading_error, :snapshot_missing \| :snapshot_corrupt}}` | Structural validation plus digest verification. Used by scoring and certificate. |
| `fetch_structural/1` | `session_field_values :: map()` | `{:ok, snapshot()} \| {:error, {:grading_error, :snapshot_missing \| :snapshot_corrupt}}` | No digest recompute; used by autosave and state read (hot path). |
| `ensure/3` | `session_id`, `user_id`, `prefix` | `{:ok, snapshot()} \| {:error, ...}` (complete union in 17.2) | The late-snapshot step (9.2). Runs in its own transaction taking `lock_session_row/2`; returns the existing verified snapshot untouched when present. |
| `question_item/2` | `snapshot`, `question_id` | `{:ok, item} \| {:error, {:grading_error, {:question_item_missing, question_id}}}` | |
| `threshold/1` | `snapshot` | `{:ok, float} \| {:error, {:grading_error, :threshold_missing \| :threshold_invalid}}` | Valid range: finite, `0.0 <= x <= 100.0`. |
| `certificate_facts/1` | `snapshot` | `{:ok, %{certificate_enabled: boolean, title: term}} \| {:error, {:grading_error, :certificate_facts_missing}}` | |
| `to_scoring_questions/1` | `snapshot` | `{:ok, [Scoring.question_row()]} \| {:error, {:grading_error, reason}}` | Maps items to the EXISTING `Scoring.question_row()` shape (`question_id`, `type` atom, `correct_option_ids`, `likert_options` weight float / polarity atom); `Scoring` itself is unchanged (it stays pure). |
| `canonical_encode/1` | any decoded JSON term | `binary()` | Sorted keys. |
| `answer_key_fields/0` | none | `[{entity_type, field_name}]` | Not here: stays in `Exam` (8.2). |

Types: `snapshot()` is the decoded map of 4.1 with string keys; `grading_reason()` is the union in section 7.

### 4.3 Creation at session start (`Session.create_with_seed/4` -> `materialize_session/5`)

Order inside the existing create transaction (the `exam` row lock is already held):
1. Preconditions (fail closed before any write): (a) the tenant's ACTIVE `session` definition declares the
   `exam_snapshot` field, (b) the restriction rows for the snapshot field exist (8.2). Failure ->
   `{:error, {:snapshot_error, :definition_missing | :restrictions_missing}}` (HTTP 503, section 7.4).
   Two cheap indexed reads (definitions by name; restrictions by type and field).
2. Existing resolution (`fetch_question_pools`, `QuestionSetResolver.resolve`, manual pins). Change:
   `fetch_pool_questions/2` and `fetch_manual_questions/2` additionally return, per question, the loaded
   question row's `type` and the loaded option rows' `is_correct`, `likert_weight`, `likert_polarity`
   (the option rows are ALREADY queried by `fetch_option_ids/2` and discarded). The random pool path adds
   no query. The manual-pin path adds ONE `Latest.get` of the question (today pins never read the question
   row; a pinned question that is missing or not `active` is a start failure `{:question_not_found, id}` (PR (a) deviation, accepted: rendered as a constant 422 without the id)
   via the existing `{:error, ...}` flow, not a silent skip). Only the questions that end up in the resolved
   set are copied into the snapshot (the pool can be far larger).
3. `Snapshot.build_from_resolved/4` with `origin: :start`. Any invalid item (see 7.2: a non-short-text
   question with no correct option, a likert question with a missing weight or polarity, a missing or
   non-numeric or out-of-range `passing_score_pct`, a type string outside the five) fails the start with
   `{:error, {:grading_error, reason}}` so a broken authoring row is caught at the first candidate instead of
   at submit time.
4. The `session` record is created ONCE with `exam_snapshot` already in `field_values` (same `write_record`
   call as today, `exam_owner()`); then the `session_question` rows (unchanged; `question_version_id` still
   not written). The snapshot and the session therefore appear atomically; there is no state "session
   without snapshot" for sessions created after the ship.

### 4.4 Lock cost

The create lock hold time grows by the manual-pin question reads and the snapshot build (CPU, no extra I/O
for pools). It is bounded by the existing O(pool) option reads that already run under the lock. Risk R-3
records the start-burst concern (all candidates of one exam serialize on the `exam` row lock); the PR body
quotes a measured create time for a 100-question exam before and after.

## 5. Reads after start

### 5.1 Scoring (`score_and_persist/3`, called under `lock_session_row/2` from `submit_txn` and `finalize_txn`)

Replace `build_scoring_inputs/2` + `passing_threshold_for/2` with: `Snapshot.fetch_verified(session.field_values)`
(PR (a): missing -> grading error `:snapshot_missing`; PR (b): missing -> `ensure` first, 9.2) ->
`Snapshot.to_scoring_questions/1` + `Snapshot.threshold/1` -> `Scoring.score_session/3` (unchanged) ->
`persist_scores` and `update_session_after_submit` (carry-forward, 5.4). Answers are still read live from
`session_answer` (they are the candidate's input). No `Latest.get` of `question` or `exam` and no
`answer_option` query remains in the scoring path. `build_question_row/2`, `passing_threshold_for/2` and the
`60.0` literal are deleted (AC2 "the old fallback is removed"; T-19 greps for the literal in `session.ex`).
`Scoring.score_session`'s `{:error, :question_without_correct_option}` is wrapped at the `Session` boundary
as `{:grading_error, {:key_missing, question_id}}`, with the id taken from the snapshot item being scored
(scoring returns only the atom; `to_scoring_questions/1` validates first, so this wrapper is defence in depth).

### 5.2 Autosave (`autosave_answer/4`)

`fetch_question_for_autosave/2` is deleted. After the existing validation chain (non-negative time,
`fetch_session`, `check_owner`, `check_in_progress`, `check_deadline`) the type comes from
`Snapshot.fetch_structural(session.field_values)` + `question_item/2`. A question id not in the snapshot ->
`{:error, :question_not_in_session}` (existing atom; the existing `fetch_session_question` check stays and
runs first). `check_options_belong` keeps using `session_question.options_order`. Ownership and
`in_progress` precede any snapshot write (a non-owner can never trigger a late snapshot; mutant M9). When the
snapshot is absent (PR (b)): `Snapshot.ensure/3`, then continue. When structurally corrupt: `{:error,
{:grading_error, :snapshot_corrupt}}` -> HTTP 500 (7.4).

### 5.3 Candidate state read (`get_session_state_for_user/3`)

`build_question_state/2` takes `type` from the snapshot item (in-progress sessions; terminal sessions per 17.1), not from the live question. `stem` and option
`text` stay live (D3). The live `Latest.get(question)` remains for the stem; a missing live question keeps the
existing `{:question_not_found, id}` error. The hand-selected response shape does not change and must never
include any `exam_snapshot` content (8.4). The snapshot-absent case depends on status (17.1, binding): for an `in_progress` session it is the same `ensure`
as 5.2 (PR (b); PR (a) returns `{:grading_error, :snapshot_missing}`), which makes a candidate GET perform one
write for a legacy session, once; for a terminal session (`submitted`, `auto_submitted`, `grading_pending`) there
is NO `ensure`, no write and no error: the type comes from the snapshot item when present, else from the live
question as display data only. A snapshot without question items (`late_certificate`) or a corrupt one on a
terminal session also falls back to the live type.

### 5.4 Carry-forward at submit (the F5 hazard)

`update_session_after_submit/4` builds its attribute map from the locked session's `field_values` merged with
the six changed keys (`status`, `submitted_at`, `score_pct`, `passed`, and the unchanged identity fields), so
that `exam_snapshot` (and any future field) is preserved byte-identical. Invariant I-1: for every session,
the decoded `exam_snapshot` after any later write equals the one written first, except the single
permitted transition `late_certificate` facts added to an `exam_snapshot` that did not exist (never an
overwrite). T-04 asserts digest-equality before and after submit; mutant M3 removes the merge.

## 6. Certificate path (PR (b))

`Certificate.issue_or_get_for_user/3` keeps guard order 1-6 of its moduledoc. Changes:
- `fetch_exam/2` and `check_certificate_enabled(exam)` are replaced by `Session.get_snapshot_for_user/3`
  (new, returns the VERIFIED snapshot for the owner's session: `{:ok, snapshot()} \| {:error,
  session_not_found \| not_owner \| {:grading_error, reason}}`) followed by `Snapshot.certificate_facts/1`.
  `check_certificate_enabled/1` reads `certificate_enabled` from the facts; `issue_or_fetch/4` writes
  `exam_title` from the facts. The certificate module no longer calls `Latest.get(exam)` anywhere.
- `session_view/1` is NOT extended with snapshot data (candidate-facing; 8.4).
- Legacy submitted session (no snapshot) that reaches guard 4: `Session.get_snapshot_for_user/3` delegates to `Snapshot.ensure_certificate_facts/3`
  (spec in 17.2; same row lock, same transaction pattern as `ensure/3`) writes `origin: "late_certificate"` from the live
  exam and returns it (D5); `grading_pending` and non-submitted sessions are refused by guards 2-3 before
  this point and never get a snapshot written.
- A `{:grading_error, _}` from the facts read renders HTTP 500 with the stable detail (7.4) in BOTH
  `render_issue_certificate/2` and `render_download_certificate/2`; `Certificate.issue_error/0` gains
  `{:grading_error, grading_reason()}` and the ISS-0676 "every issue_error renders its own response" test
  gets the new case. The idempotency key `"certificate:issue:" <> session_id` is unchanged, so the first
  issuance stays the only one and replays return the stored record.
- The certificate record already stores `exam_title`, `score_pct`, `candidate_name`, `branding_snapshot`;
  after issuance nothing is re-read (unchanged).

## 7. Grading error: type, reasons, surfacing

### 7.1 Type

`{:grading_error, grading_reason()}` returned as `{:error, {:grading_error, reason}}` by `Snapshot.*`,
`Session.submit/3`, `Session.finalize_expired/3`, `Session.create/3` (start), `Session.autosave_answer/4`,
`Session.get_session_state_for_user/3`, `Session.get_snapshot_for_user/3` and `Certificate.*`. It is a tagged
tuple (the module's existing error idiom), documented in `Snapshot`'s moduledoc and added to
`Session.submit_error`/`autosave_error` unions and to `Certificate.issue_error`.

### 7.2 `grading_reason()` (atoms and ids only, never values)

| Reason | When |
|---|---|
| `:snapshot_missing` | No `exam_snapshot` on the session and no permitted late path (PR (a): any snapshotless session; PR (b): only when the late path is not allowed). |
| `:snapshot_corrupt` | Not an object, wrong `v`, wrong shape, or digest mismatch. |
| `:threshold_missing` | `exam.passing_score_pct` absent or nil (replaces the FunctionClauseError path of F3). |
| `:threshold_invalid` | Not a parsable decimal string, non-finite, below 0 or above 100. |
| `:exam_section_missing` | The `exam` object is absent from the snapshot (replaces the "exam row lookup error -> 60.0" path of F3). |
| `{:question_item_missing, question_id}` | An id in `order` has no entry in `questions`. |
| `:snapshot_item_missing` | PR (a), accepted deviation: scoring finds no snapshot item for a `session_question` row (the scoring path iterates the session's rows); returned as `{:grading_error, :snapshot_item_missing}`. |
| `{:question_type_invalid, question_id}` | `type` not one of the five strings. |
| `{:key_missing, question_id}` | The key rule, matching what `Scoring` does (D-2, binding): `single`, `multiple` and `truefalse` need a non-empty `correct_option_ids`; `likert` has NO correct option (Scoring scores it by weight) and needs a complete, non-empty `likert_options` map with a parsable weight and a `positive`/`negative` polarity for EVERY option; `shorttext` needs neither. Violations are `{:key_missing, id}`. |
| `:certificate_facts_missing` | `exam.certificate_enabled` not a boolean, or `title` absent. |
| `:snapshot_too_large` | Canonical encoding over 2 MB (start/late build). |

### 7.3 Behaviour on error

Scoring, submit and finalize run inside `Repo.transaction`, and `Repo.rollback` already follows any
`{:error, _}` (`submit_txn`, `finalize_txn`): nothing is persisted, `session.status` stays `in_progress`, no
`session_question_score` rows exist. The deadline is NOT extended; the periodic finalize sweep retries and
logs each time. A failed start creates no session. A failed late snapshot writes nothing and leaves the
session as it was.

### 7.4 Surfacing (HTTP and logs)

| Route | Error | Response |
|---|---|---|
| `POST /exam-sessions/:id/submit` | `{:grading_error, _}` | 500 problem, detail `"exam grading failed; the session was not scored"`. |
| `POST /exam-sessions` (start) | `{:grading_error, _}` | 500, detail `"exam content is invalid; the session was not started"`. |
| start, autosave, state, submit, certificate | `{:snapshot_error, :definition_missing \| :restrictions_missing \| :audit_failed \| :write_failed}` (rollout not run, or a late-snapshot audit or write failed) | 503 problem (`Error.service_unavailable/1` through `Response.send_problem/2`; `Response` has no helper, add `Response.service_unavailable/2`), detail `"exam service is being upgraded; retry shortly"`. |
| `POST .../certificate`, `GET .../certificate/download` | `{:grading_error, _}` | 500, same stable detail as submit-class errors. |

The body never contains the reason, ids, or values (INV-4/INV-5); each handler logs `Logger.error` with the
reason tag, the session id and the tenant prefix (ids are not secrets; values are never logged). Each of the
above gets its own `render_*` clause BEFORE the catch-all, plus the ISS-0676-style test (T-20). Alerting on
grading errors is deferred to the F-ALERT/REQ-512 work (alert channel OQ-10 of the 2596 design); this design
only makes the failure typed, logged at error level and non-silent.

## 8. Answer-key field restrictions (scope 4)

### 8.1 Decisions on who may read what through the generic routes

| Entity.field | Decision | Why |
|---|---|---|
| `session.exam_snapshot` (NEW) | RESTRICTED by field (row in `entity_field_restrictions`) for every user without a `user_entity_grants` row, all roles. | Contains the answer key and per-session nonce. |
| `answer_option.is_correct`, `likert_weight`, `likert_polarity`, `question.explanation` | Unchanged: restricted. Reconciled for every exam-installed tenant (8.5). | Existing ISS-0647 rows. |
| `exam.*` (title, threshold, certificate flag, window, attempts) | NOT restricted. | Not secret: the candidate sees the title and window via `list_available_exams`; the threshold is a published requirement of the exam. Restricting would break authoring screens for no gain. |
| `session.*` other fields, `session_question`, `session_answer`, `session_question_score`, `certificate` | NOT restricted by this requirement. | These are other candidates' results (privacy of results, not the answer key). Whether to hide them from TASK_WORKER-class readers is a separate product decision (OQ-5); recommendation: file a follow-up for `entity_type_restrictions` on the five runtime types. Noted so the supervisor can decide; it does not block the snapshot. |
| `session_question.question_version_id` | Unused, not restricted. | Holds nothing. |
| Unredacted export (`EntitiesRecordsExportUnredacted`) | Stays PLATFORM_ADMIN and TENANT_ADMIN only (golden). | They already author and can read the key; the snapshot adds no new knowledge to them beyond which questions each candidate received (already in `session_question`). |

### 8.2 Seeding: `Exam.answer_key_fields/0` grows to five pairs

Add `{"session", "exam_snapshot"}` to `@answer_key_fields` (and nothing else), so `on_install/2` seeds it for
fresh installs and the reconcile step (8.5) seeds it for existing ones. The test `on_install_test.exs`
literal list is updated. `Exam.answer_key_fields/0` is the single source for the install seed, the reconcile
step, the start-time precondition (4.3 step 1) and the Stamp prerequisite (10).

### 8.3 Restricted-field refusal on the row-query and export routes: moved to PR-0 (dependency)

Status: MERGED as PR-0 (#2697); this section is now a satisfied dependency. Supervisor ruling (historical): the fix (a request that filters or sorts on a restricted field, on `POST /entities/query`
plain and join, and on default-redacted export, is refused with the same 403 and constant body the aggregate
route already uses) is its OWN first prio-1 security PR, PR-0, with its own issue and its own reproducing and
regression tests. It is NOT part of PR (a) or (b). REQ-511 depends on PR-0 for AC4. Design constraint kept:
PR-0's rule uses the same restriction sets (`FieldGrants.load_restrictions/3`) as the snapshot field
restriction, so adding `{"session","exam_snapshot"}` needs no further router change. Tests T-31 and T-32 are
owned by PR-0, not by this requirement's test list.

### 8.4 Candidate-facing leak analysis (INV-2, INV-5)

Every path that can return a `session` record or snapshot content, and why a candidate cannot read the key:

| Path | Who | Why safe |
|---|---|---|
| Exam routes (`POST /exam-sessions`, `GET /exam-sessions/:id`, submit, autosave, certificate) | CANDIDATE | Responses are hand-built maps (`session_view/1`, `question_state/0`, `submission_outcome/0`, `certificate_view/0`). None includes `exam_snapshot`. T-30 serializes every response of a full flow and asserts no snapshot key, no nonce, no digest and no correct-option flag appears. |
| `POST /entities/query`, `/aggregate`, `/export` | roles in F8 | CANDIDATE has none of these permissions (closed set, golden matrix; T-29 asserts the CANDIDATE row of the golden has no generic read permission for these three). Others get the sentinel `:__field_redacted__` (query, join, export-default); `exam_snapshot` is a non-queried JSON field so it cannot be filtered, sorted, grouped or aggregated; the oracle on queried restricted fields is closed by PR-0 refusal. A user holding both TASK_WORKER and CANDIDATE is covered by the per-user restriction (T-26). |
| Join query with `session` as primary or joined entity | readers | `redact_joined_page/2` redacts each exposed entity with its own set; T-27 joins `session_question` to `session` and asserts redaction. |
| Unredacted export | PLATFORM_ADMIN, TENANT_ADMIN | Intended (8.1). |
| Script and step reads (`ScriptReads`) | process authors | `restricted_fields/2` omits every restricted field including `exam_snapshot` after seeding (T-28). |
| Event payloads (create/update events carry full `field_values`; read through instance history/timeline under a synthetic entity-type instance) | callers holding `InstancesRead` | NOT safe today (F14 corrected): closed by PR-0b (18.1), a dependency of this requirement. After PR-0b a synthetic entity-type instance is a 404 on every `Instances` read exactly like a nonexistent instance (or, if PR-0b's designer chooses, event `field_values` are redacted per user by `FieldGrants`); T-30 proves the snapshot appears on no instance route. |
| Public certificate projection | public | Reads the certificate record only (unchanged). |

SECURITY-REVIEWER checklist items (not asserted by this design): (1) enumerate EVERY route that returns event payloads (instances list/get/history/timeline, audit, promotions platform-events, public-read, any export) and confirm each is either scoped away from entity-type instances or redacts restricted fields; (2) enumerate any tenant export/backup path
that dumps `entity_record_latest` or `events` rows and confirm it is admin-scoped.

### 8.5 Tenants installed before REQ-411 and the "every exam-installed tenant" test

`Exam.on_install/2` runs once, so existing tenants can lack rows. The rollout task (9.3) runs an idempotent
`ensure_answer_key_restrictions(prefix)` that inserts any of the five pairs not present (same
`on_conflict: :nothing` insert) and reports the count. Test T-33: for every tenant that has the `exam`
module installed in the test database (fixtures create several, including one built to look pre-REQ-411 with
zero rows), after `on_install` or the reconcile step all five pairs exist. T-34: the reconcile step is
idempotent. T-35: the Stamp prerequisite refuses a tenant lacking any row (10).

## 9. In-flight policy (PR (b)); confirms 2596 section 17.5 with two additions

### 9.1 Policy

Sessions that are `in_progress` and have no `exam_snapshot` when the snapshot code is live get one at their
NEXT TOUCH, built from the live authoring rows under the session row lock, stored with `origin: "late"` and
`taken_at`. Touches: state read of an `in_progress` session, autosave, submit, deadline auto-submit (`finalize_expired`); a state read of a terminal session is not a touch (17.1). Scoring always
goes through `ensure` first, so no scoring path ever reads live authoring rows after the ship. Not touched:
`submitted`, `auto_submitted`, `grading_pending` (already scored; nothing to snapshot) except the certificate
facts case (D5). Reasons are exactly those of 17.5 (every scoring path is a touch; no bulk backfill tool;
narrowest exposure window; the `"late"` marker lets the report list which sessions were snapshotted from live
data). Honest limit, unchanged: a late snapshot cannot undo an edit made before the touch; those sessions
keep the residual risk until they drain (they are time-boxed by `expires_at`).

Additions to the ruling:
- A snapshot that is PRESENT but corrupt is never replaced by a late one (`:snapshot_corrupt`, fail closed).
  Otherwise an attacker could reset the key by damaging the snapshot.
- If the late build cannot produce a valid snapshot (live threshold missing or invalid, a question without a
  correct option, a question row missing) the touch fails with the typed grading error. No fallback value
  is ever used. The candidate cannot submit; the sweep retries and logs. This is the explicit "fail closed"
  half of the issue's alternative, applied exactly where the live data is broken.

### 9.2 `Snapshot.ensure/3` behaviour (exact)

1. Preconditions in this order (R6): (i) ownership, FIRST: the caller already checked ownership and `in_progress`
   (autosave, state) or holds the locked row of an owner-checked submit or the system finalize; `ensure/3` and
   `ensure_certificate_facts/3` check ownership right after taking the row lock and BEFORE anything else; a
   non-owner gets exactly the not-found response of a nonexistent session (same status and bytes) and never a 503,
   never a prerequisite probe; (ii) only then the definition and restriction prerequisites (else
   `{:snapshot_error, ...}`, 503); (iii) the cutover rule of 18.5.
2. Open a transaction (or join the caller's), `lock_session_row/2`, re-read `field_values`.
3. If `exam_snapshot` present: return `fetch_verified` of it (no write). If absent and status is not
   `in_progress`: return `{:error, {:grading_error, :snapshot_missing}}` WITHOUT writing (certificate-facts case has its own
   function; the candidate state read of a terminal session never calls `ensure`, see 17.1). If absent and `in_progress`: `build_late`; then, for `ensure/3`, `Records.update_record` through `exam_owner()` immediately (for the submit and finalize paths `ensure_locked/2` only builds and the single session update of the caller persists it, see 17.2)
   with `field_values = Map.merge(locked.field_values, %{"exam_snapshot" => snapshot})`, fresh idempotency
   key. Emit one `Logger.info` with session id and `origin: late` (the persistent marker is the field itself).
4. Return the snapshot.

### 9.3 Rollout and the deploy gap (OQ-1 RESOLVED by ruling)

Existing tenants have no `exam_snapshot` field in their active `session` definition and
`additionalProperties: false` rejects it, so the code needs a definition rollout (section 10.3). Between the
deploy of PR (a) and the rollout, start and touches of snapshotless sessions return 503 `snapshot_error` (fail
closed, nothing mis-graded); autosave is an idempotent upsert, so a client retry after the rollout succeeds.
Ruling: the short 503 window on QA/BilimBaga is ACCEPTED; the rollout runs immediately after the PR (a) deploy
by the usual infra request, announced up front to letflow-2 (UAT); who, when and the verification command are in
17.5. No rollout-before-code variant is designed.

## 10. Ordering gate and `Stamp` changes (flag refusal in PR (a); prerequisites and compat in PR (b))

### 10.1 Choice

Two layers in `Letflow.Entities.ManagedTypes.Stamp`; they ship in DIFFERENT PRs (same split as 13 and 17.2):

1. **Flag (global, fail closed), PR (a).** `Application.get_env(:letflow, :exam_snapshot_complete, false)`; set to
   `false` explicitly in `config/config.exs` by PR (a) and to `true` by PR (b) (a one-line diff the PR body
   quotes). `config/test.exs` sets `true` so existing stamp tests keep passing; the gate test overrides it with
   `put_env(false)` and restores (non-async). A real (non-dry-run) `Stamp.run/1` or `run_tenant/2` returns
   `{:error, :snapshot_not_complete}` / a tenant report with `status: :snapshot_not_complete` and stamps
   nothing. `dry_run: true` is allowed before (2596 17.5: inventory and dry-run may run earlier). Because the
   refusal exists from PR (a), there is no window between the PRs in which a stamp can run.
2. **Per-tenant prerequisites (data), PR (b).** With the flag true, a tenant is stamped only if (i) its ACTIVE
   `session` definition declares `exam_snapshot` (type json) and (ii) all five `Exam.answer_key_fields()`
   restriction rows exist. Otherwise the tenant report gets `status: :snapshot_prerequisite_missing` and a new
   report key `prerequisites_missing :: [:session_definition | :answer_key_restrictions]`; nothing is stamped
   for it; other tenants continue.

Why both: the flag records "the code that reads only the snapshot has shipped" (covers every moment before PR
(b), which no tenant data can); the prerequisites record "this tenant has been rolled out" (covers a tenant the
rollout missed, a restored backup, a late-created tenant) and take over once the flag is true. A flag alone
passes a never-rolled-out tenant; data alone cannot cover the time before PR (b) is merged. Alternative
rejected: "release checklist only" (not testable, and the 2596 design already relies on a human not forgetting
a step).

### 10.2 Stamp compatibility change (F10)

`fetch_rows/4` also selects `status` and `inserted_at`; `classify_name/4` judges `compatible?/2` against the
ACTIVE row of the name (when none is active, the newest by `inserted_at`), not every row. Stamping still
covers every `managed_by IS NULL` row of the name (old inactive versions included). The `exam_snapshot` pack
field participates in `compatible?/2` automatically (it is in `pack.json`), so an un-upgraded active
`session` row yields the existing `shape_not_compatible` conflict, which the prerequisite check above (PR (b)) reports
more precisely first. The active-row change ships in PR (b) with the prerequisites. `Letflow.Release.ManagedTypes` and the Mix task report the two new statuses; the
tamper inventory is unchanged.

### 10.3a File layout and the boundary rule (D-4, binding)

Boundary rule 5 forbids code outside `lib/letflow/modules/exam/**` from referencing that tree. So
`Letflow.Release.ExamSnapshot` (in `lib/letflow/release/`) does NOT name `Letflow.Modules.Exam.*`; like `Stamp` it
reaches the exam code through `Catalog.fetch("exam")` and calls two delegates on the exam module:
`Exam.snapshot_rollout(opts)` (runs `Snapshot.Rollout.run/1`) and `Exam.snapshot_verify()` (runs
`Snapshot.Rollout.verify/0`, where `verify/0` lives). `Letflow.Release.ExamSnapshot.rollout/1` and `verify/0`
are thin wrappers over those delegates; their specs in 17.2 are unchanged. The mix task calls the release
wrapper.

### 10.3 Rollout: `Letflow.Modules.Exam.Snapshot.Rollout` (core) + `Letflow.Release.ExamSnapshot` + `mix letflow.exam_snapshot_rollout`

Same pattern as the Stamp (`Backfill`-style, per tenant, one transaction per tenant, none across tenants, a
per-tenant failure recorded as a tag and the sweep continues, `--dry-run`, idempotent):

| Step per tenant | Behaviour |
|---|---|
| 1 | `exam` not installed -> `:exam_not_installed`, skip. |
| 2 | Active `session` definition has `exam_snapshot` of type json -> `definition: :already_current`. |
| 3 | Absent, type `session` unmanaged -> create a new definition version = the tenant's ACTIVE definition_json plus the field `exam_snapshot` (json, `required: false`, `queried: false`), through `Definitions.create_definition/3` and `activate_definition/4` ONLY (never a direct insert or update of `entity_definitions`; `tenant_id` comes from `tenant_id_for_schema_name/1` of the prefix; the new version must differ from the previous active one by exactly the added field, T-37) (derived from the tenant's own active definition, NOT the pack's, because existing rows are FK-stripped and hand-posted, F9 of the 2596 design). A field of that name with another type -> `conflict: :exam_snapshot_field_conflict`, nothing written. |
| 4 | `session` already managed (stamped) and lacking the field -> `definition: :managed_cannot_upgrade`; reported, not touched (the stamp gate makes this unreachable in the normal order). |
| 5 | `ensure_answer_key_restrictions(prefix)`: insert missing pairs of `Exam.answer_key_fields()`. |

Report per tenant: `definition` status, `restrictions_added` count, `error` tag. Actor and audit for the
definition write: OQ-2 (the Stamp wrote an audit entry with `actor_id: nil`; ELIXIR-DEV verifies
`create_definition` accepts a platform actor and quotes it; if not, the task uses the first
PLATFORM_ADMIN-scoped system user the way other release tasks do). Verification obligation, flagged OQ-9: that
activating a new version that only adds an optional NON-queried JSON field needs no DDL or column promotion
on the promoted `session` table; ELIXIR-DEV proves it with a test on a promoted tenant (T-37) before relying
on it.

Fresh installs: `priv/modules/exam/entity_definitions/session.json` gains the field, `generate_pack.exs`
regenerates `pack.json`, the drift guard test and the pack-field tests (10 -> same count, field list
changed) are updated. The `description` of `session.json` gets one sentence for `exam_snapshot`.

## 11. Concurrency, idempotency, events

- Create: snapshot is built and written inside the existing create transaction under the `exam` row lock;
  atomic with the session. No retry path (create has no idempotency today; unchanged).
- Submit/finalize: unchanged lock on the session row; snapshot read from the locked row; second submit
  returns the recorded outcome without reading the snapshot.
- Late snapshot: serialized by `lock_session_row/2`; the second concurrent toucher sees the snapshot and does
  not write. Invariant I-2: the snapshot is written at most once per session (plus the one-time
  `late_certificate` case on a snapshotless session). T-24 runs two concurrent autosaves on a legacy session
  and asserts exactly one `ENTITY_RECORD_UPDATED` event adds `exam_snapshot`.
- Autosave does not take the session lock and does not write the session row (unchanged); it only reads the
  snapshot out of the `Latest` row it already fetches (no extra query).
- Events: the create event and each update event carry `exam_snapshot` in full. The tamper inventory
  (2596 section 8) reads ids and names, never values, and is unchanged. For the future F-ALERT/REQ-512
  report, the snapshot makes "which sessions were snapshotted from live data after an authoring edit may
  have happened" a field read (`origin == "late"` and `taken_at`). A DELETE event carries no field values, so
  evidence about a deleted authoring row's content at the time comes only from its earlier create/update
  events; this requirement does not depend on it: a deleted option or question after start cannot change a
  snapshotted score (T-13), and the `session_question.question_id` FK is RESTRICT.

## 12. Tests

### 12.1 Field classes (AC1: one test per class; "after start" = edit between start and first scoring)

| Id | Class | Test (all assert the session's `score_pct`, `passed`, status; certificate classes assert issuance) |
|---|---|---|
| T-01 | `answer_option.is_correct` | Flip correct to wrong and vice versa after start; scored as at start. Fails on main. |
| T-02 | `answer_option.likert_weight` | Change weights after start; likert score unchanged. |
| T-03 | `answer_option.likert_polarity` | Flip polarity after start; unchanged. |
| T-04 | `exam.passing_score_pct` | Raise above/lower below the session's percentage after start; `passed` as at start. Also asserts the carry-forward (digest equal before/after submit, I-1). |
| T-05 | `question.type` (scoring) | Change `single` -> `multiple` after start; scored under the start type. |
| T-06 | `question.type` (autosave shape) | After a live type edit, autosave validates against the snapshot type (a two-option answer to a `single` question stays rejected). |
| T-07 | `question.type` (state) | State read shows the snapshot type. |
| T-08 | `exam` row deleted or `status` archived after start | Scoring still works from the snapshot (this was the `60.0` row-error path). |
| T-09 | `exam.certificate_enabled` | Enabled at start, disabled after submit (and before the certificate request): certificate issued. Disabled at start, enabled later: refused `exam_not_certifiable`. |
| T-10 | `exam.title` | Title edited after start: the certificate's `exam_title` is the snapshot title. |
| T-11 | Certificate path reads no live exam | With the live exam row deleted after submit, issuance still succeeds (PR (b)). |
| T-12 | Display-only class (stem, option text) | Edits are visible live in the state read; score unchanged (documents D3). |
| T-13 | Option added / deleted after start | Deleted correct option still counts for the candidate who selected it; added correct option is ignored; no crash. |
| T-14 | Start-time-only inputs (rule, tag rule, manual pin, section, shuffle flags, `max_attempts`, window) | Control: edit after start; score and question set unchanged. |

### 12.2 Grading error (AC2)

| Id | Test |
|---|---|
| T-15 | Snapshot with `exam.passing_score_pct` absent -> `{:error, {:grading_error, :threshold_missing}}`; session stays `in_progress`, no score rows (replaces the nil/FunctionClauseError path). |
| T-16 | Snapshot with no `exam` object -> `:exam_section_missing` (replaces the row-error/`60.0` path). |
| T-17 | Question in `order` with no `questions` entry -> `{:question_item_missing, id}`; `single`, `multiple` and `truefalse` with empty `correct_option_ids` -> `{:key_missing, id}`; `likert` with an empty `likert_options`, or any option missing weight or polarity, or an unparsable weight -> `{:key_missing, id}`; a `likert` question with NO correct option and a complete map is VALID; a `shorttext` question with neither is VALID. |
| T-18 | Digest mismatch (field tampered in the row) -> `:snapshot_corrupt`; and a corrupt snapshot is NOT replaced by a late snapshot. |
| T-19 | Source guard: no `60.0` literal and no `passing_threshold_for` in `lib/letflow/modules/exam/session.ex` (grep-style test). |
| T-20 | Router: each reason renders the 500 problem with the stable detail and no reason text; submit, start, certificate and download each have a test (ISS-0676 pattern); the 503 `snapshot_error` case renders 503. |
| T-42 | Start with a live exam whose `passing_score_pct` is nil/invalid, or a question with no correct option, fails the START with the typed error and creates no session or session_question rows. |

### 12.3 In-flight (AC3, PR (b))

| Id | Test |
|---|---|
| T-21 | Legacy session (created by a fixture that omits `exam_snapshot`, started "before deploy") touched by autosave -> snapshot written, `origin: "late"`, `taken_at` set; a later authoring edit does not change the score. |
| T-22 | Legacy session submitted with no earlier touch: submit takes the late snapshot under the lock and scores from it; marker present. |
| T-23 | Deadline auto-submit (`finalize_expired`) of a legacy session behaves as T-22 with status `auto_submitted`. |
| T-24 | Two concurrent touches of a legacy session produce exactly one snapshot write (I-2). |
| T-25 | Legacy session in a tenant whose `session` definition lacks the field -> 503-class `{:snapshot_error, :definition_missing}`, nothing graded or written; after the rollout the same call succeeds. Also: legacy submitted+passed session requests a certificate -> `late_certificate` facts persisted once, certificate issued; second request does not re-snapshot. |

### 12.4 Restrictions and leak (AC4)

| Id | Test |
|---|---|
| T-26 | A TASK_WORKER (and a user holding TASK_WORKER plus CANDIDATE) querying `session` gets `exam_snapshot` as the sentinel; unrestricted fields stay readable. |
| T-27 | Joined query (`session_question` joined to `session`, and `session` primary) redacts `exam_snapshot`. |
| T-28 | `ScriptReads` omits `exam_snapshot` for a process script reading a session. |
| T-29 | Golden: the CANDIDATE row has no `EntitiesQuery`, `EntitiesAggregate`, `EntitiesRecordsExport` (asserts against `effective.golden`/`Authorization.role_allows?`). |
| T-30 | Full candidate flow (start, state, autosave, submit, certificate, download) serialized, then probes with a TASK_WORKER, a TENANT_AUDITOR and a TENANT_ADMIN token (PR-0b is merged): (1) `GET` instances list/get/history/timeline for the session's synthetic entity-type instance id AND for an `answer_option` synthetic id each return a 404 byte-identical to the 404 of a random uuid (status and body); (2) `POST /entities/query` (plain, join), `/aggregate`, `/export` (default) show `exam_snapshot` only as the redaction sentinel or not at all; (3) the audit entries read route (`AuditRead`), `GET /promotions/platform-events`, `ScriptReads` (a script reading a session) and the entity port (`StepWrites`/`HandlerWrites` read paths) return no snapshot content; (4) the `PUT`/`POST /entities/records/session` response (and its error bodies) never echoes a PRIOR `exam_snapshot` (it returns what the caller sent); (5) the public certificate projection. In every body `exam_snapshot`, its `nonce`, its `digest`, `correct_option_ids` and `is_correct` flags are absent. The route list is closed by the 8.4 enumeration; a test fails if the enumeration finds a route not in the probe list. |
| T-31 | OWNED BY PR-0: a request that filters or sorts on a restricted field (plain, join, export default) is refused 403 with the aggregate's constant body; RED on main before the fix; unredacted export by an admin still works. |
| T-32 | OWNED BY PR-0: unrestricted filter/sort still works; the aggregate refusal is unchanged. |
| T-33 | For every exam-installed tenant in the test DB, all five `answer_key_fields` rows exist (fresh install via `on_install`; pre-REQ-411-style tenant with zero rows after the rollout reconcile). |
| T-34 | Reconcile is idempotent (second run adds 0). |
| T-35 | Start refuses (503 `restrictions_missing`) when the snapshot restriction row is absent. |

### 12.5 Gate (AC5) and misc

| Id | Test |
|---|---|
| T-36 | Flag false: EVERY stamp entry point refuses a real run: `Stamp.run/1` -> `{:error, :snapshot_not_complete}`; `Stamp.run_tenant/2` -> report `status: :snapshot_not_complete`; `Letflow.Release.ManagedTypes.stamp/1`; the mix task `letflow.stamp_managed_types` (non-zero exit). Zero rows stamped, no audit entry. `dry_run: true` still returns a report on each. A source test asserts `:exam_snapshot_complete` is set ONLY in `config/config.exs` (false) and `config/test.exs` (true) and is never read from `System.get_env`, `runtime.exs` or `Application.put_env` in `lib/`. |
| T-37 | Rollout on a promoted tenant: adds `exam_snapshot` as a new active version through `Definitions.create_definition/3` and `activate_definition/4`; the new definition differs from the tenant's previous active one by EXACTLY the added `exam_snapshot` field (field-by-field diff test: every other field, FK, index, constraint equal); no DDL error; a session create then works; second run is `already_current`; a source test asserts the Rollout module contains no direct `Repo.insert`/`insert_all` into `entity_definitions`. |
| T-38 | Flag true, tenant with un-upgraded active `session` definition -> `status: :snapshot_prerequisite_missing`, `prerequisites_missing: [:session_definition]`, nothing stamped; after the rollout it stamps. |
| T-39 | Flag true, tenant lacking a restriction row -> `[:answer_key_restrictions]`; stamping blocked until reconciled. |
| T-40 | Stamp judges the ACTIVE row: tenant with old `session` version (no field, inactive) plus new active version (field) is stampable; all rows get `managed_by`. |
| T-41 | Property: random snapshots round-trip a real jsonb column and re-verify the digest; weights such as `"0.1"`, `"3.5"` and the normalised threshold `"60"` stay byte-stable (decimal strings per 17.2). |

Existing tests that must be updated: `pack_install_test.exs` (field counts/drift), `on_install_test.exs`
(five pairs), `entities_answer_key_field_leak_test.exs` (row-query cases belong to PR-0), `stamp_test.exs`
(prereqs, flag set true in `test.exs`), `exam_fixtures.ex` (definitions now carry the field),
`certificate_test.exs` and `session_test.exs` (live-edit expectations flip), `exam_sessions_test.exs`
(ISS-0676 render cases).

## 13. PR split and files

| PR | Contents | Files |
|---|---|---|
| PR-0 (#2697, MERGED; outside this requirement's PR count) | Restricted-field refusal on row query (plain, join) and default export (8.3). Own issue (letflow-2), own tests. | `lib/letflow/routers/entities.ex` |
| PR-0b (#2702, MERGED; outside this requirement's PR count) | Chose HIDE: synthetic entity-type instances are a 404 on `Instances` reads, as a nonexistent instance (18.1). | `lib/letflow/routers/instances.ex` and its context (as merged) |
| (a) storage + scoring read + restrictions seed + gate flag | `Snapshot` module (build_from_resolved, fetch_*, threshold, to_scoring_questions, canonical_encode, digest); `session.json` + `pack.json` + `generate_pack.exs`; `Exam.answer_key_fields` +1; create writes the snapshot; scoring, autosave, state read the snapshot (snapshotless -> grading error `:snapshot_missing`, no late path yet); `60.0` and `passing_threshold_for` removed; carry-forward; typed error + router clauses for submit/start/503; rollout task + reconcile; `Stamp` flag REFUSAL (real run refused while the flag is false; this closes the gate) and the config flag `false`. | `lib/letflow/modules/exam/{snapshot.ex (new), session.ex, exam.ex, router.ex}`, `lib/letflow/entities/managed_types/stamp.ex`, `lib/letflow/release/managed_types.ex` (widen `stamp/1` `@spec` to `{:ok, Stamp.report()} | {:error, :unsupported_module | :snapshot_not_complete}`), `lib/mix/tasks/letflow.stamp_managed_types.ex` (new clause for `{:error, :snapshot_not_complete}` and the gate exit mapping below), `lib/letflow/modules/exam/snapshot/rollout.ex`, `lib/letflow/release/exam_snapshot.ex`, `lib/mix/tasks/letflow.exam_snapshot_rollout.ex`, `lib/letflow/api/response.ex` (503 helper), `priv/modules/exam/**`, `config/config.exs`, `config/test.exs`, tests |
| (b) certificate + in-flight + Stamp prerequisites | `Stamp` per-tenant prerequisites, active-row compat and new report types (17.2); flag set `true` (the single flip); `Session.get_snapshot_for_user/3`, `Certificate` reads facts only, certificate render clauses; `Snapshot.ensure/3`, `ensure_locked/2`, `build_late`, `ensure_certificate_facts`, late audit entry; late path wired into autosave/state(in_progress)/submit/finalize. | `certificate.ex`, `session.ex`, `snapshot.ex`, `router.ex`, `config/config.exs`, tests; plus `record_late/4` and `check_prerequisites/1` (moved from `Session` to `Snapshot` and shared by the start path, `get_snapshot_for_user/3` and the `ensure` family). |

Between (a) and (b) a snapshotless in-progress session fails closed (typed error), never scores from live
data; (a) must not be deployed to a tenant with in-flight sessions it cares about (QA has none that matter;
the PR body says so). Sequence: PR-0 (#2697, merged), PR-0b (#2702, merged), then (a), then (b); both dependencies are satisfied.

Test-to-PR map (checked against the tables of section 12 and 17.4; T-31 and T-32 were PR-0's and are merged). PR (b) owns: T-09, T-10, T-11, T-21..T-25, T-38, T-39, T-40, T-44, T-48..T-52, T-58..T-63b (T-59, T-60, T-61, T-61b, T-62, T-63, T-63b), the certificate and download render cases of T-20 (T-20b), the `:certificate_facts_missing` case of T-55 (T-55c), the prerequisite and `prerequisites_missing` part of T-57 (T-57b), and mutants M4, M9, M11, M12, M14, M16. Every other test belongs to PR (a): T-01..T-08, T-12..T-19, T-20 (submit, start and 503 cases), T-26..T-30, T-33..T-37, T-41, T-42, T-43, T-45, T-46, T-47, T-53, T-54, T-55 (cases a, b, d, e), T-56, T-57 (the `:snapshot_not_complete` status and `gate_blocked_total`, T-57a), and mutants M1, M2, M3 (via T-04; extended by T-09 and T-11 in PR (b)), M5, M7, M8, M10, M13, M15 (the "fails on a missing snapshot" half; PR (b) adds the `ensure` half). M6 is PR-0's. T-30 runs in PR (a) with the live-exam certificate path and is re-run unchanged in PR (b). With PR-0 split off, (a) is smaller (R-1 reduced). The PRs record the ordering: PR (a) body states "the infra stamp is refused by code until PR (b)
flips `exam_snapshot_complete`"; PR (b) body states the rollout-then-stamp order.

## 14. Mutants (the implementer deletes or flips each; the named test must fail)

| Id | Mutation | Must fail |
|---|---|---|
| M1 | Scoring reads live `answer_option` again | T-01..T-03 |
| M2 | Reintroduce a default threshold when the key is absent | T-15, T-16, T-19 |
| M3 | `update_session_after_submit` rebuilds without `exam_snapshot` | T-04 (carry-forward), T-09, T-11 |
| M4 | Late path overwrites an existing snapshot | T-18, T-24 |
| M5 | Remove the `{"session","exam_snapshot"}` pair from `answer_key_fields` | T-26, T-33, T-35 |
| M6 | (owned by PR-0) drop the refusal for sort or the join branch | T-31 |
| M7 | Stamp ignores the flag | T-36 |
| M8 | Skip digest verification in scoring | T-18 |
| M9 | `ensure` before the ownership check in autosave | a non-owner autosave test asserting no write |
| M10 | Autosave or state reads `question.type` live | T-06, T-07 |
| M11 | Certificate reads live `exam` | T-09, T-10, T-11 |
| M12 | Stamp compat over all versions again | T-40 |
| M13 | Snapshot omitted from the create (session written without it) | T-01 (and T-22 shape) |

## 15. Gates, #2612, invariants

- SECURITY-REVIEWER: MANDATORY (tenant-data write path, answer key, generic read-route behaviour change,
  definition rollout). REVIEWER: mandatory (new module, scope, decision consistency with 2596 and 0050).
- #2612 mandatory trigger: NOT triggered. The design touches none of `ci.yml`, `cd.yml`,
  `scripts/cd_qa_decide.sh`, `scripts/ci_changed_paths.sh`, `mix.exs` aliases or `elixirc_paths`, `config
  :letflow, :modules`, `letflow.permission_matrix.ex`, `api/permission_matrix.ex`, `api/authorization.ex`,
  `modules/catalog.ex`, `priv/permission_matrix/`. Adjacent, to be flagged to ORCH: `config/config.exs`
  gets a NEW key `:exam_snapshot_complete` (not the `:modules` key) and `config/test.exs` one line; the new
  Mix task is a new file, not an alias edit; no permission or role grant changes (the golden is unchanged;
  the implementer quotes `mix letflow.permission_matrix --check`). If ORCH reads "config" broadly as a
  trigger, the rule applies to those two lines only.
- INV-1: every new query carries the explicit `prefix:` (definition, restriction and record reads);
  rollout uses `tenant_id_for_schema_name/1`. INV-2: the PR-0 refusal, the new restriction row, hand-built candidate
  responses. INV-4/INV-5: stable error bodies, logs hold tags and ids only, never snapshot values; reports hold
  names and counts. INV-6: no new route; the only changed route behaviour (in PR-0, not here) is the PR-0 refusal (403 on a restricted
  field reference). INV-7: Ecto queries only. INV-8: every new failure is a typed error with its own render
  clause; no `raise` on a bad snapshot (parsers are total). INV-10: n/a.
- Decision records: no new decision; a one-line note under 0050 D7 is NOT needed. DOC-UPDATER updates the
  exam module docs and `docs/requirements.yaml` REQ-511 criteria (currently a placeholder pointing to the
  GH body) with the ACs of this design.

## 16. Open questions and risks

Open questions (each has a default the build follows unless the supervisor overrides):

| # | Question | Default |
|---|---|---|
| OQ-1 | RESOLVED by ruling: a short 503 window on QA/BilimBaga is accepted; the rollout runs right after the PR (a) deploy (17.5). | accepted |
| OQ-2 | Actor and audit for the rollout's definition writes (Stamp used `actor_id: nil`). | Whatever `create_definition/3` accepts for a platform actor; ELIXIR-DEV quotes it. |
| OQ-3 | RESOLVED by SECURITY-REVIEWER R5: a cutover check IS required (18.5): a late snapshot is allowed only for a session that started before the `exam_snapshot` definition version existed in that tenant; otherwise fail closed. | adopted |
| OQ-4 | Snapshot stem and option text as well? | No (D3, cost 5-10x). |
| OQ-5 | Type-level restriction of `session`, `session_question`, `session_answer`, `certificate` against generic readers (other candidates' results)? | Out of scope; file a follow-up. |
| OQ-6 | RESOLVED by ruling: the PR-0 refusal is PR-0; REQ-511 stays two PRs (a), (b). | accepted |
| OQ-7 | `exam_snapshot_complete` as app config vs a stamp-module constant. | App config (testable without a prod seam). |
| OQ-8 | Late certificate facts for pre-ship submitted sessions (D5) vs refusing. | D5 as designed. |
| OQ-9 | Does adding an optional non-queried JSON field to an active promoted `session` definition need DDL? | Assumed no; T-37 proves it before the rollout relies on it. |
| OQ-10 | HTTP code for grading errors (500) and alert channel (REQ-512 / 2596 OQ-10). | 500 plus `Logger.error`; alerting deferred. |
| OQ-11 | Should audit staff get `user_entity_grants` to read `exam_snapshot`? | No grants created; staff use the DB or a future report. |

Risks:
- R-1 PR (a) size (13). R-2 The PR-0 refusal change alters an existing route for any caller that filtered on a
  restricted field (grep of `web/` and `test/` before merge). R-3 Create lock hold time (4.4); measure.
  R-4 Float/decimal handling: weights and threshold are decimal strings with a total parser; a bad stored
  string is a typed error, not a crash. R-5 The `ManifestHash`/`tenant_modules.manifest_hash` tests may pin
  the pack content; ELIXIR-DEV checks and updates. R-6 Residual: late snapshots cannot undo a pre-touch
  edit; the authoring types stay unmanaged until REQ-510 (#2680), so the snapshot is the control for
  authoring edits meanwhile (correction 8). R-7 The `get_session_state_for_user` GET performs a write for a
  legacy session once. R-8 F7 is established from reading and is owned by PR-0 (its reproducing test decides).

## 17. Amendment 2026-10-16 (CODE-DESIGN-VALIDATOR round 1: G1-G5; supervisor rulings). Binding; supersedes conflicts above.

### 17.1 G1: candidate state read by session status (and snapshot shapes without question items)

`get_session_state_for_user/3` serves a session of ANY status. Rule S-1: the snapshot is needed to SCORE and to
VALIDATE AUTOSAVE, both of which exist only for `in_progress` sessions. A terminal session (`submitted`,
`auto_submitted`, `grading_pending`) can never be scored or autosaved again, so reading it must never fail
or write because of the snapshot.

| Session status | Snapshot state | State-read behaviour (PR a and PR b) |
|---|---|---|
| `in_progress` | valid, has `questions` | `type` from the snapshot item. |
| `in_progress` | absent | PR (a): `{:error, {:grading_error, :snapshot_missing}}` (500). PR (b): `Snapshot.ensure/3` (late), then as above. |
| `in_progress` | corrupt, or `origin == "late_certificate"` (impossible by construction) | `{:error, {:grading_error, :snapshot_corrupt}}`. |
| terminal | valid with `questions` | `type` from the snapshot item when the question has one. |
| terminal | absent (legacy pre-ship), `late_certificate` (no `questions`), corrupt, or the question has no item | `type` from the LIVE question row, as display data only. No `ensure`, no write, no digest check, no grading error. Terminal sessions never affect any outcome, so a live display type cannot change a score or certificate. A missing live question keeps the existing `{:question_not_found, id}`. |

Invariant I-3: a terminal session is never given a snapshot by any touch (state read, autosave refusal,
submit replay, finalize replay); only `ensure_certificate_facts/3` may add a `late_certificate` snapshot, and
only for a `submitted` session at certificate time. Tests: T-43 (terminal legacy `submitted`, `auto_submitted`,
`grading_pending` sessions without a snapshot: state read OK, live type, zero update events, in PR (a) and PR
(b)); T-44 (`late_certificate` session state read OK); T-45 (terminal session with a corrupt snapshot: state
read OK, live type); T-46 (terminal snapshotless session never snapshotted by state read, autosave attempt,
submit replay, `finalize_expired` replay, with the field still absent and zero update events); T-47 (terminal
session WITH a snapshot after a live type edit shows the snapshot type).

### 17.2 G2: complete specifications

Error shapes (one per condition). Every snapshot condition is `{:error, {:grading_error, reason}}` with
`reason` from section 7.2; `:snapshot_missing` has ONLY that shape everywhere (the `fetch_structural/1` row
of 4.2 is corrected accordingly). Non-grading failures: `{:error, {:snapshot_error, :definition_missing |
:restrictions_missing | :audit_failed | :write_failed}}` (HTTP 503) and the existing session errors
`:session_not_found`, `:not_owner`. A Records write error inside a snapshot write is mapped to
`{:snapshot_error, :write_failed}` (the tag only; the term is logged by tag, never returned).

| Function | Arguments | Success | Complete error union |
|---|---|---|---|
| `Snapshot.build_from_resolved/4` | as 4.2 | `{:ok, snapshot()}` | `{:grading_error, :exam_section_missing \| :threshold_missing \| :threshold_invalid \| {:question_item_missing, id} \| {:question_type_invalid, id} \| {:key_missing, id} \| :snapshot_too_large}` |
| `Snapshot.build_late/3` | `session :: Latest` (locked, `in_progress`), `prefix :: String.t()`, `now :: DateTime.t()` | `{:ok, snapshot()}` (origin `"late"`) | the same union as `build_from_resolved/4`; live exam row missing -> `:exam_section_missing`; live exam field nil -> `:threshold_missing`; a `session_question` whose question row is missing -> `{:question_item_missing, id}`; option rows giving no key -> `{:key_missing, id}` |
| `Snapshot.build_certificate_only/3` | `session :: Latest` (locked, `submitted`), `prefix`, `now` | `{:ok, snapshot()}` (origin `"late_certificate"`; `exam` object holds ONLY `exam_id`, `certificate_enabled`, `title`; no `order`, `questions`, `passing_score_pct`) | `{:grading_error, :exam_section_missing \| :certificate_facts_missing \| :snapshot_too_large}` |
| `Snapshot.fetch_verified/1` | `session_field_values :: map()` | `{:ok, snapshot()}` | `{:grading_error, :snapshot_missing \| :snapshot_corrupt}` |
| `Snapshot.fetch_structural/1` | `session_field_values :: map()` | `{:ok, snapshot()}` | `{:grading_error, :snapshot_missing \| :snapshot_corrupt}` |
| `Snapshot.ensure/3` | `session_id`, `user_id`, `prefix` (candidate touch: own transaction, `lock_session_row/2`, owner check, then 9.2) | `{:ok, snapshot()}` | `:session_not_found \| :not_owner \| {:grading_error, reason}` (build_late union, plus `:snapshot_missing` for a terminal snapshotless session, plus `:snapshot_corrupt`) `\| {:snapshot_error, :definition_missing \| :restrictions_missing \| :audit_failed \| :write_failed}` |
| `Snapshot.ensure_locked/2` | `session :: Latest` (caller holds the transaction and the row lock; used by submit and finalize), `prefix` | `{:ok, snapshot(), session_after :: Latest, :existing \| :late}` (accepted deviation D-b1): it only BUILDS the late snapshot and NEVER writes. `session_after.field_values` carries the snapshot (merged), and the tag says whether it was `:existing` or newly built `:late`. Submit and finalize persist `session_after.field_values` in their ONE existing session update, after `persist_scores`, and call `record_late/4` (the audit entry of 17.6) as the LAST statement of the transaction when the tag is `:late`. Reason: writing the session snapshot first would take the session entity-type sequence lock before the score sequence lock, the reverse of a plain submit, a deadlock risk; this way exactly ONE update event adds `exam_snapshot`. `ensure/3` and `ensure_certificate_facts/3` (single-purpose transactions) write immediately. | same union as `ensure/3` minus the two session errors |
| `Snapshot.ensure_certificate_facts/3` | `session_id`, `user_id`, `prefix` (own transaction, `lock_session_row/2`, owner check) | `{:ok, snapshot()}`: an existing verified snapshot is returned untouched; else, ONLY when status is `submitted`, a `late_certificate` snapshot is built, written with the audit entry of 17.6, and returned | `:session_not_found \| :not_owner \| {:grading_error, :snapshot_missing` (status not submitted: nothing written) `\| :snapshot_corrupt \| :exam_section_missing \| :certificate_facts_missing \| :snapshot_too_large} \| {:snapshot_error, :definition_missing \| :restrictions_missing \| :audit_failed \| :write_failed}` |
| `Session.get_snapshot_for_user/3` | `session_id`, `user_id`, `prefix` | `{:ok, snapshot()}`: ownership via `get_session_for_user/3`; present snapshot -> `fetch_verified`; absent and `submitted` -> `ensure_certificate_facts/3`; absent and any other status -> `{:grading_error, :snapshot_missing}` with no write. Certificate calls ONLY this function. | `:session_not_found \| :not_owner \| {:grading_error, :snapshot_missing \| :snapshot_corrupt \| :exam_section_missing \| :certificate_facts_missing \| :snapshot_too_large} \| {:snapshot_error, :definition_missing \| :restrictions_missing \| :audit_failed \| :write_failed}` (the complete `ensure_certificate_facts/3` union) |
| `Snapshot.certificate_facts/1` | `snapshot` | `{:ok, %{certificate_enabled: boolean(), title: term()}}` | `{:grading_error, :certificate_facts_missing}` |
| `Exam.ensure_answer_key_restrictions/1` | `prefix` | `{:ok, added :: non_neg_integer()}` (idempotent insert of the missing pairs of `answer_key_fields/0`) | `{:error, :invalid_schema_name}` |

Stored number -> decimal string rule (used by the builders for `passing_score_pct` and `likert_weight`). The
input may be a JSON integer, a JSON float, a `Decimal`, or a numeric string. Convert to a `Decimal` (a float via
its shortest round-trip representation, a string via a parse that must consume the whole string, a `Decimal`
as is). Reject nil (reason `:threshold_missing`, or `{:key_missing, id}` for a likert weight), NaN, infinity
and any unparsable value (`:threshold_invalid`, or `{:key_missing, id}` for a weight). Then normalise and render
with `Decimal.to_string(:normal)`, so `60`, `60.0` and `"60.00"` all store `"60"`. The threshold must satisfy
0 <= x <= 100 (`:threshold_invalid` otherwise). Reading back parses the string with the same total parser and
never raises. `is_correct` counts only when it is the literal `true` (as today). A likert option needs
`likert_polarity` in `positive|negative`, else `{:key_missing, id}`. Test T-54 tabulates integer, float,
Decimal, numeric string, nil, `"abc"`, NaN-like, 101 and -1.

Release entry points (same pattern as `Letflow.Release.ManagedTypes` and `Stamp`):

| Entry | Signature | Result |
|---|---|---|
| `Letflow.Modules.Exam.Snapshot.Rollout.run/1` | `opts :: [dry_run: boolean(), lock_timeout_ms: pos_integer()]` | `{:ok, rollout_report()}` |
| `Letflow.Modules.Exam.Snapshot.Rollout.run_tenant/2` | `schema_name :: String.t()`, `opts` | `rollout_tenant_report()` (never raises; inside an open transaction it returns `error: :nested_transaction`) |
| `Letflow.Release.ExamSnapshot.rollout/1` | `opts` (`dry_run` default false) | `rollout_report()`; run as `bin/letflow rpc "IO.inspect(Letflow.Release.ExamSnapshot.rollout(dry_run: false))"` |
| `Letflow.Release.ExamSnapshot.verify/0` | none, read-only | `%{ready: boolean(), tenants: [%{schema_name: String.t(), session_definition: boolean(), answer_key_restrictions: boolean()}]}`; `ready` is true when every exam-installed tenant has both |
| `mix letflow.exam_snapshot_rollout` | `[--dry-run]` | prints the report; exit status non-zero when `failed_total > 0` or `conflict_total > 0` |

`rollout_tenant_report()` keys: `tenant_id`; `schema_name`; `status :: :upgraded | :already_current |
:exam_not_installed | :skipped_schema_missing | :conflict | :managed_cannot_upgrade | :failed`; `definition ::
:added | :already_current | :conflict | :managed_cannot_upgrade | :skipped`; `restrictions_added ::
non_neg_integer()`; `error :: nil | :nested_transaction | :lock_timeout | {:definition_write_failed, atom()} |
{:unexpected_exception, module()}` (tags and exception modules only, INV-4). `rollout_report()` keys: `dry_run`,
`tenants`, `upgraded_total`, `conflict_total`, `failed_total`, `restrictions_added_total`.

Stamp additions (typed): `tenant_status` gains `:snapshot_not_complete` (flag false, real run) and
`:snapshot_prerequisite_missing`; `tenant_report` gains `prerequisites_missing :: [:session_definition |
:answer_key_restrictions]` (empty by default); `report` gains `gate_blocked_total :: non_neg_integer()` (tenants whose status is `:snapshot_not_complete` or `:snapshot_prerequisite_missing`); `run/1` returns
`{:ok, report()} | {:error, :unsupported_module | :snapshot_not_complete}`. Which PR: the flag REFUSAL ships in
PR (a) with the flag `false`; the prerequisites, the active-row compatibility change, the status
`:snapshot_prerequisite_missing` and the report key `prerequisites_missing` ship in PR (b) with the flag set `true`.
Report fields by PR (D1, binding): PR (a) adds the tenant status `:snapshot_not_complete` and the report counter
`gate_blocked_total`, which in PR (a) counts ONLY tenants with status `:snapshot_not_complete`; the mix task and
`print_tenant/1` use them in PR (a) and therefore reference nothing from PR (b). PR (b) adds
`:snapshot_prerequisite_missing` and `prerequisites_missing` and extends `gate_blocked_total` to count that status too.

Stamp entry-point mapping (CDV C3; the mix task at `lib/mix/tasks/letflow.stamp_managed_types.ex` currently matches only `{:ok, report}` and `{:error, :unsupported_module}`, so an unhandled `{:error, :snapshot_not_complete}` would raise `CaseClauseError`, and it halts only when `failed_total > 0`): `Release.ManagedTypes.stamp/1` returns the widened spec above; the mix task prints `"stamp refused: exam snapshot gate is closed (:exam_snapshot_complete is false)"` and halts with status 1 on `{:error, :snapshot_not_complete}`; after `{:ok, report}` it halts with status 1 when `failed_total > 0 or gate_blocked_total > 0` (a dry run never has a blocked tenant, so dry-run exits 0); `print_tenant/1` prints the two new statuses and `prerequisites_missing`. T-36 asserts each entry point and the exit statuses; T-57 the report keys.

### 17.3 G3: what the digest does and does not do (threat model; for SECURITY-REVIEWER)

This replaces the rationale of D2 and the nonce statement of 4.1. The digest is unkeyed and stored, with its
nonce, in the same restricted field. It detects ACCIDENTS (partial write, carry-forward bug, half-applied
update, serializer difference). It does NOT detect a writer who recomputes it, and the nonce adds nothing once
the field is readable; the nonce stays only as defence in depth (if the redaction of the field were ever
relaxed, the digest would still not be a brute-forceable oracle for the correct-option set).

Threat model before the stamp: the `session` type is unmanaged, so a holder of `EntitiesRecordsWrite`
(PROCESS_OPERATOR, PLATFORM_ADMIN, TENANT_ADMIN) can `PUT /entities/records/session/:id` and overwrite or drop
`exam_snapshot` (full replacement). Dropping it on an `in_progress` session that started before the cutover causes a live late snapshot at the
next touch (marked `late`, audited, 17.6); for a session started after the cutover it fails closed (18.5). That population can already edit the authoring rows and the stored
results, so this is not a new capability; the design adds visibility (`origin`, the audit entry, the event
history with the actor). After the stamp, generic writes to `session` are refused (403), which closes it. We do
NOT key the digest (HMAC) in this requirement: it needs a server-secret lifecycle and gives no protection
against the same population. The earlier "no cutover check" default is WITHDRAWN: the cutover rule of 18.5 now closes
the drop-the-snapshot path for sessions started after the rollout. SECURITY-REVIEWER list: (1) confirm `PUT`/`POST /entities/records/session` responses
and errors never echo a PRIOR `exam_snapshot` to a restricted caller (they return what the caller sent); (2)
confirm the stamp request is not made until PR (b) is merged and the rollout verified (gate, section 10); (3)
HMAC: decided NO by SECURITY-REVIEWER (OQ-12 resolved).

### 17.4 G4: added tests, and corrected mutant bindings

| Id | Test |
|---|---|
| T-48 | Late build, live exam `passing_score_pct` nil -> `{:grading_error, :threshold_missing}`; session row unchanged, zero new events, no audit entry (PR b). |
| T-49 | Late build, live exam row missing -> `:exam_section_missing`; unchanged. |
| T-50 | Late build, a `session_question`'s question row missing -> `{:question_item_missing, id}`; unchanged. |
| T-51 | Late build, a non-short-text question with no correct option, and a likert question with an option lacking weight or polarity -> `{:key_missing, id}`; unchanged. |
| T-52 | Non-owner touch (autosave, state read) of a legacy session writes nothing (zero events, no audit entry) and returns the not-found-class error (binds M9). |
| T-53 | Start when the active `session` definition lacks `exam_snapshot` -> 503 `definition_missing`; no `session` or `session_question` rows. |
| T-55a..e | One test per remaining grading reason: `:threshold_invalid` (non-numeric, -1, 101); `{:question_type_invalid, id}`; `:certificate_facts_missing` (non-boolean flag, title absent); `:snapshot_too_large` (oversized synthetic input to the pure builder); likert-incomplete `{:key_missing, id}` on the START path. With T-15..T-18 and T-48..T-51 every `grading_reason()` of 7.2 has a test (a table-driven completeness test lists the 7.2 reasons and fails if one is untested). |
| T-54 | The number-to-decimal-string table of 17.2. |
| T-56 | `Rollout.run`, `run_tenant`, `verify` and the mix task: report shapes of 17.2, idempotency, dry-run writes nothing, non-zero exit on failure or conflict. |
| T-57 | Stamp: the new statuses and report keys of 17.2 appear exactly as typed. |
| T-58 | Late audit (17.6): one `late` snapshot -> exactly one audit entry with ids and names only; an audit failure rolls back the snapshot write (`{:snapshot_error, :audit_failed}`). |
| T-59 | `ensure_locked/2` returns `{:ok, snapshot, session_after, :late}` for a snapshotless `in_progress` session and writes NOTHING itself (zero events from the call); the assertions are on the returned `session_after.field_values` AND on the persisted row after the submit completes: the snapshot is present, `origin == "late"`, exactly ONE update event adds `exam_snapshot` for that submit, and `record_late/4` ran last (binds M14). With an existing snapshot the tag is `:existing` and no audit entry is written. |

Mutant table corrections: M9 is bound to T-52. Added: M14 `ensure_locked` returns the stale row so submit drops
the late snapshot -> T-22, T-59. M15 a terminal-session state read calls `ensure` or fails on a missing
snapshot -> T-43..T-46. M16 the late path skips the audit entry -> T-58.

### 17.5 G5: who runs the rollout, when, and how it is verified

Actor and trigger (humanless pipeline): ORCH, as a step of its post-merge checklist for PR (a), files the usual
infra request to run `Letflow.Release.ExamSnapshot.rollout(dry_run: false)` on QA immediately after the PR (a)
deploy completes, and repeats it for BilimBaga and production when those are deployed. Ruling: the short 503
window is accepted. It is announced up front to letflow-2 (UAT) so that no UAT run starts inside it; the
runbook in the PR body states the window and its expected duration (minutes). The PR body must quote the
post-deploy verification: `Letflow.Release.ExamSnapshot.verify()` returns `ready: true`, plus one exam start and
one submit succeeding on QA. No CD-hook automation is added (no extra complexity; `cd.yml` is a #2612 file).
"No window at no real cost" was evaluated: the only way is to run the additive rollout BEFORE the code, which
needs the rollout code to exist in the previous release, i.e. impossible inside the same PR; not pursued. PR (a)
alone also fails closed for snapshotless `in_progress` sessions on the auto-deploy to QA; the PR body says so
and ORCH checks that QA has none that matter before merging.

### 17.6 Ruling (c): late snapshots are reported (REQ-512 contract, names and counts only)

Every `late` or `late_certificate` snapshot write inserts, IN THE SAME transaction, one hash-chained audit entry
through `Letflow.Audit.insert_entry/3` (the pattern `Stamp.audit!/4` uses): `action:
"exam.session_snapshot_late"`, `resource_type: "session"`, `resource_id`: the session id, `actor_id`: the
touching user id, or `nil` for the system sweep, `before_state: nil`, `after_state: %{"origin" => "late" |
"late_certificate", "taken_at" => iso8601, "exam_id" => id, "started_at" => iso8601}` (ids and names only, never snapshot content,
INV-4/INV-5), `trace_id` from `AuditContext`. An audit failure rolls the snapshot write back
(`{:snapshot_error, :audit_failed}`, HTTP 503): a late snapshot that cannot be recorded is not taken. Besides
the audit entry, the persistent marker stays in the session record (`exam_snapshot.origin`, `taken_at`).
REQ-512 (GH #2683) reads the report from either source: the audit action above (preferred: tenant-wide,
ordered, hash-chained) or the field. The report lists, per tenant, session id, exam id, origin and `taken_at`,
and counts by origin. A read-only helper `Snapshot.late_origin_counts/1` (`prefix` -> `{:ok, %{late:
non_neg_integer(), late_certificate: non_neg_integer()}} | {:error, :invalid_schema_name}`) is added for the post-deploy checklist; the report
itself stays in REQ-512. Test T-58.

### 17.7 Open questions added

| # | Question | Default |
|---|---|---|
| OQ-12 | RESOLVED by SECURITY-REVIEWER: no HMAC. | accepted |
| OQ-13 | Is it acceptable to REVIEWER that only the Stamp flag refusal ships in PR (a) and the prerequisites ship in PR (b)? | Yes (17.2). |

## 18. Amendment round 3 (SECURITY-REVIEWER design verdict: B1/R1-R6; recorded answers). Binding; supersedes conflicts above.

Recorded by SECURITY-REVIEWER: OQ-12 (digest without HMAC) is acceptable; there is no deploy-to-stamp gap; the
#2612 rule is not triggered. PR sequence: PR-0 (#2697) -> PR-0b -> PR (a) -> PR (b); REQ-511 depends on PR-0 and
PR-0b.

### 18.1 B1/R1: event payloads under synthetic entity-type instances (PR-0b #2702, MERGED; chose HIDE)

Finding F14 (corrected above): record create and update events carry the full `field_values` under a synthetic
per-entity-type event instance; `Instances` list, get, history and timeline do not hide it, so `InstancesRead`
holders read record content, including the answer key and `exam_snapshot`, outside every field restriction.
This is a pre-existing exposure that REQ-511 would otherwise make worse (the key would be copied into a new
`session` event payload), so it is closed FIRST by its own prio-1 security PR-0b (own issue, filed by letflow-2
after SECURITY-REVIEWER's reproducing test; the designer of PR-0b chooses between two fixes):
(A) hide synthetic entity-type instances from every `Instances` read (list, get, history, timeline) with the same
404 body as a nonexistent instance (INV-5), or (B) per-user redaction of event `field_values` through
`FieldGrants` for the restricted fields. PR-0b (#2702) chose (A), hide. BINDING LINE (SEC A2): REQ-516 (#2701), and any other present or future route that returns record-event payloads (field_values), must apply the field restrictions of the caller (FieldGrants) or exclude restricted types; a new such route without that fails the SECURITY-REVIEWER gate. This design requires only the property: after PR-0b, no `Instances` route
returns `exam_snapshot`, its nonce or digest, or answer-key values to any caller without a `user_entity_grants`
row. Test T-30 (extended) is the acceptance proof for this requirement. Checklist item for SECURITY-REVIEWER at
the code gate: enumerate every route returning event payloads (8.4 checklist item 1) and attach the list to the
verdict.

### 18.2 R2: T-30 extended

T-30 (section 12.4) now probes, with TASK_WORKER, TENANT_AUDITOR and TENANT_ADMIN tokens after a full candidate
flow, every tenant-readable route: query (plain, join), aggregate, export (default), instances list, get,
history and timeline (including the session's synthetic entity-type instance), the public certificate
projection, plus any route found by the 8.4 enumeration; `exam_snapshot`, `nonce`, `digest`,
`correct_option_ids` and `is_correct` flags appear on none.

### 18.3 R3: flag provenance and entry points

`:exam_snapshot_complete` is set ONLY in `config/config.exs` (`false`) and `config/test.exs` (`true`). It is never
set from an environment variable, `config/runtime.exs`, `Application.put_env` in `lib/`, or a release overlay;
`lib/` reads it with `Application.get_env/3` and the fail-closed default `false`. Every Stamp entry point refuses
a real run while it is false: `Stamp.run/1`, `Stamp.run_tenant/2`, `Letflow.Release.ManagedTypes.stamp/1` and the
mix task `letflow.stamp_managed_types`. The flip to `true` appears in PR (b) and nowhere else (PR (a) diff must
show `false`). Tests: T-36 as amended (all entry points, dry-run allowed, source test on the flag provenance).

### 18.4 R4: rollout write path

The Rollout creates the new `session` definition ONLY through `Definitions.create_definition/3` and
`activate_definition/4`; no direct insert or update of `entity_definitions`. `tenant_id` is derived from the schema
prefix (`tenant_id_for_schema_name/1`), never from input. The new definition equals the tenant's previous active
one plus exactly the `exam_snapshot` field (T-37 diffs them). Reports carry tags, statuses and counts only.

### 18.5 R5: cutover rule for late snapshots (BINDING; replaces OQ-3's earlier default; ships in PR (b))

Cutover source (verified in code at `828d9d1be`): `entity_definitions` has only `inserted_at` and
`Definitions.activate_definition/4` flips `status` without a time, BUT it calls `Activation.activate_group/5`
with `artifact_kind: :entity`, `artifact_name: name`, `version_id: entity_definition.artifact_version_id`, which
inserts one `artifact_activation_history` row (schema `Letflow.Repository.ActivationHistory`; columns
`artifact_kind`, `artifact_name`, `new_version_id`, `new_version_number`, `activated_at :utc_datetime_usec`,
`tenant_id`; append-only: no update or delete exists). Pack install and the rollout both go through
`activate_definition/4`, so every activation of a `session` version has such a row. Binding rule:

`Snapshot.cutover/1` (PR (b)): `cutover(prefix :: String.t()) :: {:ok, DateTime.t()} | {:error,
:definition_missing | :invalid_schema_name}`. It returns the MINIMUM `activated_at` over `artifact_activation_history`
rows where `artifact_kind == :entity`, `artifact_name == "session"`, `tenant_id` is the prefix's tenant
(`tenant_id_for_schema_name/1`), and `new_version_id` equals the `artifact_version_id` of an `entity_definitions`
row (same tenant, `name == "session"`) whose `definition_json` declares a field named `exam_snapshot` (matched
with a bound-parameter jsonb containment, no string interpolation, INV-7). No such row -> `{:error,
:definition_missing}`, which `ensure/3`, `ensure_locked/2` and `ensure_certificate_facts/3` map to
`{:snapshot_error, :definition_missing}` (HTTP 503) with no write. There is NO audit-entry fallback and no
alternative source.

Compared quantity (SEC A3): the cutover is compared with the server-set `inserted_at` of the session RECORD
(`entity_record_latest.inserted_at`, set on insert, not castable and not changed by `update_record`; ELIXIR-DEV
confirms the upsert never rewrites it and quotes the line), NOT with the `started_at` field, because before the
stamp a writer can rewrite `started_at` together with dropping the snapshot. Rule: a late snapshot (`late`,
`late_certificate`) is allowed ONLY when the session record's `inserted_at` is earlier than the cutover; otherwise
`{:grading_error, :snapshot_missing}` with no write. Tests (all PR (b)): T-60 (record inserted before the cutover,
no snapshot -> late snapshot allowed); T-61 (record inserted at or after the cutover, snapshot dropped ->
`:snapshot_missing`, zero events, not snapshotted; same for the certificate-facts case); T-61b (record inserted
after the cutover whose writer sets `started_at` far in the past while dropping the snapshot -> still
`:snapshot_missing`); T-62 (fresh-install tenant: the cutover is the install-time activation row); T-63b
(`cutover/1` unit test: minimum over several versions, ignores versions without the field, `:definition_missing`
when none).

Fixture rule (CDV C2, binding): the test fixtures carry `exam_snapshot` from install, so a plain fixture session
is "after the cutover". Every test that needs a LEGACY (pre-ship) session (T-21..T-25, T-43..T-47 legacy
variants, T-48..T-52, T-58, T-59, T-63) builds it through ONE helper `legacy_session!` that (i) creates the
session record and then sets its stored `inserted_at` earlier than the tenant's cutover by a direct fixture
update of `entity_record_latest.inserted_at` (a test-support write, not a production path), and (ii) sets the
`started_at` field before the cutover and `expires_at` in the future. Only T-61 and T-61b use a session whose
record `inserted_at` is at or after the cutover. Cutover rows cannot be edited (append-only history), so the
session side is moved, never the cutover.

The late audit entry of 17.6 has `after_state %{"origin", "taken_at", "exam_id", "started_at"}` (ids, names and
timestamps only).

### 18.6 R6: ownership before prerequisites, and lock order

In `ensure/3` and `ensure_certificate_facts/3` the order is: take the session row lock, check ownership, then the
definition and restriction prerequisites, then the cutover rule, then build and write (9.2 step 1). A non-owner
(or a nonexistent session) receives the identical not-found response bytes, never a 503 and never a prerequisite
probe. The prerequisite probes therefore cannot be used by a non-owner to learn rollout state. Test T-63: for a
legacy session in a tenant WITHOUT the definition field, a non-owner touch and a touch of a random uuid return
byte-identical responses AND an identical number of database queries (query-count parity measured with a telemetry counter on the repo; asserted for `ensure/3`, `ensure_certificate_facts/3`, autosave and the state read), so neither bytes nor query count distinguish a non-owner from a nonexistent session; the owner gets the 503. Full lock order (no cycle, SEC A5): exam row lock (create only) -> session
row lock -> the entity-type instance sequence lock (taken by the `Records` write) -> audit chain lock. The audit insert is the LAST statement of the snapshot transaction; no code path
takes the audit chain lock and then a session row, exam row or instance sequence lock. ELIXIR-DEV quotes grep evidence in the PR that no path inverts this order, including `Stamp.audit!` (which holds no session or exam row lock).
