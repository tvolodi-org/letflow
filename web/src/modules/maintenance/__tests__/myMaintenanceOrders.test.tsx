// @vitest-environment jsdom
/** GH 4801 / REQ-899 (CMMS slice 1 part 7): My maintenance orders, built on the task inbox.
 *
 *  AC3 — the inbox filter (maintenance_work only), the order of the rows, the cut-list note after five pages and
 *  a failed instance read.
 *  AC4 — no maintenance permission is needed and no request goes to /api/v1/modules/maintenance.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, useLocation, useRoutes } from 'react-router-dom'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import { maintenanceRouteObjects } from '../maintenanceRoutes'
import { sortMyOrders, type MyOrderRow } from '../maintenanceModel'
import type { ClientMock } from './maintenanceTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-m' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const client = clientMock as unknown as ClientMock

/** A task holder with no maintenance atom at all. */
const TASK_HOLDER: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['TasksRead', 'TasksComplete'] },
}

function task(id: string, node: string, created: string) {
  return {
    task_id: id,
    instance_id: `i-${id}`,
    token_id: `tk-${id}`,
    node_id: node,
    node_name: node === 'maintenance_work' ? 'Do the work' : 'Other step',
    status: 'PENDING',
    created_at: created,
  }
}

const VARS: Record<string, Record<string, unknown>> = {
  'i-t1': { maintenance_order_number: 'WO-1', asset_inventory_number: 'FA-1', asset_name: 'Press', urgency: 'normal', description: 'Old and normal' },
  'i-t2': { maintenance_order_number: 'WO-2', asset_inventory_number: 'FA-2', asset_name: 'Lathe', urgency: 'urgent', description: 'New but urgent' },
}

function Probe() {
  const loc = useLocation()
  return <div data-testid="probe">{loc.pathname + loc.search}</div>
}
function Routes() {
  return useRoutes([...maintenanceRouteObjects, { path: 'tasks', element: <Probe /> }])
}
function renderMy(access: AccessState = TASK_HOLDER) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={['/maintenance/my-orders']}>
          <Routes />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

const inboxCalls = () => clientMock.get.mock.calls.filter(([p]) => p === '/api/v1/tasks/inbox')
const maintenanceCalls = () =>
  [...clientMock.get.mock.calls, ...clientMock.post.mock.calls].filter(([p]) => String(p).includes('/api/v1/modules/maintenance'))

function instanceAnswer(path: string) {
  const m = /\/api\/v1\/instances\/([^/?]+)$/.exec(path)
  if (!m) return undefined
  const vars = VARS[m[1]!]
  if (!vars) throw { status: 500, details: {} }
  return { id: m[1], variables: vars }
}

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
})
afterEach(() => cleanup())

