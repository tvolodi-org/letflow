/** Harness screens of GATE B rework R15 (T-1435): Users list with roles, storekeeper dashboard, denied admin page.
 *  Invented data only. */
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { P, ROLES, RequirePermission } from '@/auth/access'
import type { AccessState } from '@/auth/access/types'
import UsersPage from '@/pages/admin/UsersPage'
import TenantDashboardPage from '@/pages/dashboard/TenantDashboardPage'
import type { HarnessScreen } from '../types'

const auth = {
  session: { tenant_id: 'harness-tenant' },
  isAuthenticated: true,
  isLoading: false,
  loginSource: null,
  login: async () => undefined,
  logout: () => undefined,
  setSession: () => undefined,
  switchTenant: async () => 'ok',
  switchingToTenantSlug: null,
} as unknown as AuthContextValue

const access = (permissions: string[]): AccessState => ({ status: 'ready', info: { roles: [], platform_tenant: false, permissions } })

const USERS = [
  { id: 'u1', username: 'aigerim', display_name: 'Aigerim Sarsenova', email: 'aigerim@example.test', status: 'active', roles: [ROLES[0]] },
  { id: 'u2', username: 'dauren', display_name: 'Dauren Omarov', email: 'dauren@example.test', status: 'active', roles: [ROLES[ROLES.length - 1]] },
  { id: 'u3', username: 'saule', display_name: 'Saule Nurpeisova', email: 'saule@example.test', status: 'inactive', roles: [] },
].map(u => ({ ...u, auth_source: 'local', inserted_at: '2026-11-06T09:00:00Z', updated_at: '2026-11-06T09:00:00Z' }))

export const leftoversR15Screens: HarnessScreen[] = [
  {
    name: 'r15-users',
    routes: [
      { match: p => p === '/api/v1/identity/users', reply: () => ({ status: 200, body: { items: USERS, next_cursor: null, count: USERS.length } }) },
      { match: p => p === '/api/v1/identity/roles', reply: () => ({ status: 200, body: { items: [], next_cursor: null } }) },
    ],
    render: () => (
      <AuthContext.Provider value={auth}>
        <AccessStateProvider state={access([P.UsersGroupsRolesManage])}>
          <main className="lf-content"><UsersPage /></main>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
  {
    name: 'r15-dashboard',
    routes: [
      { match: p => p.startsWith('/api/v1/instances'), reply: () => ({ status: 200, body: { items: [], next_cursor: null, count: 0 } }) },
      { match: p => p.startsWith('/api/v1/tasks'), reply: () => ({ status: 200, body: { items: [], next_cursor: null, count: 3 } }) },
    ],
    render: () => (
      <AuthContext.Provider value={auth}>
        <AccessStateProvider state={access([])}>
          <main className="lf-content"><TenantDashboardPage /></main>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
  {
    name: 'r15-denied',
    routes: [],
    render: () => (
      <AuthContext.Provider value={auth}>
        <AccessStateProvider state={access([])}>
          <main className="lf-content">
            <RequirePermission permission={P.UsersGroupsRolesManage}><UsersPage /></RequirePermission>
          </main>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
]
