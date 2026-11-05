// @vitest-environment jsdom
/** T-1400: a 401 renews the session once and replays the request once. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { client, setToken, clearToken, getToken, _resetSessionExpiredDedupe } from '../client'
import { registerRenewer } from '@/auth/sessionRenewal'
import type { RenewOutcome } from '@/auth/sessionRenewal'

const json = (status: number, body: unknown = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

let fetchMock: ReturnType<typeof vi.fn>
let off: (() => void) | null = null
const events: CustomEvent[] = []
const onExpired = (e: Event) => events.push(e as CustomEvent)

function renewer(outcome: RenewOutcome, newToken?: string) {
  const fn = vi.fn(async () => {
    if (newToken) setToken(newToken)
    return outcome
  })
  off = registerRenewer(fn)
  return fn
}

beforeEach(() => {
  events.length = 0
  _resetSessionExpiredDedupe()
  fetchMock = vi.fn()
  vi.stubGlobal('fetch', fetchMock)
  window.fetch = fetchMock as unknown as typeof window.fetch
  window.addEventListener('auth:session-expired', onExpired)
  setToken('old')
})
afterEach(() => {
  off?.()
  off = null
  clearToken()
  window.removeEventListener('auth:session-expired', onExpired)
  vi.unstubAllGlobals()
})

const authOf = (call: number) => (fetchMock.mock.calls[call][1].headers as Record<string, string>).Authorization

describe('client 401 refresh and replay', () => {
  it('CL-01: one 401 renews, replays with the new token, no event', async () => {
    fetchMock.mockResolvedValueOnce(json(401)).mockResolvedValueOnce(json(200, { ok: 1 }))
    const r = renewer({ kind: 'ok', token: 'new' }, 'new')
    await expect(client.get('/api/x')).resolves.toEqual({ ok: 1 })
    expect(r).toHaveBeenCalledTimes(1)
    expect(authOf(0)).toBe('Bearer old')
    expect(authOf(1)).toBe('Bearer new')
    expect(events).toHaveLength(0)
  })

  it('CL-02: the replay is still 401: one event, replay_unauthorized', async () => {
    fetchMock.mockResolvedValue(json(401))
    renewer({ kind: 'ok', token: 'new' }, 'new')
    await expect(client.get('/api/x')).rejects.toMatchObject({ status: 401 })
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(events).toHaveLength(1)
    expect(events[0].detail).toEqual({ reason: 'replay_unauthorized' })
  })

  it('CL-03: terminal refresh raises refresh_failed', async () => {
    fetchMock.mockResolvedValue(json(401))
    renewer({ kind: 'terminal' })
    await expect(client.get('/api/x')).rejects.toMatchObject({ status: 401 })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(events.map(e => e.detail)).toEqual([{ reason: 'refresh_failed' }])
  })

  it('CL-04: transient refresh: the 401 error, no event', async () => {
    fetchMock.mockResolvedValue(json(401))
    renewer({ kind: 'transient' })
    await expect(client.get('/api/x')).rejects.toMatchObject({ status: 401 })
    expect(events).toHaveLength(0)
  })

  it('CL-05: no token sent: no renewal and no event', async () => {
    clearToken()
    fetchMock.mockResolvedValue(json(401))
    const r = renewer({ kind: 'terminal' })
    await expect(client.get('/api/x')).rejects.toMatchObject({ status: 401 })
    expect(r).not.toHaveBeenCalled()
    expect(events).toHaveLength(0)
  })

  it('CL-06: an explicit-token call never renews or raises the event', async () => {
    fetchMock.mockResolvedValue(json(401))
    const r = renewer({ kind: 'terminal' })
    await expect(client.getWithToken('/api/x', 'other')).rejects.toMatchObject({ status: 401 })
    expect(r).not.toHaveBeenCalled()
    expect(events).toHaveLength(0)
  })

  it('CL-07: JSON and FormData bodies are replayed intact; 5 parallel 401s: one renew, one event', async () => {
    fetchMock.mockResolvedValueOnce(json(401)).mockResolvedValueOnce(json(200))
    renewer({ kind: 'ok', token: 'new' }, 'new')
    const fd = new FormData()
    fd.append('a', 'b')
    await client.post('/api/x', { k: 1 })
    expect(fetchMock.mock.calls[0][1].body).toBe(fetchMock.mock.calls[1][1].body)
    expect(fetchMock.mock.calls[1][1].body).toBe('{"k":1}')

    fetchMock.mockReset()
    setToken('old')
    fetchMock.mockResolvedValueOnce(json(401)).mockResolvedValueOnce(json(200))
    await client.post('/api/x', fd)
    expect(fetchMock.mock.calls[1][1].body).toBe(fd)

    off?.()
    fetchMock.mockReset()
    fetchMock.mockResolvedValue(json(401))
    setToken('old')
    const slow = vi.fn(async (): Promise<RenewOutcome> => {
      await new Promise(res => setTimeout(res, 20))
      return { kind: 'terminal' }
    })
    off = registerRenewer(slow)
    const results = await Promise.allSettled([1, 2, 3, 4, 5].map(() => client.get('/api/x')))
    expect(results.every(x => x.status === 'rejected')).toBe(true)
    expect(slow).toHaveBeenCalledTimes(1)
    expect(events).toHaveLength(1)
  })

  it('CL-08: the token changed meanwhile: replay with it, no second renew', async () => {
    fetchMock
      .mockImplementationOnce(async () => {
        setToken('fresh') // a concurrent renewal lands while this request is in flight
        return json(401)
      })
      .mockResolvedValueOnce(json(200, { ok: 1 }))
    const r = renewer({ kind: 'terminal' })
    await expect(client.get('/api/x')).resolves.toEqual({ ok: 1 })
    expect(r).not.toHaveBeenCalled()
    expect(authOf(1)).toBe('Bearer fresh')
    expect(getToken()).toBe('fresh')
  })
})
