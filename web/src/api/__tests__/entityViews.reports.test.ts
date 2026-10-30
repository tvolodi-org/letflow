// @vitest-environment jsdom
/**
 * REQ-634 C1-C6 — reportViewsApi and entitiesApi.aggregateRecords hit exactly the routes of the
 * router tables, with the method, path and body asserted per function.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { reportViewsApi } from '../entityViews'
import { entitiesApi } from '../entities'
import { setToken, clearToken } from '../client'

const originalFetch = window.fetch

function respond(body: unknown, status = 200) {
  return Promise.resolve(
    new Response(status === 204 ? null : JSON.stringify(body), {
      status,
      headers: { 'Content-Type': 'application/json' },
    }),
  )
}

function mockFetch(body: unknown, status = 200) {
  const spy = vi.fn().mockImplementation(() => respond(body, status))
  window.fetch = spy as unknown as typeof window.fetch
  return spy
}

function call(spy: ReturnType<typeof vi.fn>) {
  const [url, init] = spy.mock.calls[0] as [string, RequestInit]
  return { url, method: init.method ?? 'GET', body: init.body ? JSON.parse(init.body as string) : undefined }
}

beforeEach(() => setToken('test-token'))
afterEach(() => {
  window.fetch = originalFetch
  clearToken()
  vi.restoreAllMocks()
})

describe('REQ-634 reportViewsApi', () => {
  it('C1 list -> GET /entity-views?entity_type=, keeps only reports', async () => {
    const spy = mockFetch({
      items: [
        { id: 'a', kind: 'report', name: 'R' },
        { id: 'b', kind: 'list', name: 'L' },
        { id: 'c', name: 'legacy' },
      ],
    })
    const page = await reportViewsApi.list('orders')
    const c = call(spy)
    expect(c.url).toMatch(/\/api\/v1\/entity-views\?entity_type=orders$/)
    expect(c.method).toBe('GET')
    expect(page.items.map((i) => i.id)).toEqual(['a'])
    expect(spy).toHaveBeenCalledTimes(1)
  })

  it('C2 get -> GET /entity-views/:id', async () => {
    const spy = mockFetch({ id: 'a b' })
    await reportViewsApi.get('a b')
    const c = call(spy)
    expect(c.url).toMatch(/\/api\/v1\/entity-views\/a%20b$/)
    expect(c.method).toBe('GET')
  })

  it('C3 create -> POST with kind report, no columns key when absent', async () => {
    const spy = mockFetch({ id: 'a' }, 201)
    await reportViewsApi.create({
      entity_type: 'orders',
      name: 'Totals',
      filter: [],
      group_by: [{ field: 'status' }],
      aggregates: [{ fn: 'sum', field: 'total' }],
    })
    const c = call(spy)
    expect(c.url).toMatch(/\/api\/v1\/entity-views$/)
    expect(c.method).toBe('POST')
    expect(c.body).toEqual({
      entity_type: 'orders',
      name: 'Totals',
      filter: [],
      group_by: [{ field: 'status' }],
      aggregates: [{ fn: 'sum', field: 'total' }],
      kind: 'report',
    })
    expect('columns' in c.body).toBe(false)
  })

  it('C4 update -> PUT /entity-views/:id, body has no kind or entity_type', async () => {
    const spy = mockFetch({ id: 'a' })
    await reportViewsApi.update('a', {
      name: 'Totals',
      filter: [],
      group_by: [],
      aggregates: [{ fn: 'count' }],
    })
    const c = call(spy)
    expect(c.url).toMatch(/\/api\/v1\/entity-views\/a$/)
    expect(c.method).toBe('PUT')
    expect(c.body).toEqual({ name: 'Totals', filter: [], group_by: [], aggregates: [{ fn: 'count' }] })
    expect('kind' in c.body).toBe(false)
    expect('entity_type' in c.body).toBe(false)
  })

  it('C5 remove -> DELETE /entity-views/:id', async () => {
    const spy = mockFetch(null, 204)
    await reportViewsApi.remove('a')
    const c = call(spy)
    expect(c.url).toMatch(/\/api\/v1\/entity-views\/a$/)
    expect(c.method).toBe('DELETE')
  })
})

describe('REQ-634 entitiesApi.aggregateRecords', () => {
  it('C6 -> POST /entities/query/aggregate with entity_type merged into the body', async () => {
    const spy = mockFetch({ results: [] })
    await entitiesApi.aggregateRecords('orders', {
      aggregates: [{ fn: 'count' }],
      group_by: [{ field: 'status' }],
      filters: [],
    })
    const c = call(spy)
    expect(c.url).toMatch(/\/api\/v1\/entities\/query\/aggregate$/)
    expect(c.method).toBe('POST')
    expect(c.body).toEqual({
      entity_type: 'orders',
      aggregates: [{ fn: 'count' }],
      group_by: [{ field: 'status' }],
      filters: [],
    })
  })
})
