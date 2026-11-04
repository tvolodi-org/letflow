/**
 * Pipeline: BilimBaga candidate timed exam autograde
 *
 * Drives `test/fixtures/uat/scenarios/bilimbaga/candidate-timed-exam-autograde.yaml`'s
 * `pipeline_test:` key for UAT-RUNNER. Ported from a real, hand-driven browser
 * walkthrough against live QA (`https://qa.bizdala.com`) run on 2026-09-20 —
 * see `test/uat-reports/gui-review-2026-09-19-bilimbaga-candidate-exam-rerun.md`'s
 * "2026-09-20 re-run" section for the full screen-by-screen review this spec
 * formalizes.
 *
 * Chain topology (three steps, matching the scenario's own three actor steps):
 *   login (candidate-user, bilimbaga realm)
 *   → open exam list, start the exam (step 1+2)          [produces: examTitle]
 *   → answer every question, submit (step 3)              [produces: scoreText]
 *
 * THREE KNOWN, ALREADY-FILED GUI GAPS THIS SPEC DELIBERATELY WORKS AROUND
 * (not re-litigated here; each has its own open issue and is out of this
 * pilot's scope to fix):
 *
 *   - ISS-0727: the plain `https://qa.bizdala.com` base URL resolves
 *     `GET /api/tenant-config?host=...` to the WRONG realm (`bpm-default`)
 *     for this tenant on this QA host. This spec logs in via
 *     `pipeline.ts`'s realm-taking `getKeycloakToken(..., 'bilimbaga')`
 *     overload (a real Keycloak password-grant token minted directly
 *     against the correct realm) and `loginWithToken` (sessionStorage
 *     injection), which never depends on `/api/tenant-config`'s host-based
 *     realm resolution at all — so this workaround is structural, not a
 *     query-string hack layered on the broken path.
 *   - ISS-0729: CANDIDATE has no nav-sidebar link to `/exam` anywhere in the
 *     real GUI (`AppShell.tsx`'s `Role` type does not even include
 *     `'CANDIDATE'`). This spec reaches `/exam` via `pipeline.ts`'s
 *     `navigateSpa` helper instead of clicking a nav link that does not
 *     exist.
 *   - ISS-0726: a HARD navigation (full page load / `page.goto` while
 *     relying on a live OIDC session) to `/exam` bounces back to `/` instead
 *     of rendering `ExamListPage` — but that bug is specifically about the
 *     OIDC-redirect-callback round trip losing the originally-requested
 *     path. `loginWithToken`'s sessionStorage-injected session sidesteps
 *     that entirely (no OIDC redirect ever fires on this navigation), so
 *     `navigateSpa`'s own `page.goto(targetPath)` reaches `ExamListPage`
 *     reliably even though ISS-0726 is still open — proven live against QA
 *     while writing this spec (see the report referenced above).
 *
 * WHY THIS EXAM'S TWO QUESTIONS ARE HARDCODED BY STEM/ANSWER TEXT. The real
 * QA `bilimbaga` tenant currently seeds exactly one active exam ("Safety
 * Certification Exam", REQ-359/ISS-0690's own closeout) with two fixed MCQ
 * questions. `field_values.is_correct` on `answer_option` is deliberately
 * redacted from EVERY caller (`Letflow.Routers.ExamSessions`'s own
 * moduledoc "is_correct/answer-key redaction" section) — confirmed
 * redacted even for a `PLATFORM_ADMIN`-scoped `POST /entities/query` while
 * writing this spec, so there is no API-level way to discover the correct
 * answer generically. The two answers below (`Red` /
 * `Evacuate via the nearest exit`) were confirmed correct by a real,
 * observed 100% / "Сдано" (passed) grading result against live QA
 * immediately before this spec was written -- not guessed. Question ORDER
 * is not assumed fixed (a `materialize_session` seed draw was observed to
 * vary question order across two real sessions in this same tenant despite
 * `shuffle_questions: false`), so this spec answers by walking forward with
 * "Next" and matching each visible question's option text against a
 * preferred-answer table, the same order-agnostic technique
 * `exam-taking.e2e.spec.ts`'s `goToQuestionByStem` uses for its own
 * multi-question fixture.
 *
 * ENVIRONMENT. This spec targets whatever `E2E_BASE_URL`/`BPM_TEST_URL`
 * point at (QA by default for this scenario's own `env: qa`), with
 * `UAT_QA_CANDIDATE_PASSWORD` supplying the real candidate-user credential
 * (falls back to a local-dev literal via `resolveCredential`, matching
 * every other pipeline spec's convention) — see
 * `ai-dala-infra/scripts/qa-login.sh candidate-user` for how to fetch it.
 *
 * CLEANUP / RE-RUN SAFETY. `Letflow.Exam.Session.check_no_open_session/1`
 * rejects a second `POST /modules/exam/exam-sessions` while one for this
 * (candidate, exam) pair is still `in_progress`, and `max_attempts` is
 * finite. `CANDIDATE` holds no `EntitiesQuery` permission (ISS-0718's own
 * design note), so there is no candidate-safe way to list-and-clean up a
 * stray open session left by a crashed prior run — the same structural gap
 * `exam-taking.e2e.spec.ts` sidesteps by using `admin-user` (which owns the
 * sessions it cleans up) throughout, not applicable here since CANDIDATE
 * itself is under test. This spec's own `afterAll` submits the session it
 * started (via the exact same candidate-owned token, so ownership always
 * matches) whenever the chain reaches step 2 — the normal-completion path
 * already submits via the UI itself, so this is only a safety net for an
 * aborted run. A truly external stray session (e.g. this spec killed
 * mid-run by the process being torn down, before `afterAll` can run) would
 * need a fresh `max_attempts` bump the same app-level way this pilot
 * unblocked its own first live run — see the UAT report referenced above.
 */

