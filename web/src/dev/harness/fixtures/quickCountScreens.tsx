/** REQ-855 harness screens: five states of the Quick count screen. */
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { QuickCountPageHarness } from '@/modules/stock/quickCount/QuickCountPage'
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
  catalog_item: [
    rec('i1', 'catalog_item', { name: 'Safety gloves (L)', base_uom_id: 'm1', lot_tracking_policy: 'none' }),
  ],
  location_node: [rec('l1', 'location_node', { name: 'Warehouse A' })],
  org_unit: [rec('u1', 'org_unit', { name: 'Procurement' })],
  catalog_lot: [],
  catalog_uom: [rec('m1', 'catalog_uom', { name: 'pcs' })],
}

const DOC_ID = 'qct-harness-1'
const TASK_ID = 'task-harness-1'

const quickCountDoc = {
  id: DOC_ID, kind: 'quick_count', state: 'issued', number: 'QCT-2026-000042',
  org_unit_id: 'u1', location_id: 'l1', responsible_id: null, counterparty_id: null,
  event_time: '2026-11-18T02:00:00Z',
  lines: [{ line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: null, quantity: '7', book_quantity: '10', counted_quantity: '7', difference: '-3' }],
  posted_at: null, posted_by: null, reversed_at: null, reversed_by: null, posting_check: null,
}

const baseTask = {
  id: TASK_ID, instance_id: DOC_ID, token_id: 't1', node_id: 'approve', node_name: 'Approve',
  status: 'PENDING', assignee_type: 'USER', assignee_ref: 'u1', created_at: '2026-11-18T02:00:00Z',
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

function taskDetailRoute(selfApprovalAllowed: boolean): FixtureRoute {
  return {
    match: (p, m) => p === `/api/v1/tasks/${TASK_ID}` && m === 'GET',
    reply: () => ({ status: 200, body: { ...baseTask, self_approval_allowed: selfApprovalAllowed } }),
  }
}

function tasksListRoute(): FixtureRoute {
  return {
    match: (p, m) => p === '/api/v1/tasks' && m === 'GET',
    reply: () => ({ status: 200, body: { items: [baseTask], next_cursor: null } }),
  }
}

const HARNESS_SESSION = {
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
    <AuthContext.Provider value={HARNESS_SESSION}>
      <AccessStateProvider state={QC_ACCESS}>
        {element}
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

// Pre-filled form values for states that need item/location/org selected
const FILLED_FORM = {
  itemId: 'i1',
  locationId: 'l1',
  orgUnitId: 'u1',
  lotId: '',
  countedQuantity: '7',
  reasonCode: 'recount',
  reasonText: '',
}

export const quickCountScreens: HarnessScreen[] = [
  // 1. Empty form (default state, no selections)
  {
    name: 'stock-quick-count-empty',
    routes: [entitiesRoute()],
    initialPath: '/admin/stock/quick-count',
    routePattern: '/admin/stock/quick-count',
    render: () => withQCAuth(<QuickCountPageHarness />),
  },
  // 2. Filled form with item/location/org selected and balance shown
  {
    name: 'stock-quick-count-filled',
    routes: [entitiesRoute(), balanceRoute('10')],
    initialPath: '/admin/stock/quick-count',
    routePattern: '/admin/stock/quick-count',
    render: () => withQCAuth(<QuickCountPageHarness initialForm={FILLED_FORM} />),
  },
  // 3. Result after successful submit (four-eyes on = Approve button shown)
  {
    name: 'stock-quick-count-result',
    routes: [entitiesRoute(), tasksListRoute(), taskDetailRoute(true)],
    initialPath: '/admin/stock/quick-count',
    routePattern: '/admin/stock/quick-count',
    render: () => withQCAuth(<QuickCountPageHarness initialResult={quickCountDoc} />),
  },
  // 4. Refusal: count_in_progress error shown as banner
  {
    name: 'stock-quick-count-refusal',
    routes: [entitiesRoute()],
    initialPath: '/admin/stock/quick-count',
    routePattern: '/admin/stock/quick-count',
    render: () => withQCAuth(<QuickCountPageHarness initialSubmitError={{ reason: 'count_in_progress', heldBy: 'QCT-2026-000001' }} />),
  },
  // 5. Four-eyes hint: result shown but self_approval_allowed = false
  {
    name: 'stock-quick-count-four-eyes',
    routes: [entitiesRoute(), tasksListRoute(), taskDetailRoute(false)],
    initialPath: '/admin/stock/quick-count',
    routePattern: '/admin/stock/quick-count',
    render: () => withQCAuth(<QuickCountPageHarness initialResult={quickCountDoc} />),
  },
]
