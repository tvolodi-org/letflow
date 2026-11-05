/** Harness fixtures of the My Tasks screen (T-1380, GATE B R3). Invented data only: a post task nobody has claimed and an
 *  approve task for a role, both about stock documents the signed-in user issued. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import TaskInboxPage from '@/pages/tasks/TaskInboxPage'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const ME = '11111111-2222-4333-8444-555555555555'
const T1 = 'cccccccc-0000-4000-8000-000000000001'
const T2 = 'cccccccc-0000-4000-8000-000000000002'
const I1 = 'aaaaaaaa-bbbb-4ccc-8ddd-000000000001'
const I2 = 'aaaaaaaa-bbbb-4ccc-8ddd-000000000002'
const D1 = 'dddddddd-1111-4222-8333-000000000001'
const D2 = 'dddddddd-1111-4222-8333-000000000002'
const ORG = 'bbbbbbbb-1111-4222-8333-000000000001'
const LOC = 'bbbbbbbb-1111-4222-8333-000000000002'
const ITEM = 'bbbbbbbb-1111-4222-8333-000000000003'
const UOM = 'bbbbbbbb-1111-4222-8333-000000000004'

const ago = (min: number) => new Date(Date.now() - min * 60_000).toISOString()
const tasks = [
  { id: T1, instance_id: I1, token_id: 't1', node_id: 'post', node_name: 'post', status: 'PENDING', definition_name: 'Stock document flow', created_at: ago(7) },
  { id: T2, instance_id: I2, token_id: 't2', node_id: 'approve', node_name: 'approve', status: 'PENDING', assignee_type: 'ROLE', assignee_ref: 'stock_keeper', definition_name: 'Stock document flow', created_at: ago(190) },
]
const doc = (id: string, number: string) => ({
  id, kind: 'issue', state: 'draft', number, org_unit_id: ORG, location_id: LOC, event_time: ago(200), note: 'Laptops for the new office',
  lines: [
    { line_no: 1, catalog_item_id: ITEM, catalog_uom_id: UOM, catalog_lot_id: null, quantity: '2.000' },
    { line_no: 2, catalog_item_id: ITEM, catalog_uom_id: UOM, catalog_lot_id: null, quantity: '1.000' },
  ],
})
const MASTER: Record<string, Record<string, unknown>> = {
  [ORG]: { code: 'WH-1', name: 'Warehouse team' },
  [LOC]: { code: 'A-01', name: 'Rack A, main hall' },
  [ITEM]: { code: 'LAP-01', name: 'Laptop 14 inch' },
  [UOM]: { code: 'pcs' },
}

const routes: FixtureRoute[] = [
  { match: (p, m) => p === '/api/v1/tasks/inbox' && m === 'GET', reply: (s) => ({ status: 200, body: { items: s === 'empty' ? [] : tasks, next_cursor: null, count: tasks.length } }) },
  { match: (p, m) => p.startsWith('/api/v1/tasks/') && m === 'GET', reply: (_s, p) => ({ status: 200, body: tasks.find((t) => p.endsWith(t.id)) ?? tasks[0] }) },
  { match: (p, m) => /^\/api\/v1\/instances\/[^/]+\/history$/.test(p) && m === 'GET', reply: () => ({ status: 200, body: [{ actor_id: ME }] }) },
  {
    match: (p, m) => /^\/api\/v1\/instances\/[^/]+$/.test(p) && m === 'GET',
    reply: (_s, p) => ({ status: 200, body: { id: p.split('/').pop(), variables: { document_id: p.endsWith(I1) ? D1 : D2, document_type: 'stock_issue' } } }),
  },
  {
    match: (p, m) => p.startsWith('/api/v1/modules/stock/documents/') && m === 'GET',
    reply: (_s, p) => ({ status: 200, body: p.endsWith(D1) ? doc(D1, 'ISS-2026-0001') : doc(D2, 'ISS-2026-0002') }),
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

const AUTH = {
  session: { token: 'h.' + btoa(JSON.stringify({ sub: ME })) + '.s', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, permissions: ['TasksRead', 'TasksComplete'] },
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

export const taskInboxScreens: HarnessScreen[] = [
  { name: 'tasks-inbox', routes, render: () => withAuth(<TaskInboxPage />) },
  { name: 'tasks-inbox-approve', routes, initialPath: `/?task=${T2}`, render: () => withAuth(<TaskInboxPage />) },
  { name: 'tasks-inbox-post', routes, initialPath: `/?task=${T1}`, render: () => withAuth(<TaskInboxPage />) },
]
