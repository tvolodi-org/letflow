// @vitest-environment jsdom
/** W2–W5 — T-1921: the "Official form" menu on the asset document view. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { documentsEn as docEn, documentsKk as docKk, documentsRu as docRu } from '../documents/documentsMessages'
import { DOCS, LIST, assetDoc, fakeDocument, fakeMasters, refusal, renderAssets, withAll } from './registerTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn(), getBlob: vi.fn() }))
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

describe('W2 menu and labels', () => {
  it.each([
    ['en', 'DA-1 form'],
    ['ru', 'Форма ДА-1'],
    ['kk', 'ҰМА-1 нысаны'],
  ] as const)('an issued commission shows the menu, its items are labelled in %s', async (loc, label) => {
    useUiLocaleStore.getState().setLocaleTransient(loc)
    fakeDocument(clientMock, assetDoc({ state: 'issued', number: 'ACM-1' }))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    expect(screen.getByTestId('form-da1-pdf')).toHaveTextContent(label)
    expect(screen.getByTestId('form-da1-docx')).toHaveTextContent(label)
    expect(screen.getByTestId('official-form-lang')).toBeInTheDocument()
  })
  it('a posted hand over shows the menu with DA-1 and DA-4 (four items)', async () => {
    fakeDocument(clientMock, assetDoc({ kind: 'handover', state: 'posted', number: 'AHO-1' }))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    for (const id of ['form-da1-pdf', 'form-da1-docx', 'form-da4-pdf', 'form-da4-docx']) expect(screen.getByTestId(id)).toBeInTheDocument()
  })
  it.each([
    ['en', 'DA-4 form'],
    ['ru', 'Форма ДА-4'],
    ['kk', 'ҰМА-4 нысаны'],
  ] as const)('W2b an issued change offers DA-4 only, labelled in %s', async (loc, label) => {
    useUiLocaleStore.getState().setLocaleTransient(loc)
    fakeDocument(clientMock, assetDoc({ kind: 'change', state: 'issued', number: 'ACH-1' }))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    expect(screen.getByTestId('form-da4-pdf')).toHaveTextContent(label)
    expect(screen.getByTestId('form-da4-docx')).toHaveTextContent(label)
    expect(screen.queryByTestId('form-da1-pdf')).toBeNull()
  })
  it.each([
    ['en', 'DA-3 form'],
    ['ru', 'Форма ДА-3'],
    ['kk', 'ҰМА-3 нысаны'],
  ] as const)('W2c an issued write-off offers DA-3 only, labelled in %s', async (loc, label) => {
    useUiLocaleStore.getState().setLocaleTransient(loc)
    fakeDocument(clientMock, assetDoc({ kind: 'writeoff', state: 'issued', number: 'AWO-1' }))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    expect(screen.getByTestId('form-da3-pdf')).toHaveTextContent(label)
    expect(screen.getByTestId('form-da3-docx')).toHaveTextContent(label)
    expect(screen.queryByTestId('form-da1-pdf')).toBeNull()
    expect(screen.queryByTestId('form-da4-pdf')).toBeNull()
  })
  it.each([
    ['change', 'draft'], ['writeoff', 'draft'], ['commission', 'draft'], ['opening', 'posted'], ['kind_change', 'issued'],
  ])('%s in %s has no menu', async (kind, state) => {
    fakeDocument(clientMock, assetDoc({ kind, state }))
    renderAssets(VIEW, withAll)
    await screen.findByTestId('document-lines')
    expect(screen.queryByTestId('official-form-menu')).toBeNull()
  })
  it('Escape closes the menu and returns focus to the trigger', async () => {
    fakeDocument(clientMock, assetDoc({ state: 'issued', number: 'ACM-1' }))
    renderAssets(VIEW, withAll)
    const trigger = await screen.findByTestId('official-form-menu')
    await userEvent.click(trigger)
    expect(screen.getByRole('menu')).toBeInTheDocument()
    await userEvent.keyboard('{Escape}')
    expect(screen.queryByRole('menu')).toBeNull()
    expect(trigger).toHaveFocus()
  })
})

describe('W3 download', () => {
  it('calls the print route with the form, format and the UI language and saves under the header name', async () => {
    fakeDocument(clientMock, assetDoc({ state: 'issued', number: 'ACM-1' }))
    clientMock.getBlob.mockResolvedValue(file('attachment; filename="ACM-1_DA-1.pdf"'))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-da1-pdf'))
    await waitFor(() => expect(downloads).toEqual(['ACM-1_DA-1.pdf']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'da1', format: 'pdf', lang: 'ru' })
  })
  it('the Kazakh UI asks for kk and the fallback name carries the suffix and extension', async () => {
    useUiLocaleStore.getState().setLocaleTransient('kk')
    fakeDocument(clientMock, assetDoc({ state: 'issued', number: 'ACM-1' }))
    clientMock.getBlob.mockResolvedValue(file(null))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-da1-docx'))
    await waitFor(() => expect(downloads).toEqual(['ACM-1_DA-1.docx']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'da1', format: 'docx', lang: 'kk' })
  })
})

describe('W3b DA-4 download', () => {
  it('picking DA-4 calls the print route with form da4 and saves under the header name', async () => {
    fakeDocument(clientMock, assetDoc({ kind: 'change', state: 'issued', number: 'ACH-1' }))
    clientMock.getBlob.mockResolvedValue(file('attachment; filename="ACH-1_DA-4.pdf"'))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-da4-pdf'))
    await waitFor(() => expect(downloads).toEqual(['ACH-1_DA-4.pdf']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'da4', format: 'pdf', lang: 'ru' })
  })
  it('without Content-Disposition the fallback name is ACH-1_DA-4.pdf', async () => {
    fakeDocument(clientMock, assetDoc({ kind: 'change', state: 'posted', number: 'ACH-1' }))
    clientMock.getBlob.mockResolvedValue(file(null))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-da4-pdf'))
    await waitFor(() => expect(downloads).toEqual(['ACH-1_DA-4.pdf']))
  })
})

describe('W3c DA-3 download', () => {
  it('picking DA-3 calls the print route with form da3 and the fallback name is AWO-1_DA-3.docx', async () => {
    fakeDocument(clientMock, assetDoc({ kind: 'writeoff', state: 'issued', number: 'AWO-1' }))
    clientMock.getBlob.mockResolvedValue(file(null))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-da3-docx'))
    await waitFor(() => expect(downloads).toEqual(['AWO-1_DA-3.docx']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { form: 'da3', format: 'docx', lang: 'ru' })
  })
})

describe('W4 refusals', () => {
  it('a 422 invalid_form shows the localized banner', async () => {
    fakeDocument(clientMock, assetDoc({ state: 'issued', number: 'ACM-1' }))
    clientMock.getBlob.mockRejectedValue(refusal(422, 'invalid_form'))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('official-form-menu'))
    await userEvent.click(screen.getByTestId('form-da1-pdf'))
    expect(await screen.findByText(docEn['assets.doc.print.reason.invalid_form']!)).toBeInTheDocument()
  })
})

describe('W5 catalogs', () => {
  it('every assets.doc.form* key and the new reasons exist in en, ru and kk', () => {
    const keys = Object.keys(docEn).filter((k) => k.startsWith('assets.doc.form') || /print\.reason\.invalid_(form|format)$/.test(k))
    expect(keys.length).toBe(11)
    for (const k of keys) {
      expect(docRu[k]?.trim(), k).toBeTruthy()
      expect(docKk[k]?.trim(), k).toBeTruthy()
    }
  })
})