describe('AC3 My maintenance orders', () => {
  it('lists the two maintenance_work tasks of three, urgent first, with the facts of the instance', async () => {
    client.get.mockImplementation(async (path: string) => {
      if (path === '/api/v1/tasks/inbox') {
        return {
          items: [
            task('t1', 'maintenance_work', '2026-11-20T08:00:00Z'),
            task('t3', 'other_node', '2026-11-19T08:00:00Z'),
            task('t2', 'maintenance_work', '2026-11-21T08:00:00Z'),
          ],
          next_cursor: null,
        }
      }
      return instanceAnswer(path)
    })
    renderMy()
    const first = await screen.findByTestId('my-row-asset-t2')
    expect(first).toHaveTextContent('FA-2')
    expect(first).toHaveTextContent('Lathe')
    expect(screen.getByTestId('my-row-asset-t1')).toHaveTextContent('FA-1 · Press')
    expect(screen.queryByTestId('my-row-asset-t3')).not.toBeInTheDocument()
    expect(screen.getByText('WO-2')).toBeInTheDocument()
    expect(screen.getByText('WO-1')).toBeInTheDocument()
    expect(screen.getByText('New but urgent')).toBeInTheDocument()
    // urgent first, then the other
    const rows = screen.getAllByRole('row').map((r) => r.textContent ?? '')
    expect(rows.findIndex((r) => r.includes('WO-2'))).toBeLessThan(rows.findIndex((r) => r.includes('WO-1')))
    expect(screen.queryByTestId('my-cut-note')).not.toBeInTheDocument()
    // the instance of the foreign task is never read
    expect(client.get.mock.calls.some(([p]) => String(p).endsWith('/instances/i-t3'))).toBe(false)
  })

  it('six full pages: it reads five pages and says the list is cut', async () => {
    let page = 0
    client.get.mockImplementation(async (path: string, params?: Record<string, unknown>) => {
      if (path === '/api/v1/tasks/inbox') {
        page += 1
        expect(params?.['page_size']).toBe(200)
        return { items: [task(`p${page}`, 'other_node', '2026-11-20T08:00:00Z')], next_cursor: `c${page}` }
      }
      return instanceAnswer(path)
    })
    renderMy()
    expect(await screen.findByTestId('my-cut-note')).toHaveTextContent('1000')
    expect(inboxCalls()).toHaveLength(5)
  })

  it('five pages that end by themselves show no cut note', async () => {
    let page = 0
    client.get.mockImplementation(async (path: string) => {
      if (path === '/api/v1/tasks/inbox') {
        page += 1
        return { items: [], next_cursor: page < 5 ? `c${page}` : null }
      }
      return instanceAnswer(path)
    })
    renderMy()
    expect(await screen.findByText('No work orders for you')).toBeInTheDocument()
    expect(screen.queryByTestId('my-cut-note')).not.toBeInTheDocument()
    expect(inboxCalls()).toHaveLength(5)
  })

  it('a failed instance read shows the row with the task name and a note, not an error page', async () => {
    client.get.mockImplementation(async (path: string) => {
      if (path === '/api/v1/tasks/inbox') {
        return { items: [task('t2', 'maintenance_work', '2026-11-21T08:00:00Z'), task('t9', 'maintenance_work', '2026-11-22T08:00:00Z')], next_cursor: null }
      }
      return instanceAnswer(path)
    })
    renderMy()
    const note = await screen.findByTestId('my-row-note-t9')
    expect(note).toHaveTextContent('Do the work')
    expect(note).toHaveTextContent('could not be read')
    expect(screen.getByTestId('my-row-asset-t2')).toBeInTheDocument()
  })

  it('a row opens the task screen with the task id', async () => {
    client.get.mockImplementation(async (path: string) =>
      path === '/api/v1/tasks/inbox'
        ? { items: [task('t2', 'maintenance_work', '2026-11-21T08:00:00Z')], next_cursor: null }
        : instanceAnswer(path),
    )
    renderMy()
    fireEvent.click(await screen.findByTestId('my-open-t2'))
    expect(await screen.findByTestId('probe')).toHaveTextContent('/tasks?task=t2')
  })

  it('a failed inbox read shows the shared error state with a retry', async () => {
    client.get.mockRejectedValue({ status: 500, details: {} })
    renderMy()
    expect(await screen.findByText('Retry')).toBeInTheDocument()
  })

  it('sortMyOrders: urgent first, then oldest first', () => {
    const row = (taskId: string, urgency: string | null, createdAt: string): MyOrderRow => ({
      taskId, taskName: 'x', createdAt, number: null, inventoryNumber: null, assetName: null, urgency, description: null, instanceFailed: false,
    })
    const sorted = sortMyOrders([
      row('a', 'normal', '2026-11-01T00:00:00Z'),
      row('b', 'urgent', '2026-11-03T00:00:00Z'),
      row('c', 'urgent', '2026-11-02T00:00:00Z'),
      row('d', 'low', '2026-10-30T00:00:00Z'),
    ])
    expect(sorted.map((r) => r.taskId)).toEqual(['c', 'b', 'd', 'a'])
  })
})

describe('AC4 no maintenance permission needed', () => {
  it('a TasksRead holder sees the screen and no request goes to the maintenance routes', async () => {
    client.get.mockImplementation(async (path: string) =>
      path === '/api/v1/tasks/inbox'
        ? { items: [task('t2', 'maintenance_work', '2026-11-21T08:00:00Z')], next_cursor: null }
        : instanceAnswer(path),
    )
    renderMy(TASK_HOLDER)
    expect(await screen.findByTestId('my-row-asset-t2')).toBeInTheDocument()
    expect(maintenanceCalls()).toHaveLength(0)
  })

  it('the nav item of the module needs TasksRead only', async () => {
    const { maintenanceModuleDefinition } = await import('../index')
    const mine = maintenanceModuleDefinition.navItems.find((n) => n.to === '/maintenance/my-orders')
    expect(mine).toMatchObject({ label: 'My maintenance orders', permission: 'TasksRead' })
  })

  it('a user without TasksRead does not get the screen', async () => {
    client.get.mockResolvedValue({ items: [], next_cursor: null })
    renderMy({ status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['MaintenanceRead'] } })
    await waitFor(() => expect(screen.queryByText('My maintenance orders')).not.toBeInTheDocument())
    expect(inboxCalls()).toHaveLength(0)
  })
})
