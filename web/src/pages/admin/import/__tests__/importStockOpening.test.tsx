// @vitest-environment jsdom
/** W1/W2/W3: GH T-1364 / REQ-727, the stock_opening_line import type on the Import data screen. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { getImportTypesFor, getInstalledImportTypes } from '@/modules/registry'
import { chooseFile, chooseType, clientMock, INSTALLED, ok, refused, renderPage, xlsxFile } from './importTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/hooks/useInstalledModules', async () => {
  const kit = await import('./importMocks')
  return { useInstalledModules: () => ({ data: kit.INSTALLED.value }) }
})
vi.mock('@/api/client', async (importOriginal) => {
  const kit = await import('./importMocks')
  return { ...(await importOriginal<object>()), client: kit.clientMock }
})

const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
const BASE = '/api/v1/entities/records/stock_opening_line'

beforeEach(() => {
  clientMock.postRaw.mockReset()
  clientMock.postBlob.mockReset()
  INSTALLED.value = [{ module_id: 'stock', version: '1' }]
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('W1 registry', () => {
  it('lists stock_opening_line with en, ru and kk labels only when stock is installed', () => {
    const on = getInstalledImportTypes([{ module_id: 'stock', version: '1' }])
    expect(on.map((t) => t.entityType)).toEqual(['stock_opening_line'])
    for (const l of ['en', 'ru', 'kk'] as const) expect(on[0].labels[l]).toBeTruthy()
    expect(getInstalledImportTypes([{ module_id: 'org', version: '1' }]).map((t) => t.entityType)).not.toContain('stock_opening_line')
  })
})

describe('W2 template', () => {
  it('is offered in the picker and downloads from the export route', async () => {
    const downloads: string[] = []
    URL.createObjectURL = vi.fn(() => 'blob:t')
    URL.revokeObjectURL = vi.fn()
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (this: HTMLAnchorElement) {
      downloads.push(this.download)
    })
    clientMock.postBlob.mockResolvedValue({ blob: new Blob(['x']), contentType: 'x' })
    renderPage()
    chooseType('stock_opening_line')
    fireEvent.click(screen.getByTestId('import-template'))
    await waitFor(() => expect(downloads).toEqual(['stock_opening_line-template.xlsx']))
    expect(clientMock.postBlob.mock.calls[0][0]).toBe(`${BASE}/export?format=xlsx`)
  })
})

describe('W3 dry run and confirm', () => {
  it('shows the counts and the texts of the REQ-727 reasons, then imports', async () => {
    const reasons = ['document_not_draft', 'org_unit_mismatch', 'lines_count', 'quantity_invalid', 'price_invalid', 'line_invalid']
    clientMock.postRaw.mockResolvedValueOnce({
      dry_run: true,
      results: [ok(2, 'created'), refused(3, 'reference_not_found', { header: 'catalog_item_id' }), ...reasons.map((r, i) => refused(4 + i, r))],
    })
    renderPage()
    chooseType('stock_opening_line')
    const file = xlsxFile('opening.xlsx')
    chooseFile(file)
    fireEvent.click(screen.getByTestId('import-check'))
    await screen.findByTestId('import-dry-run')
    expect(clientMock.postRaw).toHaveBeenCalledWith(`${BASE}/import?upsert_by=external_ref&dry_run=true`, file, XLSX)
    expect(screen.getByTestId('import-counts')).toHaveTextContent(/7\s*Refused/)
    expect(screen.getByText('The document is no longer a draft.')).toBeInTheDocument()
    expect(screen.getByText('A document holds at most 1000 lines.')).toBeInTheDocument()
    expect(screen.queryByText(/unknown reason/i)).not.toBeInTheDocument()
  })

  it('confirm posts the same file without dry_run after a clean check', async () => {
    clientMock.postRaw.mockResolvedValueOnce({ dry_run: true, results: [ok(2, 'created')] })
    clientMock.postRaw.mockResolvedValueOnce({ dry_run: false, results: [ok(2, 'created')] })
    renderPage()
    chooseType('stock_opening_line')
    const file = xlsxFile('opening.xlsx')
    chooseFile(file)
    fireEvent.click(screen.getByTestId('import-check'))
    await screen.findByTestId('import-dry-run')
    fireEvent.click(screen.getByTestId('import-confirm'))
    await waitFor(() => expect(clientMock.postRaw).toHaveBeenLastCalledWith(`${BASE}/import?upsert_by=external_ref&atomic=true`, file, XLSX))
  })
})

describe('T-1522 import types per permission', () => {
  const ALL = ['org', 'locations', 'catalog_items', 'stock'].map((m) => ({ module_id: m, version: '1' }))
  it('a holder of StockPost alone is offered stock_opening_line and nothing else', () => {
    expect(getImportTypesFor(ALL, (p) => p === 'StockPost').map((t) => t.entityType)).toEqual(['stock_opening_line'])
  })
  it('a holder of no module write permission is offered no type', () => {
    expect(getImportTypesFor(ALL, () => false)).toEqual([])
  })
})
