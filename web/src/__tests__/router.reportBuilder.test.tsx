// @vitest-environment jsdom
/**
 * REQ-634 G1-G3 — the report builder route is wrapped in RequirePermission(EntitiesQuery):
 * a fixture without it gets PermissionDenied and the page makes no request.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ACCESS_FIXTURES, accessState, type AccessFixtureName } from '@/auth/access/fixtures'
import { P } from '@/auth/access'
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

const PATTERN = 'entities/:entityType/reports'

function renderRoute(fixture: AccessFixtureName) {
  const root = router.routes.find((r) => r.path === '/')
  const element = root?.children?.find((c) => c.path === PATTERN)?.element
  if (!element) throw new Error('route not found')
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <AccessStateProvider state={accessState(fixture)}>
        <MemoryRouter initialEntries={['/entities/orders/reports']}>
          <Routes>
            <Route path={'/' + PATTERN} element={element} />
          </Routes>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

let fetchSpy: MockInstance<typeof window.fetch>

beforeEach(() => {
  fetchSpy = vi.spyOn(window, 'fetch').mockImplementation(
    async () =>
      new Response(JSON.stringify({ items: [] }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
  )
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

const HOLDERS = (Object.keys(ACCESS_FIXTURES) as AccessFixtureName[]).filter((k) =>
  (ACCESS_FIXTURES[k].permissions as readonly string[]).includes(P.EntitiesQuery),
)
const NON_HOLDERS = (Object.keys(ACCESS_FIXTURES) as AccessFixtureName[]).filter((k) => !HOLDERS.includes(k))

describe('REQ-634 report builder route guard', () => {
  it('G1 the route exists next to entities/:entityType', () => {
    const root = router.routes.find((r) => r.path === '/')
    expect(root?.children?.some((c) => c.path === PATTERN)).toBe(true)
  })

  it('G2 some fixtures lack EntitiesQuery (the test is not vacuous)', () => {
    expect(NON_HOLDERS.length).toBeGreaterThan(0)
  })

  it.each(NON_HOLDERS)('G2 %s gets PermissionDenied and zero client calls', (fixture) => {
    renderRoute(fixture)
    expect(screen.getByText(/do not have access to this area/)).toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it.each(HOLDERS)('G3 %s renders the page heading', async (fixture) => {
    renderRoute(fixture)
    expect(await screen.findByRole('heading', { name: /Reports: orders/ })).toBeInTheDocument()
  })
})
