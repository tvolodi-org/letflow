// @vitest-environment jsdom
/**
 * GH #2238 criterion: "a token payload claiming PLATFORM_ADMIN while /me/access says
 * TENANT_ADMIN is gated as TENANT_ADMIN". The token's role claims are never read after login:
 * the session is built, the tenant lookup decided, the landing page chosen and the shell gated
 * from GET /me/access only. Role literals are allowed in this directory.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ACCESS_FIXTURES } from '../fixtures'
expect.extend(jestDomMatchers)

const { mockGetAccess, mockGetBySlug, mockNavigate, mockSetSession, mockSigninRedirectCallback, auth } = vi.hoisted(() => ({
  mockGetAccess: vi.fn(),
  mockGetBySlug: vi.fn(),
  mockNavigate: vi.fn(),
  mockSetSession: vi.fn(),
  mockSigninRedirectCallback: vi.fn(),
  auth: { session: null as unknown },
}))

vi.mock('@/api/me', () => ({ meApi: { getAccess: mockGetAccess, getAccessWithToken: mockGetAccess } }))
vi.mock('@/api/tenants', () => ({ tenantsApi: { getBySlug: mockGetBySlug } }))
vi.mock('@/api/client', () => ({
  clearToken: vi.fn(),
  setToken: vi.fn(),
  tryRestoreE2eSession: vi.fn(() => null),
  client: { get: vi.fn(() => Promise.resolve({ items: [] })) },
}))
vi.mock('@/auth/OidcManager', () => ({
  getOidcManager: vi.fn(async () => ({ signinRedirectCallback: mockSigninRedirectCallback })),
  oidcManager: { signinSilentCallback: vi.fn() },
}))
vi.mock('@/auth/tenantConfig', () => ({ resolveRealmFromUrl: vi.fn(() => 'fixture-co'), resetTenantConfigCache: vi.fn() }))
vi.mock('react-router-dom', async importOriginal => ({
  ...(await importOriginal<typeof import('react-router-dom')>()),
  useNavigate: () => mockNavigate,
}))
vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: auth.session, setSession: mockSetSession, logout: vi.fn(), switchTenant: vi.fn(), switchingToTenantSlug: null }),
}))
vi.mock('@/hooks/useInstalledModules', () => ({ useInstalledModules: () => ({ data: [] }) }))
vi.mock('@tanstack/react-query', () => ({ useQuery: vi.fn(() => ({ data: undefined })) }))

import { buildSessionFromToken } from '@/auth/AuthProvider'
import { AppShell } from '@/components/layout/AppShell'
import { AccessProvider } from '../AccessProvider'

/** A token whose payload claims the platform-admin role. */
function platformAdminClaimToken(): string {
  const b64 = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, '')
  return `${b64({ alg: 'none' })}.${b64({ sub: 'u1', roles: ['PLATFORM_ADMIN'], tenant_id: 'fixture-co' })}.sig`
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('token claims are not authority', () => {
  it('buildSessionFromToken: token claims PLATFORM_ADMIN, /me/access says TENANT_ADMIN -> no platform tenant lookup', async () => {
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.tenantAdmin)

    const session = await buildSessionFromToken(platformAdminClaimToken())

    expect(mockGetBySlug).not.toHaveBeenCalled()
    expect(session.tenant_display_name).toBe('fixture-co')
    expect(session).not.toHaveProperty('roles')
  })

  it('OidcCallbackPage: same claim, /me/access says TENANT_ADMIN -> lands on / with no tenant lookup', async () => {
    vi.resetModules()
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.tenantAdmin)
    mockSigninRedirectCallback.mockResolvedValue({ access_token: platformAdminClaimToken() })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => expect(mockNavigate).toHaveBeenCalledWith('/', { replace: true }))
    expect(mockNavigate).not.toHaveBeenCalledWith('/platform-dashboard', { replace: true })
    expect(mockGetBySlug).not.toHaveBeenCalled()
  })

  it('OidcCallbackPage: /me/access granting platform authority -> lookup and /platform-dashboard', async () => {
    vi.resetModules()
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.platformAdmin)
    mockGetBySlug.mockResolvedValue({ display_name: 'Fixture', tenant_id: 't-1', tenant_type: 'production', production_tenant_display_name: null })
    mockSigninRedirectCallback.mockResolvedValue({ access_token: platformAdminClaimToken() })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => expect(mockNavigate).toHaveBeenCalledWith('/platform-dashboard', { replace: true }))
    expect(mockGetBySlug).toHaveBeenCalledWith('fixture-co')
  })

  it('AppShell: a session whose token claims PLATFORM_ADMIN but whose /me/access is TENANT_ADMIN is gated as TENANT_ADMIN', async () => {
    mockGetAccess.mockResolvedValue(ACCESS_FIXTURES.tenantAdmin)
    auth.session = {
      token: platformAdminClaimToken(),
      display_name: 'Test User',
      loginSource: 'oidc',
      tenant_slug: 'fixture-co',
      tenant_display_name: 'Fixture',
      tenant_id: 'tid',
      tenant_type: 'production',
      production_tenant_display_name: null,
    }

    render(
      <MemoryRouter initialEntries={['/instances']}>
        <AccessProvider>
          <AppShell />
        </AccessProvider>
      </MemoryRouter>,
    )

    await waitFor(() => expect(screen.getByRole('link', { name: 'Users' })).toBeInTheDocument())
    expect(screen.getByTestId('user-roles')).toHaveTextContent('TENANT_ADMIN')
    for (const platformOnly of ['Tenants', 'Register Tenant', 'Services', 'Health', 'Platform Migrations', 'Event Retention']) {
      expect(screen.queryByRole('link', { name: platformOnly })).not.toBeInTheDocument()
    }
  })
})
