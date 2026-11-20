/** T-2290 harness screens: the quick count document (book, counted, difference) and the Movements journal with
 *  labelled cause codes (count_set, opening_negative). Invented data only. */
import DocumentPage from '@/modules/stock/documents/DocumentPage'
import DocumentsPage from '@/modules/stock/documents/DocumentsPage'
import MovementsPage from '@/modules/stock/register/MovementsPage'
import type { FixtureRoute, HarnessScreen } from '../types'
import { journalRoutes } from './stockJournal'
import { routes as documentRoutes, withAuth } from './stockDocuments'

const qcLine = (no: number, item: string, book: string, counted: string, difference: string) => ({
  line_id: `qln${no}`, line_no: no, catalog_item_id: item, catalog_uom_id: 'm1', catalog_lot_id: null,
  quantity: counted, book_quantity: book, counted_quantity: counted, difference,
})

const QC_DOC = {
  id: 'doc-qc', kind: 'quick_count', state: 'issued', number: 'QCT-2026-000042',
  org_unit_id: 'u1', location_id: 'l1', responsible_id: null, counterparty_id: null,
  event_time: '2026-11-18T02:00:00Z', reason_code: 'recount', reason_text: null,
  lines: [qcLine(1, 'i1', '10.000', '7.000', '-3.000'), qcLine(2, 'i2', '250.000', '262.000', '12.000')],
  posted_at: null, posted_by: null, reversed_at: null, reversed_by: null, posting_check: null,
}

const qcRoutes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/modules/stock/documents/doc-qc' && method === 'GET',
    reply: () => ({ status: 200, body: QC_DOC }),
  },
  ...documentRoutes,
]

// GH 4873: a count equal to the book (difference 0) is `confirmed` on the screen AND in the list.
const QC_CONFIRMED_DOC = {
  ...QC_DOC, id: 'doc-qc0', state: 'confirmed', number: 'QCT-2026-000043',
  lines: [qcLine(1, 'i1', '10.000', '10.000', '0.000')],
}
const QC_LIST_ROWS = [
  { id: 'doc-qc0', kind: 'quick_count', state: 'confirmed', number: 'QCT-2026-000043', org_unit_id: 'u1', event_time: '2026-11-18T03:00:00Z' },
  { id: 'doc-qc', kind: 'quick_count', state: 'issued', number: 'QCT-2026-000042', org_unit_id: 'u1', event_time: '2026-11-18T02:00:00Z' },
]
const qcConfirmedRoutes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/modules/stock/documents/doc-qc0' && method === 'GET',
    reply: () => ({ status: 200, body: QC_CONFIRMED_DOC }),
  },
  ...documentRoutes,
]
const qcListRoutes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/modules/stock/documents' && method === 'GET',
    reply: () => ({ status: 200, body: { next_cursor: null, rows: QC_LIST_ROWS } }),
  },
  ...documentRoutes,
]

const leg = (n: number, q: string, sku: string, location: string) => ({
  leg_no: n, quantity: q, unit_ref: 'm1', sku, location, org_unit: 'u1', responsible: null, lot: null,
})

const CAUSE_ROWS = [
  {
    entry_id: 'jr-c1', posting_seq: 1050, cause: 'count_set', document_type: 'stock_quick_count', document_id: 'doc-qc', document_number: 'QCT-2026-000042',
    event_time: '2026-11-18T02:00:00Z', posting_time: '2026-11-18T02:01:00Z', reason_code: 'recount', legs: [leg(1, '-3.000000000', 'i1', 'l1')],
  },
  {
    entry_id: 'jr-c2', posting_seq: 1049, cause: 'opening_negative', document_type: 'stock_opening', document_id: 'doc-opn7', document_number: 'OPN-2026-000007',
    event_time: '2026-11-17T08:00:00Z', posting_time: '2026-11-17T08:05:00Z', reason_code: null, legs: [leg(1, '-4.000000000', 'i2', 'l1')],
  },
]

const causeRoutes: FixtureRoute[] = journalRoutes.map((r) =>
  r.match('/api/v1/modules/stock/movements', 'GET')
    ? { ...r, reply: () => ({ status: 200, body: { next_cursor: null, rows: CAUSE_ROWS } }) }
    : r,
)

export const quickCountDocumentScreens: HarnessScreen[] = [
  { name: 'stock-qc-document', routes: qcRoutes, initialPath: '/doc-qc', routePattern: '/:id', render: () => withAuth(<DocumentPage />) },
  { name: 'stock-qc-document-confirmed', routes: qcConfirmedRoutes, initialPath: '/doc-qc0', routePattern: '/:id', render: () => withAuth(<DocumentPage />) },
  { name: 'stock-qc-documents-list', routes: qcListRoutes, render: () => withAuth(<DocumentsPage />) },
  { name: 'stock-qc-movements', routes: causeRoutes, render: () => withAuth(<MovementsPage initialSelectedId="jr-c1" />) },
  { name: 'stock-qc-movements-filters', routes: causeRoutes, render: () => withAuth(<MovementsPage initialFiltersOpen />) },
]
