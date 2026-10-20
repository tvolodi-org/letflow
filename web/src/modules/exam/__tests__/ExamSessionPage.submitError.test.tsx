// @vitest-environment jsdom
/**
 * Q-1077 / GH 2434 -- a failed submit is not silent.
 *
 * On main handleSubmit has no catch: a rejected submitSession leaves the candidate on an unchanged page
 * with no message (and an unhandled rejection). It now shows an alert the candidate can act on, and the
 * submit button stays usable so the candidate can retry. A deadline-passed rejection goes to the
 * expired screen, as a failed save does.
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor, fireEvent } from '@testing-library/react'
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

const SUBMITTED = {
  status: 'submitted' as const,
  score_pct: 100,
  passed: true,
  session_id: OPEN_SESSION_ID,
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
  mockedExamApi.startSession.mockResolvedValue(sessionState())
})

afterEach(() => {
  cleanup()
})

async function openAndSubmit() {
  const user = userEvent.setup()
  renderPage()
  await user.click(await screen.findByTestId('exam-submit-action'))
  return user
}

describe('Q-1077 / GH 2434 -- a failed submit shows an error', () => {
  it('a network failure shows an alert and keeps the exam open', async () => {
    mockedExamApi.submitSession.mockRejectedValue(new TypeError('Failed to fetch'))

    await openAndSubmit()

    const alert = await screen.findByTestId('exam-submit-error')
    expect(alert.getAttribute('role')).toBe('alert')
    expect(alert.textContent).toBe('Your exam could not be submitted. Please try again.')
    expect(screen.getByTestId('exam-session-page')).toBeTruthy()
  })

  it('a server refusal shows the alert; the retry clears it while pending and then succeeds', async () => {
    let resolveRetry!: (v: never) => void
    mockedExamApi.submitSession
      .mockRejectedValueOnce({ status: 500, message: 'Internal', code: 'internal_error', details: {} })
      .mockReturnValueOnce(new Promise((resolve) => (resolveRetry = resolve as typeof resolveRetry)))

    const user = await openAndSubmit()
    await screen.findByTestId('exam-submit-error')
    expect(screen.getByTestId('exam-submit-action').hasAttribute('disabled')).toBe(false)

    await user.click(screen.getByTestId('exam-submit-action'))
    // the retry is still pending: the old error is gone and the exam is still open
    await waitFor(() => expect(screen.queryByTestId('exam-submit-error')).toBeNull())
    expect(screen.getByTestId('exam-session-page')).toBeTruthy()

    resolveRetry(SUBMITTED as never)
    await waitFor(() => expect(screen.queryByTestId('exam-session-page')).toBeNull())
    expect(mockedExamApi.submitSession).toHaveBeenCalledTimes(2)
  })

  it('a deadline-passed refusal goes to the expired screen, not the generic alert', async () => {
    mockedExamApi.submitSession.mockRejectedValue({
      status: 422,
      message: 'Unprocessable',
      code: 'unprocessable',
      details: { detail: 'your exam session has expired' },
    })

    await openAndSubmit()

    expect(await screen.findByTestId('exam-expired')).toBeTruthy()
    expect(screen.queryByTestId('exam-submit-error')).toBeNull()
  })
})

describe('GH 2471 -- a submit in flight guards the button', () => {
  it('two clicks in one tick send one request and the button is busy meanwhile', async () => {
    let resolveSubmit!: (v: never) => void
    mockedExamApi.submitSession.mockReturnValue(
      new Promise((resolve) => (resolveSubmit = resolve as typeof resolveSubmit)),
    )
    renderPage()
    const button = await screen.findByTestId('exam-submit-action')

    fireEvent.click(button)
    fireEvent.click(button)

    expect(mockedExamApi.submitSession).toHaveBeenCalledTimes(1)
    await waitFor(() => expect(screen.getByTestId('exam-submit-action').hasAttribute('disabled')).toBe(true))
    expect(screen.getByTestId('ds-button-spinner')).toBeTruthy()

    resolveSubmit(SUBMITTED as never)
    await waitFor(() => expect(screen.queryByTestId('exam-session-page')).toBeNull())
    expect(mockedExamApi.submitSession).toHaveBeenCalledTimes(1)
  })

  it('a failed submit enables the button again and a retry sends a second request', async () => {
    mockedExamApi.submitSession
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce(SUBMITTED as never)
    const user = await openAndSubmit()

    await screen.findByTestId('exam-submit-error')
    await waitFor(() => expect(screen.getByTestId('exam-submit-action').hasAttribute('disabled')).toBe(false))

    await user.click(screen.getByTestId('exam-submit-action'))
    await waitFor(() => expect(screen.queryByTestId('exam-session-page')).toBeNull())
    expect(mockedExamApi.submitSession).toHaveBeenCalledTimes(2)
  })
})
