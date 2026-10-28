/**
 * Exam Taking E2E tests — REQ-346 port of BilimBaga's exam-taking.spec.ts
 *
 * PORT, NOT TRANSLITERATION. The source drove BilimBaga's `/portal/sessions/:id`
 * screen — a richer exam-taking UI (a `<aside>` question-navigator grid with
 * per-question jump buttons, a flag/unflag control, a role="radio" custom
 * Likert widget, a "Finish exam" -> review-screen -> confirm-modal submit
 * flow, and a tab-switch warning modal) that has no counterpart in Letflow.
 * Letflow's real candidate-facing session screen is `ExamSessionPage.tsx`
 * (REQ-338, at `/exam/:examId/session`), a deliberately simpler one-question-
 * at-a-time screen: sequential Previous/Next paging (no jump grid), a browser-only flag
 * toggle (REQ-611), Likert renders through the exact same generic radio-option markup
 * as single-choice/true-false (no distinct widget), and clicking "Submit
 * exam" (`exam-submit-action`) calls `POST /modules/exam/exam-sessions/:id/submit`
 * directly — there is no review screen and no confirm modal to test a
 * cancel path on.
 *
 * Of the source's 11 tests, this file ports 10 real counterparts (some merged,
 * one materially rewritten against the real backend config below) and drops 1:
 *
 *   - "07 — Flag/unflag" — PORTED (REQ-611). ExamSessionPage.tsx now has a
 *     browser-only flag toggle (`exam-flag-toggle`, aria-pressed) and a
 *     `exam-flagged-count` line; flags never reach the server.
 *   - "10 — Submit confirmation happy path" — DROPPED, folded into "09"
 *     below. There is no confirm modal for a "submit anyway"/"cancel"
 *     sequence to exercise; clicking Submit performs the submission
 *     immediately.
 *   - "01 — Top bar and navigator render" is ported minus its navigator-grid
 *     assertion (no `<aside>` grid exists) — kept as "01" below, checking
 *     only what really renders (title/countdown, question-of-N progress,
 *     submit action).
 *   - "08 — Question navigator jump" has no random-access grid to jump
 *     within; rewritten as a sequential Previous/Next paging test, the real
 *     mechanism this screen actually offers for moving between questions.
 *   - "11 — Tab switch warning modal appears" is REWRITTEN against this
 *     exam's actual seeded config. `mix letflow.seed.exam_fixtures` sets
 *     "REQ-345 E2E Mixed Exam"'s `on_tab_switch` field to `"log"`, and
 *     `lib/letflow/exam/anti_cheat.ex`'s `fetch_action_taken/2` derives
 *     `action_taken` ONLY from that exam-level config (never from a client
 *     hint, never from an escalating per-signal count) — so a tab-switch
 *     signal against this exam always resolves to `action_taken: "log"`,
 *     which `ExamSessionPage.tsx`'s own `handleAntiCheatOutcome` explicitly
 *     renders as "no visible UI change" (only `warn`/`submit` show
 *     anything). The honest real-backend counterpart of "warning appears" is
 *     therefore its opposite for this exam: the signal is reported (a real
 *     `POST .../events` round-trip, asserted on directly) and produces
 *     neither a warning banner nor any dialog — there is no modal anywhere
 *     in this UI regardless of outcome.
 *
 * SELECTOR NOTE — 5 getByRole uses, each because no data-testid hook exists
 * for that element (REQ-346's AC requires this stated per-instance, not just
 * asserted in aggregate):
 *   - `getByRole('button', { name: 'Previous' })` (x2, in the paging helper
 *     used by tests 01/08) — ExamSessionPage.tsx's Previous button carries no
 *     testid.
 *   - `getByRole('button', { name: 'Next' })` (x2, same helper) — same
 *     reason, the Next button.
 *   - `getByRole('dialog')` (test 09, asserting none renders) — there is no
 *     `exam-*` testid for "no modal exists"; role="dialog" is the only
 *     selector that can assert this negative.
 * All other selectors in this file are getByTestId against the real
 * exam-* hooks named in REQ-346.
 *
 * SESSION-PER-PAGE CONSTRAINT (why these tests share one page, serially).
 * `ExamSessionPage.tsx`'s mount effect calls `examApi.startSession`
 * unconditionally on every navigation to the route (see
 * `lib/mix/tasks/letflow.seed.exam_fixtures.ex`'s own moduledoc: "there is no
 * branch ... that loads an existing session by id"), and
 * `lib/letflow/exam/session.ex`'s `check_no_open_session/1` rejects a second
 * `POST /modules/exam/exam-sessions` for the same (candidate, exam) pair while one is
 * still `in_progress`. Starting a fresh session per `test()` would therefore
 * either collide with the still-open session from the previous test, or
 * (once each is closed to avoid that) exhaust "REQ-345 E2E Mixed
 * Exam"'s `max_attempts: 5` well before all 9 tests ran. This file instead
 * opens exactly ONE session in `test.beforeAll` (a real browser page, not the
 * per-test `page` fixture — same pattern as
 * `rnd-ui-06.conflict-resolver.e2e.spec.ts`), reuses it across every
 * `test.describe.serial` test below in the order needed to visit every
 * question exactly once, and submits it in the final test — the same
 * candidate journey the source spec was trying to exercise, just paced
 * across `test()` boundaries instead of within one.
 *
 * Authentication: `web/tests/e2e/helpers.ts`'s `getKeycloakToken`/
 * `loginWithToken`, same as `employee-portal.e2e.spec.ts` (admin-user, the
 * only realm user holding a role `role_allows?/2` grants every `ExamSession*`
 * permission to unconditionally).
 */

