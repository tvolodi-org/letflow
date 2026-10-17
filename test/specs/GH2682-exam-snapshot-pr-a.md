# Test Spec: GH #2682 / REQ-511 PR a -- exam content snapshot (storage, scoring read, restriction seed, rollout, stamp gate)

**Requirement:** REQ-511 (GH #2682). Design: `lib/letflow/design/req511-exam-content-snapshot.md`
(sections 4, 5, 7, 8, 10, 12, 13, 14, 17, 18). PR a only: the certificate path and the in-flight
(late snapshot) policy are PR b. Acceptance criteria (GH #2682 body, with the REQ-VALIDATOR
corrections):

1. Editing an exam, a question, an answer option's correctness, likert weight/polarity, the passing
   threshold or the certificate flag after session start does not change that session's score or
   certificate (one test per field class). PR a covers scoring, autosave and the state read; the
   certificate flag and title are PR b (T-09, T-10, T-11).
2. A snapshot with a missing threshold or missing answer-key item produces a grading error, not
   60.0 (both the row-missing and the field-nil case); the old fallback is removed.
3. The in-flight policy (PR b).
4. Answer-key field restrictions tested.
5. Gate: the infra stamp does NOT run before this is merged; the PR records the ordering.
6. Design validated, SECURITY-REVIEWER and REVIEWER verdicts, standard gates quoted (process).

**Test tier:** unit + integration (real Postgres, real tenants, real HTTP through `Letflow.Router`)
+ property (`StreamData`, T-41) + source guards.

Facts of the implementation these tests follow (dev handoff step-08 and the REVIEWER/SECURITY
verdicts, which supersede the design text where they differ): the answer-key restriction pairs are
FIVE (four REQ-411 pairs plus `session.exam_snapshot`; the design's "six" is an arithmetic error);
the key rule is single/multiple/truefalse need a correct option, likert needs a complete non-empty
`likert_options` map (no correct option), shorttext needs neither (D-2); a pinned question that is
missing, not `active` or not a UUID fails the start with a constant 422; a snapshot item missing is
`{:grading_error, {:question_item_missing, id}}`; the threshold is normalised to a decimal string
(`60`, `60.0`, `"60.00"` all store `"60"`); a real `Stamp` run returns
`{:error, :snapshot_not_complete}` unless `:exam_snapshot_complete` is exactly `true`.

## New test files (149 tests)

| File | Tests | Tier |
|---|---|---|
| `test/letflow/modules/exam/snapshot_test.exs` | 46 | pure unit + one real jsonb round trip + property |
| `test/letflow/modules/exam/session_snapshot_test.exs` | 35 | integration (tenant, Records, Session) |
| `test/letflow/modules/exam/snapshot_restrictions_test.exs` | 18 | integration + HTTP (query, joins) + entity port |
| `test/letflow/modules/exam/exam_snapshot_router_test.exs` | 8 | HTTP, real CANDIDATE token |
| `test/letflow/modules/exam/exam_snapshot_leak_test.exs` | 10 | HTTP, full candidate flow then three reader roles |
| `test/letflow/modules/exam/snapshot_rollout_test.exs` | 18 | integration (rollout, promoted tenant, Mix task) |
| `test/letflow/entities/managed_types/stamp_snapshot_gate_test.exs` | 14 | integration + source guards |

Support: `test/support/exam_fixtures.ex` gains snapshot helpers (`snapshot_digest/1`,
`with_digest/1`, `empty_snapshot!/1`, `update_record!/4`, `delete_record!/3`, `force_field!/5`,
`session_snapshot/2`, `rewrite_snapshot!/3`, `downgrade_session_definition!/1`,
`downgrade_session_definition_without_nils!/1`, `delete_answer_key_restrictions!/1`).

## Existing tests changed (tests only; `lib/` and `priv/` untouched)

| File | Change | Why |
|---|---|---|
| `test/letflow/modules/exam/session_test.exs` | the "no-correct-option" test now expects the START to fail with `{:grading_error, {:key_missing, id}}` and no session row; four autosave tests that add a `session_question` by hand also give the snapshot an item (`add_snapshot_item!/4`, digest recomputed) | the broken bank entry is caught at start (T-42); autosave reads the answer shape from the snapshot |
| `test/letflow/modules/exam/anti_cheat_test.exs` | `create_session!/4` default carries `ExamFixtures.empty_snapshot!(exam_id)` | the "submit" policy auto-submits a hand-built session, and scoring reads only the session's own snapshot |
| `test/letflow/modules/exam/on_install_test.exs` | the five pairs asserted as a literal sorted list, no other row | the old assertion iterated `Exam.answer_key_fields()` (self-referential) |
| `test/letflow/modules/exam/entity_definitions_test.exs` | `session.exam_snapshot` is an optional, non-queried `:json` field | pack definition shape |

Run unchanged and green (no edit needed): `exam_sessions_test.exs`, `certificate_test.exs`,
`pack_install_test.exs` (drift guard on the regenerated `pack.json`), `exam_stamped_tenant_test.exs`,
`stamp_test.exs`, `stamp_trigger_test.exs`, `tamper_inventory_test.exs`,
`exam_managed_types_http_test.exs`, `bilimbaga_solution_e2e_test.exs`,
`letflow.seed.exam_fixtures_test.exs`, `client_key_namespace_test.exs`, `squat_remediation_test.exs`,
`entities_answer_key_field_leak_test.exs`, `solution_packs_module_owned_pack_test.exs`,
`exam_managed_manifest_test.exs`, `exam_definitions_test.exs`, `scoring_test.exs`,
`entities_query_restricted_filter_test.exs`.

## Acceptance criterion -> test map

### AC1: one test per field class (all in `session_snapshot_test.exs`, describe "AC1 edits after start")

| Id | Field class | Test | Fails on the pre-fix `session.ex`? |
|---|---|---|---|
| T-01 | `answer_option.is_correct` | flipped both ways after start; both candidates scored as at start | yes |
| T-02 | `answer_option.likert_weight` | scale reversed after start | yes |
| T-03 | `answer_option.likert_polarity` | flipped after start | yes |
| T-04 | `exam.passing_score_pct` | raised above / lowered below the result after start; ALSO the carry-forward invariant I-1: the snapshot map after submit equals the one before and still verifies (mutant M3) | yes |
| T-05 | `question.type` (scoring) | multiple -> single after start; 50 percent, not 100 | yes |
| T-06 | `question.type` (autosave shape) | two options for a snapshot-single question stay rejected after a live type edit | yes |
| T-07 | `question.type` (state read) | state read shows the snapshot type | yes |
| T-08 | exam row archived + threshold raised, then deleted | scoring still uses the snapshot threshold | yes |
| T-12 | display-only class (stem, option text) | edits visible live in the state read, score unchanged (documents D3) | no (control by design) |
| T-13 | option added / deleted | added correct option ignored by a multiple-choice score (live would give 50 percent); deleted option no crash | added part yes; deleted part no (soft delete: see Observations) |
| T-14 | start-time-only inputs | shuffle flags, attempts, time limit, window, extra pool question edited after start: question set, `expires_at`, score, snapshot unchanged | no (control by design) |
| T-09, T-10, T-11 | certificate flag / title / no live exam read | PR b | -- |

### AC2: typed grading errors, never 60.0

| Id | What | Where |
|---|---|---|
| T-15 | threshold key absent, or nil -> `:threshold_missing`; non-numeric / -1 / 101 / integer -> `:threshold_invalid`; submit AND finalize roll back, session stays `in_progress`, snapshot untouched | `session_snapshot_test.exs` "AC2 broken snapshot"; pure `snapshot_test.exs` |
| T-16 | no `exam` object -> `:exam_section_missing` (the old row-error / 60.0 path) | both |
| T-17 | order id without item -> `{:question_item_missing, id}`; empty key -> `{:key_missing, id}`; bad type -> `{:question_type_invalid, id}`; likert complete without correct option VALID; shorttext with neither VALID; likert with zero options / missing weight / missing polarity / bad weight -> `{:key_missing, id}` | both |
| T-18 | stale digest -> `:snapshot_corrupt`, field neither repaired nor replaced; non-object snapshot -> corrupt; digest-stale snapshot is structurally valid (`fetch_structural`) -- mutant M8 | both |
| T-19 | source guard: no `60.0`, `passing_threshold_for`, `build_scoring_inputs`, `build_question_row`, `fetch_question_for_autosave` in `session.ex` | `session_snapshot_test.exs` |
| T-20 | router: every reason renders the SAME constant 500 (`exam grading failed; the session was not scored`), body free of reason atoms, ids and values; start 500 `exam content is invalid; the session was not started`; 503 `exam service is being upgraded; retry shortly` (definition missing, restriction rows missing); pin 422 `exam pins an unavailable question` without the id; autosave/state/event routes | `exam_snapshot_router_test.exs` (certificate and download cases are PR b: T-20b) |
| T-42 | start with a live threshold nil/missing/150/-5/"abc", a question with no correct option, a likert option without weight, a type outside the five: typed error, no `session`/`session_question` row; pins to a missing / archived / draft / non-UUID question: `{:question_not_found, id}` | `session_snapshot_test.exs` "T-42 broken authoring row" |
| T-53 | active `session` definition lacks `exam_snapshot` -> `{:snapshot_error, :definition_missing}`, no rows | `session_snapshot_test.exs` |
| T-35 | restriction row absent -> `{:snapshot_error, :restrictions_missing}`, no rows | `session_snapshot_test.exs` |
| T-54 | the number table (60, 60.0, "60.00", Decimal, "1e2", NaN, Infinity, "1e999999999" bounded and fast, 101, -1, nil) | `snapshot_test.exs` |
| T-55 a, b, d, e | `:threshold_invalid`, `{:question_type_invalid, id}`, `:snapshot_too_large` (3 questions x 20 000 ids), likert incomplete `{:key_missing, id}` on the START path; completeness test lists every 7.2 reason PR a can produce (`:certificate_facts_missing` is PR b) | `snapshot_test.exs`, `session_snapshot_test.exs` |
| T-41 | property (25 runs): random snapshots round-trip a REAL jsonb column (`SELECT $1::jsonb`) and re-verify; decimal strings `0.1`, `3.5` and the normalised `60` byte-stable | `snapshot_test.exs` |
| T-43, T-45, T-46, T-47 | terminal sessions never need a snapshot: legacy snapshotless (submitted, auto_submitted, grading_pending) state read OK with the LIVE type, zero events; corrupt snapshot OK; never snapshotted by a state read, autosave attempt, submit replay or finalize replay; with a snapshot the snapshot type wins -- mutant M15 | `session_snapshot_test.exs` "terminal sessions" |
| (PR a policy) | an `in_progress` snapshotless session fails closed on submit, finalize, autosave and state read with `:snapshot_missing`, nothing written (PR b adds the late path) | `session_snapshot_test.exs` |
| R6 | ownership before any snapshot read: non-owner of a snapshotless session gets `:not_owner`; router 404 byte-identical to a nonexistent session on GET/PUT/POST submit/POST events; Repo query count equal for non-owner vs nonexistent (autosave, state, submit) | `session_snapshot_test.exs`, `exam_snapshot_router_test.exs` |

### AC4: restrictions and leak

| Id | What | Where |
|---|---|---|
| T-26 | TASK_WORKER, TASK_WORKER+CANDIDATE, TENANT_ADMIN: `exam_snapshot` is the sentinel on `POST /entities/query`, unrestricted fields readable; CONTROL: a `user_entity_grants` row lifts it; CONTROL: without the restriction row it is readable (mutant M5) | `snapshot_restrictions_test.exs` |
| T-27 | joins: session as FAR side (exam joined to session) and as PRIMARY side (session joined to session_question) redact it; CONTROL grant | same |
| T-28 | `ScriptReads` through `EntityPortImpl.prefetch/3` omits the field (no sentinel); CONTROL row removed -> present; a `match.field` on it is refused | same |
| T-29 | permission golden and `Authorization.role_allows?/2`: CANDIDATE has no `EntitiesQuery`, `EntitiesAggregate`, `EntitiesRecordsExport`, `EntitiesRecordsExportUnredacted` | same |
| T-33 / T-34 | `answer_key_fields/0` is exactly the five pairs; fixture-installed, zero-row (pre-REQ-411) and four-pair tenants end with all five rows after `Exam.ensure_answer_key_restrictions/1`; second run adds 0; `on_install/2` idempotent; unregistered schema -> `{:error, :invalid_schema_name}`; the real `Installs.install` tenant is in `on_install_test.exs` (literal list) | same + `on_install_test.exs` |
| T-30 | full candidate flow (start, state, autosave, signal, submit, certificate, download, public projection), then TASK_WORKER / TENANT_AUDITOR / TENANT_ADMIN probes: (1) Instances GET routes for the synthetic `session` and `answer_option` instance ids are byte-identical to a random uuid and 404 on the content routes, the list omits both, and an inventory test fails if a new GET route that takes an id appears; (2) plain query, aggregate (count; request naming the field refused), default export (admin; others 403); (3) `/audit`, `/promotions/platform-events`, `ScriptReads`; (4) `PUT /entities/records/session/:id` 409 / validation error / success / forged-snapshot echo never return the PRIOR snapshot; (5) public certificate projection. `exam_snapshot`, nonce, digest, `correct_option_ids` and answer-key flags are absent from every body | `exam_snapshot_leak_test.exs` |

The entity port has no other record-READ path (`StepWrites` / `HandlerWrites` are write paths), so
`prefetch/3` is the whole read surface. T-31 / T-32 are PR-0's and merged.

### AC5: the gate, rollout

| Id | What | Where |
|---|---|---|
| T-36 | flag false: `Stamp.run/1`, `Stamp.run_tenant/2`, `Release.ManagedTypes.stamp/1` refuse a real run, stamp nothing, write no audit entry; dry run on each still reports; only the literal `true` opens it (false, nil, key absent, "true", 1, :yes all refuse); unsupported module wins; CONTROL flag true stamps 6; Mix task dry run not blocked and prints `0 gate-blocked`; provenance: set only in `config.exs` (false) and `test.exs` (true), no other config file, `lib/` has no write and no env read, the only read is `Application.get_env(..., false) != true` -- mutant M7 | `stamp_snapshot_gate_test.exs` |
| T-37 | real rollout on a pre-rollout tenant: new active `session` version through `create_definition/3` + `activate_definition/4` only, field-by-field identical except the added `exam_snapshot` (name, display_name, indexes, foreign_keys, constraints, every other field; top-level keys equal), restrictions reconciled, session can start afterwards, second run `already_current`; dry run writes nothing (definition, rows, columns); OQ-9: on a tenant whose `session` is column-promoted the information_schema columns and promotion rows are identical before and after and a pre-rollout session stays readable; rows-only tenant; source guard | `snapshot_rollout_test.exs` |
| T-56 | report shapes of 17.2 (`run/1`, `run_tenant/2`, `verify/0`), release wrapper, `Exam.snapshot_rollout/1` / `snapshot_verify/0` delegates, idempotency, dry run, statuses `:upgraded`, `:already_current`, `:conflict` (field of another type), `:exam_not_installed`, `:skipped_schema_missing`, `:failed` (`no_active_session_definition`, `:nested_transaction`), `verify/0` ready/not-ready, Mix task usage raise and dry-run summary | `snapshot_rollout_test.exs` |
| T-57a | `gate_blocked_total` present and 0 on a dry run; tenant report keys unchanged, no PR-b status | `stamp_snapshot_gate_test.exs` |

## Mutants for TEST-DESIGN-VALIDATOR (all measured; each reverted, `git diff -- lib priv config` empty after each)

Each mutation was applied to the shipped file, only the named tests were run, then the file was
restored from a byte copy. Counts are `failed/selected` of the ExUnit run.

| Id | Mutation | Run | Result |
|---|---|---|---|
| M1 + pre-fix (P0) | `lib/letflow/modules/exam/session.ex` replaced by the pre-change file from `828d9d1be` (live reads of `answer_option`, `question`, exam; 60.0 fallback) | whole `session_snapshot_test.exs` | **27/34 failed** (the file as it stood at that run); the 7 that passed were T-12, T-14, T-43, T-45, T-46 (by-design controls: they behave the same on old code), the R6 ownership test, and the FIRST form of T-13. T-13 was then rewritten (added correct option on a multiple-choice question) and re-checked alone on the old code: it fails there. The R6 query-count test was added after this run and was not run against the old code |
| M2 | `Snapshot` defaults to 60.0 when the threshold is nil or the exam section is absent (3 sites) | snapshot_test + session_snapshot_test AC2/T-42 + threshold/T-54/T-55 describes | **7/24 failed** (T-15, T-16, T-54 nil case, T-55 completeness, session T-15, T-16, T-42 threshold) |
| M3 | `update_session_after_submit` rebuilds the nine named fields instead of merging the locked row | AC1 + terminal describes | **3/15 failed** (T-04 carry-forward, T-14, T-47) |
| M5 | `{"session", "exam_snapshot"}` removed from `@answer_key_fields` | restrictions + on_install + rollout + prerequisite describes | **16/19 failed** (T-26 x4 including the CONTROL, T-27 x2, T-33/T-34, rollout T-37/T-56 counts) |
| M7 | `Stamp.gate_closed?/1` returns false (flag ignored) | `stamp_snapshot_gate_test.exs` | **6/14 failed** (run, run_tenant, release wrapper, strict values, provenance, default) |
| M8 | `Snapshot.fetch_verified/1` skips the digest check | snapshot_test + AC2 | **2/14 failed** (T-18 pure, T-18 session) |
| M10 | autosave and strict state read take the type from the live question row | AC1 + terminal | **2/15 failed** (T-06, T-07) |
| M13 | the create writes the session without `"exam_snapshot"` | AC1 + start-shape + AC2 | **23/23 failed** |
| M15 | a terminal-session state read errors when the snapshot is missing/corrupt | terminal describe | **3/4 failed** (T-43, T-45, T-46; T-47 passes as designed) |

Not applicable to PR a (PR b): M4, M9, M11, M12, M14, M16. M6 is PR-0's.

## Observations and findings (implementation; not fixed, `lib/` is out of scope for this step)

1. **BLOCKER-class for the rollout: a stored definition whose optional field keys are JSON null is
   refused.** `Snapshot.Rollout.optional_atom_value/3` (called from `translate_field/1`) tests
   `Map.has_key?(field, :search_strategy)` and then maps the value through the `@strategies`
   whitelist, so a field stored with `"search_strategy": null` (which is exactly how
   `Definitions.create_definition/2` stores any field built from a `Letflow.Entities.Definition`
   map, including every definition `Letflow.ExamFixtures` and `ExamStampFixtures` create, and
   plausibly the hand-posted QA/BilimBaga rows) yields `{:error, :unsupported_definition_value}`:
   the tenant report is `status: :failed, error: {:definition_write_failed,
   :unsupported_definition_value}` and nothing is written. Reproduced by the failing test
   `snapshot_rollout_test.exs` "REPRO: a stored definition whose optional field keys are JSON null".
   All other rollout tests use `ExamFixtures.downgrade_session_definition_without_nils!/1` (keys
   with no value left out) and pass. Fix direction: treat a nil value of an optional key as absent
   (drop or keep nil) for `search_strategy` and the other optional keys.
2. Soft deletion does not hide rows from `query_all/3` in `Session` (`Latest.get/3` and the
   compiler still return `deleted: true` rows): a deleted `answer_option` is still listed by the
   state read and still counted when the snapshot is built, and a manual pin to a SOFT-DELETED
   `active` question is accepted. Design 3.4 says a deleted option "disappears from the rendered
   options"; the code shows it does not. Pre-existing behaviour, not caused by this PR; the tests do
   not pin it either way (T-13's deleted half is a documented no-crash control).
3. `managed_cannot_upgrade` (a stamped `session` lacking the field) is unreachable in PR a: the
   stamp's compatibility check rejects a `session` definition without `exam_snapshot` (pack field)
   as `shape_not_compatible`, so no test can build the state without writing the stamp GUC
   directly, which the stamp tripwire scan forbids. Not tested.
4. The `lock_timeout` rollout error path is not exercised (needs a second connection holding a
   definition-row lock); the Mix tasks' `System.halt(1)` branches cannot run in-process, so the
   stamp and rollout task exit paths are source-guarded plus covered through the report fields.

## Not run

`mix letflow.check.test` (the full parallel suite, which the ISS-0069 dead-default-argument grep
needs) was NOT run: this step was told never to run the full suite. Substitute evidence: every
new and changed test file compiles fresh on each `mix test` invocation, and the logs of all runs
(11 batches) were grepped for `default values for the optional arguments`: 0 hits; helper functions
with a default (`opt/2`, `build/3`, `request/4`, `request/5`) are called with and without it.

## Coverage check

- [x] Every acceptance criterion in PR a's scope has at least one test that fails when it is violated (mutants above).
- [x] Closed state sets (the five question types, the grading reasons) are covered by a table-driven completeness test and a property test.
- [x] Regression proof: the scoring/autosave/state tests fail against the pre-change `session.ex` (27 of 34).
- [ ] The rollout against a definition with JSON-null optional keys passes (blocked on finding 1).
