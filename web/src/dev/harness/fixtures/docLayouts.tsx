/** Harness fixtures of the document-layout screens (task T-1391). Invented data only. The same document screens in
 *  the `row` and `tabs` layouts (the preferences route answers the layout per screen), the create form in tabs with a
 *  problem badge on the hidden tab, "My settings" and the tenant default section. */
import { useEffect, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import DocumentNewPage from '@/modules/stock/documents/DocumentNewPage'
import DocumentPage from '@/modules/stock/documents/DocumentPage'
import MySettingsPage from '@/pages/me/MySettingsPage'
import { TenantLayoutDefault } from '@/pages/admin/TenantLayoutDefault'
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
  catalog_item: [rec('i1', 'catalog_item', { name: 'Laptop 14 inch, aluminium case', base_uom_id: 'm1' }), rec('i2', 'catalog_item', { name: 'Safety helmet', base_uom_id: 'm1' })],
  catalog_counterparty: [rec('c1', 'catalog_counterparty', { name: 'Steppe Supply LLP' })],
  location_node: [rec('l1', 'location_node', { name: 'Almaty central warehouse' })],
  org_unit: [rec('u1', 'org_unit', { name: 'Warehouse team' })],
  org_employee: [rec('e1', 'org_employee', { full_name: 'Aigerim Sarsenova' })],
  catalog_lot: [rec('t1', 'catalog_lot', { code: 'LOT-2026-001', item_id: 'i1' })],
  catalog_uom: [rec('m1', 'catalog_uom', { name: 'pcs' })],
}
const DOC = {
  id: 'doc-posted', kind: 'receipt', state: 'posted', number: 'RC-000042', posted_at: '2026-11-03T10:00:00Z',
  org_unit_id: 'u1', location_id: 'l1', responsible_id: 'e1', counterparty_id: 'c1', event_time: '2026-11-03T09:15:00Z',
  note: 'Delivery on the morning truck', supplier_document_ref: 'INV-4471', received_on: '2026-11-03',
  lines: [
    { line_id: 'ln1', line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: 't1', quantity: '12.000', unit_price: '450000.00', line_value: '5400000.00' },
    { line_id: 'ln2', line_no: 2, catalog_item_id: 'i2', catalog_uom_id: 'm1', catalog_lot_id: null, quantity: '250.000', unit_price: '3500.00', line_value: '875000.00' },
  ],
}
const ROWS = [
  { id: 'doc-posted', kind: 'receipt', state: 'posted', number: 'RC-000042', org_unit_id: 'u1', event_time: '2026-11-03T09:15:00Z' },
  { id: 'doc-draft', kind: 'receipt', state: 'draft', number: null, org_unit_id: 'u1', event_time: null },
]

function routes(layout: 'row' | 'tabs', tenant: 'row' | 'tabs' = 'row'): FixtureRoute[] {
  return [
    {
      match: (path, method) => path === '/api/v1/me/preferences' && method === 'GET',
      reply: () => ({
        status: 200,
        body: {
          preferences: layout === tenant ? {} : { 'ui.document_layout': layout },
          effective: { 'ui.document_layout': layout },
          tenant_defaults: { 'ui.document_layout_default': tenant },
        },
      }),
    },
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
    {
      match: (path, method) => path === '/api/v1/modules/stock/documents' && method === 'GET',
      reply: () => ({ status: 200, body: { next_cursor: null, rows: ROWS } }),
    },
    {
      match: (path, method) => path.startsWith('/api/v1/modules/stock/documents/') && method === 'GET',
      reply: () => ({ status: 200, body: DOC }),
    },
  ]
}

const AUTH = { session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession, isAuthenticated: true } as unknown as AuthContextValue
const ACCESS = { status: 'ready' as const, info: { roles: [], platform_tenant: false, permissions: ['StockRead', 'StockPost', 'TenantSettingsManage'] } }

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

/** Presses Save on the empty create form so the problem badge shows on the hidden tab. */
function SaveThenShowLines() {
  useEffect(() => {
    const frame = requestAnimationFrame(() => {
      document.querySelector<HTMLElement>('[data-testid="document-tab-lines"]')?.click()
      requestAnimationFrame(() => document.querySelector<HTMLElement>('.lf-doc__actions .lf-btn--primary')?.click())
    })
    return () => cancelAnimationFrame(frame)
  }, [])
  return null
}

export const docLayoutScreens: HarnessScreen[] = [
  { name: 'doc-layout-row', routes: routes('row'), initialPath: '/doc-posted', routePattern: '/:id', render: () => withAuth(<DocumentPage />) },
  { name: 'doc-layout-tabs', routes: routes('tabs'), initialPath: '/doc-posted', routePattern: '/:id', render: () => withAuth(<DocumentPage />) },
  { name: 'doc-layout-tabs-new', routes: routes('tabs'), initialPath: '/?kind=receipt', render: () => withAuth(<DocumentNewPage />) },
  {
    name: 'doc-layout-tabs-problems',
    routes: routes('tabs'),
    initialPath: '/?kind=receipt',
    render: () => withAuth(<><DocumentNewPage /><SaveThenShowLines /></>),
  },
  { name: 'my-settings', routes: routes('row', 'row'), render: () => withAuth(<MySettingsPage />) },
  { name: 'my-settings-tabs', routes: routes('tabs', 'row'), render: () => withAuth(<MySettingsPage />) },
  { name: 'tenant-layout-default', routes: routes('tabs', 'tabs'), render: () => withAuth(<TenantLayoutDefault />) },
]
