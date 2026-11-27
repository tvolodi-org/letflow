/** Harness fixture of T-2013: the process list with the "Copy as draft" action in each row. Invented data. */
import type { ReactElement } from 'react'
import type { ProcessDefinition } from '@/types/api'
import DefinitionListPage from '@/pages/definitions/DefinitionListPage'
import DefinitionRollbackPage from '@/pages/definitions/DefinitionRollbackPage'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import type { HarnessScreen } from '../types'

const AUTH = { session: { token: 'harness', tenant_id: 'harness-tenant' }, isAuthenticated: true } as unknown as AuthContextValue
const ACCESS: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['DefinitionsWrite', 'DefinitionsRead', 'MyAccessRead'] } }

const def = (id: string, name: string, version: string, status: ProcessDefinition['status']): ProcessDefinition => ({
  id,
  name,
  version,
  status,
  graph: { nodes: [], edges: [] },
  description: '',
  created_by: '7c1f0a52-3d0e-4b0a-9c3a-1f4d2e8b6a10',
  created_at: '2026-11-05T09:30:00Z',
  updated_at: '2026-11-05T09:30:00Z',
})
const ITEMS = [def('a1', 'purchase-request', '2', 'ACTIVE'), def('a2', 'purchase-request', '3', 'DRAFT'), def('a3', 'leave-approval', '1', 'DEPRECATED'), def('a4', 'platform.register_tenant', 'uat-20261125-ab12', 'DEPRECATED')]

export const definitionListScreens: HarnessScreen[] = [
  {
    name: 'pd-list-copy',
    routes: [
      {
        match: (p, m) => m === 'GET' && p === '/api/v1/definitions',
        reply: (state) =>
          state === 'error'
            ? { status: 500, body: { title: 'Internal Server Error', status: 500 } }
            : { status: 200, body: { items: state === 'empty' ? [] : ITEMS, next_cursor: null } },
      },
    ],
    render: (): ReactElement => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <div className="lf-main">
            <main className="lf-content">
              <DefinitionListPage />
            </main>
          </div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
  {
    name: 'pd-rollback',
    initialPath: '/a1',
    routePattern: '/:id',
    routes: [
      {
        match: (p, m) => m === 'GET' && p === '/api/v1/definitions/a1',
        reply: () => ({ status: 200, body: ITEMS[0] }),
      },
      {
        match: (p, m) => m === 'GET' && p === '/api/v1/definitions',
        reply: () => ({ status: 200, body: { items: [ITEMS[0], def('a0', 'purchase-request', '1', 'DEPRECATED')], next_cursor: null } }),
      },
    ],
    render: (): ReactElement => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={{ status: 'ready', info: { roles: [], platform_tenant: true, permissions: ['DefinitionsRollback', 'DefinitionsRead', 'MyAccessRead'] } }}>
          <div className="lf-main">
            <main className="lf-content">
              <DefinitionRollbackPage />
            </main>
          </div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
]
