// @vitest-environment jsdom
/** S1–S9 — GH 3735 / REQ-702 criterion 3: open, lines with typed input, surplus line, entry log, close. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { BASE, LIST, accessOf, entry, fakeCounts, line, order, renderCounts, writes } from './countsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-counts' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), put: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => cleanup())

const COUNTING = order({ status: 'counting' })
const sheet = (extra: Parameters<typeof fakeCounts>[1] = {}) =>
  fakeCounts(clientMock, { orders: [COUNTING], linePages: [[line(1), line(2, { counted_quantity: '3' })]], ...extra })

describe('S1 open', () => {
  it('calls POST open on an ordered count', async () => {
    fakeCounts(clientMock, { orders: [order({ status: 'ordered' })] })
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('count-open'))
    await waitFor(() => expect(writes(clientMock)).toEqual([['POST', `${BASE}/c1/open`, undefined]]))
  })
})

describe('S2 lines', () => {
  it('shows the columns and follows next_cursor', async () => {
    sheet({ linePages: [[line(1)], [line(2, { catalog_lot_id: 't1', kind: 'surplus', book_quantity: null })]] })
    renderCounts(`${LIST}/c1`)
    const table = await screen.findByTestId('count-sheet')
    for (const h of ['Location', 'Item', 'Lot', 'Responsible', 'Unit', 'Book', 'Counted']) {
      expect(within(table).getByRole('columnheader', { name: h })).toBeInTheDocument()
    }
    await waitFor(() => expect(within(table).getByText('Bolt M8')).toBeInTheDocument())
    await userEvent.click(within(table).getByTestId('load-more'))
    expect(await within(table).findByText('LOT-7')).toBeInTheDocument()
    expect(within(table).getByText('Surplus')).toBeInTheDocument()
    expect(clientMock.get).toHaveBeenCalledWith(`${BASE}/c1/lines`, { cursor: 'p1' })
  })
})

describe('S3 typed input', () => {
  it('Enter and blur send exactly {counted_quantity: text}; unchanged text sends nothing', async () => {
    sheet()
    renderCounts(`${LIST}/c1`)
    const input = await screen.findByTestId('count-input-1')
    await userEvent.type(input, '3.50{Enter}')
    await waitFor(() => expect(writes(clientMock)).toEqual([['PUT', `${BASE}/c1/lines/1/count`, { counted_quantity: '3.50' }]]))
    const second = screen.getByTestId('count-input-2')
    await userEvent.click(second)
    await userEvent.tab()
    expect(writes(clientMock)).toHaveLength(1)
    await userEvent.clear(second)
    await userEvent.type(second, '0')
    await userEvent.tab()
    await waitFor(() => expect(writes(clientMock)[1]).toEqual(['PUT', `${BASE}/c1/lines/2/count`, { counted_quantity: '0' }]))
  })
})

describe('S4 invalid input', () => {
  it.each(['-1', '1e3', 'abc', '1,5'])('does not send "%s" and shows the field error', async (text) => {
    sheet()
    renderCounts(`${LIST}/c1`)
    const input = await screen.findByTestId('count-input-1')
    await userEvent.type(input, `${text}{Enter}`)
    expect(await screen.findByText('Enter a number, 0 or more, with a dot for the fraction.')).toBeInTheDocument()
    expect(writes(clientMock)).toEqual([])
  })
})

describe('S5 surplus line', () => {
  it('posts the exact body; a bad quantity blocks it', async () => {
    sheet()
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('surplus-show'))
    const form = await screen.findByTestId('surplus-form')
    await waitFor(() => expect(within(form).getByRole('option', { name: 'Shelf B' })).toBeInTheDocument())
    await userEvent.selectOptions(within(form).getByLabelText('Location'), 'l2')
    await userEvent.selectOptions(within(form).getByLabelText('Item'), 'i1')
    await userEvent.selectOptions(within(form).getByLabelText('Unit'), 'm1')
    await userEvent.type(within(form).getByLabelText('Counted quantity'), '-2')
    await userEvent.click(screen.getByTestId('surplus-add'))
    expect(await within(form).findByText('Enter a number, 0 or more, with a dot for the fraction.')).toBeInTheDocument()
    expect(writes(clientMock)).toEqual([])
    await userEvent.clear(within(form).getByLabelText('Counted quantity'))
    await userEvent.type(within(form).getByLabelText('Counted quantity'), '2.5')
    await userEvent.click(screen.getByTestId('surplus-add'))
    await waitFor(() => expect(writes(clientMock)).toEqual([[
      'POST', `${BASE}/c1/surplus-lines`, { location_id: 'l2', catalog_item_id: 'i1', unit_ref: 'm1', counted_quantity: '2.5' },
    ]]))
  })
})

describe('S6 entry log', () => {
  it('shows user and time in the tenant zone and loads more', async () => {
    sheet({ entryPages: [[entry(1)], [entry(2, { entered_by: 'user-2', quantity_before: '4', quantity_after: '5' })]] })
    renderCounts(`${LIST}/c1`)
    const log = await screen.findByTestId('entry-log')
    expect(await within(log).findByText('user-1')).toBeInTheDocument()
    expect(within(log).getByText('2026-11-10 09:30')).toBeInTheDocument()
    await userEvent.click(within(log).getByTestId('load-more'))
    expect(await within(log).findByText('user-2')).toBeInTheDocument()
  })
})

describe('S7 close', () => {
  it('calls POST close after the confirm dialog', async () => {
    sheet()
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('count-close'))
    expect(writes(clientMock)).toEqual([])
    await userEvent.click(within(await screen.findByTestId('confirm-dialog')).getByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(writes(clientMock)).toEqual([['POST', `${BASE}/c1/close`, undefined]]))
  })
})

describe('S8 counted', () => {
  it('has read-only counted cells and no surplus form or Close button', async () => {
    fakeCounts(clientMock, { orders: [order({ status: 'counted' })], linePages: [[line(1, { counted_quantity: '9' })]] })
    renderCounts(`${LIST}/c1`)
    const table = await screen.findByTestId('count-sheet')
    expect(await within(table).findByText('9')).toBeInTheDocument()
    expect(screen.queryByTestId('count-input-1')).not.toBeInTheDocument()
    expect(screen.queryByTestId('surplus-show')).not.toBeInTheDocument()
    expect(screen.queryByTestId('count-close')).not.toBeInTheDocument()
  })
})

describe('S9 without StockCountRecord', () => {
  it('has read-only cells and no Open, Close or surplus control', async () => {
    sheet()
    renderCounts(`${LIST}/c1`, accessOf('StockRead', 'StockCountOrder'))
    const table = await screen.findByTestId('count-sheet')
    await waitFor(() => expect(within(table).getAllByText('Bolt M8').length).toBeGreaterThan(0))
    for (const id of ['count-input-1', 'count-close', 'surplus-show']) expect(screen.queryByTestId(id)).not.toBeInTheDocument()
    cleanup()
    fakeCounts(clientMock, { orders: [order({ status: 'ordered' })] })
    renderCounts(`${LIST}/c1`, accessOf('StockRead', 'StockCountOrder'))
    await screen.findByTestId('count-cancel')
    expect(screen.queryByTestId('count-open')).not.toBeInTheDocument()
  })
})
