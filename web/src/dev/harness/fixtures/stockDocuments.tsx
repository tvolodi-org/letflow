/** Harness fixtures of the stock document screens (task T-1233, REQ-722). Invented data only. */
import { useEffect, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import DocumentNewPage from '@/modules/stock/documents/DocumentNewPage'
import DocumentPage from '@/modules/stock/documents/DocumentPage'
import DocumentsPage from '@/modules/stock/documents/DocumentsPage'
import type { EntityRecord, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'
import { currenciesRoute } from './currencyDirectoryRoute'

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
    rec('i1', 'catalog_item', { name: 'Laptop 14 inch, aluminium case, 16 GB', base_uom_id: 'm1' }),
    rec('i2', 'catalog_item', { name: 'Safety helmet', base_uom_id: 'm1' }),
  ],
  catalog_counterparty: [rec('c1', 'catalog_counterparty', { name: 'Steppe Supply LLP' })],
  location_node: [rec('l1', 'location_node', { name: 'Almaty central warehouse' })],
  org_unit: [rec('u1', 'org_unit', { name: 'Warehouse team' })],
  org_employee: [rec('e1', 'org_employee', { full_name: 'Aigerim Sarsenova' })],
  catalog_lot: [rec('t1', 'catalog_lot', { code: 'LOT-2026-001', item_id: 'i1' })],
  catalog_uom: [rec('m1', 'catalog_uom', { name: 'pcs' })],
}

const lines = [
  { line_id: 'ln1', line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: 't1', quantity: '1.000000000', unit_price: '450000.000000000', line_value: '5400000.00' },
  { line_id: 'ln2', line_no: 2, catalog_item_id: 'i2', catalog_uom_id: 'm1', catalog_lot_id: null, quantity: '250.000', unit_price: '3500.00', line_value: '875000.00' },
]
const base = {
  org_unit_id: 'u1', location_id: 'l1', responsible_id: 'e1', counterparty_id: 'c1',
  event_time: '2026-11-03T09:15:00Z', note: 'Delivery on the morning truck',
  supplier_document_ref: 'INV-4471', received_on: '2026-11-03', lines,
}
const DOCS: Record<string, Record<string, unknown>> = {
  'doc-posted': { id: 'doc-posted', kind: 'receipt', state: 'posted', number: 'RC-000042', posted_at: '2026-11-03T10:00:00Z', posted_by: '5c1f0d2e-7a3b-4c4d-8e9f-0a1b2c3d4e5f', ...base },
  'doc-draft': { id: 'doc-draft', kind: 'receipt', state: 'draft', number: null, ...base },
  'doc-issued': { id: 'doc-issued', kind: 'issue', state: 'issued', number: 'IS-000007', ...base, counterparty_id: null },
}
const ROWS = [
  { id: 'doc-posted', kind: 'receipt', state: 'posted', number: 'RC-000042', org_unit_id: 'u1', event_time: '2026-11-03T09:15:00Z' },
  { id: 'doc-issued', kind: 'issue', state: 'issued', number: 'IS-000007', org_unit_id: 'u1', event_time: '2026-11-02T14:00:00Z' },
  { id: 'doc-draft', kind: 'receipt', state: 'draft', number: null, org_unit_id: 'u1', event_time: null },
  { id: 'doc-wo', kind: 'write_off', state: 'reversed', number: 'WO-000003', org_unit_id: 'u1', event_time: '2026-10-28T08:00:00Z' },
]

export const routes: FixtureRoute[] = [
  currenciesRoute,
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
    match: (path, method) => path === '/api/v1/modules/stock/documents' && method === 'GET',
    reply: (state) => ({ status: 200, body: { next_cursor: null, rows: state === 'empty' ? [] : ROWS } }),
  },
  {
    match: (path, method) => path.startsWith('/api/v1/modules/stock/documents/') && method === 'GET',
    reply: (_s, path) => {
      const doc = DOCS[decodeURIComponent(path.split('/').pop() ?? '')]
      return doc ? { status: 200, body: doc } : { status: 404, body: { error: 'not_found' } }
    },
  },
]

export const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
export const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, permissions: ['StockRead', 'StockPost', 'StockReverse'] },
}

export function withAuth(page: ReactElement): ReactElement {
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

/** Harness only: opens the loaded draft in edit mode (the edit state is local to the screen, a screenshot cannot click). */
/** Harness only: the Edit / Save draft button labels in every shipped language (the shots run in en, ru and kk). */
export const EDIT_LABELS = ['Edit', 'Изменить', 'Өзгерту']
export const SAVE_LABELS = ['Save draft', 'Сохранить черновик', 'Жобаны сақтау']

export function OpenInEdit({ children }: { children: ReactElement }): ReactElement {
  useEffect(() => {
    const id = window.setInterval(() => {
      const btn = Array.from(document.querySelectorAll('button')).find((b) => EDIT_LABELS.includes(b.textContent?.trim() ?? ''))
      if (btn) {
        btn.click()
        window.clearInterval(id)
      }
    }, 150)
    return () => window.clearInterval(id)
  }, [])
  return children
}

export const stockDocumentsScreens: HarnessScreen[] = [
  { name: 'stock-documents', routes, render: () => withAuth(<DocumentsPage />) },
  { name: 'stock-document-posted', routes, initialPath: '/doc-posted', routePattern: '/:id', render: () => withAuth(<DocumentPage />) },
  { name: 'stock-document-draft', routes, initialPath: '/doc-draft', routePattern: '/:id', render: () => withAuth(<DocumentPage />) },
  { name: 'stock-document-draft-edit', routes, initialPath: '/doc-draft', routePattern: '/:id', render: () => withAuth(<OpenInEdit><DocumentPage /></OpenInEdit>) },
  { name: 'stock-document-new-receipt', routes, initialPath: '/?kind=receipt', render: () => withAuth(<DocumentNewPage />) },
  { name: 'stock-document-new-issue', routes, initialPath: '/?kind=issue', render: () => withAuth(<DocumentNewPage />) },
  { name: 'stock-document-new-writeoff', routes, initialPath: '/?kind=write_off', render: () => withAuth(<DocumentNewPage />) },
]
