/** Harness fixtures of the stock balance history panel (task T-1430). Invented data only. The balances route always
 *  answers; only the movements route follows the harness state (empty / error), so the panel shows its own states. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import BalancesPage from '@/modules/stock/register/BalancesPage'
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
  catalog_item: [rec('i1', 'catalog_item', { code: 'ITM-0001', name: 'Laptop 14 inch, aluminium case, 16 GB' })],
  location_node: [rec('l1', 'location_node', { code: 'WH-ALA', name: 'Almaty central warehouse' }), rec('l2', 'location_node', { code: 'DOCK-1', name: 'Receiving dock' })],
  org_unit: [rec('u1', 'org_unit', { code: 'WT', name: 'Warehouse team' })],
  org_employee: [rec('e1', 'org_employee', { code: 'E-017', full_name: 'Aigerim Sarsenova' })],
  catalog_lot: [rec('t1', 'catalog_lot', { code: 'LOT-2026-001', item_id: 'i1' })],
  catalog_uom: [rec('m1', 'catalog_uom', { code: 'PCS', name: 'pcs' })],
}

const BALANCES = [
  { sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'e1', lot: 't1', unit_ref: 'm1', quantity: '12.000' },
  { sku: 'i1', location: 'l2', org_unit: 'u1', responsible: 'e1', lot: 't1', unit_ref: 'm1', quantity: '5.000' },
]
const leg = (no: number, quantity: string, location: string) => ({ leg_no: no, quantity, unit_ref: 'm1', sku: 'i1', location, org_unit: 'u1', responsible: 'e1', lot: 't1' })
const MOVEMENTS = [
  { entry_id: 'en-1', posting_seq: 1001, cause: 'receipt', document_type: 'stock_receipt', document_id: 'doc-1', document_number: 'RCP-2026-000012', event_time: '2026-11-01T09:15:00Z', legs: [leg(1, '20.000', 'l1')] },
  { entry_id: 'en-2', posting_seq: 1020, cause: 'transfer', document_type: 'stock_transfer', document_id: 'doc-2', document_number: 'TRF-2026-000004', event_time: '2026-11-03T11:40:00Z', legs: [leg(1, '-5.000', 'l1'), leg(2, '5.000', 'l2')] },
  { entry_id: 'en-3', posting_seq: 1041, cause: 'issue', document_type: 'stock_issue', document_id: 'doc-3', document_number: 'ISS-2026-000031', event_time: '2026-11-05T15:05:00Z', legs: [leg(1, '-3.000', 'l1')] },
]

export const routes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: (_state, _p, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: { field: string; op: string; value?: unknown }[] }
      const ids = b.filters?.find((f) => f.field === 'record_id')?.value
      let items = MASTERS[b.entity_type ?? ''] ?? []
      if (Array.isArray(ids)) items = items.filter((r) => ids.includes(r.record_id))
      return { status: 200, body: { items, next_cursor: null } }
    },
  },
  {
    match: (path, method) => path === '/api/v1/modules/stock/balances' && method === 'GET',
    reply: () => ({ status: 200, body: { ledger_seq: 1041, next_cursor: null, rows: BALANCES } }),
  },
  {
    match: (path, method) => path === '/api/v1/modules/stock/movements' && method === 'GET',
    reply: (state) =>
      state === 'error'
        ? { status: 500, body: { error: 'internal' } }
        : { status: 200, body: { next_cursor: null, rows: state === 'empty' ? [] : MOVEMENTS } },
  },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

export function withAuth(page: ReactElement, fluid = false): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <div className="lf-main">
        <main className={fluid ? 'lf-content lf-content--fluid' : 'lf-content'}>{page}</main>
      </div>
    </AuthContext.Provider>
  )
}

const open = <BalancesPage initialSelectedId="i1|l1|u1|e1|t1|m1" />

/** The movements route always fails: the panel's own error banner and retry, with the balances list intact. */
const failingRoutes: FixtureRoute[] = routes.map((r) =>
  r.match('/api/v1/modules/stock/movements', 'GET')
    ? { ...r, reply: () => ({ status: 500, body: { error: 'internal' } }) }
    : r,
)

export const stockBalanceHistoryScreens: HarnessScreen[] = [
  { name: 'stock-balance-history', routes, render: () => withAuth(open) },
  { name: 'stock-balance-history-failing', routes: failingRoutes, render: () => withAuth(open) },
]
