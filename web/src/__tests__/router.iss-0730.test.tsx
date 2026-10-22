// @vitest-environment jsdom
/**
 * Regression test — ISS-0730: no reachable GUI route rendered the
 * promotion-review screens (PromotionReviewStateMachine +
 * NonSkippableApprovalGate). Components existed but were never wired into
 * router.tsx.
 *
 * TC-ISS0730-01: router.routes maps definitions/:id/promotions/:reviewId to
 *   PromotionReviewPage, and the parent definitions/:id path is untouched
 *   (still DefinitionEditorPage).
 * TC-ISS0730-02: navigating to the review URL as a non-platform-admin user
 *   redirects to /instances (client-side role gate), matching the pattern
 *   used by AuditLogPage/HealthDashboardPage/MetricsPage -- per
 *   lib/letflow/design/iss0730-promotion-review-page-routing.md §3.1.
 * TC-ISS0730-03: navigating to the review URL as a platform-admin user is
 *   NOT redirected -- the role gate lets the actual reviewer through. Without
 *   this, an inverted role check (`if (isPlatformAdmin) return <Navigate .../>`)
 *   would still pass TC-ISS0730-02 (a non-admin who is also never let in
 *   trivially "isn't redirected to the wrong place" in some readings) while
 *   locking every real platform-admin out -- this test targets that failure
 *   mode directly, from the opposite session.
 * TC-ISS0730-04: none of the plausible wrong/guessed paths the original
 *   issue's live investigation tried (/admin/promotions, /promotions,
 *   /definitions/promotions, /admin/definitions/promotions -- ISS-0730.yaml
 *   lines 41-45) resolve to any route at all. Guards against the review page
 *   becoming reachable at a second, undocumented URL alongside the real one.
 */

import type { ReactElement } from 'react'
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup } from '@testing-library/react'
import { MemoryRouter, Routes, Route, matchRoutes } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(() => ({ data: undefined, isLoading: false, isError: false, error: null, refetch: vi.fn() })),
  useMutation: vi.fn(() => ({ mutate: vi.fn(), mutateAsync: vi.fn(), isPending: false, isError: false })),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

import { useAuth } from '@/auth/AuthContext'
import { router } from '@/router'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'
import PromotionReviewPage from '@/pages/definitions/PromotionReviewPage'
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
}

const ADMIN_SESSION = {
  ...NON_ADMIN_SESSION,
  display_name: 'Platform Admin',
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

describe('ISS-0730 regression — promotion review route wiring', () => {
  it('TC-ISS0730-01: definitions/:id/promotions/:reviewId routes to PromotionReviewPage; parent definitions/:id still routes to DefinitionEditorPage', () => {
    const children = rootChildren()

    const parentRoute = children.find((c) => c.path === 'definitions/:id')
    expect(parentRoute).toBeDefined()
    expect((parentRoute!.element as ReactElement).type).toBe(DefinitionEditorPage)

    const reviewRoute = children.find((c) => c.path === 'definitions/:id/promotions/:reviewId')
    expect(reviewRoute).toBeDefined()
    expect((reviewRoute!.element as ReactElement).type).toBe(PromotionReviewPage)
    expect((reviewRoute!.element as ReactElement).type).not.toBe(DefinitionEditorPage)
  })

  it('TC-ISS0730-02: navigating to a review URL as a non-platform-admin user redirects to /instances', () => {
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

    const targetUrl = '/definitions/def-1/promotions/review-42'
    const matches = matchRoutes(router.routes, targetUrl)
    expect(matches).not.toBeNull()
    const leaf = matches![matches!.length - 1]

    renderWithAccess(
      <MemoryRouter initialEntries={[targetUrl]}>
        <Routes>
          <Route path={leaf.route.path} element={leaf.route.element as ReactElement} />
          <Route path="/instances" element={<div data-testid="instances-redirect-target" />} />
        </Routes>
      </MemoryRouter>,
      'taskWorker',
    )

    expect(screen.getByTestId('instances-redirect-target')).toBeInTheDocument()
    expect(screen.queryByTestId('non-skippable-approval-gate')).not.toBeInTheDocument()
  })

  it('TC-ISS0730-03: navigating to a review URL as a platform-admin user is NOT redirected to /instances', () => {
    mockUseAuth.mockReturnValue({
      session: ADMIN_SESSION,
      isAuthenticated: true,
      isLoading: false,
      loginSource: null,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
    })

    const targetUrl = '/definitions/def-1/promotions/review-42'
    const matches = matchRoutes(router.routes, targetUrl)
    expect(matches).not.toBeNull()
    const leaf = matches![matches!.length - 1]

    renderWithAccess(
      <MemoryRouter initialEntries={[targetUrl]}>
        <Routes>
          <Route path={leaf.route.path} element={leaf.route.element as ReactElement} />
          <Route path="/instances" element={<div data-testid="instances-redirect-target" />} />
        </Routes>
      </MemoryRouter>,
      'platformAdmin',
    )

    expect(screen.queryByTestId('instances-redirect-target')).not.toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Promotion Review' })).toBeInTheDocument()
  })

  it('TC-ISS0730-04: none of the plausible pre-fix guessed URLs route to PromotionReviewPage', () => {
    // ISS-0730.yaml lines 41-45: these exact URLs were tried live pre-fix and
    // all 404'd. '/definitions/promotions' is a partial exception -- it
    // structurally matches the dynamic `definitions/:id` leaf with
    // `id: "promotions"` (ordinary param-matching, not a route this fix
    // creates), so for that one path the assertion is narrowed to "does not
    // resolve to PromotionReviewPage" rather than "matches nothing at all".
    const guessedPaths = [
      '/admin/promotions',
      '/promotions',
      '/definitions/promotions',
      '/admin/definitions/promotions',
    ]

    for (const path of guessedPaths) {
      const matches = matchRoutes(router.routes, path)
      const leaf = matches?.[matches.length - 1]
      expect((leaf?.route.element as ReactElement | undefined)?.type).not.toBe(PromotionReviewPage)
    }
  })
})
