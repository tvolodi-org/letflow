// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, cleanup } from '@testing-library/react'
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

async function renderShell(path = '/instances') {
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
    <MemoryRouter initialEntries={[path]}>
      <BrandingProvider>
        <AccessStateProvider state={accessState('platformAdmin')}>
          <Routes>
            <Route element={<AppShell />}>
              <Route path="/admin/stock/balances" element={<button>Page button</button>} />
              <Route path="/instances" element={<><LocationProbe /><button>Page button</button></>} />
            </Route>
          </Routes>
        </AccessStateProvider>
      </BrandingProvider>
    </MemoryRouter>,
  )
}

describe('AppShell fluid content (T-1445)', () => {
  it('F1 the Balances route fills wide windows, another route keeps the capped column', async () => {
    await renderShell('/admin/stock/balances')
    expect(document.getElementById('main-content')).toHaveClass('lf-content--fluid')
    cleanup()
    await renderShell('/instances')
    expect(document.getElementById('main-content')).not.toHaveClass('lf-content--fluid')
  })
})
