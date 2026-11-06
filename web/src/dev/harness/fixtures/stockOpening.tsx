/** Harness fixtures of the opening balance stock document screens (task T-1316, REQ-725). Invented data only. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import DocumentNewPage from '@/modules/stock/documents/DocumentNewPage'
import DocumentPage from '@/modules/stock/documents/DocumentPage'
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
  catalog_item: [rec('i1', 'catalog_item', { name: 'Laptop 14 inch, aluminium case, 16 GB', base_uom_id: 'm1' })],
  location_node: [
    rec('l1', 'location_node', { name: 'Almaty central warehouse' }),
    rec('l2', 'location_node', { name: 'Astana branch, shelf B-12' }),
  ],
  org_unit: [rec('u1', 'org_unit', { name: 'Warehouse team' }), rec('u2', 'org_unit', { name: 'Sales department' })],
  org_employee: [
    rec('e1', 'org_employee', { full_name: 'Aigerim Sarsenova' }),
    rec('e2', 'org_employee', { full_name: 'Marat Kenzhebayev' }),
  ],
  catalog_uom: [rec('m1', 'catalog_uom', { name: 'pcs' })],
}

const line = (n: number, item: string, extra: Record<string, unknown>) => ({
  line_id: `ln${n}`, line_no: n, catalog_item_id: item, catalog_uom_id: 'm1', catalog_lot_id: null, quantity: '12.000',
  location_id: 'l1', responsible_id: 'e1', received_on: '2026-09-15', unit_price: '450000.00', ...extra,
})
const base = {
  kind: 'opening', org_unit_id: 'u1', location_id: null, responsible_id: null, event_time: null, note: 'Balances at the start of work', external_ref_system: 'erp', external_ref_id: 'OB-2026-01',
  lines: [line(1, 'i1', {}), line(2, 'i1', { location_id: 'l2', responsible_id: 'e2', received_on: '2026-10-02', unit_price: null })],
}
const DOCS: Record<string, Record<string, unknown>> = {
  'doc-open-draft': { ...base, id: 'doc-open-draft', state: 'draft', number: null },
  'doc-open-issued': { ...base, id: 'doc-open-issued', state: 'issued', number: 'OB-000001', issued_at: '2026-11-04T09:00:00Z' },
  'doc-open-posted': { ...base, id: 'doc-open-posted', state: 'posted', number: 'OB-000001', posted_at: '2026-11-04T10:00:00Z', posted_by: 'e2' },
}

export const routes: FixtureRoute[] = [
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
    match: (path, method) => /^\/api\/v1\/modules\/stock\/documents\/doc-open-[a-z]+$/.test(path) && method === 'GET',
    reply: (_s, path) => ({ status: 200, body: DOCS[path.split('/').pop() ?? ''] }),
  },
  {
    match: (path, method) => path.endsWith('/check') && method === 'POST',
    reply: () => ({ status: 200, body: { ok: false, lines: [{ line_no: 2, reasons: ['lot_required'] }] } }),
  },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, permissions: ['StockRead', 'StockPost', 'StockReverse'] },
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

export const stockOpeningScreens: HarnessScreen[] = [
  { name: 'stock-opening-new', routes, initialPath: '/?kind=opening', render: () => withAuth(<DocumentNewPage />) },
  { name: 'stock-opening-draft', routes, initialPath: '/doc-open-draft', routePattern: '/:id', render: () => withAuth(<DocumentPage />) },
  { name: 'stock-opening-issued', routes, initialPath: '/doc-open-issued', routePattern: '/:id', render: () => withAuth(<DocumentPage />) },
  { name: 'stock-opening-posted', routes, initialPath: '/doc-open-posted', routePattern: '/:id', render: () => withAuth(<DocumentPage />) },
]
