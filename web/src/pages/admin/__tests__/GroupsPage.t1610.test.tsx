// @vitest-environment jsdom
/**
 * T-1610 (B4#5): Groups ergonomics -- bulk add, find by name, roles column, last-administrator warning.
 * Mocked-useQuery pattern on purpose (see GroupsPage.iss0823.test.tsx: a real QueryClientProvider hangs jsdom).
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, waitFor, act, within } from '@testing-library/react'
import { renderWithAccess } from '@/auth/access/testing'
import userEvent from '@testing-library/user-event'
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
      tenant_display_name: 'Acme',
      tenant_id: 'tid-1',
      tenant_type: 'production',
    },
  })),
}))

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return { ...actual, useNavigate: vi.fn(() => vi.fn()) }
})

const api = vi.hoisted(() => ({
  addMember: vi.fn(),
  removeMembers: vi.fn(),
  usersList: vi.fn(),
}))
vi.mock('@/api/identity', () => ({
  groupsApi: {
    list: vi.fn(),
    members: vi.fn(),
    addMember: api.addMember,
    removeMembers: api.removeMembers,
    create: vi.fn(),
    delete: vi.fn(),
  },
  usersApi: { list: api.usersList },
  rolesApi: { list: vi.fn() },
}))

const mockUseQuery = vi.fn()
const mutationOpts: Array<Record<string, unknown>> = []
const removeMutate = vi.fn()
vi.mock('@tanstack/react-query', () => ({
  useQuery: (opts: unknown) => mockUseQuery(opts),
  useMutation: (opts: Record<string, unknown>) => {
    mutationOpts.push(opts)
    return { mutate: removeMutate, mutateAsync: vi.fn(), isPending: false, isError: false, error: null }
  },
  useQueryClient: () => ({ invalidateQueries: vi.fn() }),
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

import GroupsPage from '../GroupsPage'

const ADMIN_GROUP = { id: 'g-admin', name: 'admins', display_name: 'Admins', description: null }
const OTHER_GROUP = { id: 'g-ops', name: 'ops', display_name: 'Operators', description: null }
const ROLES = [
  { id: 'r1', name: 'TENANT_ADMIN', kind: 'platform_role', group_id: 'g-admin', is_system: true, permissions: [] },
  { id: 'r2', name: 'dispatcher', kind: 'process_routing_role', group_id: null, is_system: false, permissions: [] },
]

function mkUser(i: number, status: 'active' | 'inactive' = 'active') {
  return {
    id: `u-${i}`,
    username: `user${i}`,
    display_name: `Ann ${i}`,
    email: `ann${i}@example.com`,
    status,
    auth_source: 'internal',
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
  }
}

function install(opts: { members?: ReturnType<typeof mkUser>[]; membersNext?: string | null; users?: ReturnType<typeof mkUser>[] }) {
  mockUseQuery.mockImplementation((o: unknown) => {
    const { queryKey } = o as { queryKey: unknown[] }
    const ok = (data: unknown) => ({ data, isLoading: false, isError: false, error: null, refetch: vi.fn() }) as unknown as UseQueryResult
    switch (queryKey[0]) {
      case 'groups':
        return ok({ items: [ADMIN_GROUP, OTHER_GROUP], total: 2 })
      case 'roles':
        return ok({ items: ROLES })
      case 'groupMembers':
        return ok({ items: opts.members ?? [], next_cursor: opts.membersNext ?? null, count: (opts.members ?? []).length })
      case 'users':
        return ok({ items: opts.users ?? [], next_cursor: null, total: (opts.users ?? []).length })
      default:
        return ok(undefined)
    }
  })
}

beforeEach(() => {
  mutationOpts.length = 0
})
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

async function openManage(rowIndex: number) {
  const user = userEvent.setup()
  await waitFor(() => screen.getAllByText('Manage members'))
  await user.click(screen.getAllByText('Manage members')[rowIndex])
  return user
}

describe('T-1610 bulk add and find by name', () => {
  it('G1: ticking 3 users and clicking Add selected calls addMember for each', async () => {
    install({ users: [mkUser(1), mkUser(2), mkUser(3), mkUser(4)] })
    api.addMember.mockResolvedValue({ created: true })
    renderWithAccess(React.createElement(GroupsPage))
    const user = await openManage(1)
    for (const n of [1, 2, 3]) await user.click(await screen.findByLabelText(new RegExp(`Ann ${n}\\b`)))
    await user.click(screen.getByRole('button', { name: 'Add selected (3)' }))
    await waitFor(() => expect(api.addMember).toHaveBeenCalledTimes(3))
    expect(api.addMember.mock.calls.map((c) => c[1])).toEqual(['u-1', 'u-2', 'u-3'])
    expect(await screen.findByTestId('add-summary')).toHaveTextContent('Added 3, failed 0.')
  })

  it('G2: one failure is reported, the rest are added, the failed user stays ticked', async () => {
    install({ users: [mkUser(1), mkUser(2), mkUser(3)] })
    api.addMember.mockResolvedValueOnce({ created: true }).mockRejectedValueOnce(new Error('boom')).mockResolvedValueOnce({ created: true })
    renderWithAccess(React.createElement(GroupsPage))
    const user = await openManage(1)
    for (const n of [1, 2, 3]) await user.click(await screen.findByLabelText(new RegExp(`Ann ${n}\\b`)))
    await user.click(screen.getByRole('button', { name: 'Add selected (3)' }))
    const summary = await screen.findByTestId('add-summary')
    expect(summary).toHaveTextContent('Added 2, failed 1.')
    expect(summary).toHaveTextContent('Ann 2')
    expect(screen.getByLabelText(/Ann 2\b/)).toBeChecked()
    expect(screen.getByLabelText(/Ann 1\b/)).not.toBeChecked()
    expect(api.addMember).toHaveBeenCalledTimes(3)
  })

  it('G3: typing in the search box queries users with the search term (debounced)', async () => {
    install({ users: [mkUser(1)] })
    renderWithAccess(React.createElement(GroupsPage))
    const user = await openManage(1)
    await user.type(await screen.findByRole('searchbox'), 'ann')
    await waitFor(() => {
      const keys = mockUseQuery.mock.calls.map((c) => (c[0] as { queryKey: unknown[] }).queryKey)
      expect(keys).toContainEqual(['users', { search: 'ann', page_size: 50 }])
    })
    const call = mockUseQuery.mock.calls
      .map((c) => c[0] as { queryKey: unknown[]; queryFn: () => unknown })
      .reverse()
      .find((o) => o.queryKey[0] === 'users')!
    api.usersList.mockResolvedValue({ items: [] })
    await call.queryFn()
    expect(api.usersList).toHaveBeenCalledWith({ search: 'ann', page_size: 50 })
  })

  it('G4: current members are absent from the picker; inactive users are tagged and selectable', async () => {
    install({ members: [mkUser(1)], users: [mkUser(1), mkUser(2, 'inactive')] })
    renderWithAccess(React.createElement(GroupsPage))
    await openManage(1)
    const picker = await screen.findByRole('group', { name: /Find a user/ })
    expect(within(picker).queryByLabelText(/Ann 1\b/)).not.toBeInTheDocument()
    expect(within(picker).getByLabelText(/Ann 2\b/).closest('label')).toHaveTextContent('inactive')
  })
})

describe('T-1610 roles of a group', () => {
  it('G5: the Roles column names the role a group gives, and only for that group', async () => {
    install({})
    renderWithAccess(React.createElement(GroupsPage))
    await waitFor(() => screen.getByText('admins'))
    const adminRow = screen.getByText('admins').closest('tr')!
    const opsRow = screen.getByText('ops').closest('tr')!
    expect(within(adminRow).getByText('Organisation administrator')).toBeInTheDocument()
    expect(within(opsRow).queryByText('Organisation administrator')).not.toBeInTheDocument()
    expect(screen.queryByText('dispatcher')).not.toBeInTheDocument()
  })
})

describe('T-1610 last-administrator warning', () => {
  it('G6: removing the only active member of the TENANT_ADMIN group asks first', async () => {
    install({ members: [mkUser(1)] })
    renderWithAccess(React.createElement(GroupsPage))
    const user = await openManage(0)
    await user.click(await screen.findByRole('button', { name: 'Remove' }))
    expect(await screen.findByTestId('last-admin-warning')).toBeInTheDocument()
    expect(removeMutate).not.toHaveBeenCalled()
    await user.click(screen.getByRole('button', { name: 'Remove anyway' }))
    await waitFor(() => expect(removeMutate).toHaveBeenCalledWith({ groupId: 'g-admin', userId: 'u-1' }))
  })

  it('G7: two active members, or another group, remove directly', async () => {
    install({ members: [mkUser(1), mkUser(2)] })
    renderWithAccess(React.createElement(GroupsPage))
    const user = await openManage(0)
    await user.click((await screen.findAllByRole('button', { name: 'Remove' }))[0])
    await waitFor(() => expect(removeMutate).toHaveBeenCalledWith({ groupId: 'g-admin', userId: 'u-1' }))
    expect(screen.queryByTestId('last-admin-warning')).not.toBeInTheDocument()
  })

  it('G7b: a truncated member list gives no warning (cannot know)', async () => {
    install({ members: [mkUser(1)], membersNext: 'c2' })
    renderWithAccess(React.createElement(GroupsPage))
    const user = await openManage(0)
    await user.click(await screen.findByRole('button', { name: 'Remove' }))
    await waitFor(() => expect(removeMutate).toHaveBeenCalled())
    expect(screen.queryByTestId('last-admin-warning')).not.toBeInTheDocument()
  })

  it('G8: a 409 last_tenant_wide_admin answer shows a plain sentence', async () => {
    install({ members: [mkUser(1), mkUser(2)] })
    renderWithAccess(React.createElement(GroupsPage))
    await openManage(0)
    // The page also hosts a grant card with its own mutations: pick the removeMember one by its mutationFn.
    const removeOpts = [...mutationOpts]
      .reverse()
      .find((o) => String(o.mutationFn).includes('removeMembers')) as { onError: (e: unknown) => void }
    act(() => removeOpts.onError({ status: 409, code: 'last_tenant_wide_admin' }))
    expect(await screen.findByTestId('group-action-error-dialog')).toHaveTextContent('at least one administrator')
  })
})
