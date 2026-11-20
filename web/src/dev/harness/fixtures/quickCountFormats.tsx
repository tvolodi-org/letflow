/** T-2364 harness screens: the quantities of the quick count chain shown in the Balances number format.
 *
 *  The server keeps up to 9 decimals; the screens show at most 3, trimmed and grouped by the user's language
 *  (`formatQuantity`). These screens carry the raw 9-decimal values so a screenshot shows the formatted result:
 *  the form's book quantity and live difference, the result panel, the document screen and the workbook check
 *  table. Invented data only. */
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import DocumentPage from '@/modules/stock/documents/DocumentPage'
import { QuickCountPageHarness } from '@/modules/stock/quickCount/QuickCountPage'
import { WorkbookImportPageHarness } from '@/modules/stock/workbook/WorkbookImportPage'
import type { WorkbookCheckResult } from '@/modules/stock/workbook/workbook.api'
import type { EntityRecord, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'
import { routes as documentRoutes, withAuth } from './stockDocuments'

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
    rec('i1', 'catalog_item', { code: 'GLV-L', name: 'Safety gloves (L)', base_uom_id: 'm1', tracking_policy: 'none' }),
  ],
  location_node: [rec('l1', 'location_node', { name: 'Warehouse A' })],
  org_unit: [rec('u1', 'org_unit', { name: 'Procurement' })],
  catalog_uom: [rec('m1', 'catalog_uom', { name: 'pcs' })],
}

/** The book's raw value: nine decimals, as the server sends it. */
const BOOK_RAW = '857.000000000'
/** A counted quantity beyond the float precision; the difference keeps nine decimals too. */
const COUNTED_RAW = '12345678901.123456789'
/** 12345678901.123456789 - 857.000000000, the exact difference of the two. */
const DIFFERENCE_RAW = '12345678044.123456789'

const FILLED_FORM = {
  itemId: 'i1',
  locationId: 'l1',
  orgUnitId: 'u1',
  lotId: '',
  countedQuantity: '857',
  reasonCode: 'recount',
  reasonText: '',
}

const QC_SESSION = {
  session: { token: 'harness', tenant_id: 'harness-tenant', tenant_slug: 'demo', display_name: 'Aigerim S.', tenant_display_name: 'Demo Holding', tenant_type: 'production' } as unknown as UserSession,
  isAuthenticated: true,
  isLoading: false,
  loginSource: null,
  login: () => {},
  logout: () => {},
  setSession: () => {},
} as unknown as AuthContextValue

const QC_ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, permissions: ['StockQuickCount', 'StockRead'] },
}

function withQCAuth(element: React.ReactElement) {
  return (
    <AuthContext.Provider value={QC_SESSION}>
      <AccessStateProvider state={QC_ACCESS}>
        <div className="lf-main">
          <main className="lf-content">{element}</main>
        </div>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

function entitiesRoute(): FixtureRoute {
  return {
    match: (p, m) => p === '/api/v1/entities/query' && m === 'POST',
    reply: (_s, _p, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: { field: string; op: string; value?: unknown }[] }
      const ids = b.filters?.find((f) => f.field === 'record_id')?.value
      let items = MASTERS[b.entity_type ?? ''] ?? []
      if (Array.isArray(ids)) items = items.filter((r) => ids.includes(r.record_id))
      return { status: 200, body: { items, next_cursor: null } }
    },
  }
}

function balanceRoute(quantity: string): FixtureRoute {
  return {
    match: (p, m) => p === '/api/v1/modules/stock/balances' && m === 'GET',
    reply: () => ({
      status: 200,
      body: { rows: [{ sku: 'i1', location: 'l1', org_unit: 'u1', responsible: null, lot: null, unit_ref: 'm1', quantity }], next_cursor: null },
    }),
  }
}

function tasksListRoute(): FixtureRoute {
  return {
    match: (p, m) => p === '/api/v1/tasks' && m === 'GET',
    reply: () => ({ status: 200, body: { items: [], next_cursor: null } }),
  }
}

/** The document the quick count form writes: the same three quantities, raw. */
const QC_DOC = {
  id: 'doc-qc-fmt', kind: 'quick_count', state: 'issued', number: 'QCT-2026-000044',
  org_unit_id: 'u1', location_id: 'l1', responsible_id: null, counterparty_id: null,
  event_time: '2026-11-18T02:00:00Z', reason_code: 'recount', reason_text: null,
  lines: [{
    line_id: 'qln1', line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: null,
    quantity: COUNTED_RAW, book_quantity: BOOK_RAW, counted_quantity: COUNTED_RAW, difference: DIFFERENCE_RAW,
  }],
  posted_at: null, posted_by: null, reversed_at: null, reversed_by: null, posting_check: null,
}

const qcDocumentRoutes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/modules/stock/documents/doc-qc-fmt' && method === 'GET',
    reply: () => ({ status: 200, body: QC_DOC }),
  },
  ...documentRoutes,
]

/** The workbook check table: the same three quantities, raw. */
const WB_CHECK: WorkbookCheckResult = {
  sheet: 'Остатки 2026-11-18',
  rows_read: 143,
  remarks: [],
  changes: [
    { row: 1, item_code: 'GLV-L', item_name: 'Safety gloves (L)', place_code: 'A-01', book_quantity: BOOK_RAW, file_quantity: COUNTED_RAW, difference: DIFFERENCE_RAW },
  ],
  unchanged_count: 142,
  too_many_changes: false,
}

export const quickCountFormatScreens: HarnessScreen[] = [
  // The form with the book's raw nine decimals: the balance reads 857, not 857.000000000.
  {
    name: 'stock-qc-format-book',
    routes: [entitiesRoute(), balanceRoute(BOOK_RAW)],
    initialPath: '/admin/stock/quick-count',
    routePattern: '/admin/stock/quick-count',
    render: () => withQCAuth(<QuickCountPageHarness initialForm={FILLED_FORM} />),
  },
  // The form with a nine-decimal counted quantity: the live difference is grouped and trimmed.
  {
    name: 'stock-qc-format-difference',
    routes: [entitiesRoute(), balanceRoute(BOOK_RAW)],
    initialPath: '/admin/stock/quick-count',
    routePattern: '/admin/stock/quick-count',
    render: () => withQCAuth(<QuickCountPageHarness initialForm={{ ...FILLED_FORM, countedQuantity: COUNTED_RAW }} />),
  },
  // The result panel: book, counted and difference in the same format.
  {
    name: 'stock-qc-format-result',
    routes: [entitiesRoute(), tasksListRoute()],
    initialPath: '/admin/stock/quick-count',
    routePattern: '/admin/stock/quick-count',
    render: () => withQCAuth(<QuickCountPageHarness initialResult={QC_DOC} />),
  },
  // The document screen: the same three quantities on the lines.
  {
    name: 'stock-qc-format-document',
    routes: qcDocumentRoutes,
    initialPath: '/doc-qc-fmt',
    routePattern: '/:id',
    render: () => withAuth(<DocumentPage />),
  },
  // The workbook check table: book, file and difference in the same format.
  {
    name: 'stock-wb-format-quantities',
    routes: [entitiesRoute()],
    initialPath: '/admin/stock/workbook-import',
    routePattern: '/admin/stock/workbook-import',
    render: () =>
      withAuth(
        <WorkbookImportPageHarness harness={{ checkResult: WB_CHECK, orgUnitId: 'u1', harnessChecked: true, importRows: [] }} />,
      ),
  },
]
