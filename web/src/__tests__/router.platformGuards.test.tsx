// @vitest-environment jsdom
/**
 * Router-level test — GH #2238 slice 2a (REQ-450): platform pages are guarded by RequirePermission.
 *
 * A direct URL to a platform page as a non-platform admin renders PermissionDenied and mounts
 * neither the page nor its data hooks, so no request reaches the resource. A platform admin still
 * renders each page. Every platformOnly NAV_ITEMS target has a route guarded by the same
 * permission and platformOnly flag as its nav entry.
 */

import type { ReactElement } from 'react'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState, type AccessFixtureName } from '@/auth/access/fixtures'
import { P, RequirePermission, type Permission } from '@/auth/access'
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

interface GuardedRoute {
  /** The route's path in router.tsx. */
  path: string
  /** A concrete URL for the path, so that route params resolve. */
  url: string
  permission: Permission
}

// Each entry: the permission and platformOnly flag that its nav entry (AppShell NAV_ITEMS) uses.
// /admin/onboarding and /admin/tenants/:slug/edit render the same platform pages as their nav
// targets, so they carry the same guard.
const GUARDED_ROUTES: GuardedRoute[] = [
  { path: 'admin/tenants', url: '/admin/tenants', permission: P.TenantsManage },
  { path: 'admin/onboarding/new', url: '/admin/onboarding/new', permission: P.TenantsManage },
  { path: 'admin/onboarding', url: '/admin/onboarding', permission: P.TenantsManage },
  { path: 'admin/tenants/:slug/edit', url: '/admin/tenants/acme/edit', permission: P.TenantsManage },
  { path: 'admin/platform-migrations', url: '/admin/platform-migrations', permission: P.TenantsManage },
  { path: 'admin/event-retention', url: '/admin/event-retention', permission: P.TenantsManage },
  { path: 'admin/health', url: '/admin/health', permission: P.TenantsManage },
  { path: 'admin/services', url: '/admin/services', permission: P.PlatformServicesManage },
]

function rootChildren() {
  const root = router.routes.find((r) => r.path === '/')
  if (!root?.children) throw new Error('root route with children not found in router.routes')
  return root.children
}

function findRoute(path: string) {
  return rootChildren().find((c) => c.path === path)
}

function renderRoute(route: GuardedRoute, fixture: AccessFixtureName) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const element = findRoute(route.path)?.element
  if (!element) throw new Error(`no route element for ${route.path}`)
  return render(
    <QueryClientProvider client={queryClient}>
      <AccessStateProvider state={accessState(fixture)}>
        <MemoryRouter initialEntries={[route.url]}>
          <Routes>
            <Route path={route.path} element={element} />
          </Routes>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

let fetchSpy: MockInstance<typeof window.fetch>

beforeEach(() => {
  fetchSpy = vi.spyOn(window, 'fetch').mockImplementation(async () =>
    new Response(JSON.stringify({ items: [] }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
  )
})

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('GH 2238 slice 2a — platform route guards', () => {
  it.each(GUARDED_ROUTES)('$path: non-platform tenant admin gets PermissionDenied and no request', (route) => {
    renderRoute(route, 'tenantAdmin')
    expect(screen.getByText(/do not have access to this area/)).toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it.each(GUARDED_ROUTES)('$path: platform admin still renders the page', (route) => {
    const { container } = renderRoute(route, 'platformAdmin')
    expect(screen.queryByText(/do not have access to this area/)).toBeNull()
    expect(container.innerHTML).not.toBe('')
  })

  it('every platformOnly NAV_ITEMS target has a route guarded by the same permission and platformOnly', () => {
    const platformItems = NAV_ITEMS.filter((n) => n.platformOnly)
    expect(platformItems.length).toBeGreaterThan(0)
    for (const item of platformItems) {
      const route = findRoute(item.to.slice(1))
      expect(route, item.to).toBeDefined()
      const element = route!.element as ReactElement
      expect(element.type, item.to).toBe(RequirePermission)
      expect(element.props, item.to).toMatchObject({ permission: item.permission, platformOnly: true })
    }
  })
})
