// @vitest-environment jsdom
/**
 * Q-1078 / GH 2435 -- a save after the session was finalised shows the expired screen.
 *
 * The backend answers a save to a session that is no longer in progress (finalised by expiry, per
 * lib/letflow/modules/exam/router.ex render_autosave) with 422 'session is not in progress', not the
 * 'your exam session has expired' text the page matched, so the candidate saw a generic save error and
 * could keep answering a closed session. The mapping now treats it as terminal, like the expired text.
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('../exam.api', () => ({
  examApi: {
    startSession: vi.fn(),
    getSessionState: vi.fn(),
    saveAnswer: vi.fn(),
    submitSession: vi.fn(),
    reportEvent: vi.fn(),
  },
}))

import { examApi } from '../exam.api'
import ExamSessionPage from '../ExamSessionPage'
import type { ExamSessionStateResponse } from '../exam.types'

const mockedExamApi = vi.mocked(examApi, true)

const OPEN_SESSION_ID = 'session-open-1'

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/exam/exam-1/session']}>
      <Routes>
        <Route path="/exam/:examId/session" element={<ExamSessionPage />} />
        <Route path="*" element={<div />} />
      </Routes>
    </MemoryRouter>,
  )
}

function sessionState(overrides: Partial<ExamSessionStateResponse> = {}): ExamSessionStateResponse {
  return {
    session: {
      id: OPEN_SESSION_ID,
      exam_id: 'exam-1',
      candidate_id: 'user-1',
      status: 'in_progress',
      seed: 1,
      started_at: '2026-09-13T00:00:00Z',
      expires_at: '2026-09-13T01:00:00Z',
      score_pct: null,
      passed: null,
    },
    remaining_seconds: 100,
    questions: [
      {
        question_id: 'q1',
        sort_order: 1,
        type: 'single',
        stem: { en: 'Question one' },
        options: [
          { id: 'opt-a', text: { en: 'Option A' } },
          { id: 'opt-b', text: { en: 'Option B' } },
        ],
      },
    ],
    answers: {},
    ...overrides,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  mockedExamApi.startSession.mockResolvedValue(sessionState())
})

afterEach(() => {
  cleanup()
})

async function openAndAnswer() {
  const user = userEvent.setup()
  renderPage()
  await screen.findByTestId('exam-session-page')
  await user.click(screen.getByText('Option A'))
}

describe('Q-1078 / GH 2435 -- a save after expiry shows the expired screen', () => {
  it("the 422 'session is not in progress' on a save shows the expired screen", async () => {
    mockedExamApi.saveAnswer.mockRejectedValue({
      status: 422,
      message: 'Unprocessable',
      code: 'unprocessable',
      details: { detail: 'session is not in progress' },
    })

    await openAndAnswer()

    expect(await screen.findByTestId('exam-expired')).toBeTruthy()
    expect(screen.queryByTestId('exam-session-page')).toBeNull()
  })

  it('the existing expired text still shows the expired screen', async () => {
    mockedExamApi.saveAnswer.mockRejectedValue({
      status: 422,
      message: 'Unprocessable',
      code: 'unprocessable',
      details: { detail: 'your exam session has expired' },
    })

    await openAndAnswer()

    expect(await screen.findByTestId('exam-expired')).toBeTruthy()
  })

  it('an unrelated save failure keeps the exam open with the save error', async () => {
    mockedExamApi.saveAnswer.mockRejectedValue({
      status: 500,
      message: 'Internal',
      code: 'internal_error',
      details: {},
    })

    await openAndAnswer()

    expect(await screen.findByText('Could not save your answer. Please try again.')).toBeTruthy()
    expect(screen.getByTestId('exam-session-page')).toBeTruthy()
    expect(screen.queryByTestId('exam-expired')).toBeNull()
  })

  it('a 422 with the not-in-progress text on a different status is not treated as expiry', async () => {
    mockedExamApi.saveAnswer.mockRejectedValue({
      status: 409,
      message: 'Conflict',
      code: 'conflict',
      details: { detail: 'session is not in progress' },
    })

    await openAndAnswer()

    expect(await screen.findByText('Could not save your answer. Please try again.')).toBeTruthy()
    expect(screen.queryByTestId('exam-expired')).toBeNull()
  })

  it('a failed save that resolves after the result screen keeps the result screen', async () => {
    let rejectSave!: (e: unknown) => void
    mockedExamApi.saveAnswer.mockReturnValue(new Promise((_, reject) => (rejectSave = reject)))
    // GH 2941: Submit now waits for the pending save, so the result screen comes from a forced
    // (anti-cheat) submit that does not wait for it.
    mockedExamApi.reportEvent.mockResolvedValue({
      action_taken: 'submit',
      event_count: 1,
      warning: false,
      submission: { status: 'submitted', total_score: 0, total_max_score: 10, percentage: 0, passed: false },
    })

    const user = userEvent.setup()
    renderPage()
    await screen.findByTestId('exam-session-page')
    await user.click(screen.getByText('Option A'))
    window.dispatchEvent(new Event('blur'))
    await waitFor(() => expect(screen.queryByTestId('exam-session-page')).toBeNull())

    await act(async () => {
      rejectSave({
        status: 422,
        message: 'Unprocessable',
        code: 'unprocessable',
        details: { detail: 'session is not in progress' },
      })
    })

    expect(screen.queryByTestId('exam-expired')).toBeNull()
  })

  it('the closed-session screen does not claim the time ran out', async () => {
    mockedExamApi.saveAnswer.mockRejectedValue({
      status: 422,
      message: 'Unprocessable',
      code: 'unprocessable',
      details: { detail: 'session is not in progress' },
    })

    await openAndAnswer()

    const body = await screen.findByTestId('exam-expired')
    expect(body.textContent).not.toMatch(/time|run out|expired/i)
  })
})
