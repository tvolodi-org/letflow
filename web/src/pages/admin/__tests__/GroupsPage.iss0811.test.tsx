// @vitest-environment jsdom
/**
 * ISS-0811: GroupsPage Members column and Group type wire-shape correctness.
 *
 * group_map/1 (lib/letflow/routers/identity.ex:749-756) emits:
 *   id, name, display_name, description, created_at
 * It does NOT emit is_system or member_count. GroupsPage previously showed
 * "0" for all groups' member counts — a phantom value from a required field
 * the server never sends.
 *
 * Fix: Members column removed; Group type corrected to mark is_system and
 * member_count as optional (not required). This test pins the corrected behaviour.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import React from 'react'
import type { UseQueryResult } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(() => ({
    session: {
      token: 'tok',
      display_name: 'Admin',
      loginSource: null,
      tenant_slug: 'demo-corp',
      tenant_display_name: 'Demo Corp',
      tenant_id: 'tid-1',
      tenant_type: 'production',
    },
  })),
}))

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return { ...actual, useNavigate: vi.fn(() => vi.fn()) }
})

const mockUseQuery = vi.fn()
const mockUseMutation = vi.fn(() => ({
  mutate: vi.fn(), mutateAsync: vi.fn(), isPending: false, isError: false, error: null,
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
      groupMembers: (id: string) => ['groupMembers', id],
      users: (f: unknown) => ['users', f],
    },
  })),
}))

import GroupsPage from '../GroupsPage'

/** Wire payload matching group_map/1 exactly: {id, name, display_name, description, created_at} */
const WIRE_GROUP = {
  id: 'g-1',
  name: 'operators',
  display_name: 'Operators',
  description: 'Process operators',
  created_at: '2026-01-01T00:00:00Z',
  // is_system and member_count intentionally absent — group_map/1 never emits them
}

function installQueryMock() {
  mockUseQuery.mockImplementation((opts: unknown) => {
    const { queryKey } = opts as { queryKey: unknown[] }
    if (Array.isArray(queryKey) && queryKey[0] === 'groups') {
      return {
        data: { items: [WIRE_GROUP], total: 1 },
        isLoading: false, isError: false, error: null, refetch: vi.fn(),
      } as unknown as UseQueryResult
    }
    return { data: undefined, isLoading: false, isError: false, error: null } as unknown as UseQueryResult
  })
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('ISS-0811 — GroupsPage Members column removed; Group wire shape correctness', () => {
  it('TC-ISS0811-01: the groups table has no Members column (member_count never sent by group_map/1)', () => {
    installQueryMock()
    render(React.createElement(GroupsPage))

    // The table renders; assert no "Members" column header appears
    expect(screen.queryByRole('columnheader', { name: /members/i })).not.toBeInTheDocument()
  })

  it('TC-ISS0811-02: group row is rendered with real wire-shape data (no phantom 0 count)', () => {
    installQueryMock()
    render(React.createElement(GroupsPage))

    // The group name and display name render correctly from group_map/1 fields
    expect(screen.getByText('operators')).toBeInTheDocument()
    expect(screen.getByText('Operators')).toBeInTheDocument()
  })

  it('TC-ISS0811-03: Delete button is visible for groups (is_system condition removed — backend enforces)', () => {
    installQueryMock()
    render(React.createElement(GroupsPage))

    // Delete button should be visible (no longer conditionally hidden by phantom is_system/member_count)
    const deleteButton = screen.getByTestId('delete-group-g-1')
    expect(deleteButton).toBeInTheDocument()
  })
})
