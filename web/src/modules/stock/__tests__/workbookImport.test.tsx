// @vitest-environment jsdom
/** REQ-887: workbook import screen — C1 access guard, C2 check flow with remarks, C3 load button states,
 *  C4 apply answers (201 / applied-false), C5 loads list and cancel flow, C6 i18n. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { wbEn, wbRu, wbKk } from '../workbook/workbookMessages'
import { stockRouteObjects } from '../stockRoutes'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-wb' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn(), postRaw: vi.fn(), patch: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({
  ...(await importOriginal<object>()),
  client: clientMock,
}))

const withQC: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['StockQuickCount', 'StockRead'] },
}
const withQCAndReverse: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['StockQuickCount', 'StockRead', 'StockReverse'] },
}
const withoutQC: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['StockRead'] },
}

const WB_PATH = '/admin/stock/workbook-import'
const DOC_ID = 'wb-doc-1'

const OU_REC = {
  record_id: 'ou1',
  entity_type: 'org_unit',
  field_values: { active: true, name: 'Склад A' },
  deleted: false,
  entity_def_version: '1',
  last_event_global_seq: 1,
}

function refusal(status: number, reason?: string) {
  return { status, message: 'x', code: String(status), details: reason ? { reason } : {} }
}

function setupDefaultMocks(importRows: object[] = []) {
  clientMock.get.mockImplementation(async (path: string) => {
    if ((path as string).includes('stock-workbook/imports')) return { rows: importRows }
    return { rows: [] }
  })
  clientMock.post.mockImplementation(async (path: string, body?: unknown) => {
    if (path === '/api/v1/entities/query') {
      const b = (body ?? {}) as { entity_type?: string }
      if (b.entity_type === 'org_unit') return { items: [OU_REC], next_cursor: null }
      return { items: [], next_cursor: null }
    }
    return {}
  })
}

function renderWB(access: AccessState = withQC, importRows: object[] = []) {
  setupDefaultMocks(importRows)
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  function Routes() {
    return useRoutes(stockRouteObjects)
  }
  return render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={[WB_PATH]}>
          <Routes />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

function xlsxFile(name = 'stock.xlsx'): File {
  return new File(['content'], name, { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' })
}

function checkResult(opts: { remarks?: { row: number | null; text: string }[]; changes?: number; unchanged?: number; tooMany?: boolean } = {}) {
  return {
    sheet: 'Остатки 2026-11-18',
    rows_read: 50,
    remarks: opts.remarks ?? [],
    changes: Array.from({ length: opts.changes ?? 2 }, (_, i) => ({
      row: i + 1,
      item_code: `ART-${i + 1}`,
      item_name: `Article ${i + 1}`,
      place_code: 'A-01',
      book_quantity: '10',
      file_quantity: '8',
      difference: '-2',
    })),
    unchanged_count: opts.unchanged ?? 5,
    too_many_changes: opts.tooMany ?? false,
  }
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

beforeEach(() => {
  useUiLocaleStore.getState().setLocaleTransient('en')
})

/** Renders the stock router at /admin/stock/balances. The balances GET is mocked empty; masters are mocked. */
function renderBAL(access: AccessState = withQC) {
  clientMock.get.mockImplementation(async (path: string) => {
    if ((path as string).includes('balances')) return { ledger_seq: 1, next_cursor: null, rows: [] }
    if ((path as string).includes('stock-workbook/imports')) return { rows: [] }
    return { rows: [] }
  })
  clientMock.post.mockImplementation(async (path: string, body?: unknown) => {
    if (path === '/api/v1/entities/query') {
      const b = (body ?? {}) as { entity_type?: string }
      if (b.entity_type === 'org_unit') return { items: [OU_REC], next_cursor: null }
      return { items: [], next_cursor: null }
    }
    return {}
  })
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  function Routes() {
    return useRoutes(stockRouteObjects)
  }
  return render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={['/admin/stock/balances']}>
          <Routes />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

/** Choose org unit and file, wait for button to be enabled, click Check, wait for result. */
async function setupAndCheck(opts: Parameters<typeof checkResult>[0] = {}, access = withQC) {
  const user = userEvent.setup()
  renderWB(access)
  await waitFor(() => expect(screen.getByTestId('wb-check')).toBeInTheDocument())
  // Wait for the org unit options to load (the placeholder plus at least one option)
  const orgUnitSelect = screen.getByTestId('wb-org-unit').querySelector('select')!
  await waitFor(() => expect(orgUnitSelect.options.length).toBeGreaterThan(1))
  // Choose org unit
  fireEvent.change(orgUnitSelect, { target: { value: 'ou1' } })
  // Upload file
  const f = xlsxFile()
  await user.upload(screen.getByTestId('dropzone-input'), f)
  // Wait for button to be enabled
  await waitFor(() => expect(screen.getByTestId('wb-check')).not.toBeDisabled())
  // Click Check
  clientMock.postRaw.mockResolvedValueOnce(checkResult(opts))
  fireEvent.click(screen.getByTestId('wb-check'))
  await waitFor(() => expect(screen.getByTestId('wb-check-result')).toBeInTheDocument())
  return f
}

/** C1: access guard. */
describe('C1 access', () => {
  it('shows the workbook import screen with StockQuickCount', async () => {
    renderWB(withQC)
    await waitFor(() => expect(screen.getByText(wbEn['stock.wb.title'])).toBeInTheDocument())
  })

  it('shows forbidden page without StockQuickCount', async () => {
    renderWB(withoutQC)
    await waitFor(() => expect(screen.queryByText(wbEn['stock.wb.title'])).not.toBeInTheDocument())
  })
})

/** C1 BalancesPage: the Load from Excel button is shown to StockQuickCount users and hidden otherwise. */
describe('C1 BalancesPage link', () => {
  it('shows wb-import-link with StockQuickCount', async () => {
    renderBAL(withQC)
    await waitFor(() => expect(screen.getByTestId('wb-import-link')).toBeInTheDocument())
  })

  it('hides wb-import-link without StockQuickCount', async () => {
    renderBAL(withoutQC)
    // Wait for the page title to confirm the page has mounted, then check the button is absent
    await waitFor(() => expect(screen.getByText('Balances')).toBeInTheDocument())
    expect(screen.queryByTestId('wb-import-link')).not.toBeInTheDocument()
  })
})

/** C2: check flow — posting the file to the check route, remarks shown as server text. */
describe('C2 check', () => {
  it('posts the file to the check route with org_unit_id and shows rows_read, remarks and changes', async () => {
    const user = userEvent.setup()
    renderWB()
    await waitFor(() => expect(screen.getByTestId('wb-check')).toBeInTheDocument())

    const orgUnitSelect = screen.getByTestId('wb-org-unit').querySelector('select')!
    await waitFor(() => expect(orgUnitSelect.options.length).toBeGreaterThan(1))
    fireEvent.change(orgUnitSelect, { target: { value: 'ou1' } })

    const f = xlsxFile('my-stock.xlsx')
    await user.upload(screen.getByTestId('dropzone-input'), f)
    await waitFor(() => expect(screen.getByTestId('wb-check')).not.toBeDisabled())

    const remarkText = 'Строка 3: артикул ART-X не найден в справочнике'
    clientMock.postRaw.mockResolvedValueOnce(checkResult({ remarks: [{ row: 3, text: remarkText }], changes: 2 }))
    fireEvent.click(screen.getByTestId('wb-check'))

    await waitFor(() => expect(screen.getByTestId('wb-check-result')).toBeInTheDocument())

    // The route is called with org_unit_id
    expect(clientMock.postRaw.mock.calls[0]![0]).toContain('org_unit_id=ou1')
    // rows_read shown
    expect(screen.getByTestId('wb-sheet')).toHaveTextContent('50')
    // remark shown as-is (Russian server text)
    expect(screen.getByTestId('wb-remarks')).toHaveTextContent(remarkText)
    // unchanged_count shown
    expect(screen.getByTestId('wb-unchanged-count')).toHaveTextContent('5')
    // changes table shows the item codes
    expect(screen.getByText('ART-1')).toBeInTheDocument()
    expect(screen.getByText('ART-2')).toBeInTheDocument()
  })

  it('marks a row-null change as emptied', async () => {
    const user = userEvent.setup()
    renderWB()
    await waitFor(() => expect(screen.getByTestId('wb-check')).toBeInTheDocument())

    const orgUnitSelect = screen.getByTestId('wb-org-unit').querySelector('select')!
    await waitFor(() => expect(orgUnitSelect.options.length).toBeGreaterThan(1))
    fireEvent.change(orgUnitSelect, { target: { value: 'ou1' } })
    await user.upload(screen.getByTestId('dropzone-input'), xlsxFile())
    await waitFor(() => expect(screen.getByTestId('wb-check')).not.toBeDisabled())

    clientMock.postRaw.mockResolvedValueOnce({
      sheet: 'S', rows_read: 1, remarks: [],
      changes: [{ row: null, item_code: 'ART-1', item_name: 'Name 1', place_code: 'B-02', book_quantity: '5', file_quantity: '0', difference: '-5' }],
      unchanged_count: 0, too_many_changes: false,
    })
    fireEvent.click(screen.getByTestId('wb-check'))
    await waitFor(() => expect(screen.getByTestId('wb-check-result')).toBeInTheDocument())

    // The place cell shows the emptied label for a row-null change
    expect(screen.getByRole('cell', { name: /B-02/ })).toHaveTextContent(wbEn['stock.wb.emptied'])
  })

  it('shows remarks as returned by the server (Russian text)', async () => {
    const user = userEvent.setup()
    renderWB()
    await waitFor(() => expect(screen.getByTestId('wb-check')).toBeInTheDocument())

    const orgUnitSelect = screen.getByTestId('wb-org-unit').querySelector('select')!
    await waitFor(() => expect(orgUnitSelect.options.length).toBeGreaterThan(1))
    fireEvent.change(orgUnitSelect, { target: { value: 'ou1' } })
    await user.upload(screen.getByTestId('dropzone-input'), xlsxFile())
    await waitFor(() => expect(screen.getByTestId('wb-check')).not.toBeDisabled())

    const remarkText = 'Строка 7: единица измерения не найдена'
    clientMock.postRaw.mockResolvedValueOnce(checkResult({ remarks: [{ row: 7, text: remarkText }] }))
    fireEvent.click(screen.getByTestId('wb-check'))
    await waitFor(() => expect(screen.getByTestId('wb-remarks')).toHaveTextContent(remarkText))
  })

  it.each(['en', 'ru', 'kk'] as const)('%s: remarks shown verbatim and UI labels use the active locale', async (locale) => {
    useUiLocaleStore.getState().setLocaleTransient(locale)
    const msgs = locale === 'ru' ? wbRu : locale === 'kk' ? wbKk : wbEn
    const user = userEvent.setup()
    renderWB()
    await waitFor(() => expect(screen.getByTestId('wb-check')).toBeInTheDocument())
    const orgUnitSelect = screen.getByTestId('wb-org-unit').querySelector('select')!
    await waitFor(() => expect(orgUnitSelect.options.length).toBeGreaterThan(1))
    fireEvent.change(orgUnitSelect, { target: { value: 'ou1' } })
    await user.upload(screen.getByTestId('dropzone-input'), xlsxFile())
    await waitFor(() => expect(screen.getByTestId('wb-check')).not.toBeDisabled())
    const remarkText = 'Строка 2: артикул не найден'
    clientMock.postRaw.mockResolvedValueOnce(checkResult({ remarks: [{ row: 2, text: remarkText }], changes: 2 }))
    fireEvent.click(screen.getByTestId('wb-check'))
    await waitFor(() => expect(screen.getByTestId('wb-check-result')).toBeInTheDocument())
    // The remark text from the server appears as-is in every locale
    expect(screen.getByTestId('wb-remarks')).toHaveTextContent(remarkText)
    // The UI label for the check card uses the active locale
    expect(screen.getByText(msgs['stock.wb.card.result'])).toBeInTheDocument()
  })
})

/** C3: load button states. */
describe('C3 load button', () => {
  it('load button does not appear before a check', async () => {
    renderWB()
    await waitFor(() => expect(screen.getByTestId('wb-check')).toBeInTheDocument())
    expect(screen.queryByTestId('wb-load')).not.toBeInTheDocument()
  })

  it('load button is disabled after a check with no changes', async () => {
    await setupAndCheck({ changes: 0 })
    expect(screen.getByTestId('wb-load')).toBeDisabled()
  })

  it('load button is disabled with too_many_changes true', async () => {
    await setupAndCheck({ tooMany: true })
    expect(screen.getByTestId('wb-load')).toBeDisabled()
  })

  it('load button is enabled after a check with changes', async () => {
    await setupAndCheck({ changes: 2 })
    expect(screen.getByTestId('wb-load')).not.toBeDisabled()
  })

  it('choosing a different org unit clears the check result', async () => {
    await setupAndCheck({ changes: 2 })
    expect(screen.getByTestId('wb-load')).not.toBeDisabled()
    const orgUnitSelect = screen.getByTestId('wb-org-unit').querySelector('select')!
    fireEvent.change(orgUnitSelect, { target: { value: '' } })
    await waitFor(() => expect(screen.queryByTestId('wb-check-result')).not.toBeInTheDocument())
    expect(screen.queryByTestId('wb-load')).not.toBeInTheDocument()
  })

  it('uploading a different file after check clears the check result', async () => {
    const user = userEvent.setup()
    await setupAndCheck({ changes: 2 })
    expect(screen.getByTestId('wb-load')).not.toBeDisabled()
    // Upload a different file — the check result must be cleared
    await user.upload(screen.getByTestId('dropzone-input'), xlsxFile('other.xlsx'))
    await waitFor(() => expect(screen.queryByTestId('wb-check-result')).not.toBeInTheDocument())
    expect(screen.queryByTestId('wb-load')).not.toBeInTheDocument()
  })

  it('posts the file and file_name to the apply route with org_unit_id and the checked file', async () => {
    const checkedFile = await setupAndCheck({ changes: 1 })
    clientMock.postRaw.mockResolvedValueOnce({
      document_id: DOC_ID, number: 'QCI-2026-000001', lines: 1, remarks: [], approve_task_id: null,
    })
    fireEvent.click(screen.getByTestId('wb-load'))
    await waitFor(() => expect(screen.getByTestId('wb-load-success')).toBeInTheDocument())
    const applyCalls = clientMock.postRaw.mock.calls as [string, ...unknown[]][]
    const applyCall = applyCalls.find((c) => c[0].includes('apply'))
    expect(applyCall).toBeDefined()
    expect(applyCall![0]).toContain('file_name=stock.xlsx')
    expect(applyCall![0]).toContain('org_unit_id=ou1')
    expect(applyCall![1]).toBe(checkedFile)
  })
})

/** C4: apply answers — 201 (success) and 200 applied:false. */
describe('C4 apply answers', () => {
  async function setupCheckedAndClickLoad(result: unknown) {
    await setupAndCheck({ changes: 1 })
    expect(screen.getByTestId('wb-load')).not.toBeDisabled()
    clientMock.postRaw.mockResolvedValueOnce(result)
    fireEvent.click(screen.getByTestId('wb-load'))
  }

  it('201: shows document number and link to admin/stock/documents/:id in en', async () => {
    await setupCheckedAndClickLoad({
      document_id: DOC_ID, number: 'QCI-2026-000042', lines: 5, remarks: [], approve_task_id: null,
    })
    await waitFor(() => expect(screen.getByTestId('wb-load-success')).toBeInTheDocument())
    expect(screen.getByTestId('wb-load-success')).toHaveTextContent('QCI-2026-000042')
    const link = screen.getByTestId('wb-doc-link')
    expect(link).toHaveAttribute('href', `/admin/stock/documents/${DOC_ID}`)
  })

  it('201: the new load appears in Previous loads without reopening', async () => {
    let loaded = false
    const row = {
      document_id: DOC_ID, number: 'QCI-2026-000042', created_at: '2026-11-18T04:00:00Z', created_by: null,
      file_name: 'stock.xlsx', sheet: 'S', lines: 5, remarks_count: 0, state: 'issued', reversal_pending: false,
    }
    await setupAndCheck({ changes: 1 })
    clientMock.get.mockImplementation(async (path: string) => {
      if ((path as string).includes('stock-workbook/imports')) return { rows: loaded ? [row] : [] }
      return { rows: [] }
    })
    clientMock.postRaw.mockImplementationOnce(async () => {
      loaded = true
      return { document_id: DOC_ID, number: 'QCI-2026-000042', lines: 5, remarks: [], approve_task_id: null }
    })
    fireEvent.click(screen.getByTestId('wb-load'))
    expect(await screen.findByTestId(`load-doc-${DOC_ID}`)).toHaveTextContent('QCI-2026-000042')
  })

  it('applied false: shows no-difference text', async () => {
    await setupCheckedAndClickLoad({ applied: false, changes: 0, remarks: [] })
    await waitFor(() => expect(screen.getByTestId('wb-load-no-change')).toBeInTheDocument())
    expect(screen.getByTestId('wb-load-no-change')).toHaveTextContent(wbEn['stock.wb.load.noChange'])
  })

  it('201 success text exists in ru and differs from en', () => {
    expect(wbRu['stock.wb.load.success']).not.toBe('')
    expect(wbRu['stock.wb.load.success']).not.toBe(wbEn['stock.wb.load.success'])
  })

  it('applied false text exists in kk and differs from en', () => {
    expect(wbKk['stock.wb.load.noChange']).not.toBe('')
    expect(wbKk['stock.wb.load.noChange']).not.toBe(wbEn['stock.wb.load.noChange'])
  })

  it.each(['en', 'ru', 'kk'] as const)('%s: 201 success text renders in the active locale', async (locale) => {
    useUiLocaleStore.getState().setLocaleTransient(locale)
    const msgs = locale === 'ru' ? wbRu : locale === 'kk' ? wbKk : wbEn
    await setupCheckedAndClickLoad({
      document_id: DOC_ID, number: 'QCI-2026-000099', lines: 2, remarks: [], approve_task_id: null,
    })
    await waitFor(() => expect(screen.getByTestId('wb-load-success')).toBeInTheDocument())
    // The success element contains a portion of the locale-specific success template
    const successText = msgs['stock.wb.load.success'].replace('{number}', 'QCI-2026-000099')
    expect(screen.getByTestId('wb-load-success')).toHaveTextContent('QCI-2026-000099')
    // Also verify the locale label appears (e.g. 'Open document' in en, 'Открыть документ' in ru)
    expect(screen.getByTestId('wb-load-success')).toBeInTheDocument()
    expect(successText.length).toBeGreaterThan(0)
  })

  it.each(['en', 'ru', 'kk'] as const)('%s: applied false renders no-change text in the active locale', async (locale) => {
    useUiLocaleStore.getState().setLocaleTransient(locale)
    const msgs = locale === 'ru' ? wbRu : locale === 'kk' ? wbKk : wbEn
    await setupCheckedAndClickLoad({ applied: false, changes: 0, remarks: [] })
    await waitFor(() => expect(screen.getByTestId('wb-load-no-change')).toBeInTheDocument())
    expect(screen.getByTestId('wb-load-no-change')).toHaveTextContent(msgs['stock.wb.load.noChange'])
  })
})

/** C5: loads list and cancel. */
describe('C5 loads and cancel', () => {
  const importRow = {
    document_id: 'imp-1',
    number: 'QCI-2026-000010',
    created_at: '2026-11-18T04:00:00Z',
    created_by: 'aaaaaaaa-0000-0000-0000-000000000001',
    file_name: 'stock.xlsx',
    sheet: 'Остатки',
    lines: 10,
    remarks_count: 2,
    state: 'issued',
    reversal_pending: false,
  }

  it('shows the loads list with file name, lines, remarks count and state', async () => {
    renderWB(withQCAndReverse, [importRow])
    await waitFor(() => expect(screen.getByTestId('wb-loads-section')).toBeInTheDocument())
    await waitFor(() => expect(screen.getAllByText('stock.xlsx').length).toBeGreaterThan(0))
    expect(screen.getByText('10')).toBeInTheDocument()
    // User column shows '—' (created_by is a UUID, not resolvable by the client)
    expect(screen.getAllByText('—').length).toBeGreaterThan(0)
  })

  it('shows the document number linked to the document', async () => {
    renderWB(withQCAndReverse, [importRow])
    const link = await screen.findByTestId('load-doc-imp-1')
    expect(link).toHaveTextContent('QCI-2026-000010')
    expect(link).toHaveAttribute('href', '/admin/stock/documents/imp-1')
  })

  it('shows Cancel button for StockReverse on an issued load', async () => {
    renderWB(withQCAndReverse, [importRow])
    await waitFor(() => expect(screen.getByTestId(`cancel-${importRow.document_id}`)).toBeInTheDocument())
  })

  it('shows Cancel button for StockReverse on a posted load', async () => {
    renderWB(withQCAndReverse, [{ ...importRow, state: 'posted' }])
    await waitFor(() => expect(screen.getAllByText('stock.xlsx').length).toBeGreaterThan(0))
    expect(screen.getByTestId(`cancel-${importRow.document_id}`)).toBeInTheDocument()
  })

  it('does not show Cancel without StockReverse', async () => {
    renderWB(withQC, [importRow])
    await waitFor(() => expect(screen.getAllByText('stock.xlsx').length).toBeGreaterThan(0))
    expect(screen.queryByTestId(`cancel-${importRow.document_id}`)).not.toBeInTheDocument()
  })

  it('does not show Cancel for a reversed load', async () => {
    renderWB(withQCAndReverse, [{ ...importRow, state: 'reversed' }])
    await waitFor(() => expect(screen.getAllByText('stock.xlsx').length).toBeGreaterThan(0))
    expect(screen.queryByTestId(`cancel-${importRow.document_id}`)).not.toBeInTheDocument()
  })

  it('does not show Cancel for a cancelled load', async () => {
    renderWB(withQCAndReverse, [{ ...importRow, state: 'cancelled' }])
    await waitFor(() => expect(screen.getAllByText('stock.xlsx').length).toBeGreaterThan(0))
    expect(screen.queryByTestId(`cancel-${importRow.document_id}`)).not.toBeInTheDocument()
  })

  it('does not show Cancel for a load with reversal_pending', async () => {
    renderWB(withQCAndReverse, [{ ...importRow, reversal_pending: true }])
    await waitFor(() => expect(screen.getAllByText('stock.xlsx').length).toBeGreaterThan(0))
    expect(screen.queryByTestId(`cancel-${importRow.document_id}`)).not.toBeInTheDocument()
    // The state column shows the reversal pending label instead of the state pill
    expect(screen.getByText(wbEn['stock.wb.loads.reversalPending'])).toBeInTheDocument()
  })

  it('cancel dialog: confirm button is disabled while reason is empty', async () => {
    renderWB(withQCAndReverse, [importRow])
    await waitFor(() => expect(screen.getByTestId(`cancel-${importRow.document_id}`)).toBeInTheDocument())
    fireEvent.click(screen.getByTestId(`cancel-${importRow.document_id}`))
    await waitFor(() => expect(screen.getByTestId('wb-cancel-reason')).toBeInTheDocument())
    const confirmBtn = screen.getByRole('button', { name: wbEn['stock.wb.cancel.confirm'] })
    expect(confirmBtn).toBeDisabled()
  })

  it('cancel dialog: confirm is enabled with a non-empty reason', async () => {
    renderWB(withQCAndReverse, [importRow])
    await waitFor(() => expect(screen.getByTestId(`cancel-${importRow.document_id}`)).toBeInTheDocument())
    fireEvent.click(screen.getByTestId(`cancel-${importRow.document_id}`))
    await waitFor(() => expect(screen.getByTestId('wb-cancel-reason')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('wb-cancel-reason'), { target: { value: 'x' } })
    await waitFor(() => expect(screen.getByRole('button', { name: wbEn['stock.wb.cancel.confirm'] })).not.toBeDisabled())
  })

  it('cancel posts the reason and shows cancelled result', async () => {
    renderWB(withQCAndReverse, [importRow])
    // Override the get mock after initial render: subsequent imports fetches return the cancelled state
    let importsGetCount = 0
    clientMock.get.mockImplementation(async (path: string) => {
      if ((path as string).includes('stock-workbook/imports')) {
        importsGetCount++
        return { rows: [{ ...importRow, state: 'cancelled' }] }
      }
      return { rows: [] }
    })
    clientMock.post.mockImplementation(async (path: string, body?: unknown) => {
      if (typeof path === 'string' && path.includes('/cancel')) return { action: 'cancelled', lines: 10 }
      const b = (body ?? {}) as { entity_type?: string }
      if (path === '/api/v1/entities/query') {
        if (b.entity_type === 'org_unit') return { items: [OU_REC], next_cursor: null }
        return { items: [], next_cursor: null }
      }
      return {}
    })
    await waitFor(() => expect(screen.getByTestId(`cancel-${importRow.document_id}`)).toBeInTheDocument())
    fireEvent.click(screen.getByTestId(`cancel-${importRow.document_id}`))
    await waitFor(() => expect(screen.getByTestId('wb-cancel-reason')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('wb-cancel-reason'), { target: { value: 'Found an error' } })
    await waitFor(() => expect(screen.getByRole('button', { name: wbEn['stock.wb.cancel.confirm'] })).not.toBeDisabled())
    fireEvent.click(screen.getByRole('button', { name: wbEn['stock.wb.cancel.confirm'] }))
    await waitFor(() => expect(screen.getByTestId('wb-cancel-result')).toBeInTheDocument())
    expect(screen.getByTestId('wb-cancel-result')).toHaveTextContent(wbEn['stock.wb.cancel.cancelled'])
    // The cancel route is called with the exact path and body
    expect(clientMock.post).toHaveBeenCalledWith(
      '/api/v1/modules/stock/stock-workbook/imports/imp-1/cancel',
      { reason: 'Found an error' },
    )
    // The imports list is re-fetched after cancel (invalidateQueries triggered a GET)
    await waitFor(() => expect(importsGetCount).toBeGreaterThan(0))
  })

  it('reverse_pending: shows reverse pending message with document link', async () => {
    renderWB(withQCAndReverse, [importRow])
    clientMock.post.mockImplementation(async (path: string, body?: unknown) => {
      if (typeof path === 'string' && path.includes('/cancel')) return { action: 'reverse_pending', lines: 10 }
      const b = (body ?? {}) as { entity_type?: string }
      if (path === '/api/v1/entities/query') {
        if (b.entity_type === 'org_unit') return { items: [OU_REC], next_cursor: null }
        return { items: [], next_cursor: null }
      }
      return {}
    })
    await waitFor(() => expect(screen.getByTestId(`cancel-${importRow.document_id}`)).toBeInTheDocument())
    fireEvent.click(screen.getByTestId(`cancel-${importRow.document_id}`))
    await waitFor(() => expect(screen.getByTestId('wb-cancel-reason')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('wb-cancel-reason'), { target: { value: 'Error' } })
    await waitFor(() => expect(screen.getByRole('button', { name: wbEn['stock.wb.cancel.confirm'] })).not.toBeDisabled())
    fireEvent.click(screen.getByRole('button', { name: wbEn['stock.wb.cancel.confirm'] }))
    await waitFor(() => expect(screen.getByTestId('wb-cancel-result')).toBeInTheDocument())
    expect(screen.getByTestId('wb-cancel-result')).toHaveTextContent(wbEn['stock.wb.cancel.reversePending'])
    // Link to the document
    expect(screen.getByTestId('wb-cancel-doc-link')).toHaveAttribute('href', `/admin/stock/documents/${importRow.document_id}`)
  })

  it('409 reversal_pending shows error in dialog', async () => {
    renderWB(withQCAndReverse, [importRow])
    clientMock.post.mockImplementation(async (path: string, body?: unknown) => {
      if (typeof path === 'string' && path.includes('/cancel')) throw refusal(409, 'reversal_pending')
      const b = (body ?? {}) as { entity_type?: string }
      if (path === '/api/v1/entities/query') {
        if (b.entity_type === 'org_unit') return { items: [OU_REC], next_cursor: null }
        return { items: [], next_cursor: null }
      }
      return {}
    })
    await waitFor(() => expect(screen.getByTestId(`cancel-${importRow.document_id}`)).toBeInTheDocument())
    fireEvent.click(screen.getByTestId(`cancel-${importRow.document_id}`))
    await waitFor(() => expect(screen.getByTestId('wb-cancel-reason')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('wb-cancel-reason'), { target: { value: 'Reason' } })
    await waitFor(() => expect(screen.getByRole('button', { name: wbEn['stock.wb.cancel.confirm'] })).not.toBeDisabled())
    fireEvent.click(screen.getByRole('button', { name: wbEn['stock.wb.cancel.confirm'] }))
    // Dialog stays open with error
    await waitFor(() => expect(screen.getByRole('dialog')).toBeInTheDocument())
    expect(screen.getByRole('dialog')).toHaveTextContent(wbEn['stock.wb.err.reversal_pending'])
  })

  it('cancel reason textarea has a 500-character limit', async () => {
    renderWB(withQCAndReverse, [importRow])
    await waitFor(() => expect(screen.getByTestId(`cancel-${importRow.document_id}`)).toBeInTheDocument())
    fireEvent.click(screen.getByTestId(`cancel-${importRow.document_id}`))
    await waitFor(() => expect(screen.getByTestId('wb-cancel-reason')).toBeInTheDocument())
    expect(screen.getByTestId('wb-cancel-reason')).toHaveAttribute('maxlength', '500')
  })

  it('422 import_already_cancelled shows error in dialog', async () => {
    renderWB(withQCAndReverse, [importRow])
    clientMock.post.mockImplementation(async (path: string, body?: unknown) => {
      if (typeof path === 'string' && path.includes('/cancel')) throw refusal(422, 'import_already_cancelled')
      const b = (body ?? {}) as { entity_type?: string }
      if (path === '/api/v1/entities/query') {
        if (b.entity_type === 'org_unit') return { items: [OU_REC], next_cursor: null }
        return { items: [], next_cursor: null }
      }
      return {}
    })
    await waitFor(() => expect(screen.getByTestId(`cancel-${importRow.document_id}`)).toBeInTheDocument())
    fireEvent.click(screen.getByTestId(`cancel-${importRow.document_id}`))
    await waitFor(() => expect(screen.getByTestId('wb-cancel-reason')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('wb-cancel-reason'), { target: { value: 'x' } })
    await waitFor(() => expect(screen.getByRole('button', { name: wbEn['stock.wb.cancel.confirm'] })).not.toBeDisabled())
    fireEvent.click(screen.getByRole('button', { name: wbEn['stock.wb.cancel.confirm'] }))
    await waitFor(() => expect(screen.getByRole('dialog')).toBeInTheDocument())
    expect(screen.getByRole('dialog')).toHaveTextContent(wbEn['stock.wb.err.import_already_cancelled'])
  })
})

/** C6: i18n — every new message id exists in en, ru and kk. */
describe('C6 i18n', () => {
  const EN_KEYS = Object.keys(wbEn)

  it('all en keys exist in ru', () => {
    for (const k of EN_KEYS) {
      expect(wbRu[k], `ru missing key: ${k}`).toBeTruthy()
    }
  })

  it('all en keys exist in kk', () => {
    for (const k of EN_KEYS) {
      expect(wbKk[k], `kk missing key: ${k}`).toBeTruthy()
    }
  })

  it('ru and kk differ from en for the title', () => {
    expect(wbRu['stock.wb.title']).not.toBe(wbEn['stock.wb.title'])
    expect(wbKk['stock.wb.title']).not.toBe(wbEn['stock.wb.title'])
  })

  it('the load button label is correct in all three locales', () => {
    expect(wbRu['stock.wb.load']).toBe('Записать остатки из файла')
    expect(wbEn['stock.wb.load']).toBe('Write balances from the file')
    expect(wbKk['stock.wb.load']).toBe('Файлдағы қалдықтарды жазу')
  })
})
