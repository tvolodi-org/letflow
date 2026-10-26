# BilimBaga study T1d: is adaptive question selection used in production?

Written 2026-10-26. Read-only study; nothing was changed in code, definitions, seeds or tests.
It answers task T1d of `bilimbaga-retirement-status.md` (criterion 1, exam core, gap 4).
Source read: the BilimBaga repo at `c:\Users\tvolo\dev\ai-dala\BilimBaga\` (paths below are
relative to it).

## Finding in one paragraph

BilimBaga does have adaptive selection (requirement FR-BB72, "Adaptive Difficulty"). It is
fully built, but it is an opt-in exam flag that defaults to off, no seed or config turns it on,
the exam wizard has no control to set it, and no e2e spec exercises it. Production data was not
available to this study, so actual use cannot be proven from the repo. Everything the repo
shows points to "built, not used". Recommendation: drop the adaptive part of criterion 1.

## Where it lives

- Algorithm: `backend/internal/exams/adaptive.go` (`NextDifficulty`, `difficultyIndex`).
- Session logic: `backend/internal/sessions/service.go` (`SelectNextAdaptiveQuestion`,
  `RecordAdaptiveAnswer`); state type `AdaptiveState`, `ErrNotAdaptive` in
  `backend/internal/sessions/model.go`; route handler `GetNextQuestion` in
  `backend/internal/sessions/handler.go` (404 `NOT_ADAPTIVE` for a non-adaptive session).
- Publish rule: `backend/internal/exams/service.go` (`minAdaptiveQuestionsPerDifficulty = 5`,
  `AdaptivePublishValidationError`), mapped to 422 `INSUFFICIENT_ADAPTIVE_QUESTIONS`.
- Schema: `backend/migrations/026_adaptive_exam.up.sql`: `exams.adaptive BOOL NOT NULL DEFAULT
  false` and `exam_sessions.adaptive_state JSONB`.
- Taking UI: `frontend/src/pages/ExamTaking/ExamLayout.tsx` (single-question render when
  `session.adaptive === true`), `frontend/src/api/sessions.ts` (`useNextAdaptiveQuestion`).
- Spec and report: FR-BB72 in `docs/requirements/employee-exam-taking-process.md` ("Step 9,
  Adaptive Difficulty (Optional, Phase 7)") and `docs/issue-reports/FR-BB72-INNER-REPORT.md`.

## Is it used? Evidence

1. Default off, optional. Migration 026: `ADD COLUMN adaptive BOOL NOT NULL DEFAULT false`.
   The spec calls it "Optional, Phase 7" and applies it "only to exams with `adaptive = true`".
2. No seed or deploy config sets it. A case-insensitive search for `adaptive` in `scripts/`,
   `deploy/`, `swarm/`, `docker-compose.yml`, `backend/cmd` and `backend/**/*.sql` finds only
   migration 026 (up and down). No seed exam is adaptive and there is no feature flag or env var.
3. No authoring control in the web UI. A search for `adaptive` in
   `frontend/src/pages/ExamWizard/` (non-test files) and in the exam API/type files finds
   nothing. The only wizard references are the publish-error messages
   (`exam.wizard.step4.adaptiveInsufficient*` in `en.json`, `ru.json`, `kk.json`, via
   `frontend/src/api/examErrors.ts`). An examiner can therefore set `adaptive` only by calling the
   API directly (`CreateExamRequest.Adaptive`, `backend/internal/exams/handler.go`). The UAT
   scenario `docs/uat-scenarios/ai-content-authoring-20260609.md` (Scenario 4) expects an
   "Adaptive difficulty" toggle, but the code has none.
4. No e2e coverage. `docs/requirements/FR-BB67-e2e-coverage-employee-portal-exam-taking-grading.md`
   line 195: "Out of scope: adaptive exam mode (FR-BB72 flow) ... deferred to a follow-up
   FR-BB82". A search for `adaptive` in `frontend/e2e` and `frontend/tests` finds nothing.
5. The reviews treat it as an edge case. `docs/code-reviews/ISS-132-review.md` says "I did not
   verify that adaptive question selection works without rules"; `ISS-151` found that an adaptive
   exam with zero rules could be published. Both are bugs of a rarely used path.
6. Not proven: production database contents. `SELECT count(*) FROM exams WHERE adaptive` on the
   production database would settle it. This study did not have access and did not guess.

## Recommendation

Drop the adaptive part of criterion 1. Reasons: it is off by default, nothing in the repo sets
it, the web UI cannot set it, no e2e covers it, and the Letflow side (`ExamSessionPage`,
generic exam session flow) has no adaptive route either. Building it would be a size-M item
(`bilimbaga-retirement-status.md`, gap 4) for a feature with no evidence of use.

Condition: the owner or portfolio confirms with one query on the BilimBaga production database
(`exams.adaptive = true` row count, and `exam_sessions.adaptive_state IS NOT NULL` count). If
both are zero, record the criterion as dropped. If either is non-zero, the adaptive part stays
and becomes a `requirement` task (FR-BB72 as the source, with the 5-per-difficulty publish rule
and `NextDifficulty` as the behaviour to reproduce). The "results history / exam history" half of
gap 4 (FR-BB41/46) is unaffected by this finding.
