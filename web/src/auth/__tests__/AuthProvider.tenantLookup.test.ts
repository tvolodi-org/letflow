// @vitest-environment jsdom
/**
 * Q-1074 / GH 2431 (S1, MAJOR): buildSessionFromToken is the second caller of
 * GET /api/v1/tenants/:slug. That route is TENANTS_MANAGE (platform-only), so
 * every candidate or tenant-user session build got a 403, logged and swallowed.
 *
 * Pinned here, on the same rule as OidcCallbackPage, decided from a mocked GET
 * /me/access (never from the token's role claims):
 *   - a session whose access lacks platform tenant management makes NO
 *     tenants/:slug request; the session's tenant display name is the slug;
 *   - a session whose access grants it still makes the request and uses the record;
 *   - a failed access call counts as no access (no request).
 */

import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('@/api/client', () => ({
  clearToken: vi.fn(),
  setToken: vi.fn(),
  tryRestoreE2eSession: vi.fn(() => null),
}))

vi.mock('@/auth/OidcManager', () => ({
  getOidcManager: vi.fn(async () => ({})),
}))

vi.mock('@/auth/tenantOidcRegistry', () => ({
  attemptSilentSwitch: vi.fn(),
}))

vi.mock('@/api/me', () => ({
  meApi: { getAccessWithToken: vi.fn() },
}))

vi.mock('@/api/tenants', () => ({
  tenantsApi: {
    getBySlug: vi.fn(),
  },
}))

vi.mock('@/auth/tenantConfig', () => ({
  resetTenantConfigCache: vi.fn(),
  resolveRealmFromUrl: vi.fn(() => null),
}))

vi.mock('@/auth/emailFirstFlag', () => ({
  isEmailFirstLoginEnabled: vi.fn(() => false),
}))

vi.mock('@/auth/oidcRedirectArgs', () => ({
  buildRedirectArgs: vi.fn(() => ({})),
}))

import { buildSessionFromToken } from '@/auth/AuthProvider'
import { tenantsApi } from '@/api/tenants'
import { meApi } from '@/api/me'
import { ACCESS_FIXTURES } from '@/auth/access/fixtures'

const SLUG = 'bilimbaga'

function fakeToken(tenantId: string): string {
  const header = { alg: 'none', typ: 'JWT' }
  const payload = { roles: ['claimed'], tenant_id: tenantId, sub: 'user-1', preferred_username: 'tester' }
  const b64 = (obj: unknown) => btoa(JSON.stringify(obj)).replace(/=+$/, '')
  return `${b64(header)}.${b64(payload)}.sig`
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('Q-1074 / GH 2431 — buildSessionFromToken tenant lookup', () => {
  it('candidate access: makes no tenants/:slug request and the display name is the slug', async () => {
    vi.mocked(meApi.getAccessWithToken).mockResolvedValue(ACCESS_FIXTURES.candidate)

    const session = await buildSessionFromToken(fakeToken(SLUG))

    expect(meApi.getAccessWithToken).toHaveBeenCalledOnce()
    expect(tenantsApi.getBySlug).not.toHaveBeenCalled()
    expect(session.tenant_slug).toBe(SLUG)
    expect(session.tenant_display_name).toBe(SLUG)
  })

  it('platform admin access: still looks up the tenant and uses the record', async () => {
    vi.mocked(meApi.getAccessWithToken).mockResolvedValue(ACCESS_FIXTURES.platformAdmin)
    vi.mocked(tenantsApi.getBySlug).mockResolvedValue({
      slug: SLUG,
      display_name: 'Bilimbaga Tenant',
      tenant_id: 't-1',
      tenant_type: 'production',
      production_tenant_display_name: null,
    } as never)

    const session = await buildSessionFromToken(fakeToken(SLUG))

    expect(tenantsApi.getBySlug).toHaveBeenCalledWith(SLUG)
    expect(session.tenant_display_name).toBe('Bilimbaga Tenant')
    expect(session.tenant_id).toBe('t-1')
  })

  it('a failed access call counts as no access: no tenants/:slug request', async () => {
    vi.mocked(meApi.getAccessWithToken).mockRejectedValue({ status: 500 })

    const session = await buildSessionFromToken(fakeToken(SLUG))

    expect(tenantsApi.getBySlug).not.toHaveBeenCalled()
    expect(session.tenant_display_name).toBe(SLUG)
  })
})
