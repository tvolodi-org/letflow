/**
 * E2E -- BilimBaga study T3b batch 2: anti-cheat signals on the exam session screen
 * (`/exam/:examId/session`, ExamSessionPage + useAntiCheatSignals).
 *
 * Ported from BilimBaga's `tab-switch.spec.ts` (origin/main, 7 tests; classification in
 * docs/migration/bilimbaga-e2e-new-files-classification.md, section 2 and 3). The session start
 * and the `POST .../exam-sessions/:id/events` answer are stubbed with page.route, so the UI
 * reaction to each server policy (log / warn / submit) is deterministic and needs no seeded exam
 * (same approach as the source). Only the login (Keycloak token) and the SPA are live.
 *
 * Adaptations to Letflow's real screen:
 *   - Route is `/exam/:examId/session`, not `/portal/sessions/:id`. The session id is not in the
 *     URL; a forced submit renders the result view in place (`exam-result-page`), it does not
 *     navigate to a result URL.
 *   - The events body is bare (`{action_taken, event_count, warning, submission}`), not
 *     `{data, error}`; the client sends `{type}` with a Bearer token.
 *   - The warning is a non-dismissable banner (`exam-anticheat-warning`, role="alert"), not a
 *     modal: there is no Cancel button, so "can be dismissed" has no counterpart. The test checks
 *     the banner, its count and that the candidate stays on the exam.
 *
 * Overlap with exam-taking.e2e.spec.ts test 11: that test sends one tab_switch against the real
 * seeded exam (policy "log") and asserts the real round trip; test 1 here checks the request
 * contract against a stub and test 4 the log outcome. They are kept because exam-taking's one
 * covers the live backend and these cover the reaction to each policy.
 *
 * Skipped from this batch (reason): the source's "successful start navigates to the session
 * page" is a duplicate of employee-portal.e2e.spec.ts test 05 (list Start -> session route) and
 * exam-taking.e2e.spec.ts (session page renders); it is not ported again.
 *
 * Test (a) is `test.fixme`: Letflow's useAntiCheatSignals has no 300 ms blur window, so a tab
 * switch that also fires `blur` reports two events. Left as a documented gap, not weakened.
 *
 * Needs a live instance (backend + Keycloak); it could not be run on the host that wrote it.
 */
import { expect, test, type Page, type Request as PwRequest } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

const EXAM_ID = '11111111-2222-4333-8444-555555555555'
const SESSION_ID = '66666666-7777-4888-9999-aaaaaaaaaaaa'
const START_URL = /\/api\/v1\/modules\/exam\/exam-sessions$/
const EVENTS_URL = /\/api\/v1\/modules\/exam\/exam-sessions\/[^/]+\/events$/
const SESSION_PATH = new RegExp(`/exam/${EXAM_ID}/session$`)

interface Outcome {
  action_taken: 'log' | 'warn' | 'submit'
  event_count: number
  warning: boolean
  submission: {
    status: 'submitted' | 'grading_pending' | 'auto_submitted'
    total_score: number
    total_max_score: number
    percentage: number
    passed: boolean | null
  } | null
}

const LOG_OUTCOME: Outcome = { action_taken: 'log', event_count: 1, warning: false, submission: null }
const WARN_OUTCOME: Outcome = { action_taken: 'warn', event_count: 1, warning: true, submission: null }
const SUBMIT_OUTCOME: Outcome = {
  action_taken: 'submit',
  event_count: 3,
  warning: false,
  submission: { status: 'auto_submitted', total_score: 0, total_max_score: 1, percentage: 0, passed: false },
}

async function json(route: import('@playwright/test').Route, status: number, body: unknown) {
  await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
}

/** Stub the session start with one single-choice question, stub events with `outcome`, open the exam. */
async function openExam(page: Page, outcome: Outcome): Promise<PwRequest[]> {
  const sent: PwRequest[] = []
  await page.route(START_URL, (route) => {
    if (route.request().method() !== 'POST') return route.continue()
    return json(route, 201, {
      session: {
        id: SESSION_ID,
        exam_id: EXAM_ID,
        candidate_id: 'c-1',
        status: 'in_progress',
        seed: 1,
        started_at: '2026-10-26T10:00:00Z',
        expires_at: '2026-10-26T11:00:00Z',
        score_pct: null,
        passed: null,
      },
      remaining_seconds: 3600,
      questions: [
        {
          question_id: 'q-1',
          sort_order: 1,
          type: 'single',
          stem: { en: 'Pick one' },
          options: [
            { id: 'o-1', text: { en: 'A' } },
            { id: 'o-2', text: { en: 'B' } },
          ],
        },
      ],
      answers: {},
    })
  })
  await page.route(EVENTS_URL, (route) => {
    if (route.request().method() !== 'POST') return route.continue()
    sent.push(route.request())
    return json(route, 200, outcome)
  })
  await page.goto(`/exam/${EXAM_ID}/session`, { waitUntil: 'domcontentloaded' })
  await expect(page.getByTestId('exam-session-page')).toBeVisible({ timeout: 15_000 })
  return sent
}

function eventTypes(requests: PwRequest[]): unknown[] {
  return requests.map((r) => (r.postDataJSON() as { type: unknown }).type)
}

