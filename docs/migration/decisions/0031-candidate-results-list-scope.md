# 0031 — Candidate results-list scope: Letflow does not serve a cross-session results-LIST today; the gap is recorded, not built

Status: decided (2026-09-15, `CODE-DESIGNER`, REQ-350). `SECURITY-REVIEWER`
skipped by explicit `REVIEWER` judgment (docs-only, no tenant-data path);
`REVIEWER` sign-off: PASS (2026-09-15). See sign-off sections below.
Owner: `ORCH` (this record settles a standing open question in
`docs/migration/stage-10-bilimbaga-vertical.md`'s "Open questions" section; it
produces no implementation, and none is scheduled by it).

## Allocation note

`docs/requirements.yaml`'s REQ-350 entry states an `ORCH` pin of `0032` at
registration time (highest existing record then was `0030`, with REQ-353 pinned
to `0031` in the same pass). Per this requirement's own acceptance criteria, the
number is re-verified at write time rather than trusted from the pin. Running
`ls docs/migration/decisions/` immediately before creating this file returned,
as its highest four entries:

```
0027-solution-pack-service-catalog-install-policy.md
0028-unauthenticated-read-boundary.md
0029-solution-pack-scripted-rules-and-role-seeding-scope.md
0030-exam-session-p3-bucket-verdicts.md
```

No `0031-*.md` file exists in that listing — REQ-353's pinned `0031` had not
been registered yet at the moment this file was written. **The actual number
allocated is `0031`, taken as the lowest free number at write time, not the
`0032` the requirement text pinned.** This substitution is stated here
explicitly, per the requirement's own instruction, rather than silently
overwriting or reusing another requirement's number. The stage-file citation
this record's companion edit writes (see "Consequences" below) cites `0031`,
read back from this file's own name, not from the original pin.

## Why this record exists

`docs/migration/stage-10-bilimbaga-vertical.md`'s "Open questions" section
carries an item beginning "No way to view a past exam result — surfaced twice
during P5, recorded here before it surfaces a third time," whose closing
sentence is the mandate this record answers: *"Deciding whether Letflow should
route `GetSessionResult`, a results-list, or neither is a product-scope
question that P5 must not settle by side effect. It needs its own requirement
once `REQ-349` reports how much of the result-side corpus is actually
unportable without it."* `REQ-349` is done and has reported (see "The measured
evidence" below). This record is that requirement's answer for the
results-LIST half of the gap; the single-result-by-id half is a separate,
already-settled matter (`REQ-351`, frontend-only, no new backend route, not
decided here).

## The scope fence this record examines — and confirms was correct, not a defect

`lib/letflow/routers/exam_sessions.ex`'s moduledoc states, verbatim, under
"Deliberately NOT routed here, and why (REQ-335's own scope fence)":

> **Cross-session history / results-list views**
> (`GetExamHistory`/`HandleGetMyResults`, FR-BB41/FR-BB46) -- outside
> REQ-330's five analysed behaviours (start, autosave, submit, anti-cheat
> signal, and this route's own state read); `GetSessionResult` is also not
> routed here for the same reason -- a *result* view is a sixth behaviour
> this requirement's own dependency chain (REQ-330's five) never
> authorized, not a subset of the *state* read this module does implement.

**This record states explicitly: that was a CORRECT `REQ-335` scope decision
at the time, not an oversight to be corrected.** `REQ-335`'s dependency chain
(`REQ-330`'s five analysed live-session behaviours) genuinely never included a
results view of any shape, and routing one anyway would have been scope creep
against that requirement's own analysed behaviour set. Nothing below reopens
that judgment as a mistake — this record decides only whether a *later,
independent* requirement should now build the sixth behaviour `REQ-335`
correctly declined to build.

## The measured evidence, re-derived from the P5 close-out table

`REQ-349`'s P5 close-out (`docs/migration/stage-10-bilimbaga-vertical.md`,
"## P5 close-out — REQ-348, 2026-09-14") reports **34 of 168** corpus
`test()` blocks ported and passing, with 90 whole-file NO-COUNTERPART. The
per-file table rows for the three files touched by the missing results
surface, quoted directly:

