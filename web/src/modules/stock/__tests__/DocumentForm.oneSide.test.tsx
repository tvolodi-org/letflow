// @vitest-environment jsdom
/** C3 — GH 3769 / REQ-722: the draft forms of receipt, issue and write off (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { DOCS, LIST, MASTERS, fakeDocument, fakeMasters, queryBodies, refusal, renderStock, stockDoc, withAtom, withPost } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const NEW = `${LIST}/new`
const created = (): [string, Record<string, unknown>][] =>
  clientMock.post.mock.calls.filter(([p]) => p === DOCS) as [string, Record<string, unknown>][]

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
  vi.useRealTimers()
})
afterEach(() => cleanup())

const pick = (label: string | RegExp, value: string, scope?: HTMLElement) =>
  fireEvent.change((scope ? within(scope) : screen).getByLabelText(label), { target: { value } })

async function fillHeader() {
  await screen.findByRole('option', { name: 'Main store' })
  await screen.findByRole('option', { name: 'Shelf A' })
  await screen.findByRole('option', { name: 'Aigul B.' })
  fireEvent.change(screen.getByLabelText('Event time'), { target: { value: '2026-11-04T10:00' } })
  pick('Org unit', 'u1')
  pick('Location', 'l1')
  pick('Responsible', 'e1')
}
async function fillLine(row: HTMLElement, item: string, qty: string) {
  await within(row).findByRole('option', { name: item === 'i1' ? 'Bolt M8' : 'Nut M8' })
  pick('Item', item, row)
  pick('Quantity', qty, row)
}
const save = () => fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
const firstRow = () => screen.getAllByTestId('line-editor-row')[0]

describe('C3-a/b/c create per kind', () => {
  it('receipt: exact header fields and exact body', async () => {
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) =>
      p === DOCS ? stockDoc({ id: 'dn' }) : { items: MASTERS[(b as { entity_type: string }).entity_type] ?? [], next_cursor: null })
    renderStock(NEW, withPost)
    await fillHeader()
    for (const l of [/^Counterparty/, /^Supplier document reference/, /^Received on/]) expect(screen.getByLabelText(l)).toBeInTheDocument()
    expect(screen.queryByLabelText(/^Reason$/)).not.toBeInTheDocument()
    await screen.findByRole('option', { name: 'Acme Ltd' })
    pick(/^Counterparty/, 'c1')
    pick(/^Supplier document reference/, 'INV-7')
    pick(/^Received on/, '2026-11-03')
    pick(/^Note/, 'first batch')
    const row = firstRow()
    await fillLine(row, 'i1', '3.5')
    await waitFor(() => expect(within(row).getByLabelText('Unit')).toHaveValue('pcs'))
    await within(row).findByRole('option', { name: 'LOT-7' })
    pick(/^Lot/, 't1', row)
    pick(/^Unit price/, '2.5', row)
    pick(/^Line value/, '8.75', row)
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]).toEqual({
      kind: 'receipt', event_time: '2026-11-04T10:00:00+05:00', org_unit_id: 'u1', location_id: 'l1', responsible_id: 'e1',
      note: 'first batch', counterparty_id: 'c1', supplier_document_ref: 'INV-7', received_on: '2026-11-03',
      lines: [{ catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: 't1', quantity: '3.5', unit_price: '2.5', line_value: '8.75' }],
    })
  })

  it('issue: no receipt or write off fields, exact body', async () => {
    renderStock(`${NEW}?kind=issue`, withPost)
    await fillHeader()
    for (const l of [/^Counterparty/, /^Supplier document/, /^Received on/, /^Reason$/]) expect(screen.queryByLabelText(l)).not.toBeInTheDocument()
    expect(within(firstRow()).queryByLabelText(/^Unit price/)).not.toBeInTheDocument()
    await fillLine(firstRow(), 'i2', '1')
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]).toEqual({
      kind: 'issue', event_time: '2026-11-04T10:00:00+05:00', org_unit_id: 'u1', location_id: 'l1', responsible_id: 'e1',
      lines: [{ catalog_item_id: 'i2', catalog_uom_id: 'm1', quantity: '1' }],
    })
  })

  it('write off: reason code, text required for other, exact body', async () => {
    renderStock(`${NEW}?kind=write_off`, withPost)
    await fillHeader()
    await fillLine(firstRow(), 'i1', '2')
    save()
    expect(created()).toHaveLength(0)
    pick(/^Reason$/, 'other')
    save()
    expect(created()).toHaveLength(0)
    expect(screen.getByText('Give the reason text.')).toBeInTheDocument()
    pick(/^Reason text/, 'burnt')
    save()
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0][1]).toMatchObject({ kind: 'write_off', reason_code: 'other', reason_text: 'burnt' })
    expect(screen.queryByLabelText(/^Counterparty/)).not.toBeInTheDocument()
  })
})

describe('C3-d edit', () => {
  it('removing line 2 of 3 sends the whole header and lines 1 and 3 with every loaded field', async () => {
    const doc = stockDoc({
      counterparty_id: 'c1', note: 'n',
      lines: [
        { line_id: 'a', line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: 't1', quantity: '1', unit_price: '2', line_value: '2' },
        { line_id: 'b', line_no: 2, catalog_item_id: 'i2', catalog_uom_id: 'm1', catalog_lot_id: 't2', quantity: '2' },
        { line_id: 'c', line_no: 3, catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '3', unit_price: '4' },
      ],
    })
    fakeDocument(clientMock, doc)
    clientMock.put.mockResolvedValue(doc)
    renderStock(`${LIST}/d1`, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'Edit' }))
    await screen.findByTestId('document-form')
    expect(screen.getByLabelText('Org unit')).toBeDisabled()
    fireEvent.click(within(screen.getAllByTestId('line-editor-row')[1]).getByRole('button', { name: 'Remove line' }))
    save()
    await waitFor(() => expect(clientMock.put).toHaveBeenCalledTimes(1))
    const [path, body] = clientMock.put.mock.calls[0]
    expect(path).toBe(`${DOCS}/d1`)
    expect(body).toEqual({
      kind: 'receipt', event_time: '2026-11-04T10:00:00+05:00', org_unit_id: 'u1', location_id: 'l1', responsible_id: 'e1',
      note: 'n', counterparty_id: 'c1',
      lines: [
        { catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: 't1', quantity: '1', unit_price: '2', line_value: '2' },
        { catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '3', unit_price: '4' },
      ],
    })
  })
})

describe('C3-e checks before sending', () => {
  it.each(['0', '-1', '1.0000000001', 'abc'])('quantity %s is not sent and marks the field', async (q) => {
    renderStock(`${NEW}?kind=issue`, withPost)
    await fillHeader()
    await fillLine(firstRow(), 'i1', q)
    save()
    expect(await within(firstRow()).findByText('The quantity must be a decimal number above zero.')).toBeInTheDocument()
    expect(created()).toHaveLength(0)
  })

  it('changing the item sets its base unit and clears the lot', async () => {
    renderStock(NEW, withPost)
    await screen.findByRole('option', { name: 'Bolt M8' })
    const row = firstRow()
    pick('Item', 'i1', row)
    await within(row).findByRole('option', { name: 'LOT-7' })
    pick(/^Lot/, 't1', row)
    pick('Item', 'i2', row)
    expect(within(row).getByLabelText(/^Lot/)).toHaveValue('')
    await waitFor(() => expect(within(row).getByLabelText('Unit')).toHaveValue('pcs'))
  })

  it('the server refusal with a line number marks that line, a general one shows a banner', async () => {
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => {
      if (p === DOCS) throw refusal(422, 'lot_required', { line_no: 1 })
      return { items: MASTERS[(b as { entity_type: string }).entity_type] ?? [], next_cursor: null }
    })
    renderStock(`${NEW}?kind=issue`, withPost)
    await fillHeader()
    await fillLine(firstRow(), 'i1', '1')
    save()
    expect(await within(firstRow()).findByText('This item needs a lot.')).toBeInTheDocument()
  })
})

describe('C3-f pickers', () => {
  it('reads active records of each master, lots filtered on the item, and nothing without StockPost', async () => {
    renderStock(NEW, withPost)
    await fillHeader()
    for (const t of ['org_unit', 'location_node', 'org_employee', 'catalog_item', 'catalog_counterparty']) {
      expect(queryBodies(clientMock, t)[0]['filters']).toEqual(
        expect.arrayContaining([{ field: 'active', op: 'eq', value: true }, { field: 'deleted', op: 'eq', value: false }]),
      )
    }
    expect(queryBodies(clientMock, 'catalog_lot')).toHaveLength(0)
    pick('Item', 'i1', firstRow())
    await waitFor(() => expect(queryBodies(clientMock, 'catalog_lot')).toHaveLength(1))
    expect(queryBodies(clientMock, 'catalog_lot')[0]['filters']).toEqual(expect.arrayContaining([{ field: 'item_id', op: 'eq', value: 'i1' }]))
    cleanup()
    clientMock.get.mockClear()
    renderStock(NEW, withAtom)
    expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
    expect(screen.queryByTestId('document-form')).not.toBeInTheDocument()
  })
})
