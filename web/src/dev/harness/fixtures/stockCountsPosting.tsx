/** Harness fixtures of the count posting panel (task T-1315, REQ-718). Invented data only. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import CountsPage from '@/modules/stock/counts/CountsPage'
import type { EntityRecord, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const rec = (id: string, type: string, fields: Record<string, unknown>): EntityRecord => ({
  record_id: id,
  entity_type: type,
  field_values: { active: true, ...fields },
  deleted: false,
  entity_def_version: '1',
  last_event_global_seq: 1,
})

const MASTERS: Record<string, EntityRecord[]> = {
  org_unit: [rec('u1', 'org_unit', { name: 'Central warehouse' })],
  org_employee: [rec('e1', 'org_employee', { full_name: 'Aigerim Sarsenova' }), rec('e2', 'org_employee', { full_name: 'Marat Kenzhebekov' })],
  location_node: [rec('l1', 'location_node', { name: 'Hall A, shelf 1' })],
  catalog_item: [rec('i1', 'catalog_item', { name: 'Safety helmet' })],
  catalog_uom: [rec('m1', 'catalog_uom', { name: 'pcs' })],
}

const BASE = {
  org_unit_id: 'u1', kind: 'full', status: 'signed', planned_start: '2026-10-20T04:00:00Z', planned_end: '2026-10-21T12:00:00Z',
  chair_employee_id: 'e1', member_employee_ids: ['e2'], location_ids: ['l1'], note: null, issued_at: '2026-10-19T08:00:00Z',
  sheet_document_id: 'd1', sheet_signed_at: '2026-10-21T13:00:00Z', differences_document_id: 'd2', differences_number: 'DIF-0003',
}
const ENTRY = '0b9f6c1e-5a3d-4e7b-9c21-7d8e4f1a2b36'
const ORDERS = [
  { ...BASE, id: 'c4', number: 'CNT-0004', posting_state: 'none', post_pending: false, reverse_pending: false },
  { ...BASE, id: 'c5', number: 'CNT-0005', posting_state: 'none', post_pending: true, reverse_pending: false },
  { ...BASE, id: 'c6', number: 'CNT-0006', status: 'posted', posting_state: 'posted', posting_check: 'ok', entry_id: ENTRY, posted_at: '2026-10-22T09:00:00Z', posting_document_id: 'd9', posting_number: 'POST-2026-000003' },
  { ...BASE, id: 'c7', number: 'CNT-0007', status: 'posted', posting_state: 'posted', posting_check: 'mismatch', entry_id: ENTRY, posted_at: '2026-10-22T09:00:00Z' },
  { ...BASE, id: 'c8', number: 'CNT-0008', status: 'posted', posting_state: 'reversed', posting_check: 'ok', entry_id: ENTRY, posted_at: '2026-10-22T09:00:00Z', reversed_at: '2026-10-23T10:00:00Z' },
  { ...BASE, id: 'c9', number: 'CNT-0009', posting_state: 'none', post_pending: false, reverse_pending: false, differences_empty: true },
]

const routes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: (_s, _p, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: { field: string; value?: unknown }[] }
      const ids = b.filters?.find((f) => f.field === 'record_id')?.value
      let items = MASTERS[b.entity_type ?? ''] ?? []
      if (Array.isArray(ids)) items = items.filter((r) => ids.includes(r.record_id))
      return { status: 200, body: { items, next_cursor: null } }
    },
  },
  { match: (path, method) => /\/counts$/.test(path) && method === 'GET', reply: () => ({ status: 200, body: { rows: ORDERS, next_cursor: null } }) },
  {
    match: (path, method) => /\/counts\/c\d$/.test(path) && method === 'GET',
    reply: (_s, path) => ({ status: 200, body: ORDERS.find((o) => path.endsWith(o.id)) ?? ORDERS[0] }),
  },
  { match: (path, method) => /\/counts\/c\d\/lines$/.test(path) && method === 'GET', reply: () => ({ status: 200, body: { rows: [], next_cursor: null } }) },
  { match: (path, method) => /\/entries$/.test(path) && method === 'GET', reply: () => ({ status: 200, body: { rows: [], next_cursor: null } }) },
  { match: (path, method) => /\/differences$/.test(path) && method === 'GET', reply: () => ({ status: 200, body: { number: 'DIF-0003', version_no: 1, issued_at: '2026-10-21T13:10:00Z', content_hash: 'abc', lines: [] } }) },
  { match: (path, method) => /\/signatures$/.test(path) && method === 'GET', reply: () => ({ status: 200, body: { rows: [] } }) },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

function withAuth(page: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider
        state={{
          status: 'ready',
          info: { roles: [], platform_tenant: false, permissions: ['StockRead', 'StockCountOrder', 'StockCountRecord', 'StockPost', 'StockReverse'] },
        }}
      >
        <div className="lf-main">
          <main className="lf-content">{page}</main>
        </div>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

const screen = (name: string, id: string): HarnessScreen => ({
  name, initialPath: `/admin/stock/counts/${id}`, routePattern: '/admin/stock/counts/:id', routes, render: () => withAuth(<CountsPage />),
})

export const stockCountPostingScreens: HarnessScreen[] = [
  screen('stock-count-post-ready', 'c4'),
  screen('stock-count-post-pending', 'c5'),
  screen('stock-count-post-posted', 'c6'),
  screen('stock-count-post-mismatch', 'c7'),
  screen('stock-count-post-reversed', 'c8'),
  screen('stock-count-post-empty', 'c9'),
]
