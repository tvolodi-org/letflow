// @vitest-environment jsdom
/** P1–P5 — REQ-738: PDF print buttons beside the xlsx downloads on the count screen. Network mocked. */
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

const ISSUED = order({ status: 'counted', issued_at: '2026-11-09T08:00:00Z', sheet_document_id: 'd1' })
const file = (cd: string | null) => ({ blob: new Blob(['x']), contentType: 'application/pdf', contentDisposition: cd })

describe('P1 which print buttons show', () => {
  it('print shows exactly when the xlsx button shows', async () => {
    fakeCounts(clientMock, { orders: [ISSUED] })
    renderCounts(`${LIST}/c1`)
    await screen.findByTestId('print-order')
    expect(screen.getByTestId('print-sheet')).toBeInTheDocument()
    expect(screen.queryByTestId('print-differences')).toBeNull()
    expect(screen.queryByTestId('paperwork-differences')).toBeNull()
  })
})

describe('P2 download and language', () => {
  it.each([['en'], ['ru'], ['kk']] as const)('sends lang=%s and saves under the header name', async (l) => {
    useUiLocaleStore.getState().setLocaleTransient(l)
    fakeCounts(clientMock, { orders: [ISSUED] })
    clientMock.getBlob.mockResolvedValue(file('attachment; filename="CNT-0001-sheet.pdf"'))
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('print-sheet'))
    await waitFor(() => expect(downloads).toEqual(['CNT-0001-sheet.pdf']))
    expect(clientMock.getBlob).toHaveBeenCalledTimes(1)
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${BASE}/c1/print/sheet`, { lang: l })
  })
  it('falls back to a name built from the number', async () => {
    fakeCounts(clientMock, { orders: [ISSUED] })
    clientMock.getBlob.mockResolvedValue(file(null))
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('print-sheet'))
    await waitFor(() => expect(downloads).toEqual(['count-CNT-0001-sheet.pdf']))
  })
})

describe('P3 single flight', () => {
  it('a second click while the request runs sends nothing', async () => {
    fakeCounts(clientMock, { orders: [ISSUED] })
    let done: (v: ReturnType<typeof file>) => void = () => {}
    clientMock.getBlob.mockReturnValue(new Promise((res) => { done = res }))
    renderCounts(`${LIST}/c1`)
    const btn = await screen.findByTestId('print-order')
    await userEvent.click(btn)
    await userEvent.click(btn)
    await userEvent.click(screen.getByTestId('paperwork-order'))
    expect(clientMock.getBlob).toHaveBeenCalledTimes(1)
    done(file(null))
    await waitFor(() => expect(downloads).toHaveLength(1))
  })
})

describe('P4 refusals', () => {
  it.each(['document_not_issued', 'print_not_available', 'print_unsupported_character', 'invalid_lang'] as const)('422 %s shows its message', async (r) => {
    fakeCounts(clientMock, { orders: [ISSUED] })
    clientMock.getBlob.mockRejectedValue(problem(422, r))
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('print-order'))
    expect(await screen.findByText(countsEn[`counts.print.reason.${r}`])).toBeInTheDocument()
  })
  it('404 shows not found; 403 and 500 show the generic message', async () => {
    for (const [status, id] of [[404, 'counts.error.notFound'], [403, 'counts.error.generic'], [500, 'counts.error.generic']] as const) {
      fakeCounts(clientMock, { orders: [ISSUED] })
      clientMock.getBlob.mockRejectedValue(problem(status))
      renderCounts(`${LIST}/c1`)
      await userEvent.click(await screen.findByTestId('print-order'))
      expect(await screen.findByText(countsEn[id])).toBeInTheDocument()
      cleanup()
    }
  })
  it('the message follows the language (ru)', async () => {
    useUiLocaleStore.getState().setLocaleTransient('ru')
    fakeCounts(clientMock, { orders: [ISSUED] })
    clientMock.getBlob.mockRejectedValue(problem(422, 'invalid_lang'))
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('print-order'))
    expect(await screen.findByText(countsRu['counts.print.reason.invalid_lang'])).toBeInTheDocument()
  })
})

describe('P5 model and catalogs', () => {
  it('printReasonMessageId maps status and reason', () => {
    expect(printReasonMessageId(problem(422, 'print_not_available'))).toBe('counts.print.reason.print_not_available')
    expect(printReasonMessageId(problem(422, 'other'))).toBe('counts.error.generic')
    expect(printReasonMessageId(problem(404))).toBe('counts.error.notFound')
    expect(printReasonMessageId(problem(403))).toBe('counts.error.generic')
    expect(printReasonMessageId(null)).toBe('counts.error.generic')
  })
  it('new keys are non-empty and translated', () => {
    const keys = Object.keys(countsEn).filter((k) => k.startsWith('counts.print.'))
    expect(keys.length).toBe(7)
    for (const k of keys) {
      expect(countsRu[k]?.trim(), k).toBeTruthy()
      expect(countsKk[k]?.trim(), k).toBeTruthy()
      expect(countsRu[k]).not.toBe(countsEn[k])
      expect(countsKk[k]).not.toBe(countsEn[k])
    }
  })
})
