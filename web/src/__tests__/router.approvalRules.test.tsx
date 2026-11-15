// @vitest-environment jsdom
/**
 * T-1989 W-R1: /admin/approval-rules renders the no-permission state for a user without
 * ApprovalRulesManage; the nav item is hidden for that user.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ACCESS_FIXTURES, accessState, type AccessFixtureName } from '@/auth/access/fixtures'
import { P } from '@/auth/access'
import { NAV_ITEMS } from '@/components/layout/AppShell'
import { NAV_ROLE_PERMISSIONS } from '@/dev/harness/navRoleAccess'
import { router } from '@/router'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: {
      token: 'tok',
      display_name: 'Test User',
      loginSource: null,
      tenant_slug: 'fixture-co',
      tenant_display_name: 'Fixture Co',
      tenant_id: 'tid-fixture-co',
      tenant_type: 'production',
    },
    logout: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  }),
}))

const PATH = 'admin/approval-rules'

/** The tenantAdmin base fixture predates the module atoms; its full set is the harness's `admin` role screen. */
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

// INV-10: platform authority does not hold a tenant-scope atom; only the tenant administrator does.
const HOLDERS: AccessFixtureName[] = ['tenantAdmin']
const NON_HOLDERS = (Object.keys(ACCESS_FIXTURES) as AccessFixtureName[]).filter(
  (k) => !HOLDERS.includes(k) && !(ACCESS_FIXTURES[k].permissions as readonly string[]).includes('ApprovalRulesManage'),
)

let fetchSpy: MockInstance<typeof window.fetch>
beforeEach(() => {
  fetchSpy = vi.spyOn(window, 'fetch').mockImplementation(
    async () =>
      new Response(JSON.stringify({ items: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
  )
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('T-1989 W-R1: route and nav', () => {
  it('has a nav entry gated by ApprovalRulesManage', () => {
    const item = NAV_ITEMS.find((n) => n.to === '/admin/approval-rules')
    expect(item?.label).toBe('Approval rules')
    expect(item?.permission).toBe(P.ApprovalRulesManage)
  })

  it.each(NON_HOLDERS)('%s gets PermissionDenied and no request', (fixture) => {
    renderRoute(fixture)
    expect(screen.getByText(/do not have access to this area/)).toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it.each(HOLDERS)('%s does not get the no-permission text', async (fixture) => {
    renderRoute(fixture)
    await Promise.resolve()
    expect(screen.queryByText(/do not have access to this area/)).toBeNull()
  })

  it('only the tenant administrator holds ApprovalRulesManage', () => {
    const holders = (Object.keys(ACCESS_FIXTURES) as AccessFixtureName[]).filter((k) => {
      const s = stateFor(k)
      return s.status === 'ready' && (s.info.permissions as readonly string[]).includes(P.ApprovalRulesManage)
    })
    expect(holders.sort()).toEqual([...HOLDERS].sort())
  })
})
