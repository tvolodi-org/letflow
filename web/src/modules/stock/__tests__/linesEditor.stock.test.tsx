// @vitest-environment jsdom
/** T-1448 S1-S5: the lines editor on the stock documents (adapter of LFLinesEditor). */
import { readFileSync } from 'node:fs'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { DOCS, LIST, addFirstLine, fakeDocument, fakeMasters, pickItem, queryBodies, renderStock, stockDoc, withPost } from './stockTestKit'
import { incrementQuantity, scanLines } from '../documents/LinesEditor'
import { buildCatalog } from '../documents/linesCatalog'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
  localStorage.clear()
})
afterEach(() => cleanup())

const headers = () => screen.getAllByRole('columnheader').map((h) => h.textContent ?? '')
const created = () => clientMock.post.mock.calls.filter(([p]) => p === DOCS) as [string, Record<string, unknown>][]

describe('S1 columns per document kind', () => {
  const COMMON = ['Line', 'Item', 'Lot', 'Quantity, unit']
  const cases: [string, string[]][] = [
    ['receipt', [...COMMON, 'Unit price', 'Line value']],
    ['issue', COMMON],
    ['write_off', COMMON],
    ['transfer', COMMON],
    ['hand_over', COMMON],
    ['return', COMMON],
    ['opening', [...COMMON, 'Location', 'Responsible', 'Real receipt date', 'Unit price', 'Line value']],
  ]
  it.each(cases)('%s: the grid has the columns of its kind and an action cell', async (kind, expected) => {
    renderStock(`${LIST}/new?kind=${kind}`, withPost)
    await addFirstLine()
    const got = headers()
    expect(got.slice(0, expected.length)).toEqual(expected)
    expect(got).toHaveLength(expected.length + 1) // + the sr-only actions header
  })

  it('a receipt shows the sum of the line values in the footer under the value column', async () => {
    renderStock(`${LIST}/new?kind=receipt`, withPost)
    const row = await addFirstLine()
    fireEvent.change(within(row).getByLabelText('Line value'), { target: { value: '2.5' } })
    expect(screen.getByTestId('lines-editor').querySelector('tfoot')).toHaveTextContent('2.5')
  })
})

