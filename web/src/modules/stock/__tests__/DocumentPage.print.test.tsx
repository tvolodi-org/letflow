// @vitest-environment jsdom
/** D1–D5 — REQ-738: the print button on the stock document view. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { docEn, docKk, docRu } from '../documents/documentsMessages'
import { DOC_KINDS, DOC_STATES, documentPrintable, printErrorMessageId } from '../documents/documentsModel'
import { formsForDocument } from '../forms/officialForms'
import { DOCS, LIST, fakeDocument, fakeMasters, refusal, renderStock, stockDoc } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const VIEW = `${LIST}/d1`
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

const KINDS = ['receipt', 'issue', 'write_off', 'transfer', 'hand_over', 'return']
const STATES = ['issued', 'posted', 'reversed']

describe('D1 button and download', () => {
  it.each(KINDS.flatMap((k) => STATES.map((s) => [k, s])))('%s in %s shows the button', async (kind, state) => {
    fakeDocument(clientMock, stockDoc({ kind, state, number: 'DOC-1' }))
    renderStock(VIEW)
    expect(await screen.findByTestId('document-print')).toBeInTheDocument()
  })
  it('click calls the print route with the UI language and saves under the header name', async () => {
    fakeDocument(clientMock, stockDoc({ kind: 'transfer', state: 'issued', number: 'TR-1' }))
    clientMock.getBlob.mockResolvedValue(file('attachment; filename="TR-1-ru.pdf"'))
    renderStock(VIEW)
    await userEvent.click(await screen.findByTestId('document-print'))
    await waitFor(() => expect(downloads).toEqual(['TR-1-ru.pdf']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { lang: 'en' })
  })
  it('falls back to <number>.pdf', async () => {
    fakeDocument(clientMock, stockDoc({ kind: 'return', state: 'posted', number: 'RT-7' }))
    clientMock.getBlob.mockResolvedValue(file(null))
    renderStock(VIEW)
    await userEvent.click(await screen.findByTestId('document-print'))
    await waitFor(() => expect(downloads).toEqual(['RT-7.pdf']))
  })
})

describe('D2 absent', () => {
  it.each([
    ['hand_over', 'draft'], ['hand_over', 'cancelled'], ['opening', 'issued'], ['opening', 'posted'], ['receipt', 'draft'], ['write_off', 'cancelled'],
  ])('%s in %s has no button', async (kind, state) => {
    fakeDocument(clientMock, stockDoc({ kind, state }))
    renderStock(VIEW)
    await screen.findByTestId('document-lines')
    expect(screen.queryByTestId('document-print')).toBeNull()
  })
})

describe('D3 language', () => {
  it.each([['ru'], ['kk']] as const)('sends lang=%s', async (l) => {
    useUiLocaleStore.getState().setLocaleTransient(l)
    fakeDocument(clientMock, stockDoc({ kind: 'hand_over', state: 'issued', number: 'H-1' }))
    clientMock.getBlob.mockResolvedValue(file(null))
    renderStock(VIEW)
    await userEvent.click(await screen.findByTestId('document-print'))
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { lang: l }))
  })
})

describe('D4 refusals', () => {
  beforeEach(() => fakeDocument(clientMock, stockDoc({ kind: 'transfer', state: 'issued', number: 'TR-1' })))
  it.each(['document_not_issued', 'print_not_available', 'print_unsupported_character', 'invalid_lang'] as const)('422 %s', async (r) => {
    clientMock.getBlob.mockRejectedValue(refusal(422, r))
    renderStock(VIEW)
    await userEvent.click(await screen.findByTestId('document-print'))
    expect(await screen.findByText(docEn[`stock.doc.print.reason.${r}`])).toBeInTheDocument()
  })
  it.each([[404, 'stock.doc.error.notFound'], [403, 'stock.doc.error.generic'], [500, 'stock.doc.error.generic']] as const)('%s', async (status, id) => {
    clientMock.getBlob.mockRejectedValue(refusal(status))
    renderStock(VIEW)
    await userEvent.click(await screen.findByTestId('document-print'))
    expect(await screen.findByText(docEn[id])).toBeInTheDocument()
  })
  it('a second click while the request runs sends nothing', async () => {
    let done: (v: ReturnType<typeof file>) => void = () => {}
    clientMock.getBlob.mockReturnValue(new Promise((res) => { done = res }))
    renderStock(VIEW)
    const btn = await screen.findByTestId('document-print')
    await userEvent.click(btn)
    await userEvent.click(btn)
    expect(clientMock.getBlob).toHaveBeenCalledTimes(1)
    done(file(null))
    await waitFor(() => expect(downloads).toHaveLength(1))
  })
})

describe('D5 model and catalogs', () => {
  it('documentPrintable and printErrorMessageId', () => {
    expect(documentPrintable({ kind: 'transfer', state: 'issued' })).toBe(true)
    expect(documentPrintable({ kind: 'transfer', state: 'draft' })).toBe(false)
    expect(documentPrintable({ kind: 'opening', state: 'posted' })).toBe(false)
    expect(printErrorMessageId(refusal(422, 'invalid_lang'))).toBe('stock.doc.print.reason.invalid_lang')
    expect(printErrorMessageId(refusal(422, 'unknown'))).toBe('stock.doc.error.generic')
    expect(printErrorMessageId(refusal(403))).toBe('stock.doc.error.generic')
    expect(printErrorMessageId(refusal(404))).toBe('stock.doc.error.notFound')
  })
  it('new keys are non-empty and translated', () => {
    const keys = Object.keys(docEn).filter((k) => k.startsWith('stock.doc.print'))
    // 7 from REQ-738 and T-1434, 2 Z-5 buttons and 1 reason (card_too_long) of T-1417, 3 reasons of T-1925
    expect(keys.length).toBe(13)
    for (const k of keys) {
      expect(docRu[k]?.trim(), k).toBeTruthy()
      expect(docKk[k]?.trim(), k).toBeTruthy()
      expect(docRu[k]).not.toBe(docEn[k])
      expect(docKk[k]).not.toBe(docEn[k])
    }
  })
})

// D6: one state policy for the act and every document form.
it.each(DOC_KINDS.flatMap(kind => DOC_STATES.map(state => [kind, state])))('D6 %s %s print policy', (kind, state) => {
  const active = ['issued', 'posted', 'reversed'].includes(state)
  expect(documentPrintable({ kind, state })).toBe(kind !== 'opening' && active)
  const form = ({ receipt: 'z1', issue: 'z2', transfer: 'z5', hand_over: 'z5', return: 'z5', write_off: 'z6' } as Record<string, string>)[kind]
  expect(formsForDocument({ kind, state })).toEqual(active && form ? [form] : [])
})
