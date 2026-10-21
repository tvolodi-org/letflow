// @vitest-environment jsdom
/**
 * ISS-0728 — candidate navigation for the exam module.
 *
 * After REQ-412, "Exams" (/exam) and "Question Bank" (/admin/bilimbaga) come
 * from the exam module's navItems via getInstalledModuleNavItems — they are
 * no longer hardcoded in AppShell's NAV_ITEMS. This test verifies role-gating
 * still works correctly when the exam module is installed.
 *
 * Cases:
 *   1. The candidate fixture with exam installed sees the "Exams" nav entry, linking to /exam.
 *   2. The candidate fixture does NOT see any admin nav entry.
 *   3. "Exams" follows the :ExamSessionStart permission from /me/access: the designer,
 *      operator and task-worker fixtures do NOT see it, while each still sees its own
 *      already-established nav entry. (The platform admin holds the permission, so it
 *      now sees "Exams" too: the old hand-copied role list excluded it.)
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
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
    tenant_slug: 'acme',
    tenant_display_name: 'Acme Co',
    tenant_id: 'tid-acme',
    tenant_type: 'production',
    production_tenant_display_name: null,
  }
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

/** Render AppShell with the exam module installed so module nav items appear. */
async function renderAppShellAs(fixture: AccessFixtureName) {
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
  // Install the exam module so Exams / Question Bank nav items appear.
  vi.mocked(useInstalledModules).mockReturnValue({
    data: [{ module_id: 'exam', version: '1.0.0' }],
    isLoading: false,
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

describe('ISS-0728 — candidate Exams nav entry (module-driven after REQ-412)', () => {
  it('candidate sees the "Exams" nav entry, linking to /exam', async () => {
    await renderAppShellAs('candidate')
    await waitFor(() => expect(screen.getByText('Exams')).toBeInTheDocument())
    expect(screen.getByRole('link', { name: 'Exams' })).toHaveAttribute('href', '/exam')
  })

  it('candidate does NOT see any admin nav entry', async () => {
    await renderAppShellAs('candidate')
    await waitFor(() => expect(screen.getByText('Exams')).toBeInTheDocument())
    expect(screen.queryByText('Instances')).not.toBeInTheDocument()
    expect(screen.queryByText('My Tasks')).not.toBeInTheDocument()
    expect(screen.queryByText('Definitions')).not.toBeInTheDocument()
    expect(screen.queryByText('DLQ')).not.toBeInTheDocument()
    expect(screen.queryByText('Webhooks')).not.toBeInTheDocument()
    expect(screen.queryByText('Users')).not.toBeInTheDocument()
    expect(screen.queryByText('Question Bank')).not.toBeInTheDocument()
  })

  it('platform admin (holds :ExamSessionStart) sees "Exams"', async () => {
    await renderAppShellAs('platformAdmin')
    await waitFor(() => expect(screen.getByText('Question Bank')).toBeInTheDocument())
    expect(screen.getByText('Exams')).toBeInTheDocument()
  })

  it('designer does NOT see "Exams"', async () => {
    await renderAppShellAs('designer')
    await waitFor(() => expect(screen.getByText('Definitions')).toBeInTheDocument())
    expect(screen.queryByText('Exams')).not.toBeInTheDocument()
  })

  it('operator does NOT see "Exams"', async () => {
    await renderAppShellAs('operator')
    await waitFor(() => expect(screen.getByText('Question Bank')).toBeInTheDocument())
    expect(screen.queryByText('Exams')).not.toBeInTheDocument()
  })

  it('task worker does NOT see "Exams"', async () => {
    await renderAppShellAs('taskWorker')
    await waitFor(() => expect(screen.getByTestId('logout-button')).toBeInTheDocument())
    expect(screen.queryByText('Exams')).not.toBeInTheDocument()
  })
})

