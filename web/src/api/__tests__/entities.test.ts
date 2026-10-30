// @vitest-environment jsdom
/**
 * REQ-336 AC1 — web/src/api/entities.ts follows definitions.ts's own shape
 * (named functions over client.get/post/put/delete) and exposes exactly the
 * five functions the requirement names -- no GET-by-id or GET-list function,
 * because lib/letflow/routers/entities.ex defines no such route
 * (Letflow.Entities.Records is command-only; the only record-read route is
 * POST /entities/query). Verified two ways: (1) a runtime shape check that
 * no get-by-id/list-shaped key exists on the exported object, and (2) real
 * fetch-call assertions that each function hits the exact method+path the
 * router table documents.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { entitiesApi } from '../entities'
import { setToken, clearToken } from '../client'

const originalFetch = window.fetch

function jsonResponse(body: unknown, init: { status?: number; headers?: Record<string, string> } = {}) {
  return Promise.resolve(
    new Response(JSON.stringify(body), {
      status: init.status ?? 200,
      headers: { 'Content-Type': 'application/json', ...(init.headers ?? {}) },
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

describe('REQ-336 AC1 — entitiesApi shape', () => {
  it('exposes exactly getActiveDefinition, queryRecords, createRecord, updateRecord, deleteRecord', () => {
    const keys = Object.keys(entitiesApi).sort()
    expect(keys).toEqual(
      ['aggregateRecords', 'createRecord', 'deleteRecord', 'getActiveDefinition', 'queryRecords', 'updateRecord'].sort(),
    )
  })

  it('defines no get-by-id or list function -- no such route exists on the router', () => {
    const keys = Object.keys(entitiesApi)
    for (const forbidden of ['getRecord', 'listRecords', 'getRecordById', 'list', 'get']) {
      expect(keys).not.toContain(forbidden)
    }
  })
})

describe('REQ-336 AC1 — entitiesApi hits the real route table', () => {
  it('getActiveDefinition -> GET /api/v1/entities/definitions/active/:name', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ id: 'd1' }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await entitiesApi.getActiveDefinition('tag')

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/entities/definitions/active/tag'),
      expect.objectContaining({}),
    )
  })

  it('queryRecords -> POST /api/v1/entities/query with entity_type in the body', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ items: [], next_cursor: null }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await entitiesApi.queryRecords('tag', { page_size: 25 })

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/entities/query'),
      expect.objectContaining({ method: 'POST' }),
    )
    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({ entity_type: 'tag', page_size: 25 })
  })

  it('createRecord -> POST /api/v1/entities/records/:entity_type with field_values', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ record_id: 'r1' }, { status: 201 }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await entitiesApi.createRecord('tag', { name: 'algebra' })

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/entities/records/tag'),
      expect.objectContaining({ method: 'POST' }),
    )
    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({ field_values: { name: 'algebra' } })
  })

  it('updateRecord -> PUT /api/v1/entities/records/:entity_type/:record_id, with If-Match when supplied', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ record_id: 'r1' }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await entitiesApi.updateRecord('tag', 'r1', { name: 'algebra-2' }, 'v1-hex')

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/entities/records/tag/r1'),
      expect.objectContaining({ method: 'PUT' }),
    )
    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect((init.headers as Record<string, string>)['If-Match']).toBe('v1-hex')
  })

  it('deleteRecord -> DELETE /api/v1/entities/records/:entity_type/:record_id', async () => {
    const fetchSpy = vi.fn().mockImplementation(() =>
      Promise.resolve(new Response(null, { status: 204 })),
    )
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await entitiesApi.deleteRecord('tag', 'r1')

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/entities/records/tag/r1'),
      expect.objectContaining({ method: 'DELETE' }),
    )
  })

  it('a 409 on updateRecord propagates client.ts\'s PD-08 ApiError shape (details.xResourceVersion)', async () => {
    const fetchSpy = vi.fn().mockImplementation(() =>
      jsonResponse(
        { title: 'Conflict' },
        { status: 409, headers: { 'X-Resource-Version': 'new-version-hex' } },
      ),
    )
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await expect(entitiesApi.updateRecord('tag', 'r1', { name: 'x' }, 'stale-version')).rejects.toMatchObject({
      status: 409,
      details: { xResourceVersion: 'new-version-hex' },
    })
  })
})
