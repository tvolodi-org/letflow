/** REQ-887 harness screens: workbook import screen states for screenshots.
 *  States: loading, empty, error, checked-remarks, checked-no-changes, too-many-changes,
 *  loaded, file-changed, cancel-confirmation (9 states × 12 variants = 108 screenshots). */
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { WorkbookImportPageHarness } from '@/modules/stock/workbook/WorkbookImportPage'
import BalancesPage from '@/modules/stock/register/BalancesPage'
import type { WorkbookCheckResult, WorkbookImportRow } from '@/modules/stock/workbook/workbook.api'
import type { UserSession } from '@/types/api'
import type { EntityRecord } from '@/types/api'
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
  org_unit: [rec('ou1', 'org_unit', { name: 'Склад A / Warehouse A' })],
}

const HARNESS_SESSION = {
  session: {
    token: 'harness',
    tenant_id: 'harness-tenant',
    tenant_slug: 'demo',
    display_name: 'Aigerim S.',
    tenant_display_name: 'Demo Holding',
    tenant_type: 'production',
  } as unknown as UserSession,
  isAuthenticated: true,
  isLoading: false,
  loginSource: null,
  login: () => {},
  logout: () => {},
  setSession: () => {},
} as unknown as AuthContextValue

const WB_ACCESS = {
  status: 'ready' as const,
  info: {
    roles: [],
    platform_tenant: false,
    permissions: ['StockQuickCount', 'StockRead', 'StockReverse'],
  },
}

function withAuth(element: React.ReactElement) {
  return (
    <AuthContext.Provider value={HARNESS_SESSION}>
      <AccessStateProvider state={WB_ACCESS}>{element}</AccessStateProvider>
    </AuthContext.Provider>
  )
}

function entitiesRoute(): FixtureRoute {
  return {
    match: (p, m) => p === '/api/v1/entities/query' && m === 'POST',
    reply: (_s, _p, body) => {
      const b = (body ?? {}) as { entity_type?: string }
      const items = MASTERS[b.entity_type ?? ''] ?? []
      return { status: 200, body: { items, next_cursor: null } }
    },
  }
}

function importsRoute(rows: WorkbookImportRow[]): FixtureRoute {
  return {
    match: (p, m) => p === '/api/v1/modules/stock/stock-workbook/imports' && m === 'GET',
    reply: () => ({ status: 200, body: { rows } }),
  }
}

function importsLoadingRoute(): FixtureRoute {
  return {
    match: (p, m) => p === '/api/v1/modules/stock/stock-workbook/imports' && m === 'GET',
    pending: true,
    reply: () => ({ status: 200, body: { rows: [] } }),
  }
}

function importsErrorRoute(): FixtureRoute {
  return {
    match: (p, m) => p === '/api/v1/modules/stock/stock-workbook/imports' && m === 'GET',
    reply: () => ({ status: 500, body: { type: 'about:blank', title: 'Server error', status: 500 } }),
  }
}

function balancesRoute(): FixtureRoute {
  return {
    match: (p, m) => p === '/api/v1/modules/stock/balances' && m === 'GET',
    reply: () => ({ status: 200, body: { ledger_seq: 1, next_cursor: null, rows: [] } }),
  }
}

const IMPORT_ROWS: WorkbookImportRow[] = [
  {
    document_id: 'd1',
    number: 'QCI-2026-000001',
    created_at: '2026-11-18T04:00:00Z',
    created_by: 'operator',
    file_name: 'stock-2026-11-18.xlsx',
    sheet: 'Остатки 2026-11-18',
    lines: 42,
    remarks_count: 3,
    state: 'issued',
    reversal_pending: false,
  },
  {
    document_id: 'd2',
    number: 'QCI-2026-000002',
    created_at: '2026-11-17T10:00:00Z',
    created_by: 'bookkeeper',
    file_name: 'stock-2026-11-17.xlsx',
    sheet: 'Остатки 2026-11-17',
    lines: 100,
    remarks_count: 0,
    state: 'posted',
    reversal_pending: false,
  },
]

const CHECK_RESULT_REMARKS: WorkbookCheckResult = {
  sheet: 'Остатки 2026-11-18',
  rows_read: 143,
  remarks: [
    'Строка 3: артикул ART-X не найден в справочнике номенклатуры',
    'Строка 7: единица измерения кг не соответствует базовой единице шт',
    'Строка 12: количество 0 не учитывается (позиция пропускается)',
  ],
  changes: [
    { row: 1, item_code: 'GLV-L', item_name: 'Перчатки защитные (L)', place_code: 'A-01', book_quantity: '100', file_quantity: '95', difference: '-5' },
    { row: 2, item_code: 'BOX-A4', item_name: 'Коробка картонная A4', place_code: 'B-02', book_quantity: '500', file_quantity: '487', difference: '-13' },
    { row: null, item_code: 'TAPE-50', item_name: 'Скотч 50мм', place_code: 'C-03', book_quantity: '30', file_quantity: '0', difference: '-30' },
  ],
  unchanged_count: 140,
  too_many_changes: false,
}

const CHECK_RESULT_NO_CHANGES: WorkbookCheckResult = {
  sheet: 'Остатки 2026-11-18',
  rows_read: 50,
  remarks: [],
  changes: [],
  unchanged_count: 50,
  too_many_changes: false,
}

