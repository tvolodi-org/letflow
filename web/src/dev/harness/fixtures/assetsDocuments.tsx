/** Harness fixtures of the asset document, balances and movements screens (T-1334 / C14). Invented data only.
 *  Own file (one registry line): sibling style tasks all edit the registry. */
import { useEffect, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import DocumentNewPage from '@/modules/assets/documents/DocumentNewPage'
import DocumentPage from '@/modules/assets/documents/DocumentPage'
import DocumentsPage from '@/modules/assets/documents/DocumentsPage'
import BalancesPage from '@/modules/assets/register/BalancesPage'
import MovementsPage from '@/modules/assets/register/MovementsPage'
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
  assets_card: [
    rec('a1', 'assets_card', { inventory_number: 'FA-0001', name: 'Delivery van Gazelle Next' }),
    rec('a2', 'assets_card', { inventory_number: 'FA-0002', name: 'Reach truck with a long model name for the wrapping check' }),
    rec('a3', 'assets_card', { inventory_number: 'LV-0101', name: 'Monitor 27 inch' }),
  ],
  org_unit: [
    rec('u1', 'org_unit', { code: 'WH', name: 'Warehouse team' }),
    rec('u2', 'org_unit', { code: 'IT', name: 'IT department' }),
  ],
  location_node: [rec('l1', 'location_node', { code: 'R-12', name: 'Almaty central warehouse' })],
  org_employee: [
    rec('e1', 'org_employee', { full_name: 'Aigerim Sarsenova' }),
    rec('e2', 'org_employee', { full_name: 'Marat Kenzhebekov' }),
  ],
}

const lines = [
  { line_id: 'ln1', line_no: 1, asset_id: 'a1', quantity: '1.000000000' },
  { line_id: 'ln2', line_no: 2, asset_id: 'a3', quantity: '2.000000000' },
]
const base = {
  org_unit_id: 'u1', location_id: 'l1', material_responsible_id: 'e1', actual_user_id: 'e2',
  event_time: '2026-11-03T09:15:00Z', note: 'Delivery on the morning truck', lines,
}
const POSTING = { posted_at: '2026-11-03T10:00:00Z', posted_by: '5c1f0d2e-7a3b-4c4d-8e9f-0a1b2c3d4e5f' }
const DOCS: Record<string, Record<string, unknown>> = {
  'doc-posted': { id: 'doc-posted', kind: 'commission', state: 'posted', number: 'ACM-2026-000042', ...POSTING, ...base },
  'doc-posted-150': { id: 'doc-posted-150', kind: 'commission', state: 'posted', number: 'ACM-2026-000150', ...POSTING, ...base, lines: Array.from({ length: 150 }, (_, i) => ({ line_id: `m${i}`, line_no: i + 1, asset_id: `a${(i % 3) + 1}`, quantity: `${1 + (i % 4)}.000000000` })) },
  'doc-draft': { id: 'doc-draft', kind: 'commission', state: 'draft', number: null, ...base },
  'doc-issued': { id: 'doc-issued', kind: 'handover', state: 'issued', number: 'AHO-2026-000007', issued_at: '2026-11-03T09:30:00Z', org_unit_id: 'u1', from_location_id: 'l1', from_material_responsible_id: 'e1', from_actual_user_id: null, to_org_unit_id: 'u2', to_location_id: null, to_material_responsible_id: 'e2', to_actual_user_id: 'e2', event_time: '2026-11-03T09:15:00Z', note: null, lines },
  'doc-reversed': { id: 'doc-reversed', kind: 'writeoff', state: 'reversed', number: 'AWO-2026-000003', ...POSTING, reversed_at: '2026-11-04T08:00:00Z', reversed_by: '5c1f0d2e-7a3b-4c4d-8e9f-0a1b2c3d4e5f', org_unit_id: 'u1', location_id: 'l1', material_responsible_id: 'e1', actual_user_id: null, reason_code: 'broken', reason_text: 'Dropped from the loading ramp', event_time: '2026-11-02T08:00:00Z', note: null, lines: [lines[0]] },
  'doc-mismatch': { id: 'doc-mismatch', kind: 'change', state: 'posted', number: 'ACH-2026-000011', posting_check: 'mismatch', ...POSTING, org_unit_id: 'u1', location_id: 'l1', from_material_responsible_id: 'e1', from_actual_user_id: null, to_material_responsible_id: 'e2', to_actual_user_id: 'e2', event_time: '2026-11-01T08:00:00Z', note: null, lines },
}
const ROWS = [
  { id: 'doc-posted', kind: 'commission', state: 'posted', number: 'ACM-2026-000042', org_unit_id: 'u1', event_time: '2026-11-03T09:15:00Z' },
  { id: 'doc-issued', kind: 'handover', state: 'issued', number: 'AHO-2026-000007', org_unit_id: 'u1', event_time: '2026-11-02T14:00:00Z' },
  { id: 'doc-draft', kind: 'commission', state: 'draft', number: null, org_unit_id: 'u1', event_time: null },
  { id: 'doc-reversed', kind: 'writeoff', state: 'reversed', number: 'AWO-2026-000003', org_unit_id: 'u1', event_time: '2026-10-28T08:00:00Z' },
  { id: 'doc-mismatch', kind: 'change', state: 'posted', number: 'ACH-2026-000011', org_unit_id: 'u1', event_time: '2026-10-27T08:00:00Z' },
]

