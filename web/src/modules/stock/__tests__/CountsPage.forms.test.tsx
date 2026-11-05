// @vitest-environment jsdom
/** W1–W4 — T-1418: the official count form buttons (Inv-18 on the differences, Inv-10 on the sheet). Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { countsEn, countsKk, countsRu } from '../counts/countsMessages'
import { printReasonMessageId } from '../counts/countsModel'
import { BASE, LIST, fakeCounts, order, problem, renderCounts } from './countsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-counts' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), put: vi.fn(), patch: vi.fn(), get: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

let downloads: string[] = []
beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
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

const SHEET_ONLY = order({ status: 'counted', issued_at: '2026-11-09T08:00:00Z', sheet_document_id: 'd1' })
const BOTH = order({ status: 'counted', issued_at: '2026-11-09T08:00:00Z', sheet_document_id: 'd1', differences_document_id: 'd2' })
const file = (cd: string | null) => ({ blob: new Blob(['x']), contentType: 'application/octet-stream', contentDisposition: cd })

describe('W1 which form buttons show', () => {
  it('Inv-10 only with an issued sheet, Inv-18 only with an issued differences document', async () => {
    fakeCounts(clientMock, { orders: [SHEET_ONLY] })
    renderCounts(`${LIST}/c1`)
    await screen.findByTestId('print-order')
    expect(screen.getByTestId('form-inv10-docx')).toBeInTheDocument()
    expect(screen.getByTestId('form-inv10-pdf')).toBeInTheDocument()
    expect(screen.queryByTestId('form-inv18-docx')).toBeNull()
    expect(screen.queryByTestId('form-inv18-pdf')).toBeNull()
    cleanup()

    fakeCounts(clientMock, { orders: [BOTH] })
    renderCounts(`${LIST}/c1`)
    await screen.findByTestId('print-order')
    for (const id of ['form-inv10-docx', 'form-inv10-pdf', 'form-inv18-docx', 'form-inv18-pdf']) {
      expect(screen.getByTestId(id)).toBeInTheDocument()
    }
  })
})

describe('W2 download and language', () => {
  it.each([
    ['en', 'ru'],
    ['ru', 'ru'],
    ['kk', 'kk'],
  ] as const)('UI %s requests the form in %s and saves the .docx under the header name', async (ui, lang) => {
    useUiLocaleStore.getState().setLocaleTransient(ui)
    fakeCounts(clientMock, { orders: [BOTH] })
    clientMock.getBlob.mockResolvedValue(file('attachment; filename="CD-2026-0001_Inv-18.docx"'))
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('form-inv18-docx'))
    await waitFor(() => expect(downloads).toEqual(['CD-2026-0001_Inv-18.docx']))
    expect(clientMock.getBlob).toHaveBeenCalledTimes(1)
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${BASE}/c1/print/differences`, { form: 'inv18', format: 'docx', lang })
  })
  it('Inv-10 as PDF asks the sheet kind and falls back to a name built from the number', async () => {
    fakeCounts(clientMock, { orders: [SHEET_ONLY] })
    clientMock.getBlob.mockResolvedValue(file(null))
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('form-inv10-pdf'))
    await waitFor(() => expect(downloads).toEqual(['count-CNT-0001-inv10.pdf']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${BASE}/c1/print/sheet`, { form: 'inv10', format: 'pdf', lang: 'ru' })
  })
})

describe('W3 refusals', () => {
  it.each(['invalid_form', 'invalid_format', 'print_too_large', 'document_not_issued'] as const)('422 %s shows its message', async (r) => {
    fakeCounts(clientMock, { orders: [BOTH] })
    clientMock.getBlob.mockRejectedValue(problem(422, r))
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('form-inv18-pdf'))
    const id = r === 'document_not_issued' ? `counts.print.reason.${r}` : `counts.form.reason.${r}`
    expect(await screen.findByText(countsEn[id])).toBeInTheDocument()
  })
  it('the model maps the form reasons and the catalogs are complete', () => {
    expect(printReasonMessageId(problem(422, 'print_too_large'))).toBe('counts.form.reason.print_too_large')
    const keys = [
      ...['inv18', 'inv10'].flatMap((f) => [`counts.form.${f}.docx`, `counts.form.${f}.pdf`]),
      ...['invalid_form', 'invalid_format', 'print_too_large'].map((r) => `counts.form.reason.${r}`),
    ]
    for (const k of keys) {
      expect(countsEn[k]?.trim(), k).toBeTruthy()
      expect(countsRu[k]?.trim(), k).toBeTruthy()
      expect(countsKk[k]?.trim(), k).toBeTruthy()
    }
  })
})

describe('W4 single flight', () => {
  it('two clicks send one request', async () => {
    fakeCounts(clientMock, { orders: [BOTH] })
    let done: (v: ReturnType<typeof file>) => void = () => {}
    clientMock.getBlob.mockReturnValue(new Promise((res) => { done = res }))
    renderCounts(`${LIST}/c1`)
    const btn = await screen.findByTestId('form-inv18-docx')
    await userEvent.click(btn)
    await userEvent.click(btn)
    await userEvent.click(screen.getByTestId('form-inv10-pdf'))
    expect(clientMock.getBlob).toHaveBeenCalledTimes(1)
    done(file(null))
    await waitFor(() => expect(downloads).toHaveLength(1))
  })
})
