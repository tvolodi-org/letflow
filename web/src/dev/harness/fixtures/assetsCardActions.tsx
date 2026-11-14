/** Harness fixtures of the asset card actions (T-1880 / D-135): the card panel (tabs Main and Accounting, Actions menu in
 *  the header), the row menu, and the document form opened from a card with the card as its line. Invented data only. Own file
 *  (one registry line). The balances answer is per screen (the harness routes see the path, not the query string). */
import { useEffect, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import AssetCardsPage from '@/modules/assets/AssetCardsPage'
import DocumentNewPage from '@/modules/assets/documents/DocumentNewPage'
import DocumentPage from '@/modules/assets/documents/DocumentPage'
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
const card = (id: string, no: string, name: string, extra: Record<string, unknown> = {}) =>
  rec(id, 'assets_card', { inventory_number: no, name, kind: 'fixed', org_unit_id: 'u-wh', ...extra })

const MASTERS: Record<string, EntityRecord[]> = {
  assets_card: [
    card('c-1', 'FA-0001', 'Delivery van Gazelle Next'),
    card('c-2', 'FA-0002', 'Reach truck with a long model name for the wrapping check'),
    card('c-3', 'FA-0003', 'Office laser printer'),
    card('c-4', 'LV-0101', 'Monitor 27 inch', { kind: 'low_value' }),
    card('c-5', 'FA-0005', 'Desktop workstation'),
    card('c-7', 'FA-0007', 'Server rack UPS'),
    card('c-8', 'FA-0009', 'Forklift (sold)', { active: false }),
  ],
  org_unit: [rec('u-wh', 'org_unit', { code: 'WH', name: 'Warehouse team' }), rec('u-it', 'org_unit', { code: 'IT', name: 'IT department' })],
  location_node: [rec('l-1', 'location_node', { code: 'WH-A1', name: 'Warehouse A, rack 1' })],
  org_employee: [
    rec('e-1', 'org_employee', { code: 'E-014', full_name: 'Aigul Nurlanovna', name: 'Aigul Nurlanovna' }),
    rec('e-2', 'org_employee', { code: 'E-027', full_name: 'Bolat Serikov', name: 'Bolat Serikov' }),
  ],
}
const ROW = { asset: 'c-1', org_unit: 'u-wh', location: 'l-1', material_responsible: 'e-1', actual_user: 'e-2', unit_ref: 'pcs', quantity: '1.000000000' }
const ROW2 = { ...ROW, org_unit: 'u-it', location: null }
const HELD: Record<string, boolean> = { 'c-1': true, 'c-2': true, 'c-5': true }

type Clause = { field: string; op: string; value?: unknown }

function facts(rows: unknown[]): FixtureRoute[] {
  return [
    {
      match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
      reply: (_s, _p, body) => {
        const b = (body ?? {}) as { entity_type?: string; filters?: Clause[] }
        const filters = b.filters ?? []
        const onlyActive = filters.some((f) => f.field === 'active' && f.value === true)
        const ids = filters.find((f) => f.field === 'record_id' && f.op === 'in')?.value
        const one = filters.find((f) => f.field === 'record_id' && f.op === 'eq')?.value
        const items = (MASTERS[b.entity_type ?? ''] ?? []).filter(
          (r) =>
            (!onlyActive || r.field_values['active'] === true) &&
            (!Array.isArray(ids) || ids.includes(r.record_id)) &&
            (one === undefined || r.record_id === one),
        )
        return { status: 200, body: { items, next_cursor: null } }
      },
    },
    {
      match: (path, method) => /\/modules\/assets\/cards\/[^/]+\/lock$/.test(path) && method === 'GET',
      reply: (_s, path) => ({ status: 200, body: { posted: false, held: HELD[decodeURIComponent(path.split('/').slice(-2)[0])] === true } }),
    },
    {
      match: (path, method) => path === '/api/v1/modules/assets/balances' && method === 'GET',
      reply: () => ({ status: 200, body: { next_cursor: null, rows } }),
    },
    {
      match: (path, method) => path.startsWith('/api/v1/modules/assets/documents/') && method === 'GET',
      reply: () => ({
        status: 200,
        body: {
          id: 'd-1', kind: 'change', state: 'draft', number: null, org_unit_id: 'u-wh', location_id: 'l-1',
          from_material_responsible_id: 'e-1', from_actual_user_id: 'e-2', to_material_responsible_id: 'e-2', to_actual_user_id: null,
          event_time: '2026-11-13T09:15:00Z', note: null, lines: [{ line_id: 'ln1', line_no: 1, asset_id: 'c-1', quantity: '1.000000000' }],
        },
      }),
    },
    { match: (path, method) => path.startsWith('/api/v1/modules/assets/') && method !== 'GET', reply: () => ({ status: 200, body: {} }) },
  ]
}
const IN_REGISTER = facts([ROW])
const NO_ROWS = facts([])
const TWO_ROWS = facts([ROW2, { ...ROW, asset: 'c-4', quantity: '12.000000000' }])

const AUTH = { session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession, isAuthenticated: true } as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, permissions: ['AssetsRead', 'AssetsPost', 'AssetsReverse', 'AssetsCardWrite'] },
}
const withAuth = (page: ReactElement): ReactElement => (
  <AuthContext.Provider value={AUTH}>
    <AccessStateProvider state={ACCESS}>
      <div className="lf-main">
        <main className="lf-content">{page}</main>
      </div>
    </AccessStateProvider>
  </AuthContext.Provider>
)