const BALANCES = [
  { asset: 'a1', org_unit: 'u1', location: 'l1', material_responsible: 'e1', actual_user: null, unit_ref: 'pcs', quantity: '1.000000000', last_posting_seq: 3 },
  { asset: 'a2', org_unit: 'u1', location: null, material_responsible: 'e1', actual_user: 'e2', unit_ref: 'pcs', quantity: '1.000000000', last_posting_seq: 2 },
  { asset: 'a3', org_unit: 'u2', location: 'l1', material_responsible: 'e2', actual_user: 'e2', unit_ref: 'pcs', quantity: '12.500000000', last_posting_seq: 5 },
]
const leg = (no: number, asset: string, unit: string, loc: string | null, resp: string, user: string | null, qty: string) => ({
  leg_no: no, asset, org_unit: unit, location: loc, material_responsible: resp, actual_user: user, quantity: qty, unit_ref: 'pcs',
})
const MOVEMENTS = [
  { entry_id: 'en-1', posting_seq: 1, cause: 'commission', document_type: 'assets_commission', document_id: 'doc-posted', event_time: '2026-11-03T09:15:00Z', posting_time: '2026-11-03T10:00:00Z', legs: [leg(1, 'a1', 'u1', 'l1', 'e1', null, '1'), leg(2, 'a3', 'u1', 'l1', 'e1', null, '2')] },
  { entry_id: 'en-2', posting_seq: 2, cause: 'handover', document_type: 'assets_handover', document_id: 'doc-issued', event_time: '2026-11-04T09:15:00Z', posting_time: '2026-11-04T10:00:00Z', legs: [leg(1, 'a1', 'u1', 'l1', 'e1', null, '-1'), leg(2, 'a1', 'u2', null, 'e2', 'e2', '1')] },
  { entry_id: 'en-3', posting_seq: 3, cause: 'writeoff', document_type: 'assets_writeoff', document_id: 'doc-reversed', event_time: '2026-11-05T09:15:00Z', posting_time: '2026-11-05T10:00:00Z', legs: [leg(1, 'a3', 'u1', 'l1', 'e1', null, '-2')] },
  { entry_id: 'en-4', posting_seq: 4, cause: 'reversal', reverses_entry_id: 'en-3', document_type: 'assets_writeoff', document_id: 'doc-reversed', event_time: '2026-11-06T09:15:00Z', posting_time: '2026-11-06T10:00:00Z', legs: [leg(1, 'a3', 'u1', 'l1', 'e1', null, '2')] },
  { entry_id: 'en-5', posting_seq: 5, cause: 'change', document_type: 'assets_change', document_id: 'doc-mismatch', event_time: '2026-11-06T11:15:00Z', posting_time: '2026-11-06T11:30:00Z', legs: [{ leg_no: 1, masked: true, quantity: '1', unit_ref: 'pcs' }] },
]

export const routes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: (state, _p, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: { field: string; op: string; value?: unknown }[] }
      const ids = b.filters?.find((f) => f.field === 'record_id')?.value
      let items = MASTERS[b.entity_type ?? ''] ?? []
      if (Array.isArray(ids)) items = items.filter((r) => ids.includes(r.record_id))
      else if (state === 'empty') items = []
      return { status: 200, body: { items, next_cursor: null } }
    },
  },
  {
    match: (path, method) => path === '/api/v1/modules/assets/documents' && method === 'GET',
    reply: (state) => ({ status: 200, body: { next_cursor: null, rows: state === 'empty' ? [] : ROWS } }),
  },
  {
    match: (path, method) => path.startsWith('/api/v1/modules/assets/documents/') && method === 'GET',
    reply: (_s, path) => {
      const doc = DOCS[decodeURIComponent(path.split('/').pop() ?? '')]
      return doc ? { status: 200, body: doc } : { status: 404, body: { error: 'not_found' } }
    },
  },
  {
    match: (path, method) => path === '/api/v1/modules/assets/balances' && method === 'GET',
    reply: (state) => ({ status: 200, body: { ledger_seq: 5, coverage: 'visible_only', next_cursor: null, rows: state === 'empty' ? [] : BALANCES } }),
  },
  {
    match: (path, method) => path === '/api/v1/modules/assets/movements' && method === 'GET',
    reply: (state) => ({ status: 200, body: { next_cursor: null, rows: state === 'empty' ? [] : MOVEMENTS } }),
  },
  { match: (path, method) => path.startsWith('/api/v1/modules/assets/') && method !== 'GET', reply: () => ({ status: 200, body: {} }) },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, permissions: ['AssetsRead', 'AssetsPost', 'AssetsReverse'] },
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

