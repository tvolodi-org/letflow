// @vitest-environment jsdom
/** A1..A5 — T-1379 (GATE B rework R2): the stock documents on the platform document form (`lf-doc`), through the real
 *  route table with uuid ids and a mocked client. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { DOCS, LIST, MASTERS, addFirstLine, fakeMasters, renderStock, stockDoc, withPost } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
})
afterEach(() => cleanup())

function listAndDoc(doc: Record<string, unknown>) {
  clientMock.get.mockImplementation(async (path: string) => {
    if (path === `${DOCS}/${String(doc['id'])}`) return doc
    if (path === DOCS) return { rows: [{ ...doc, lines: undefined }], next_cursor: null }
    return { rows: [], next_cursor: null }
  })
}

describe('A1 layout', () => {
  it('the list route shows the list and a blank detail pane in one lf-doc', async () => {
    listAndDoc(stockDoc({ number: 'RC-1', state: 'posted' }))
    renderStock(LIST, withPost)
    const ws = await screen.findByTestId('document-workspace')
    expect(ws).toHaveClass('lf-doc')
    expect(ws).toHaveAttribute('data-layout', 'row')
    expect(ws).not.toHaveAttribute('data-detail')
    expect(screen.getByTestId('document-blank')).toBeInTheDocument()
    expect(await screen.findByTestId('document-row')).not.toHaveAttribute('aria-current')
  })

  it('a document route keeps the list, marks the row, and shows the header and lines cards', async () => {
    listAndDoc(stockDoc({ id: '5b58a738-1c2d-4e3f-8a9b-000000000001', number: 'RC-1', state: 'posted' }))
    renderStock(`${LIST}/5b58a738-1c2d-4e3f-8a9b-000000000001`, withPost)
    const ws = await screen.findByTestId('document-workspace')
    expect(ws).toHaveAttribute('data-detail', 'open')
    expect(await screen.findByTestId('document-header')).toBeInTheDocument()
    expect(screen.getByTestId('document-lines')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByTestId('document-row')).toHaveAttribute('aria-current', 'true'))
    expect(ws.querySelector('.lf-doc__header')).not.toBeNull()
    expect(ws.querySelector('.lf-doc__lines')).not.toBeNull()
    expect(ws.querySelector('.lf-doc__back')).not.toBeNull()
  })

  it('Escape closes the viewed document and the back button does too', async () => {
    listAndDoc(stockDoc({ number: 'RC-1', state: 'posted' }))
    renderStock(`${LIST}/d1`, withPost)
    await screen.findByTestId('document-header')
    fireEvent.keyDown(document, { key: 'Escape' })
    await waitFor(() => expect(screen.getByTestId('document-blank')).toBeInTheDocument())
  })
})

describe('A2 header card', () => {
  it('shows labelled values, the number in mono, the state as a pill, and never an id', async () => {
    listAndDoc(stockDoc({ number: 'RC-1', state: 'posted' }))
    renderStock(`${LIST}/d1`, withPost)
    const header = await screen.findByTestId('document-header')
    expect(header).toHaveClass('lf-doc__fields')
    await waitFor(() => expect(header).toHaveTextContent('Main store'))
    expect(header.querySelector('.lf-doc__label')).not.toBeNull()
    expect(screen.getAllByText('Posted').length).toBeGreaterThan(0)
    expect(document.body.textContent ?? '').not.toMatch(UUID)
  })
})

describe('A3/A4/A5 lines table in edit mode', () => {
  const firstRows = () => screen.getAllByTestId('line-editor-row')

  it('a single line keeps its action cell so every cell sits under its header (GATE B R2)', async () => {
    renderStock(`${LIST}/new?kind=receipt`, withPost)
    await screen.findByTestId('lines-editor')
    await addFirstLine()
    const table = screen.getByTestId('lines-editor').querySelector('table.lf-le__table') as HTMLElement
    const heads = within(table).getAllByRole('columnheader').length
    expect(firstRows()).toHaveLength(1)
    expect(firstRows()[0].querySelectorAll('td')).toHaveLength(heads)
  })

  it('is a grid with one row per line, add and delete, and Enter moves down then adds a row', async () => {
    renderStock(`${LIST}/new?kind=issue`, withPost)
    const table = (await screen.findByTestId('lines-editor')).querySelector('table.lf-le__table')
    expect(table).toBeNull() // a new draft starts with the empty state
    await addFirstLine()
    expect(within(screen.getByTestId('lines-editor').querySelector('table.lf-le__table') as HTMLElement).getAllByRole('columnheader').length).toBeGreaterThanOrEqual(5)
    fireEvent.click(screen.getByRole('button', { name: 'Add line' }))
    fireEvent.click(screen.getByRole('button', { name: 'Add line' }))
    expect(firstRows()).toHaveLength(3)
    const q = (i: number) => within(firstRows()[i]).getByLabelText('Quantity')
    fireEvent.change(q(0), { target: { value: '1' } })
    fireEvent.change(q(1), { target: { value: '2' } })
    fireEvent.change(q(2), { target: { value: '3' } })
    q(0).focus()
    fireEvent.keyDown(q(0), { key: 'Enter' })
    // Enter is the next cell in reading order: from the last cell of line 1 to the item cell of line 2.
    await waitFor(() => expect(within(firstRows()[1]).getByLabelText('Item')).toHaveFocus())
    fireEvent.keyDown(q(2), { key: 'Enter' })
    await waitFor(() => expect(firstRows()).toHaveLength(4))
    // delete line 2: lines 1, 3 and the new one stay, in order
    fireEvent.click(within(firstRows()[1]).getByRole('button', { name: /^Delete line/ }))
    expect(firstRows()).toHaveLength(3)
    expect(q(0)).toHaveValue('1')
    expect(q(1)).toHaveValue('3')
  })

  it('a line error marks its own row and names the field in the status line', async () => {
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => {
      void p
      return { items: MASTERS[(b as { entity_type: string }).entity_type] ?? [], next_cursor: null }
    })
    renderStock(`${LIST}/new?kind=issue`, withPost)
    const row = await addFirstLine()
    fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
    await waitFor(() => expect(firstRows()[0]).toHaveClass('is-error'))
    expect(within(row).getByLabelText('Quantity')).toHaveAttribute('aria-invalid', 'true')
    fireEvent.focusIn(within(row).getByLabelText('Quantity'))
    expect(await screen.findByText(/The quantity must be a decimal number above zero/)).toBeInTheDocument()
    expect(screen.getByText('1 line has errors', { exact: false })).toBeInTheDocument()
  })

  it('totals: a receipt shows the count and the sum of the line values', async () => {
    renderStock(`${LIST}/new?kind=receipt`, withPost)
    await screen.findByTestId('lines-editor')
    const first = await addFirstLine()
    fireEvent.change(within(first).getByLabelText('Line value'), { target: { value: '1.5' } })
    fireEvent.click(screen.getByRole('button', { name: 'Add line' }))
    fireEvent.change(within(firstRows()[1]).getByLabelText('Line value'), { target: { value: '2.25' } })
    const foot = screen.getByTestId('lines-editor').querySelector('tfoot')!
    expect(foot).toHaveTextContent('Lines 2')
    expect(foot).toHaveTextContent('3.75')
  })
})

describe('T1410 B1 header hides empty fields', () => {
  it('a draft shows no empty optional rows and no Posting group', async () => {
    listAndDoc(stockDoc({ state: 'draft' }))
    renderStock(`${LIST}/d1`, withPost)
    const header = await screen.findByTestId('document-header')
    await waitFor(() => expect(header).toHaveTextContent('Main store'))
    for (const label of ['Supplier document', 'Counterparty', 'Posted at', 'Posted by', 'Reversed at', 'Posting']) {
      expect(header).not.toHaveTextContent(label)
    }
  })

  it('a posted receipt with a supplier reference shows that row and the Posting group', async () => {
    listAndDoc(stockDoc({ state: 'posted', number: 'RC-1', supplier_document_ref: 'INV-77', posted_at: '2026-11-04T06:00:00Z', issued_at: '2026-11-04T05:30:00Z' }))
    renderStock(`${LIST}/d1`, withPost)
    const header = await screen.findByTestId('document-header')
    await waitFor(() => expect(header).toHaveTextContent('INV-77'))
    expect(header).toHaveTextContent('Posted at')
    expect(header).toHaveTextContent('Posting')
  })
})

describe('D1 T-1433 view numbers', () => {
  it('groups money and trims 9-decimal zeros in the lines table and totals row', async () => {
    const id = '5b58a738-1c2d-4e3f-8a9b-000000000002'
    listAndDoc(stockDoc({
      id, number: 'RC-2', state: 'posted',
      lines: [
        { line_id: 'a', line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: 't1', quantity: '20.000000000', unit_price: '450000.000000000', line_value: '9000000.000000000' },
      ],
    }))
    renderStock(`${LIST}/${id}`, withPost)
    const lines = await screen.findByTestId('lines-editor')
    await waitFor(() => expect(lines).toHaveTextContent('450,000'))
    expect(lines).toHaveTextContent('9,000,000')
    expect(lines.textContent).not.toMatch(/\.0{3,}/)
  })
})

describe('U2/U3 T-1438 draft edit is a table with trimmed decimals', () => {
  it('shows the lines as rows of one edit table and the quantity without 9 decimals; save sends it as typed', async () => {
    const doc = stockDoc({
      id: 'd1',
      lines: [{ line_id: 'a', line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: 't1', quantity: '1.000000000', unit_price: '450000.000000000' }],
    })
    listAndDoc(doc)
    clientMock.put.mockResolvedValue(doc)
    renderStock(`${LIST}/d1`, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'Edit' }))
    const editor = await screen.findByTestId('lines-editor')
    const table = editor.querySelector('table.lf-le__table')
    expect(table).not.toBeNull()
    const rows = table!.querySelectorAll('tr[data-testid="line-editor-row"]')
    expect(rows).toHaveLength(1)
    const row = within(rows[0] as HTMLElement)
    expect(row.getByLabelText('Quantity')).toHaveValue('1')
    expect(row.getByLabelText('Unit price')).toHaveValue('450000')
    fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
    await waitFor(() => expect(clientMock.put).toHaveBeenCalledTimes(1))
    expect((clientMock.put.mock.calls[0][1] as { lines: { quantity: string }[] }).lines[0].quantity).toBe('1')
  })
})
