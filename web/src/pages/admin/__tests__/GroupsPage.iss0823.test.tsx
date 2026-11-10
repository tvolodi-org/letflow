// @vitest-environment jsdom
/**
 * ISS-0823: GroupsPage Add-member dropdown truncation warning.
 * ISS-0816/ISS-0828: GroupsPage members list truncation warning.
 *
 * NOTE (ISS-0824/GH-1817): GroupsPage CANNOT be tested with a real
 * QueryClientProvider in jsdom. When the members or users query is backed by
 * a never-resolving promise (the natural state of an unresolved mock), real
 * react-query's retry logic spins the jsdom event loop indefinitely.
 * This is a jsdom harness artifact, NOT a production render loop:
 *   - Production: queries resolve (or fail with HTTP errors) normally
 *   - jsdom: never-resolving promises cause react-query to retry forever
 * All GroupsPage tests must use the mocked-useQuery pattern (vi.mock
 * '@tanstack/react-query') and NEVER use a real QueryClientProvider.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor } from '@testing-library/react'
import { renderWithAccess } from '@/auth/access/testing'
import userEvent from '@testing-library/user-event'
import React from 'react'
import type { UseQueryResult } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

// ── Mocks ─────────────────────────────────────────────────────────────────────

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(() => ({
    session: {
      token: 'tok',
      display_name: 'Admin',
      loginSource: null,
      tenant_slug: 'demo-corp',
      tenant_display_name: 'Acme',
      tenant_id: 'tid-1',
      tenant_type: 'production',
    },
  })),
}))

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return {
    ...actual,
    useNavigate: vi.fn(() => vi.fn()),
  }
})

// ── Controlled useQuery mock ──────────────────────────────────────────────────

const mockUseQuery = vi.fn()
const mockUseMutation = vi.fn(() => ({
  mutate: vi.fn(),
  mutateAsync: vi.fn(),
  isPending: false,
  isError: false,
  error: null,
}))
const mockUseQueryClient = vi.fn(() => ({ invalidateQueries: vi.fn() }))

vi.mock('@tanstack/react-query', () => ({
  useQuery: (opts: unknown) => mockUseQuery(opts),
  useMutation: () => mockUseMutation(),
  useQueryClient: () => mockUseQueryClient(),
}))

vi.mock('@/api/useTenantScopedQueryKeys', () => ({
  useTenantScopedQueryKeys: vi.fn(() => ({
    admin: {
      groups: () => ['groups'],
      roleGrants: () => ['roleGrants'],
      groupMembers: (id: string) => ['groupMembers', id],
      users: (f: unknown) => ['users', f],
      roles: () => ['roles'],
    },
  })),
}))

// ── Component under test ──────────────────────────────────────────────────────

import GroupsPage from '../GroupsPage'

// ── Fixtures ──────────────────────────────────────────────────────────────────

const SAMPLE_GROUP = {
  id: 'g-1',
  group_id: 'g-1',
  name: 'operators',
  display_name: 'Operators',
  description: null,
  is_system: false,
  member_count: 0,
}

function makeUser(i: number) {
  return {
    id: `u-${i}`,
    username: `user${i}`,
    display_name: `User ${i}`,
    email: `user${i}@example.com`,
    status: 'active' as const,
    auth_source: 'internal',
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
  }
}

/** Install useQuery mock that returns controlled data per queryKey prefix */
function installQueryMock(usersNextCursor: string | null, membersNextCursor: string | null = null) {
  mockUseQuery.mockImplementation((opts: unknown) => {
    const { queryKey } = opts as { queryKey: unknown[] }
    if (Array.isArray(queryKey) && queryKey[0] === 'groups') {
      return {
        data: { items: [SAMPLE_GROUP], total: 1 },
        isLoading: false,
        isError: false,
        error: null,
        refetch: vi.fn(),
      } as unknown as UseQueryResult
    }
    if (Array.isArray(queryKey) && queryKey[0] === 'groupMembers') {
      return {
        data: { items: [], next_cursor: membersNextCursor, count: membersNextCursor ? 51 : 0 },
        isLoading: false,
        isError: false,
        error: null,
      } as unknown as UseQueryResult
    }
    if (Array.isArray(queryKey) && queryKey[0] === 'users') {
      return {
        data: {
          items: Array.from({ length: 3 }, (_, i) => makeUser(i)),
          next_cursor: usersNextCursor,
          total: usersNextCursor ? 201 : 3,
        },
        isLoading: false,
        isError: false,
        error: null,
      } as unknown as UseQueryResult
    }
    return { data: undefined, isLoading: false, isError: false, error: null } as unknown as UseQueryResult
  })
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('ISS-0823 — GroupsPage Add-member user list (superseded by T-1610: search result, not first 200)', () => {
  it('TC-ISS0823-01: T-1610 replaced the 200-user warning by a "more users match" note when next_cursor is set', async () => {
    installQueryMock('cursor-page-2')
    renderWithAccess(React.createElement(GroupsPage))

    const user = userEvent.setup()
    await waitFor(() => screen.getByText('Manage members'))
    await user.click(screen.getByText('Manage members'))

    await waitFor(() => {
      expect(screen.getByTestId('more-users-match-note')).toBeInTheDocument()
    })
    expect(screen.queryByTestId('user-list-truncated-warning')).not.toBeInTheDocument()
  })

  it('TC-ISS0823-02: no note when usersApi.list returns next_cursor: null', async () => {
    installQueryMock(null)
    renderWithAccess(React.createElement(GroupsPage))

    const user = userEvent.setup()
    await waitFor(() => screen.getByText('Manage members'))
    await user.click(screen.getByText('Manage members'))

    await waitFor(() => {
      expect(screen.queryByTestId('more-users-match-note')).not.toBeInTheDocument()
    })
  })

  it('TC-ISS0823-03: the picker lists the fixture users as checkboxes (no crash when the list is truncated)', async () => {
    installQueryMock('cursor-page-2')
    renderWithAccess(React.createElement(GroupsPage))

    const user = userEvent.setup()
    await waitFor(() => screen.getByText('Manage members'))
    await user.click(screen.getByText('Manage members'))

    await waitFor(() => {
      expect(screen.getByLabelText(/User 0/)).toBeInTheDocument()
      expect(screen.getByLabelText(/User 2/)).toBeInTheDocument()
    })
  })
})

describe('ISS-0816/ISS-0828 — GroupsPage members list truncation warning (AC3)', () => {
  it('TC-ISS0816-01: shows truncation warning when groupsApi.members returns next_cursor (>50 members)', async () => {
    installQueryMock(null, 'cursor-members-2')
    renderWithAccess(React.createElement(GroupsPage))

    const user = userEvent.setup()
    await waitFor(() => screen.getByText('Manage members'))
    await user.click(screen.getByText('Manage members'))

    await waitFor(() => {
      expect(screen.getByTestId('members-list-truncated-warning')).toBeInTheDocument()
    })
    expect(screen.getByTestId('members-list-truncated-warning')).toHaveTextContent('more than 50 members')
    expect(screen.getByTestId('members-list-truncated-warning')).toHaveTextContent('first 50')
  })

  it('TC-ISS0816-02: no members truncation warning when next_cursor is null (≤50 members)', async () => {
    installQueryMock(null, null)
    renderWithAccess(React.createElement(GroupsPage))

    const user = userEvent.setup()
    await waitFor(() => screen.getByText('Manage members'))
    await user.click(screen.getByText('Manage members'))

    await waitFor(() => {
      expect(screen.queryByTestId('members-list-truncated-warning')).not.toBeInTheDocument()
    })
  })
})