/** Harness only: the Reverse button label in every shipped language (the shots run in en, ru and kk). */
const REVERSE_LABELS = ['Reverse', 'Сторнировать', 'Сторнолау']

/** Harness only: opens the reverse dialog of the loaded posted document (the dialog state is local, a shot cannot click). */
function OpenReverse({ children }: { children: ReactElement }): ReactElement {
  useEffect(() => {
    const id = window.setInterval(() => {
      const btn = Array.from(document.querySelectorAll('button')).find((b) => REVERSE_LABELS.includes(b.textContent?.trim() ?? ''))
      if (btn) {
        btn.click()
        window.clearInterval(id)
      }
    }, 150)
    return () => window.clearInterval(id)
  }, [])
  return children
}

/** Harness only: clicks the first button whose label is one of these (a shot cannot click): Edit, Save in every shipped language. */
function ClickButton({ labels, children }: { labels: string[]; children: ReactElement }): ReactElement {
  useEffect(() => {
    const id = window.setInterval(() => {
      const btn = Array.from(document.querySelectorAll('button')).find((b) => labels.includes(b.textContent?.trim() ?? ''))
      if (btn) {
        btn.click()
        window.clearInterval(id)
      }
    }, 150)
    return () => window.clearInterval(id)
  }, [labels])
  return children
}
const EDIT_LABELS = ['Edit', 'Изменить', 'Өзгерту']
const SAVE_LABELS = ['Save', 'Сохранить', 'Сақтау']

const creating = (name: string, kind: string, extra?: (el: ReactElement) => ReactElement): HarnessScreen => ({
  name,
  routes,
  initialPath: `/new?kind=${kind}`,
  routePattern: '/new',
  render: () => withAuth((extra ?? ((e) => e))(<DocumentNewPage />)),
})

const view = (name: string, id: string, extra?: (el: ReactElement) => ReactElement): HarnessScreen => ({
  name,
  routes,
  initialPath: `/${id}`,
  routePattern: '/:id',
  render: () => withAuth((extra ?? ((e) => e))(<DocumentPage />)),
})

export const assetsDocumentsScreens: HarnessScreen[] = [
  { name: 'asset-documents', routes, render: () => withAuth(<DocumentsPage />) },
  view('asset-document-draft', 'doc-draft'),
  view('asset-document-edit', 'doc-draft', (e) => <ClickButton labels={EDIT_LABELS}>{e}</ClickButton>),
  creating('asset-document-new', 'commission'),
  creating('asset-document-new-handover', 'handover'),
  creating('asset-document-new-writeoff', 'writeoff'),
  creating('asset-document-new-errors', 'change', (e) => <ClickButton labels={SAVE_LABELS}>{e}</ClickButton>),
  view('asset-document-issued', 'doc-issued'),
  view('asset-document-posted', 'doc-posted'),
  view('asset-document-posted-150', 'doc-posted-150'),
  view('asset-document-reverse', 'doc-posted', (e) => <OpenReverse>{e}</OpenReverse>),
  view('asset-document-reversed', 'doc-reversed'),
  view('asset-document-mismatch', 'doc-mismatch'),
  { name: 'asset-balances', routes, render: () => withAuth(<BalancesPage />) },
  { name: 'asset-balances-history', routes, render: () => withAuth(<BalancesPage initialSelectedId="a1|u1|l1|e1|" />) },
  { name: 'asset-balances-subtree', routes, render: () => withAuth(<BalancesPage initialFilters={{ scope_subtree: 'u1' }} />) },
  { name: 'asset-movements', routes, render: () => withAuth(<MovementsPage />) },
  { name: 'asset-movements-detail', routes, render: () => withAuth(<MovementsPage initialSelectedId="en-2" initialDetail />) },
  { name: 'asset-movements-masked', routes, render: () => withAuth(<MovementsPage initialSelectedId="en-5" initialDetail />) },
]
