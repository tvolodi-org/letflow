/** Harness fixtures of the My Tasks screen for an ASSET document (T-1942). Invented data only: the Approve task of an
 *  issued asset opening that the signed-in user issued. Variants: loaded, document refused, document loading, no lines. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import TaskInboxPage from '@/pages/tasks/TaskInboxPage'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const ME = '11111111-2222-4333-8444-555555555555'
const T1 = 'cccccccc-0000-4000-8000-0000000000a1'
const I1 = 'aaaaaaaa-bbbb-4ccc-8ddd-0000000000a1'
const D1 = 'dddddddd-1111-4222-8333-0000000000a1'
const ORG = 'bbbbbbbb-1111-4222-8333-0000000000a1'
const LOC = 'bbbbbbbb-1111-4222-8333-0000000000a2'

const task = { id: T1, instance_id: I1, token_id: 't1', node_id: 'approve', node_name: 'approve', status: 'PENDING', assignee_type: 'ROLE', assignee_ref: 'asset_approver', definition_name: 'Asset opening flow', created_at: new Date(Date.now() - 45 * 60_000).toISOString() }
const lines = [
  { line_no: 1, asset_id: 'a1', quantity: '1.000000000', location_id: LOC, inventory_number: 'FA-0101', asset_name: 'Delivery van Gazelle Next' },
  { line_no: 2, asset_id: 'a2', quantity: '4.000000000', location_id: LOC, inventory_number: 'LV-0201', asset_name: 'Monitor 27 inch' },
]
const doc = (withLines: boolean) => ({
  id: D1, kind: 'opening', state: 'issued', number: 'AOP-2026-000001', org_unit_id: ORG, event_time: null,
  note: 'Opening balances of the Almaty warehouse', lines: withLines ? lines : [],
})
const MASTER: Record<string, Record<string, unknown>> = {
  [ORG]: { code: 'WH-1', name: 'Warehouse team' },
  [LOC]: { code: 'A-01', name: 'Rack A, main hall' },
}

type Mode = 'loaded' | 'refused' | 'loading' | 'empty-lines'

function routesFor(mode: Mode): FixtureRoute[] {
  return [
    { match: (p, m) => p === '/api/v1/tasks/inbox' && m === 'GET', reply: () => ({ status: 200, body: { items: [task], next_cursor: null, count: 1 } }) },
    { match: (p, m) => p.startsWith('/api/v1/tasks/') && m === 'GET', reply: () => ({ status: 200, body: task }) },
    { match: (p, m) => /^\/api\/v1\/instances\/[^/]+\/history$/.test(p) && m === 'GET', reply: () => ({ status: 200, body: [{ actor_id: ME }] }) },
    {
      match: (p, m) => /^\/api\/v1\/instances\/[^/]+$/.test(p) && m === 'GET',
      reply: (_s, p) => ({ status: 200, body: { id: p.split('/').pop(), variables: { document_id: D1, document_type: 'assets_opening' } } }),
    },
    {
      match: (p, m) => p.startsWith('/api/v1/modules/assets/documents/') && m === 'GET',
      pending: mode === 'loading',
      reply: () => (mode === 'refused' ? { status: 403, body: { error: 'forbidden' } } : { status: 200, body: doc(mode !== 'empty-lines') }),
    },
    {
      match: (p, m) => p === '/api/v1/entities/query' && m === 'POST',
      reply: (_s, _p, body) => {
        const b = (body ?? {}) as { entity_type?: string; filters?: { value?: string[] }[] }
        const ids = b.filters?.[0]?.value ?? []
        const items = ids.filter((id) => MASTER[id]).map((id) => ({ record_id: id, entity_type: b.entity_type, field_values: { active: true, ...MASTER[id] }, deleted: false, entity_def_version: '1', last_event_global_seq: 1 }))
        return { status: 200, body: { items, next_cursor: null } }
      },
    },
  ]
}

const AUTH = {
  session: { token: 'h.' + btoa(JSON.stringify({ sub: ME })) + '.s', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, user_id: ME, permissions: ['TasksRead', 'TasksComplete'] },
}

function withAuth(page: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={ACCESS}>
        <div className="lf-main">
          <main className="lf-content">{page}</main>
        </div>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

const screen = (name: string, mode: Mode): HarnessScreen => ({ name, routes: routesFor(mode), initialPath: `/?task=${T1}`, render: () => withAuth(<TaskInboxPage />) })

export const taskInboxAssetsScreens: HarnessScreen[] = [
  screen('tasks-assets-approve', 'loaded'),
  screen('tasks-assets-refused', 'refused'),
  screen('tasks-assets-loading', 'loading'),
  screen('tasks-assets-empty-lines', 'empty-lines'),
]
