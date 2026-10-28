// @vitest-environment jsdom
/**
 * REQ-589 - examiner grading screens: U-guard, U-list, U-answer, U-save, U-i18n.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, useLocation, useRoutes } from 'react-router-dom'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ACCESS_FIXTURES, accessState } from '@/auth/access/fixtures'
import type { AccessState } from '@/auth/access/types'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: {
      token: 'tok',
      display_name: 'Examiner',
      loginSource: 'oidc',
      tenant_slug: 'fixture-tenant',
      tenant_display_name: 'Fixture Tenant',
      tenant_id: 'tid-grading',
      tenant_type: 'test',
    },
    isAuthenticated: true,
  }),
}))

vi.mock('../exam.api', () => ({
  examApi: {},
  examAuthoringApi: {},
  examGradingApi: { listQueue: vi.fn(), getAnswer: vi.fn(), grade: vi.fn() },
}))

import { examGradingApi } from '../exam.api'
import { examRouteObjects } from '../examRoutes'
import { examModuleDefinition } from '../index'
import { EXAM_UI_LOCALES, examMessages } from '../examMessages'

const api = vi.mocked(examGradingApi)

const examiner: AccessState = {
  status: 'ready',
  info: {
    ...ACCESS_FIXTURES.tenantAdmin,
    permissions: [...ACCESS_FIXTURES.tenantAdmin.permissions, 'ExamGradingRead', 'ExamGradingWrite'],
  },
}

const ROW = (n: number) => ({
  session_id: `sess-${n}`,
  question_id: `q-${n}`,
  exam_title: `Exam title ${n}`,
  stem: `Stem text ${n}`,
  max_score: 1,
  submitted_at: `2026-10-0${n}T10:00:00Z`,
})

function Routes() {
  return useRoutes(examRouteObjects)
}

function Where() {
  return <span data-testid="where">{useLocation().pathname}</span>
}

function renderAt(path: string, access: AccessState = examiner) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const view = render(
    <QueryClientProvider client={client}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={[path]}>
          <Routes />
          <Where />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
  return view
}

beforeEach(() => {
  vi.clearAllMocks()
  api.listQueue.mockResolvedValue({ items: [ROW(1), ROW(2), ROW(3)], next_cursor: null })
  api.getAnswer.mockResolvedValue({ ...ROW(1), text_answer: 'my answer' })
})

afterEach(() => cleanup())

describe('REQ-589 U-guard', () => {
  it('both routes render for ExamGradingRead', async () => {
    renderAt('/exam/grading')
    expect(await screen.findByTestId('exam-grading-list-page')).toBeInTheDocument()
    cleanup()
    renderAt('/exam/grading/sess-1/q-1')
    expect(await screen.findByTestId('exam-grading-answer-page')).toBeInTheDocument()
  })

  it('both routes show the forbidden page for the candidate fixture', async () => {
    for (const path of ['/exam/grading', '/exam/grading/sess-1/q-1']) {
      renderAt(path, accessState('candidate'))
      expect(await screen.findByText(/You do not have access to this area/)).toBeInTheDocument()
      expect(screen.queryByTestId('exam-grading-list-page')).not.toBeInTheDocument()
      expect(screen.queryByTestId('exam-grading-answer-page')).not.toBeInTheDocument()
      cleanup()
    }
    expect(api.listQueue).not.toHaveBeenCalled()
    expect(api.getAnswer).not.toHaveBeenCalled()
  })

  it('both routes are in examRouteObjects and the nav entry needs ExamGradingRead', () => {
    const exam = examRouteObjects.find((r) => r.path === 'exam')
    const paths = (exam?.children ?? []).map((c) => c.path)
    expect(paths).toContain('grading')
    expect(paths).toContain('grading/:sessionId/:questionId')
    expect(examModuleDefinition.routeObjects).toBe(examRouteObjects)
    const nav = examModuleDefinition.navItems.find((n) => n.to === '/exam/grading')
    expect(nav).toMatchObject({ label: 'Grading', permission: 'ExamGradingRead' })
  })
})

describe('REQ-589 U-list', () => {
  it('shows three rows without candidate identity', async () => {
    renderAt('/exam/grading')
    const rows = await screen.findAllByTestId('exam-grading-row')
    expect(rows).toHaveLength(3)
    expect(rows[0]).toHaveTextContent('Exam title 1')
    expect(rows[0]).toHaveTextContent('Stem text 1')
    expect(rows[0].querySelectorAll('td')[2].textContent).toMatch(/2026/)
    expect(screen.getByTestId('exam-grading-table').textContent).not.toMatch(/user|candidate|@/i)
  })

  it('the exam filter sends the exam id', async () => {
    renderAt('/exam/grading')
    await screen.findAllByTestId('exam-grading-row')
    fireEvent.change(screen.getByTestId('exam-grading-filter-input'), { target: { value: ' exam-42 ' } })
    fireEvent.click(screen.getByTestId('exam-grading-filter-apply'))
    await waitFor(() =>
      expect(api.listQueue).toHaveBeenLastCalledWith(expect.objectContaining({ exam_id: 'exam-42' })),
    )
  })

  it('paging follows next_cursor', async () => {
    api.listQueue.mockImplementation(async (opts) =>
      opts?.cursor === 'c2'
        ? { items: [ROW(3)], next_cursor: null }
        : { items: [ROW(1), ROW(2)], next_cursor: 'c2' },
    )
    renderAt('/exam/grading')
    await screen.findAllByTestId('exam-grading-row')
    const nextBtn = () => screen.getByTestId('pagination-next').querySelector('button')!
    const prevBtn = () => screen.getByTestId('pagination-prev').querySelector('button')!
    expect(nextBtn()).toBeEnabled()
    expect(prevBtn()).toBeDisabled()
    fireEvent.click(nextBtn())
    await screen.findByText('Exam title 3')
    expect(api.listQueue).toHaveBeenLastCalledWith(expect.objectContaining({ cursor: 'c2' }))
    expect(screen.getAllByTestId('exam-grading-row')).toHaveLength(1)
    expect(nextBtn()).toBeDisabled()
    fireEvent.click(prevBtn())
    await screen.findByText('Exam title 1')
  })

  it('an empty response shows the empty-state text', async () => {
    api.listQueue.mockResolvedValue({ items: [], next_cursor: null })
    renderAt('/exam/grading')
    expect(await screen.findByTestId('exam-grading-empty')).toHaveTextContent(
      examMessages.en['exam.grading.list.empty'],
    )
  })
})

describe('REQ-589 U-answer', () => {
  it('shows markup in the answer as literal text', async () => {
    api.getAnswer.mockResolvedValue({ ...ROW(1), text_answer: '<script>alert(1)</script>' })
    renderAt('/exam/grading/sess-1/q-1')
    const text = await screen.findByTestId('exam-grading-text')
    expect(text.textContent).toBe('<script>alert(1)</script>')
    expect(text.querySelector('script')).toBeNull()
    expect(document.querySelector('script')).toBeNull()
  })

  it('Save is enabled only for 0..max', async () => {
    api.getAnswer.mockResolvedValue({ ...ROW(1), max_score: 2.5, text_answer: 'a' })
    renderAt('/exam/grading/sess-1/q-1')
    const input = await screen.findByTestId('exam-grading-score')
    const save = screen.getByTestId('exam-grading-save')
    expect(save).toBeDisabled()
    const cases: [string, boolean][] = [
      ['0', true],
      ['2.5', true],
      ['1.25', true],
      ['2.6', false],
      ['-1', false],
      ['', false],
    ]
    for (const [value, enabled] of cases) {
      fireEvent.change(input, { target: { value } })
      if (enabled) expect(save).toBeEnabled()
      else expect(save).toBeDisabled()
    }
    expect(screen.getByTestId('exam-grading-max')).toHaveTextContent('2.5')
  })
})

describe('REQ-589 U-save', () => {
  async function fillAndSave() {
    const view = renderAt('/exam/grading/sess-1/q-1')
    fireEvent.change(await screen.findByTestId('exam-grading-score'), { target: { value: '0.5' } })
    fireEvent.click(screen.getByTestId('exam-grading-save'))
    return view
  }

  it('200: one request with only score, confirmation, list re-fetched', async () => {
    api.grade.mockResolvedValue({
      session_id: 'sess-1',
      question_id: 'q-1',
      score: 0.5,
      max_score: 1,
      grading_status: 'graded',
      session_status: 'submitted',
    })
    await fillAndSave()
    expect(await screen.findByTestId('exam-grading-list-page')).toBeInTheDocument()
    expect(screen.getByTestId('where').textContent).toBe('/exam/grading')
    expect(api.grade).toHaveBeenCalledTimes(1)
    expect(api.grade).toHaveBeenCalledWith('sess-1', 'q-1', 0.5)
    expect(await screen.findByTestId('exam-grading-notice')).toHaveTextContent(
      examMessages.en['exam.grading.saved'],
    )
    await waitFor(() => expect(api.listQueue).toHaveBeenCalled())
  })

  it('409: already-graded text and the list is re-fetched', async () => {
    api.grade.mockRejectedValue({ status: 409, message: 'Conflict', code: 'x' })
    await fillAndSave()
    expect(await screen.findByTestId('exam-grading-notice')).toHaveTextContent(
      examMessages.en['exam.grading.alreadyGraded'],
    )
    await waitFor(() => expect(api.listQueue).toHaveBeenCalled())
  })

  it('422: field error, stays on the answer', async () => {
    api.grade.mockRejectedValue({ status: 422, message: 'bad', code: '422' })
    await fillAndSave()
    expect(await screen.findByTestId('exam-grading-field-error')).toHaveTextContent(
      examMessages.en['exam.grading.answer.scoreInvalid'],
    )
    expect(screen.getByTestId('exam-grading-answer-page')).toBeInTheDocument()
  })

  it('404: the not-found page', async () => {
    api.grade.mockRejectedValue({ status: 404, message: 'nf', code: '404' })
    await fillAndSave()
    expect(await screen.findByTestId('not-found-page')).toBeInTheDocument()
  })

  it('404 on load: the not-found page', async () => {
    api.getAnswer.mockRejectedValue({ status: 404, message: 'nf', code: '404' })
    renderAt('/exam/grading/sess-1/q-1')
    expect(await screen.findByTestId('not-found-page')).toBeInTheDocument()
  })

  it('a double click sends one request', async () => {
    api.grade.mockImplementation(() => new Promise(() => {}))
    renderAt('/exam/grading/sess-1/q-1')
    fireEvent.change(await screen.findByTestId('exam-grading-score'), { target: { value: '1' } })
    const save = screen.getByTestId('exam-grading-save')
    fireEvent.click(save)
    fireEvent.click(save)
    await waitFor(() => expect(api.grade).toHaveBeenCalledTimes(1))
    await new Promise((r) => setTimeout(r, 20))
    expect(api.grade).toHaveBeenCalledTimes(1)
  })
})

describe('REQ-589 U-i18n', () => {
  it('every grading key exists in kk, ru and en and is non-empty', () => {
    const keys = Object.keys(examMessages.en).filter((k) => k.startsWith('exam.grading.'))
    expect(keys.length).toBeGreaterThan(10)
    for (const locale of EXAM_UI_LOCALES) {
      for (const key of keys) {
        expect(examMessages[locale][key], `${locale} ${key}`).toBeTruthy()
      }
    }
  })

  it.each(['ru', 'kk'] as const)('the list renders in %s with no missing-key fallback', async (locale) => {
    const spy = vi.spyOn(navigator, 'languages', 'get').mockReturnValue([locale])
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {})
    api.listQueue.mockResolvedValue({ items: [], next_cursor: null })
    renderAt('/exam/grading')
    expect(await screen.findByTestId('exam-grading-empty')).toHaveTextContent(
      examMessages[locale]['exam.grading.list.empty'],
    )
    expect(screen.getByTestId('exam-grading-list-page').textContent).not.toMatch(/exam\.grading\./)
    expect(errors).not.toHaveBeenCalled()
    spy.mockRestore()
    errors.mockRestore()
  })
})
