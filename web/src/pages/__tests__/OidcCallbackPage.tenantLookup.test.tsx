// @vitest-environment jsdom
/**
 * Q-1074 / GH 2431 (S1, MAJOR): a non-platform login must not call
 * GET /api/v1/tenants/:slug. That route is gated by TENANTS_MANAGE (a
 * PLATFORM_ADMIN permission), so every candidate or tenant-user login got a
 * 403 on it, swallowed by the page's catch.
 *
 * Pinned here:
 *   - a candidate login makes NO tenants/:slug request, and the session's
 *     tenant display name is the slug (the header then shows the slug);
 *   - a PLATFORM_ADMIN login still makes the request and uses the record.
 *
 * "Platform" is decided from the roles already in the decoded token, the same
 * `roles.includes('PLATFORM_ADMIN')` check the page uses for its redirect. The
 * backend still enforces the real permission; this only decides whether to
 * ask.
 */

import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

const mockNavigate = vi.fn()
const mockSetSession = vi.fn()
const mockSigninRedirectCallback = vi.fn()

vi.mock('react-router-dom', () => ({
  useNavigate: () => mockNavigate,
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ setSession: mockSetSession }),
}))

vi.mock('@/auth/OidcManager', () => ({
  getOidcManager: vi.fn(async () => ({
    signinRedirectCallback: mockSigninRedirectCallback,
  })),
  oidcManager: {
    signinSilentCallback: vi.fn(),
  },
}))

vi.mock('@/api/client', () => ({
  setToken: vi.fn(),
}))

vi.mock('@/auth/tenantConfig', () => ({
  resolveRealmFromUrl: vi.fn(() => null),
}))

vi.mock('@/api/tenants', () => ({
  tenantsApi: {
    getBySlug: vi.fn(),
  },
}))

import { tenantsApi } from '@/api/tenants'
import { resolveRealmFromUrl } from '@/auth/tenantConfig'

function fakeToken(roles: string[]): string {
  const header = { alg: 'none', typ: 'JWT' }
  const payload = { roles, sub: 'user-1', preferred_username: 'tester' }
  const b64 = (obj: unknown) => btoa(JSON.stringify(obj)).replace(/=+$/, '')
  return `${b64(header)}.${b64(payload)}.sig`
}

const SLUG = 'bilimbaga'

beforeEach(() => {
  vi.mocked(resolveRealmFromUrl).mockReturnValue(SLUG)
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.mocked(resolveRealmFromUrl).mockReturnValue(null)
})

describe('Q-1074 / GH 2431 — OidcCallbackPage tenant lookup', () => {
  it('candidate login: makes no tenants/:slug request and the header shows the slug', async () => {
    vi.resetModules()
    const token = fakeToken(['CANDIDATE'])
    mockSigninRedirectCallback.mockResolvedValue({ access_token: token })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockSetSession).toHaveBeenCalledTimes(1)
    })
    expect(tenantsApi.getBySlug).not.toHaveBeenCalled()
    const session = mockSetSession.mock.calls[0][0]
    expect(session.tenant_slug).toBe(SLUG)
    expect(session.tenant_display_name).toBe(SLUG)
  })

  it('PLATFORM_ADMIN login: still looks up the tenant and uses the record', async () => {
    vi.resetModules()
    const token = fakeToken(['PLATFORM_ADMIN'])
    mockSigninRedirectCallback.mockResolvedValue({ access_token: token })
    vi.mocked(tenantsApi.getBySlug).mockResolvedValue({
      slug: SLUG,
      display_name: 'Bilimbaga Tenant',
      tenant_id: 't-1',
      tenant_type: 'production',
      production_tenant_display_name: null,
    } as never)

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockSetSession).toHaveBeenCalledTimes(1)
    })
    expect(tenantsApi.getBySlug).toHaveBeenCalledWith(SLUG)
    const session = mockSetSession.mock.calls[0][0]
    expect(session.tenant_display_name).toBe('Bilimbaga Tenant')
    expect(session.tenant_id).toBe('t-1')
  })
})
