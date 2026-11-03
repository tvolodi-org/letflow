// @vitest-environment jsdom
/** D-083: the switcher sits in the TopBar and the left menu follows it in en, ru, kk. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import type { UserSession } from '@/types/api'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { navMessages } from '../navMessages'
import { UI_LOCALES } from '@/i18n/uiLocaleStore'
import { NAV_ITEMS } from '../AppShell'

expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({ useQuery: vi.fn(() => ({ data: undefined })) }))
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

beforeEach(() => {
  window.localStorage.clear()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  window.localStorage.clear()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

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
              <Route path="/instances" element={<div>page</div>} />
            </Route>
          </Routes>
        </AccessStateProvider>
      </BrandingProvider>
    </MemoryRouter>,
  )
}

describe('AppShell language switch', () => {
  it('has the switcher in the TopBar with the three languages', async () => {
    await renderShell()
    const bar = screen.getByTestId('topbar')
    await userEvent.click(within(bar).getByTestId('language-switcher-trigger'))
    for (const name of ['English', 'Русский', 'Қазақша']) {
      expect(within(bar).getByRole('menuitemradio', { name: new RegExp(name) })).toBeInTheDocument()
    }
  })

  it('choosing a language relabels the menu at once and persists', async () => {
    await renderShell()
    const nav = screen.getByRole('navigation', { name: 'Main' })
    expect(within(nav).getByText('My Tasks')).toBeInTheDocument()
    await userEvent.click(screen.getByTestId('language-switcher-trigger'))
    await userEvent.click(screen.getByRole('menuitemradio', { name: /Русский/ }))
    expect(within(nav).getByText(navMessages.ru.items['/tasks'])).toBeInTheDocument()
    expect(within(nav).getByText(navMessages.ru.groups.work)).toBeInTheDocument()
    expect(window.localStorage.getItem('lf-locale')).toBe('ru')
    await userEvent.click(screen.getByTestId('language-switcher-trigger'))
    await userEvent.click(screen.getByRole('menuitemradio', { name: /Қазақша/ }))
    expect(within(nav).getByText(navMessages.kk.items['/tasks'])).toBeInTheDocument()
    expect(window.localStorage.getItem('lf-locale')).toBe('kk')
  })

  it('keyboard: arrows and Escape work in the TopBar switcher', async () => {
    await renderShell()
    const user = userEvent.setup()
    const trigger = screen.getByTestId('language-switcher-trigger')
    trigger.focus()
    await user.keyboard('{ArrowDown}{ArrowDown}')
    expect(screen.getByRole('menuitemradio', { name: /English/ })).toHaveFocus()
    await user.keyboard('{Escape}')
    expect(trigger).toHaveFocus()
  })
})

describe('nav catalog', () => {
  it('every NAV_ITEMS route and group has a word in en, ru and kk', () => {
    for (const l of UI_LOCALES) {
      for (const n of NAV_ITEMS) expect(navMessages[l].items[n.to], `${l} ${n.to}`).toBeTruthy()
      expect(Object.values(navMessages[l].groups).every(Boolean)).toBe(true)
    }
  })
})
