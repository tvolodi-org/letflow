// @vitest-environment jsdom
/**
 * GH 2941 -- Submit waits for in-flight answer autosaves, so the last answer is graded.
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
      {
        question_id: 'q2',
        sort_order: 2,
        type: 'short_text',
        stem: { en: 'Question two' },
        options: [],
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


const SAVED = { remaining_seconds: 42 }

describe('GH 2941 -- Submit waits for pending saves', () => {
  it('sends the submit only after an in-flight option save has resolved', async () => {
    let resolveSave!: (v: typeof SAVED) => void
    mockedExamApi.saveAnswer.mockReturnValue(new Promise((resolve) => (resolveSave = resolve)))
    mockedExamApi.submitSession.mockResolvedValue(SUBMITTED as never)
    renderPage()
    fireEvent.click(await screen.findByTestId('exam-option-opt-b'))
    await waitFor(() => expect(mockedExamApi.saveAnswer).toHaveBeenCalledTimes(1))

    fireEvent.click(screen.getByTestId('exam-submit-action'))
    await new Promise((r) => setTimeout(r, 20))
    expect(mockedExamApi.submitSession).not.toHaveBeenCalled()

    resolveSave(SAVED)
    await waitFor(() => expect(mockedExamApi.submitSession).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(screen.queryByTestId('exam-session-page')).toBeNull())
  })

  it('flushes a pending short_text draft before submitting', async () => {
    mockedExamApi.saveAnswer.mockResolvedValue(SAVED)
    const order: string[] = []
    mockedExamApi.saveAnswer.mockImplementation(async () => {
      order.push('save')
      return SAVED
    })
    mockedExamApi.submitSession.mockImplementation(async () => {
      order.push('submit')
      return SUBMITTED as never
    })
    renderPage()
    fireEvent.click(await screen.findByText('Next'))
    fireEvent.change(await screen.findByTestId('exam-short-text-input'), { target: { value: 'Paris' } })

    fireEvent.click(screen.getByTestId('exam-submit-action'))

    await waitFor(() => expect(mockedExamApi.submitSession).toHaveBeenCalledTimes(1))
    expect(mockedExamApi.saveAnswer).toHaveBeenCalledWith(
      OPEN_SESSION_ID,
      'q2',
      expect.objectContaining({ text_answer: 'Paris' }),
    )
    expect(order).toEqual(['save', 'submit'])
  })

  it('does not submit when a pending save fails: the page stays open with the save error shown', async () => {
    let rejectSave!: (e: unknown) => void
    mockedExamApi.saveAnswer.mockReturnValue(new Promise((_, reject) => (rejectSave = reject)))
    renderPage()
    fireEvent.click(await screen.findByTestId('exam-option-opt-b'))
    await waitFor(() => expect(mockedExamApi.saveAnswer).toHaveBeenCalledTimes(1))

    fireEvent.click(screen.getByTestId('exam-submit-action'))
    rejectSave(new TypeError('Failed to fetch'))

    await screen.findByTestId('exam-submit-error')
    expect(mockedExamApi.submitSession).not.toHaveBeenCalled()
    expect(screen.getByTestId('exam-session-page')).toBeTruthy()
    expect(screen.getByText('Could not save your answer', { exact: false })).toBeTruthy()
    await waitFor(() => expect(screen.getByTestId('exam-submit-action').hasAttribute('disabled')).toBe(false))
  })

  it('two clicks while a save is pending still send one submit', async () => {
    let resolveSave!: (v: typeof SAVED) => void
    mockedExamApi.saveAnswer.mockReturnValue(new Promise((resolve) => (resolveSave = resolve)))
    mockedExamApi.submitSession.mockResolvedValue(SUBMITTED as never)
    renderPage()
    fireEvent.click(await screen.findByTestId('exam-option-opt-b'))
    const button = screen.getByTestId('exam-submit-action')
    fireEvent.click(button)
    fireEvent.click(button)
    resolveSave(SAVED)
    await waitFor(() => expect(mockedExamApi.submitSession).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(screen.queryByTestId('exam-session-page')).toBeNull())
    expect(mockedExamApi.submitSession).toHaveBeenCalledTimes(1)
  })
})
