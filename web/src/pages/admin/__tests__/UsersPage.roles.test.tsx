// @vitest-environment jsdom
/** T-1435 U4/D3: the Users list fills the Roles cell from `roles` and shows the date in the UI language's format. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { renderWithAccess } from '@/auth/access/testing'
import { ROLES } from '@/auth/access/roles'
import { roleLabel } from '@/auth/access/roleLabels'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-1', tenant_slug: 't', tenant_display_name: 'T', tenant_type: 'production' } }),
}))
vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return { ...actual, useNavigate: () => vi.fn() }
})
const ROLE = ROLES.find((r) => r === ROLES[ROLES.length - 1]) as string
const USER = { id: 'u1', username: 'ann', display_name: 'Ann', email: 'ann@x.io', status: 'active', roles: [ROLE], inserted_at: '2026-11-06T09:00:00Z' }
vi.mock('@tanstack/react-query', () => ({
  useQuery: () => ({ data: { items: [USER] }, isLoading: false, isError: false, error: null, refetch: vi.fn() }),
  useMutation: () => ({ mutate: vi.fn(), mutateAsync: vi.fn(), isPending: false, isError: false, error: null }),
  useQueryClient: () => ({ invalidateQueries: vi.fn() }),
}))
vi.mock('@/api/useTenantScopedQueryKeys', () => ({
  useTenantScopedQueryKeys: () => ({ admin: { users: () => ['users'], roles: () => ['roles'] } }),
}))

import UsersPage from '../UsersPage'

afterEach(cleanup)

describe('T-1435 UsersPage', () => {
  it('U4 shows the role in the Roles cell', () => {
    renderWithAccess(<UsersPage />, 'tenantAdmin')
    expect(screen.getByText(roleLabel(ROLE, 'en'))).toBeInTheDocument()
  })
  it('D3 date follows the language: ru DD-MM-YYYY, en short month', () => {
    useUiLocaleStore.getState().setLocaleTransient('ru')
    renderWithAccess(<UsersPage />, 'tenantAdmin')
    expect(screen.getByText('06-11-2026')).toBeInTheDocument()
    cleanup()
    useUiLocaleStore.getState().setLocaleTransient('en')
    renderWithAccess(<UsersPage />, 'tenantAdmin')
    expect(screen.getByText('Nov 6, 2026')).toBeInTheDocument()
  })
})
