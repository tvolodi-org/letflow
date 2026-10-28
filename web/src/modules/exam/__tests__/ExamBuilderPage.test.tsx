// @vitest-environment jsdom
/**
 * GH 3355 / REQ-602 — the exam builder screen: L (load), S (save), V (validation), E (errors),
 * G (gating). The HTTP client is mocked, so the tests assert the real requests of exam.api.ts.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ACCESS_FIXTURES } from '@/auth/access/fixtures'
import type { AccessState } from '@/auth/access/types'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-builder' }, isAuthenticated: true }),
}))

const clientMock = vi.hoisted(() => ({
  post: vi.fn(),
  putWithHeaders: vi.fn(),
  delete: vi.fn(),
  get: vi.fn(),
}))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

import { examRouteObjects } from '../examRoutes'

const EXAM = '11111111-1111-4111-8111-111111111111'
const SEC_A = '22222222-2222-4222-8222-222222222222'
const SEC_B = '33333333-3333-4333-8333-333333333333'
const R1 = '44444444-4444-4444-8444-444444444441'
const R2 = '44444444-4444-4444-8444-444444444442'
const R3 = '44444444-4444-4444-8444-444444444443'
const AUTH = '/api/v1/modules/exam/authoring'

const rec = (record_id: string, field_values: Record<string, unknown>) => ({
  record_id,
  field_values,
  deleted: false,
  entity_def_version: 'v1',
  last_event_global_seq: 1,
})

const DATA = {
  exam: [
    rec(EXAM, {
      title: { en: 'Safety exam' },
      status: 'draft',
      time_limit_minutes: 60,
      passing_score_pct: 70,
      max_attempts: 2,
      shuffle_questions: false,
      shuffle_options: false,
      show_answers: 'never',
      on_tab_switch: 'log',
      certificate_enabled: false,
    }),
  ],
  // Shuffled on purpose: the screen orders them by sort_order.
  exam_section: [
    rec(SEC_A, { exam_id: EXAM, title: { en: 'Part A' }, sort_order: 2 }),
    rec(SEC_B, { exam_id: EXAM, title: { en: 'Part B' }, sort_order: 1 }),
  ],
  exam_question_rule: [
    rec(R1, { exam_id: EXAM, section_id: SEC_A, mode: 'random', count: 2, sort_order: 1 }),
    rec(R2, { exam_id: EXAM, section_id: SEC_B, mode: 'random', count: 1, sort_order: 2 }),
    rec(R3, { exam_id: EXAM, mode: 'manual', count: 1, sort_order: 3 }),
  ],
}

let data: Record<string, unknown[]>
let failRuleOnce = false

function queryCalls() {
  return clientMock.post.mock.calls.filter(([path]) => path === '/api/v1/entities/query')
}
let writes: unknown[][] = []
function writeCalls() {
  return writes
}

beforeEach(() => {
  data = structuredClone(DATA)
  failRuleOnce = false
  writes = []
  clientMock.post.mockReset()
  clientMock.putWithHeaders.mockReset()
  clientMock.delete.mockReset()
  clientMock.post.mockImplementation(async (path: string, body: { entity_type?: string }) => {
    if (path === '/api/v1/entities/query') return { items: data[body.entity_type as string] ?? [], next_cursor: null }
    if (path.startsWith(AUTH)) writes.push(['POST', path, body])
    if (path === `${AUTH}/exam_section`) return rec('sec-new', {})
    if (path === `${AUTH}/exam_question_rule`) {
      if (failRuleOnce) {
        failRuleOnce = false
        throw { status: 500, message: 'boom' }
      }
      return rec('rule-new', {})
    }
    throw new Error(`unexpected POST ${path}`)
  })
  clientMock.putWithHeaders.mockImplementation(async (p: string, b: unknown, h: unknown) => {
    writes.push(['PUT', p, b, h])
    return rec('x', {})
  })
  clientMock.delete.mockImplementation(async (p: string) => {
    writes.push(['DELETE', p])
    return rec('x', {})
  })
})

afterEach(() => cleanup())

const writer: AccessState = { status: 'ready', info: ACCESS_FIXTURES.tenantAdmin }
const reader: AccessState = {
  status: 'ready',
  info: {
    ...ACCESS_FIXTURES.tenantAdmin,
    permissions: ACCESS_FIXTURES.tenantAdmin.permissions.filter((p) => p !== 'ExamAuthoringWrite'),
  },
}

function Routes() {
  return useRoutes(examRouteObjects)
}

function renderAt(path: string, access: AccessState = writer) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={[path]}>
          <Routes />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

async function open() {
  renderAt(`/admin/bilimbaga/exam-builder/${EXAM}`)
  await screen.findByTestId('exam-builder-exam')
}

const field = (id: string) => screen.getByTestId(id) as HTMLInputElement
const setValue = (id: string, value: string) => fireEvent.change(field(id), { target: { value } })
const click = (id: string) => fireEvent.click(screen.getByTestId(id))

describe('L load', () => {
  it('L1 sends one query per entity type with the exam id filter', async () => {
    await open()
    const calls = queryCalls().map(([, body]) => body)
    expect(calls).toHaveLength(3)
    expect(calls.map((b) => b.entity_type).sort()).toEqual(['exam', 'exam_question_rule', 'exam_section'])
    expect(calls.find((b) => b.entity_type === 'exam').filters).toEqual([{ field: 'record_id', op: 'eq', value: EXAM }])
    for (const type of ['exam_section', 'exam_question_rule']) {
      const body = calls.find((b) => b.entity_type === type)
      expect(body.filters).toEqual([{ field: 'exam_id', op: 'eq', value: EXAM }])
      expect(body.sort).toEqual([{ field: 'sort_order', dir: 'asc' }])
    }
  })

  it('L2 orders sections by sort_order and groups rules under them', async () => {
    await open()
    const sectionIds = screen
      .getAllByTestId(/^exam-builder-section-[0-9a-f-]{36}$/)
      .map((el) => el.getAttribute('data-testid'))
    expect(sectionIds).toEqual([`exam-builder-section-${SEC_B}`, `exam-builder-section-${SEC_A}`])
    expect(within(screen.getByTestId(`exam-builder-section-${SEC_A}`)).getByTestId(`exam-builder-rule-${R1}`)).toBeInTheDocument()
    expect(within(screen.getByTestId(`exam-builder-section-${SEC_B}`)).getByTestId(`exam-builder-rule-${R2}`)).toBeInTheDocument()
    expect(within(screen.getByTestId('exam-builder-group-unsectioned')).getByTestId(`exam-builder-rule-${R3}`)).toBeInTheDocument()
    expect(field('exam-builder-exam-title-en').value).toBe('Safety exam')
  })
})

describe('S save', () => {
  it('S1 saves PUT exam, sections, rules, then deletes with rules first', async () => {
    await open()
    setValue('exam-builder-exam-time_limit_minutes', '90')
    click('exam-builder-add-section')
    setValue('exam-builder-section-new-s1-sort_order', '5')
    setValue('exam-builder-section-new-s1-title-en', 'Part C')
    click('exam-builder-section-new-s1-add-rule')
    setValue(`exam-builder-rule-${R1}-count`, '3')
    click(`exam-builder-rule-${R3}-remove`)
    click(`exam-builder-section-${SEC_B}-remove`)
    click('exam-builder-save')
    await screen.findByTestId('exam-builder-saved')

    const calls = writeCalls()
    expect(calls.map(([method, path]) => `${method} ${String(path).replace(AUTH, '')}`)).toEqual([
      `PUT /exam/${EXAM}`,
      'POST /exam_section',
      `PUT /exam_question_rule/${R1}`,
      'POST /exam_question_rule',
      `DELETE /exam_question_rule/${R3}`,
      `DELETE /exam_question_rule/${R2}`,
      `DELETE /exam_section/${SEC_B}`,
    ])
    const [examPut, sectionPost, r1Put, rulePost] = calls
    expect(examPut[2]).toMatchObject({ field_values: { time_limit_minutes: 90, title: { en: 'Safety exam' } } })
    expect(Object.keys(examPut[2] as object)).toEqual(['field_values'])
    expect((examPut[2] as { field_values: object }).field_values).not.toHaveProperty('exam_id')
    expect(examPut[3]).toEqual({})
    expect(sectionPost[2]).toEqual({ field_values: { exam_id: EXAM, sort_order: 5, title: { en: 'Part C' } } })
    expect(r1Put[2]).toMatchObject({ field_values: { exam_id: EXAM, section_id: SEC_A, count: 3 } })
    expect(rulePost[2]).toMatchObject({ field_values: { exam_id: EXAM, section_id: 'sec-new', mode: 'random', count: 1 } })
  })

  it('S2 sends only the exam when nothing else changed', async () => {
    await open()
    click('exam-builder-save')
    await screen.findByTestId('exam-builder-saved')
    expect(writeCalls().map(([method]) => method)).toEqual(['PUT'])
  })
})

describe('V validation', () => {
  it.each([
    ['exam title', () => setValue('exam-builder-exam-title-en', ''), 'exam-builder-exam-title'],
    ['time limit missing', () => setValue('exam-builder-exam-time_limit_minutes', ''), 'exam-builder-exam-time_limit_minutes'],
    ['passing score missing', () => setValue('exam-builder-exam-passing_score_pct', ''), 'exam-builder-exam-passing_score_pct'],
    ['passing score above 100', () => setValue('exam-builder-exam-passing_score_pct', '101'), 'exam-builder-exam-passing_score_pct'],
    ['attempts zero', () => setValue('exam-builder-exam-max_attempts', '0'), 'exam-builder-exam-max_attempts'],
    ['rule count zero', () => setValue(`exam-builder-rule-${R1}-count`, '0'), `exam-builder-rule-${R1}-count`],
    ['rule sort missing', () => setValue(`exam-builder-rule-${R1}-sort_order`, ''), `exam-builder-rule-${R1}-sort_order`],
    ['duplicate section sort', () => setValue(`exam-builder-section-${SEC_A}-sort_order`, '1'), `exam-builder-section-${SEC_A}-sort_order`],
    ['duplicate rule sort', () => setValue(`exam-builder-rule-${R2}-sort_order`, '1'), `exam-builder-rule-${R2}-sort_order`],
  ])('V %s shows a message at the control and sends nothing', async (_name, edit, testId) => {
    await open()
    edit()
    click('exam-builder-save')
    expect(await screen.findByTestId(`${testId}-error`)).toBeInTheDocument()
    expect(screen.getByTestId('exam-builder-banner')).toBeInTheDocument()
    expect(writeCalls()).toEqual([])
  })
})

describe('E errors', () => {
  it('E1 puts a 422 (real client shape: details is the list) at the matching control', async () => {
    clientMock.putWithHeaders.mockRejectedValueOnce({
      status: 422,
      message: 'Validation failed',
      details: [{ code: 'out_of_range', path: ['time_limit_minutes'], message: 'too long' }],
    })
    await open()
    click('exam-builder-save')
    const message = await screen.findByTestId('exam-builder-exam-time_limit_minutes-error')
    expect(message).toHaveTextContent('too long')
    expect(screen.getByTestId('exam-builder-exam-time_limit_minutes')).toHaveAttribute('aria-invalid', 'true')
  })

  it('E1 also reads {errors: [...]} with a string path, on the failing rule', async () => {
    clientMock.putWithHeaders
      .mockResolvedValueOnce(rec('x', {}))
      .mockRejectedValueOnce({ status: 422, message: 'bad', details: { errors: [{ path: 'count', message: 'too many' }] } })
    await open()
    setValue(`exam-builder-rule-${R1}-count`, '9')
    click('exam-builder-save')
    expect(await screen.findByTestId(`exam-builder-rule-${R1}-count-error`)).toHaveTextContent('too many')
  })

  it('E2 shows the 409 message with Reload, and Reload loads again and drops the draft', async () => {
    clientMock.putWithHeaders.mockRejectedValueOnce({ status: 409, message: 'Conflict', details: { xResourceVersion: 'v9' } })
    await open()
    setValue('exam-builder-exam-time_limit_minutes', '15')
    click('exam-builder-save')
    expect(await screen.findByTestId('exam-builder-banner')).toHaveTextContent('changed or removed elsewhere')
    expect(queryCalls()).toHaveLength(3)
    click('exam-builder-reload')
    await waitFor(() => expect(queryCalls()).toHaveLength(6))
    await waitFor(() => expect(field('exam-builder-exam-time_limit_minutes').value).toBe('60'))
    expect(screen.queryByTestId('exam-builder-banner')).not.toBeInTheDocument()
  })

  it('E3 shows a forbidden message for 403 and a generic one for other errors', async () => {
    clientMock.putWithHeaders.mockRejectedValueOnce({ status: 403, message: 'Forbidden' })
    await open()
    click('exam-builder-save')
    expect(await screen.findByTestId('exam-builder-banner')).toHaveTextContent('You may not edit exams.')

    clientMock.putWithHeaders.mockRejectedValueOnce({ status: 500, message: 'boom' })
    click('exam-builder-save')
    await waitFor(() => expect(screen.getByTestId('exam-builder-banner')).toHaveTextContent('could not be saved'))
  })

  it('E4 stops at the first failure, lists saved and unsaved changes, and a retry does not repeat the POST', async () => {
    failRuleOnce = true
    await open()
    click('exam-builder-add-section')
    click('exam-builder-section-new-s1-add-rule')
    click(`exam-builder-rule-${R3}-remove`)
    click('exam-builder-save')
    await screen.findByTestId('exam-builder-save-result')
    expect(screen.getAllByTestId('exam-builder-save-result-item').map((li) => li.getAttribute('data-status'))).toEqual([
      'done',
      'done',
      'failed',
      'pending',
    ])
    expect(writeCalls().map(([method, path]) => `${method} ${String(path).replace(AUTH, '')}`)).toEqual([
      `PUT /exam/${EXAM}`,
      'POST /exam_section',
      'POST /exam_question_rule',
    ])
    expect(clientMock.delete).not.toHaveBeenCalled()

    click('exam-builder-save')
    await screen.findByTestId('exam-builder-saved')
    expect(writeCalls().map(([method, path]) => `${method} ${String(path).replace(AUTH, '')}`)).toEqual([
      `PUT /exam/${EXAM}`,
      'POST /exam_section',
      'POST /exam_question_rule',
      `PUT /exam/${EXAM}`,
      'POST /exam_question_rule',
      `DELETE /exam_question_rule/${R3}`,
    ])
  })
})

describe('G gating', () => {
  it('G1 without ExamAuthoringWrite shows the forbidden state, no editor and no request', async () => {
    renderAt(`/admin/bilimbaga/exam-builder/${EXAM}`, reader)
    expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
    expect(screen.queryByTestId('exam-builder-page')).not.toBeInTheDocument()
    expect(clientMock.post).not.toHaveBeenCalled()
  })

  it('G2 a non-UUID id shows not-found and sends no request', async () => {
    renderAt('/admin/bilimbaga/exam-builder/not-a-uuid')
    expect(await screen.findByTestId('exam-builder-not-found')).toBeInTheDocument()
    expect(clientMock.post).not.toHaveBeenCalled()
  })

  it('G3 an unknown id (empty exam page) shows not-found, not an empty form', async () => {
    data.exam = []
    renderAt(`/admin/bilimbaga/exam-builder/${EXAM}`)
    expect(await screen.findByTestId('exam-builder-not-found')).toBeInTheDocument()
    expect(screen.queryByTestId('exam-builder-exam')).not.toBeInTheDocument()
  })

  it('G4 a 404 from the query shows not-found', async () => {
    clientMock.post.mockRejectedValue({ status: 404, message: 'not found' })
    renderAt(`/admin/bilimbaga/exam-builder/${EXAM}`)
    expect(await screen.findByTestId('exam-builder-not-found')).toBeInTheDocument()
  })
})
