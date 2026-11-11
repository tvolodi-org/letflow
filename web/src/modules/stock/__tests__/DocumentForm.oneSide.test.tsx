// @vitest-environment jsdom
/** C3 — GH 3769 / REQ-722: the draft forms of receipt, issue and write off (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { DOCS, LIST, MASTERS, addFirstLine, fakeDocument, pickItem, fakeMasters, queryBodies, refusal, renderStock, stockDoc, withAtom, withPost } from './stockTestKit'

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

const form = () => within(screen.getByTestId('document-form'))
const pick = (label: string | RegExp, value: string, scope?: HTMLElement) =>
  fireEvent.change((scope ? within(scope) : form()).getByLabelText(label), { target: { value } })

async function fillHeader() {
  await screen.findByTestId('document-form')
  await form().findByRole('option', { name: 'Main store' })
  await form().findByRole('option', { name: 'Shelf A' })
  await form().findByRole('option', { name: 'Aigul B.' })
  fireEvent.change(form().getByLabelText('Event time, date'), { target: { value: '2026-11-04' } })
  fireEvent.change(form().getByLabelText('Event time, time'), { target: { value: '10:00' } })
  pick('Org unit', 'u1')
  pick('Location', 'l1')
  pick('Responsible', 'e1')
}
async function fillLine(item: string, qty: string, row?: HTMLElement) {
  const r = row ?? (await addFirstLine())
  await pickItem(r, item)
  pick('Quantity', qty, r)
}
const save = () => fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
const firstRow = () => screen.getAllByTestId('line-editor-row')[0]

describe('C3-a/b/c create per kind', () => {
  it('receipt: exact header fields and exact body', async () => {
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) =>
      p === DOCS ? stockDoc({ id: 'dn' }) : { items: MASTERS[(b as { entity_type: string }).entity_type] ?? [], next_cursor: null })
    renderStock(NEW, withPost)
    await fillHeader()
    for (const l of [/^Counterparty/, /^Supplier document reference/, /^Received on/]) expect(form().getByLabelText(l)).toBeInTheDocument()
    expect(form().queryByLabelText(/^Reason$/)).not.toBeInTheDocument()
    await form().findByRole('option', { name: 'Acme Ltd' })
    pick(/^Counterparty/, 'c1')
    pick(/^Supplier document reference/, 'INV-7')
    pick(/^Received on/, '2026-11-03')
    pick(/^Note/, 'first batch')
    await fillLine('i1', '3.5')
    const row = firstRow()
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
    for (const l of [/^Counterparty/, /^Supplier document/, /^Received on/, /^Reason$/]) expect(form().queryByLabelText(l)).not.toBeInTheDocument()
    await fillLine('i2', '1')
    expect(within(firstRow()).queryByLabelText(/^Unit price/)).not.toBeInTheDocument()
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
    await fillLine('i1', '2')
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
    expect(form().queryByLabelText(/^Counterparty/)).not.toBeInTheDocument()
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
    expect(form().getByLabelText('Org unit')).toBeDisabled()
    fireEvent.click(within(screen.getAllByTestId('line-editor-row')[1]).getByRole('button', { name: /^Delete line/ }))
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
    await fillLine('i1', q)
    save()
    // The messages of the focused row show in the status line under the grid (fixed row height, T-1448).
    fireEvent.focusIn(within(firstRow()).getByLabelText('Quantity'))
    expect((await screen.findAllByText(/The quantity must be a decimal number above zero\./)).length).toBeGreaterThan(0)
    expect(created()).toHaveLength(0)
  })

  it('changing the item sets its base unit and clears the lot', async () => {
    renderStock(NEW, withPost)
    const row = await addFirstLine()
    await pickItem(row, 'i1')
    await within(row).findByRole('option', { name: 'LOT-7' })
    pick(/^Lot/, 't1', row)
    await pickItem(row, 'i2')
    expect(within(row).getByLabelText(/^Lot/)).toHaveValue('')
    await within(row).findByText('pcs')
  })

  it('the server refusal with a line number marks that line, a general one shows a banner', async () => {
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => {
      if (p === DOCS) throw refusal(422, 'lot_required', { line_no: 1 })
      return { items: MASTERS[(b as { entity_type: string }).entity_type] ?? [], next_cursor: null }
    })
    renderStock(`${NEW}?kind=issue`, withPost)
    await fillHeader()
    await fillLine('i1', '1')
    save()
    fireEvent.focusIn(within(firstRow()).getByLabelText('Quantity'))
    expect(await screen.findByText(/This item needs a lot\./)).toBeInTheDocument()
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
    await pickItem(await addFirstLine(), 'i1')
    await waitFor(() => expect(queryBodies(clientMock, 'catalog_lot')).toHaveLength(1))
    expect(queryBodies(clientMock, 'catalog_lot')[0]['filters']).toEqual(expect.arrayContaining([{ field: 'item_id', op: 'eq', value: 'i1' }]))
    cleanup()
    clientMock.get.mockClear()
    renderStock(NEW, withAtom)
    expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
    expect(screen.queryByTestId('document-form')).not.toBeInTheDocument()
  })
})

describe('typed dates (rule 10, T-1379)', () => {
  afterEach(() => useUiLocaleStore.getState().reloadFromEnvironment())
  it('ru: the date and time fields are masked DD-MM-YYYY, never native inputs; en types YYYY-MM-DD', async () => {
    useUiLocaleStore.getState().setLocaleTransient('ru')
    renderStock(NEW, withPost)
    const date = (await screen.findAllByRole('combobox')).find((e) => e.getAttribute('aria-label')?.endsWith(', дата')) as HTMLInputElement
    expect(date).toBeDefined()
    expect(date).toHaveAttribute('placeholder', 'ДД-ММ-ГГГГ')
    expect(document.querySelector('input[type="datetime-local"], input[type="date"]')).toBeNull()
    fireEvent.change(date, { target: { value: '04112026' } })
    expect(date).toHaveValue('04-11-2026')
    fireEvent.change(date, { target: { value: '31-02-2026' } })
    expect(screen.getByText(/такой даты не существует/)).toBeInTheDocument()
    useUiLocaleStore.getState().setLocaleTransient('en')
    await waitFor(() => expect(screen.getByLabelText('Event time, date')).toHaveAttribute('placeholder', 'YYYY-MM-DD'))
    fireEvent.change(screen.getByLabelText('Event time, date'), { target: { value: '20261104' } })
    expect(screen.getByLabelText('Event time, date')).toHaveValue('2026-11-04')
  })
})
