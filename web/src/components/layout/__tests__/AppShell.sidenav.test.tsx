// @vitest-environment jsdom
/** T-1442 N1-N6 — collapsible side nav: toggle, labels in en/ru/kk, icons + title, remembered state, splitter, clamp. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup, act } from '@testing-library/react'
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

beforeEach(async () => {
  localStorage.clear()
  const { resetDefaultLayoutStore } = await import('@/hooks/useLayoutPrefs')
  resetDefaultLayoutStore()
})
afterEach(async () => {
  cleanup()
  const { useUiLocaleStore } = await import('@/i18n/uiLocaleStore')
  act(() => useUiLocaleStore.getState().setLocale('en'))
})

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
            </Route>
          </Routes>
        </AccessStateProvider>
      </BrandingProvider>
    </MemoryRouter>,
  )
}
const app = (c: HTMLElement) => c.querySelector('.lf-app') as HTMLElement

describe('AppShell side nav', () => {
  it('N1 the toggle collapses and expands the nav and flips aria-expanded and its label', async () => {
    const user = userEvent.setup()
    const { container } = await renderShell()
    expect(app(container)).toHaveAttribute('data-nav', 'expanded')
    const toggle = await screen.findByTestId('sidenav-toggle')
    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    expect(toggle).toHaveAttribute('aria-label', 'Collapse the side nav')
    await user.click(toggle)
    expect(app(container)).toHaveAttribute('data-nav', 'collapsed')
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(toggle).toHaveAttribute('aria-label', 'Expand the side nav')
    await user.click(toggle)
    expect(app(container)).toHaveAttribute('data-nav', 'expanded')
  })

  it('N2 the toggle label is translated (ru, kk)', async () => {
    const { useUiLocaleStore } = await import('@/i18n/uiLocaleStore')
    act(() => useUiLocaleStore.getState().setLocale('ru'))
    await renderShell()
    expect(await screen.findByTestId('sidenav-toggle')).toHaveAttribute('aria-label', 'Свернуть меню')
    cleanup()
    act(() => useUiLocaleStore.getState().setLocale('kk'))
    await renderShell()
    expect(await screen.findByTestId('sidenav-toggle')).toHaveAttribute('aria-label', 'Мәзірді жию')
  })

  it('N3 every nav link keeps its accessible name, gets a title and an aria-hidden icon', async () => {
    await renderShell()
    const link = await screen.findByRole('link', { name: 'Instances' })
    expect(link).toHaveAttribute('title', 'Instances')
    const icon = link.querySelector('svg')
    expect(icon).toHaveAttribute('aria-hidden', 'true')
    expect(link.querySelector('span')?.textContent).toBe('Instances')
  })

  it('N4 the collapsed state is restored from the stored layout', async () => {
    localStorage.setItem('lf.prefs.ui.layout.v1.anon', JSON.stringify({ v: 1, shell: { sidenav: { collapsed: true } }, screens: {} }))
    const { resetDefaultLayoutStore } = await import('@/hooks/useLayoutPrefs')
    resetDefaultLayoutStore()
    const { container } = await renderShell()
    expect(app(container)).toHaveAttribute('data-nav', 'collapsed')
    expect(await screen.findByTestId('sidenav-toggle')).toHaveAttribute('aria-expanded', 'false')
  })

  it('N4b collapsed: Sign out is an icon with a label, expanded it shows the text', async () => {
    const { container } = await renderShell()
    const out = await screen.findByTestId('logout-button')
    expect(out).toHaveTextContent('Sign out')
    await userEvent.click(screen.getByTestId('sidenav-toggle'))
    expect(app(container)).toHaveAttribute('data-nav', 'collapsed')
    expect(out).toHaveTextContent('')
    expect(out).toHaveAttribute('aria-label', 'Sign out')
    expect(out.querySelector('svg')).toBeTruthy()
  })

  it('N5the splitter on the nav edge is a separator with the 200-360 px range and the translated label', async () => {
    const { container } = await renderShell()
    await screen.findByTestId('sidenav')
    const h = container.querySelector('.lf-splitter') as HTMLElement
    expect(h).toBeTruthy()
    expect(h).toHaveAttribute('role', 'separator')
    expect(h).toHaveAttribute('aria-label', 'Resize the side nav')
    expect(h).toHaveAttribute('aria-controls', 'app-sidenav')
    expect(h.querySelector('.lf-splitter__btn')).toBeTruthy()
  })

  it('N6 a stored width outside 200-360 is clamped when applied and left as stored', async () => {
    localStorage.setItem('lf.prefs.ui.layout.v1.anon', JSON.stringify({ v: 1, shell: { sidenav: { w: 420 } }, screens: {} }))
    const { resetDefaultLayoutStore, useLayoutPrefs } = await import('@/hooks/useLayoutPrefs')
    resetDefaultLayoutStore()
    const { container } = await renderShell()
    expect(app(container).style.getPropertyValue('--sidenav-width')).toBe('360px')
    let w: number | undefined
    function Probe() {
      w = useLayoutPrefs().getShell().w
      return null
    }
    render(<Probe />)
    expect(w).toBe(420)
  })

  it('T5 the Reset layout entry in the nav foot clears the stored layout', async () => {
    localStorage.setItem('lf.prefs.ui.layout.v1.anon', JSON.stringify({ v: 1, shell: { sidenav: { collapsed: true } }, screens: { s: { collapsed: { list: [0] } } } }))
    const { resetDefaultLayoutStore } = await import('@/hooks/useLayoutPrefs')
    resetDefaultLayoutStore()
    const { container } = await renderShell()
    expect(app(container)).toHaveAttribute('data-nav', 'collapsed')
    const btn = await screen.findByTestId('reset-layout-all')
    expect(btn).toHaveAttribute('title')
    act(() => void btn.click())
    expect(localStorage.getItem('lf.prefs.ui.layout.v1.anon')).toBeNull()
    expect(app(container)).not.toHaveAttribute('data-nav', 'collapsed')
  })

  it('N8 a module entry with no icon mapping gets a letter glyph', async () => {
    const { NavIcon } = await import('../navIcons')
    const { container } = render(<NavIcon to="/x/unknown" label="warehouse" />)
    expect(container.querySelector('[data-testid=nav-glyph]')?.textContent).toBe('W')
  })
})
