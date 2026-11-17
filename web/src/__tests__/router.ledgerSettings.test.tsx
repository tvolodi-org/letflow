// @vitest-environment jsdom
/**
 * REQ-839 W-R1: the route /admin/ledger-settings and its nav entry exist only for a holder of
 * LedgerSettingsManage. Mirror of router.approvalRules.test.tsx.
 */
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 'header.' + btoa(JSON.stringify({ sub: 'admin-id' })) + '.sig',
        display_name: 'Admin',
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: 'tenant-1',
        tenant_type: null,
      },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import { router } from '@/router'
import { NAV_ITEMS } from '@/components/layout/AppShell'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ACCESS_FIXTURES, accessState, type AccessFixtureName } from '@/auth/access/fixtures'
import { P } from '@/auth/access'
import { NAV_ROLE_PERMISSIONS } from '@/dev/harness/navRoleAccess'

const PATH = 'admin/ledger-settings'

function stateFor(fixture: AccessFixtureName) {
  const base = accessState(fixture)
  if (fixture !== 'tenantAdmin' || base.status !== 'ready') return base
  return { ...base, info: { ...base.info, permissions: [...NAV_ROLE_PERMISSIONS.admin] } } as typeof base
}

function renderRoute(fixture: AccessFixtureName) {
  const root = router.routes.find((r) => r.path === '/')
  const element = root?.children?.find((c) => c.path === PATH)?.element
  if (!element) throw new Error('route not found: ' + PATH)
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={stateFor(fixture)}>
        <MemoryRouter initialEntries={['/' + PATH]}>
          <Routes>
            <Route path={'/' + PATH} element={element} />
          </Routes>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

const HOLDERS: AccessFixtureName[] = ['tenantAdmin']
const NON_HOLDERS = (Object.keys(ACCESS_FIXTURES) as AccessFixtureName[]).filter(
  (k) => !HOLDERS.includes(k) && !(ACCESS_FIXTURES[k].permissions as readonly string[]).includes('LedgerSettingsManage'),
)

let fetchSpy: MockInstance<typeof window.fetch>
beforeEach(() => {
  fetchSpy = vi.spyOn(window, 'fetch').mockImplementation(
    async () => new Response(JSON.stringify({ items: [] }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
  )
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('REQ-839 route and nav', () => {
  it('has a nav entry gated by LedgerSettingsManage', () => {
    const item = NAV_ITEMS.find((n) => n.to === '/admin/ledger-settings')
    expect(item?.label).toBe('Negative balances')
    expect(item?.permission).toBe(P.LedgerSettingsManage)
  })

  it.each(NON_HOLDERS)('%s (a storekeeper among them) gets PermissionDenied and no request', (fixture) => {
    renderRoute(fixture)
    expect(screen.getByText(/do not have access to this area/)).toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it.each(HOLDERS)('%s does not get the no-permission text', async (fixture) => {
    renderRoute(fixture)
    await Promise.resolve()
    expect(screen.queryByText(/do not have access to this area/)).toBeNull()
  })

  it('a storekeeper does not hold the permission', () => {
    expect(NAV_ROLE_PERMISSIONS.storekeeper as readonly string[]).not.toContain('LedgerSettingsManage')
    expect(NAV_ROLE_PERMISSIONS.admin as readonly string[]).toContain('LedgerSettingsManage')
  })
})
