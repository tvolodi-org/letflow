// @vitest-environment jsdom
/** U12/U13: T-1633, the import route is guarded and resolves before :userId; the Users page button opens it. */
import type { ReactElement } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen } from '@testing-library/react'
import { matchRoutes } from 'react-router-dom'
expect.extend(jestDomMatchers)

const navigate = vi.fn()
vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return { ...actual, useNavigate: () => navigate }
})
vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-1', tenant_slug: 't', tenant_display_name: 'T', tenant_type: 'production' } }),
}))
vi.mock('@tanstack/react-query', () => ({
  useQuery: () => ({ data: { items: [] }, isLoading: false, isError: false, error: null, refetch: vi.fn() }),
  useMutation: () => ({ mutate: vi.fn(), mutateAsync: vi.fn(), isPending: false, isError: false, error: null }),
  useQueryClient: () => ({ invalidateQueries: vi.fn() }),
}))
vi.mock('@/api/useTenantScopedQueryKeys', () => ({
  useTenantScopedQueryKeys: () => ({ admin: { users: () => ['users'], roles: () => ['roles'] } }),
}))

import { router } from '@/router'
import { P } from '@/auth/access'
import { renderWithAccess } from '@/auth/access/testing'
import UsersPage from '@/pages/admin/UsersPage'
import UsersImportPage from '@/pages/admin/usersImport/UsersImportPage'

afterEach(() => {
  cleanup()
  navigate.mockClear()
})

describe('U12 route', () => {
  it('admin/users/import resolves to the import page, guarded by UsersGroupsRolesManage', () => {
    const root = router.routes.find((r) => r.path === '/')
    const children = root?.children ?? []
    const match = matchRoutes(children, '/admin/users/import')
    expect(match).not.toBeNull()
    const route = match![match!.length - 1].route
    expect(route.path).toBe('admin/users/import')
    const guard = route.element as ReactElement<{ permission: string; children: ReactElement }>
    expect(guard.props.permission).toBe(P.UsersGroupsRolesManage)
    expect(guard.props.children.type).toBe(UsersImportPage)
  })
})

describe('U13 Users page button', () => {
  it('navigates to the import screen for a tenant admin', () => {
    renderWithAccess(<UsersPage />, 'tenantAdmin')
    fireEvent.click(screen.getByText('Import from Excel'))
    expect(navigate).toHaveBeenCalledWith('/admin/users/import')
  })
  it('is hidden without the manage permission', () => {
    renderWithAccess(<UsersPage />, 'auditor')
    expect(screen.queryByText('Import from Excel')).toBeNull()
  })
})
