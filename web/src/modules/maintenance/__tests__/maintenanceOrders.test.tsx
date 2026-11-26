// @vitest-environment jsdom
/** GH 4801 / REQ-899 (CMMS slice 1 part 7): the order form, the order list and the order page.
 *
 *  AC1 — the form from a request (read-only, `request_id` only) and direct (card, description, urgency), the
 *  assignee picker lists the active users only, a 409 request_not_new is shown as a sentence.
 *  AC2 — the five statuses in words, the status filter, work done / done by / closed by, Assign only for a
 *  MaintenanceOrderManage holder and only for an open or in-work order.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import type { MaintenanceOrder } from '../maintenance.api'
import { API, CARDS, READ_ONLY, WITH_ALL, WITH_MANAGE, bodiesOf, request, renderMaintenance, type ClientMock } from './maintenanceTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-m' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const client = clientMock as unknown as ClientMock

function order(over: Partial<MaintenanceOrder> = {}): MaintenanceOrder {
  return {
    id: 'o-1',
    number: 'WO-2026-000001',
    status: 'open',
    assignee_user_id: null,
    asset: { id: 'c-1', inventory_number: 'FA-1', name: 'Press machine' },
    request: { id: 'r-1', number: 'WR-2026-000001' },
    description: 'The press does not start.',
    urgency: 'normal',
    work_done: null,
    done_by: null,
    done_at: null,
    closed_by: null,
    closed_at: null,
    created_at: '2026-11-21T09:00:00Z',
    ...over,
  }
}

const USERS = [
  { id: 'u-1', username: 'ann', display_name: 'Ann Planner', email: 'a@x', status: 'active' },
  { id: 'u-2', username: 'bob', display_name: 'Bob Gone', email: 'b@x', status: 'inactive' },
  { id: 'u-3', username: 'cy', display_name: 'Cy Tech', email: 'c@x', status: 'active' },
]

interface Options {
  orders?: MaintenanceOrder[]
  createRefusal?: unknown
  usersFail?: boolean
}

function server(options: Options = {}) {
  const orders = options.orders ?? [order()]
  client.get.mockImplementation(async (path: string, params?: Record<string, unknown>) => {
    if (path === '/api/v1/me/modules') return { installed_modules: [{ module_id: 'maintenance', version: '1.0.0' }] }
    if (path === '/api/v1/identity/users') {
      if (options.usersFail) throw { status: 403, details: {} }
      void params
      return { items: USERS, next_cursor: null }
    }
    if (path.startsWith(`${API}/orders?`) || path === `${API}/orders`) return { rows: orders, next_cursor: null }
    const one = /\/orders\/([^/?]+)$/.exec(path)
    if (one) return orders.find((o) => o.id === one[1]) ?? { status: 404, details: {} }
    const req = /\/requests\/([^/?]+)$/.exec(path)
    if (req) return request({ id: req[1] })
    return { rows: [], next_cursor: null }
  })
  client.post.mockImplementation(async (path: string, body: unknown) => {
    if (path === '/api/v1/entities/query') return { items: CARDS, next_cursor: null }
    if (path === `${API}/orders`) {
      if (options.createRefusal) throw options.createRefusal
      return order({ id: 'o-new', number: 'WO-2026-000002', description: (body as { description?: string }).description ?? 'x' })
    }
    if (/\/orders\/[^/]+\/assign$/.test(path)) return order({ status: 'in_work', assignee_user_id: (body as { user_id: string }).user_id })
    return {}
  })
}

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  server()
})
afterEach(() => cleanup())

describe('AC1 the order form', () => {
  it('from a request it shows the card, description and urgency read-only and sends request_id only', async () => {
    renderMaintenance('/admin/maintenance/orders/new?request=r-1', WITH_ALL)
    expect(await screen.findByTestId('order-card-readonly')).toBeInTheDocument()
    await waitFor(() => expect((screen.getByLabelText('Equipment of the request') as HTMLInputElement).value).toContain('FA-1'))
    expect(screen.getByLabelText('Description of the request')).toHaveValue('The press does not start.')
    expect(screen.getByLabelText('Description of the request')).toHaveAttribute('readonly')
    expect(screen.getByLabelText('Urgency of the request')).toHaveValue('Normal')
    fireEvent.click(screen.getByTestId('order-save'))
    await waitFor(() => expect(bodiesOf(client, `${API}/orders`)).toHaveLength(1))
    const body = bodiesOf(client, `${API}/orders`)[0]!
    expect(Object.keys(body).sort()).toEqual(['idempotency_key', 'request_id'])
    expect(body['request_id']).toBe('r-1')
  })

  it('direct it sends asset_card_id, description and urgency, with the chosen assignee', async () => {
    renderMaintenance('/admin/maintenance/orders/new', WITH_ALL)
    const card = await screen.findByLabelText('Equipment')
    await screen.findByRole('option', { name: /FA-1/ })
    fireEvent.change(card, { target: { value: 'c-1' } })
    fireEvent.change(screen.getByTestId('order-description'), { target: { value: 'Belt is torn' } })
    fireEvent.change(screen.getByLabelText('Urgency'), { target: { value: 'urgent' } })
    await screen.findByRole('option', { name: 'Cy Tech' })
    fireEvent.change(screen.getByLabelText('Assignee'), { target: { value: 'u-3' } })
    fireEvent.click(screen.getByTestId('order-save'))
    await waitFor(() => expect(bodiesOf(client, `${API}/orders`)).toHaveLength(1))
    const body = bodiesOf(client, `${API}/orders`)[0]!
    expect(Object.keys(body).sort()).toEqual(['assignee_user_id', 'asset_card_id', 'description', 'idempotency_key', 'urgency'].sort())
    expect(body).toMatchObject({ asset_card_id: 'c-1', description: 'Belt is torn', urgency: 'urgent', assignee_user_id: 'u-3' })
  })

  it('direct without a description sends nothing', async () => {
    renderMaintenance('/admin/maintenance/orders/new', WITH_ALL)
    const card = await screen.findByLabelText('Equipment')
    await screen.findByRole('option', { name: /FA-1/ })
    fireEvent.change(card, { target: { value: 'c-1' } })
    fireEvent.click(screen.getByTestId('order-save'))
    await waitFor(() => expect(screen.getByText('Describe the fault.')).toBeInTheDocument())
    expect(bodiesOf(client, `${API}/orders`)).toHaveLength(0)
  })

  it('the assignee picker lists only active users', async () => {
    renderMaintenance('/admin/maintenance/orders/new', WITH_ALL)
    await screen.findByRole('option', { name: 'Ann Planner' })
    const names = within(screen.getByLabelText('Assignee')).getAllByRole('option').map((o) => o.textContent)
    expect(names).toEqual(['Choose a person', 'Ann Planner', 'Cy Tech'])
  })

  it('a refused list of users says so and Save still works without an assignee', async () => {
    server({ usersFail: true })
    renderMaintenance('/admin/maintenance/orders/new?request=r-1', WITH_ALL)
    expect(await screen.findByTestId('assignee-load-error')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByTestId('order-save')).not.toBeDisabled())
    fireEvent.click(screen.getByTestId('order-save'))
    await waitFor(() => expect(bodiesOf(client, `${API}/orders`)).toHaveLength(1))
    expect(bodiesOf(client, `${API}/orders`)[0]).not.toHaveProperty('assignee_user_id')
  })

  it('a 409 request_not_new answer is shown as a sentence', async () => {
    server({ createRefusal: { status: 409, details: { reason: 'request_not_new' } } })
    renderMaintenance('/admin/maintenance/orders/new?request=r-1', WITH_ALL)
    await waitFor(() => expect(screen.getByTestId('order-save')).not.toBeDisabled())
    fireEvent.click(screen.getByTestId('order-save'))
    expect(await screen.findByTestId('order-form-error')).toHaveTextContent('The request is no longer new.')
    expect(screen.getByTestId('order-form-error')).not.toHaveTextContent('request_not_new')
  })

  it('the form needs MaintenanceOrderManage', async () => {
    renderMaintenance('/admin/maintenance/orders/new', READ_ONLY)
    await waitFor(() => expect(screen.queryByTestId('order-save')).not.toBeInTheDocument())
  })
})

describe('AC2 the list and the page', () => {
  it('the list shows the five statuses in words', async () => {
    const statuses = ['open', 'in_work', 'done', 'closed', 'cancelled']
    server({ orders: statuses.map((s, i) => order({ id: `o-${i}`, number: `WO-${i}`, status: s })) })
    renderMaintenance('/admin/maintenance/orders', WITH_ALL)
    for (const [i, word] of ['Open', 'In work', 'Done', 'Closed', 'Cancelled'].entries()) {
      expect(await screen.findByTestId(`order-row-status-o-${i}`)).toHaveTextContent(word)
    }
  })

  it('the status filter sends status=in_work', async () => {
    renderMaintenance('/admin/maintenance/orders', WITH_ALL)
    await screen.findByText('WO-2026-000001')
    fireEvent.change(screen.getByLabelText('Status'), { target: { value: 'in_work' } })
    await waitFor(() =>
      expect(clientMock.get.mock.calls.some(([p]) => String(p).includes(`${API}/orders?status=in_work`))).toBe(true),
    )
  })

  it('the page shows work done, done by and closed by when the server sends them', async () => {
    server({
      orders: [
        order({
          status: 'closed',
          assignee_user_id: 'u-3',
          work_done: 'Replaced the belt.',
          done_by: 'u-3',
          done_at: '2026-11-22T10:00:00Z',
          closed_by: 'u-1',
          closed_at: '2026-11-23T10:00:00Z',
        }),
      ],
    })
    renderMaintenance('/admin/maintenance/orders/o-1', WITH_ALL)
    const detail = await screen.findByTestId('maintenance-order-detail')
    expect(within(detail).getByTestId('order-work-done')).toHaveTextContent('Replaced the belt.')
    await waitFor(() => expect(within(detail).getByTestId('order-done-by')).toHaveTextContent('Cy Tech'))
    expect(within(detail).getByTestId('order-closed-by')).toHaveTextContent('Ann Planner')
    expect(within(detail).getByTestId('order-request')).toHaveTextContent('WR-2026-000001')
  })

  it('an open order has no work done block', async () => {
    renderMaintenance('/admin/maintenance/orders/o-1', WITH_ALL)
    const detail = await screen.findByTestId('maintenance-order-detail')
    expect(within(detail).queryByTestId('order-work-done')).not.toBeInTheDocument()
    expect(within(detail).queryByTestId('order-closed-by')).not.toBeInTheDocument()
  })

  it('Assign shows for a manager on an open order and Reassign on an assigned one in work', async () => {
    renderMaintenance('/admin/maintenance/orders/o-1', WITH_MANAGE)
    expect(await screen.findByTestId('order-assign')).toHaveTextContent('Assign')
    cleanup()
    server({ orders: [order({ status: 'in_work', assignee_user_id: 'u-3' })] })
    renderMaintenance('/admin/maintenance/orders/o-1', WITH_MANAGE)
    expect(await screen.findByTestId('order-assign')).toHaveTextContent('Reassign')
  })

  it.each(['done', 'closed', 'cancelled'])('no Assign on a %s order', async (status) => {
    server({ orders: [order({ status })] })
    renderMaintenance('/admin/maintenance/orders/o-1', WITH_MANAGE)
    await screen.findByTestId('maintenance-order-detail')
    expect(screen.queryByTestId('order-assign')).not.toBeInTheDocument()
  })

  it('no Assign for a reader without MaintenanceOrderManage', async () => {
    renderMaintenance('/admin/maintenance/orders/o-1', READ_ONLY)
    await screen.findByTestId('maintenance-order-detail')
    expect(screen.queryByTestId('order-assign')).not.toBeInTheDocument()
    expect(screen.queryByTestId('order-create')).not.toBeInTheDocument()
  })

  it('Assign sends POST /orders/:id/assign with the chosen user', async () => {
    renderMaintenance('/admin/maintenance/orders/o-1', WITH_MANAGE)
    fireEvent.click(await screen.findByTestId('order-assign'))
    const dialog = await screen.findByTestId('assign-dialog')
    await within(dialog).findByRole('option', { name: 'Cy Tech' })
    fireEvent.change(within(dialog).getByLabelText('Assignee'), { target: { value: 'u-3' } })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Assign' }))
    await waitFor(() => expect(bodiesOf(client, `${API}/orders/o-1/assign`)).toEqual([{ user_id: 'u-3' }]))
  })

  it('Assign without a person sends nothing', async () => {
    renderMaintenance('/admin/maintenance/orders/o-1', WITH_MANAGE)
    fireEvent.click(await screen.findByTestId('order-assign'))
    const dialog = await screen.findByTestId('assign-dialog')
    fireEvent.click(within(dialog).getByRole('button', { name: 'Assign' }))
    expect(await within(dialog).findByText('Choose a person.')).toBeInTheDocument()
    expect(bodiesOf(client, `${API}/orders/o-1/assign`)).toHaveLength(0)
  })

  it('Make work order of a request opens the form of the order for that request', async () => {
    renderMaintenance('/admin/maintenance/requests/r-1', WITH_MANAGE)
    fireEvent.click(await screen.findByTestId('request-make-order'))
    expect(await screen.findByTestId('order-card-readonly')).toBeInTheDocument()
  })
})
