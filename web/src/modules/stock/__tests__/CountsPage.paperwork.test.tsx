// @vitest-environment jsdom
/** P1–P2 — GH 3761 / REQ-720 criterion 4: xlsx paperwork downloads through client.getBlob. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { countsEn } from '../counts/countsMessages'
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

describe('P1 downloads', () => {
  it('a button only for each issued document; the path per kind; the Content-Disposition name', async () => {
    fakeCounts(clientMock, { orders: [ISSUED] })
    clientMock.getBlob.mockResolvedValue({ blob: new Blob(['x']), contentType: 'x', contentDisposition: 'attachment; filename="CNT-0001-sheet.xlsx"' })
    renderCounts(`${LIST}/c1`)
    await screen.findByTestId('paperwork-order')
    expect(screen.getByTestId('paperwork-sheet')).toBeInTheDocument()
    expect(screen.queryByTestId('paperwork-differences')).toBeNull()
    await userEvent.click(screen.getByTestId('paperwork-sheet'))
    await waitFor(() => expect(downloads).toEqual(['CNT-0001-sheet.xlsx']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(`${BASE}/c1/paperwork/sheet`)
    await userEvent.click(screen.getByTestId('paperwork-order'))
    await waitFor(() => expect(clientMock.getBlob).toHaveBeenCalledWith(`${BASE}/c1/paperwork/order`))
  })
  it('falls back to a name built from the number when there is no header', async () => {
    fakeCounts(clientMock, { orders: [ISSUED] })
    clientMock.getBlob.mockResolvedValue({ blob: new Blob(['x']), contentType: 'x', contentDisposition: null })
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('paperwork-order'))
    await waitFor(() => expect(downloads).toEqual(['count-CNT-0001-order.xlsx']))
  })
})

describe('P2 refusal', () => {
  it('422 document_not_issued shows its message', async () => {
    fakeCounts(clientMock, { orders: [ISSUED] })
    clientMock.getBlob.mockRejectedValue(problem(422, 'document_not_issued'))
    renderCounts(`${LIST}/c1`)
    await userEvent.click(await screen.findByTestId('paperwork-order'))
    expect(await screen.findByText(countsEn['counts.reason.document_not_issued'])).toBeInTheDocument()
  })
})
