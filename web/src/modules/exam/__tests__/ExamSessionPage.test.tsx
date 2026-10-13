// @vitest-environment jsdom
/**
 * REQ-338 — ExamSessionPage, covering this requirement's own acceptance
 * criteria directly against rendered output (not just the underlying api/
 * util functions, which have their own narrower unit tests):
 *
 *  - AC2: each of REQ-332's six eligibility errors renders a distinct
 *    translated message.
 *  - AC3: the countdown is re-anchored to the server's remaining_seconds on
 *    every save response, immediately, not asymptotically.
 *  - AC4: autosave fires on answer change with visible feedback, and a
 *    deadline-passed save error surfaces a terminal state, not a retry loop.
 *  - AC5: a grading_pending outcome renders a pending state, never a numeric
 *    score, distinguished from a fully-graded submission.
 *  - AC6: each of the three anti-cheat signal types is wired to reportEvent.
 *  - AC7: a 'submit' anti-cheat outcome transitions to the result view using
 *    the server's own response, and tears down the listeners (no further
 *    reportEvent call after that transition).
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, fireEvent, waitFor } from '@testing-library/react'
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
      id: 'session-1',
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

describe('REQ-338 AC2 — six distinct eligibility errors', () => {
  const cases: Array<[string, string]> = [
    ['not_assigned', 'you are not assigned to this exam'],
    ['exam_archived', 'this exam has been archived and is no longer available'],
    ['exam_not_active', 'this exam is not currently active'],
    ['outside_availability_window', 'this exam is not available at this time'],
    ['attempts_exhausted', 'you have used all allowed attempts for this exam'],
    ['session_already_open', 'you already have an active session for this exam'],
  ]

  for (const [kind, detail] of cases) {
    it(`renders a distinct message for ${kind}`, async () => {
      mockedExamApi.startSession.mockRejectedValue({
        status: 403,
        message: 'Forbidden',
        code: 'FORBIDDEN',
        details: { detail },
      })

      renderPage()

      const errorEl = await screen.findByTestId('exam-start-error')
      expect(errorEl.textContent).toBeTruthy()

      // Collect this case's message, compared against the other five below.
      ;(cases as unknown as Record<string, string>)[`__rendered_${kind}`] = errorEl.textContent as string
    })
  }

  it('all six rendered messages are pairwise distinct', async () => {
    const rendered: string[] = []
    for (const [, detail] of cases) {
      mockedExamApi.startSession.mockRejectedValueOnce({
        status: 403,
        message: 'Forbidden',
        code: 'FORBIDDEN',
        details: { detail },
      })
      renderPage()
      const errorEl = await screen.findByTestId('exam-start-error')
      rendered.push(errorEl.textContent as string)
      cleanup()
    }
    expect(new Set(rendered).size).toBe(cases.length)
  })
})

describe('REQ-338 AC3/AC4 — autosave, countdown re-anchoring, deadline terminal state', () => {
  it('autosaves on answer change, re-anchors the countdown to the server value immediately, and shows save feedback', async () => {
    mockedExamApi.startSession.mockResolvedValue(sessionState({ remaining_seconds: 100 }))
    mockedExamApi.saveAnswer.mockResolvedValue({ remaining_seconds: 42 })

    renderPage()

    await screen.findByTestId('exam-session-page')
    expect(screen.getByRole('heading', { level: 1 }).textContent).toContain('01:40')

    fireEvent.click(screen.getByTestId('exam-option-opt-a'))

    await waitFor(() => expect(mockedExamApi.saveAnswer).toHaveBeenCalledTimes(1))
    expect(mockedExamApi.saveAnswer).toHaveBeenCalledWith(
      'session-1',
      'q1',
      expect.objectContaining({ selected_option_ids: ['opt-a'] }),
    )

    // Re-anchored immediately to the server's 42 -- not left free-running from 100.
    await waitFor(() => expect(screen.getByRole('heading', { level: 1 }).textContent).toContain('00:42'))
    await waitFor(() => expect(screen.getByTestId('exam-save-status').textContent).toBeTruthy())
  })

  it('a deadline-passed autosave error moves to a terminal expired state, not a retry loop', async () => {
    mockedExamApi.startSession.mockResolvedValue(sessionState())
    mockedExamApi.saveAnswer.mockRejectedValue({
      status: 422,
      message: 'Unprocessable Entity',
      code: '422',
      details: { detail: 'your exam session has expired' },
    })

    renderPage()
    await screen.findByTestId('exam-session-page')

    fireEvent.click(screen.getByTestId('exam-option-opt-a'))

    await screen.findByTestId('exam-expired')
    expect(mockedExamApi.saveAnswer).toHaveBeenCalledTimes(1)
  })
})

describe('REQ-338 AC5 — grading_pending vs a fully-graded result', () => {
  it('renders a pending state and no numeric score for grading_pending', async () => {
    mockedExamApi.startSession.mockResolvedValue(sessionState())
    mockedExamApi.submitSession.mockResolvedValue({
      status: 'grading_pending',
      total_score: 0,
      total_max_score: 10,
      percentage: 0,
      passed: null,
    })

    renderPage()
    await screen.findByTestId('exam-session-page')
    fireEvent.click(screen.getByTestId('exam-submit-action'))

    await screen.findByTestId('exam-result-pending')
    expect(screen.queryByTestId('exam-result-score')).not.toBeInTheDocument()
  })

  it('renders the real score for a fully-graded submission', async () => {
    mockedExamApi.startSession.mockResolvedValue(sessionState())
    mockedExamApi.submitSession.mockResolvedValue({
      status: 'submitted',
      total_score: 8,
      total_max_score: 10,
      percentage: 80,
      passed: true,
    })

    renderPage()
    await screen.findByTestId('exam-session-page')
    fireEvent.click(screen.getByTestId('exam-submit-action'))

    await screen.findByTestId('exam-result-score')
    expect(screen.queryByTestId('exam-result-pending')).not.toBeInTheDocument()
  })
})

describe('ISS-0650 — short_text question renders a real text input, wired through autosave', () => {
  function shortTextSessionState(overrides: Partial<ExamSessionStateResponse> = {}): ExamSessionStateResponse {
    return sessionState({
      questions: [
        {
          question_id: 'q1',
          sort_order: 1,
          type: 'short_text',
          stem: { en: 'What is the capital of France?' },
          options: [],
        },
      ],
      ...overrides,
    })
  }

  it('renders a real textarea, not the old "not yet supported" placeholder', async () => {
    mockedExamApi.startSession.mockResolvedValue(shortTextSessionState())

    renderPage()

    await screen.findByTestId('exam-session-page')
    expect(screen.getByTestId('exam-short-text-input')).toBeInTheDocument()
    expect(screen.queryByTestId('exam-short-text-unsupported')).not.toBeInTheDocument()
  })

  it('displays a previously-saved text_answer on load', async () => {
    mockedExamApi.startSession.mockResolvedValue(
      shortTextSessionState({
        answers: {
          q1: { selected_option_ids: [], text_answer: 'Paris', time_spent_seconds: 10, saved_at: '2026-09-13T00:00:00Z' },
        },
      }),
    )

    renderPage()

    const textarea = await screen.findByTestId('exam-short-text-input')
    expect((textarea as HTMLTextAreaElement).value).toBe('Paris')
  })

  it('autosaves on blur with the correct text_answer payload', async () => {
    mockedExamApi.startSession.mockResolvedValue(shortTextSessionState())
    mockedExamApi.saveAnswer.mockResolvedValue({ remaining_seconds: 42 })

    renderPage()
    await screen.findByTestId('exam-session-page')

    const textarea = await screen.findByTestId('exam-short-text-input')
    fireEvent.change(textarea, { target: { value: 'Paris' } })
    fireEvent.blur(textarea)

    await waitFor(() => expect(mockedExamApi.saveAnswer).toHaveBeenCalledTimes(1))
    expect(mockedExamApi.saveAnswer).toHaveBeenCalledWith(
      'session-1',
      'q1',
      expect.objectContaining({ selected_option_ids: [], text_answer: 'Paris' }),
    )
  })

  it('does not autosave on blur when the text has not changed from the saved value', async () => {
    mockedExamApi.startSession.mockResolvedValue(
      shortTextSessionState({
        answers: {
          q1: { selected_option_ids: [], text_answer: 'Paris', time_spent_seconds: 10, saved_at: '2026-09-13T00:00:00Z' },
        },
      }),
    )

    renderPage()
    const textarea = await screen.findByTestId('exam-short-text-input')
    fireEvent.blur(textarea)

    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(mockedExamApi.saveAnswer).not.toHaveBeenCalled()
  })
})

describe('REQ-338 AC6/AC7 — anti-cheat signal wiring and teardown', () => {
  it('visibilitychange -> tab_switch', async () => {
    mockedExamApi.startSession.mockResolvedValue(sessionState())
    mockedExamApi.reportEvent.mockResolvedValue({ action_taken: 'log', event_count: 1, warning: false, submission: null })

    renderPage()
    await screen.findByTestId('exam-session-page')

    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true })
    document.dispatchEvent(new Event('visibilitychange'))

    await waitFor(() => expect(mockedExamApi.reportEvent).toHaveBeenCalledWith('session-1', 'tab_switch'))
  })

  it('blur -> blur', async () => {
    mockedExamApi.startSession.mockResolvedValue(sessionState())
    mockedExamApi.reportEvent.mockResolvedValue({ action_taken: 'log', event_count: 1, warning: false, submission: null })

    renderPage()
    await screen.findByTestId('exam-session-page')

    window.dispatchEvent(new Event('blur'))

    await waitFor(() => expect(mockedExamApi.reportEvent).toHaveBeenCalledWith('session-1', 'blur'))
  })

  it('fullscreenchange -> fullscreen_exit', async () => {
    mockedExamApi.startSession.mockResolvedValue(sessionState())
    mockedExamApi.reportEvent.mockResolvedValue({ action_taken: 'log', event_count: 1, warning: false, submission: null })

    renderPage()
    await screen.findByTestId('exam-session-page')

    Object.defineProperty(document, 'fullscreenElement', { value: null, configurable: true })
    document.dispatchEvent(new Event('fullscreenchange'))

    await waitFor(() => expect(mockedExamApi.reportEvent).toHaveBeenCalledWith('session-1', 'fullscreen_exit'))
  })

  it('a warn outcome surfaces the running event count without changing screens', async () => {
    mockedExamApi.startSession.mockResolvedValue(sessionState())
    mockedExamApi.reportEvent.mockResolvedValue({ action_taken: 'warn', event_count: 2, warning: true, submission: null })

    renderPage()
    await screen.findByTestId('exam-session-page')

    window.dispatchEvent(new Event('blur'))

    const warningEl = await screen.findByTestId('exam-anticheat-warning')
    expect(warningEl.textContent).toContain('2')
    expect(screen.getByTestId('exam-session-page')).toBeInTheDocument()
  })

  it('a submit outcome transitions to the result view using the server response and tears down listeners', async () => {
    mockedExamApi.startSession.mockResolvedValue(sessionState())
    mockedExamApi.reportEvent.mockResolvedValue({
      action_taken: 'submit',
      event_count: 3,
      warning: false,
      submission: { status: 'submitted', total_score: 5, total_max_score: 10, percentage: 50, passed: false },
    })

    renderPage()
    await screen.findByTestId('exam-session-page')

    window.dispatchEvent(new Event('blur'))

    await screen.findByTestId('exam-result-page')
    expect(screen.queryByTestId('exam-session-page')).not.toBeInTheDocument()
    expect(mockedExamApi.reportEvent).toHaveBeenCalledTimes(1)

    // Leaving the in-progress screen tore the listeners down -- another
    // browser event triggers no further reportEvent call.
    window.dispatchEvent(new Event('blur'))
    document.dispatchEvent(new Event('visibilitychange'))
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(mockedExamApi.reportEvent).toHaveBeenCalledTimes(1)
  })
})

describe('ISS-0654 — forced anti-cheat submit flushes an uncommitted short_text draft first', () => {
  function shortTextSessionState(overrides: Partial<ExamSessionStateResponse> = {}): ExamSessionStateResponse {
    return sessionState({
      questions: [
        {
          question_id: 'q1',
          sort_order: 1,
          type: 'short_text',
          stem: { en: 'What is the capital of France?' },
          options: [],
        },
      ],
      ...overrides,
    })
  }

  it('awaits the flushed saveAnswer to completion before reportEvent is called, and the draft reaches the server', async () => {
    mockedExamApi.startSession.mockResolvedValue(shortTextSessionState())

    const order: string[] = []
    mockedExamApi.saveAnswer.mockImplementation(async () => {
      order.push('saveAnswer:start')
      // Deliberately slow, so a real race (flush fired-and-forgotten) would
      // let reportEvent's own resolution race ahead of this instead of
      // waiting for it.
      await new Promise((resolve) => setTimeout(resolve, 20))
      order.push('saveAnswer:resolved')
      return { remaining_seconds: 42 }
    })
    mockedExamApi.reportEvent.mockImplementation(async () => {
      order.push('reportEvent:called')
      return {
        action_taken: 'submit',
        event_count: 1,
        warning: false,
        submission: { status: 'submitted', total_score: 0, total_max_score: 10, percentage: 0, passed: false },
      }
    })

    renderPage()
    await screen.findByTestId('exam-session-page')

    const textarea = await screen.findByTestId('exam-short-text-input')
    // Keystroke only -- no blur on the textarea itself, matching the bug:
    // the candidate is still typing when the forced signal fires.
    fireEvent.change(textarea, { target: { value: 'Paris' } })

    // A browser-level signal (e.g. the tab-switch/window-blur REQ-333
    // listens for) fires with no textarea blur in between.
    window.dispatchEvent(new Event('blur'))

    await screen.findByTestId('exam-result-page')

    // The uncommitted draft was flushed through the SAME saveAnswer call
    // handleTextAnswerBlur uses, with the correct short_text payload shape.
    expect(mockedExamApi.saveAnswer).toHaveBeenCalledWith(
      'session-1',
      'q1',
      expect.objectContaining({ selected_option_ids: [], text_answer: 'Paris' }),
    )
    expect(mockedExamApi.reportEvent).toHaveBeenCalledWith('session-1', 'blur')

    // No race: the flush's saveAnswer fully resolved BEFORE reportEvent (the
    // call that can trigger the forced submit) was ever invoked.
    expect(order).toEqual(['saveAnswer:start', 'saveAnswer:resolved', 'reportEvent:called'])
  })

  it('does not call saveAnswer again on a forced submit when the draft already matches the saved value', async () => {
    mockedExamApi.startSession.mockResolvedValue(
      shortTextSessionState({
        answers: {
          q1: { selected_option_ids: [], text_answer: 'Paris', time_spent_seconds: 10, saved_at: '2026-09-13T00:00:00Z' },
        },
      }),
    )
    mockedExamApi.reportEvent.mockResolvedValue({
      action_taken: 'submit',
      event_count: 1,
      warning: false,
      submission: { status: 'submitted', total_score: 0, total_max_score: 10, percentage: 0, passed: false },
    })

    renderPage()
    await screen.findByTestId('exam-short-text-input')

    window.dispatchEvent(new Event('blur'))

    await screen.findByTestId('exam-result-page')
    expect(mockedExamApi.saveAnswer).not.toHaveBeenCalled()
  })
})

/**
 * Q-1075 / GH 2432: the page reports the measured running total on each save. It must never
 * send the stored value or a 0 default when time has passed. Date.now is driven by hand here.
 */