/** Harness only: clicks the element with this test id once it exists (a shot cannot click). */
function ClickTestId({ id, children }: { id: string; children: ReactElement }): ReactElement {
  useEffect(() => {
    const t = window.setInterval(() => {
      const el = document.querySelector<HTMLElement>(`[data-testid="${id}"]`)
      if (el) {
        el.click()
        window.clearInterval(t)
      }
    }, 150)
    return () => window.clearInterval(t)
  }, [id])
  return children
}

/** Harness only: clicks checkboxes by test id once they exist (a shot cannot click). */
function TickTestIds({ ids, children }: { ids: string[]; children: ReactElement }): ReactElement {
  useEffect(() => {
    const remaining = new Set(ids)
    const t = window.setInterval(() => {
      for (const id of remaining) {
        const el = document.querySelector<HTMLElement>(`[data-testid="${id}"] input`)
        if (el) {
          el.click()
          remaining.delete(id)
        }
      }
      if (remaining.size === 0) window.clearInterval(t)
    }, 150)
    return () => window.clearInterval(t)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  return children
}

const panel = (name: string, cardId: string, routes: FixtureRoute[], open?: string, tab?: string): HarnessScreen => ({
  name,
  routes,
  render: () => {
    const page = <AssetCardsPage initialSelectedId={cardId} initialCardTab={tab} />
    return withAuth(open ? <ClickTestId id={open}>{page}</ClickTestId> : page)
  },
})
const fromCard = (name: string, kind: string, cardId: string, routes: FixtureRoute[]): HarnessScreen => ({
  name,
  routes,
  initialPath: `/new?kind=${kind}&asset=${cardId}`,
  routePattern: '/new',
  render: () => withAuth(<DocumentNewPage />),
})

export const assetsCardActionsScreens: HarnessScreen[] = [
  panel('asset-card-actions', 'c-1', IN_REGISTER),
  panel('asset-card-actions-menu', 'c-1', IN_REGISTER, 'card-actions-panel-c-1'),
  panel('asset-card-actions-new', 'c-3', NO_ROWS),
  panel('asset-card-actions-new-menu', 'c-3', NO_ROWS, 'card-actions-panel-c-3'),
  panel('asset-card-actions-pending', 'c-2', NO_ROWS),
  panel('asset-card-actions-pending-menu', 'c-2', NO_ROWS, 'card-actions-panel-c-2'),
  panel('asset-card-actions-lowvalue', 'c-4', TWO_ROWS),
  panel('asset-card-actions-lowvalue-menu', 'c-4', TWO_ROWS, 'card-actions-panel-c-4'),
  panel('asset-card-actions-retired', 'c-8', NO_ROWS),
  panel('asset-card-actions-retired-menu', 'c-8', NO_ROWS, 'card-actions-panel-c-8'),
  panel('asset-card-tabs-main', 'c-1', IN_REGISTER),
  panel('asset-card-tabs-accounting', 'c-1', IN_REGISTER, undefined, 'accounting'),
  panel('asset-card-tabs-retired-main', 'c-8', NO_ROWS),
  panel('asset-card-tabs-retired-accounting', 'c-8', NO_ROWS, undefined, 'accounting'),
  { name: 'asset-card-rows', routes: IN_REGISTER, render: () => withAuth(<AssetCardsPage />) },
  { name: 'asset-card-row-menu', routes: IN_REGISTER, render: () => withAuth(<ClickTestId id="card-actions-c-1"><AssetCardsPage /></ClickTestId>) },
  fromCard('asset-doc-from-card-commission', 'commission', 'c-3', NO_ROWS),
  fromCard('asset-doc-from-card-change', 'change', 'c-1', IN_REGISTER),
  fromCard('asset-doc-from-card-handover', 'handover', 'c-1', IN_REGISTER),
  fromCard('asset-doc-from-card-writeoff', 'writeoff', 'c-1', IN_REGISTER),
  fromCard('asset-doc-from-card-many', 'handover', 'c-4', TWO_ROWS),
  {
    name: 'asset-doc-back-to-card',
    routes: IN_REGISTER,
    initialPath: '/d-1?card=c-1',
    routePattern: '/:id',
    render: () => withAuth(<DocumentPage />),
  },
  {
    name: 'asset-doc-back-to-cards',
    routes: IN_REGISTER,
    initialPath: '/d-1?card=c-1&card=c-5',
    routePattern: '/:id',
    render: () => withAuth(<DocumentPage />),
  },
  {
    name: 'asset-card-select',
    routes: IN_REGISTER,
    render: () => withAuth(<TickTestIds ids={['card-select-c-1', 'card-select-c-5']}><AssetCardsPage /></TickTestIds>),
  },
  {
    name: 'asset-card-select-blocked',
    routes: NO_ROWS,
    render: () => withAuth(<TickTestIds ids={['card-select-c-1', 'card-select-c-3']}><AssetCardsPage /></TickTestIds>),
  },
  {
    name: 'asset-card-select-new',
    routes: NO_ROWS,
    render: () => withAuth(<TickTestIds ids={['card-select-c-3', 'card-select-c-7']}><AssetCardsPage /></TickTestIds>),
  },
  {
    name: 'asset-doc-from-cards-multi',
    routes: IN_REGISTER,
    initialPath: '/new?kind=change&asset=c-1&asset=c-5',
    routePattern: '/new',
    render: () => withAuth(<DocumentNewPage />),
  },
]
