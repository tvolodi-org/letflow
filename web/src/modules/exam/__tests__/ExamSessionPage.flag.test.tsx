// @vitest-environment jsdom
/**
 * REQ-611 / GH 3421 -- the flag/unflag control on the exam-taking screen. The flag is browser-only state:
 * it marks and counts, and never reaches the server.
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor, fireEvent } from '@testing-library/react'
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

const SESSION_ID = 'session-flag-1'
const SUBMITTED = { status: 'submitted' as const, score_pct: 100, passed: true, session_id: SESSION_ID }

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

function question(id: string) {
  return {
    question_id: id,
    sort_order: 1,
    type: 'single' as const,
    stem: { en: `Stem ${id}` },
    options: [{ id: `${id}-a`, text: { en: 'A' } }],
  }
}

function sessionState(): ExamSessionStateResponse {
  return {
    session: {
      id: SESSION_ID,
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
    questions: [question('q1'), question('q2'), question('q3')],
    answers: {},
  }
}

function toggle() {
  return screen.getByTestId('exam-flag-toggle')
}

beforeEach(() => {
  vi.clearAllMocks()
  mockedExamApi.startSession.mockResolvedValue(sessionState())
  mockedExamApi.submitSession.mockResolvedValue(SUBMITTED as never)
})

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('REQ-611 -- flag toggle', () => {
  it('F1 flips aria-pressed false -> true -> false', async () => {
    renderPage()
    await screen.findByTestId('exam-flag-toggle')
    expect(toggle()).toHaveAttribute('aria-pressed', 'false')
    fireEvent.click(toggle())
    expect(toggle()).toHaveAttribute('aria-pressed', 'true')
    fireEvent.click(toggle())
    expect(toggle()).toHaveAttribute('aria-pressed', 'false')
  })

  it('F2 the flag persists while paging Next then Previous', async () => {
    renderPage()
    await screen.findByTestId('exam-flag-toggle')
    fireEvent.click(toggle())
    fireEvent.click(screen.getByText('Next'))
    await screen.findByText('Stem q2')
    expect(toggle()).toHaveAttribute('aria-pressed', 'false')
    fireEvent.click(screen.getByText('Previous'))
    await screen.findByText('Stem q1')
    expect(toggle()).toHaveAttribute('aria-pressed', 'true')
  })

  it('F3 the flagged count is absent at 0, then 2, then 1', async () => {
    renderPage()
    await screen.findByTestId('exam-flag-toggle')
    expect(screen.queryByTestId('exam-flagged-count')).toBeNull()
    fireEvent.click(toggle())
    expect(screen.getByTestId('exam-flagged-count')).toHaveTextContent('Flagged: 1')
    fireEvent.click(screen.getByText('Next'))
    await screen.findByText('Stem q2')
    fireEvent.click(toggle())
    expect(screen.getByTestId('exam-flagged-count')).toHaveTextContent('Flagged: 2')
    fireEvent.click(toggle())
    expect(screen.getByTestId('exam-flagged-count')).toHaveTextContent('Flagged: 1')
  })

  it('F4 the count and toggle label use the active locale (ru)', async () => {
    vi.spyOn(window.navigator, 'languages', 'get').mockReturnValue(['ru-RU'])
    renderPage()
    await screen.findByTestId('exam-flag-toggle')
    expect(toggle()).toHaveTextContent('Отметить вопрос')
    fireEvent.click(toggle())
    expect(toggle()).toHaveTextContent('Снять отметку')
    expect(screen.getByTestId('exam-flagged-count')).toHaveTextContent('Отмечено: 1')
  })

  it('F5 toggling sends no request of any kind', async () => {
    renderPage()
    await screen.findByTestId('exam-flag-toggle')
    mockedExamApi.startSession.mockClear()
    fireEvent.click(toggle())
    fireEvent.click(toggle())
    fireEvent.click(toggle())
    expect(mockedExamApi.saveAnswer).not.toHaveBeenCalled()
    expect(mockedExamApi.submitSession).not.toHaveBeenCalled()
    expect(mockedExamApi.reportEvent).not.toHaveBeenCalled()
    expect(mockedExamApi.startSession).not.toHaveBeenCalled()
  })

  it('F6 submit is not blocked by two flags and sends the same arguments as without flags', async () => {
    renderPage()
    await screen.findByTestId('exam-flag-toggle')
    fireEvent.click(screen.getByTestId('exam-submit-action'))
    await waitFor(() => expect(mockedExamApi.submitSession).toHaveBeenCalledTimes(1))
    const unflaggedArgs = mockedExamApi.submitSession.mock.calls[0]
    cleanup()
    vi.clearAllMocks()
    mockedExamApi.startSession.mockResolvedValue(sessionState())
    mockedExamApi.submitSession.mockResolvedValue(SUBMITTED as never)

    renderPage()
    await screen.findByTestId('exam-flag-toggle')
    fireEvent.click(toggle())
    fireEvent.click(screen.getByText('Next'))
    await screen.findByText('Stem q2')
    fireEvent.click(toggle())
    expect(screen.getByTestId('exam-flagged-count')).toHaveTextContent('Flagged: 2')
    fireEvent.click(screen.getByTestId('exam-submit-action'))
    await waitFor(() => expect(mockedExamApi.submitSession).toHaveBeenCalledTimes(1))
    expect(mockedExamApi.submitSession.mock.calls[0]).toEqual(unflaggedArgs)
    expect(screen.queryByRole('dialog')).toBeNull()
  })
})
