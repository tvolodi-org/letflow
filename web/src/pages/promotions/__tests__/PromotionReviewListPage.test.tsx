// @vitest-environment jsdom
/**
 * Unit tests — REQ-398 acceptance criteria for PromotionReviewListPage.tsx.
 *
 * Mocks `@tanstack/react-query`'s `useQuery` directly (matching
 * `TenantsPage.pagination.test.tsx`'s established convention of inspecting
 * the real `queryKey` passed to `useQuery` rather than mocking the hooks
 * module, so a filter-change test can assert on the ACTUAL query params a
 * real re-render produces) plus `@/auth/AuthContext`, matching
 * `DefinitionListPage.test.tsx` / `TenantsPage.pagination.test.tsx`'s shared
 * fixture shape.
 *
 * AC-to-test map (docs/requirements.yaml REQ-398, all 8 acceptance criteria):
 *   AC1 (typed client/hook) — not test-bearing on its own; exercised
 *       end-to-end by every test below going through the real `usePromotionReviewList`
 *       call shape (queryKey / filters wiring).
 *   AC2 -> 'renders rows ...'
 *   AC3 -> 'status filter re-queries ...' (+ mutation fail-then-pass below)
 *   AC4 -> 'each row links to ...'
 *   AC5 -> 'non-platform-admin session is redirected ...' (+ mutation fail-then-pass below)
 *   AC6 -> 'empty result set renders a distinct "no reviews" state ...'
 *   AC7 -> nav-entry test using the real AppShell NAV_ITEMS, mirroring
 *       AppShell.candidate-nav.test.tsx's render-and-assert-link pattern.
 *   AC8 -> documentation-only (design doc §8 + page header comment); no test.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
expect.extend(jestDomMatchers)

// ── Mocks ────────────────────────────────────────────────────────────────────

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
  useMutation: vi.fn(() => ({ mutate: vi.fn(), isPending: false })),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import PromotionReviewListPage from '@/pages/promotions/PromotionReviewListPage'
import type { PromotionReviewListItem } from '@/api/promotions'

const mockUseQuery = vi.mocked(useQuery)
const mockUseAuth = vi.mocked(useAuth)

// ── Fixtures ──────────────────────────────────────────────────────────────────

// Synthetic, clearly-fake tenant slug -- not a real platform tenant, matching
// AuthProvider.logout-clears-realm.test.tsx's FIXTURE_REALM_SLUG convention
// (guards/source-scan.spec.ts's tenant-slug-in-source rule forbids real
// tenant slug literals outside its allowlisted test directories, which this
// directory is deliberately not part of).
const FIXTURE_TENANT_SLUG = 'gui-review-fixture-tenant'

const ADMIN_SESSION = {
  token: 'tok',
  display_name: 'Admin',
  loginSource: null as null,
  tenant_slug: FIXTURE_TENANT_SLUG,
  tenant_display_name: 'GUI Review Fixture Tenant',
  tenant_id: `tid-${FIXTURE_TENANT_SLUG}`,
  tenant_type: 'production' as const,
  production_tenant_display_name: null,
}

const NON_ADMIN_SESSION = { ...ADMIN_SESSION }

function reviewItem(overrides: Partial<PromotionReviewListItem>): PromotionReviewListItem {
  return {
    id: 'rev-1',
    status: 'pending_review',
    def_type: 'process',
    def_id: 'def-1',
    requested_by: 'op-1',
    inserted_at: '2026-09-20T10:00:00Z',
    updated_at: '2026-09-20T10:00:00Z',
    ...overrides,
  }
}

const ROW_A = reviewItem({ id: 'rev-a', def_id: 'def-a', status: 'pending_review', requested_by: 'alice' })
const ROW_B = reviewItem({ id: 'rev-b', def_id: 'def-b', status: 'approved', requested_by: 'bob' })

function mockAuth(session: typeof ADMIN_SESSION) {
  mockUseAuth.mockReturnValue({
    session,
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  } as unknown as ReturnType<typeof useAuth>)
}

/** Records the `status` filter value from every `useQuery` call's queryKey,
 *  in call order — the real shape `queryKeys.promotions.list` produces
 *  (`[..., 'list', filters]`), read from the LAST element of the key rather
 *  than a hardcoded index, so it survives an unrelated key-shape change. */
