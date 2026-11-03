// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'

expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({ useQuery: vi.fn(() => ({ data: undefined })) }))
vi.mock('@/auth/AuthContext', () => ({ useAuth: vi.fn() }))
vi.mock('@/api/client', () => ({
  client: { get: vi.fn(() => Promise.resolve({ items: [] })) },
  resolveApiUrl: (path: string) => path,
}))

afterEach(cleanup)

async function renderShell() {
  const { useAuth } = await import('@/auth/AuthContext')
  vi.mocked(useAuth).mockReturnValue({
    session: { token: 't', display_name: 'Test User', loginSource: null, tenant_slug: 'acme', tenant_display_name: 'Acme Co', tenant_id: 'tid', tenant_type: 'production' },
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
  return render(
    <MemoryRouter initialEntries={['/instances']}>
      <BrandingProvider>
        <AccessStateProvider state={accessState('platformAdmin')}>
          <Routes>
            <Route element={<AppShell />}>
              <Route path="/instances" element={<p>Instances page</p>} />
              <Route path="/tasks" element={<p>Tasks page</p>} />
            </Route>
          </Routes>
        </AccessStateProvider>
      </BrandingProvider>
    </MemoryRouter>,
  )
}

describe('AppShell restyle: night nav, active item, drawer', () => {
  it('nav is the night sidenav and the active item carries aria-current (ember dot via CSS)', async () => {
    await renderShell()
    const nav = await screen.findByTestId('sidenav')
    expect(nav).toHaveClass('lf-sidenav', 'lf-night')
    const active = await screen.findByRole('link', { name: 'Instances' })
    expect(active).toHaveAttribute('aria-current', 'page')
    expect(active).toHaveClass('lf-sidenav__item')
    expect(await screen.findByRole('link', { name: 'My Tasks' })).not.toHaveAttribute('aria-current')
  })

  it('drawer: menu button opens and closes it, Escape closes it, scrim click closes it', async () => {
    const user = userEvent.setup()
    const { container } = await renderShell()
    await screen.findByTestId('sidenav')
    const app = container.querySelector('.lf-app') as HTMLElement
    expect(app).not.toHaveClass('is-nav-open')
    await user.click(screen.getByRole('button', { name: 'Open menu' }))
    expect(app).toHaveClass('is-nav-open')
    expect(screen.getByRole('button', { name: 'Close menu' })).toHaveAttribute('aria-controls', 'app-sidenav')
    await user.keyboard('{Escape}')
    expect(app).not.toHaveClass('is-nav-open')
    await user.click(screen.getByRole('button', { name: 'Open menu' }))
    await user.click(screen.getByTestId('nav-scrim'))
    expect(app).not.toHaveClass('is-nav-open')
  })

  it('drawer closes after navigating to another page', async () => {
    const user = userEvent.setup()
    const { container } = await renderShell()
    await user.click(screen.getByRole('button', { name: 'Open menu' }))
    await user.click(await screen.findByRole('link', { name: 'My Tasks' }))
    expect(screen.getByText('Tasks page')).toBeInTheDocument()
    expect(container.querySelector('.lf-app')).not.toHaveClass('is-nav-open')
  })
})
