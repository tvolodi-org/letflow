// @vitest-environment jsdom
/** L1 (AC2) — GH 3605 / REQ-673: list filters, item picker, expiry sort, retired switch. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { fakeServer, queryBodies, rec, renderLots, writeCalls } from './catalogItemsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-ci' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const ITEM1 = rec('i1', 'catalog_item', { code: 'ITEM-1', name: 'Bolt', active: true })
const ITEM2 = rec('i2', 'catalog_item', { code: 'ITEM-2', name: 'Nut', active: true })
const LOT1 = rec('l1', 'catalog_lot', { code: 'LOT-A', item_id: 'i1', producer: 'Acme', mark: 'M1', expiry_date: '2027-01-01', active: true })
const LOT2 = rec('l2', 'catalog_lot', { code: 'LOT-B', item_id: 'i2', producer: '', mark: '', expiry_date: '', active: true })
const LOT3 = rec('l3', 'catalog_lot', { code: 'LOT-C', item_id: 'i1', producer: '', mark: '', expiry_date: '', active: false })

function DATA() {
  return {
    catalog_item: [ITEM1, ITEM2],
    catalog_lot: [LOT1, LOT2, LOT3],
  }
}

beforeEach(() => {
  clientMock.post.mockReset()
  fakeServer(clientMock, DATA())
})
afterEach(() => cleanup())

describe('L1 list', () => {
  it('queries catalog_lot with deleted eq false and active eq true by default', async () => {
    renderLots('/admin/catalog/lots')
    await screen.findByTestId('lot-row-LOT-A')
    const bodies = queryBodies(clientMock, 'catalog_lot')
    expect(bodies.length).toBeGreaterThan(0)
    const filters = bodies[0]?.['filters'] as { field: string; op: string; value?: unknown }[]
    expect(filters).toContainEqual({ field: 'deleted', op: 'eq', value: false })
    expect(filters).toContainEqual({ field: 'active', op: 'eq', value: true })
    expect(screen.queryByTestId('lot-row-LOT-C')).not.toBeInTheDocument()
  })

  it('shows item code and name in the lot row', async () => {
    renderLots('/admin/catalog/lots')
    const row = await screen.findByTestId('lot-row-LOT-A')
    expect(row).toHaveTextContent('ITEM-1')
    expect(row).toHaveTextContent('Bolt')
  })

  it('picking an item adds item_id eq filter and only shows that item lots', async () => {
    renderLots('/admin/catalog/lots')
    await screen.findByTestId('lot-row-LOT-A')
    fireEvent.change(screen.getByLabelText('Item'), { target: { value: 'i1' } })
    await waitFor(() =>
      expect(queryBodies(clientMock, 'catalog_lot').some((b) =>
        (b['filters'] as { field: string; op: string; value?: unknown }[]).some(
          (f) => f.field === 'item_id' && f.value === 'i1',
        ),
      )).toBe(true),
    )
    await waitFor(() => expect(screen.queryByTestId('lot-row-LOT-B')).not.toBeInTheDocument())
    expect(await screen.findByTestId('lot-row-LOT-A')).toBeInTheDocument()
  })

  it('retired switch drops the active filter', async () => {
    renderLots('/admin/catalog/lots')
    await screen.findByTestId('lot-row-LOT-A')
    fireEvent.click(screen.getByTestId('show-retired'))
    await waitFor(() =>
      expect(
        queryBodies(clientMock, 'catalog_lot').some(
          (b) => !(b['filters'] as { field: string }[]).some((f) => f.field === 'active'),
        ),
      ).toBe(true),
    )
    expect(await screen.findByTestId('lot-row-LOT-C')).toBeInTheDocument()
  })

  it('sort toggle sends expiry_date sort on the lots query', async () => {
    renderLots('/admin/catalog/lots')
    await screen.findByTestId('lot-row-LOT-A')
    fireEvent.click(screen.getByTestId('expiry-sort-toggle'))
    await waitFor(() =>
      expect(
        queryBodies(clientMock, 'catalog_lot').some(
          (b) => JSON.stringify(b['sort']) === JSON.stringify([{ field: 'expiry_date', dir: 'asc' }]),
        ),
      ).toBe(true),
    )
    fireEvent.click(screen.getByTestId('expiry-sort-toggle'))
    await waitFor(() =>
      expect(
        queryBodies(clientMock, 'catalog_lot').some(
          (b) => JSON.stringify(b['sort']) === JSON.stringify([{ field: 'expiry_date', dir: 'asc' }]),
        ),
      ).toBe(true),
    )
  })

  it('no write calls are made just from loading the list', async () => {
    renderLots('/admin/catalog/lots')
    await screen.findByTestId('lot-row-LOT-A')
    expect(writeCalls(clientMock)).toHaveLength(0)
  })
})
