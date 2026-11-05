// @vitest-environment jsdom
/** B1–B4 — GH 3767 / REQ-724: the balances screen (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { BAL, fakeMasters, queryBodies, renderStock, routeCalls } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const ROW = { sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'e1', lot: 't1', unit_ref: 'm1', quantity: '12.500' }

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.get.mockReset()
  clientMock.getBlob.mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockResolvedValue({ ledger_seq: 42, next_cursor: null, rows: [ROW] })
})
afterEach(() => cleanup())

async function pick(label: string, optionText: string) {
  const select = await screen.findByLabelText(label)
  await waitFor(() => expect(within(select).getByRole('option', { name: optionText })).toBeInTheDocument())
  fireEvent.change(select, { target: { value: (within(select).getByRole('option', { name: optionText }) as HTMLOptionElement).value } })
}

describe('B1 query keys', () => {
  it('first call has no basis, cutoff_seq or filter keys', async () => {
    renderStock(BAL)
    await screen.findByRole('table')
    await within(screen.getByRole('table')).findByText('Bolt M8')
    expect(routeCalls(clientMock, 'balances')).toEqual([{}])
  })

  it('each filter sends only its own key with the record id; lot is filtered on the chosen item', async () => {
    renderStock(BAL)
    await screen.findByText('Bolt M8')
    await pick('Location', 'Shelf A')
    await waitFor(() => expect(routeCalls(clientMock, 'balances').at(-1)).toEqual({ location: 'l1' }))
    await pick('Org unit', 'Main store')
    await waitFor(() => expect(routeCalls(clientMock, 'balances').at(-1)).toEqual({ location: 'l1', org_unit: 'u1' }))
    await pick('Responsible', 'Aigul B.')
    await waitFor(() => expect(routeCalls(clientMock, 'balances').at(-1)).toEqual({ location: 'l1', org_unit: 'u1', responsible: 'e1' }))
    expect(screen.getByLabelText('Lot')).toBeDisabled()
    await pick('Item', 'Bolt M8')
    await waitFor(() => expect(queryBodies(clientMock, 'catalog_lot').some((b) => JSON.stringify(b['filters']).includes('"item_id"'))).toBe(true))
    const lotBody = queryBodies(clientMock, 'catalog_lot').find((b) => JSON.stringify(b['filters']).includes('"item_id"'))!
    expect(lotBody['filters']).toContainEqual({ field: 'item_id', op: 'eq', value: 'i1' })
    await pick('Lot', 'LOT-7')
    await waitFor(() =>
      expect(routeCalls(clientMock, 'balances').at(-1)).toEqual({ location: 'l1', org_unit: 'u1', responsible: 'e1', sku: 'i1', lot: 't1' }),
    )
  })

  it('pickers list active records only', async () => {
    renderStock(BAL)
    await screen.findByText('Bolt M8')
    await waitFor(() => expect(queryBodies(clientMock, 'catalog_item').length).toBeGreaterThan(0))
    expect(queryBodies(clientMock, 'catalog_item')[0]['filters']).toEqual(
      expect.arrayContaining([
        { field: 'active', op: 'eq', value: true },
        { field: 'deleted', op: 'eq', value: false },
      ]),
    )
  })
})

describe('B2 row', () => {
  it('shows names, quantity text unchanged, a zero row and the ledger position', async () => {
    clientMock.get.mockResolvedValue({
      ledger_seq: 42,
      next_cursor: null,
      rows: [ROW, { ...ROW, sku: 'i2', quantity: '0' }],
    })
    renderStock(BAL)
    const cell = await screen.findByText('12.500')
    const row = cell.closest('tr')!
    for (const text of ['Bolt M8', 'Shelf A', 'Main store', 'Aigul B.', 'LOT-7', 'pcs']) {
      expect(within(row).getByText(text)).toBeInTheDocument()
    }
    expect(within(screen.getByRole('table')).getByText('Nut M8').closest('tr')).toHaveTextContent('0')
    expect(screen.getByTestId('ledger-seq')).toHaveTextContent('42')
  })
})

describe('B3 names', () => {
  it('one query per master type for the page, record_id in <ids>; null slots and unresolved ids', async () => {
    clientMock.get.mockResolvedValue({
      ledger_seq: 1,
      next_cursor: null,
      rows: [
        ROW,
        { ...ROW, sku: 'i1', responsible: null, lot: null, quantity: '3' },
        { ...ROW, sku: 'gone-id', location: 'l1', quantity: '4' },
      ],
    })
    renderStock(BAL)
    await screen.findByText('gone-id')
    for (const type of ['catalog_item', 'location_node', 'org_unit', 'org_employee', 'catalog_lot', 'catalog_uom']) {
      const named = queryBodies(clientMock, type).filter((b) =>
        (b['filters'] as { field: string }[]).some((f) => f.field === 'record_id'),
      )
      expect(named).toHaveLength(1)
    }
    const items = queryBodies(clientMock, 'catalog_item').find((b) => JSON.stringify(b['filters']).includes('record_id'))!
    expect(items['filters']).toEqual([{ field: 'record_id', op: 'in', value: ['gone-id', 'i1'] }])
    const nullRow = screen.getByText('3').closest('tr')!
    expect(within(nullRow).getAllByText('-')).toHaveLength(2)
  })
})

describe('B4 paging', () => {
  it('Load more sends the cursor, appends rows and disappears at the end', async () => {
    clientMock.get.mockImplementation(async (_p: string, params: Record<string, string>) =>
      params?.cursor === 'c1'
        ? { ledger_seq: 9, next_cursor: null, rows: [{ ...ROW, sku: 'i2', quantity: '7' }] }
        : { ledger_seq: 9, next_cursor: 'c1', rows: [ROW] },
    )
    renderStock(BAL)
    fireEvent.click(await screen.findByTestId('load-more'))
    await within(screen.getByRole('table')).findByText('Nut M8')
    expect(within(screen.getByRole('table')).getByText('Bolt M8')).toBeInTheDocument()
    expect(routeCalls(clientMock, 'balances').at(-1)).toEqual({ cursor: 'c1' })
    expect(screen.queryByTestId('load-more')).not.toBeInTheDocument()
  })
})

describe('T1 as-of date', () => {
  it('sends as_of_date only, shows the server day, zone and cutoff, and clearing drops it', async () => {
    clientMock.get.mockResolvedValue({ as_of_date: '2026-11-03', timezone: 'Asia/Almaty', cutoff_seq: 17, ledger_seq: 42, next_cursor: null, rows: [ROW] })
    renderStock(BAL)
    await within(await screen.findByRole('table')).findByText('Bolt M8')
    fireEvent.change(screen.getByLabelText('As of date'), { target: { value: '2026-11-03' } })
    await screen.findByTestId('as-of-read')
    expect(screen.getByTestId('as-of-read')).toHaveTextContent('Balance at the end of 2026-11-03 (Asia/Almaty), through ledger position 17')
    const calls = routeCalls(clientMock, 'balances')
    expect(calls[calls.length - 1]).toEqual({ as_of_date: '2026-11-03' })
    fireEvent.click(screen.getByRole('button', { name: 'Clear filters' }))
    await waitFor(() => expect(routeCalls(clientMock, 'balances').at(-1)).toEqual({}))
  })
})

describe('T7 future as-of date', () => {
  it('shows the future message, sends no as_of_date and caps the input at today', async () => {
    renderStock(BAL)
    await within(await screen.findByRole('table')).findByText('Bolt M8')
    const input = screen.getByLabelText('As of date')
    expect(input).toHaveAttribute('max')
    fireEvent.change(input, { target: { value: '2999-01-01' } })
    expect(await screen.findByText('The date cannot be in the future.')).toBeInTheDocument()
    await waitFor(() => expect(routeCalls(clientMock, 'balances').at(-1)).toEqual({}))
  })
})

describe('T3 export', () => {
  const download = () => {
    const create = vi.fn(() => 'blob:x')
    Object.assign(URL, { createObjectURL: create, revokeObjectURL: vi.fn() })
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
    return { create, click }
  }
  it('asks for the xlsx with the current filters and day, no cursor, and saves the file', async () => {
    const { create, click } = download()
    clientMock.getBlob.mockResolvedValue({ blob: new Blob(['x']), contentType: 'x' })
    renderStock(BAL)
    await within(await screen.findByRole('table')).findByText('Bolt M8')
    fireEvent.change(screen.getByLabelText('As of date'), { target: { value: '2026-11-03' } })
    await waitFor(() => expect(routeCalls(clientMock, 'balances').at(-1)).toEqual({ as_of_date: '2026-11-03' }))
    fireEvent.click(screen.getByRole('button', { name: 'Export to Excel' }))
    await waitFor(() => expect(click).toHaveBeenCalled())
    expect(clientMock.getBlob).toHaveBeenCalledWith('/api/v1/modules/stock/balances', { as_of_date: '2026-11-03', format: 'xlsx' })
    expect(create).toHaveBeenCalled()
  })
  it('shows an error and saves nothing when the export fails', async () => {
    const { click } = download()
    clientMock.getBlob.mockRejectedValue({ status: 403 })
    renderStock(BAL)
    await within(await screen.findByRole('table')).findByText('Bolt M8')
    fireEvent.click(screen.getByRole('button', { name: 'Export to Excel' }))
    expect(await screen.findByText('The file could not be exported. Try again.')).toBeInTheDocument()
    expect(click).not.toHaveBeenCalled()
  })
})
