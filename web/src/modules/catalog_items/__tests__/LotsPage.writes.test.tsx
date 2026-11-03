// @vitest-environment jsdom
/** W1/W2/W3 (AC3) — GH 3605 / REQ-673: create, edit and retire calls. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { findLot, queryLot, fakeServer, queryBodies, rec, renderLots, writeCalls } from './catalogItemsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-ci-writes' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const BASE = '/api/v1/modules/catalog_items'
const ITEM1 = rec('i1', 'catalog_item', { code: 'ITEM-1', name: 'Bolt', active: true })
const LOT1 = rec('l1', 'catalog_lot', { code: 'LOT-A', item_id: 'i1', producer: 'Acme', mark: 'M1', expiry_date: '2027-01-01', active: true })

function DATA() {
  return { catalog_item: [ITEM1], catalog_lot: [LOT1] }
}

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
  fakeServer(clientMock, DATA())
})
afterEach(() => cleanup())

describe('W1 create', () => {
  it('POSTs /lots with item_id, code, idempotency_key; omits empty optional fields', async () => {
    renderLots('/admin/catalog/lots')
    await findLot('LOT-A')
    fireEvent.click(screen.getByTestId('create-lot'))
    fireEvent.change(await screen.findByLabelText('Item'), { target: { value: 'i1' } })
    fireEvent.change(screen.getByLabelText('Lot code'), { target: { value: 'LOT-NEW' } })
    const before = queryBodies(clientMock, 'catalog_lot').length
    fireEvent.click(screen.getByTestId('create-submit'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const [call] = writeCalls(clientMock)
    expect(call.method).toBe('POST')
    expect(call.path).toBe(`${BASE}/lots`)
    expect(call.body['item_id']).toBe('i1')
    expect(call.body['code']).toBe('LOT-NEW')
    expect(call.body['idempotency_key']).toBeTruthy()
    expect(call.body).not.toHaveProperty('producer')
    expect(call.body).not.toHaveProperty('mark')
    expect(call.body).not.toHaveProperty('expiry_date')
    await waitFor(() => expect(queryBodies(clientMock, 'catalog_lot').length).toBeGreaterThan(before))
  })

  it('POSTs /lots including expiry_date when filled in', async () => {
    renderLots('/admin/catalog/lots')
    await findLot('LOT-A')
    fireEvent.click(screen.getByTestId('create-lot'))
    fireEvent.change(await screen.findByLabelText('Item'), { target: { value: 'i1' } })
    fireEvent.change(screen.getByLabelText('Lot code'), { target: { value: 'LOT-EXP' } })
    fireEvent.change(screen.getByLabelText(/^Expiry date/), { target: { value: '2026-12-31' } })
    fireEvent.click(screen.getByTestId('create-submit'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].body['expiry_date']).toBe('2026-12-31')
  })

  it('disables create submit when item or code is empty', async () => {
    renderLots('/admin/catalog/lots')
    await findLot('LOT-A')
    fireEvent.click(screen.getByTestId('create-lot'))
    await screen.findByLabelText('Item')
    expect(screen.getByTestId('create-submit')).toBeDisabled()
  })
})

describe('W2 edit', () => {
  it('PATCHes /lots/:id with exactly producer, mark, expiry_date and idempotency_key', async () => {
    renderLots('/admin/catalog/lots')
    await findLot('LOT-A')
    fireEvent.click(screen.getByTestId('edit-LOT-A'))
    fireEvent.change(await screen.findByLabelText(/^Producer/), { target: { value: 'NewCo' } })
    const before = queryBodies(clientMock, 'catalog_lot').length
    fireEvent.click(screen.getByTestId('edit-submit'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const [call] = writeCalls(clientMock)
    expect(call.method).toBe('PATCH')
    expect(call.path).toBe(`${BASE}/lots/l1`)
    expect(Object.keys(call.body).sort()).toEqual(['expiry_date', 'idempotency_key', 'mark', 'producer'])
    expect(call.body['producer']).toBe('NewCo')
    expect(call.body['idempotency_key']).toBeTruthy()
    await waitFor(() => expect(queryBodies(clientMock, 'catalog_lot').length).toBeGreaterThan(before))
  })

  it('sends null for an emptied field', async () => {
    renderLots('/admin/catalog/lots')
    await findLot('LOT-A')
    fireEvent.click(screen.getByTestId('edit-LOT-A'))
    fireEvent.change(await screen.findByLabelText(/^Producer/), { target: { value: '' } })
    fireEvent.click(screen.getByTestId('edit-submit'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].body['producer']).toBeNull()
  })

  it('does not include item_id or code in the edit body', async () => {
    renderLots('/admin/catalog/lots')
    await findLot('LOT-A')
    fireEvent.click(screen.getByTestId('edit-LOT-A'))
    await screen.findByLabelText(/^Producer/)
    fireEvent.click(screen.getByTestId('edit-submit'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    expect(writeCalls(clientMock)[0].body).not.toHaveProperty('item_id')
    expect(writeCalls(clientMock)[0].body).not.toHaveProperty('code')
  })
})

describe('W3 retire', () => {
  it('POSTs /lots/:id/retire with only idempotency_key after confirmation, then reloads', async () => {
    renderLots('/admin/catalog/lots')
    await findLot('LOT-A')
    fireEvent.click(screen.getByTestId('retire-LOT-A'))
    expect(await screen.findByText(/A retired lot cannot be activated again/)).toBeInTheDocument()
    expect(writeCalls(clientMock)).toHaveLength(0)
    const dialog = screen.getByRole('dialog')
    const { within: wi } = await import('@testing-library/react')
    const confirmBtn = wi(dialog).getByRole('button', { name: 'Retire' })
    const before = queryBodies(clientMock, 'catalog_lot').length
    fireEvent.click(confirmBtn)
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const [call] = writeCalls(clientMock)
    expect(call.method).toBe('POST')
    expect(call.path).toBe(`${BASE}/lots/l1/retire`)
    expect(Object.keys(call.body)).toEqual(['idempotency_key'])
    expect(call.body['idempotency_key']).toBeTruthy()
    await waitFor(() => expect(queryBodies(clientMock, 'catalog_lot').length).toBeGreaterThan(before))
  })

  it('retired lots have no retire button', async () => {
    clientMock.post.mockReset()
    fakeServer(clientMock, {
      catalog_item: [ITEM1],
      catalog_lot: [
        rec('l2', 'catalog_lot', { code: 'LOT-RET', item_id: 'i1', active: false }),
      ],
    })
    renderLots('/admin/catalog/lots')
    await waitFor(() => expect(queryLot('LOT-RET')).not.toBeInTheDocument())
    fireEvent.click(screen.getByTestId('show-retired'))
    await findLot('LOT-RET')
    expect(screen.queryByTestId('retire-LOT-RET')).not.toBeInTheDocument()
  })
})
