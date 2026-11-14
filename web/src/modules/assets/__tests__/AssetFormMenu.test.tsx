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
  it('a posted hand over shows the menu', async () => {
    fakeDocument(clientMock, assetDoc({ kind: 'handover', state: 'posted', number: 'AHO-1' }))
    renderAssets(VIEW, withAll)
    expect(await screen.findByTestId('official-form-menu')).toBeInTheDocument()
  })
  it.each([
    ['change', 'posted'], ['writeoff', 'issued'], ['commission', 'draft'], ['opening', 'posted'], ['kind_change', 'issued'],
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
    expect(keys.length).toBe(9)
    for (const k of keys) {
      expect(docRu[k]?.trim(), k).toBeTruthy()
      expect(docKk[k]?.trim(), k).toBeTruthy()
    }
  })
})