const CHECK_RESULT_TOO_MANY: WorkbookCheckResult = {
  sheet: 'Остатки 2026-11-18',
  rows_read: 2000,
  remarks: ['Строка 1: замечание к файлу'],
  changes: Array.from({ length: 5 }, (_, i) => ({
    row: i + 1,
    item_code: `ART-${i + 1}`,
    item_name: `Article ${i + 1}`,
    place_code: 'A-01',
    book_quantity: '10',
    file_quantity: '8',
    difference: '-2',
  })),
  unchanged_count: 0,
  too_many_changes: true,
}

export const workbookImportScreens: HarnessScreen[] = [
  // 1. Loading: imports list is loading
  {
    name: 'wb-import-loading',
    routes: [entitiesRoute(), importsLoadingRoute()],
    initialPath: '/admin/stock/workbook-import',
    routePattern: '/admin/stock/workbook-import',
    render: () => withAuth(<WorkbookImportPageHarness />),
  },
  // 2. Empty: no loads yet, no check done
  {
    name: 'wb-import-empty',
    routes: [entitiesRoute(), importsRoute([])],
    initialPath: '/admin/stock/workbook-import',
    routePattern: '/admin/stock/workbook-import',
    render: () => withAuth(<WorkbookImportPageHarness harness={{ importRows: [] }} />),
  },
  // 3. Error: check failed with xlsx_unreadable error
  {
    name: 'wb-import-check-error',
    routes: [entitiesRoute(), importsRoute(IMPORT_ROWS)],
    initialPath: '/admin/stock/workbook-import',
    routePattern: '/admin/stock/workbook-import',
    render: () =>
      withAuth(
        <WorkbookImportPageHarness
          harness={{
            checkError: 'stock.wb.err.xlsx_unreadable',
            importRows: IMPORT_ROWS,
          }}
        />,
      ),
  },
  // 4. Checked with remarks, changes and emptied row
  {
    name: 'wb-import-checked-remarks',
    routes: [entitiesRoute(), importsRoute(IMPORT_ROWS)],
    initialPath: '/admin/stock/workbook-import',
    routePattern: '/admin/stock/workbook-import',
    render: () =>
      withAuth(
        <WorkbookImportPageHarness
          harness={{
            checkResult: CHECK_RESULT_REMARKS,
            orgUnitId: 'ou1',
            harnessChecked: true,
            importRows: IMPORT_ROWS,
          }}
        />,
      ),
  },
  // 5. Checked without changes
  {
    name: 'wb-import-checked-no-changes',
    routes: [entitiesRoute(), importsRoute(IMPORT_ROWS)],
    initialPath: '/admin/stock/workbook-import',
    routePattern: '/admin/stock/workbook-import',
    render: () =>
      withAuth(
        <WorkbookImportPageHarness
          harness={{
            checkResult: CHECK_RESULT_NO_CHANGES,
            orgUnitId: 'ou1',
            importRows: IMPORT_ROWS,
          }}
        />,
      ),
  },
  // 6. Too many changes
  {
    name: 'wb-import-too-many-changes',
    routes: [entitiesRoute(), importsRoute(IMPORT_ROWS)],
    initialPath: '/admin/stock/workbook-import',
    routePattern: '/admin/stock/workbook-import',
    render: () =>
      withAuth(
        <WorkbookImportPageHarness
          harness={{
            checkResult: CHECK_RESULT_TOO_MANY,
            orgUnitId: 'ou1',
            importRows: IMPORT_ROWS,
          }}
        />,
      ),
  },
  // 7. Loaded: 201 success shown with document number and link
  {
    name: 'wb-import-loaded',
    routes: [entitiesRoute(), importsRoute(IMPORT_ROWS)],
    initialPath: '/admin/stock/workbook-import',
    routePattern: '/admin/stock/workbook-import',
    render: () =>
      withAuth(
        <WorkbookImportPageHarness
          harness={{
            checkResult: CHECK_RESULT_REMARKS,
            orgUnitId: 'ou1',
            loadResult: { documentId: 'd1', number: 'QCI-2026-000001' },
            importRows: IMPORT_ROWS,
          }}
        />,
      ),
  },
  // 8. File changed: check result shown but harnessChecked:false to show stale state
  {
    name: 'wb-import-file-changed',
    routes: [entitiesRoute(), importsRoute(IMPORT_ROWS)],
    initialPath: '/admin/stock/workbook-import',
    routePattern: '/admin/stock/workbook-import',
    render: () =>
      withAuth(
        <WorkbookImportPageHarness
          harness={{
            checkResult: CHECK_RESULT_REMARKS,
            orgUnitId: 'ou1',
            harnessChecked: false,
            importRows: IMPORT_ROWS,
          }}
        />,
      ),
  },
  // 9. Cancel confirmation dialog open
  {
    name: 'wb-import-cancel-dialog',
    routes: [entitiesRoute(), importsRoute(IMPORT_ROWS)],
    initialPath: '/admin/stock/workbook-import',
    routePattern: '/admin/stock/workbook-import',
    render: () =>
      withAuth(
        <WorkbookImportPageHarness
          harness={{
            cancelDialogOpen: true,
            importRows: IMPORT_ROWS,
          }}
        />,
      ),
  },
  // 10. Load list error
  {
    name: 'wb-import-load-list-error',
    routes: [entitiesRoute(), importsErrorRoute()],
    initialPath: '/admin/stock/workbook-import',
    routePattern: '/admin/stock/workbook-import',
    render: () => withAuth(<WorkbookImportPageHarness />),
  },
  // 11. Balances page header
  {
    name: 'wb-import-balances-header',
    routes: [entitiesRoute(), balancesRoute()],
    initialPath: '/admin/stock/balances',
    routePattern: 'admin/stock/balances',
    render: () => withAuth(<BalancesPage />),
  },
]
