/** Harness fixtures of the Audit log page (T-1557): rows with user names, a deleted actor (id shown), a document
 *  post and a role change; `empty` = no rows, `error` = 500, `loading` = never answers. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import AuditLogPage from '@/pages/admin/AuditLogPage'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const AUTH = {
  session: { token: 'h.' + btoa(JSON.stringify({ sub: 'u1' })) + '.s', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, user_id: 'u1', permissions: ['AuditRead'] },
}

const entry = (n: number, over: Record<string, unknown>) => ({
  audit_id: `a${n}`,
  actor_id: '11111111-1111-1111-1111-111111111111',
  actor_name: 'Aigerim Sadykova',
  resource_name: null,
  before_state: null,
  after_state: { cause: 'receipt' },
  timestamp: `2026-11-0${n}T10:15:00Z`,
  ...over,
})

const ROWS = [
  entry(5, { action: 'document.posted', resource_type: 'document', resource_id: 'DOC-000412' }),
  entry(4, { action: 'document.reversed', resource_type: 'document', resource_id: 'DOC-000398' }),
  entry(3, {
    action: 'group_member.added',
    resource_type: 'group_member',
    resource_id: '22222222-2222-2222-2222-222222222222',
    resource_name: 'Dmitry Petrov',
  }),
  entry(2, {
    action: 'group.delete',
    actor_id: '33333333-3333-3333-3333-333333333333',
    actor_name: null,
    resource_type: 'group',
    resource_id: '44444444-4444-4444-4444-444444444444',
  }),
]
const USERS = [
  { id: '11111111-1111-1111-1111-111111111111', username: 'aigerim', display_name: 'Aigerim Sadykova', email: 'a@example.test', status: 'active' },
  { id: '22222222-2222-2222-2222-222222222222', username: 'dmitry', display_name: 'Dmitry Petrov', email: 'd@example.test', status: 'active' },
]

const routes: FixtureRoute[] = [
  {
    match: (p, m) => m === 'GET' && p.endsWith('/api/v1/audit'),
    reply: (state) => ({ status: 200, body: { items: state === 'empty' ? [] : ROWS, next_cursor: null, count: ROWS.length } }),
  },
  {
    match: (p, m) => m === 'GET' && p.endsWith('/api/v1/identity/users'),
    reply: () => ({ status: 200, body: { items: USERS, next_cursor: null, count: USERS.length } }),
  },
]

export const auditLogScreens: HarnessScreen[] = [
  {
    name: 'audit-log',
    routes,
    render: (): ReactElement => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <div className="lf-main">
            <main className="lf-content">
              <AuditLogPage />
            </main>
          </div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
]
