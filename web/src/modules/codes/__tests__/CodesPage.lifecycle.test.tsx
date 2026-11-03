// @vitest-environment jsdom
/** L1–L3 — GH 3606 / REQ-672: list filters, row actions, retire warning, history. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { fakeServer, queryBodies, rec, renderCodes, writeCalls } from './codesTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-codes' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const BASE = '/api/v1/modules/codes'
const DATA = () => ({
  code_tag: [
    rec('c1', 'code_tag', { value: 'FREE-1', kind: 'barcode', status: 'not_assigned' }),
    rec('c2', 'code_tag', { value: 'USED-1', kind: 'qr', status: 'assigned' }),
    rec('c3', 'code_tag', { value: 'GONE-1', kind: 'epc', status: 'retired' }),
  ],
  location_node: [rec('l1', 'location_node', { code: 'A-01', name: 'Aisle' })],
  catalog_item: [rec('i1', 'catalog_item', { code: 'ITEM-1', name: 'Bolt' })],
  catalog_lot: [],
  code_assignment: [
    rec('a2', 'code_assignment', { code_id: 'c2', target_type: 'catalog_item', target_id: 'i1', assigned_at: '2026-02-01T10:00:00Z' }),
    rec('a1', 'code_assignment', {
      code_id: 'c2', target_type: 'location_node', target_id: 'l1',
      assigned_at: '2026-01-01T10:00:00Z', released_at: '2026-01-15T10:00:00Z',
    }),
  ],
})

beforeEach(() => {
  clientMock.post.mockReset()
  fakeServer(clientMock, DATA())
})
afterEach(() => cleanup())

const row = (v: string) => screen.findByTestId(`code-row-${v}`)

describe('L1 row actions', () => {
  it('lists status, kind and the open target of an assigned code; retired rows have no actions but history', async () => {
    renderCodes('/admin/codes')
    const used = await row('USED-1')
    await waitFor(() => expect(used).toHaveTextContent('Item ITEM-1'))
    expect(used).toHaveTextContent('Assigned')
    const gone = await row('GONE-1')
    expect(within(gone).queryByRole('button', { name: 'Retire' })).toBeNull()
    expect(within(gone).queryByRole('button', { name: 'Assign' })).toBeNull()
    expect(within(gone).getByRole('button', { name: 'History' })).toBeInTheDocument()
  })

  it('assigns a code to a target and reloads the list', async () => {
    renderCodes('/admin/codes')
    fireEvent.click(within(await row('FREE-1')).getByRole('button', { name: 'Assign' }))
    fireEvent.change(await screen.findByLabelText('Target type'), { target: { value: 'location_node' } })
    await screen.findByRole('option', { name: 'A-01 - Aisle' })
    fireEvent.change(screen.getByLabelText('Target'), { target: { value: 'l1' } })
    const before = queryBodies(clientMock, 'code_tag').length
    fireEvent.click(screen.getByTestId('assign-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const [call] = writeCalls(clientMock)
    expect(call.path).toBe(`${BASE}/c1/assign`)
    expect(call.body).toMatchObject({ target_type: 'location_node', target_id: 'l1' })
    expect(call.body['idempotency_key']).toBeTruthy()
    await waitFor(() => expect(queryBodies(clientMock, 'code_tag').length).toBeGreaterThan(before))
  })

  it('releases an assigned code', async () => {
    renderCodes('/admin/codes')
    fireEvent.click(within(await row('USED-1')).getByRole('button', { name: 'Release' }))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].path).toBe(`${BASE}/c2/release`)
    expect(Object.keys(writeCalls(clientMock)[0].body)).toEqual(['idempotency_key'])
  })

  it('shows the warning before retiring and posts only after the confirmation', async () => {
    renderCodes('/admin/codes')
    fireEvent.click(within(await row('FREE-1')).getByRole('button', { name: 'Retire' }))
    expect(await screen.findByText(/A retired code never comes back/)).toBeInTheDocument()
    expect(writeCalls(clientMock)).toHaveLength(0)
    const dialog = screen.getByRole('dialog')
    fireEvent.click(within(dialog).getByRole('button', { name: 'Retire' }))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].path).toBe(`${BASE}/c1/retire`)
  })

  it('rewrites the value', async () => {
    renderCodes('/admin/codes')
    fireEvent.click(within(await row('FREE-1')).getByRole('button', { name: 'Change value' }))
    const input = await screen.findByLabelText('New value')
    expect(input).toHaveValue('FREE-1')
    fireEvent.change(input, { target: { value: 'FREE-2' } })
    fireEvent.click(screen.getByTestId('value-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].path).toBe(`${BASE}/c1/value`)
    expect(writeCalls(clientMock)[0].body).toMatchObject({ value: 'FREE-2' })
  })
})

describe('L2 history', () => {
  it('shows the assignments of the code in time order with an open end', async () => {
    renderCodes('/admin/codes')
    fireEvent.click(within(await row('USED-1')).getByRole('button', { name: 'History' }))
    const panel = await screen.findByTestId('history-panel')
    await waitFor(() => expect(within(panel).getAllByTestId('history-row')).toHaveLength(2))
    const rows = within(panel).getAllByTestId('history-row')
    expect(rows[0]).toHaveTextContent('Location A-01')
    expect(rows[1]).toHaveTextContent('Item ITEM-1')
    expect(rows[1]).toHaveTextContent('open')
    const q = queryBodies(clientMock, 'code_assignment').find((b) =>
      (b['filters'] as { field: string }[]).some((f) => f.field === 'code_id'),
    )
    expect(q?.['filters']).toContainEqual({ field: 'code_id', op: 'eq', value: 'c2' })
    expect(q?.['sort']).toEqual([{ field: 'assigned_at', dir: 'asc' }])
  })
})

describe('L3 list filters', () => {
  it('puts the status and the exact value into the query', async () => {
    renderCodes('/admin/codes')
    await row('FREE-1')
    fireEvent.change(screen.getByLabelText('Status filter'), { target: { value: 'assigned' } })
    await waitFor(() =>
      expect(queryBodies(clientMock, 'code_tag').some((b) =>
        (b['filters'] as unknown[]).some((f) => JSON.stringify(f) === JSON.stringify({ field: 'status', op: 'eq', value: 'assigned' })),
      )).toBe(true),
    )
    fireEvent.change(screen.getByLabelText('Exact value'), { target: { value: 'USED-1' } })
    fireEvent.click(screen.getByTestId('codes-search'))
    await waitFor(() =>
      expect(queryBodies(clientMock, 'code_tag').some((b) =>
        (b['filters'] as unknown[]).some((f) => JSON.stringify(f) === JSON.stringify({ field: 'value', op: 'eq', value: 'USED-1' })),
      )).toBe(true),
    )
  })
})
