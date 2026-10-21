// @vitest-environment jsdom
/**
 * Unit tests — REQ-277: DlqPage cursor-stack-to-page pagination adaptation
 *
 * REQ-277's design (lib/letflow/design/req277-page-migration-definitions-dlq.md §5.3)
 * wraps DlqPage's pre-existing `cursorStack: string[]` / `goNext` / `goPrev` state as a
 * synthesized 1-indexed `page` for `PaginationControls`:
 *
 *   page := cursorStack.length + 1
 *   hasNextPage := data?.next_cursor != null
 *   onPageChange := (nextPage) => (nextPage > page ? goNext() : goPrev())
 *
 * This is the one piece of genuinely new logic this migration introduced (everything
 * else is a primitive swap with no behavioral change) — REVIEWER's sign-off was a
 * read-through, not an executed test, so this file exercises it directly: forward twice,
 * back once, confirming the page counter, the cursor sent in each query, Previous/Next
 * disabled-state, and that applying a filter resets pagination to page 1.
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
import DlqPage from '@/pages/dlq/DlqPage'
import type { CursorPage, DlqEntry } from '@/types/api'

const mockUseQuery = vi.mocked(useQuery)
const mockUseAuth = vi.mocked(useAuth)

// ── Fixtures ──────────────────────────────────────────────────────────────────

const SESSION = {
  token: 'tok',
  display_name: 'Operator',
  loginSource: null as null,
  tenant_slug: 'test-tenant',
  tenant_display_name: 'Test Tenant',
  tenant_id: 'tid-test-tenant',
  tenant_type: 'production' as const,
  production_tenant_display_name: null,
}

function entry(id: string): DlqEntry {
  return {
    id,
    entry_type: 'event',
    reason: `reason-${id}`,
    retry_count: 0,
    created_at: '2026-01-01T00:00:00Z',
    status: 'pending',
  }
}

// Three server "pages", keyed by the cursor that must be sent to fetch them.
// undefined = page 1 (no cursor yet), 'cursor-2' = page 2, 'cursor-3' = page 3.
// count = items in this page (Pagination.Page wire shape: {items, next_cursor, count}).
const PAGES: Record<string, CursorPage<DlqEntry>> = {
  __page1__: { items: [entry('e1')], next_cursor: 'cursor-2', count: 1 },
  'cursor-2': { items: [entry('e2')], next_cursor: 'cursor-3', count: 1 },
  'cursor-3': { items: [entry('e3')], next_cursor: null, count: 1 },
}

/** Records every cursor value DlqPage's useQuery call requested, in call order. */
let requestedCursors: (string | undefined)[]

function installUseQueryMock(): void {
  requestedCursors = []
  mockUseQuery.mockImplementation((opts: unknown) => {
    const { queryKey } = opts as { queryKey: readonly unknown[] }
    // REQ-384 §7.1: queryKeys.dlq.list is now tenant-prefixed —
    // ['tenant', tenantId, 'dlq', 'list', filters] — so filters is at index
    // 4, not 2.
    const filters = (queryKey[4] ?? {}) as { cursor?: string }
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

function renderDlqPage(): ReturnType<typeof render> {
  return render(
    <MemoryRouter>
      <DlqPage />
    </MemoryRouter>,
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

describe('REQ-277 — DlqPage pagination adaptation (cursor-stack -> PaginationControls page)', () => {
  it('page 1: Previous disabled, Next enabled, no cursor sent', () => {
    installUseQueryMock()
    mockUseAuth.mockReturnValue({
      session: SESSION,
      isAuthenticated: true,
      isLoading: false,
      loginSource: null,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
    })

    renderDlqPage()

    expect(screen.getByText('reason-e1')).toBeInTheDocument()
    expect(prevButton()).toBeDisabled()
    expect(nextButton()).not.toBeDisabled()
    expect(requestedCursors[requestedCursors.length - 1]).toBeUndefined()
  })

  it('forward twice then back once: page counter, cursor sent, and Next/Previous disabled-state track it', () => {
    installUseQueryMock()
    mockUseAuth.mockReturnValue({
      session: SESSION,
      isAuthenticated: true,
      isLoading: false,
      loginSource: null,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
    })

    renderDlqPage()

    // Page 1: seeded by e1's reason text.
    expect(screen.getByText('reason-e1')).toBeInTheDocument()

    // --- Next -> page 2 ---
    fireEvent.click(nextButton())
    expect(screen.getByText('reason-e2')).toBeInTheDocument()
    expect(requestedCursors[requestedCursors.length - 1]).toBe('cursor-2')
    expect(prevButton()).not.toBeDisabled()
    expect(nextButton()).not.toBeDisabled() // page 2's next_cursor is 'cursor-3'

    // --- Next -> page 3 (last page: next_cursor is null) ---
    fireEvent.click(nextButton())
    expect(screen.getByText('reason-e3')).toBeInTheDocument()
    expect(requestedCursors[requestedCursors.length - 1]).toBe('cursor-3')
    expect(prevButton()).not.toBeDisabled()
    expect(nextButton()).toBeDisabled() // hasNextPage derived from next_cursor == null

    // --- Previous -> back to page 2 ---
    fireEvent.click(prevButton())
    expect(screen.getByText('reason-e2')).toBeInTheDocument()
    expect(requestedCursors[requestedCursors.length - 1]).toBe('cursor-2')
    expect(prevButton()).not.toBeDisabled()
    expect(nextButton()).not.toBeDisabled()
  })

  it('applying a filter resets pagination to page 1 (cursor stack cleared)', () => {
    installUseQueryMock()
    mockUseAuth.mockReturnValue({
      session: SESSION,
      isAuthenticated: true,
      isLoading: false,
      loginSource: null,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
    })

    renderDlqPage()

    // Navigate to page 2 first.
    fireEvent.click(nextButton())
    expect(screen.getByText('reason-e2')).toBeInTheDocument()
    expect(prevButton()).not.toBeDisabled()

    // Apply a filter (search text + Apply button) — DlqPage's applyFilters()
    // calls setCursorStack([]), which must bring us back to page 1.
    fireEvent.change(screen.getByTestId('dlq-filter-search'), { target: { value: 'timeout' } })
    fireEvent.click(screen.getByTestId('dlq-filter-apply'))

    expect(screen.getByText('reason-e1')).toBeInTheDocument()
    expect(prevButton()).toBeDisabled()
    expect(requestedCursors[requestedCursors.length - 1]).toBeUndefined()
  })
})
