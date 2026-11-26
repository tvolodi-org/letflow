/** Harness fixtures of the maintenance work orders (GH 4801 / REQ-899): the order list with the record, a closed
 *  order, the assign dialog, the form from a request and direct, and My maintenance orders (list, cut, one failed
 *  instance read). Invented data only. Own file (one registry line). */
import { useEffect, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import MaintenanceOrderFormPage from '@/modules/maintenance/MaintenanceOrderFormPage'
import MaintenanceOrdersPage from '@/modules/maintenance/MaintenanceOrdersPage'
import MyMaintenanceOrdersPage from '@/modules/maintenance/MyMaintenanceOrdersPage'
import type { EntityRecord, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const rec = (id: string, fields: Record<string, unknown>): EntityRecord => ({
  record_id: id,
  entity_type: 'assets_card',
  field_values: { active: true, ...fields },
  deleted: false,
  entity_def_version: '1',
  last_event_global_seq: 1,
})
const CARDS = [
  rec('c-1', { inventory_number: 'FA-0001', name: 'Delivery van Gazelle Next' }),
  rec('c-2', { inventory_number: 'FA-0002', name: 'Reach truck with a long model name for the wrapping check' }),
]
const VAN = { id: 'c-1', inventory_number: 'FA-0001', name: 'Delivery van Gazelle Next' }
const TRUCK = { id: 'c-2', inventory_number: 'FA-0002', name: 'Reach truck with a long model name for the wrapping check' }

const order = (id: string, number: string, status: string, urgency: string, asset: typeof VAN, over: Record<string, unknown> = {}) => ({
  id,
  number,
  status,
  assignee_user_id: null,
  asset,
  request: { id: 'r-1', number: 'WR-2026-000003' },
  description: 'The van does not start in the morning. The engine light is on.',
  urgency,
  work_done: null,
  done_by: null,
  done_at: null,
  closed_by: null,
  closed_at: null,
  created_at: '2026-11-21T09:15:00Z',
  ...over,
})
const ORDERS = [
  order('o-1', 'WO-2026-000004', 'open', 'urgent', VAN),
  order('o-2', 'WO-2026-000003', 'in_work', 'normal', TRUCK, { assignee_user_id: 'u-2', request: null, description: 'The mast squeaks.' }),
  order('o-3', 'WO-2026-000002', 'closed', 'low', VAN, {
    assignee_user_id: 'u-2',
    work_done: 'Replaced the starter relay and checked the battery.',
    done_by: 'u-2',
    done_at: '2026-11-22T10:30:00Z',
    closed_by: 'u-1',
    closed_at: '2026-11-23T08:00:00Z',
  }),
]
const USERS = [
  { id: 'u-1', username: 'ann', display_name: 'Ann Planner', email: 'ann@example.test', status: 'active' },
  { id: 'u-2', username: 'cy', display_name: 'Cy Technician', email: 'cy@example.test', status: 'active' },
  { id: 'u-3', username: 'bob', display_name: 'Bob Retired', email: 'bob@example.test', status: 'inactive' },
]
const REQUEST = {
  id: 'r-1',
  number: 'WR-2026-000003',
  status: 'new',
  asset: VAN,
  description: 'The van does not start in the morning. The engine light is on.',
  urgency: 'urgent',
  reported_by: 'u-1',
  reject_reason: null,
  order: null,
  photo_count: 0,
  created_at: '2026-11-21T09:15:00Z',
}

const task = (id: string, instance: string, created: string, node = 'maintenance_work') => ({
  task_id: id,
  instance_id: instance,
  token_id: `tk-${id}`,
  node_id: node,
  node_name: 'Do the work',
  status: 'PENDING',
  created_at: created,
})
const INBOX = [
  task('t-1', 'i-1', '2026-11-20T08:00:00Z'),
  task('t-2', 'i-2', '2026-11-21T08:00:00Z'),
  task('t-3', 'i-3', '2026-11-19T08:00:00Z', 'review_step'),
  task('t-4', 'i-4', '2026-11-22T08:00:00Z'),
]
const VARS: Record<string, Record<string, unknown>> = {
  'i-1': { maintenance_order_number: 'WO-2026-000003', asset_inventory_number: 'FA-0002', asset_name: TRUCK.name, urgency: 'normal', description: 'The mast squeaks.' },
  'i-2': { maintenance_order_number: 'WO-2026-000004', asset_inventory_number: 'FA-0001', asset_name: VAN.name, urgency: 'urgent', description: 'The van does not start in the morning.' },
}

function routes(opts: { cut?: boolean } = {}): FixtureRoute[] {
  // The cut screen answers the first page with the tasks and four empty pages after it, each with a next cursor.
  let inboxCalls = 0
  return [
    {
      match: (path, method) => path === '/api/v1/modules/maintenance/orders' && method === 'GET',
      reply: (state) => ({ status: 200, body: { rows: state === 'empty' ? [] : ORDERS, next_cursor: null } }),
    },
    {
      match: (path, method) => /\/modules\/maintenance\/orders\/[^/]+$/.test(path) && method === 'GET',
      reply: (_s, path) => {
        const id = decodeURIComponent(path.split('/').slice(-1)[0] ?? '')
        return { status: 200, body: ORDERS.find((o) => o.id === id) ?? ORDERS[0] }
      },
    },
    {
      match: (path, method) => /\/modules\/maintenance\/requests\/[^/]+$/.test(path) && method === 'GET',
      reply: () => ({ status: 200, body: REQUEST }),
    },
    {
      match: (path, method) => path === '/api/v1/identity/users' && method === 'GET',
      reply: () => ({ status: 200, body: { items: USERS, next_cursor: null } }),
    },
    {
      match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
      reply: () => ({ status: 200, body: { items: CARDS, next_cursor: null } }),
    },
    {
      match: (path, method) => path === '/api/v1/tasks/inbox' && method === 'GET',
      reply: (state) => {
        inboxCalls += 1
        return {
          status: 200,
          body: { items: state === 'empty' || inboxCalls > 1 ? [] : INBOX, next_cursor: opts.cut === true ? 'more' : null },
        }
      },
    },
    {
      // i-4 answers a 500: the row stays with a note.
      match: (path, method) => /\/api\/v1\/instances\/i-4$/.test(path) && method === 'GET',
      reply: () => ({ status: 500, body: { reason: 'harness_failure' } }),
    },
    {
      match: (path, method) => /\/api\/v1\/instances\/[^/]+$/.test(path) && method === 'GET',
      reply: (_s, path) => {
        const id = decodeURIComponent(path.split('/').slice(-1)[0] ?? '')
        return { status: 200, body: { id, variables: VARS[id] ?? {} } }
      },
    },
    {
      match: (path, method) => path.startsWith('/api/v1/modules/maintenance/') && method !== 'GET',
      reply: () => ({ status: 200, body: {} }),
    },
  ]
}

const AUTH = { session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession, isAuthenticated: true } as unknown as AuthContextValue
const access = (permissions: string[]) => ({ status: 'ready' as const, info: { roles: [], platform_tenant: false, permissions } })
const MANAGER = access(['MaintenanceRead', 'MaintenanceRequestCreate', 'MaintenanceOrderManage', 'TasksRead'])
const TECHNICIAN = access(['TasksRead', 'TasksComplete'])
const withAuth = (page: ReactElement, state = MANAGER): ReactElement => (
  <AuthContext.Provider value={AUTH}>
    <AccessStateProvider state={state}>
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

export const maintenanceOrdersScreens: HarnessScreen[] = [
  {
    name: 'maintenance-orders',
    initialPath: '/orders',
    routePattern: '/orders',
    routes: routes(),
    render: () => withAuth(<MaintenanceOrdersPage />),
  },
  {
    name: 'maintenance-order',
    initialPath: '/o-3',
    routePattern: '/:id',
    routes: routes(),
    render: () => withAuth(<MaintenanceOrdersPage />),
  },
  {
    name: 'maintenance-order-assign',
    initialPath: '/o-1',
    routePattern: '/:id',
    routes: routes(),
    render: () => withAuth(<ClickTestId id="order-assign"><MaintenanceOrdersPage /></ClickTestId>),
  },
  {
    name: 'maintenance-order-form-request',
    initialPath: '/new?request=r-1',
    routePattern: '/new',
    routes: routes(),
    render: () => withAuth(<MaintenanceOrderFormPage />),
  },
  {
    name: 'maintenance-order-form-direct',
    initialPath: '/new',
    routePattern: '/new',
    routes: routes(),
    render: () => withAuth(<MaintenanceOrderFormPage />),
  },
  {
    name: 'maintenance-my-orders',
    initialPath: '/my-orders',
    routePattern: '/my-orders',
    routes: routes(),
    render: () => withAuth(<MyMaintenanceOrdersPage />, TECHNICIAN),
  },
  {
    name: 'maintenance-my-orders-cut',
    initialPath: '/my-orders',
    routePattern: '/my-orders',
    routes: routes({ cut: true }),
    render: () => withAuth(<MyMaintenanceOrdersPage />, TECHNICIAN),
  },
]
