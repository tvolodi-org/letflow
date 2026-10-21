// @vitest-environment jsdom
/**
 * REQ-470 / GH 2478: buildSessionFromToken takes tenant_type from the public
 * tenant-config for every session, not from the platform-only tenants record.
 */

import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('@/api/client', () => ({
  clearToken: vi.fn(),
  setToken: vi.fn(),
  tryRestoreE2eSession: vi.fn(() => null),
}))
vi.mock('@/auth/OidcManager', () => ({ getOidcManager: vi.fn(async () => ({})) }))
vi.mock('@/auth/tenantOidcRegistry', () => ({ attemptSilentSwitch: vi.fn() }))
vi.mock('@/api/me', () => ({ meApi: { getAccessWithToken: vi.fn() } }))
vi.mock('@/api/tenants', () => ({ tenantsApi: { getBySlug: vi.fn() } }))
vi.mock('@/auth/tenantConfig', () => ({
  resetTenantConfigCache: vi.fn(),
  resolveRealmFromUrl: vi.fn(() => null),
  fetchTenantConfigForSlug: vi.fn(),
}))
vi.mock('@/auth/emailFirstFlag', () => ({ isEmailFirstLoginEnabled: vi.fn(() => false) }))
vi.mock('@/auth/oidcRedirectArgs', () => ({ buildRedirectArgs: vi.fn(() => ({})) }))

import { buildSessionFromToken } from '@/auth/AuthProvider'
import { tenantsApi } from '@/api/tenants'
import { meApi } from '@/api/me'
import { fetchTenantConfigForSlug } from '@/auth/tenantConfig'
import { ACCESS_FIXTURES } from '@/auth/access/fixtures'

const SLUG = 'acme-test'

function fakeToken(): string {
  const b64 = (obj: unknown) => btoa(JSON.stringify(obj)).replace(/=+$/, '')
  return `${b64({ alg: 'none', typ: 'JWT' })}.${b64({ roles: ['claimed'], tenant_id: SLUG, sub: 'u-1', preferred_username: 'tester' })}.sig`
}

const config = (extra: Record<string, unknown>) =>
  ({ oidc_authority: 'http://idp', client_id: 'web', ...extra }) as never

beforeEach(() => {
  vi.clearAllMocks()
})

describe('REQ-470 — buildSessionFromToken tenant_type from tenant-config', () => {
  it.each([
    ['tenantAdmin', ACCESS_FIXTURES.tenantAdmin],
    ['taskWorker', ACCESS_FIXTURES.taskWorker],
  ])('%s session: tenant_type test from tenant-config lands in the session, no tenants request', async (_n, access) => {
    vi.mocked(meApi.getAccessWithToken).mockResolvedValue(access)
    vi.mocked(fetchTenantConfigForSlug).mockResolvedValue(config({ tenant_type: 'test' }))

    const session = await buildSessionFromToken(fakeToken())

    expect(fetchTenantConfigForSlug).toHaveBeenCalledWith(SLUG)
    expect(tenantsApi.getBySlug).not.toHaveBeenCalled()
    expect(session.tenant_type).toBe('test')
  })

  it('a tenant-config response without the key leaves tenant_type null', async () => {
    vi.mocked(meApi.getAccessWithToken).mockResolvedValue(ACCESS_FIXTURES.tenantAdmin)
    vi.mocked(fetchTenantConfigForSlug).mockResolvedValue(config({}))

    expect((await buildSessionFromToken(fakeToken())).tenant_type).toBeNull()
  })

  it('a failed tenant-config lookup leaves tenant_type null and the session is still built', async () => {
    vi.mocked(meApi.getAccessWithToken).mockResolvedValue(ACCESS_FIXTURES.taskWorker)
    vi.mocked(fetchTenantConfigForSlug).mockRejectedValue(new Error('boom'))

    const session = await buildSessionFromToken(fakeToken())

    expect(session.tenant_type).toBeNull()
    expect(session.tenant_slug).toBe(SLUG)
  })

  it('platform admin: tenant_type still comes from tenant-config, not the tenants record', async () => {
    vi.mocked(meApi.getAccessWithToken).mockResolvedValue(ACCESS_FIXTURES.platformAdmin)
    vi.mocked(tenantsApi.getBySlug).mockResolvedValue({ slug: SLUG, display_name: 'Acme', tenant_id: 't-1', tenant_type: 'production' } as never)
    vi.mocked(fetchTenantConfigForSlug).mockResolvedValue(config({ tenant_type: 'test' }))

    const session = await buildSessionFromToken(fakeToken())

    expect(session.tenant_type).toBe('test')
    expect(session.tenant_display_name).toBe('Acme')
  })
})