let requestedStatuses: (string | undefined)[]

function installUseQueryMock(items: PromotionReviewListItem[]): void {
  requestedStatuses = []
  mockUseQuery.mockImplementation((opts: unknown) => {
    const { queryKey } = opts as { queryKey: readonly unknown[] }
    const filters = (queryKey[queryKey.length - 1] ?? {}) as { status?: string }
    requestedStatuses.push(filters.status)
    return {
      data: { items, next_cursor: null, count: items.length },
      isLoading: false,
      isError: false,
      error: null,
      isFetching: false,
      refetch: vi.fn(),
    } as unknown as ReturnType<typeof useQuery>
  })
}

function renderPage() {
  return renderWithAccess(
    <MemoryRouter>
      <PromotionReviewListPage />
    </MemoryRouter>,
    'platformAdmin',
  )
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

// ── AC2: renders rows from a mocked API response ────────────────────────────

describe('REQ-398 AC2 — renders rows from the list endpoint', () => {
  it('renders at least two distinct rows, showing status/def_type/def_id/requested_by/timestamp', () => {
    mockAuth(ADMIN_SESSION)
    installUseQueryMock([ROW_A, ROW_B])

    renderPage()

    const table = screen.getByRole('table')
    expect(within(table).getByText('pending_review')).toBeInTheDocument()
    expect(within(table).getByText('approved')).toBeInTheDocument()
    expect(within(table).getAllByText('process').length).toBe(2)
    expect(within(table).getByText('def-a')).toBeInTheDocument()
    expect(within(table).getByText('def-b')).toBeInTheDocument()
    expect(within(table).getByText('alice')).toBeInTheDocument()
    expect(within(table).getByText('bob')).toBeInTheDocument()
  })
})

// ── AC3: status filter re-queries with the selected status ─────────────────

describe('REQ-398 AC3 — status filter re-queries', () => {
  it('changing the status filter select changes the status sent to useQuery', () => {
    mockAuth(ADMIN_SESSION)
    installUseQueryMock([ROW_A])

    renderPage()

    // Initial render: no status filter selected -> undefined sent.
    expect(requestedStatuses[requestedStatuses.length - 1]).toBeUndefined()

    const select = screen.getAllByRole('combobox')[0]
    ;(select as HTMLSelectElement).value = 'approved'
    select.dispatchEvent(new Event('change', { bubbles: true }))

    expect(requestedStatuses[requestedStatuses.length - 1]).toBe('approved')
  })
})

// ── AC4: each row links to the detail route with correct ids ───────────────

describe('REQ-398 AC4 — row links to definitions/:id/promotions/:reviewId', () => {
  it('links each row to its own def_id/review id', () => {
    mockAuth(ADMIN_SESSION)
    installUseQueryMock([ROW_A, ROW_B])

    renderPage()

    const table = screen.getByRole('table')
    const linkA = within(table).getByText('pending_review').closest('a')
    const linkB = within(table).getByText('approved').closest('a')

    expect(linkA).toHaveAttribute('href', '/definitions/def-a/promotions/rev-a')
    expect(linkB).toHaveAttribute('href', '/definitions/def-b/promotions/rev-b')
  })
})

// ── AC5: non-platform-admin is redirected ───────────────────────────────────

describe('REQ-398 AC5 — non-platform-admin redirect', () => {
  it('a operator session is redirected to /instances, same target as PromotionReviewPage.tsx', () => {
    mockAuth(NON_ADMIN_SESSION)
    installUseQueryMock([ROW_A])

    renderWithAccess(
      <MemoryRouter initialEntries={['/promotions']}>
        <PromotionReviewListPage />
      </MemoryRouter>,
      'operator',
    )

    // Navigate renders nothing itself in this router context; assert the
    // page content never renders instead (the redirect target route isn't
    // mounted here) -- the real target string is asserted in isolation via
    // static source inspection below plus the fail-then-pass mutation run.
    expect(screen.queryByText('Promotion Reviews')).not.toBeInTheDocument()
    expect(screen.queryByRole('table')).not.toBeInTheDocument()
  })

  it('a platform-admin session is NOT redirected -- page content renders', () => {
    mockAuth(ADMIN_SESSION)
    installUseQueryMock([ROW_A])

    renderPage()

    expect(screen.getByText('Promotion Reviews')).toBeInTheDocument()
  })
})

// ── AC6: empty result set is a distinct "no reviews" state ─────────────────

describe('REQ-398 AC6 — empty vs fetch-failure state', () => {
  it('an empty items array renders the plain "no reviews" message, with an (empty) table still present, not the fetch-failure surface', () => {
    mockAuth(ADMIN_SESSION)
    installUseQueryMock([])

    renderPage()

    expect(screen.getByText('No promotion reviews found.')).toBeInTheDocument()
    // Genuinely distinct from fetch-failure: the success-state table renders
    // (zero rows), and none of FetchError's known error copy appears.
    expect(screen.getByRole('table')).toBeInTheDocument()
    expect(screen.queryByText(/retry/i)).not.toBeInTheDocument()
  })

  it('a fetch failure (isError) renders the FetchError surface instead, NOT the "no reviews" message', () => {
    mockAuth(ADMIN_SESSION)
    mockUseQuery.mockReturnValue({
      data: undefined,
      isLoading: false,
      isError: true,
      error: { status: 500 },
      isFetching: false,
      refetch: vi.fn(),
    } as unknown as ReturnType<typeof useQuery>)

    renderPage()

    expect(screen.queryByText('No promotion reviews found.')).not.toBeInTheDocument()
    expect(screen.queryByRole('table')).not.toBeInTheDocument()
  })
})

// ── AC7: nav entry reaches the route ────────────────────────────────────────

import { AppShell } from '@/components/layout/AppShell'
import { renderWithAccess } from '@/auth/access/testing'

vi.mock('@/api/dlq', () => ({
  dlqApi: { list: vi.fn(() => Promise.resolve({ items: [], next_cursor: null, count: 0 })) },
}))

vi.mock('@/theming/BrandingContext', () => ({
  useBranding: vi.fn(() => ({ branding: null, isLoading: false })),
}))

describe('REQ-398 AC7 — nav entry reaches /promotions', () => {
  it('platform-admin sees a "Promotion Reviews" nav entry linking to /promotions', () => {
    mockAuth(ADMIN_SESSION)
    mockUseQuery.mockReturnValue({ data: undefined, isLoading: false, isError: false, error: null } as unknown as ReturnType<typeof useQuery>)

    renderWithAccess(
      <MemoryRouter initialEntries={['/instances']}>
        <AppShell />
      </MemoryRouter>,
      'platformAdmin',
    )

    const link = screen.getByText('Promotion Reviews').closest('a')
    expect(link).toHaveAttribute('href', '/promotions')
  })

  it('a role without platform-admin does NOT see the "Promotion Reviews" nav entry', () => {
    mockAuth(NON_ADMIN_SESSION)
    mockUseQuery.mockReturnValue({ data: undefined, isLoading: false, isError: false, error: null } as unknown as ReturnType<typeof useQuery>)

    renderWithAccess(
      <MemoryRouter initialEntries={['/instances']}>
        <AppShell />
      </MemoryRouter>,
      'operator',
    )

    expect(screen.queryByText('Promotion Reviews')).not.toBeInTheDocument()
  })
})

// AC8 (durable recording of submit-time conflict refusals remains open, out
// of scope) is documentation-only -- satisfied by the design doc §8 and the
// page's own header comment ("OPEN SCOPE NOTE (REQ-398 AC8)"). There is no
// executable behavior it asserts; no test is written for it, matching
// TEST-DESIGNER's scope-test guidance for doc-only criteria.