import { test, expect, type APIRequestContext, type Page, type BrowserContext } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

// ---------------------------------------------------------------------------
// REQ-345 fixture lookup + cleanup helpers (same shapes as employee-portal.e2e.spec.ts)
// ---------------------------------------------------------------------------

interface ExamRecord {
  record_id: string
  field_values: { title?: { en?: string }; status?: string }
}

async function queryActiveExams(request: APIRequestContext, token: string): Promise<ExamRecord[]> {
  const res = await request.post('/api/v1/entities/query', {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: {
      entity_type: 'exam',
      filters: [{ field: 'status', op: 'eq', value: 'active' }],
      page_size: 100,
    },
  })
  if (!res.ok()) {
    throw new Error(`POST /api/v1/entities/query (exam) failed: ${res.status()} ${await res.text()}`)
  }
  const body = (await res.json()) as { items: ExamRecord[] }
  return body.items
}

function findExamByTitle(exams: ExamRecord[], titleEn: string): string {
  const match = exams.find((e) => e.field_values.title?.en === titleEn)
  if (!match) {
    throw new Error(
      `REQ-345 fixture exam "${titleEn}" not found among active exams. ` +
        'Run `mix letflow.seed.exam_fixtures` against the dev DB first.',
    )
  }
  return match.record_id
}

/** Submits every still-open (in_progress) session against the given exam, via
 *  the same raw HTTP route ExamSessionPage's own "Submit exam" button calls.
 *  Cleanup only — see employee-portal.e2e.spec.ts's identical helper for the
 *  full rationale (avoiding check_no_open_session/1 blocking a later run). */
async function submitOpenSessionsForExam(request: APIRequestContext, token: string, examId: string): Promise<void> {
  const res = await request.post('/api/v1/entities/query', {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: {
      entity_type: 'session',
      filters: [
        { field: 'exam_id', op: 'eq', value: examId },
        { field: 'status', op: 'eq', value: 'in_progress' },
      ],
      page_size: 100,
    },
  })
  if (!res.ok()) return
  const body = (await res.json()) as { items: Array<{ record_id: string }> }
  for (const item of body.items) {
    await request.post(`/api/v1/modules/exam/exam-sessions/${item.record_id}/submit`, {
      headers: { Authorization: `Bearer ${token}` },
    })
  }
}

// ---------------------------------------------------------------------------
// Page-level helpers, against ExamSessionPage.tsx's real testids/messages
// ---------------------------------------------------------------------------

const MAX_QUESTIONS = 5

/** Rewinds to question 1 via "Previous", then advances via "Next" until the
 *  visible question's stem contains `stemSubstring` — identifying a question
 *  by its real, distinct seeded stem text (e.g. "(single)", "(truefalse)")
 *  rather than by position, since "REQ-345 Mixed Exam"'s
 *  `exam_question_rule` (`mode: "random"`) does not guarantee a fixed
 *  question order. */
