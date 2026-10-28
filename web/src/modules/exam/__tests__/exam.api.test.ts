// @vitest-environment jsdom
/**
 * REQ-338 AC1 — exam.api.ts exposes the five named operations
 * (startSession, saveAnswer, submitSession, getSessionState, reportEvent)
 * and each hits REQ-335's real route remounted under REQ-410's module path
 * (lib/letflow/routers/exam_sessions.ex's own "Route table"):
 *
 *   POST   /api/v1/modules/exam/exam-sessions
 *   GET    /api/v1/modules/exam/exam-sessions/:id
 *   PUT    /api/v1/modules/exam/exam-sessions/:id/answers/:question_id
 *   POST   /api/v1/modules/exam/exam-sessions/:id/submit
 *   POST   /api/v1/modules/exam/exam-sessions/:id/events
 *
 * Plus `listAvailableExams` (ISS-0718), which replaced this file's original
 * `queryExamRecords` wrapper around the generic `POST /entities/query` route:
 * candidate role cannot reach that route (`:EntitiesQuery` is outside candidate role's
 * ISS-0646 closed permission set), so the exam list screen now calls the
 * dedicated `GET /modules/exam/exam-sessions/available` route instead; see
 * exam.api.ts's own moduledoc comment.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { examApi, examAuthoringApi } from '../exam.api'
import { setToken, clearToken } from '@/api/client'

const originalFetch = window.fetch

function jsonResponse(body: unknown, init: { status?: number } = {}) {
  return Promise.resolve(
    new Response(JSON.stringify(body), {
      status: init.status ?? 200,
      headers: { 'Content-Type': 'application/json' },
    }),
  )
}

beforeEach(() => {
  setToken('test-token')
})

afterEach(() => {
  window.fetch = originalFetch
  clearToken()
  vi.restoreAllMocks()
})

describe('REQ-338 AC1 — examApi shape', () => {
  it('exposes exactly the five named session operations plus the list and certificate operations', () => {
    const keys = Object.keys(examApi).sort()
    expect(keys).toEqual(
      [
        'startSession',
        'getSessionState',
        'saveAnswer',
        'submitSession',
        'reportEvent',
        'listAvailableExams',
        'listMySessions',
        'downloadCertificate',
      ].sort(),
    )
  })
})

describe('REQ-338 AC1 — examApi hits REQ-335s real route table', () => {
  it('startSession -> POST /api/v1/modules/exam/exam-sessions with exam_id in the body', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ session: {}, remaining_seconds: 0, questions: [], answers: {} }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.startSession('exam-1')

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/modules/exam/exam-sessions'),
      expect.objectContaining({ method: 'POST' }),
    )
    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({ exam_id: 'exam-1' })
  })

  it('getSessionState -> GET /api/v1/modules/exam/exam-sessions/:id', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ session: {}, remaining_seconds: 0, questions: [], answers: {} }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.getSessionState('session-1')

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/modules/exam/exam-sessions/session-1'),
      expect.objectContaining({}),
    )
  })

  it('saveAnswer -> PUT /api/v1/modules/exam/exam-sessions/:id/answers/:question_id', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ remaining_seconds: 42 }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.saveAnswer('session-1', 'question-1', { selected_option_ids: ['opt-1'], time_spent_seconds: 5 })

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/modules/exam/exam-sessions/session-1/answers/question-1'),
      expect.objectContaining({ method: 'PUT' }),
    )
    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({ selected_option_ids: ['opt-1'], time_spent_seconds: 5 })
  })

  it('saveAnswer -> ISS-0650: carries text_answer in the body when supplied', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ remaining_seconds: 42 }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.saveAnswer('session-1', 'question-1', {
      selected_option_ids: [],
      time_spent_seconds: 5,
      text_answer: 'Paris',
    })

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({
      selected_option_ids: [],
      time_spent_seconds: 5,
      text_answer: 'Paris',
    })
  })

  it('submitSession -> POST /api/v1/modules/exam/exam-sessions/:id/submit', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ status: 'submitted', total_score: 1, total_max_score: 1, percentage: 100, passed: true }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.submitSession('session-1')

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/modules/exam/exam-sessions/session-1/submit'),
      expect.objectContaining({ method: 'POST' }),
    )
  })

  it('reportEvent -> POST /api/v1/modules/exam/exam-sessions/:id/events with type in the body', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ action_taken: 'log', event_count: 1, warning: false, submission: null }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.reportEvent('session-1', 'tab_switch')

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/modules/exam/exam-sessions/session-1/events'),
      expect.objectContaining({ method: 'POST' }),
    )
    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({ type: 'tab_switch' })
  })
})

/** GH 2680 / REQ-510 slice 2 — the authoring write client (examAuthoringApi) hits the exam
 *  module's authoring routes with the generic record routes' bodies. */
