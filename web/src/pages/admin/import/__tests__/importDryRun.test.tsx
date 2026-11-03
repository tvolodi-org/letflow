// @vitest-environment jsdom
/** D1/C1/C2: GH 3650 / REQ-675 criteria 3 and 4, dry run and confirm. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { chooseFile, chooseType, clientMock, ok, refused, renderPage, xlsxFile } from './importTestKit'

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
const DRY_PATH = '/api/v1/entities/records/org_unit/import?upsert_by=external_ref&dry_run=true'
const REAL_PATH = '/api/v1/entities/records/org_unit/import?upsert_by=external_ref'

beforeEach(() => {
  clientMock.postRaw.mockReset()
})
afterEach(() => cleanup())

describe('D1 dry run', () => {
  it('sends the raw file and shows rows, translated reason and counts', async () => {
    clientMock.postRaw.mockResolvedValue({
      dry_run: true,
      results: [ok(2, 'created'), ok(3, 'unchanged'), refused(4, 'reference_not_found', { header: 'base_uom_id' })],
    })
    renderPage()
    const file = xlsxFile()
    chooseFile(file)
    fireEvent.click(screen.getByTestId('import-check'))
    await screen.findByTestId('import-dry-run')
    expect(clientMock.postRaw).toHaveBeenCalledWith(DRY_PATH, file, XLSX)
    const rows = screen.getAllByTestId('datatable-row')
    expect(rows).toHaveLength(3)
    expect(rows[0]).toHaveTextContent('Created')
    expect(rows[0]).toHaveTextContent('E2')
    expect(rows[1]).toHaveTextContent('Unchanged')
    expect(rows[2]).toHaveTextContent('Refused')
    expect(rows[2]).toHaveTextContent('The referenced record was not found.')
    expect(rows[2]).toHaveTextContent('base_uom_id')
    expect(rows[2]).toHaveTextContent('4')
    const counts = screen.getByTestId('import-counts')
    expect(counts).toHaveTextContent(/1\s*Created/)
    expect(counts).toHaveTextContent(/1\s*Unchanged/)
    expect(counts).toHaveTextContent(/1\s*Refused/)
    expect(screen.getByText('Nothing has been written yet.')).toBeInTheDocument()
  })

  it('lists the violations of record_payload_invalid by field', async () => {
    clientMock.postRaw.mockResolvedValue({
      dry_run: true,
      results: [
        refused(2, 'record_payload_invalid', {
          violations: [{ code: 'required', path: 'code', message: 'code violates required' }],
        }),
      ],
    })
    renderPage()
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('import-check'))
    const row = await screen.findByTestId('datatable-row')
    expect(row).toHaveTextContent('code: code violates required')
  })
})

describe('C1/C2 confirm', () => {
  it('enables Import only after a clean dry run of the same file and type', async () => {
    clientMock.postRaw.mockResolvedValueOnce({ dry_run: true, results: [ok(2, 'created'), refused(3, 'cycle')] })
    renderPage()
    const confirm = screen.getByTestId('import-confirm')
    expect(confirm).toBeDisabled()
    chooseFile(xlsxFile())
    expect(confirm).toBeDisabled()
    fireEvent.click(screen.getByTestId('import-check'))
    await screen.findByTestId('import-dry-run')
    expect(confirm).toBeDisabled()

    clientMock.postRaw.mockResolvedValueOnce({ dry_run: true, results: [ok(2, 'created')] })
    fireEvent.click(screen.getByTestId('import-check'))
    await waitFor(() => expect(confirm).toBeEnabled())

    chooseFile(xlsxFile('other.xlsx'))
    expect(confirm).toBeDisabled()
    expect(screen.queryByTestId('import-dry-run')).not.toBeInTheDocument()

    clientMock.postRaw.mockResolvedValue({ dry_run: true, results: [ok(2, 'created')] })
    fireEvent.click(screen.getByTestId('import-check'))
    await waitFor(() => expect(confirm).toBeEnabled())
    chooseType('org_position')
    expect(confirm).toBeDisabled()
  })

  it('imports the same bytes without dry_run and shows the import answer', async () => {
    clientMock.postRaw.mockImplementation(async (path: string) =>
      path.includes('dry_run')
        ? { dry_run: true, results: [ok(2, 'created')] }
        : { results: [ok(2, 'updated'), ok(3, 'updated')] },
    )
    renderPage()
    const file = xlsxFile()
    chooseFile(file)
    fireEvent.click(screen.getByTestId('import-check'))
    await screen.findByTestId('import-dry-run')
    fireEvent.click(screen.getByTestId('import-confirm'))
    await screen.findByTestId('import-summary')
    expect(clientMock.postRaw).toHaveBeenLastCalledWith(REAL_PATH, file, XLSX)
    expect(screen.getAllByTestId('datatable-row')).toHaveLength(2)
    expect(screen.getByTestId('import-counts')).toHaveTextContent(/2\s*Updated/)
    expect(screen.getByTestId('import-counts')).toHaveTextContent(/0\s*Created/)
    expect(screen.getByTestId('import-confirm')).toBeDisabled()
  })
})