async function goToQuestionByStem(page: Page, stemSubstring: string): Promise<void> {
  const prevButton = page.getByRole('button', { name: 'Previous' })
  for (let i = 0; i < MAX_QUESTIONS; i++) {
    if (await prevButton.isDisabled()) break
    await prevButton.click()
  }

  const heading = page.locator('[data-testid^="exam-question-"] h3')
  const nextButton = page.getByRole('button', { name: 'Next' })
  for (let i = 0; i < MAX_QUESTIONS; i++) {
    const text = await heading.textContent()
    if (text?.includes(stemSubstring)) return
    if (await nextButton.isDisabled()) break
    await nextButton.click()
  }
  throw new Error(`goToQuestionByStem: no question containing "${stemSubstring}" found within ${MAX_QUESTIONS} questions`)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe.serial('Exam Taking (REQ-346 port onto /exam/:examId/session)', () => {
  let context: BrowserContext
  let page: Page
  let token: string
  let mixedExamId: string

  test.beforeAll(async ({ browser, request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    const exams = await queryActiveExams(request, token)
    mixedExamId = findExamByTitle(exams, 'REQ-345 E2E Mixed Exam')
    // Defensive: a prior interrupted run may have left a session open.
    await submitOpenSessionsForExam(request, token, mixedExamId)

    context = await browser.newContext()
    page = await context.newPage()
    await loginWithToken(page, token)

    await page.goto(`/exam/${mixedExamId}/session`, { waitUntil: 'domcontentloaded' })
    await expect(page.getByTestId('exam-session-page')).toBeVisible({ timeout: 15_000 })
  })

  test.afterAll(async ({ request }) => {
    // Whatever state the last test left the session in, close it out so a
    // later re-run of this file (or another file sharing this exam) does not
    // hit check_no_open_session/1 or exhaust max_attempts.
    await submitOpenSessionsForExam(request, token, mixedExamId)
    await context?.close()
  })

  test('01 — top bar renders: countdown title, question-of-N progress, submit action (no navigator grid in this UI)', async () => {
    await expect(page.getByTestId('page-layout-title')).toContainText(/\d{2}:\d{2}/)
    await expect(page.getByText(/Question \d+ of 5/)).toBeVisible({ timeout: 10_000 })
    await expect(page.getByTestId('exam-submit-action')).toBeVisible()
  })

  test('02 — single-choice: selecting an option checks it and autosaves', async () => {
    await goToQuestionByStem(page, '(single)')

    const options = page.locator('[data-testid^="exam-option-"]')
    const first = options.first()
    await expect(first).toHaveAttribute('type', 'radio')
    await first.click()
    await expect(first).toBeChecked()

    await expect(page.getByTestId('exam-save-status')).toHaveText('Saved', { timeout: 8_000 })
  })

  test('03 — multiple-choice: checkboxes toggle independently and autosave', async () => {
    await goToQuestionByStem(page, '(multiple)')

    const options = page.locator('[data-testid^="exam-option-"]')
    const first = options.first()
    await expect(first).toHaveAttribute('type', 'checkbox')

    await first.click()
    await expect(first).toBeChecked()
    await expect(page.getByTestId('exam-save-status')).toHaveText('Saved', { timeout: 8_000 })

    await first.click()
    await expect(first).not.toBeChecked()
    await expect(page.getByTestId('exam-save-status')).toHaveText('Saved', { timeout: 8_000 })

    await first.click()
    await expect(first).toBeChecked()
  })

  test('04 — true/false: a 2-option radio question selects', async () => {
    await goToQuestionByStem(page, '(truefalse)')

    const options = page.locator('[data-testid^="exam-option-"]')
    await expect(options).toHaveCount(2)
    await expect(options.first()).toHaveAttribute('type', 'radio')

    await options.first().click()
    await expect(options.first()).toBeChecked()
    await expect(page.getByTestId('exam-save-status')).toHaveText('Saved', { timeout: 8_000 })
  })

  test('05 — likert: renders through the same generic radio-option markup as single/true-false (no distinct widget) and selects', async () => {
    await goToQuestionByStem(page, '(likert)')

    const options = page.locator('[data-testid^="exam-option-"]')
    await expect(options.first()).toHaveAttribute('type', 'radio')
    // Unlike BilimBaga's source (a role="radio" custom scale widget),
    // Letflow's Likert question is indistinguishable in the DOM from a
    // single-choice question — same native <input type="radio"> markup.
    await expect(page.locator('[role="radio"]')).toHaveCount(0)

    await options.last().click()
    await expect(options.last()).toBeChecked()
    await expect(page.getByTestId('exam-save-status')).toHaveText('Saved', { timeout: 8_000 })
  })

  test('06 — short-text: typing and blurring the textarea autosaves', async () => {
    await goToQuestionByStem(page, '(shorttext)')

    const textarea = page.getByTestId('exam-short-text-input')
    await expect(textarea).toBeVisible({ timeout: 10_000 })
    await expect(textarea).toHaveAttribute('placeholder', 'Type your answer here…')

    const uniqueAnswer = `E2E short text answer — ${Date.now()}`
    await textarea.click()
    await textarea.fill(uniqueAnswer)
    await textarea.blur()

    await expect(page.getByTestId('exam-save-status')).toHaveText('Saved', { timeout: 8_000 })
    await expect(textarea).toHaveValue(uniqueAnswer)
  })

  test('07 — Flag/unflag: the toggle flips aria-pressed, the count follows, the flag survives paging', async () => {
    await goToQuestionByStem(page, '(single)')
    const toggle = page.getByTestId('exam-flag-toggle')
    await expect(toggle).toHaveAttribute('aria-pressed', 'false')
    await expect(page.getByTestId('exam-flagged-count')).toHaveCount(0)

    await toggle.click()
    await expect(toggle).toHaveAttribute('aria-pressed', 'true')
    await expect(page.getByTestId('exam-flagged-count')).toBeVisible()

    await page.getByRole('button', { name: 'Next' }).click()
    await expect(toggle).toHaveAttribute('aria-pressed', 'false')
    await page.getByRole('button', { name: 'Previous' }).click()
    await expect(toggle).toHaveAttribute('aria-pressed', 'true')

    await toggle.click()
    await expect(toggle).toHaveAttribute('aria-pressed', 'false')
    await expect(page.getByTestId('exam-flagged-count')).toHaveCount(0)
  })

  test('08 — sequential Previous/Next paging moves between questions (real mechanism; no jump grid exists)', async () => {
    const prevButton = page.getByRole('button', { name: 'Previous' })
    const nextButton = page.getByRole('button', { name: 'Next' })

    for (let i = 0; i < MAX_QUESTIONS; i++) {
      if (await prevButton.isDisabled()) break
      await prevButton.click()
    }
    await expect(page.getByText('Question 1 of 5')).toBeVisible()
    await expect(prevButton).toBeDisabled()

    for (let i = 0; i < MAX_QUESTIONS - 1; i++) {
      await nextButton.click()
    }
    await expect(page.getByText('Question 5 of 5')).toBeVisible()
    await expect(nextButton).toBeDisabled()

    await prevButton.click()
    await expect(page.getByText('Question 4 of 5')).toBeVisible()
  })

  test('11 — a tab-switch signal is reported; this exam\'s on_tab_switch:"log" config renders no warning and no dialog', async () => {
    const eventsResponse = page.waitForResponse(
      (res) => res.url().includes('/modules/exam/exam-sessions/') && res.url().includes('/events') && res.request().method() === 'POST',
    )

    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'hidden', writable: true, configurable: true })
      document.dispatchEvent(new Event('visibilitychange'))
    })

    const res = await eventsResponse
    expect(res.ok()).toBeTruthy()
    const body = (await res.json()) as { action_taken: string }
    expect(body.action_taken).toBe('log')

    await expect(page.getByTestId('exam-anticheat-warning')).toHaveCount(0)
    await expect(page.getByRole('dialog')).toHaveCount(0)
    // Restore visibility so later tests in this file are not affected.
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: true, configurable: true })
    })
  })

  test('09 — submitting the exam transitions directly to the result view (no review screen, no confirm modal)', async () => {
    await page.getByTestId('exam-submit-action').click()

    await expect(page.getByTestId('exam-result-page')).toBeVisible({ timeout: 15_000 })
    // "REQ-345 E2E Mixed Exam" always includes a short_text question, which
    // (per lib/letflow/exam/scoring.ex's own moduledoc-documented rule) makes
    // every one of its sessions grading_pending, never a numeric score.
    await expect(page.getByTestId('exam-result-pending')).toBeVisible()
    await expect(page.getByTestId('exam-result-score')).toHaveCount(0)
  })
})