describe('S2 line by line sends the same body as the grid', () => {
  it('an issue saved in the one-line form posts the line exactly like a grid row', async () => {
    localStorage.setItem('lf.linesMode.stock-documents.lines', 'form')
    fakeMasters(clientMock)
    const masters = clientMock.post.getMockImplementation()!
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => (p === DOCS ? stockDoc({ id: 'dn' }) : masters(p, b)))
    renderStock(`${LIST}/new?kind=issue`, withPost)
    await screen.findByTestId('document-form')
    fireEvent.click(await screen.findByRole('button', { name: 'Add line' }))
    await waitFor(() => {
      const input = screen.getByLabelText('Item')
      fireEvent.change(input, { target: { value: 'Bolt M8' } })
      fireEvent.blur(input)
      expect(screen.getByText('pcs')).toBeInTheDocument()
    })
    fireEvent.change(screen.getByLabelText('Quantity'), { target: { value: '3' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save and close' }))
    expect(screen.getByTestId('line-saved-row')).toBeInTheDocument()
    // header fields come from the form; the lines part of the body is what is compared
    const orgUnit = within(screen.getByTestId('document-form')).getByLabelText('Org unit')
    await within(orgUnit).findByRole('option', { name: 'Main store' })
    fireEvent.change(orgUnit, { target: { value: 'u1' } })
    fireEvent.change(within(screen.getByTestId('document-form')).getByLabelText('Location'), { target: { value: 'l1' } })
    fireEvent.change(within(screen.getByTestId('document-form')).getByLabelText('Responsible'), { target: { value: 'e1' } })
    fireEvent.change(screen.getByLabelText('Event time, date'), { target: { value: '2026-11-04' } })
    fireEvent.change(screen.getByLabelText('Event time, time'), { target: { value: '10:00' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
    await waitFor(() => expect(created()).toHaveLength(1))
    expect(created()[0]![1]['lines']).toEqual([{ catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '3' }])
  })
})

describe('S3 posted document view', () => {
  it('150 lines mount only a window of rows', async () => {
    const lines = Array.from({ length: 150 }, (_, i) => ({ line_id: `l${i}`, line_no: i + 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '1.000000000' }))
    fakeDocument(clientMock, stockDoc({ id: 'dp', state: 'posted', number: 'RC-9', lines }))
    renderStock(`${LIST}/dp`, withPost)
    await screen.findByTestId('document-lines')
    const rows = screen.getAllByTestId('line-row')
    expect(rows.length).toBeLessThanOrEqual(30)
    expect(rows.length).toBeGreaterThan(0)
    expect(screen.getByTestId('lines-scroll')).toHaveAttribute('aria-rowcount', '151')
    expect(screen.queryByLabelText('Scan field')).not.toBeInTheDocument()
  })
})

describe('S4 catalog and lots', () => {
  it('lots are asked per item present in the lines, never for a blank row', async () => {
    const doc = stockDoc({
      id: 'd1',
      lines: [
        { line_id: 'a', line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '1' },
        { line_id: 'b', line_no: 2, catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '2' },
        { line_id: 'c', line_no: 3, catalog_item_id: 'i2', catalog_uom_id: 'm1', quantity: '3' },
      ],
    })
    fakeDocument(clientMock, doc)
    renderStock(`${LIST}/d1`, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'Edit' }))
    await screen.findAllByTestId('line-editor-row')
    await waitFor(() => expect(queryBodies(clientMock, 'catalog_lot').length).toBeGreaterThan(0))
    const items = queryBodies(clientMock, 'catalog_lot').map((b) => JSON.stringify(b['filters']))
    expect(items.every((f) => f.includes('"item_id"'))).toBe(true)
    expect(new Set(items).size).toBe(2)
  })

  it('the catalog resolves a code, "CODE – Title", a barcode and a unique title; suggest gives at most 8', () => {
    const opts = Array.from({ length: 12 }, (_, i) => ({ value: `i${i}`, label: '', fields: { code: `C-${i}`, name: `Part ${i}`, base_uom_id: 'm1', barcode: `46${i}`, tracking_policy: i === 0 ? 'none' : 'lot' } }))
    const c = buildCatalog(opts)
    expect(c.resolve('c-3')?.id).toBe('i3')
    expect(c.resolve('C-4 – Part 4')?.id).toBe('i4')
    expect(c.resolve('465')?.id).toBe('i5')
    expect(c.resolve('part 6')?.id).toBe('i6')
    expect(c.resolve('nope')).toBeNull()
    expect(c.suggest('part')).toHaveLength(8)
    expect(c.byId('i0')?.lotTracked).toBe(false)
    expect(c.byId('i1')?.lotTracked).toBe(true)
  })

  it('scan: +1 on the first line of the item, else a new line with quantity 1 and the base unit', () => {
    const c = buildCatalog([{ value: 'i1', label: '', fields: { code: 'B', name: 'Bolt', base_uom_id: 'm1' } }])
    const empty = { itemId: '', uomId: '', lotId: '', quantity: '', unitPrice: '', lineValue: '', locationId: '', responsibleId: '', receivedOn: '', externalRefSystem: '', externalRefId: '' }
    const added = scanLines('B', [], c.resolve)
    expect(added.status).toBe('new')
    expect(added.lines[0]).toMatchObject({ itemId: 'i1', uomId: 'm1', quantity: '1' })
    const again = scanLines('B', [{ ...empty, itemId: 'i1', uomId: 'm1', quantity: '2.5' }], c.resolve)
    expect(again).toMatchObject({ status: 'inc', index: 0, qty: '3.5' })
    expect(scanLines('X', [], c.resolve).status).toBe('unknown')
    expect(incrementQuantity('')).toBe('1')
  })
})

describe('S5 the line limit lives in one place', () => {
  const read = (rel: string) => readFileSync(new URL(rel, import.meta.url), 'utf8')
  it('MAX_LINES is declared once and the adapter and the message use it', () => {
    const model = read('../documents/documentsModel.ts')
    expect(model.match(/export const MAX_LINES = \d+/g)).toHaveLength(1)
    const adapter = read('../documents/LinesEditor.tsx')
    expect(adapter).toContain('max={MAX_LINES}')
    expect(adapter).not.toMatch(/\b100\b/)
    const msgs = read('../documents/documentsMessages.ts')
    expect(msgs.match(/'stock\.doc\.error\.lines_count': '[^']*\{max\}[^']*'/g)).toHaveLength(3)
  })
  it('the maximum message names the limit', async () => {
    renderStock(`${LIST}/new?kind=issue`, withPost)
    const row = await addFirstLine()
    await pickItem(row, 'i1')
    expect(screen.getByText('1 of 100 lines')).toBeInTheDocument()
  })
})
