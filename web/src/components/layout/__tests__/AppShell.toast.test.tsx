// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup, waitFor, act } from '@testing-library/react'
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
  }
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

/** Render AppShell with the exam module installed so module nav items appear. */
async function renderShell(fixture: AccessFixtureName) {
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

describe('T-1185 — one global ToastContainer in the app shell', () => {
  it('renders a toast fired from outside any screen exactly once', async () => {
    await renderShell('candidate')
    const { useToast } = await import('@/hooks/useToast')
    const { clearAllToasts } = await import('@/hooks/useToast')
    const api = useToast()
    act(() => api.success('Saved by shell test'))
    await waitFor(() => expect(screen.getAllByText('Saved by shell test')).toHaveLength(1))
    expect(screen.getAllByTestId('toast-container')).toHaveLength(1)
    act(() => clearAllToasts())
  })
})