| Source file | Blocks | Ported file | Ported | Drop reason |
|---|---|---|---|---|
| `my-results.spec.ts` | 6 | *(same file)* | 0 | all 6 dropped, NO-COUNTERPART (cross-session results-LIST view — `REQ-335`'s scope fence excludes it; no `/portal`-equivalent route exists) |
| `exam-result.spec.ts` | 5 | `exam-result.e2e.spec.ts` (shared with `my-results.spec.ts` below) | 4 | 1 dropped, NO-COUNTERPART (result-by-id deep link — `REQ-335`'s own scope fence excludes result-by-id/results-list views; no route exists) |
| `employee-portal.spec.ts` | 8 | `employee-portal.e2e.spec.ts` | 3 | 5 dropped, NO-COUNTERPART (Start-modal open/cancel, Continue CTA, View-Result CTA, "My Results" page — none exist; `ExamListPage`'s Start button navigates directly, no modal) |

Of `employee-portal.spec.ts`'s 5 drops, only **2** (the View-Result CTA and
the "My Results" page) are caused by the missing results surface; the other
**3** (Start-modal open/cancel, the Continue CTA) are unrelated surfaces and
are explicitly excluded from this record's count, per the requirement's own
instruction not to fold in drops with other causes.

**Total: 9 of 168 blocks (≈5.4%) are blocked specifically by the missing
results surface** — `my-results.spec.ts` 6 + `exam-result.spec.ts` 1 +
`employee-portal.spec.ts` 2. Of those nine, **SIX are whole-file blocked**
(`my-results.spec.ts`, 0 of 6 ported) and the **other three are within-file
drops** from files that did port in part (`exam-result.spec.ts` ported 4 of
5; `employee-portal.spec.ts` ported 3 of 8). The figure "seven whole-file
blocked" does not appear anywhere in this record and is false; it is not used
here.

**This record states honestly: nine tests is a small number, and it is not on
its own a mandate to build.** "Do not serve it, and record why" is weighed
below on equal footing with "serve it."

## The decisive technical fact and the constraint on any "serve it" design

A candidate's own results-list is expressible through machinery that already
exists. `priv/packs/bilimbaga/entity_definitions/session.json` declares
`user_id`, `exam_id` and `status` as `queried: true` (status carrying four
enum values: `in_progress`, `submitted`, `auto_submitted`,
`grading_pending`), with an index `idx_session_user_exam_status` over
`(user_id, exam_id, status)`. `Letflow.Exam.Session`'s own private
`query_all/3` helper (`lib/letflow/exam/session.ex:1130`) already compiles
exactly this shape of filtered read through
`Letflow.Entities.Query.Compiler`. So "sessions belonging to the calling
candidate, filtered by status" needs no new query capability.

**The constraint that shapes any "serve it" design:** in the same
`session.json`, `submitted_at`, `score_pct` and `passed` are all declared
`queried: false`. They can be *returned* in a row but can never be filtered
on or sorted by through the entity query DSL as it stands today — a "sort by
date, most recent first" or "filter to failed attempts only" results-list is
not directly expressible against the current definition.

## Decision

### 1. Whether Letflow serves a cross-session results-LIST for the calling candidate at all — NOT TODAY. Recorded as a real gap, not built.

**No results-LIST surface is built by this record, and none is scheduled by
it.** Weighing the evidence above:

- **For building it:** the capability is cheap relative to most bucket-B/C
  work — the read shape already exists (`query_all/3` over `session`), and
  the candidate-owner scoping this needs is the same `user_id` predicate
  `Letflow.Exam.Session.get_session_state_for_user/3` already applies
  elsewhere in the module. Nine real Playwright blocks name it directly, and
  a candidate genuinely has no way today to see a list of their own past
  attempts once the submitting browser tab is gone.
- **Against building it now:** nine of 168 corpus blocks (5.4%) is a small
  fraction to build a new product surface against, and — critically — a
  *usable* results-list (sortable by date, filterable to failed attempts,
  the two behaviours the corpus and the roadmap actually name) is **not**
  expressible against the current entity definition without one of two real
  changes (§4 below), neither of which is free: it is either a pack-schema
  migration with DDL consequences, or an in-memory-sort implementation
  detail that a `CODE-DESIGNER` would need to size and a `TEST-DESIGNER`
  would need to prove bounded (an unindexed in-memory sort over "all of one
  candidate's sessions across all exams" has no natural page-size cap the
  entity query DSL enforces for it). Building the list surface and its
  sort/filter fix in the same requirement that discovers the fix is needed
  is exactly the kind of open-ended sizing `REQ-VALIDATOR` exists to catch,
  and no such requirement is filed or sized yet.
- **The companion requirement, `REQ-351`, already closes the higher-value
  half of the same gap** (a candidate's own single just-submitted result,
  durably viewable by session id) without touching this record's territory
  at all, and does so with zero new backend surface — it reuses an already-
  routed, already-owned read. That leaves the marginal, additional value of
  *also* building the list surface smaller than it would be if `REQ-351`
  did not exist: a candidate who wants to see one particular past result can
  already reach it (by REQ-351) if they still have the link/id; only the
  "show me everything I've ever taken" list view remains unserved.

**Verdict: do not serve a results-list surface at this time.** The gap is
real, measured, and filed (this record), not silently dropped — see
"Revisitability" below for the trigger under which this verdict should be
reopened.

### 2. Route-vs-entity-query — moot given §1's "no," but stated for a future requirement to adopt without re-deriving it

**If this were ever built, the entity-records-query shape is the right one,
not a new `ExamSessions` route.** `web/src/api/exam.ts` already calls
`POST /entities/query` directly for the exam list screen (`client.post<ExamRecordsPage>('/api/v1/entities/query', { entity_type: 'exam', ...query })`,
line 123) — real, shipped precedent for a candidate-facing list screen built
directly against the generic entity-query route rather than a bespoke
`Letflow.Routers.ExamSessions` endpoint. A results-list is architecturally
the same shape (a filtered, owned-by-caller list of one entity type), and
`Letflow.Exam.Session`'s own `query_all/3` already proves the `session`
entity type compiles through the same `Letflow.Entities.Query.Compiler` the
generic route uses. Building a bespoke `GetExamHistory`/`HandleGetMyResults`
route on `ExamSessions` would duplicate a capability the generic route
already provides, for no behaviour a generic query cannot express (modulo
§4's sort/filter constraint, which is a schema-flag question, not a
routing-layer one). A future requirement that adopts §1's reversal should
build against the generic entity-query route, not a new `ExamSessions`
endpoint.

### 3. FR-BB41 (GetExamHistory) vs. FR-BB46 (HandleGetMyResults) — ONE surface, not two

**These are one surface, not two, if either is ever built.** `REQ-335`'s
scope fence names them together for a reason that holds up: both are "a list
of this candidate's own past sessions," differing only in whether an
`exam_id` filter is applied (`GetExamHistory` — across all exams;
`HandleGetMyResults` — scoped to one exam). Given §2's chosen shape (a
generic entity-query read filtered on `user_id` and optionally `exam_id`),
the two BilimBaga endpoints collapse to the same underlying read with an
optional filter clause — there is no independent behaviour in one that the
other's mechanism does not already cover. A single "candidate's own sessions,
optionally scoped to one exam" capability serves both FR-BB41 and FR-BB46;
building two separate surfaces for what is one parametrized query would be
the kind of needless duplication `0022`'s bucket rules exist to prevent.

### 4. The queried:false sort/filter constraint — moot under §1's verdict; stated for the record

Since §1's verdict is not-to-serve, no sort or filter implementation is
built, and the constraint therefore does not need to be resolved today. **For
a future requirement that reverses §1**, this record states the two real
options rather than leaving them undiscovered:

1. **Flip `submitted_at`, `score_pct` and `passed` to `queried: true`** in
   `priv/packs/bilimbaga/entity_definitions/session.json`. This is a real
   pack-schema change with real DDL consequences —
   `Letflow.Entities.Definition.Validator` and
   `lib/letflow/entities/definition/ddl.ex` drive actual database DDL
   (indexed/promoted columns) from these flags, so this is not a
   documentation-only edit; it needs its own migration path and its own
   `CODE-DESIGNER`/`ELIXIR-DEV` turn against `Letflow.Entities.Definition`'s
   promotion machinery.
2. **Sort/filter in memory after an unfiltered-by-those-fields read.** Cheaper
   to ship, but only sound with an enforced page/window bound — an
   unbounded in-memory sort over "all sessions for this candidate across all
   time" is a latent cost/DoS surface as a candidate's history grows, and
   whichever future requirement picks this option must size that bound
   explicitly rather than inherit "assume it stays small" as an unstated
   assumption.

This record does not choose between the two — that choice belongs to the
requirement that actually reverses §1's verdict, informed by how large a
candidate's session history is expected to grow and whether the schema
change in (1) is justified by more callers than just this one screen.

### 5. Admin view of other candidates' results — OUT OF SCOPE, decided independently of §1

**Explicitly out of scope, and this is a separate, independent verdict from
§1's candidate-scoped answer, not a consequence of it.** `CANDIDATE` holds
`ExamSessionRead` under `lib/letflow/routers/exam_sessions.ex`'s own
permission-vocabulary section — every read this record and its companion
(`REQ-351`) discuss is scoped to the calling candidate's own `user_id`, the
same ownership discipline `get_session_state_for_user/3` already enforces. An
admin-facing view of *other* candidates' results is a different permission
question entirely (an `AdminServicesManage`/`ExamAdmin`-class capability, not
`ExamSessionRead`), with its own INV-5 (not-found/forbidden
indistinguishability) and INV-1 (tenant isolation) considerations that a
candidate-scoped list does not raise the same way — an admin-facing list
necessarily crosses `user_id` boundaries within the tenant, which the
candidate-scoped design in §§1-4 never does. This record does not authorize,
design, or gesture at that capability; it is a distinct, unfiled, unscheduled
question, and nothing in this record's "serve it" analysis above should be
read as bearing on it one way or the other.

## Revisitability

**A not-to-serve verdict here is revisitable, and this record states the
trigger explicitly so a future stage does not have to re-litigate it from
scratch.** The verdict in §1 should be reopened if either of the following
occurs:

1. **The measured gap grows.** 9 of 168 (5.4%) is the figure this record
   weighs against; if a later parity or UAT pass finds the *proportion* of
   product behaviour blocked by the missing list surface has grown — more
   corpus tests, more UAT scenarios, or a direct product request naming a
   results-list as a requirement — that changes the cost/benefit balance
   this record struck and the question should be re-opened against the new
   figure, not against this record's 2026-09-15 numbers.
2. **A second caller for the sort/filter capability appears.** If some other,
   unrelated part of the platform independently needs `queried: true` on
   fields presently `queried: false` in an entity definition (i.e., the §4
   schema-migration cost stops being a cost this decision alone would incur,
   because another requirement is paying it anyway), the "flip the flags"
   option in §4 becomes markedly cheaper and the balance in §1 should be
   re-struck.

Absent either trigger, this record's verdict stands: no results-list surface
is built, and the gap stays recorded here rather than resurfacing as an
undocumented product question a future porting or UAT pass would otherwise
have to rediscover from scratch.

## Consequences

- **No implementation of any kind follows from this record.** No route, no
  handler, no screen, no spec is added by `REQ-350`. `Letflow.Exam.Session`,
  `lib/letflow/routers/exam_sessions.ex`, `priv/packs/bilimbaga/`, and every
  file under `web/src/`/`web/tests/e2e/` are untouched by this record.
- **`docs/migration/stage-10-bilimbaga-vertical.md`'s "Open questions"
  section is updated by this same requirement turn** (not deferred to a
  separate `DOC-UPDATER` pass, since `REQ-350`'s own acceptance criteria
  require the edit) — the "No way to view a past exam result" bullet is
  updated in place to cite this record, in the same "ANSWERED by decision
  NNNN" form the section's other resolved bullets use, preserving the
  original question text. See the close-out for the exact citation line and
  its number match against this file's own name.
- **§2's route-vs-query and §3's one-surface answers are available to a
  future requirement without re-derivation**, should §1's verdict ever be
  reversed under the trigger in "Revisitability" above.
- **If a future requirement does reverse §1 and build the list surface,
  that requirement's own bucket declaration is not made here.** Per this
  record's evidence (§1, "the decisive technical fact"), the read is a
  bucket-A entity-record query (`session` entity type, already defined) if
  served purely through the generic entity-query route with no new
  exam-specific module; it becomes bucket-C only if it needs a new module
  under `lib/letflow/exam/` (for example, to implement §4's in-memory
  sort/filter behind an owned, bounded function rather than leaving it to
  the SPA). **Whichever bucket that future requirement lands in, if it ships
  executable code under `lib/letflow/exam/`, it will need its own per-entry
  `REVIEWER` rule-2 sign-off, on the same basis `REQ-338`'s screens and
  `REQ-330`'s four exam modules were reached.** This record does not write
  that sign-off and does not pre-authorize it — it only flags, by name, that
  it will be required.

## What this record does not decide

- **Whether or when a results-list surface is built.** §1's verdict is "not
  today," not "never" — see "Revisitability" for the exact reopening
  triggers.
- **The single-result-by-id question.** `REQ-351` owns that half and the
  evidence already settles it independently of this record; this record
  neither depends on `REQ-351` nor pre-empts it.
- **The sort/filter mechanism choice (§4's two options)**, left to whichever
  future requirement actually reverses §1.
- **Any admin-facing view of other candidates' results (§5)** — a distinct,
  unfiled, unscheduled permission question this record explicitly declines
  to design.
- **The rule-2 sign-off for any future bucket-A/bucket-C implementation this
  record's §1 reversal might call for** — flagged in "Consequences" above,
  left to `REVIEWER` at that future requirement's own gate.
- **Implementation of any kind.** No file under `lib/letflow/`, `web/src/`,
  `web/tests/e2e/`, or `priv/packs/` is touched by this record.

## SECURITY-REVIEWER sign-off

**Skipped, by `REVIEWER`'s own explicit judgment call at this gate (2026-09-15,
`REVIEWER`, REQ-350) — not left unfilled.** `git status --porcelain` at review
time showed exactly two changes: this file (untracked) and a diff to
`docs/migration/stage-10-bilimbaga-vertical.md`'s "Open questions" bullet — no
file under `lib/letflow/`, `web/src/`, `web/tests/e2e/`, or `priv/packs/` is
touched. This record ships no route, handler, schema flag, or DDL of any
kind (§1's verdict is not-to-serve; §4's two schema-migration options are
explicitly left unchosen, moot under §1). There is no tenant-data path, no
response shape, and no secret to gate on `security-invariants.md`'s INV-1..
INV-8 against. This is the same class of skip already on record for
comparable docs-only decision-record turns in this pipeline (e.g.
`requirement_status.v17.yaml`'s ISS-0663 close-out entry). If a future
requirement reverses §1 and ships §4's schema-migration or route work, that
requirement gets its own SECURITY-REVIEWER gate — this skip covers only this
record's own diff.

## REVIEWER sign-off

**Verdict: PASS (2026-09-15, `REVIEWER`, REQ-350).**

Independently re-verified against the actual files, not against
`CODE-DESIGNER`'s self-report:

1. **Shape.** Section headings (`Status`/`Owner`, `Allocation note`, `Why
   this record exists`, numbered `Decision` subsections, `Revisitability`,
   `Consequences`, `What this record does not decide`, sign-off sections)
   match `0027`'s and `0030`'s convention.
2. **Numbering.** `ls docs/migration/decisions/` at review time shows `0031`
   as the newest file, with `0030` the next-highest — the allocation note's
   own account (0030 highest at write time, `0031` free, `0032`'s original
   pin correctly abandoned) is internally consistent, and `git ls-tree -r
   origin/main -- docs/migration/decisions/` confirms `main` still has no
   `0031` of its own — no concurrent registration has claimed it.
   `REQ-353` (pinned to the same `0031`) is `status: pending` in
   `docs/requirements.yaml`, not yet executed, so there is no live
   collision to resolve, only one correctly flagged as a future risk.
3. **All five required questions** (results-list yes/no; route-vs-entity-
   query; FR-BB41-vs-FR-BB46 one surface or two; the `queried:false`
   sort/filter constraint; admin-vs-candidate scope) are answered
   explicitly in §§1-5, none left implicit.
4. **Verbatim quote.** The router moduledoc quote in "The scope fence this
   record examines" was diffed word-for-word against
   `lib/letflow/routers/exam_sessions.ex`'s current
   "Deliberately NOT routed here" section — exact match, including the
   trailing "not a subset of the *state* read this module does implement"
   clause. The record states explicitly that `REQ-335`'s decision was
   correct at the time, not a defect.
5. **Figure re-derivation.** Re-read `docs/migration/stage-10-bilimbaga-
   vertical.md`'s "## P5 close-out — REQ-348, 2026-09-14" table directly:
   `my-results.spec.ts` 6 of 6 dropped, `exam-result.spec.ts` 1 of 5
   dropped (4 ported), `employee-portal.spec.ts` 5 of 8 dropped (3 ported,
   only 2 of the 5 attributable to the missing results surface). 6+1+2 = 9
   of 168, matching the record exactly. The false "seven whole-file
   blocked" figure does not appear anywhere in this record.
6. **Whole-file-vs-within-file split** stated correctly: SIX whole-file
   (`my-results.spec.ts`, 0/6), THREE within-file (`exam-result.spec.ts`
   4/5 ported, `employee-portal.spec.ts` 3/8 ported) — matches the table.
7. **`queried:false` fields.** Read
   `priv/packs/bilimbaga/entity_definitions/session.json` directly:
   `submitted_at`, `score_pct`, and `passed` are each declared
   `"queried": false`; `user_id`, `exam_id`, `status` are `"queried": true`.
   Matches the record's characterization exactly.
8. **No bucket-C rule-2 sign-off written** — correctly deferred to whichever
   future requirement reverses §1, per "Consequences."
9. **Stage-file bullet.** `git diff docs/migration/stage-10-bilimbaga-
   vertical.md` shows the "No way to view a past exam result" bullet
   rewritten to "ANSWERED by decision [0031](decisions/0031-candidate-
   results-list-scope.md)", matching the section's existing "ANSWERED by
   decision NNNN" form, with the original question text preserved verbatim
   in a parenthetical. The `0031` cited matches this file's own filename
   number exactly.
10. **Diff scope.** `git status --porcelain` shows only
    `docs/migration/stage-10-bilimbaga-vertical.md` (modified) and this
    record (untracked) — nothing under `lib/letflow/`, `web/src/`,
    `web/tests/e2e/`, or `priv/packs/`.
11. **Revisitability** is stated explicitly, with two concrete triggers (the
    measured gap growing; a second caller needing the same `queried: true`
    schema flip).

**No idiom/OTP/supervision questions arise — this record ships no code of
any kind, so questions 1-2 of this gate's usual purpose (gen_statem usage,
supervision integrity) do not apply.** On question 4 (scope creep): the
record does not overreach — it explicitly declines to pre-author a bucket
declaration or a rule-2 sign-off for hypothetical future implementation
work (§"Consequences"), leaving that to the requirement that would actually
need it, which is the correct restraint rather than scope creep in either
direction.

**No defects found. This gate PASSes.** Ready for `ORCH` to commit/push.

## Addendum (2026-10-28, GH #3321 / REQ-587): the results list is now served

Section 1 ("not served today") is reversed under Revisitability trigger 1: the BilimBaga certificates
criterion (FR-BB41/FR-BB46) needs a candidate to find their own sessions and certificates. The old text
above, including the quotation of the router's earlier "Deliberately NOT routed here" bullet, is kept as
history and is superseded by this addendum.

- The list is `GET /api/v1/modules/exam/exam-sessions/mine`, an exam-module route gated by the existing
  `:ExamSessionRead`. It departs from section 2 (generic entity query) because CANDIDATE does not hold the
  entity-query permission and must not (recorded as an open owner question).
- Section 4 option 2 (in-memory sort) is not used: the list is ordered by `expires_at` descending, which is
  already a queried field, so no `queried` flag flips and there is no migration.
- Section 5 is unchanged. No new permission, role grant or feature flag.
- The owner filter is `user_id` from the auth context; no caller-supplied owner, candidate or tenant parameter is read.
