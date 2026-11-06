/** Harness fixtures of GATE B rework R12 (T-1422): the Movements screen on the journal component. Invented data only.
 *  Screens: split (wide: list left, legs of the selected row right), v1 expanded (narrow: legs inline), v3 details
 *  (narrow: full-screen pane with Back and previous/next), v2 sheet (kept as an option). Empty and error come from the
 *  harness state. */
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import MovementsPage from '@/modules/stock/register/MovementsPage'
import type { EntityRecord, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const rec = (id: string, type: string, fields: Record<string, unknown>): EntityRecord => ({
  record_id: id, entity_type: type, field_values: { active: true, ...fields }, deleted: false, entity_def_version: '1', last_event_global_seq: 1,
})

const MASTERS: Record<string, EntityRecord[]> = {
  catalog_item: [
    rec('i1', 'catalog_item', { code: 'ITM-0001', name: 'Laptop 14 inch, aluminium case, 16 GB' }),
    rec('i2', 'catalog_item', { code: 'ITM-0002', name: 'Safety helmet' }),
  ],
  location_node: [
    rec('l1', 'location_node', { code: 'WH-ALA', name: 'Almaty central warehouse' }),
    rec('l2', 'location_node', { code: 'DOCK-1', name: 'Receiving dock' }),
  ],
  org_unit: [rec('u1', 'org_unit', { code: 'WT', name: 'Warehouse team' })],
  org_employee: [rec('e1', 'org_employee', { code: 'E-017', full_name: 'Aigerim Sarsenova' })],
  catalog_lot: [rec('t1', 'catalog_lot', { code: 'LOT-2026-001', item_id: 'i1' })],
  catalog_uom: [rec('m1', 'catalog_uom', { code: 'PCS', name: 'pcs' })],
}

const leg = (n: number, q: string, sku: string, location: string, responsible: string | null = null) => ({
  leg_no: n, quantity: q, unit_ref: 'm1', sku, location, org_unit: 'u1', responsible, lot: null,
})

const MOVEMENTS = [
  {
    entry_id: 'jr-1', posting_seq: 1046, cause: 'transfer', document_type: 'stock_transfer', document_id: '5b58a738-1c2d-4e3f-8a9b-000000000001', document_number: 'TRF-2026-000002',
    event_time: '2026-11-05T11:24:00Z', posting_time: '2026-11-05T11:25:10Z', reason_code: null,
    legs: [leg(1, '-5.000000000', 'i1', 'l1', 'e1'), leg(2, '5.000000000', 'i1', 'l2')],
  },
  {
    entry_id: 'jr-2', posting_seq: 1045, cause: 'receipt', document_type: 'stock_receipt', document_id: '5b58a738-1c2d-4e3f-8a9b-000000000002', document_number: 'RCP-2026-000001',
    event_time: '2026-11-05T09:10:00Z', posting_time: '2026-11-05T09:11:00Z', reason_code: null,
    legs: [leg(1, '40.000000000', 'i1', 'l1'), leg(2, '120.000000000', 'i2', 'l1')],
  },
  {
    entry_id: 'jr-3', posting_seq: 1044, cause: 'reversal', reverses_entry_id: 'jr-4', document_type: 'stock_reversal', document_id: '5b58a738-1c2d-4e3f-8a9b-000000000003',
    document_number: 'REV-2026-000001', event_time: '2026-11-04T16:00:00Z', posting_time: '2026-11-04T16:00:30Z', reason_code: 'wrong_quantity',
    legs: [leg(1, '-12.500000000', 'i2', 'l1')],
  },
  {
    entry_id: 'jr-4', posting_seq: 1043, cause: 'issue', document_type: 'stock_issue', document_id: '5b58a738-1c2d-4e3f-8a9b-000000000004', document_number: 'ISS-2026-000004',
    event_time: '2026-11-04T12:00:00Z', posting_time: '2026-11-04T12:01:00Z', reason_code: null,
    legs: [leg(1, '12.500000000', 'i2', 'l1')],
  },
  {
    entry_id: 'jr-5', posting_seq: 1042, cause: 'opening', document_type: 'stock_opening', document_id: '5b58a738-1c2d-4e3f-8a9b-000000000005', document_number: 'OPN-2026-000001',
    event_time: '2026-11-01T08:00:00Z', posting_time: '2026-11-01T08:05:00Z', reason_code: null,
    legs: [leg(1, '250.000000000', 'i2', 'l1')],
  },
]

const routes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: (state, _p, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: { field: string; op: string; value?: unknown }[] }
      const ids = b.filters?.find((f) => f.field === 'record_id')?.value
      let items = MASTERS[b.entity_type ?? ''] ?? []
      if (Array.isArray(ids)) items = items.filter((r) => ids.includes(r.record_id))
      return { status: 200, body: { items: state === 'empty' ? [] : items, next_cursor: null } }
    },
  },
  {
    match: (path, method) => path === '/api/v1/modules/stock/movements' && method === 'GET',
    reply: (state) => ({ status: 200, body: { next_cursor: null, rows: state === 'empty' ? [] : MOVEMENTS } }),
  },
  {
    match: (path, method) => path.startsWith('/api/v1/modules/stock/documents/') && method === 'GET',
    reply: () => ({ status: 200, body: { id: 'doc', posted_by_label: 'Aigerim Sarsenova (E-017)' } }),
  },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant', tenant_type: 'test' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

const shell = (page: React.ReactElement) => (
  <AuthContext.Provider value={AUTH}>
    <div className="lf-main">
      <main className="lf-content">{page}</main>
    </div>
  </AuthContext.Provider>
)

export const stockJournalScreens: HarnessScreen[] = [
  { name: 'stock-journal-split', routes, render: () => shell(<MovementsPage initialSelectedId="jr-1" />) },
  { name: 'stock-journal-v1-expanded', routes, render: () => shell(<MovementsPage initialOpenId="jr-2" />) },
  { name: 'stock-journal-v3-details', routes, render: () => shell(<MovementsPage initialSelectedId="jr-1" initialDetail />) },
  { name: 'stock-journal-v2-sheet', routes, render: () => shell(<MovementsPage variant="v2" initialSelectedId="jr-1" initialDetail />) },
]
