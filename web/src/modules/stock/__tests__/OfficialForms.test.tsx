// @vitest-environment jsdom
/** F1–F8 — T-1434: the "Official form" menu on issue documents (Z-2) and its catalogs. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { printErrorMessageId } from '../documents/documentsModel'
import { formEn, formKk, formRu } from '../forms/officialFormMessages'
import { formsForCount, formsForDocument, officialFormLang } from '../forms/officialForms'
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
  it.each(['issued', 'posted'])('an issue document in state %s', async (state) => {
    await open(state)
    expect(screen.getByTestId('official-form-menu')).toBeInTheDocument()
  })
  it.each([
    ['draft', 'issue'],
    ['reversed', 'issue'],
    ['issued', 'transfer'],
    ['posted', 'receipt'],
    ['issued', 'hand_over'],
    ['issued', 'return'],
  ])('state %s, kind %s: none', async (state, kind) => {
    await open(state, kind)
    expect(screen.queryByTestId('official-form-menu')).toBeNull()
  })
  it('the registry rules', () => {
    expect(formsForDocument({ kind: 'issue', state: 'issued' })).toEqual(['z2'])
    expect(formsForCount('sheet')).toEqual(['inv10'])
    expect(formsForCount('differences')).toEqual(['inv18'])
    expect(formsForCount('order')).toEqual([])
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
  it('en, ru and kk have the same non-empty ids', () => {
    const ids = Object.keys(formEn).sort()
    expect(Object.keys(formRu).sort()).toEqual(ids)
    expect(Object.keys(formKk).sort()).toEqual(ids)
    for (const c of [formEn, formRu, formKk]) for (const id of ids) expect(c[id].trim(), id).not.toBe('')
    for (const l of ['en', 'ru', 'kk'] as const) for (const id of ids) expect(stockMessages[l][id], `${l} ${id}`).toBeTruthy()
  })
})
