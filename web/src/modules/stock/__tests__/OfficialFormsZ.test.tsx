// @vitest-environment jsdom
/** W-1..W-4 — T-1417 (E5c): the official form buttons, Z-5 on a transfer and Z-3 on the balances screen. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { docEn } from '../documents/documentsMessages'
import { officialFormLang } from '../forms/officialForms'
import { stockMessages } from '../stockMessages'
import { BAL, DOCS, LIST, fakeDocument, fakeMasters, refusal, renderStock, stockDoc } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const CARD = '/api/v1/modules/stock/stock-card/print'
let downloads: string[] = []
const file = (cd: string | null) => ({ blob: new Blob(['x']), contentType: 'application/pdf', contentDisposition: cd })

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  useUiLocaleStore.getState().setLocaleTransient('en')
  downloads = []
  URL.createObjectURL = vi.fn(() => 'blob:x')
  URL.revokeObjectURL = vi.fn()
  vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (this: HTMLAnchorElement) {
    downloads.push(this.download)
  })
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('W-1 Z-5 buttons on a transfer', () => {
  it('two buttons; a click asks for form z5 in the chosen format, English prints ru', async () => {
    fakeDocument(clientMock, stockDoc({ kind: 'transfer', state: 'issued', number: 'TR-1' }))
    clientMock.getBlob.mockResolvedValue(file('attachment; filename="TR-1_Z-5.docx"'))
    renderStock(`${LIST}/d1`)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    await userEvent.click(await screen.findByTestId('form-z5-docx'))
    await waitFor(() => expect(downloads).toEqual(['TR-1_Z-5.docx']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'z5', format: 'docx', lang: 'ru' })
    await userEvent.click(screen.getByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-z5-pdf'))
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenLastCalledWith(`${DOCS}/d1/print`, { form: 'z5', format: 'pdf', lang: 'ru' }))
  })
  it('a Kazakh screen asks for kk', async () => {
    useUiLocaleStore.getState().setLocaleTransient('kk')
    fakeDocument(clientMock, stockDoc({ kind: 'transfer', state: 'posted', number: 'TR-2' }))
    clientMock.getBlob.mockResolvedValue(file(null))
    renderStock(`${LIST}/d1`)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    await userEvent.click(await screen.findByTestId('form-z5-pdf'))
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'z5', format: 'pdf', lang: 'kk' }))
    expect(officialFormLang('uz')).toBe('ru')
  })
})

describe('W-Z5HR-2 Z-5 on a return and a hand over (T-1959)', () => {
  it('a return in ru asks for z5 docx and saves under the number', async () => {
    fakeDocument(clientMock, stockDoc({ kind: 'return', state: 'issued', number: 'RT-1' }))
    clientMock.getBlob.mockResolvedValue(file(null))
    renderStock(`${LIST}/d1`)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    await userEvent.click(await screen.findByTestId('form-z5-docx'))
    await waitFor(() => expect(downloads).toEqual(['RT-1_Z-5.docx']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'z5', format: 'docx', lang: 'ru' })
  })
  it('a Kazakh screen: hand over item reads Қ-5 and asks for kk', async () => {
    useUiLocaleStore.getState().setLocaleTransient('kk')
    fakeDocument(clientMock, stockDoc({ kind: 'hand_over', state: 'posted', number: 'H-2' }))
    clientMock.getBlob.mockResolvedValue(file(null))
    renderStock(`${LIST}/d1`)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    expect(screen.getByTestId('form-z5-pdf')).toHaveTextContent('Қ-5 нысаны')
    await userEvent.click(screen.getByTestId('form-z5-pdf'))
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'z5', format: 'pdf', lang: 'kk' }))
  })
})

describe('W-2 no Z-5 elsewhere', () => {
  it.each([['transfer', 'draft'], ['hand_over', 'draft'], ['return', 'cancelled'], ['issue', 'issued'], ['receipt', 'posted']])('%s in %s', async (kind, state) => {
    fakeDocument(clientMock, stockDoc({ kind, state }))
    renderStock(`${LIST}/d1`)
    await screen.findByTestId('document-lines')
    await userEvent.click(screen.queryByTestId('official-form-menu') ?? document.body)
    expect(screen.queryByTestId('form-z5-pdf')).toBeNull()
    expect(screen.queryByTestId('form-z5-docx')).toBeNull()
  })
})

async function pick(label: string, optionText: string) {
  const select = await screen.findByLabelText(label)
  await waitFor(() => expect(within(select).getByRole('option', { name: optionText })).toBeInTheDocument())
  fireEvent.change(select, { target: { value: (within(select).getByRole('option', { name: optionText }) as HTMLOptionElement).value } })
}

describe('W-3 Z-3 buttons on the balances screen', () => {
  beforeEach(() => clientMock.get.mockResolvedValue({ ledger_seq: 1, next_cursor: null, rows: [] }))

  it('disabled until an item and a location are chosen, then the route gets both ids', async () => {
    clientMock.getBlob.mockResolvedValue(file('attachment; filename="stock-card_I1_Z-3.pdf"'))
    renderStock(BAL)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    expect(screen.getByTestId('form-z3-pdf')).toHaveAttribute('aria-disabled', 'true')
    expect(screen.getByTestId('form-z3-docx')).toHaveAttribute('aria-disabled', 'true')
    expect(screen.getByTestId('stock-card-hint')).toHaveTextContent('Choose an item and a place to print the stock card.')
    await userEvent.click(screen.getByTestId('form-z3-pdf'))
    expect(clientMock.getBlob).not.toHaveBeenCalled()
    await pick('Item', 'Bolt M8')
    await pick('Location', 'Shelf A')
    await waitFor(() => expect(screen.queryByTestId('stock-card-hint')).toBeNull())
    await waitFor(() => expect(screen.getByTestId('form-z3-docx')).not.toHaveAttribute('aria-disabled'))
    await userEvent.click(screen.getByTestId('form-z3-docx'))
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenCalledWith(CARD, { sku: 'i1', location: 'l1', format: 'docx', lang: 'ru' }))
    await pick('Lot', 'LOT-7')
    await userEvent.click(screen.getByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-z3-pdf'))
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenLastCalledWith(CARD, { sku: 'i1', location: 'l1', lot: 't1', format: 'pdf', lang: 'ru' }))
    await waitFor(() => expect(downloads).toContain('stock-card_I1_Z-3.pdf'))
  })
})

describe('W-4 refusals and catalogs', () => {
  beforeEach(() => clientMock.get.mockResolvedValue({ ledger_seq: 1, next_cursor: null, rows: [] }))

  it.each([[404, undefined, 'stock.balances.cardEmpty'], [422, 'card_too_long', 'stock.doc.print.reason.card_too_long']] as const)('%s %s', async (status, reason, id) => {
    clientMock.getBlob.mockRejectedValue(refusal(status, reason))
    renderStock(BAL)
    await screen.findByTestId('official-form-menu')
    await pick('Item', 'Bolt M8')
    await pick('Location', 'Shelf A')
    await waitFor(() => expect(screen.queryByTestId('stock-card-hint')).toBeNull())
    await userEvent.click(screen.getByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-z3-pdf'))
    const text = id.startsWith('stock.doc') ? docEn[id] : stockMessages.en[id]
    expect(await screen.findByText(text as string)).toBeInTheDocument()
  })

  it('every new key has a ru and a kk text that differs from English', () => {
    const keys = Object.keys(stockMessages.en).filter((k) => k.startsWith('stock.balances.card'))
    // The two standalone PDF/DOCX labels were removed in D8; the shared menu owns formats.
    expect(keys.length).toBe(2)
    for (const k of keys) {
      for (const l of ['ru', 'kk'] as const) {
        expect(stockMessages[l][k]?.trim(), `${l} ${k}`).toBeTruthy()
        expect(stockMessages[l][k]).not.toBe(stockMessages.en[k])
      }
    }
  })
})
