/** Harness fixtures of the scanner, differences and signers screens (task T-1269, REQ-720). Invented data only. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import CountsPage from '@/modules/stock/counts/CountsPage'
import { SignersDialog } from '@/modules/stock/counts/SignersDialog'
import { StockIntlProvider } from '@/modules/stock/StockIntlProvider'
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
  org_employee: [
    rec('e1', 'org_employee', { full_name: 'Aigerim Sarsenova' }),
    rec('e2', 'org_employee', { full_name: 'Marat Kenzhebekov' }),
    rec('e3', 'org_employee', { full_name: 'Dana Serikova' }),
  ],
  location_node: [rec('l1', 'location_node', { name: 'Hall A, shelf 1' }), rec('l2', 'location_node', { name: 'Receiving dock' })],
  catalog_item: [rec('i1', 'catalog_item', { name: 'Safety helmet' }), rec('i2', 'catalog_item', { name: 'Laptop 14 inch, aluminium case' })],
  catalog_uom: [rec('m1', 'catalog_uom', { name: 'pcs' })],
  catalog_lot: [rec('t1', 'catalog_lot', { code: 'LOT-2026-001', item_id: 'i2' })],
}

const ORDERS = [
  { id: 'c2', number: 'CNT-0002', org_unit_id: 'u1', kind: 'selective', status: 'counting', planned_start: '2026-11-03T04:00:00Z', planned_end: '2026-11-04T12:00:00Z', chair_employee_id: 'e1', member_employee_ids: ['e2'], location_ids: ['l1', 'l2'], note: null, issued_at: '2026-11-02T08:00:00Z' },
  { id: 'c3', number: 'CNT-0003', org_unit_id: 'u1', kind: 'full', status: 'counted', planned_start: '2026-10-20T04:00:00Z', planned_end: '2026-10-21T12:00:00Z', chair_employee_id: 'e1', member_employee_ids: ['e2', 'e3'], location_ids: ['l1'], note: null, issued_at: '2026-10-19T08:00:00Z', sheet_document_id: 'd1', sheet_signed_at: '2026-10-21T13:00:00Z', differences_document_id: 'd2', differences_number: 'DIF-0003' },
]
const LINES = [
  { line_no: 1, kind: 'stock', location_id: 'l1', catalog_item_id: 'i1', catalog_lot_id: null, responsible_employee_id: 'e1', unit_ref: 'm1', book_quantity: '40.000', counted_quantity: '38' },
  { line_no: 2, kind: 'stock', location_id: 'l1', catalog_item_id: 'i2', catalog_lot_id: 't1', responsible_employee_id: 'e3', unit_ref: 'm1', book_quantity: '12.000', counted_quantity: '12' },
  { line_no: 3, kind: 'surplus', location_id: 'l1', catalog_item_id: 'i1', catalog_lot_id: null, responsible_employee_id: 'e2', unit_ref: 'm1', book_quantity: '0', counted_quantity: '2' },
]
const DIFFERENCES = {
  number: 'DIF-0003', version_no: 1, issued_at: '2026-10-21T13:10:00Z', content_hash: 'abc',
  lines: [
    { line_no: 1, location_id: 'l1', catalog_item_id: 'i1', responsible_employee_id: 'e1', unit_ref: 'm1', book_quantity: '40.000', counted_quantity: '38', difference: '-2', direction: 'shortage' },
    { line_no: 3, location_id: 'l1', catalog_item_id: 'i1', responsible_employee_id: 'e2', unit_ref: 'm1', book_quantity: '0', counted_quantity: '2', difference: '2', direction: 'surplus' },
  ],
}
const SIGNATURES = [
  { document_kind: 'sheet', version_no: 1, employee_id: 'e1', signer_role: 'chair', marked_at: '2026-10-21T13:00:00Z' },
  { document_kind: 'sheet', version_no: 1, employee_id: 'e2', signer_role: 'member', marked_at: '2026-10-21T13:00:00Z' },
  { document_kind: 'sheet', version_no: 1, employee_id: 'e3', signer_role: 'member', marked_at: '2026-10-21T13:00:00Z' },
]

const routes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: (state, _p, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: { field: string; value?: unknown }[] }
      const ids = b.filters?.find((f) => f.field === 'record_id')?.value
      let items = state === 'empty' ? [] : (MASTERS[b.entity_type ?? ''] ?? [])
      if (Array.isArray(ids)) items = items.filter((r) => ids.includes(r.record_id))
      return { status: 200, body: { items, next_cursor: null } }
    },
  },
  { match: (path, method) => /\/counts$/.test(path) && method === 'GET', reply: () => ({ status: 200, body: { rows: ORDERS, next_cursor: null } }) },
  {
    match: (path, method) => /\/counts\/c\d$/.test(path) && method === 'GET',
    reply: (_s, path) => ({ status: 200, body: ORDERS.find((o) => path.endsWith(o.id)) ?? ORDERS[0] }),
  },
  {
    match: (path, method) => /\/counts\/c\d\/lines$/.test(path) && method === 'GET',
    reply: (state) => ({ status: 200, body: { rows: state === 'empty' ? [] : LINES, next_cursor: null } }),
  },
  { match: (path, method) => /\/entries$/.test(path) && method === 'GET', reply: () => ({ status: 200, body: { rows: [], next_cursor: null } }) },
  { match: (path, method) => /\/differences$/.test(path) && method === 'GET', reply: (state) => ({ status: 200, body: state === 'empty' ? { ...DIFFERENCES, lines: [] } : DIFFERENCES }) },
  { match: (path, method) => /\/signatures$/.test(path) && method === 'GET', reply: () => ({ status: 200, body: { rows: SIGNATURES } }) },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

function withAuth(page: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider
        state={{ status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['StockRead', 'StockCountOrder', 'StockCountRecord'] } }}
      >
        <div className="lf-main">
          <main className="lf-content">{page}</main>
        </div>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

const NAMES: Record<string, string> = { e1: 'Aigerim Sarsenova', e2: 'Marat Kenzhebekov', e3: 'Dana Serikova' }

export const stockCountDiffScreens: HarnessScreen[] = [
  { name: 'stock-count-scan', initialPath: '/admin/stock/counts/c2', routePattern: '/admin/stock/counts/:id', routes, render: () => withAuth(<CountsPage />) },
  { name: 'stock-count-differences', initialPath: '/admin/stock/counts/c3', routePattern: '/admin/stock/counts/:id', routes, render: () => withAuth(<CountsPage />) },
  {
    name: 'stock-count-signers-dialog',
    initialPath: '/',
    routePattern: '/',
    routes,
    render: () => (
      <StockIntlProvider>
        <SignersDialog
          title="Who signed the count sheet?"
          signers={[{ id: 'e1', role: 'chair' }, { id: 'e2', role: 'member' }, { id: 'e3', role: 'responsible' }]}
          nameOf={(id) => NAMES[id] ?? id}
          isLoading={false}
          error={null}
          onConfirm={() => undefined}
          onCancel={() => undefined}
        />
      </StockIntlProvider>
    ),
  },
]
