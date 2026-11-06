// @vitest-environment jsdom
/** O1/O4/O5/O6 — GH T-1316 / REQ-725, REQ-726: the opening balance on the form, the view and Movements (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { stockMessages } from '../stockMessages'
import { DOCS, LIST, MOV, fakeDocument, fakeMasters, refusal, renderStock, stockDoc, withPost } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const OPENING = (over: Record<string, unknown> = {}) =>
  stockDoc({
    kind: 'opening', event_time: null, location_id: null, responsible_id: null, note: null,
    lines: [
      { line_id: 'x1', line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '3', location_id: 'l1', responsible_id: 'e1', received_on: '2026-09-15' },
      { line_id: 'x2', line_no: 2, catalog_item_id: 'i2', catalog_uom_id: 'm1', quantity: '4', location_id: 'l1', responsible_id: 'e1', received_on: '2026-09-16' },
    ],
    ...over,
  })

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
  window.localStorage.clear()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  window.localStorage.clear()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

const form = () => within(screen.getByTestId('document-form'))
const pick = (label: string | RegExp, value: string, scope?: HTMLElement) =>
  fireEvent.change((scope ? within(scope) : form()).getByLabelText(label), { target: { value } })

describe('T1410 line card title', () => {
  it('the index cell label is the bare word, so the card reads Line 1 once', async () => {
    renderStock(`${LIST}/new?kind=opening`, withPost)
    await form().findByRole('option', { name: 'Main store' })
    for (const row of screen.getAllByTestId('line-editor-row')) {
      const idx = row.querySelector('td.is-idx')
      expect(idx?.getAttribute('data-label')).toBe('Line')
      expect(idx?.getAttribute('data-label')).not.toMatch(/\d/)
    }
  })
})

describe('O1 create', () => {
  it('shows the opening fields and posts exactly the opening body', async () => {
    const masters = clientMock.post.getMockImplementation()!
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) =>
      p === DOCS ? stockDoc({ id: 'dn', kind: 'opening' }) : masters(p, b))
    renderStock(`${LIST}/new?kind=opening`, withPost)
    await form().findByRole('option', { name: 'Main store' })
    expect(form().queryByLabelText('Event time')).not.toBeInTheDocument()
    expect(form().getByLabelText('Org unit')).toBeInTheDocument()
    expect(screen.getAllByLabelText('Location')).toHaveLength(1)
    pick('Org unit', 'u1')
    const row = screen.getAllByTestId('line-editor-row')[0]
    await within(row).findByRole('option', { name: 'Bolt M8' })
    await within(row).findByRole('option', { name: 'Shelf A' })
    await within(row).findByRole('option', { name: 'Aigul B.' })
    pick('Item', 'i1', row)
    pick('Quantity', '3', row)
    pick('Location', 'l1', row)
    pick('Responsible', 'e1', row)
    pick('Real receipt date', '2026-09-15', row)
    fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
    await waitFor(() => expect(clientMock.post.mock.calls.filter(([p]) => p === DOCS)).toHaveLength(1))
    expect(clientMock.post.mock.calls.find(([p]) => p === DOCS)?.[1]).toEqual({
      kind: 'opening', org_unit_id: 'u1',
      lines: [{ catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: '3', location_id: 'l1', responsible_id: 'e1', received_on: '2026-09-15' }],
    })
  })
  it('W6 shows the external id fields on an opening form only, posts the pair and places a taken refusal', async () => {
    const masters = clientMock.post.getMockImplementation()!
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => {
      if (p === DOCS) throw refusal(409, 'external_ref_taken', { field: 'external_ref_id' })
      return masters(p, b)
    })
    renderStock(`${LIST}/new?kind=opening`, withPost)
    await form().findByRole('option', { name: 'Main store' })
    expect(form().getByLabelText(/External system/)).toBeInTheDocument()
    pick('Org unit', 'u1')
    pick(/External system/, 'erp')
    const row = screen.getAllByTestId('line-editor-row')[0]
    await within(row).findByRole('option', { name: 'Bolt M8' })
    await within(row).findByRole('option', { name: 'Shelf A' })
    await within(row).findByRole('option', { name: 'Aigul B.' })
    pick('Item', 'i1', row)
    pick('Quantity', '3', row)
    pick('Location', 'l1', row)
    pick('Responsible', 'e1', row)
    pick('Real receipt date', '2026-09-15', row)
    fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
    expect(await screen.findByText('Give both the external system and the external id, or neither.')).toBeInTheDocument()
    expect(clientMock.post.mock.calls.filter(([p]) => p === DOCS)).toHaveLength(0)
    pick(/External id/, 'OB-7')
    fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
    await waitFor(() => expect(clientMock.post.mock.calls.filter(([p]) => p === DOCS)).toHaveLength(1))
    expect(clientMock.post.mock.calls.find(([p]) => p === DOCS)?.[1]).toMatchObject({ external_ref_system: 'erp', external_ref_id: 'OB-7' })
    expect(await screen.findByText('This external reference is already used.')).toBeInTheDocument()
  })
  it('W6b a receipt form has no external id fields', async () => {
    renderStock(`${LIST}/new?kind=receipt`, withPost)
    await form().findByRole('option', { name: 'Main store' })
    expect(form().queryByLabelText(/External system/)).not.toBeInTheDocument()
  })
  it('sends nothing when the receipt date is missing', async () => {
    renderStock(`${LIST}/new?kind=opening`, withPost)
    await form().findByRole('option', { name: 'Main store' })
    pick('Org unit', 'u1')
    fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
    expect((await screen.findAllByText('This field is required.')).length).toBeGreaterThan(0)
    expect(clientMock.post.mock.calls.filter(([p]) => p === DOCS)).toHaveLength(0)
  })
})

describe('W7 view', () => {
  it('shows the external pair of an opening document and no rows without one', async () => {
    fakeDocument(clientMock, OPENING({ external_ref_system: 'erp', external_ref_id: 'OB-7' }))
    renderStock(`${LIST}/d1`, withPost)
    expect(await screen.findByText('OB-7')).toBeInTheDocument()
    expect(screen.getByText('External system')).toBeInTheDocument()
    cleanup()
    fakeDocument(clientMock, OPENING())
    renderStock(`${LIST}/d1`, withPost)
    await screen.findByText('Org unit')
    expect(screen.queryByText('External system')).not.toBeInTheDocument()
  })
})

describe('O4 check and issue', () => {
  it('Check all lines lists the reasons per line and writes nothing', async () => {
    fakeDocument(clientMock, OPENING())
    clientMock.post.mockImplementation(async (p: string) =>
      p === `${DOCS}/d1/check` ? { ok: false, lines: [{ line_no: 2, reasons: ['lot_required'] }] } : { items: [], next_cursor: null })
    renderStock(`${LIST}/d1`, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'Check all lines' }))
    const res = await screen.findByTestId('check-result')
    expect(res).toHaveTextContent(/Line 2: .+/)
    expect(clientMock.post).toHaveBeenCalledWith(`${DOCS}/d1/check`)
    expect(clientMock.put.mock.calls).toHaveLength(0)
  })
  it('an issue refusal names the line', async () => {
    fakeDocument(clientMock, OPENING())
    clientMock.post.mockRejectedValue(refusal(422, 'lot_required', { line_no: 3 }))
    renderStock(`${LIST}/d1`, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'Issue' }))
    const dlg = await screen.findByRole('dialog')
    fireEvent.click(within(dlg).getByRole('button', { name: 'Issue' }))
    await waitFor(() => expect(within(dlg).getByRole('alert').textContent).toMatch(/^Line 3:/))
  })
})

describe('O5 second administrator', () => {
  it('an issued opening points to the task inbox and says who may approve', async () => {
    fakeDocument(clientMock, OPENING({ state: 'issued', number: 'OB-1' }))
    renderStock(`${LIST}/d1`, withPost)
    expect(await screen.findByText(stockMessages.en['stock.doc.waiting.opening'])).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Open the task inbox' })).toBeInTheDocument()
    expect(screen.queryByLabelText('Event time')).not.toBeInTheDocument()
  })
})

describe('O6 opening words in en, ru, kk', () => {
  it.each(['en', 'ru', 'kk'] as const)('Movements shows the %s word, not the raw one', async (lang) => {
    useUiLocaleStore.getState().setLocaleTransient(lang)
    clientMock.get.mockResolvedValue({
      next_cursor: null,
      rows: [{ entry_id: 'en1', posting_seq: 17, cause: 'opening', reason_code: null, document_type: 'stock_opening', document_id: 'd1', event_time: '2026-11-04T18:00:00Z', legs: [] }],
    })
    renderStock(MOV)
    const word = stockMessages[lang]['stock.cause.opening']
    await screen.findAllByTestId('journal-row')
    expect(screen.getAllByText(word).length).toBeGreaterThanOrEqual(2)
    expect(screen.queryByText('opening')).not.toBeInTheDocument()
    expect(screen.queryByText('stock_opening')).not.toBeInTheDocument()
    expect(within(screen.getByLabelText(stockMessages[lang]['stock.filter.cause'])).getByRole('option', { name: word })).toBeInTheDocument()
    await act(async () => {})
  })
  it('the documents list shows the kind word', () => {
    for (const l of ['en', 'ru', 'kk'] as const) expect(stockMessages[l]['stock.doc.kind.opening']).toBeTruthy()
  })
})
