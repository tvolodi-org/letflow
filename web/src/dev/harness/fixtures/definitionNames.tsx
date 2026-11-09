/** Harness fixtures of T-1511: friendly definition names on the instances board, the instance detail and the
 *  definitions list. Invented data only; shapes follow the real answers (definition_id only on instances). */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import InstanceBoardPage from '@/pages/instances/InstanceBoardPage'
import InstanceDetailPage from '@/pages/instances/InstanceDetailPage'
import DefinitionListPage from '@/pages/definitions/DefinitionListPage'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const def = (id: string, name: string, version: string) => ({
  id,
  name,
  version,
  status: 'ACTIVE',
  description: '',
  graph: { nodes: [], edges: [] },
  created_by: 'harness',
  created_at: '2026-11-01T09:00:00Z',
  updated_at: '2026-11-01T09:00:00Z',
})
const DEFS = [def('d-wo', 'assets_writeoff', '1.0.0'), def('d-ho', 'assets_handover', '1.0.0'), def('d-own', 'Order approval', '3')]
const inst = (id: string, definition_id: string) => ({
  instance_id: id,
  definition_id,
  correlation_key: null,
  scope_node_id: 'root',
  status: 'ACTIVE',
  current_nodes: ['n2'],
  variables: {},
  started_at: '2026-11-08T09:00:00Z',
})
const INSTS = [inst('inst-0001-aaaa', 'd-wo'), inst('inst-0002-bbbb', 'd-own'), inst('inst-0003-cccc', 'd-ho')]

const routes: FixtureRoute[] = [
  {
    match: (p, m) => m === 'GET' && p === '/api/v1/instances',
    reply: (state) => ({ status: 200, body: { items: state === 'empty' ? [] : INSTS, next_cursor: null } }),
  },
  {
    match: (p, m) => m === 'GET' && /^\/api\/v1\/instances\/[^/]+$/.test(p),
    reply: (_s, p) => ({ status: 200, body: INSTS.find((i) => p.endsWith(i.instance_id)) ?? INSTS[0] }),
  },
  {
    match: (p, m) => m === 'GET' && /^\/api\/v1\/instances\/[^/]+\/timeline$/.test(p),
    reply: () => ({ status: 200, body: { items: [], count: 0, next_cursor: null } }),
  },
  {
    match: (p, m) => m === 'GET' && p === '/api/v1/definitions',
    reply: (state) => ({ status: 200, body: { items: state === 'empty' ? [] : DEFS, next_cursor: null } }),
  },
  {
    match: (p, m) => m === 'GET' && /^\/api\/v1\/definitions\/[^/]+$/.test(p),
    reply: (_s, p) => ({ status: 200, body: DEFS.find((d) => p.endsWith(`/${d.id}`)) ?? DEFS[0] }),
  },
  { match: (p, m) => m === 'GET' && p.startsWith('/api/v1/tasks'), reply: () => ({ status: 200, body: { items: [], next_cursor: null } }) },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

function frame(page: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <div className="lf-main">
        <main className="lf-content">
          {page}
        </main>
      </div>
    </AuthContext.Provider>
  )
}

export const definitionNameScreens: HarnessScreen[] = [
  { name: 'definition-names-instances', routes, render: () => frame(<InstanceBoardPage />) },
  {
    name: 'definition-names-instance-detail',
    initialPath: '/instances/inst-0001-aaaa',
    routePattern: '/instances/:id',
    routes,
    render: () => frame(<InstanceDetailPage />),
  },
  { name: 'definition-names-definitions', routes, render: () => frame(<DefinitionListPage />) },
]
