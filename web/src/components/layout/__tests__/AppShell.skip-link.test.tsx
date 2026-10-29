// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import type { UserSession } from '@/types/api'

expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(() => ({ data: undefined })),
}))
vi.mock('@/auth/AuthContext', () => ({ useAuth: vi.fn() }))
vi.mock('@/api/client', () => ({
  client: { get: vi.fn(() => Promise.resolve({ items: [] })) },
  resolveApiUrl: (path: string) => path,
}))

const SESSION: UserSession = {
  token: 'tok',
  display_name: 'Test User',
  loginSource: null,
  tenant_slug: 'acme',
  tenant_display_name: 'Acme Co',
  tenant_id: 'tid-acme',
  tenant_type: 'production',
}

afterEach(cleanup)

function LocationProbe() {
  const l = useLocation()
  return <div data-testid="loc">{l.pathname + l.hash}</div>
}

async function renderShell() {
  const { useAuth } = await import('@/auth/AuthContext')
  vi.mocked(useAuth).mockReturnValue({
    session: SESSION,
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  })
  const { BrandingProvider } = await import('@/theming/BrandingProvider')
  const { AppShell } = await import('../AppShell')
  const { AccessStateProvider } = await import('@/auth/access/AccessContext')
  const { accessState } = await import('@/auth/access/fixtures')
  render(
    <MemoryRouter initialEntries={['/instances']}>
      <BrandingProvider>
        <AccessStateProvider state={accessState('platformAdmin')}>
          <Routes>
            <Route element={<AppShell />}>
              <Route path="/instances" element={<><LocationProbe /><button>Page button</button></>} />
            </Route>
          </Routes>
        </AccessStateProvider>
      </BrandingProvider>
    </MemoryRouter>,
  )
}

describe('AppShell skip link (REQ-608)', () => {
  it('main has id main-content and tabindex -1, exactly once', async () => {
    await renderShell()
    const main = screen.getByRole('main')
    expect(document.querySelectorAll('#main-content')).toHaveLength(1)
    expect(document.getElementById('main-content')).toBe(main)
    expect(main).toHaveAttribute('tabindex', '-1')
  })

  it('skip link is the first focusable element', async () => {
    const user = userEvent.setup()
    await renderShell()
    await user.tab()
    expect(document.activeElement).toHaveAttribute('href', '#main-content')
    expect(screen.getByRole('link', { name: 'Skip to main content' })).toHaveFocus()
  })

  it('click and Enter focus main without changing the location; Tab then enters the page', async () => {
    const user = userEvent.setup()
    await renderShell()
    const main = screen.getByRole('main')
    await user.click(screen.getByRole('link', { name: 'Skip to main content' }))
    expect(main).toHaveFocus()
    expect(screen.getByTestId('loc')).toHaveTextContent('/instances')

    await user.tab()
    expect(screen.getByRole('button', { name: 'Page button' })).toHaveFocus()

    await user.tab({ shift: true })
    await user.tab({ shift: true })
    ;(document.activeElement as HTMLElement).blur()
    await user.tab()
    await user.keyboard('{Enter}')
    expect(main).toHaveFocus()
    expect(screen.getByTestId('loc')).toHaveTextContent('/instances')
  })
})
