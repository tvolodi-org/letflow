// @vitest-environment jsdom
/**
 * T-1400 MG-03: on /auth/callback OidcCallbackPage and AuthProvider both ask for the OIDC
 * manager while the tenant-config request is pending. The manager that RECEIVES the token
 * (signinRedirectCallback) must be the one AuthProvider hangs the expiry/renewal handler on.
 * Uses the REAL getOidcManager and a real UserManager; only the config request is deferred.
 */
import { cleanup, render, waitFor, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { User, UserManager } from 'oidc-client-ts'
import { afterEach, describe, expect, it, vi } from 'vitest'

const { cfg } = vi.hoisted(() => {
  const cfg = { resolve: (() => {}) as (v: unknown) => void, promise: null as unknown as Promise<unknown> }
  cfg.promise = new Promise(r => (cfg.resolve = r))
  return { cfg }
})

vi.mock('react-router-dom', () => ({ useNavigate: () => vi.fn() }))
vi.mock('@/api/client', () => ({
  setToken: vi.fn(),
  clearToken: vi.fn(),
  tryRestoreE2eSession: vi.fn(() => null),
}))
vi.mock('@/auth/tenantConfig', () => ({
  fetchTenantConfig: vi.fn(() => cfg.promise),
  isTenantConfigCached: () => true,
  resolveRealmFromUrl: () => null,
  resetTenantConfigCache: vi.fn(),
}))
vi.mock('@/api/me', () => ({
  meApi: { getAccessWithToken: vi.fn(async () => ({ roles: [], permissions: [], platform_tenant: false })) },
}))
vi.mock('@/api/tenants', () => ({ tenantsApi: { getBySlug: vi.fn() } }))
vi.mock('@/auth/tenantType', () => ({ fetchTenantTypeForSlug: vi.fn(async () => 'production') }))
vi.mock('@/auth/tenantOidcRegistry', () => ({
  attemptSilentSwitch: vi.fn(),
  getOrCreateManagerForTenant: vi.fn(),
}))

import OidcCallbackPage from '../OidcCallbackPage'
import { AuthProvider } from '@/auth/AuthProvider'

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('callback page + AuthProvider share one OIDC manager', () => {
  it('MG-03: the manager that got the token is the one with the expiring handler', async () => {
    // header.payload.sig with roles, so the page proceeds past its token check
    const payload = btoa(JSON.stringify({ roles: ['T_ADMIN'], sub: 'u1' }))
    const token = `eyJhbGciOiJub25lIn0.${payload}.sig`
    const user = new User({
      access_token: token,
      token_type: 'Bearer',
      refresh_token: 'r',
      expires_at: Math.floor(Date.now() / 1000) + 300,
      profile: {} as never,
    })
    const callbackSpy = vi.spyOn(UserManager.prototype, 'signinRedirectCallback').mockResolvedValue(user)
    const eventsProto = Object.getPrototypeOf(new UserManager({ authority: 'http://x/r', client_id: 'c', redirect_uri: 'http://x/cb' }).events)
    const addSpy = vi.spyOn(eventsProto, 'addAccessTokenExpiring')

    const qc = new QueryClient()
    render(
      <QueryClientProvider client={qc}>
        <AuthProvider>
          <OidcCallbackPage />
        </AuthProvider>
      </QueryClientProvider>,
    )
    await act(async () => {
      cfg.resolve({ oidc_authority: 'http://idp.test/realms/r', client_id: 'c' })
    })
    await waitFor(() => expect(callbackSpy).toHaveBeenCalled())
    await waitFor(() => expect(addSpy).toHaveBeenCalled())

    const receiver = callbackSpy.mock.contexts[0] as UserManager
    expect(addSpy.mock.contexts[0]).toBe(receiver.events)
  })
})