/** Simulate the browser tab becoming hidden (what switching tabs does). */
async function fireTabHidden(page: Page) {
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' })
    document.dispatchEvent(new Event('visibilitychange'))
  })
}

test.describe('Anti-cheat signals on /exam/:examId/session (T3b batch 2)', () => {
  test.setTimeout(60_000)

  test.beforeEach(async ({ page, request }) => {
    const token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    await loginWithToken(page, token)
  })

  test('tab hidden reports a tab_switch event and the endpoint contract holds', async ({ page }) => {
    const sent = await openExam(page, LOG_OUTCOME)
    const [request, response] = await Promise.all([
      page.waitForRequest((r) => EVENTS_URL.test(r.url()) && r.method() === 'POST'),
      page.waitForResponse((r) => EVENTS_URL.test(r.url())),
      fireTabHidden(page),
    ])
    expect(request.postDataJSON()).toEqual({ type: 'tab_switch' })
    expect(request.headers()['authorization']).toMatch(/^Bearer /)
    expect(response.status()).toBe(200)
    const body = (await response.json()) as Outcome
    expect(typeof body.warning).toBe('boolean')
    expect(eventTypes(sent)).toEqual(['tab_switch'])
  })

  test('window blur reports a blur event', async ({ page }) => {
    await openExam(page, LOG_OUTCOME)
    const [request] = await Promise.all([
      page.waitForRequest((r) => EVENTS_URL.test(r.url()) && r.method() === 'POST'),
      page.evaluate(() => window.dispatchEvent(new Event('blur'))),
    ])
    expect(request.postDataJSON()).toEqual({ type: 'blur' })
  })

  test('warn policy shows the warning banner (not dismissable) and keeps the exam open', async ({ page }) => {
    await openExam(page, WARN_OUTCOME)
    await fireTabHidden(page)

    const banner = page.getByTestId('exam-anticheat-warning')
    await expect(banner).toBeVisible({ timeout: 10_000 })
    await expect(banner).toContainText(/leaving the exam window has been detected \(1 time/i)
    await expect(page.getByRole('dialog')).toHaveCount(0)
    await expect(page).toHaveURL(SESSION_PATH)
    await expect(page.getByTestId('exam-submit-action')).toBeVisible()
  })

  test('log policy does not interrupt the exam', async ({ page }) => {
    await openExam(page, LOG_OUTCOME)
    const [response] = await Promise.all([
      page.waitForResponse((r) => EVENTS_URL.test(r.url())),
      fireTabHidden(page),
    ])
    expect(response.status()).toBe(200)
    await expect(page.getByTestId('exam-anticheat-warning')).toHaveCount(0)
    await expect(page.getByRole('dialog')).toHaveCount(0)
    await expect(page).toHaveURL(SESSION_PATH)
    await expect(page.getByTestId('exam-session-page')).toBeVisible()
  })

  test('auto-submit policy replaces the exam with the result view', async ({ page }) => {
    await openExam(page, SUBMIT_OUTCOME)
    await fireTabHidden(page)
    await expect(page.getByTestId('exam-result-page')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByTestId('exam-session-page')).toHaveCount(0)
    await expect(page.getByTestId('exam-result-score')).toBeVisible()
  })

  test.fixme(
    '(a) a simulated tab switch under submit sends exactly one tab_switch and auto-submits',
    async ({ page }) => {
      // Intended behaviour from the source (FR-BB319): the blur that accompanies a tab switch is not
      // sent. Letflow's useAntiCheatSignals has no blur window, so today this reports two events.
      const sent = await openExam(page, SUBMIT_OUTCOME)
      await page.evaluate(() => {
        Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' })
        document.dispatchEvent(new Event('visibilitychange'))
        window.dispatchEvent(new Event('blur'))
      })
      await expect(page.getByTestId('exam-result-page')).toBeVisible({ timeout: 15_000 })
      await page.waitForTimeout(500)
      expect(eventTypes(sent)).toEqual(['tab_switch'])
    },
  )

  test('(b) a bare blur under submit sends one blur, warns with event_count 1 and does not submit', async ({
    page,
  }) => {
    const sent = await openExam(page, WARN_OUTCOME)
    const [request, response] = await Promise.all([
      page.waitForRequest((r) => EVENTS_URL.test(r.url()) && r.method() === 'POST'),
      page.waitForResponse((r) => EVENTS_URL.test(r.url())),
      page.evaluate(() => window.dispatchEvent(new Event('blur'))),
    ])
    expect(request.postDataJSON()).toEqual({ type: 'blur' })
    expect(response.status()).toBe(200)
    const body = (await response.json()) as Outcome
    expect(body).toMatchObject({ warning: true, event_count: 1, submission: null })

    await expect(page.getByTestId('exam-anticheat-warning')).toContainText(/\(1 time/i)
    await expect(page.getByTestId('exam-result-page')).toHaveCount(0)
    await expect(page).toHaveURL(SESSION_PATH)
    // Nothing else is sent after the warning.
    await page.waitForTimeout(500)
    expect(eventTypes(sent)).toEqual(['blur'])
  })
})