describe('Q-1075 / GH 2432 -- the save reports the measured running total, not the 0 default', () => {
  let dateNow: { mockRestore: () => void } | undefined

  afterEach(() => {
    dateNow?.mockRestore()
    dateNow = undefined
  })

  it('a save after a delay reports the seconds measured on the question, and later saves add to them', async () => {
    let now = 1_000_000
    dateNow = vi.spyOn(Date, 'now').mockImplementation(() => now)

    const q2 = {
      question_id: 'q2',
      sort_order: 2,
      type: 'single' as const,
      stem: { en: 'Question two' },
      options: [
        { id: 'opt-c', text: { en: 'Option C' } },
        { id: 'opt-d', text: { en: 'Option D' } },
      ],
    }
    mockedExamApi.startSession.mockResolvedValue(
      sessionState({ remaining_seconds: 100, questions: [sessionState().questions[0], q2] }),
    )
    mockedExamApi.saveAnswer.mockResolvedValue({ remaining_seconds: 42 })

    renderPage()
    await screen.findByTestId('exam-session-page')
    // Let the mount effect that starts the q1 clock run before the first advance. The effect reads
    // Date.now when it runs, so an advance that landed before it would drop q1's first seconds.
    await new Promise((resolve) => setImmediate(resolve))

    now += 3_000 // q1 shown for 3 s
    fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    now += 2_000 // q2 shown for 2 s
    fireEvent.click(screen.getByRole('button', { name: 'Previous' }))
    now += 1_000 // q1 revisited for 1 s, then answered: 3 s + 1 s = 4 s
    fireEvent.click(screen.getByTestId('exam-option-opt-a'))

    await waitFor(() => expect(mockedExamApi.saveAnswer).toHaveBeenCalledTimes(1))
    expect(mockedExamApi.saveAnswer.mock.calls[0][2]).toMatchObject({ time_spent_seconds: 4 })

    now += 1_000 // one more second on q1 before a second save: 4 s + 1 s = 5 s
    fireEvent.click(screen.getByTestId('exam-option-opt-b'))

    await waitFor(() => expect(mockedExamApi.saveAnswer).toHaveBeenCalledTimes(2))
    expect(mockedExamApi.saveAnswer.mock.calls[1][2]).toMatchObject({ time_spent_seconds: 5 })
  })
})
