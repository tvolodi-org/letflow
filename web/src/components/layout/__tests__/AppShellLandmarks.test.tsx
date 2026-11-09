// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup } from '@testing-library/react'
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
              <Route path="/instances" element={<><LocationProbe /><h1>Page title</h1></>} />
            </Route>
          </Routes>
        </AccessStateProvider>
      </BrandingProvider>
    </MemoryRouter>,
  )
}

describe('AppShell landmarks (T-1586)', () => {
  it('L1: one main, skip link target, every nav and aside has a unique accessible name', async () => {
    await renderShell()
    expect(screen.getAllByRole('main')).toHaveLength(1)
    expect(document.getElementById('main-content')).toBe(screen.getByRole('main'))
    expect(screen.getByRole('link', { name: 'Skip to main content' })).toHaveAttribute('href', '#main-content')
    const named = [...document.querySelectorAll('nav, aside')]
    expect(named.length).toBeGreaterThan(0)
    const names = named.map((n) => n.getAttribute('aria-label') ?? n.getAttribute('aria-labelledby') ?? '')
    names.forEach((n) => expect(n).not.toBe(''))
    expect(new Set(names).size).toBe(names.length)
  })

  it('L2: the main nav name comes from the catalogue in all three languages', async () => {
    const { navMessages } = await import('../navMessages')
    for (const l of ['en', 'ru', 'kk'] as const) expect(navMessages[l].mainNav.length).toBeGreaterThan(0)
    await renderShell()
    expect(screen.getByRole('navigation', { name: navMessages.en.mainNav })).toBeInTheDocument()
  })

  it('L3: exactly one h1 once a page is routed in', async () => {
    await renderShell()
    expect(screen.getAllByRole('heading', { level: 1 })).toHaveLength(1)
  })
})