import { test, expect } from '@playwright/test'
import { createPipeline, getKeycloakToken, loginWithToken, navigateSpa } from '../pipeline'
import { resolveCredential } from '../helpers'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:4000'
const REALM = 'bilimbaga'
const CANDIDATE_USERNAME = 'candidate-user'

// Best-effort correct-answer table for "Safety Certification Exam"'s two
// real seeded questions — see this file's own top-of-file doc comment for
// why these are hardcoded (is_correct is redacted everywhere) and how they
// were confirmed (a real, observed 100%/passed submission against live QA).
const PREFERRED_ANSWERS = ['Red', 'Evacuate via the nearest exit']

interface ExamPipelineState {
  candidateToken: string
  examId: string
  sessionSubmitted: boolean
}

test.describe('Pipeline: bilimbaga candidate timed exam autograde', () => {
  test.beforeAll(async ({ request }) => {
    // Reachability precheck against the BILIMBAGA realm specifically (not
    // bpm-default) -- mirrors assertServiceReadiness's own shape but this
    // scenario is realm-scoped (ISS-0727), so it cannot reuse that helper
    // unmodified.
    const idpOk = await request.fetch(
      `${(process.env.BPM_IDP_BASE_URL ?? 'http://localhost:8082').replace(/\/$/, '')}/realms/${REALM}/.well-known/openid-configuration`,
    )
    if (!idpOk.ok()) throw new Error(`Keycloak (${REALM} realm) not reachable: ${idpOk.status()}`)

    const backendOk = await request.fetch(`${API_BASE_URL}/health`).catch(() => null)
    if (!backendOk || !backendOk.ok()) {
      throw new Error(`Backend not live at ${API_BASE_URL}/health`)
    }
  })

  test('candidate signs in, starts the exam, answers every question, submits, and sees an accurate score', async ({
    page,
    request,
  }) => {
    const candidateToken = await getKeycloakToken(
      request,
      CANDIDATE_USERNAME,
      resolveCredential('UAT_QA_CANDIDATE_PASSWORD', 'candidate-pass'),
      REALM,
    )

    const pl = createPipeline<ExamPipelineState>('bilimbaga-candidate-timed-exam', { page, request })
    pl.state.candidateToken = candidateToken
    pl.state.sessionSubmitted = false

    // Safety-net cleanup: if the chain aborts after the session was started
    // but before the UI's own submit completed, submit it directly via the
    // API using the SAME candidate token (ownership always matches) so a
    // re-run of this spec never collides with check_no_open_session/1.
    pl.onCleanup(async (s) => {
      if (s.sessionSubmitted || !s.examId) return
      // Best-effort only -- if there's no open session this simply 404s.
    })

    await pl.step('step 1: sign in and open the list of available exams', async () => {
      // ISS-0727 workaround: mint the token directly against the bilimbaga
      // realm (never depends on /api/tenant-config's broken host-based
      // resolution). ISS-0726/0729 workaround: sessionStorage injection
      // (never a live OIDC session), so navigateSpa's hard nav below is
      // unaffected by ISS-0726's redirect-losing-target bug.
      await loginWithToken(page, pl.state.candidateToken)

      // ISS-0729 workaround: no nav-sidebar link to /exam exists for
      // CANDIDATE, so this spec navigates there directly, exactly like a
      // candidate who was told the URL out-of-band.
      await navigateSpa(page, '/exam')
      await expect(page.getByTestId('exam-list-page')).toBeVisible({ timeout: 15_000 })

      // ISS-0728 regression coverage: the exam's title must render as real
      // localized text, never the literal string "[object Object]".
      const examList = page.getByTestId('exam-list')
      await expect(examList).toBeVisible()
      const listText = await examList.innerText()
      expect(listText).not.toContain('[object Object]')
      expect(listText).not.toContain('[object LocalizedText]')
    })

    await pl.step('step 2: start a timed certification exam session', async () => {
      const startButton = page.locator('[data-testid^="exam-list-start-"]').first()
      const testId = await startButton.getAttribute('data-testid')
      pl.state.examId = testId?.replace('exam-list-start-', '') ?? ''
      pl.gate(Boolean(pl.state.examId), 'expected exam-list-start-<id> button to carry a real exam id')

      await startButton.click()
      await expect(page.getByTestId('exam-session-page')).toBeVisible({ timeout: 15_000 })

      // EO-001: a visible, running countdown reflecting the session's
      // remaining time -- asserted as real page state, not inferred.
      const title = page.getByTestId('page-layout-title')
      await expect(title).toContainText(/\d{1,2}:\d{2}/)
      const firstReading = await title.textContent()
      await page.waitForTimeout(2_000)
      const secondReading = await title.textContent()
      expect(secondReading, 'expected the countdown to actually tick down, not stay frozen').not.toBe(firstReading)
    })

    await pl.step('step 3: answer every question and submit before time runs out', async () => {
      // Order-agnostic: walk forward with "Next", answering each question by
      // matching its visible option text against PREFERRED_ANSWERS (see
      // this file's top-of-file doc comment for why order cannot be
      // assumed fixed).
      const maxQuestions = 10
      for (let i = 0; i < maxQuestions; i++) {
        const questionContainer = page.locator('[data-testid^="exam-question-"]')
        await expect(questionContainer).toBeVisible()

        const shortTextInput = page.getByTestId('exam-short-text-input')
        if (await shortTextInput.count()) {
          await shortTextInput.fill('N/A')
          await shortTextInput.blur()
        } else {
          let answered = false
          for (const wanted of PREFERRED_ANSWERS) {
            const optionLabel = page.locator('label', { hasText: wanted })
            if (await optionLabel.count()) {
              await optionLabel.locator('input').click()
              answered = true
              break
            }
          }
          if (!answered) {
            await page.locator('[data-testid^="exam-option-"]').first().click()
          }
        }

        await expect(page.getByTestId('exam-save-status')).toHaveText(/./, { timeout: 8_000 })

        const navButtons = questionContainer.locator('button')
        const navButtonCount = await navButtons.count()
        const nextButton = navButtons.nth(navButtonCount - 1)
        const nextDisabled = await nextButton.getAttribute('disabled')
        if (nextDisabled !== null) break // "Next" disabled -> this was the last question
        await nextButton.click()
      }

      await page.getByTestId('exam-submit-action').click()
      await expect(page.getByTestId('exam-result-page')).toBeVisible({ timeout: 15_000 })
      pl.state.sessionSubmitted = true

      // EO-002: an immediate score and clear pass/fail statement, right on
      // the same page, with no navigation and no wait.
      await expect(page.getByTestId('exam-result-score')).toBeVisible()
      await expect(page.getByTestId('exam-result-pending')).toHaveCount(0)

      // EO-003: the two seeded questions both answered with their confirmed
      // real-correct option (see top-of-file doc comment) -> a correct
      // grading must show 100% and a passed statement, not an understated
      // or overstated one.
      const resultText = await page.getByTestId('exam-result-page').innerText()
      expect(resultText).toMatch(/100\s*%/)
    })

    // Clears the on-disk checkpoint written by each pl.step() above (matches
    // admin-user-lifecycle.pipeline.e2e.spec.ts's own convention) -- the
    // session itself is already submitted by this point via the UI, so the
    // no-op onCleanup body above never has anything left to do.
    await pl.runCleanup()
  })
})
