// @vitest-environment jsdom
/**
 * Regression test — ISS-0289: web/src/pages/admin/UserDetailPage.tsx existed in
 * the tree but was not reachable from the router. Navigating to
 * /admin/users/:id rendered UsersPage.tsx's partial inline edit branch, which
 * had (a) no platform-admin role gate and (b) no group-membership editing,
 * instead of the dedicated UserDetailPage.tsx.
 *
 * TC-ISS0289-01: router.routes maps the parameterized detail path to
 *   UserDetailPage, not UsersPage; the bare list path still maps to UsersPage.
 *   This directly encodes the bug: pre-fix, router.tsx registered only
 *   `admin/users/:id` -> <UsersPage />, so no route both carried a param and
 *   pointed at UserDetailPage.
 * TC-ISS0289-02: navigating to /admin/users/<id> as a non-platform-admin user
 *   renders the "You do not have permission to manage users." gate, not an
 *   editable form -- the concrete authorization regression SECURITY-REVIEWER
 *   flagged as previously absent (UsersPage's inline branch had no role
 *   gate at all).
 *
 * Both cases resolve "which component renders for this URL" via react-router's
 * own `matchRoutes` / `router.routes` against the real router config in
 * web/src/router.tsx, rather than hardcoding a route-param name -- so the test
 * is agnostic to whether the fix used `:id` or `:userId`.
 */

import type { ReactElement } from 'react'
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup } from '@testing-library/react'
import { MemoryRouter, Routes, Route, matchRoutes } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(() => ({ data: undefined, isLoading: false, isError: false, error: null, refetch: vi.fn() })),
  useMutation: vi.fn(() => ({ mutate: vi.fn(), isPending: false, isError: false })),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

import { useAuth } from '@/auth/AuthContext'
import { router } from '@/router'
import UserDetailPage from '@/pages/admin/UserDetailPage'
import UsersPage from '@/pages/admin/UsersPage'
import { renderWithAccess } from '@/auth/access/testing'

const mockUseAuth = vi.mocked(useAuth)

// ── Fixtures ──────────────────────────────────────────────────────────────────

const NON_ADMIN_SESSION = {
  token: 'tok',
  display_name: 'Regular User',
  loginSource: null as null,
  tenant_slug: 'demo-co',
  tenant_display_name: 'Demo Co',
  tenant_id: 'tid-demo-co',
  tenant_type: 'production' as const,
  production_tenant_display_name: null,
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function rootChildren() {
  const root = router.routes.find((r) => r.path === '/')
  if (!root?.children) throw new Error('root route with children not found in router.routes')
  return root.children
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('ISS-0289 regression — admin/users detail route wiring', () => {
  it('TC-ISS0289-01: parameterized admin/users detail path routes to UserDetailPage; bare admin/users list still routes to UsersPage', () => {
    const children = rootChildren()

    const listRoute = children.find((c) => c.path === 'admin/users')
    expect(listRoute).toBeDefined()
    expect((listRoute!.element as ReactElement).type).toBe(UsersPage)

    // The parameterized detail route: any child path under 'admin/users/' other
    // than the bare list path itself.
    const detailRoute = children.find(
      (c) => typeof c.path === 'string' && c.path.startsWith('admin/users/') && c.path !== 'admin/users',
    )
    expect(detailRoute).toBeDefined()
    expect((detailRoute!.element as ReactElement).type).toBe(UserDetailPage)
    expect((detailRoute!.element as ReactElement).type).not.toBe(UsersPage)
  })

  it('TC-ISS0289-02: navigating to /admin/users/<id> as a non-platform-admin user shows the permission gate, not an editable form', () => {
    mockUseAuth.mockReturnValue({
      session: NON_ADMIN_SESSION,
      isAuthenticated: true,
      isLoading: false,
      loginSource: null,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
    })

    const targetUrl = '/admin/users/user-42'
    const matches = matchRoutes(router.routes, targetUrl)
    expect(matches).not.toBeNull()
    const leaf = matches![matches!.length - 1]

    renderWithAccess(
      <MemoryRouter initialEntries={[targetUrl]}>
        <Routes>
          <Route path={leaf.route.path} element={leaf.route.element as ReactElement} />
        </Routes>
      </MemoryRouter>,
      'taskWorker',
    )

    // VERDICT: permission-denied message is shown for a non-admin user.
    // Pre-fix, this URL resolved to UsersPage.tsx's inline branch, which had NO
    // platform-admin gate at all -- it rendered an editable admin-user-detail-form
    // for ANY authenticated user regardless of role. That is the regression
    // SECURITY-REVIEWER flagged as previously absent.
    expect(screen.getByText('You do not have permission to manage users.')).toBeInTheDocument()
    expect(screen.queryByTestId('admin-user-detail-form')).not.toBeInTheDocument()
  })
})
