// @vitest-environment jsdom
/**
 * ISS-0836: the 'sample' module was removed from production REGISTERED_MODULES;
 * its test fixture data is kept here as a local const (moved to test-only data
 * per ISS-0836's acceptance criteria). The registry module is mocked so tests
 * do not depend on the production module list.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import type { UserSession } from '@/types/api'
import type { AccessFixtureName } from '@/auth/access/fixtures'
import type { InstalledModule } from '@/api/me'

expect.extend(jestDomMatchers)

// Test-only fixture module definition (was previously in production REGISTERED_MODULES;
// removed from registry.ts by ISS-0836, kept here as test-only data).
const SAMPLE_FIXTURE_NAV_ITEM = { to: '/sample', label: 'Sample', permission: 'ExamSessionStart' }

vi.mock('@/modules/registry', () => ({
  getInstalledModuleNavItems: vi.fn(
    (installed: InstalledModule[]) =>
      installed.some((m) => m.module_id === 'sample')
        ? [SAMPLE_FIXTURE_NAV_ITEM]
        : [],
  ),
  REGISTERED_MODULE_ROUTE_OBJECTS: [],
}))

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(() => ({ data: undefined })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('@/hooks/useInstalledModules', () => ({
  useInstalledModules: vi.fn(),
}))

vi.mock('@/api/client', () => ({
  client: { get: vi.fn(() => Promise.resolve({ items: [] })) },
}))

function testSession(): UserSession {
  return {
    token: 'tok',
    display_name: 'Test User',
    loginSource: null,
    tenant_slug: 'acme',
    tenant_display_name: 'Acme Co',
    tenant_id: 'tid-acme',
    tenant_type: 'production',
  }
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

async function renderAppShellAs(fixture: AccessFixtureName, installedModules: Array<{ module_id: string; version: string }> = []) {
  vi.resetModules()

  const { useAuth } = await import('@/auth/AuthContext')
  const { useInstalledModules } = await import('@/hooks/useInstalledModules')
  vi.mocked(useAuth).mockReturnValue({
    session: testSession(),
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  })
  vi.mocked(useInstalledModules).mockReturnValue({
    data: installedModules,
    isLoading: false,
    error: null,
    isError: false,
    isSuccess: true,
    status: 'success',
    fetchStatus: 'idle',
    isFetched: true,
    isFetchedAfterMount: true,
    isPending: false,
    isRefetching: false,
    isLoadingError: false,
    isPlaceholderData: false,
    isRefetchError: false,
    refetch: vi.fn(),
    failureCount: 0,
    failureReason: null,
    isInitialLoading: false,
    isPaused: false,
    dataUpdatedAt: 0,
    errorUpdatedAt: 0,
    receive: vi.fn(),
    promise: Promise.resolve({ data: installedModules }),
  } as never)

  const { BrandingProvider } = await import('@/theming/BrandingProvider')
  const { AppShell } = await import('../AppShell')
  const { AccessStateProvider } = await import('@/auth/access/AccessContext')
  const { accessState } = await import('@/auth/access/fixtures')

  render(
    <MemoryRouter initialEntries={['/instances']}>
      <BrandingProvider>
        <AccessStateProvider state={accessState(fixture)}>
          <AppShell />
        </AccessStateProvider>
      </BrandingProvider>
    </MemoryRouter>,
  )
}

describe('AppShell installed-module nav', () => {
  it('shows an installed module nav item for the roles it grants', async () => {
    await renderAppShellAs('candidate', [{ module_id: 'sample', version: '1.0.0' }])
    await waitFor(() => expect(screen.getByText('Sample')).toBeInTheDocument())
    expect(screen.getByRole('link', { name: 'Sample' })).toHaveAttribute('href', '/sample')
  })

  it('hides a module nav item when the tenant has not installed it', async () => {
    await renderAppShellAs('candidate', [])
    await waitFor(() => expect(screen.getByTestId('logout-button')).toBeInTheDocument())
    // With no installed modules, neither module-provided nav item appears.
    expect(screen.queryByText('Sample')).not.toBeInTheDocument()
    expect(screen.queryByText('Exams')).not.toBeInTheDocument()
  })
})
