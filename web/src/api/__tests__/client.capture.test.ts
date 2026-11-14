// @vitest-environment jsdom
/** W4b-W4g (T-1950): authedFetch and throwOnErrorResponse feed the problem-report request ring. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('@/auth/sessionRenewal', () => ({ renewSession: vi.fn() }))

import { client, clearToken, setToken } from '../client'
import { renewSession } from '@/auth/sessionRenewal'
import { resetCapture, snapshot } from '@/lib/problemReport/capture'

const TASK = '/api/v1/tasks/0b9f8e7a-1111-4222-8333-444455556666'
const json = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers })

beforeEach(() => {
  resetCapture()
  clearToken()
})
afterEach(() => {
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

describe('request ring from the client (W4b-W4g)', () => {
  it('W4b: a 500 records path pattern, header trace id and body error code', async () => {
    window.fetch = vi.fn().mockResolvedValue(json(500, { type: 'stale_thing', title: 'x', trace_id: 'tb1' }, { 'x-trace-id': 'th1' }))
    await expect(client.get(TASK)).rejects.toMatchObject({ status: 500 })
    const last = snapshot().requests.at(-1)
    expect(last).toMatchObject({ method: 'GET', path: '/api/v1/tasks/:id', status: 500, trace_id: 'th1', error_code: 'stale_thing' })
  })

  it('W4c: a network failure records status 0 and the caller still gets the error', async () => {
    window.fetch = vi.fn().mockRejectedValue(new TypeError('Failed to fetch'))
    await expect(client.get('/api/v1/x')).rejects.toBeInstanceOf(TypeError)
    expect(snapshot().requests.at(-1)).toMatchObject({ path: '/api/v1/x', status: 0 })
  })

  it('W4d: a mock without headers does not break the request', async () => {
    window.fetch = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({ a: 1 }) })
    await expect(client.get('/api/v1/x')).resolves.toEqual({ a: 1 })
    expect(snapshot().requests.at(-1)).toMatchObject({ status: 200 })
  })

  it('W4e: the report route is not recorded', async () => {
    window.fetch = vi.fn().mockResolvedValue(json(201, { id: '1', number: 'SR-1', received_at: 'x' }))
    await client.post('/api/v1/me/problem-reports', { text: 'x' })
    expect(snapshot().requests).toHaveLength(0)
  })

  it('W4g: a 401 replayed to 200 records one entry with status 200', async () => {
    setToken('t1')
    vi.mocked(renewSession).mockImplementation(async () => {
      setToken('t2')
      return { kind: 'renewed' } as never
    })
    window.fetch = vi.fn().mockResolvedValueOnce(json(401, {})).mockResolvedValueOnce(json(200, { ok: 1 }))
    await client.get('/api/v1/y')
    const r = snapshot().requests
    expect(r).toHaveLength(1)
    expect(r[0].status).toBe(200)
  })
})
