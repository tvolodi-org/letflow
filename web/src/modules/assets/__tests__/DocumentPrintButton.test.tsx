// @vitest-environment jsdom
/** W2–W4 — T-1915: the print button on the asset document view. Network mocked. */
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

describe('W2 button and labels', () => {
  it.each([
    ['en', 'Print (PDF)'],
    ['ru', 'Печать (PDF)'],
    ['kk', 'Басып шығару (PDF)'],
  ] as const)('an issued commission shows the button in %s', async (loc, label) => {
    useUiLocaleStore.getState().setLocaleTransient(loc)
    fakeDocument(clientMock, assetDoc({ state: 'issued', number: 'ACM-1' }))
    renderAssets(VIEW, withAll)
    expect(await screen.findByTestId('document-print')).toHaveTextContent(label)
  })
  it.each([
    ['commission', 'draft'], ['opening', 'posted'], ['kind_change', 'issued'], ['writeoff', 'cancelled'],
  ])('%s in %s has no button', async (kind, state) => {
    fakeDocument(clientMock, assetDoc({ kind, state }))
    renderAssets(VIEW, withAll)
    await screen.findByTestId('document-lines')
    expect(screen.queryByTestId('document-print')).toBeNull()
  })
  it('the catalogs carry the new keys in all three languages', () => {
    for (const k of Object.keys(docEn).filter((x) => x.startsWith('assets.doc.print'))) {
      expect(docRu[k]?.trim(), k).toBeTruthy()
      expect(docKk[k]?.trim(), k).toBeTruthy()
    }
  })
})

describe('W3 download', () => {
  it('calls the print route with the UI language and saves under the header name', async () => {
    fakeDocument(clientMock, assetDoc({ kind: 'handover', state: 'posted', number: 'AHO-1' }))
    clientMock.getBlob.mockResolvedValue(file('attachment; filename="AHO-1.pdf"'))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('document-print'))
    await waitFor(() => expect(downloads).toEqual(['AHO-1.pdf']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${DOCS}/d1/print`, { lang: 'en' })
  })
  it('two clicks in one tick send one request', async () => {
    fakeDocument(clientMock, assetDoc({ state: 'issued', number: 'ACM-1' }))
    let done: (v: ReturnType<typeof file>) => void = () => {}
    clientMock.getBlob.mockReturnValue(new Promise((res) => { done = res }))
    renderAssets(VIEW, withAll)
    const btn = await screen.findByTestId('document-print')
    await userEvent.click(btn)
    await userEvent.click(btn)
    expect(clientMock.getBlob).toHaveBeenCalledTimes(1)
    done(file(null))
    await waitFor(() => expect(downloads).toEqual(['ACM-1.pdf']))
  })
})

describe('W4 refusals', () => {
  beforeEach(() => fakeDocument(clientMock, assetDoc({ state: 'issued', number: 'ACM-1' })))
  it('a 422 document_not_issued shows the localized banner', async () => {
    clientMock.getBlob.mockRejectedValue(refusal(422, 'document_not_issued'))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('document-print'))
    expect(await screen.findByText(docEn['assets.doc.print.reason.document_not_issued']!)).toBeInTheDocument()
  })
  it('a 404 shows the not-found text', async () => {
    clientMock.getBlob.mockRejectedValue(refusal(404))
    renderAssets(VIEW, withAll)
    await userEvent.click(await screen.findByTestId('document-print'))
    expect(await screen.findByText(docEn['assets.doc.error.notFound']!)).toBeInTheDocument()
  })
})
