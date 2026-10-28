// @vitest-environment jsdom
/**
 * REQ-614 R1/R2 — the print-templates route and nav entry follow DocumentPrintTemplatesManage,
 * and only the tenant-admin and platform-admin fixtures hold it. Fixtures are picked by key.
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

const PATH = 'admin/print-templates'

function renderRoute(fixture: AccessFixtureName) {
  const root = router.routes.find((r) => r.path === '/')
  const element = root?.children?.find((c) => c.path === PATH)?.element
  if (!element) throw new Error('route not found')
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <AccessStateProvider state={accessState(fixture)}>
        <MemoryRouter initialEntries={['/' + PATH]}>
          <Routes>
            <Route path={'/' + PATH} element={element} />
          </Routes>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

let fetchSpy: MockInstance<typeof window.fetch>

beforeEach(() => {
  fetchSpy = vi.spyOn(window, 'fetch').mockImplementation(
    async () => new Response(JSON.stringify({ overrides: [] }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
  )
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

const HOLDERS: AccessFixtureName[] = ['tenantAdmin', 'platformAdmin']
const NON_HOLDERS = (Object.keys(ACCESS_FIXTURES) as AccessFixtureName[]).filter((k) => !HOLDERS.includes(k))

describe('REQ-614 R1 route and nav', () => {
  it('has a nav entry gated by the permission', () => {
    const item = NAV_ITEMS.find((n) => n.to === '/admin/print-templates')
    expect(item?.label).toBe('Print Templates')
    expect(item?.permission).toBe(P.DocumentPrintTemplatesManage)
  })

  it.each(HOLDERS)('%s renders the page', async (fixture) => {
    renderRoute(fixture)
    expect(await screen.findByRole('heading', { name: 'Print templates' })).toBeInTheDocument()
  })

  it.each(NON_HOLDERS)('%s gets PermissionDenied and no request', (fixture) => {
    renderRoute(fixture)
    expect(screen.getByText(/do not have access to this area/)).toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()
  })
})

describe('REQ-614 R2 fixtures', () => {
  it('only the two admin fixtures hold the permission', () => {
    const holders = (Object.keys(ACCESS_FIXTURES) as AccessFixtureName[]).filter((k) =>
      (ACCESS_FIXTURES[k].permissions as readonly string[]).includes(P.DocumentPrintTemplatesManage),
    )
    expect(holders.sort()).toEqual([...HOLDERS].sort())
  })
})
