// @vitest-environment jsdom
/**
 * REQ-343 AC5 — the "Question Bank" nav entry (routing to
 * /admin/bilimbaga) is gated by the caller's
 * :EntitiesRecordsWrite permission from GET /me/access (REQ-309's role
 * matrix: the platform admin and operator fixtures hold it; the designer and
 * task-worker fixtures do not). A caller lacking that permission must not
 * see the nav entry. Mirrors AppShell.branding.test.tsx's own mocking pattern
 * (useAuth/client.get mocked directly — DIRECTIVE T-2, no msw/raw-fetch).
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
  // Install the exam module so Question Bank nav item appears.
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

describe('REQ-343 AC5 — Question Bank nav entry role gating', () => {
  it('platform admin sees the nav entry', async () => {
    await renderAppShellAs('platformAdmin')
    await waitFor(() => expect(screen.getByText('Question Bank')).toBeInTheDocument())
  })

  it('operator (holds :EntitiesRecordsWrite) sees the nav entry', async () => {
    await renderAppShellAs('operator')
    await waitFor(() => expect(screen.getByText('Question Bank')).toBeInTheDocument())
  })

  it('designer (no :EntitiesRecordsWrite) does NOT see the nav entry', async () => {
    await renderAppShellAs('designer')
    await waitFor(() => expect(screen.getByText('Definitions')).toBeInTheDocument())
    expect(screen.queryByText('Question Bank')).not.toBeInTheDocument()
  })

  it('task worker does NOT see the nav entry', async () => {
    await renderAppShellAs('taskWorker')
    await waitFor(() => expect(screen.getByText('My Tasks')).toBeInTheDocument())
    expect(screen.queryByText('Question Bank')).not.toBeInTheDocument()
  })
})
