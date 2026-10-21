// @vitest-environment jsdom
/**
 * REQ-470 / GH 2478: OidcCallbackPage takes tenant_type from the public
 * tenant-config for every login (not from the platform-only tenants record).
 */

import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

const mockSetSession = vi.fn()
const mockGetAccess = vi.fn()
const mockSigninRedirectCallback = vi.fn()

vi.mock('react-router-dom', () => ({ useNavigate: () => vi.fn() }))
vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ setSession: mockSetSession }) }))
vi.mock('@/auth/OidcManager', () => ({
  getOidcManager: vi.fn(async () => ({ signinRedirectCallback: mockSigninRedirectCallback })),
  oidcManager: { signinSilentCallback: vi.fn() },
}))
vi.mock('@/api/client', () => ({ setToken: vi.fn() }))
vi.mock('@/auth/tenantConfig', () => ({
  resolveRealmFromUrl: vi.fn(() => null),
  fetchTenantConfigForSlug: vi.fn(),
}))
vi.mock('@/api/me', () => ({
  meApi: { getAccessWithToken: (...args: unknown[]) => mockGetAccess(...args) },
}))
vi.mock('@/api/tenants', () => ({ tenantsApi: { getBySlug: vi.fn() } }))

import { tenantsApi } from '@/api/tenants'
import { fetchTenantConfigForSlug, resolveRealmFromUrl } from '@/auth/tenantConfig'
import { ACCESS_FIXTURES } from '@/auth/access/fixtures'

const SLUG = 'zeta-test'

function fakeToken(): string {
  const b64 = (obj: unknown) => btoa(JSON.stringify(obj)).replace(/=+$/, '')
  return `${b64({ alg: 'none', typ: 'JWT' })}.${b64({ roles: ['claimed'], sub: 'u-1', preferred_username: 'tester' })}.sig`
}

const config = (extra: Record<string, unknown>) =>
  ({ oidc_authority: 'http://idp', client_id: 'web', ...extra }) as never

async function login(access: unknown) {
  vi.resetModules()
  mockGetAccess.mockResolvedValue(access)
  mockSigninRedirectCallback.mockResolvedValue({ access_token: fakeToken() })
  const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
  render(<OidcCallbackPage />)
  await waitFor(() => expect(mockSetSession).toHaveBeenCalledTimes(1))
  return mockSetSession.mock.calls[0][0]
}

beforeEach(() => {
  vi.mocked(resolveRealmFromUrl).mockReturnValue(SLUG)
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.mocked(resolveRealmFromUrl).mockReturnValue(null)
})

describe('REQ-470 — OidcCallbackPage tenant_type from tenant-config', () => {
  it.each([
    ['tenantAdmin', ACCESS_FIXTURES.tenantAdmin],
    ['taskWorker', ACCESS_FIXTURES.taskWorker],
  ])('%s login: tenant_type test lands in the session, no tenants request', async (_role, access) => {
    vi.mocked(fetchTenantConfigForSlug).mockResolvedValue(config({ tenant_type: 'test' }))

    const session = await login(access)

    expect(tenantsApi.getBySlug).not.toHaveBeenCalled()
    expect(session.tenant_type).toBe('test')
  })

  it('a tenant-config response without the key leaves tenant_type null', async () => {
    vi.mocked(fetchTenantConfigForSlug).mockResolvedValue(config({}))

    expect((await login(ACCESS_FIXTURES.tenantAdmin)).tenant_type).toBeNull()
  })
})
