/** Harness fixtures of the asset OPENING document screens (T-1877). Invented data only. Own file (one registry line).
 *  Cards carry their kind, cost, accumulated depreciation and acquisition date (read-only in the lines); the check route
 *  answers a result with reasons on two lines. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import DocumentNewPage from '@/modules/assets/documents/DocumentNewPage'
import DocumentPage from '@/modules/assets/documents/DocumentPage'
import type { EntityRecord, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'
import { ClickButton, EDIT_LABELS, SAVE_LABELS, routes as baseRoutes } from './assetsDocuments'

const rec = (id: string, type: string, fields: Record<string, unknown>): EntityRecord => ({
  record_id: id, entity_type: type, field_values: { active: true, ...fields }, deleted: false, entity_def_version: '1', last_event_global_seq: 1,
})
const CARDS: EntityRecord[] = [
  rec('a1', 'assets_card', { inventory_number: 'FA-0101', name: 'Delivery van Gazelle Next', kind: 'fixed', acquisition_cost: '8450000.00', accumulated_depreciation: '2112500.00', acquisition_date: '2022-03-15' }),
  rec('a2', 'assets_card', { inventory_number: 'LV-0201', name: 'Monitor 27 inch', kind: 'low_value', acquisition_cost: '85000.00', accumulated_depreciation: '0.00', acquisition_date: '2024-06-01' }),
  rec('a3', 'assets_card', { inventory_number: 'IA-0301', name: 'Accounting software licence', kind: 'intangible', acquisition_cost: '1200000.00', accumulated_depreciation: '400000.00', acquisition_date: '2023-01-10' }),
]

const ln = (n: number, over: Record<string, unknown>) => ({
  line_id: `op${n}`, line_no: n, asset_id: 'a1', quantity: '1.000000000', location_id: 'l1', material_responsible_id: 'e1', actual_user_id: null,
  external_ref_system: 'erp', external_ref_id: `row-${n}`, ...over,
})
const LINES = [
  ln(1, {}),
  ln(2, { asset_id: 'a2', quantity: '4.000000000', actual_user_id: 'e2' }),
  ln(3, { asset_id: 'a2', quantity: '2.000000000', location_id: 'l1', material_responsible_id: 'e2' }),
  ln(4, { asset_id: 'a3', location_id: null, material_responsible_id: 'e2' }),
]
const head = { kind: 'opening', org_unit_id: 'u1', event_time: null, note: 'Opening balances of the Almaty warehouse', external_ref_system: 'erp', external_ref_id: 'OP-2026-01' }
const DOCS: Record<string, Record<string, unknown>> = {
  'op-draft': { id: 'op-draft', state: 'draft', number: null, ...head, lines: LINES },
  'op-noref': { id: 'op-noref', state: 'draft', number: null, ...head, external_ref_system: null, external_ref_id: null, lines: LINES },
  'op-issued': { id: 'op-issued', state: 'issued', number: 'AOP-2026-000001', issued_at: '2026-11-03T09:30:00Z', ...head, lines: LINES },
  'op-posted': {
    id: 'op-posted', state: 'posted', number: 'AOP-2026-000001', issued_at: '2026-11-03T09:30:00Z', posted_at: '2026-11-03T10:00:00Z',
    posted_by: '5c1f0d2e-7a3b-4c4d-8e9f-0a1b2c3d4e5f', ...head, lines: LINES,
  },
  'op-empty': { id: 'op-empty', state: 'draft', number: null, ...head, external_ref_system: null, external_ref_id: null, lines: [] },
}
const CHECK = {
  ok: false,
  header: [],
  lines: [
    { line_no: 1, reasons: [], fields: [] },
    { line_no: 2, reasons: ['asset_already_in_register', 'not_linked'], fields: [] },
    { line_no: 3, reasons: ['employee_not_active'], fields: ['material_responsible_id', 'actual_user_id'] },
    { line_no: 4, reasons: ['location_not_allowed'], fields: [] },
  ],
}

const routes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: (state, p, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: { field: string; op: string; value?: unknown }[] }
      if (b.entity_type !== 'assets_card') return baseRoutes[0]!.reply(state, p, body)
      const ids = b.filters?.find((f) => f.field === 'record_id')?.value
      const own = Array.isArray(ids) ? CARDS.filter((r) => ids.includes(r.record_id)) : state === 'empty' ? [] : CARDS
      return { status: 200, body: { items: own, next_cursor: null } }
    },
  },
  {
    match: (path, method) => /\/documents\/op-[a-z]+\/check$/.test(path) && method === 'POST',
    reply: () => ({ status: 200, body: CHECK }),
  },
  {
    match: (path, method) => path.startsWith('/api/v1/modules/assets/documents/op-') && method === 'GET',
    reply: (_s, path) => {
      const doc = DOCS[decodeURIComponent(path.split('/').pop() ?? '')]
      return doc ? { status: 200, body: doc } : { status: 404, body: { error: 'not_found' } }
    },
  },
  ...baseRoutes,
]

const AUTH = { session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession, isAuthenticated: true } as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: {
    roles: [], platform_tenant: false,
    permissions: ['AssetsRead', 'AssetsPost', 'AssetsReverse', 'AssetsCardWrite', 'EntitiesRecordsImport', 'EntitiesRecordsExport'],
  },
}
function withOpeningAuth(page: ReactElement): ReactElement {
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

/** Harness only: the Check button label in every shipped language. */
const CHECK_LABELS = ['Check all lines', 'Проверить все строки', 'Барлық жолдарды тексеру']

const creating = (name: string, extra?: (el: ReactElement) => ReactElement): HarnessScreen => ({
  name, routes, initialPath: '/new?kind=opening', routePattern: '/new', render: () => withOpeningAuth((extra ?? ((e) => e))(<DocumentNewPage />)),
})
const view = (name: string, id: string, extra?: (el: ReactElement) => ReactElement): HarnessScreen => ({
  name, routes, initialPath: `/${id}`, routePattern: '/:id', render: () => withOpeningAuth((extra ?? ((e) => e))(<DocumentPage />)),
})

export const assetsOpeningScreens: HarnessScreen[] = [
  creating('asset-document-op-new'),
  creating('asset-document-op-errors', (e) => <ClickButton labels={SAVE_LABELS}>{e}</ClickButton>),
  view('asset-document-op-draft', 'op-draft'),
  view('asset-document-op-check', 'op-draft', (e) => <ClickButton labels={CHECK_LABELS}>{e}</ClickButton>),
  view('asset-document-op-edit', 'op-draft', (e) => <ClickButton labels={EDIT_LABELS}>{e}</ClickButton>),
  view('asset-document-op-edit-noref', 'op-noref', (e) => <ClickButton labels={EDIT_LABELS}>{e}</ClickButton>),
  view('asset-document-op-issued', 'op-issued'),
  view('asset-document-op-posted', 'op-posted'),
  view('asset-document-op-empty-lines', 'op-empty'),
]
