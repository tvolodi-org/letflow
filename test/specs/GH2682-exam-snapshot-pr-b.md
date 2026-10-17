# Test Spec: GH #2682 / REQ-511 PR b -- certificate from the snapshot, lazy late snapshot with cutover, Stamp prerequisites, flag true

**Requirement:** REQ-511 (GH #2682). Design: `lib/letflow/design/req511-exam-content-snapshot.md`
(sections 6, 9, 10, 12, 13, 14, 17, 18.5, 18.6). PR b only: storage, scoring read, restrictions seed,
rollout and the flag refusal are PR a (`test/specs/GH2682-exam-snapshot-pr-a.md`). Acceptance criteria
(GH #2682 body, with the REQ-VALIDATOR corrections), PR b's share:

1. Editing the certificate flag or the title after session start does not change that session's
   certificate (one test per field class): T-09, T-10, T-11.
2. (PR a) typed grading errors; PR b adds the certificate-side reasons: T-55c.
3. The in-flight policy: a session that started before the snapshot code shipped gets a `late`
   snapshot at its first touch, bounded by the cutover rule, audited; terminal sessions are never
   snapshotted except certificate-only facts: T-21..T-25, T-44, T-48..T-52, T-58..T-63b.
4. (PR a) restrictions and leak.
5. Gate: the flag flips to `true` here; the live gate is the per-tenant prerequisite: T-38, T-39,
   T-40, T-57b.
6. Design validated, SECURITY-REVIEWER and REVIEWER code verdicts (process).

**Test tier:** integration (real Postgres, real tenants) + HTTP through `Letflow.Router` with a real
CANDIDATE token + source guards. No mocks.

## Facts of the implementation these tests follow

The dev handoff step-01 (PR b), the SECURITY-REVIEWER step-02 and the REVIEWER step-03 verdicts
supersede the design text where they differ:

* **D-b1 (accepted deviation).** `Snapshot.ensure_locked/2` returns
  `{:ok, snapshot, session_after, :existing | :late}` and only BUILDS (reads); `submit`/`finalize`
  persist `session_after.field_values` in their ONE session update, then call
  `Snapshot.record_late/4` (the audit entry) as the last statement. `ensure/3` and
  `ensure_certificate_facts/3` write at once (session row, then audit). T-59 is written against that.
* The cutover is compared with `entity_record_latest.inserted_at` of the session RECORD (server-set,
  never rewritten by an update), strictly: `inserted_at < cutover` allows a late snapshot, equal fails
  closed. The writable `started_at` field is never compared.
* `Snapshot.cutover/1` is the MINIMUM `activated_at` over `artifact_activation_history` rows of the
  `session` entity whose version declares a field named `exam_snapshot`; no row is
  `{:error, :definition_missing}` (-> `{:snapshot_error, :definition_missing}`, 503); a schema that
  is not a registered tenant is `{:error, :invalid_schema_name}`.
* `Snapshot.check_prerequisites/1` (active `session` definition declares the json field
  `exam_snapshot`, and its restriction row exists) now guards the start AND every late snapshot.
* `Stamp`: `prerequisites_missing` is judged only for a REAL run, only while the tenant still has an
  unstamped row, in the advisory pass and again from the LOCKED rows; the judged definition row is
  the ACTIVE one (none active: the newest by `inserted_at`; SECURITY N1); every NULL row of a
  stampable name is still stamped. Order of `prerequisites_missing`:
  `[:session_definition, :answer_key_restrictions]`. `gate_blocked_total` counts
  `:snapshot_not_complete` and `:snapshot_prerequisite_missing`.
* The answer-key restriction pairs are FIVE (the design's "six" is an arithmetic error).
* `Latest.get/3` returns SOFT-deleted rows (it does not filter `deleted`), so "the live row is gone"
  cases use a hard delete (a direct test-support write) and "soft-deleted live exam" is a separate
  T-11 variant. See Observations.
* SEC N2: `certificate_enabled` is `required: true, type: boolean` in the `exam` definition, so nil /
  absent cannot come from a validated write. If a row holds nil (direct write) the snapshot carries
  nil and the certificate is `{:grading_error, :certificate_facts_missing}` (HTTP 500, constant
  body), not the old 409. Tested as the actual behaviour (see T-55c / N2 below). This is the design's
  own T-55c, so it is not an implementation defect.

## New test files

| File | Tier |
|---|---|
| `test/letflow/modules/exam/snapshot_late_test.exs` | integration (tenant, Records, Session, Snapshot, audit) |
| `test/letflow/modules/exam/certificate_snapshot_test.exs` | integration (Certificate, Session, Snapshot) |
| `test/letflow/modules/exam/exam_snapshot_late_router_test.exs` | HTTP, real CANDIDATE token |
| `test/letflow/entities/managed_types/stamp_snapshot_prerequisites_test.exs` | integration (Stamp, Release wrapper, Mix task source guard) |

Support (tests only): `Letflow.ExamFixtures.legacy_session!/2` (the ONE legacy-session helper of
design 18.5: removes `exam_snapshot`, moves `entity_record_latest.inserted_at` one hour before
`Snapshot.cutover/1`, sets `started_at` before the cutover and `expires_at` one hour ahead) and
`Letflow.ExamStampFixtures.stamp_ready_tenant!/1` (a hand-built exam tenant that already holds the
five restriction rows a rolled-out tenant has).

## Existing tests changed (tests only; `lib/`, `priv/`, `config/` untouched)

| File | Change | Why |
|---|---|---|
| `test/letflow/entities/managed_types/stamp_snapshot_gate_test.exs` | T-36 provenance test rewritten: `true` in `config/config.exs` and `config/test.exs` (and NOT `false` in config.exs), the flag nowhere else (also asserts `runtime.exs` never mentions it); tenant report key list gains `:prerequisites_missing`; the PR a "adds no prerequisite key" test now asserts the key is `[]`; header updated. The closed-gate tests are unchanged (they set the flag to `false` with `Application.put_env/3` and restore it) | PR b is the single flip; the old assertion was `false` (the failing test REVIEWER named, `:204-206`) |
| `test/letflow/entities/managed_types/stamp_test.exs` | the five hand-built exam tenants (`b2`, `b3`, `b4`, `tag`, `tenant_with_certificate!`) start from `stamp_ready_tenant!/1`; the OLDER-VERSION test (SECURITY F-3) rewritten to the judged-row rule (a hostile OLDER row no longer conflicts when the newest is good; a newest-hostile still does) plus a new active-row case; the SECURITY F-4 race test now creates AND activates the hostile version | hand-built tenants had no restriction rows, so a real run now reports `:snapshot_prerequisite_missing`; "every version" is gone (design 10.2) |
| `test/letflow/modules/exam/snapshot_test.exs` | T-55 completeness test now produces `:certificate_facts_missing` too and drops `@pr_b_reasons` | the table is complete in PR b |
| `test/letflow/modules/exam/session_snapshot_test.exs` | header and one test title: the snapshotless in-progress cases are POST-cutover records (T-61), not "no late path" | wording only; the assertions still hold (a plain fixture session is after the cutover) |

Run unchanged and expected green (read, no edit needed): `certificate_test.exs`,
`exam_sessions_test.exs` (all its sessions come from `Session.create`, so the certificate reads the
snapshot taken at start; the live-edit cases are the new files above), `session_test.exs` (its
hand-built sessions are terminal), `exam_snapshot_router_test.exs`, `snapshot_rollout_test.exs`,
`stamp_trigger_test.exs`, `tamper_inventory_test.exs`, `exam_stamped_tenant_test.exs`,
`exam_managed_types_http_test.exs`.

## Acceptance criterion -> test map

### AC1: certificate reads only the snapshot (`certificate_snapshot_test.exs`, `exam_snapshot_late_router_test.exs`)

| Id | Field class | Test | Fails on the pre-PR-b `certificate.ex`? |
|---|---|---|---|
| T-09 | `exam.certificate_enabled` | enabled at start / disabled after submit: issued; disabled at start / enabled later: `:exam_not_certifiable`; same over HTTP (200 + PDF, 409) | yes (it read the live flag) |
| T-10 | `exam.title` | title edited after start: `exam_title` is the original; a snapshot with another title and an unchanged live title decides the certificate | yes |
| T-11 | no live exam read | exam archived, soft-deleted, hard-deleted, nil flag / missing title after the submit: issuance succeeds; over HTTP the row removed | yes |
| T-55c | `:certificate_facts_missing` | pure `Snapshot.certificate_facts/1` table (nil / string / integer flag, missing `exam`, nil / missing title); a stored snapshot with a non-boolean flag, nil flag, missing title, missing flag; no certificate is created | -- (new reason) |
| N2 | nil flag on a live row | start with a nil live flag: the snapshot carries nil, the certificate is `:certificate_facts_missing`; the definition field is asserted `required: true, boolean` | -- |
| guards | order unchanged | not passed -> `:session_not_passed`, not submitted -> `:session_not_submitted`, ownership `:not_owner` / `:session_not_found` (no write for a legacy session), corrupt snapshot `:snapshot_corrupt` and not replaced (also on a pre-cutover record) | -- |

### AC3: in-flight policy (`snapshot_late_test.exs`, `certificate_snapshot_test.exs`)

| Id | What | Test |
|---|---|---|
| fixture | `legacy_session!/2` | a plain session is after the cutover; the helper makes it before it, snapshotless, deadline ahead |
| T-21 / T-60 | autosave and state read of a pre-cutover session | late snapshot written (origin `late`, `taken_at`, digest verifies), equals the start snapshot of the same rows modulo provenance fields, one audit entry; a later authoring edit changes neither the key nor the score; the state read freezes the type; a second read writes nothing |
| T-22 | submit with no earlier touch | snapshot taken under the lock, scored from it (an edit before the first touch is part of it: documented residual), survives the submit's own write, audit actor = submitter |
| T-23 | `finalize_expired` | `auto_submitted`, `late` snapshot, audit entry with a nil actor, replay writes nothing |
| T-24 | concurrency (M4) | four concurrent `ensure/3`: identical results, exactly ONE update event, ONE audit entry; a state read racing a submit and an ensure: one snapshot, one entry; a VALID snapshot on a pre-cutover record is returned as is (no rebuild, no write, same nonce) |
| T-25 | prerequisites | tenant without the `exam_snapshot` field: every touch `{:snapshot_error, :definition_missing}`, nothing written, works after `Rollout.run_tenant/2`; tenant without the restriction row: `:restrictions_missing`; legacy submitted session in an un-rolled-out tenant: certificate refuses, works after the rollout; legacy submitted + passed: `late_certificate` facts persisted once, certificate issued, second request does not re-snapshot |
| T-44 | `late_certificate` state read | terminal: OK with the LIVE type, zero events; an in-progress session holding such facts: `:snapshot_corrupt` |
| T-48..T-51 | late build with broken live rows | live threshold nil `:threshold_missing`; exam hard-deleted `:exam_section_missing`; a question hard-deleted `{:question_item_missing, id}`; no correct option / likert option without weight or polarity `{:key_missing, id}`: `ensure/3` and `submit/3` both return the typed error and the row, event log, audit log and score rows are unchanged |
| T-52 | non-owner | autosave, state, submit, `ensure/3`, `ensure_certificate_facts/3` by another user: `:not_owner`, unchanged state; random id `:session_not_found` (M9) |
| T-58 | audit entry | exactly one entry, keys `exam_id origin started_at taken_at`, ids/names only (no key material), actor / resource; a failing audit insert (a CHECK constraint on the tenant's `audit_entries`) rolls back `ensure/3`, a late `submit/3` and the certificate facts (row, events, scores, certificate all unchanged); `record_late/4` maps the failure to `{:snapshot_error, :audit_failed}` and logs a tag, never digest or nonce (M16) |
| T-59 | `ensure_locked/2` (M14) | returns `{:ok, snapshot, session_after, :late}`, writes nothing (state, events, audit unchanged, persisted row still snapshotless), `session_after.field_values` = row + snapshot; with a snapshot `:existing` and the same row; a late submit writes exactly as many events as a plain submit (one session update carries the snapshot) and the persisted row has the late snapshot |
| T-61 | post-cutover record lost its snapshot (delete or nil) | every touch `:snapshot_missing`, nothing written, no audit entry; also the certificate facts (context and HTTP 500) |
| T-61b | `started_at` rewritten far into the past | still `:snapshot_missing` |
| boundary | strict `<` | inserted exactly AT the cutover: refused; one microsecond earlier: healed |
| T-62 | fresh-install tenant | `Installs.install("exam")` creates every definition INACTIVE (`SolutionPack.install` never activates, decision 0026 section 2), so right after the install there is no activation row and `Snapshot.cutover/1` is `{:error, :definition_missing}`; after the go-live `Definitions.activate_definition("session", ...)` the cutover is exactly that activation (the pack's `session` already declares `exam_snapshot`); a fixture tenant likewise. Design 18.5 says "pack install ... go through activate_definition/4": the install itself does not, the go-live does (see Observations) |
| T-63 | R6 | tenant not rolled out: non-owner and random id get `{:error, :not_owner}` / `{:error, :session_not_found}` at EXACTLY the same Repo query count (`ensure/3`, `ensure_certificate_facts/3`, autosave, state); the owner gets the 503-class error; over HTTP the two get byte-identical 404s on GET state, PUT answer, POST submit, POST events, POST certificate, GET download |
| T-63b | `Snapshot.cutover/1` | none: `:definition_missing`; after the rollout the MIN activation of a field-declaring version; a later field-declaring version does not move it; an EARLIER version without the field is ignored; active definition with no history row: `:definition_missing` and the touch is the 503-class error, nothing written; unregistered schema `:invalid_schema_name` |
| I-3 | terminal sessions | legacy `submitted`, `auto_submitted`, `grading_pending`: state read OK, `ensure/3` `:snapshot_missing`, autosave `:session_not_in_progress`, submit and finalize replays, all zero writes; certificate facts only for `submitted` (auto_submitted and grading_pending, and in_progress: `:snapshot_missing`) |
| counts | `Snapshot.late_origin_counts/1` | fresh tenant 0/0; 2 late + 1 late_certificate (start snapshots not counted); bad prefix `:invalid_schema_name` |

### AC3 over HTTP (`exam_snapshot_late_router_test.exs`)

| Id | What |
|---|---|
| T-20b | certificate and download: `snapshot_corrupt`, `certificate_facts_missing` and `snapshot_missing` are the SAME constant 500 (`exam grading failed; the session was not scored`), byte-identical per route, no reason / id / word of the snapshot in the body; a rollout gap (definition, restriction row) is the constant 503 (`exam service is being upgraded; retry shortly`) on both, no PDF headers; T-61 over HTTP is the constant 500 |
| legacy flow | a pre-cutover session: first touch GET state (200, late snapshot, no `exam_snapshot` in the body), PUT answer, POST submit, certificate 200; a legacy submitted session: certificate 200 + PDF from `late_certificate` facts, bodies carry no snapshot words |

### AC5: Stamp (`stamp_snapshot_prerequisites_test.exs`, `stamp_snapshot_gate_test.exs`, `stamp_test.exs`)

| Id | What |
|---|---|
| T-38 | active `session` definition lacks the field: `:snapshot_prerequisite_missing`, `[:session_definition]`, nothing stamped, no audit entry; after the rollout it stamps; no `session` row at all is blocked the same way |
| T-39 | no restriction rows / one missing pair (the snapshot pair): `[:answer_key_restrictions]`; both: fixed order; once reconciled it stamps |
| T-40 | old inactive version without the field + new active with it: stampable, EVERY row of the name stamped (8 rows), second run `:nothing_to_stamp`; an ACTIVE hostile row still conflicts, an INACTIVE hostile next to a good active row does not (M12); N1: no active version, the newest is judged |
| T-57b | sweep: blocked tenant reported, sweep continues, `gate_blocked_total` counts it; the Release wrapper returns the same report (the Mix task halts on exactly `failed_total > 0 or gate_blocked_total > 0`: source guard, `System.halt(1)` cannot run in-process); a dry run is never blocked and prints `0 gate-blocked`; report keys stable |
| scope | a fully stamped tenant stays `:nothing_to_stamp` when a restriction row later disappears; the prerequisites are re-judged from the locked rows (`after_precheck` seam: restriction row deleted, or a field-less session version activated, after the advisory pass); the closed flag wins over the prerequisite (`:snapshot_not_complete`) |
| T-36 | flag provenance: `true` in `config.exs` and `test.exs`, not `false`, nowhere else, not in `runtime.exs` |

## Mutants (each applied locally by editing `lib/`, the named tests must fail, then reverted with `git checkout` and checked with `git diff --quiet` on lib/modules, lib/entities, lib/release, lib/mix, config, priv)

Measured counts are in the last column of both tables (`failed of run`, one `mix test --warnings-as-errors` invocation of the named files; every mutant compiled warning-free).

| Id | Mutation | Must fail | Measured |
|---|---|---|---|
| M4a | `Snapshot.ensure_locked/2`: the `{:error, _corrupt}` branch calls `build_missing/2` instead of returning the error | `snapshot_late_test.exs` T-18b corrupt (non-object value); PR a `session_snapshot_test.exs` T-18 non-object | 2 failed of 95 (`snapshot_late_test` + `certificate_snapshot_test` + `session_snapshot_test`). The stale-DIGEST variants are not caught by this mutant: that error comes from `fetch_verified/1` inside the `{:ok, _}` branch, which is separate code |
| M4b | `ensure_locked/2`: the `{:ok, _}` branch calls `build_missing/2` (an existing snapshot is rebuilt) | T-24 (concurrency, existing returned as is), T-59 `:existing`, T-44, T-58, T-21, T-22, I-3, `late_origin_counts` | 11 failed of 39 (`snapshot_late_test`) |
| M9 | `Snapshot.ensure/3`: remove `:ok <- check_owner(session, user_id)` | T-52, T-63 parity | 2 failed of 39 (`snapshot_late_test`) |
| M11 | `Certificate.issue_or_get_for_user/3`: read the facts from the live exam row instead of the snapshot | T-09, T-10, T-11, T-55c, N2, late_certificate, T-20b (`certificate_snapshot_test.exs`, `exam_snapshot_late_router_test.exs`) | 13 failed of 31 |
| M12 | `Stamp.incompatible_judged_rows/2`: judge every row (`Enum.reject(rows, &compatible?(...))`) again | T-40 (3 tests), T-38 end-to-end, the rewritten OLDER-VERSION test, the active-judged test | 6 failed of 40 (`stamp_snapshot_prerequisites_test` + `stamp_test`) |
| M14 | `Snapshot.build_missing/2`: return the stale `session` instead of `put_snapshot(session, snapshot)` | T-22, T-59 (3 tests), T-21, T-23, the HTTP legacy flow | 12 failed of 49 (`snapshot_late_test` + `exam_snapshot_late_router_test`) |
| M16 | `Snapshot.record_late/4`: skip `Audit.insert_entry/3` (`case (if prefix == "", do: Audit.insert_entry(...), else: {:ok, nil})`) | T-58 (4 tests), T-21/T-22/T-23/T-24, late_certificate audit, boundary, `late_origin_counts` is unaffected | 15 failed of 60 (`snapshot_late_test` + `certificate_snapshot_test`) |

PR b-specific mutants (offered to TEST-DESIGN-VALIDATOR to re-apply; none is in design section 14):

| Id | Mutation | Must fail | Measured |
|---|---|---|---|
| M17 | `Snapshot.check_before_cutover/2`: `== :lt` becomes `in [:lt, :eq, :gt]` (always allowed) | T-61, T-61b, boundary, certificate T-61, HTTP T-61 / T-20b | 6 failed of 70 (`snapshot_late_test` + `certificate_snapshot_test` + `exam_snapshot_late_router_test`) |
| M18 | `check_before_cutover/2`: `== :lt` becomes `!= :gt` (an instant equal to the cutover is allowed) | the strict boundary test | 1 failed of 39 (`snapshot_late_test`) |
| M19 | `Stamp.prerequisites_missing/2`: always `[]` (extra `and schema == ""`) | T-38, T-39 (3 tests), T-57b, RACE, flag-first | 11 failed of 17 (`stamp_snapshot_prerequisites_test`) |
| M20 | `Stamp.sweep/3`: `gate_blocked_total` counts only `:snapshot_not_complete` | T-57b sweep and Release wrapper | 2 failed of 17 |
| M21 | `Stamp.real_run`: drop the prerequisite re-check from the LOCKED rows | the two RACE tests | 2 failed of 17 |
| M22 | `Snapshot.build_missing/2`: drop `require_status(session, "in_progress")` | I-3 terminal tests | 1 failed of 39 |
| M23 | `Snapshot.certificate_snapshot/3`: drop `require_status(session, "submitted")` | the in-progress / auto_submitted / grading_pending certificate-facts tests | 2 failed of 60 (`snapshot_late_test` + `certificate_snapshot_test`) |
| M24 | `Snapshot.ensure_certificate_facts/3`: `check_owner` removed | T-52, T-63 (`certificate_facts` leg) | 2 failed of 60. Note: this run overlapped another agent's mix process (the mutex directory was replaced at 12:38; see handoff) |

## Observations (not defects of the tested behaviour; for ORCH / REVIEWER)

* `Latest.get/3` does not filter `deleted: true`. `Snapshot.build_late/3` and
  `build_certificate_only/3` read the live exam / question through it, so a SOFT-deleted exam or
  question is still used to build a late snapshot. A hard delete (row gone) is the typed error
  (T-49, T-50). Not asserted either way for the soft delete (the T-11 soft-delete case is about the
  certificate reading the SNAPSHOT, which is unaffected).
* A failed (not passed) legacy submitted session that requests a certificate takes the
  `late_certificate` facts (and the audit entry) before the 409 `:session_not_passed`: the design's
  guard order, flagged by REVIEWER as a non-blocking suggestion. Not pinned by a test.
* The Mix task's real-run exit (`System.halt(1)`) is asserted by source guard plus the exit condition
  evaluated on the report, as in PR a; a nested `mix` spawn would need the `nested_mix_test.exs`
  allowlist and would sweep the whole test database.
* Design 18.5 states that "pack install and the rollout both go through `activate_definition/4`".
  The rollout does; `SolutionPack.install` does NOT (it creates every definition `:inactive`, decision
  0026 section 2). So a freshly installed exam tenant has no `artifact_activation_history` row, and
  `Snapshot.cutover/1` is `:definition_missing`, until the tenant goes live; at that point it has no
  legacy sessions anyway and the cutover is its go-live activation (T-62 asserts both states). Not a
  defect (fails closed, and no session can start before an active `session` definition exists), but
  the design sentence is imprecise.
* Test-only change to the MUTEX note: the machine mix mutex directory created by this agent was
  replaced (by another agent, ELIXIR-DEV-2654) at 12:38 while mutant M24 and the final format check
  were running; nothing of this agent's remained to release.

## Verified runs (this agent, `LETFLOW_DEV_DB_CONFIRMED=1 MIX_ENV=test mix test --warnings-as-errors <files>`)

| Files | Result |
|---|---|
| `snapshot_late_test.exs` | 39 passed |
| `certificate_snapshot_test.exs` + `exam_snapshot_late_router_test.exs` | 31 passed |
| `stamp_snapshot_prerequisites_test.exs` + `stamp_snapshot_gate_test.exs` | 31 passed |
| `stamp_test.exs` + `snapshot_test.exs` | 69 passed |
| `session_snapshot_test.exs` + `exam_snapshot_router_test.exs` + `certificate_test.exs` | 52 passed |
| `exam_sessions_test.exs` + `exam_stamped_tenant_test.exs` | 41 passed |
| `session_test.exs` + `snapshot_rollout_test.exs` | 67 passed |

`mix letflow.check.test` runs the WHOLE suite and was NOT run (instruction: never the full suite;
hosted CI runs it). The dead-default-argument class it exists for is covered by the
`--warnings-as-errors` runs above (test modules recompile on every `mix test`; no helper added here
has a default argument) and `grep -c "default values for the optional arguments"` over this agent's
logs is 0. `mix format --check-formatted` on every touched test file: clean.
