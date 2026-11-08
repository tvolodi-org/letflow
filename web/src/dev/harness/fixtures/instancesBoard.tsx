/** Harness fixtures of the Instances board (T-1495). The list answer carries definition_id only (the real wire
 *  shape); the Definition column resolves name and version from GET /definitions/:id. Invented data only.
 *  Screens: instances-board (names resolved, one definition that cannot be loaded), instances-board-defs-loading
 *  (the definition answers never arrive), plus the empty / loading / error states of the list. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import InstanceBoardPage from '@/pages/instances/InstanceBoardPage'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const ME = '11111111-2222-4333-8444-555555555555'
const D_OK = 'dddddddd-1111-4222-8333-000000000001'
const D_OK2 = 'dddddddd-1111-4222-8333-000000000002'
const D_GONE = 'dddddddd-1111-4222-8333-000000000003'
const ago = (min: number) => new Date(Date.now() - min * 60_000).toISOString()

const item = (n: number, definition_id: string, status: string) => ({
  instance_id: `aaaaaaaa-bbbb-4ccc-8ddd-00000000000${n}`,
  definition_id,
  correlation_key: n === 2 ? 'ORD-2026-0042' : null,
  scope_node_id: 'root',
  status,
  started_at: ago(30 * n),
})
const items = [item(1, D_OK, 'ACTIVE'), item(2, D_OK2, 'COMPLETED'), item(3, D_GONE, 'ACTIVE')]
const DEFS: Record<string, { name: string; version: string }> = {
  [D_OK]: { name: 'Stock document flow', version: '3' },
  [D_OK2]: { name: 'Purchase approval', version: '1' },
}

const listRoute: FixtureRoute = {
  match: (p, m) => p === '/api/v1/instances' && m === 'GET',
  reply: (s) => ({ status: 200, body: { items: s === 'empty' ? [] : items, next_cursor: null } }),
}
const defsRoute: FixtureRoute = {
  match: (p, m) => p.startsWith('/api/v1/definitions') && m === 'GET',
  reply: (_s, p) => {
    const d = DEFS[p.split('/').pop() ?? '']
    if (p === '/api/v1/definitions') return { status: 200, body: { items: [], next_cursor: null } }
    return d ? { status: 200, body: { id: p.split('/').pop(), ...d, status: 'ACTIVE', graph: { nodes: [], edges: [] } } } : { status: 404, body: { title: 'Not found', status: 404 } }
  },
}
const routes: FixtureRoute[] = [listRoute, defsRoute]

const AUTH = {
  session: { token: 'h.' + btoa(JSON.stringify({ sub: ME })) + '.s', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, user_id: ME, permissions: ['InstancesRead', 'InstancesWrite', 'DefinitionsRead'] },
}

function board(): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={ACCESS}>
        <div className="lf-main">
          <main className="lf-content"><InstanceBoardPage /></main>
        </div>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

/** The definition answers never arrive; the list does. Wrapped around the fixture fetch for this screen only. */
const hangDefinitions: FixtureRoute = {
  match: (p, m) => p.startsWith('/api/v1/definitions/') && m === 'GET',
  reply: () => ({ status: 200, body: {} }),
}
let installed = false
function holdDefinitions(): ReactElement {
  if (!installed) {
    installed = true
    const inner = window.fetch
    window.fetch = (input, init) => {
      const raw = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
      if (new URL(raw, 'http://harness.invalid').pathname.startsWith('/api/v1/definitions/')) return new Promise<Response>(() => {})
      return inner(input, init)
    }
  }
  return board()
}

export const instancesBoardScreens: HarnessScreen[] = [
  { name: 'instances-board', routes, render: board },
  { name: 'instances-board-defs-loading', routes: [listRoute, hangDefinitions], render: holdDefinitions },
]