describe('GH 2680 — examAuthoringApi hits /modules/exam/authoring', () => {
  it('createRecord -> POST /api/v1/modules/exam/authoring/:entity_type with field_values in the body', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ record_id: 'r1' }, { status: 201 }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examAuthoringApi.createRecord('tag', { name: 'algebra' })

    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/modules/exam/authoring/tag')
    expect(url).not.toContain('/entities/')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({ field_values: { name: 'algebra' } })
  })

  it('updateRecord -> PUT /api/v1/modules/exam/authoring/:entity_type/:record_id with field_values, and sends If-Match as updateRecord does', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ record_id: 'r1' }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examAuthoringApi.updateRecord('exam', 'r1', { title: { en: 'Final' } }, 'v1-hex')

    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/modules/exam/authoring/exam/r1')
    expect(init.method).toBe('PUT')
    expect(JSON.parse(init.body as string)).toEqual({ field_values: { title: { en: 'Final' } } })
    expect(new Headers(init.headers).get('If-Match')).toBe('v1-hex')
  })

  it('updateRecord without ifMatch sends no If-Match header', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ record_id: 'r1' }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examAuthoringApi.updateRecord('tag', 'r1', { name: 'x' })

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(new Headers(init.headers).get('If-Match')).toBeNull()
  })

  it('deleteRecord -> DELETE /api/v1/modules/exam/authoring/:entity_type/:record_id, bodyless', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ record_id: 'r1', deleted: true }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examAuthoringApi.deleteRecord('question', 'r1')

    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/modules/exam/authoring/question/r1')
    expect(init.method).toBe('DELETE')
    expect(init.body).toBeUndefined()
  })

  it('a stale If-Match 409 from the authoring PUT rejects with the same ApiError status the generic route gives', async () => {
    window.fetch = vi.fn().mockImplementation(() =>
      jsonResponse({ title: 'Conflict', type: 'stale_version' }, { status: 409 }),
    ) as unknown as typeof window.fetch

    await expect(examAuthoringApi.updateRecord('tag', 'r1', { name: 'x' }, 'stale')).rejects.toMatchObject({ status: 409 })
  })

  it('a 403 from the authoring routes keeps the restricted-field detail the page maps', async () => {
    const detail = 'one or more requested fields are restricted for this caller'
    window.fetch = vi.fn().mockImplementation(() =>
      jsonResponse({ detail, status: 403 }, { status: 403 }),
    ) as unknown as typeof window.fetch

    await expect(examAuthoringApi.createRecord('tag', { name: 'x' })).rejects.toMatchObject({
      status: 403,
      details: { detail },
    })
  })

  it('a 404 from the authoring routes rejects with status 404', async () => {
    window.fetch = vi.fn().mockImplementation(() =>
      jsonResponse({ title: 'Not Found', status: 404 }, { status: 404 }),
    ) as unknown as typeof window.fetch

    await expect(examAuthoringApi.deleteRecord('tag', 'missing')).rejects.toMatchObject({ status: 404 })
  })
})

describe('GH GH 3321 / REQ-587 — listMySessions and downloadCertificate', () => {
  it('listMySessions -> GET /exam-sessions/mine with cursor, page_size and exam_id only', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ items: [], next_cursor: null }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.listMySessions({ cursor: 'c1', page_size: 20, exam_id: 'e1' })

    const [url] = fetchSpy.mock.calls[0] as [string]
    const parsed = new URL(url, 'http://x')
    expect(parsed.pathname).toBe('/api/v1/modules/exam/exam-sessions/mine')
    expect([...parsed.searchParams.keys()].sort()).toEqual(['cursor', 'exam_id', 'page_size'])
    expect(parsed.searchParams.get('cursor')).toBe('c1')
  })

  it('downloadCertificate -> GET /exam-sessions/:id/certificate/download as a blob', async () => {
    const fetchSpy = vi
      .fn()
      .mockImplementation(() =>
        Promise.resolve(new Response('%PDF', { status: 200, headers: { 'Content-Type': 'application/pdf' } })),
      )
    window.fetch = fetchSpy as unknown as typeof window.fetch

    const { contentType } = await examApi.downloadCertificate('s-1')

    expect(contentType).toBe('application/pdf')
    expect((fetchSpy.mock.calls[0] as [string])[0]).toContain(
      '/api/v1/modules/exam/exam-sessions/s-1/certificate/download',
    )
  })
})
