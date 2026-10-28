// @vitest-environment jsdom
/**
 * REQ-412 AC4 — exam module nav items and route guard.
 *
 * With `GET /api/v1/me/modules` returning exam in installed_modules:
 *   - A the candidate fixture sees the /exam nav item.
 *   - A the process operator fixture sees the /admin/bilimbaga nav item.
 *
 * With installed_modules: []:
 *   - Neither nav item renders.
 *   - Navigating to /exam renders the not-found content (ModuleGuard gates
 *     the route; when the exam module is not installed, it renders NotFoundPage).
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import type { UserSession } from '@/types/api'
import type { AccessFixtureName } from '@/auth/access/fixtures'

expect.extend(jestDomMatchers)

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
    tenant_slug: 'fixture-tenant',
    tenant_display_name: 'Fixture Tenant',
    tenant_id: 'tid-fixture',
    tenant_type: 'production',
  }
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

type InstalledModule = { module_id: string; version: string }

async function renderAppShellAt(
  fixture: AccessFixtureName,
  installedModules: InstalledModule[],
  initialPath = '/instances',
) {
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
  } as never)

  const { BrandingProvider } = await import('@/theming/BrandingProvider')
  const { AppShell } = await import('@/components/layout/AppShell')
  const { AccessStateProvider } = await import('@/auth/access/AccessContext')
  const { accessState } = await import('@/auth/access/fixtures')

  render(
    <MemoryRouter initialEntries={[initialPath]}>
      <BrandingProvider>
        <AccessStateProvider state={accessState(fixture)}>
          <AppShell />
        </AccessStateProvider>
      </BrandingProvider>
    </MemoryRouter>,
  )
}

describe('REQ-412 AC4 — exam module nav items', () => {
  it('the candidate fixture sees the /exam nav item when exam module is installed', async () => {
    await renderAppShellAt('candidate', [{ module_id: 'exam', version: '1.0.0' }])
    await waitFor(() => expect(screen.getByText('Exams')).toBeInTheDocument())
    expect(screen.getByRole('link', { name: 'Exams' })).toHaveAttribute('href', '/exam')
  })

  it('the process operator fixture sees the /admin/bilimbaga nav item when exam module is installed', async () => {
    await renderAppShellAt('operator', [{ module_id: 'exam', version: '1.0.0' }])
    await waitFor(() => expect(screen.getByText('Question Bank')).toBeInTheDocument())
    expect(screen.getByRole('link', { name: 'Question Bank' })).toHaveAttribute('href', '/admin/bilimbaga')
  })

  it('with installed_modules:[], the candidate fixture does not see the /exam nav item', async () => {
    await renderAppShellAt('candidate', [])
    await waitFor(() => expect(screen.getByTestId('logout-button')).toBeInTheDocument())
    expect(screen.queryByText('Exams')).not.toBeInTheDocument()
  })

  it('with installed_modules:[], the process operator fixture does not see the /admin/bilimbaga nav item', async () => {
    await renderAppShellAt('operator', [])
    await waitFor(() => expect(screen.getByTestId('logout-button')).toBeInTheDocument())
    expect(screen.queryByText('Question Bank')).not.toBeInTheDocument()
  })
})

describe('REQ-412 AC4 — /exam route guard when exam module not installed', () => {
  it('navigating to /exam renders not-found content when installed_modules is empty', async () => {
    vi.resetModules()

    const { useInstalledModules } = await import('@/hooks/useInstalledModules')
    vi.mocked(useInstalledModules).mockReturnValue({
      data: [],
      isLoading: false,
    } as never)

    const { ModuleGuard } = await import('@/components/routing/ModuleGuard')
    const { NotFoundPage } = await import('@/pages/NotFoundPage')

    render(
      <MemoryRouter initialEntries={['/exam']}>
        <Routes>
          <Route
            path="exam"
            element={<ModuleGuard moduleId="exam" />}
          >
            <Route index element={<div data-testid="exam-list-page">Exam List</div>} />
          </Route>
          <Route path="*" element={<NotFoundPage />} />
        </Routes>
      </MemoryRouter>,
    )

    await waitFor(() =>
      expect(screen.getByTestId('not-found-page')).toBeInTheDocument(),
    )
    expect(screen.queryByTestId('exam-list-page')).not.toBeInTheDocument()
  })
})

describe('GH 3355 / REQ-602 — exam builder nav item', () => {
  it('a holder of ExamAuthoringWrite sees the Exam builder link', async () => {
    await renderAppShellAt('tenantAdmin', [{ module_id: 'exam', version: '1.0.0' }])
    await waitFor(() => expect(screen.getByRole('link', { name: 'Exam builder' })).toBeInTheDocument())
    expect(screen.getByRole('link', { name: 'Exam builder' })).toHaveAttribute('href', '/admin/bilimbaga/exam-builder')
  })

  it('the process operator fixture does not see it', async () => {
    await renderAppShellAt('operator', [{ module_id: 'exam', version: '1.0.0' }])
    await waitFor(() => expect(screen.getByText('Question Bank')).toBeInTheDocument())
    expect(screen.queryByRole('link', { name: 'Exam builder' })).not.toBeInTheDocument()
  })
})
