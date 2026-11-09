// @vitest-environment jsdom
/**
 * T-1522 / D-114(1): the walk. For each role the real AppShell and the real route tree (guards included) render with the
 * role's access set; every link the sidebar shows is opened and the page must be neither the permission-denied page, the
 * access-error page nor the not-found page. Same screens and access sets as the harness screens nav-role-* (shots).
 * Direct URLs stay refused: a storekeeper opening an org page gets the permission-denied page.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { AppShell } from '../AppShell'
import { appRoutes } from '@/router'
import { ALL_MODULE_IDS, NAV_ROLE_PERMISSIONS, type NavRole } from '@/dev/harness/navRoleAccess'
expect.extend(jestDomMatchers)

const auth = {
  session: { tenant_id: 't1', token: 't', display_name: 'Test User', loginSource: null, tenant_slug: 'demo', tenant_display_name: 'Demo', tenant_type: 'production' },
  isAuthenticated: true, isLoading: false, loginSource: null,
  login: async () => undefined, logout: () => undefined, setSession: () => undefined,
  switchTenant: async () => 'ok', switchingToTenantSlug: null,
} as unknown as AuthContextValue

function reply(url: string): Response {
  const body = url.includes('/api/v1/me/modules')
    ? { installed_modules: ALL_MODULE_IDS.map((m) => ({ module_id: m, version: '1' })) }
    : { items: [], rows: [], next_cursor: null, count: 0 }
  return new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' } })
}

beforeEach(() => {
  vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => Promise.resolve(reply(String(input instanceof Request ? input.url : input)))))
})
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

function Pages() {
  const children = appRoutes.find((r) => r.path === '/')?.children ?? []
  return useRoutes([{ element: <AppShell />, children }])
}

function mount(role: NavRole, at: string) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <AuthContext.Provider value={auth}>
        <AccessStateProvider state={{ status: 'ready', info: { roles: [], platform_tenant: false, permissions: [...NAV_ROLE_PERMISSIONS[role]] } }}>
          <MemoryRouter initialEntries={[at]}>
            <Pages />
          </MemoryRouter>
        </AccessStateProvider>
      </AuthContext.Provider>
    </QueryClientProvider>,
  )
}

/** The sidebar links of the Main nav. */
function navLinks(): { href: string; label: string }[] {
  return Array.from(screen.getByRole('navigation', { name: 'Main' }).querySelectorAll('a')).map((a) => ({ href: a.getAttribute('href') ?? '', label: a.textContent ?? '' }))
}

const REFUSED = ['permission-denied', 'access-error', 'not-found-page']

const EXPECTED_COUNT: Record<NavRole, number> = { admin: 36, storekeeper: 7, worker: 3, scoped: 1 }

describe('T-1522 walk: every visible sidebar entry opens a page, for each role', () => {
  it.each(['admin', 'storekeeper', 'worker', 'scoped'] as const)('%s', async (role) => {
    const first = mount(role, '/')
    await waitFor(() => expect(navLinks().length).toBe(EXPECTED_COUNT[role]))
    const links = navLinks()
    first.unmount()
    for (const link of links) {
      const view = mount(role, link.href)
      await waitFor(() => expect(screen.getByRole('navigation', { name: 'Main' })).toBeInTheDocument())
      // let the guards and lazy module routes settle
      await waitFor(() => expect(screen.getByRole('main')).toBeInTheDocument())
      await new Promise((r) => setTimeout(r, 30))
      for (const id of REFUSED) expect(screen.queryByTestId(id), `${role}: ${link.label} (${link.href}) shows ${id}`).toBeNull()
      view.unmount()
    }
  }, 240_000)

  it('negative control: a storekeeper opening an org page directly is refused by the guard', async () => {
    mount('storekeeper', '/admin/org/units')
    await waitFor(() => expect(screen.getByTestId('permission-denied')).toBeInTheDocument())
  })

  it('negative control: a task worker opening Import data directly is refused', async () => {
    mount('worker', '/admin/import')
    await waitFor(() => expect(screen.getByTestId('permission-denied')).toBeInTheDocument())
  })
})
