/** Harness fixtures of the print button on the asset document screen (T-1915). Invented data only. Each state has its own
 *  screen name, so the shot tool never overwrites a file. The busy and error states appear only after a click: they are
 *  proven by `DocumentPrintButton.test.tsx` (W3, W4). Own file (one registry line). */
import DocumentPage from '@/modules/assets/documents/DocumentPage'
import type { FixtureRoute, HarnessScreen } from '../types'
import { routes as baseRoutes, withAuth } from './assetsDocuments'

const lines = [
  { line_id: 'ln1', line_no: 1, asset_id: 'a1', quantity: '1.000000000' },
  { line_id: 'ln2', line_no: 2, asset_id: 'a3', quantity: '2.000000000' },
]
const POSTING = { posted_at: '2026-11-03T10:00:00Z', posted_by: '5c1f0d2e-7a3b-4c4d-8e9f-0a1b2c3d4e5f' }
const side = { org_unit_id: 'u1', location_id: 'l1', event_time: '2026-11-03T09:15:00Z', note: null, lines }
const DOCS: Record<string, Record<string, unknown>> = {
  'print-commission-issued': { id: 'print-commission-issued', kind: 'commission', state: 'issued', number: 'ACM-2026-000051', issued_at: '2026-11-03T09:30:00Z', ...side, material_responsible_id: 'e1', actual_user_id: 'e2' },
  'print-change-posted': { id: 'print-change-posted', kind: 'change', state: 'posted', number: 'ACH-2026-000012', ...POSTING, ...side, from_material_responsible_id: 'e1', from_actual_user_id: null, to_material_responsible_id: 'e2', to_actual_user_id: 'e2' },
  'print-handover-posted': { id: 'print-handover-posted', kind: 'handover', state: 'posted', number: 'AHO-2026-000008', ...POSTING, org_unit_id: 'u1', from_location_id: 'l1', from_material_responsible_id: 'e1', from_actual_user_id: null, to_org_unit_id: 'u2', to_location_id: null, to_material_responsible_id: 'e2', to_actual_user_id: 'e2', event_time: '2026-11-03T09:15:00Z', note: null, lines },
  'print-kind-change-posted': { id: 'print-kind-change-posted', kind: 'kind_change', state: 'posted', number: 'AKC-2026-000002', ...POSTING, org_unit_id: 'u1', reason_text: 'Stock became assets', event_time: '2026-11-03T09:15:00Z', note: null, lines: [] },
}
const ownDocs: FixtureRoute = {
  match: (path, method) => method === 'GET' && path.startsWith('/api/v1/modules/assets/documents/print-'),
  reply: (_s, path) => {
    const doc = DOCS[decodeURIComponent(path.split('/').pop() ?? '')]
    return doc ? { status: 200, body: doc } : { status: 404, body: { error: 'not_found' } }
  },
}
const routes: FixtureRoute[] = [ownDocs, ...baseRoutes]

const view = (name: string, id: string): HarnessScreen => ({
  name,
  routes,
  initialPath: `/${id}`,
  routePattern: '/:id',
  render: () => withAuth(<DocumentPage />),
})

export const assetsPrintButtonsScreens: HarnessScreen[] = [
  view('asset-print-commission-issued', 'print-commission-issued'),
  view('asset-print-change-posted', 'print-change-posted'),
  view('asset-print-handover-posted', 'print-handover-posted'),
  view('asset-print-writeoff-reversed', 'doc-reversed'),
  view('asset-print-commission-draft', 'doc-draft'),
  view('asset-print-kind-change-posted', 'print-kind-change-posted'),
]
