// @vitest-environment jsdom
/** T-1657 / REQ-789: the client posts an empty body to the reset route and no longer has the password-taking function. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { usersApi } from '../identity'
import { clearToken, setToken } from '../client'

const originalFetch = window.fetch

beforeEach(() => setToken('test-token'))
afterEach(() => {
  window.fetch = originalFetch
  clearToken()
  vi.restoreAllMocks()
})

describe('T-1657 usersApi.sendPasswordResetInstructions', () => {
  it('A1 posts {} to /api/v1/identity/users/:id/reset-password', async () => {
    const fetchSpy = vi.fn().mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify({ status: 'requested' }), { status: 202, headers: { 'Content-Type': 'application/json' } })),
    )
    window.fetch = fetchSpy as unknown as typeof window.fetch
    await usersApi.sendPasswordResetInstructions('u-1')
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/identity/users/u-1/reset-password')
    expect(init.method).toBe('POST')
    expect(JSON.parse(String(init.body))).toEqual({})
  })

  it('A2 usersApi has no resetPassword', () => {
    expect('resetPassword' in usersApi).toBe(false)
  })
})
