// @vitest-environment jsdom
/**
 * Q-1076 / GH #2433 -- a reload mid-exam resumes the candidate's open session.
 *
 * On main the mount-time startSession is refused with 409 session_already_open, and the page stops at
 * the error screen, whose only action goes back to the exam list: the candidate is stranded. The refusal
 * now names the candidate's own open session (session_id), and the page resumes it with getSessionState.
 * The countdown is the server's stored remaining_seconds; nothing is re-anchored or reset.
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
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

// The 409 body after Q-1076: the problem document's type/title/status/detail, plus the additive session_id.
const REFUSED_WITH_OPEN_SESSION = {
  status: 409,
  message: 'Conflict',
  code: 'conflict',
  details: {
    type: 'conflict',
    title: 'Conflict',
    status: 409,
    detail: 'you already have an active session for this exam',
    session_id: OPEN_SESSION_ID,
  },
}

// The same refusal from an older server, which names no session.
const REFUSED_WITHOUT_SESSION = {
  status: 409,
  message: 'Conflict',
  code: 'conflict',
  details: { detail: 'you already have an active session for this exam' },
}

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
})

afterEach(() => {
  cleanup()
})

describe('Q-1076 / GH #2433 -- reload mid-exam', () => {
  it('a refused second start resumes the open session and reaches the in-progress screen', async () => {
    mockedExamApi.startSession.mockRejectedValue(REFUSED_WITH_OPEN_SESSION)
    mockedExamApi.getSessionState.mockResolvedValue(sessionState())

    renderPage()

    expect(await screen.findByTestId('exam-session-page')).toBeTruthy()
    expect(mockedExamApi.getSessionState).toHaveBeenCalledWith(OPEN_SESSION_ID)
    expect(mockedExamApi.startSession).toHaveBeenCalledTimes(1)
    expect(screen.queryByTestId('exam-start-error')).toBeNull()
  })

  it('the resumed session shows the stored remaining time, not a fresh one', async () => {
    mockedExamApi.startSession.mockRejectedValue(REFUSED_WITH_OPEN_SESSION)
    mockedExamApi.getSessionState.mockResolvedValue(sessionState({ remaining_seconds: 100 }))

    renderPage()

    await screen.findByTestId('exam-session-page')
    expect(await screen.findByText(/01:40/)).toBeTruthy()
  })

  it('a refusal that names no session keeps the error screen and never tries to resume', async () => {
    mockedExamApi.startSession.mockRejectedValue(REFUSED_WITHOUT_SESSION)

    renderPage()

    expect(await screen.findByTestId('exam-start-error')).toBeTruthy()
    expect(mockedExamApi.getSessionState).not.toHaveBeenCalled()
  })

  it('when the resume itself fails, the error screen shows the start error', async () => {
    mockedExamApi.startSession.mockRejectedValue(REFUSED_WITH_OPEN_SESSION)
    mockedExamApi.getSessionState.mockRejectedValue({
      status: 404,
      message: 'Not Found',
      code: 'not-found',
      details: { detail: 'not found' },
    })

    renderPage()

    expect(await screen.findByTestId('exam-start-error')).toBeTruthy()
    expect(screen.queryByTestId('exam-session-page')).toBeNull()
  })
})
