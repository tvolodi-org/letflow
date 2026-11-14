// @vitest-environment jsdom
/** W1, W2, W11 (T-1950): the button is on every signed-in screen, for every role; AppShell starts the rings fresh. */
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import type { AccessState } from '@/auth/access'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { recordAction, resetCapture, snapshot } from '@/lib/problemReport/capture'
import { reportProblemMessages as M } from '../reportProblemMessages'

expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({ useQuery: vi.fn(() => ({ data: undefined })) }))
vi.mock('@/auth/AuthContext', () => ({ useAuth: vi.fn() }))
vi.mock('@/api/client', () => ({
  client: { get: vi.fn(() => Promise.resolve({ items: [] })) },
  resolveApiUrl: (path: string) => path,
}))
// The dialog needs a query client; this file only checks that the button is there and opens it.
vi.mock('../ReportProblemDialog', () => ({ ReportProblemDialog: () => <div data-testid="report-dialog" /> }))

async function renderShell(path: string, state: AccessState) {
  const { useAuth } = await import('@/auth/AuthContext')
  vi.mocked(useAuth).mockReturnValue({
    session: { token: 't', display_name: 'U', tenant_id: 'tid', tenant_slug: 'a', tenant_display_name: 'A', tenant_type: 'production', loginSource: null },
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  } as never)
  const { BrandingProvider } = await import('@/theming/BrandingProvider')
  const { AppShell } = await import('../AppShell')
  const { AccessStateProvider } = await import('@/auth/access/AccessContext')
  render(
    <MemoryRouter initialEntries={[path]}>
      <BrandingProvider>
        <AccessStateProvider state={state}>
          <Routes>
            <Route element={<AppShell />}>
              <Route path="*" element={<div>page</div>} />
            </Route>
          </Routes>
        </AccessStateProvider>
      </BrandingProvider>
    </MemoryRouter>,
  )
}

beforeEach(() => {
  useUiLocaleStore.getState().setLocaleTransient('en')
})
// The first import of the real AppShell is slow: load it once, outside any test's 5 s budget.
beforeAll(async () => {
  await import('../AppShell')
}, 60000)
afterEach(() => cleanup())

describe('Report a problem button', () => {
  it.each(['/tasks', '/admin/assets/documents', '/definitions'])('W1: shown on %s', async (path) => {
    const { accessState } = await import('@/auth/access/fixtures')
    await renderShell(path, accessState('platformAdmin'))
    expect(screen.getByTestId('topbar-report-problem')).toHaveAccessibleName(M.en.button)
  }, 30000)

  it('W2: shown for a user with no roles and no permissions, and opens the dialog', async () => {
    await renderShell('/tasks', { status: 'ready', info: { roles: [], platform_tenant: false, permissions: [] } } as AccessState)
    await userEvent.click(screen.getByTestId('topbar-report-problem'))
    expect(screen.getByTestId('report-dialog')).toBeInTheDocument()
  })

  it('W11: mounting the shell resets the rings and records the page', async () => {
    const { accessState } = await import('@/auth/access/fixtures')
    resetCapture()
    recordAction('click', 'tenant-a-leftover')
    await renderShell('/tasks', accessState('platformAdmin'))
    const names = snapshot().actions.map((a) => a.name)
    expect(names).toEqual(['/tasks'])
  })
})
