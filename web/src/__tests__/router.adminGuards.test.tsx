// @vitest-environment jsdom
/** T-1435 R1/R2: the admin pages opened by URL without their permission show only the no-access text. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState, type AccessFixtureName } from '@/auth/access/fixtures'
import { router } from '@/router'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: { token: 'tok', display_name: 'U', loginSource: null, tenant_slug: 'fx', tenant_display_name: 'Fx', tenant_id: 'tid-fx', tenant_type: 'production' },
    logout: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  }),
}))

const PATHS = ['admin/users', 'admin/users/u1', 'admin/groups', 'admin/tokens', 'admin/audit', 'dlq', 'webhooks']

function renderRoute(path: string, fixture: AccessFixtureName) {
  const root = router.routes.find((r) => r.path === '/')
  const element = root?.children?.find((c) => c.path === (path === 'admin/users/u1' ? 'admin/users/:userId' : path))?.element
  if (!element) throw new Error('route not found: ' + path)
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={accessState(fixture)}>
        <MemoryRouter initialEntries={['/' + path]}>
          <Routes>
            <Route path={path === 'admin/users/u1' ? '/admin/users/:userId' : '/' + path} element={element} />
          </Routes>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

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

describe('T-1435 R1 no permission', () => {
  it.each(PATHS)('%s: storekeeper sees only the no-access text', (path) => {
    renderRoute(path, 'storekeeper')
    expect(screen.getByText(/do not have access to this area/)).toBeInTheDocument()
    expect(screen.queryByRole('heading')).toBeNull()
    expect(screen.queryByTestId('admin-users-search')).toBeNull()
    expect(fetchSpy).not.toHaveBeenCalled()
  })
})

describe('T-1435 R2 permitted', () => {
  it.each(PATHS)('%s: tenant admin does not get the no-access text', async (path) => {
    renderRoute(path, 'tenantAdmin')
    await Promise.resolve()
    expect(screen.queryByText(/do not have access to this area/)).toBeNull()
  })
})

describe('T-1435 N1 import entry follows the permission', () => {
  it('the Import data entry is gated by EntitiesRecordsImport, which the storekeeper holds (decision 0081 D4)', async () => {
    const { NAV_ITEMS } = await import('@/components/layout/AppShell')
    const { ACCESS_FIXTURES } = await import('@/auth/access/fixtures')
    const item = NAV_ITEMS.find((n) => n.to === '/admin/import')
    expect(item?.permission).toBe('EntitiesRecordsImport')
    expect(ACCESS_FIXTURES.storekeeper.permissions as readonly string[]).toContain('EntitiesRecordsImport')
    expect(ACCESS_FIXTURES.auditor.permissions as readonly string[]).not.toContain('EntitiesRecordsImport')
  })
})
