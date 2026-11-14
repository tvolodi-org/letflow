// @vitest-environment jsdom
/** F1–F8 — T-1434: the "Official form" menu on issue documents (Z-2) and its catalogs. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { printErrorMessageId } from '../documents/documentsModel'
import { formEn, formKk, formRu } from '../forms/officialFormMessages'
import { formsForDocument, formsForOrder, officialFormLang } from '../forms/officialForms'
import { stockMessages } from '../stockMessages'
import { DOCS, LIST, fakeDocument, fakeMasters, refusal, renderStock, stockDoc } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

let downloads: string[] = []
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

const file = (cd: string | null) => ({ blob: new Blob(['x']), contentType: 'application/octet-stream', contentDisposition: cd })
const open = async (state: string, kind = 'issue') => {
  fakeDocument(clientMock, stockDoc({ id: 'd1', kind, state, number: state === 'draft' ? null : 'ISS-1' }))
  renderStock(`${LIST}/d1`)
  await screen.findByTestId('document-header')
}

describe('F1/F2 which documents show the menu', () => {
  it.each(['issued', 'posted', 'reversed'])('an issue document in state %s', async (state) => {
    await open(state)
    expect(screen.getByTestId('official-form-menu')).toBeInTheDocument()
  })
  it.each([
    ['draft', 'issue'],
    ['draft', 'receipt'],
    ['issued', 'hand_over'],
    ['issued', 'return'],
  ])('state %s, kind %s: none', async (state, kind) => {
    await open(state, kind)
    expect(screen.queryByTestId('official-form-menu')).toBeNull()
  })
  it('a transfer shows the one menu with Z-5 only (T-1441)', async () => {
    await open('issued', 'transfer')
    await userEvent.click(screen.getByTestId('official-form-menu'))
    expect(screen.getByTestId('form-z5-pdf')).toBeInTheDocument()
    expect(screen.queryByTestId('form-z2-pdf')).toBeNull()
    expect(screen.queryByTestId('document-print-z5-pdf')).toBeNull()
  })
  it('the registry rules', () => {
    expect(formsForDocument({ kind: 'issue', state: 'issued' })).toEqual(['z2'])
    expect(formsForOrder()).toEqual(['inv10', 'inv18'])
  })
})

// W1: receipt in issued/posted shows the Z-1 menu
describe('W1 receipt shows the Z-1 menu', () => {
  it.each(['issued', 'posted', 'reversed'])('a receipt in state %s shows form-z1 items', async (state) => {
    fakeDocument(clientMock, stockDoc({ id: 'd1', kind: 'receipt', state, number: 'RCP-1' }))
    renderStock(`${LIST}/d1`)
    await screen.findByTestId('document-header')
    expect(screen.getByTestId('official-form-menu')).toBeInTheDocument()
    await userEvent.click(screen.getByTestId('official-form-menu'))
    expect(screen.getByTestId('form-z1-pdf')).toBeInTheDocument()
    expect(screen.getByTestId('form-z1-docx')).toBeInTheDocument()
    expect(screen.queryByTestId('form-z2-pdf')).toBeNull()
    expect(screen.queryByTestId('form-z5-pdf')).toBeNull()
  })
})

// W2: Z-1 download calls the print route with form=z1 and uses _Z-1 suffix
describe('W2 Z-1 download', () => {
  it.each([
    ['docx', 'RCP-1_Z-1.docx'],
    ['pdf', 'RCP-1_Z-1.pdf'],
  ] as const)('Z-1 as %s calls the print route and saves the fallback name', async (format, name) => {
    fakeDocument(clientMock, stockDoc({ id: 'd1', kind: 'receipt', state: 'issued', number: 'RCP-1' }))
    renderStock(`${LIST}/d1`)
    await screen.findByTestId('document-header')
    clientMock.getBlob.mockResolvedValue(file(null))
    await userEvent.click(screen.getByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId(`form-z1-${format}`))
    await waitFor(() => expect(downloads).toEqual([name]))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'z1', format, lang: 'ru' })
  })
})

// W3: kk UI requests lang kk and shows Қ-1 нысаны
describe('W3 kk UI for Z-1', () => {
  it('kk UI requests lang kk for z1 and shows Қ-1 нысаны', async () => {
    useUiLocaleStore.getState().setLocaleTransient('kk')
    fakeDocument(clientMock, stockDoc({ id: 'd1', kind: 'receipt', state: 'issued', number: 'RCP-1' }))
    renderStock(`${LIST}/d1`)
    await screen.findByTestId('document-header')
    clientMock.getBlob.mockResolvedValue(file(null))
    await userEvent.click(screen.getByTestId('official-form-menu'))
    expect(screen.getByTestId('form-z1-pdf')).toHaveTextContent('Қ-1 нысаны')
    await userEvent.click(screen.getByTestId('form-z1-pdf'))
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenCalledTimes(1))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'z1', format: 'pdf', lang: 'kk' })
  })
})

// W4: formsForDocument catalog tests
describe('W4 formsForDocument', () => {
  it('receipt issued gives z1, receipt and issue share the issued states', () => {
    expect(formsForDocument({ kind: 'receipt', state: 'issued' })).toEqual(['z1'])
    expect(formsForDocument({ kind: 'receipt', state: 'posted' })).toEqual(['z1'])
    expect(formsForDocument({ kind: 'receipt', state: 'reversed' })).toEqual(['z1'])
    expect(formsForDocument({ kind: 'issue', state: 'issued' })).toEqual(['z2'])
    expect(formsForDocument({ kind: 'issue', state: 'posted' })).toEqual(['z2'])
  })
})

// W-Z6: the write-off screen offers Z-6 / Қ-6 (T-1914)
describe('W-Z6 write-off shows the Z-6 menu', () => {
  it('W-Z6-1 the registry gives z6 for issued, posted and reversed write-offs only', () => {
    for (const state of ['issued', 'posted', 'reversed']) expect(formsForDocument({ kind: 'write_off', state })).toEqual(['z6'])
    for (const state of ['draft', 'cancelled']) expect(formsForDocument({ kind: 'write_off', state })).toEqual([])
  })
  it('W-Z6-2 an issued write-off shows the menu with Z-6 only', async () => {
    await open('issued', 'write_off')
    await userEvent.click(screen.getByTestId('official-form-menu'))
    expect(screen.getByTestId('form-z6-pdf')).toBeInTheDocument()
    expect(screen.getByTestId('form-z6-docx')).toBeInTheDocument()
    for (const f of ['z1', 'z2', 'z5']) expect(screen.queryByTestId(`form-${f}-pdf`)).toBeNull()
  })
  it('W-Z6-3 Z-6 docx calls the print route with ru and saves the fallback name; kk UI asks kk', async () => {
    await open('issued', 'write_off')
    clientMock.getBlob.mockResolvedValue(file(null))
    await userEvent.click(screen.getByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-z6-docx'))
    await waitFor(() => expect(downloads).toEqual(['ISS-1_Z-6.docx']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'z6', format: 'docx', lang: 'ru' })
    cleanup()
    clientMock.getBlob.mockClear()
    useUiLocaleStore.getState().setLocaleTransient('kk')
    await open('issued', 'write_off')
    await userEvent.click(screen.getByTestId('official-form-menu'))
    expect(screen.getByTestId('form-z6-pdf')).toHaveTextContent('Қ-6 нысаны')
    await userEvent.click(screen.getByTestId('form-z6-pdf'))
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'z6', format: 'pdf', lang: 'kk' }))
  })
})

describe('F3/F4 download and language', () => {
  it.each([
    ['docx', 'ISS-1-Z-2.docx'],
    ['pdf', 'ISS-1-Z-2.pdf'],
  ] as const)('Z-2 as %s calls the print route and saves the fallback name', async (format, name) => {
    await open('posted')
    clientMock.getBlob.mockResolvedValue(file(null))
    await userEvent.click(screen.getByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId(`form-z2-${format}`))
    await waitFor(() => expect(downloads).toEqual([name]))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'z2', format, lang: 'ru' })
  })
  it('the header name wins', async () => {
    await open('issued')
    clientMock.getBlob.mockResolvedValue(file('attachment; filename="ISS-1_Z-2.docx"'))
    await userEvent.click(screen.getByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-z2-docx'))
    await waitFor(() => expect(downloads).toEqual(['ISS-1_Z-2.docx']))
  })
  it.each([
    ['en', 'ru'],
    ['ru', 'ru'],
    ['kk', 'kk'],
  ] as const)('UI %s requests lang %s', async (ui, lang) => {
    useUiLocaleStore.getState().setLocaleTransient(ui)
    await open('issued')
    clientMock.getBlob.mockResolvedValue(file(null))
    await userEvent.click(screen.getByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-z2-pdf'))
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenCalledTimes(1))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'z2', format: 'pdf', lang })
    expect(officialFormLang(ui)).toBe(lang)
  })
})

describe('F6 refusals', () => {
  it.each(['invalid_form', 'invalid_format', 'document_not_issued'])('422 %s shows its message', async (reason) => {
    await open('issued')
    clientMock.getBlob.mockRejectedValue(refusal(422, reason))
    await userEvent.click(screen.getByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-z2-docx'))
    expect(await screen.findByText(stockMessages.en[`stock.doc.print.reason.${reason}`])).toBeInTheDocument()
    expect(printErrorMessageId(refusal(422, reason))).toBe(`stock.doc.print.reason.${reason}`)
  })
  it('404 shows not found', async () => {
    await open('issued')
    clientMock.getBlob.mockRejectedValue(refusal(404, 'not_found'))
    await userEvent.click(screen.getByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-z2-docx'))
    expect(await screen.findByText(stockMessages.en['stock.doc.error.notFound'])).toBeInTheDocument()
  })
})

describe('F7 menu keyboard and mouse', () => {
  it('opens on click, Escape closes and focuses the trigger, outside click closes', async () => {
    await open('issued')
    const trigger = screen.getByTestId('official-form-menu')
    expect(trigger).toHaveAttribute('aria-expanded', 'false')
    await userEvent.click(trigger)
    expect(trigger).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByRole('menu')).toBeInTheDocument()
    expect(screen.getByTestId('official-form-lang')).toHaveTextContent('Russian')
    await userEvent.keyboard('{Escape}')
    expect(screen.queryByRole('menu')).toBeNull()
    expect(trigger).toHaveFocus()
    await userEvent.click(trigger)
    await userEvent.click(document.body)
    expect(screen.queryByRole('menu')).toBeNull()
  })
})

describe('F8 catalogs', () => {
  it('D8 obsolete separate stock-card button labels are removed', () => {
    for (const lang of ['en', 'ru', 'kk'] as const) {
      expect(stockMessages[lang]).not.toHaveProperty('stock.balances.cardPdf')
      expect(stockMessages[lang]).not.toHaveProperty('stock.balances.cardDocx')
    }
  })
  it('en, ru and kk have the same non-empty ids', () => {
    const ids = Object.keys(formEn).sort()
    expect(Object.keys(formRu).sort()).toEqual(ids)
    expect(Object.keys(formKk).sort()).toEqual(ids)
    for (const c of [formEn, formRu, formKk]) for (const id of ids) expect(c[id].trim(), id).not.toBe('')
    for (const l of ['en', 'ru', 'kk'] as const) for (const id of ids) expect(stockMessages[l][id], `${l} ${id}`).toBeTruthy()
  })
})

describe('T1/T2 menu stays inside the viewport (T-1441)', () => {
  const rectLeft = (left: number) =>
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockImplementation(function (this: HTMLElement) {
      return (this.getAttribute('role') === 'menu' ? { left, right: left + 200, top: 0, bottom: 0, width: 200, height: 0, x: left, y: 0 } : {}) as DOMRect
    })
  it('right-anchored by default, start-aligned when it would clip on the left, reset on close', async () => {
    await open('issued')
    const root = screen.getByTestId('official-form-menu').parentElement as HTMLElement
    const spy = rectLeft(300)
    await userEvent.click(screen.getByTestId('official-form-menu'))
    expect(root).not.toHaveClass('lf-formmenu--start')
    await userEvent.keyboard('{Escape}')
    spy.mockRestore()
    rectLeft(-40)
    await userEvent.click(screen.getByTestId('official-form-menu'))
    expect(root).toHaveClass('lf-formmenu--start')
    await userEvent.keyboard('{Escape}')
    expect(root).not.toHaveClass('lf-formmenu--start')
  })
})

it('W5 Kazakh Z-2 menu uses Қ-2', async () => {
  useUiLocaleStore.getState().setLocaleTransient('kk')
  await open('reversed')
  await userEvent.click(screen.getByTestId('official-form-menu'))
  expect(screen.getByTestId('form-z2-pdf')).toHaveTextContent('Қ-2 нысаны')
})
