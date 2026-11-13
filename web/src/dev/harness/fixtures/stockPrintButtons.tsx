/** T-1913: actual document page print states; invented data only. */
import DocumentPage from '@/modules/stock/documents/DocumentPage'
import { StockIntlProvider } from '@/modules/stock/StockIntlProvider'
import { OfficialFormMenu } from '@/modules/stock/forms/OfficialFormMenu'
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
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

const doc = {
  id: 'doc-transfer', kind: 'transfer', state: 'posted', number: 'TR-000011', posted_at: '2026-11-03T10:00:00Z', posted_by: 'e1',
  org_unit_id: 'u1', from_location_id: 'l1', from_responsible_id: 'e1', to_org_unit_id: 'u2', to_location_id: 'l2', to_responsible_id: 'e2',
  event_time: '2026-11-03T09:15:00Z', note: 'Moved for the new office',
  lines: [{ line_id: 'ln1', line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: null, quantity: '12.000' }],
}

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

const states = [
  ['receipt-issued', 'receipt', 'issued'],
  ['issue-issued', 'issue', 'issued'],
  ['writeoff-issued', 'write_off', 'issued'],
  ['issue-reversed', 'issue', 'reversed'],
  ['opening-posted', 'opening', 'posted'],
] as const
export const stockPrintButtonsScreens: HarnessScreen[] = [
  ...states.map(([name, kind, state]) => {
    const routes: FixtureRoute[] = [
      { match: (p, m) => p === '/api/v1/entities/query' && m === 'POST', reply: (_state, _p, body) => {
        const b = (body ?? {}) as { entity_type?: string }
        return { status: 200, body: { items: MASTERS[b.entity_type ?? ''] ?? [], next_cursor: null } }
      } },
      { match: (p, m) => p === '/api/v1/modules/stock/documents/doc-transfer' && m === 'GET',
        reply: () => ({ status: 200, body: { ...doc, kind, state, location_id: 'l1', responsible_id: 'e1', reason_code: 'damaged' } }) },
    ]
    return { name: `stock-print-${name}`, routes, initialPath: '/doc-transfer', routePattern: '/:id', render: () => withAuth(<DocumentPage />) }
  }),
  { name: 'stock-print-issue-menu-kk', routes: [], render: () => withAuth(<StockIntlProvider><OfficialFormMenu forms={['z2']} busyKey={null} onPick={() => undefined} initialOpen /></StockIntlProvider>) },
]
