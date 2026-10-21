// @vitest-environment jsdom
/**
 * Unit tests — ISS-0711 §4: TenantsPage cursor-based pagination
 *
 * lib/letflow/design/iss0711-tenant-count-field-mismatch.md §4 replaces
 * TenantsPage's offset/`total` pagination (broken — the real
 * GET /api/v1/tenants endpoint has never sent `total`/`limit`/`offset`) with
 * the same `cursorStack: string[]` / `PaginationControls` pattern already
 * proven by AuditLogPage.tsx and DlqPage.tsx (see
 * DlqPage.pagination.test.tsx, the direct precedent this file follows).
 *
 * This exercises real forward/back clicks across three server "pages" to
 * confirm the fix genuinely paginates past one page — not just that it
 * compiles against the corrected TenantListResponse type.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, within, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
  useMutation: vi.fn(() => ({
    mutate: vi.fn(),
    isPending: false,
    isError: false,
  })),
  useQueryClient: vi.fn(() => ({
    invalidateQueries: vi.fn(),
  })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import TenantsPage from '@/pages/admin/tenants/TenantsPage'
import type { Tenant, TenantListResponse } from '@/api/tenants'
import { renderWithAccess } from '@/auth/access/testing'

const mockUseQuery = vi.mocked(useQuery)
const mockUseAuth = vi.mocked(useAuth)

// ── Fixtures ──────────────────────────────────────────────────────────────────

const ADMIN_SESSION = {
  token: 'tok',
  display_name: 'Admin',
  loginSource: null as null,
  tenant_slug: 'platform',
  tenant_display_name: 'Platform',
  tenant_id: 'tid-platform',
  tenant_type: 'production' as const,
  production_tenant_display_name: null,
}

function tenant(slug: string): Tenant {
  return {
    slug,
    display_name: `Display ${slug}`,
    idp_realm_id: `${slug}-realm`,
    status: 'ACTIVE',
    created_at: '2026-01-01T00:00:00Z',
    tenant_type: 'production',
    production_tenant_id: null,
    production_tenant_display_name: null,
  }
}

// Three real-shape server "pages" ({items, next_cursor, count}), keyed by the
// cursor that must be sent to fetch them. __page1__ = no cursor yet.
const PAGES: Record<string, TenantListResponse> = {
  __page1__: { items: [tenant('tenant-a')], next_cursor: 'cursor-2', count: 1 },
  'cursor-2': { items: [tenant('tenant-b')], next_cursor: 'cursor-3', count: 1 },
  'cursor-3': { items: [tenant('tenant-c')], next_cursor: null, count: 1 },
}

/** Records every cursor value TenantsPage's useQuery call requested, in call order. */
let requestedCursors: (string | undefined)[]

function installUseQueryMock(): void {
  requestedCursors = []
  mockUseQuery.mockImplementation((opts: unknown) => {
    const { queryKey } = opts as { queryKey: readonly unknown[] }
    const filters = (queryKey[2] ?? {}) as { cursor?: string }
    requestedCursors.push(filters.cursor)
    const page = PAGES[filters.cursor ?? '__page1__']
    return {
      data: page,
      isLoading: false,
      isError: false,
      error: null,
      refetch: vi.fn(),
    } as unknown as ReturnType<typeof useQuery>
  })
}

function renderTenantsPage(): ReturnType<typeof render> {
  return renderWithAccess(
    <MemoryRouter>
      <TenantsPage />
    </MemoryRouter>,
    'platformAdmin',
  )
}

function nextButton(): HTMLElement {
  return within(screen.getByTestId('pagination-next')).getByRole('button')
}

function prevButton(): HTMLElement {
  return within(screen.getByTestId('pagination-prev')).getByRole('button')
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('ISS-0711 §4 — TenantsPage cursor-based pagination', () => {
  it('page 1 with more pages available: pagination controls render, Previous disabled, Next enabled, no cursor sent', () => {
    installUseQueryMock()
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

    renderTenantsPage()

    expect(screen.getByText('Display tenant-a')).toBeInTheDocument()
    expect(screen.getByTestId('tenants-pagination')).toBeInTheDocument()
    expect(prevButton()).toBeDisabled()
    expect(nextButton()).not.toBeDisabled()
    expect(requestedCursors[requestedCursors.length - 1]).toBeUndefined()
  })

  it('forward twice then back once: real clicks page through three server pages, cursor sent each time, Next/Previous disabled-state tracks it', () => {
    installUseQueryMock()
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

    renderTenantsPage()

    // Page 1: seeded by tenant-a.
    expect(screen.getByText('Display tenant-a')).toBeInTheDocument()

    // --- Next -> page 2 ---
    fireEvent.click(nextButton())
    expect(screen.getByText('Display tenant-b')).toBeInTheDocument()
    expect(requestedCursors[requestedCursors.length - 1]).toBe('cursor-2')
    expect(prevButton()).not.toBeDisabled()
    expect(nextButton()).not.toBeDisabled() // page 2's next_cursor is 'cursor-3'

    // --- Next -> page 3 (last page: next_cursor is null) ---
    fireEvent.click(nextButton())
    expect(screen.getByText('Display tenant-c')).toBeInTheDocument()
    expect(requestedCursors[requestedCursors.length - 1]).toBe('cursor-3')
    expect(prevButton()).not.toBeDisabled()
    expect(nextButton()).toBeDisabled() // hasNextPage derived from next_cursor == null

    // --- Previous -> back to page 2 ---
    fireEvent.click(prevButton())
    expect(screen.getByText('Display tenant-b')).toBeInTheDocument()
    expect(requestedCursors[requestedCursors.length - 1]).toBe('cursor-2')
    expect(prevButton()).not.toBeDisabled()
    expect(nextButton()).not.toBeDisabled()
  })

  it('changing the search filter resets pagination to page 1 (cursor stack cleared)', () => {
    installUseQueryMock()
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

    renderTenantsPage()

    // Navigate to page 2 first.
    fireEvent.click(nextButton())
    expect(screen.getByText('Display tenant-b')).toBeInTheDocument()
    expect(prevButton()).not.toBeDisabled()

    // Changing the search input calls handleSearchChange, which must reset
    // cursorStack back to [] (page 1).
    fireEvent.change(screen.getByTestId('tenants-search'), { target: { value: 'acme' } })

    expect(screen.getByText('Display tenant-a')).toBeInTheDocument()
    expect(prevButton()).toBeDisabled()
    expect(requestedCursors[requestedCursors.length - 1]).toBeUndefined()
  })

  it('a single full page with no next_cursor and no prior pages hides pagination controls entirely', () => {
    mockUseQuery.mockReturnValue({
      data: { items: [tenant('only-tenant')], next_cursor: null, count: 1 },
      isLoading: false,
      isError: false,
      error: null,
      refetch: vi.fn(),
    } as unknown as ReturnType<typeof useQuery>)
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

    renderTenantsPage()

    expect(screen.getByText('Display only-tenant')).toBeInTheDocument()
    expect(screen.queryByTestId('tenants-pagination')).not.toBeInTheDocument()
  })
})
