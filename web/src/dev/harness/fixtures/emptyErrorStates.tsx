/** Harness fixtures of the empty-list, failed-load and refusal texts of the core screens (T-1553).
 *  Screens: users-states, definitions-states (state=empty | error), permission-denied-states. Invented data only. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { PermissionDenied } from '@/components/ui/PermissionDenied'
import DefinitionListPage from '@/pages/definitions/DefinitionListPage'
import UsersPage from '@/pages/admin/UsersPage'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const ME = '11111111-2222-4333-8444-555555555555'
const AUTH = {
  session: { token: 'h.' + btoa(JSON.stringify({ sub: ME })) + '.s', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: {
    roles: [],
    platform_tenant: false,
    user_id: ME,
    permissions: ['UsersGroupsRolesManage', 'DefinitionsRead', 'DefinitionsWrite'],
  },
}

const emptyList = (path: string): FixtureRoute => ({
  match: (p, m) => p === path && m === 'GET',
  reply: (s) =>
    s === 'error'
      ? { status: 500, body: { title: 'internal_error', status: 500 } }
      : { status: 200, body: { items: [], next_cursor: null } },
})

const shell = (page: ReactElement): ReactElement => (
  <AuthContext.Provider value={AUTH}>
    <AccessStateProvider state={ACCESS}>
      <div className="lf-main">
        <main className="lf-content">{page}</main>
      </div>
    </AccessStateProvider>
  </AuthContext.Provider>
)

export const emptyErrorStates: HarnessScreen[] = [
  {
    name: 'users-states',
    routes: [emptyList('/api/v1/identity/users'), emptyList('/api/v1/identity/roles')],
    render: () => shell(<UsersPage />),
  },
  {
    name: 'definitions-states',
    routes: [emptyList('/api/v1/definitions')],
    render: () => shell(<DefinitionListPage />),
  },
  {
    name: 'permission-denied-states',
    routes: [],
    render: () => shell(<PermissionDenied />),
  },
]
