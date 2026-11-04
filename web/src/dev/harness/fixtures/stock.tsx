/** Harness fixtures of the stock register screens (task T-1234, REQ-724). Invented data only. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import BalancesPage from '@/modules/stock/register/BalancesPage'
import MovementsPage from '@/modules/stock/register/MovementsPage'
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
  catalog_item: [
    rec('i1', 'catalog_item', { name: 'Laptop 14 inch, aluminium case, 16 GB' }),
    rec('i2', 'catalog_item', { name: 'Safety helmet' }),
  ],
  location_node: [rec('l1', 'location_node', { name: 'Almaty central warehouse' }), rec('l2', 'location_node', { name: 'Receiving dock' })],
  org_unit: [rec('u1', 'org_unit', { name: 'Warehouse team' })],
  org_employee: [rec('e1', 'org_employee', { full_name: 'Aigerim Sarsenova' })],
  catalog_lot: [rec('t1', 'catalog_lot', { code: 'LOT-2026-001', item_id: 'i1' })],
  catalog_uom: [rec('m1', 'catalog_uom', { name: 'pcs' })],
}

const BALANCES = [
  { sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'e1', lot: 't1', unit_ref: 'm1', quantity: '12.000' },
  { sku: 'i2', location: 'l2', org_unit: 'u1', responsible: null, lot: null, unit_ref: 'm1', quantity: '0.000' },
  { sku: 'i2', location: 'l1', org_unit: 'u1', responsible: null, lot: null, unit_ref: 'm1', quantity: '250.000' },
]
const MOVEMENTS = [
  {
    entry_id: 'en-1', posting_seq: 1042, cause: 'transfer', document_type: 'stock_transfer', document_id: 'doc-0001',
    event_time: '2026-11-03T09:15:00Z',
    legs: [
      { leg_no: 1, quantity: '-5.000', unit_ref: 'm1', sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'e1', lot: 't1' },
      { leg_no: 2, quantity: '5.000', unit_ref: 'm1', sku: 'i1', location: 'l2', org_unit: 'u1', responsible: null, lot: 't1' },
    ],
  },
  { entry_id: 'en-2', posting_seq: 1041, cause: 'receipt', document_type: 'stock_receipt', document_id: 'doc-0002', event_time: '2026-11-02T14:00:00Z',
    legs: [{ leg_no: 1, quantity: '250.000', unit_ref: 'm1', sku: 'i2', location: 'l1', org_unit: 'u1' }] },
  { entry_id: 'en-3', posting_seq: 1040, cause: 'reversal', document_type: null, document_id: null, event_time: null,
    legs: [{ leg_no: 1, quantity: '1.000', unit_ref: 'm1', masked: true }] },
]

const routes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: (state, _p, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: { field: string; op: string; value?: unknown }[] }
      const ids = b.filters?.find((f) => f.field === 'record_id')?.value
      let items = state === 'empty' ? [] : (MASTERS[b.entity_type ?? ''] ?? [])
      if (Array.isArray(ids)) items = items.filter((r) => ids.includes(r.record_id))
      return { status: 200, body: { items, next_cursor: null } }
    },
  },
  {
    match: (path, method) => path === '/api/v1/modules/stock/balances' && method === 'GET',
    reply: (state) => ({ status: 200, body: { ledger_seq: 1042, next_cursor: null, rows: state === 'empty' ? [] : BALANCES } }),
  },
  {
    match: (path, method) => path === '/api/v1/modules/stock/movements' && method === 'GET',
    reply: (state) => ({ status: 200, body: { next_cursor: null, rows: state === 'empty' ? [] : MOVEMENTS } }),
  },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

function withAuth(page: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <div className="lf-main">
        <main className="lf-content">{page}</main>
      </div>
    </AuthContext.Provider>
  )
}

export const stockScreens: HarnessScreen[] = [
  { name: 'stock-balances', routes, render: () => withAuth(<BalancesPage />) },
  { name: 'stock-movements', routes, render: () => withAuth(<MovementsPage />) },
  { name: 'stock-movements-legs', routes, render: () => withAuth(<MovementsPage initialOpenId="en-1" />) },
]
