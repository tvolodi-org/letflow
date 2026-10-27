// @vitest-environment jsdom
/**
 * T-0747: the access token (300 s) is renewed before it expires, with no page
 * navigation. Uses a REAL oidc-client-ts UserManager (the one the callback
 * stores the user in) and a fake clock; only the token endpoint (fetch) is faked.
 *
 * TR-01: with a 300 s token a refresh_token request is made before 300 s.
 * TR-02: a renewal that fails does not redirect; the next 401 event does.
 */

import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, act } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { User, UserManager } from 'oidc-client-ts'
expect.extend(jestDomMatchers)

const { mockSetToken, holder } = vi.hoisted(() => ({
  mockSetToken: vi.fn(),
  holder: { manager: null as unknown },
}))

vi.mock('@/api/client', () => ({
  clearToken: vi.fn(),
  setToken: mockSetToken,
  tryRestoreE2eSession: vi.fn(() => null),
}))

vi.mock('../OidcManager', async importOriginal => {
  const actual = await importOriginal<typeof import('../OidcManager')>()
  return { ...actual, getOidcManager: vi.fn(async () => holder.manager) }
})

import { AuthProvider } from '../AuthProvider'
import { buildOidcSettings } from '../OidcManager'

const AUTHORITY = 'http://idp.test/realms/r'
const NOW_S = 1_800_000_000

function tokenResponse(access: string) {
  return new Response(
    JSON.stringify({ access_token: access, token_type: 'Bearer', expires_in: 300, refresh_token: 'r2' }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  )
}

async function setup(fetchImpl: (url: string, init?: RequestInit) => Promise<Response>) {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'Date'] })
  vi.setSystemTime(NOW_S * 1000)
  const fetchMock = vi.fn(fetchImpl)
  vi.stubGlobal('fetch', fetchMock)
  const manager = new UserManager(buildOidcSettings(AUTHORITY, 'letflow-web'))
  holder.manager = manager
  // what signinRedirectCallback leaves behind: user in the store, timers loaded
  const user = new User({
      access_token: 'a1',
      token_type: 'Bearer',
      refresh_token: 'r1',
      expires_at: NOW_S + 300,
      profile: {} as never,
  })
  await manager.storeUser(user)
  manager.events.load(user) // signinRedirectCallback does both
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={qc}>
      <AuthProvider>{null}</AuthProvider>
    </QueryClientProvider>,
  )
  await act(async () => {
    await vi.advanceTimersByTimeAsync(0)
  })
  return { fetchMock }
}

beforeEach(() => {
  mockSetToken.mockClear()
})

afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('AuthProvider token renewal', () => {
  it('TR-01: renews with the refresh token before a 300 s token expires', async () => {
    const { fetchMock } = await setup(async () => tokenResponse('a2'))
    const onExpired = vi.fn()
    window.addEventListener('auth:session-expired', onExpired)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(299_000)
    })

    const tokenCalls = fetchMock.mock.calls.filter(([u]) => String(u).endsWith('/token'))
    expect(tokenCalls).toHaveLength(1)
    expect(String(tokenCalls[0][1]?.body)).toContain('grant_type=refresh_token')
    expect(mockSetToken).toHaveBeenCalledWith('a2')
    expect(onExpired).not.toHaveBeenCalled()
    window.removeEventListener('auth:session-expired', onExpired)
  })

  it('TR-02: a failed renewal does not redirect by itself', async () => {
    const { fetchMock } = await setup(async () => new Response('{"error":"invalid_grant"}', { status: 400 }))
    const onExpired = vi.fn()
    window.addEventListener('auth:session-expired', onExpired)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(299_000)
    })

    expect(fetchMock.mock.calls.some(([u]) => String(u).endsWith('/token'))).toBe(true)
    expect(onExpired).not.toHaveBeenCalled()
    window.removeEventListener('auth:session-expired', onExpired)
  })
})
