// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
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

async function renderAt(path: string) {
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
              <Route path="*" element={<div>page</div>} />
            </Route>
          </Routes>
        </AccessStateProvider>
      </BrandingProvider>
    </MemoryRouter>,
  )
}

describe('J3-8 AppShell fluid content for the data screens that opt in', () => {
  it('the movements journal fills wide windows', async () => {
    await renderAt('/admin/stock/movements')
    expect(screen.getByRole('main')).toHaveClass('lf-content--fluid')
  })

  it('a sub-path of an opted-in screen is fluid too; other screens keep the capped column', async () => {
    await renderAt('/admin/stock/movements/x')
    expect(screen.getByRole('main')).toHaveClass('lf-content--fluid')
    cleanup()
    await renderAt('/admin/stock/balances')
    expect(screen.getByRole('main')).not.toHaveClass('lf-content--fluid')
    expect(screen.getByRole('main')).toHaveClass('lf-content')
  })
})
