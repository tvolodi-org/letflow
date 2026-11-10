// @vitest-environment jsdom
/** U1-U6, U9-U11, U14: T-1633 / REQ-791, the users import screen (BA decision T-1631 item 2). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { QueryClient } from '@tanstack/react-query'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { USERS_IMPORT_REASON_TYPES } from '../usersImportMessages'
import { usersRefusedRowsCsv } from '../usersImportModel'
import { clientMock } from './usersImportMocks'
import { apiError, chooseFile, ok, refused, renderPage, xlsxFile } from './usersImportKit'

expect.extend(jestDomMatchers)

vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: (await import('./usersImportMocks')).clientMock }))
vi.mock('@/api/useTenantScopedQueryKeys', () => ({
  useTenantScopedQueryKeys: () => ({ admin: { users: (f?: object) => ['tenant', 't1', 'admin', 'users', f ?? {}] } }),
}))

const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
const DRY = '/api/v1/identity/users/import?dry_run=true'
const REAL = '/api/v1/identity/users/import'
const downloads: string[] = []

beforeEach(() => {
  clientMock.postRaw.mockReset()
  clientMock.getBlob.mockReset()
  downloads.length = 0
  useUiLocaleStore.getState().setLocaleTransient('en')
  URL.createObjectURL = vi.fn(() => 'blob:t')
  URL.revokeObjectURL = vi.fn()
  vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (this: HTMLAnchorElement) {
    downloads.push(this.download)
  })
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('U1/U2 template', () => {
  it('U1 GETs the template route and saves users-template.xlsx', async () => {
    clientMock.getBlob.mockResolvedValue({ blob: new Blob(['x']), contentType: 'x' })
    renderPage()
    fireEvent.click(screen.getByTestId('users-import-template'))
    await waitFor(() => expect(downloads).toEqual(['users-template.xlsx']))
    expect(clientMock.getBlob).toHaveBeenCalledWith('/api/v1/identity/users/import-template')
  })
  it('U2 a failed download shows a banner', async () => {
    clientMock.getBlob.mockRejectedValue(apiError(500))
    renderPage()
    fireEvent.click(screen.getByTestId('users-import-template'))
    await screen.findByTestId('users-import-template-failed')
    expect(downloads).toEqual([])
  })
})

describe('U3/U4/U5 dry run and report', () => {
  it('U3 Check posts dry_run=true, Import is off while a row is refused; U4 row, column and reason; U5 counts', async () => {
    clientMock.postRaw.mockResolvedValue({
      dry_run: true,
      results: [ok(2, 'created'), ok(3, 'unchanged'), refused(4, 'user_field_required', 'email'), refused(5, 'xlsx_cell_count')],
    })
    renderPage()
    const file = xlsxFile()
    chooseFile(file)
    expect(screen.getByTestId('users-import-confirm')).toBeDisabled()
    fireEvent.click(screen.getByTestId('users-import-check'))
    await screen.findByTestId('users-import-dry-run')
    expect(clientMock.postRaw).toHaveBeenCalledWith(DRY, file, XLSX)
    const rows = screen.getAllByTestId('datatable-row')
    expect(rows).toHaveLength(4)
    expect(rows[0]).toHaveTextContent('Would create')
    expect(rows[1]).toHaveTextContent('Unchanged')
    expect(rows[2]).toHaveTextContent('Refused')
    expect(rows[2]).toHaveTextContent('email')
    expect(rows[2]).toHaveTextContent('A required value is empty. Fill it in.')
    expect(rows[2]).toHaveTextContent('4')
    expect(rows[3]).toHaveTextContent('The row has more cells than columns. Remove the extra cell.')
    const counts = screen.getByTestId('users-import-counts')
    expect(counts).toHaveTextContent(/1\s*Would be created/)
    expect(counts).toHaveTextContent(/1\s*Unchanged/)
    expect(counts).toHaveTextContent(/2\s*Refused/)
    expect(screen.getByTestId('users-import-confirm')).toBeDisabled()
    expect(screen.getByText('Nothing was written.')).toBeInTheDocument()
  })
  it('an empty answer keeps Import off', async () => {
    clientMock.postRaw.mockResolvedValue({ dry_run: true, results: [] })
    renderPage()
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('users-import-check'))
    await screen.findByText('The file has no data rows.')
    expect(screen.getByTestId('users-import-confirm')).toBeDisabled()
  })
})

describe('U6 refused rows CSV', () => {
  it('has row, column and a localized reason for every reason type, no cell text', () => {
    const results = USERS_IMPORT_REASON_TYPES.map((t, i) => refused(i + 2, t, i % 2 === 0 ? 'username' : undefined))
    for (const locale of ['en', 'ru', 'kk'] as const) {
      const csv = usersRefusedRowsCsv(locale, [ok(1, 'created'), ...results])
      const lines = csv.replace('﻿', '').trim().split('\r\n')
      expect(lines).toHaveLength(1 + USERS_IMPORT_REASON_TYPES.length)
      expect(csv).not.toMatch(/user_field_required|csv_invalid_value|unknown/)
    }
    expect(usersRefusedRowsCsv('ru', results)).toContain('Строка')
    expect(usersRefusedRowsCsv('en', [refused(7, 'user_field_required', '=x')])).toContain("'=x")
  })
  it('the download button saves users-refused-rows.csv', async () => {
    clientMock.postRaw.mockResolvedValue({ dry_run: true, results: [refused(2, 'user_field_invalid', 'email')] })
    renderPage()
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('users-import-check'))
    fireEvent.click(await screen.findByTestId('users-import-download-refused'))
    expect(downloads).toEqual(['users-refused-rows.csv'])
  })
})

describe('U9/U10/U14 fix and re-upload, import', () => {
  it('U9 dirty check, pick a new file, clean check, Import posts without dry_run', async () => {
    clientMock.postRaw
      .mockResolvedValueOnce({ dry_run: true, results: [refused(2, 'user_duplicate_in_file', 'username')] })
      .mockResolvedValueOnce({ dry_run: true, results: [ok(2, 'created')] })
      .mockResolvedValueOnce({ results: [ok(2, 'created')], applied: true })
    renderPage()
    chooseFile(xlsxFile('a.xlsx'))
    fireEvent.click(screen.getByTestId('users-import-check'))
    await screen.findByTestId('users-import-why')
    const fixed = xlsxFile('b.xlsx')
    chooseFile(fixed)
    expect(screen.queryByTestId('users-import-dry-run')).toBeNull()
    fireEvent.click(screen.getByTestId('users-import-check'))
    await waitFor(() => expect(screen.getByTestId('users-import-confirm')).toBeEnabled())
    fireEvent.click(screen.getByTestId('users-import-confirm'))
    await screen.findByTestId('users-import-summary')
    expect(clientMock.postRaw).toHaveBeenLastCalledWith(REAL, fixed, XLSX)
    expect(screen.getByTestId('users-import-counts')).toHaveTextContent(/1\s*Created/)
  })
  it('U10 applied:false shows the not-applied banner and clears the file picker', async () => {
    clientMock.postRaw
      .mockResolvedValueOnce({ dry_run: true, results: [ok(2, 'created')] })
      .mockResolvedValueOnce({ results: [refused(2, 'user_exists_different', 'username')], applied: false })
    renderPage()
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('users-import-check'))
    await waitFor(() => expect(screen.getByTestId('users-import-confirm')).toBeEnabled())
    fireEvent.click(screen.getByTestId('users-import-confirm'))
    await screen.findByTestId('users-import-not-applied')
    expect(screen.getByTestId('users-import-reupload')).toBeInTheDocument()
    expect(screen.queryByTestId('users-import-summary')).toBeNull()
    expect(screen.getByTestId('users-import-check')).toBeDisabled()
  })
  it('U14 applied:true invalidates the cached users list; a dry run does not', async () => {
    const qc = new QueryClient()
    const key = ['tenant', 't1', 'admin', 'users', { search: 'ann' }]
    qc.setQueryData(key, { items: [] })
    clientMock.postRaw
      .mockResolvedValueOnce({ dry_run: true, results: [ok(2, 'created')] })
      .mockResolvedValueOnce({ results: [ok(2, 'created')], applied: true })
    renderPage(qc)
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('users-import-check'))
    await waitFor(() => expect(screen.getByTestId('users-import-confirm')).toBeEnabled())
    expect(qc.getQueryState(key)?.isInvalidated).toBe(false)
    fireEvent.click(screen.getByTestId('users-import-confirm'))
    await screen.findByTestId('users-import-summary')
    await waitFor(() => expect(qc.getQueryState(key)?.isInvalidated).toBe(true))
  })
})

describe('U15 stale answer, U16 duplicate email', () => {
  it('U15 an answer for file A cannot authorize file B', async () => {
    let resolveA: (v: unknown) => void = () => {}
    clientMock.postRaw.mockReturnValueOnce(new Promise((r) => (resolveA = r)))
    renderPage()
    chooseFile(xlsxFile('a.xlsx'))
    fireEvent.click(screen.getByTestId('users-import-check'))
    chooseFile(xlsxFile('b.xlsx'))
    resolveA({ dry_run: true, results: [ok(2, 'created')] })
    await new Promise((r) => setTimeout(r, 0))
    expect(screen.queryByTestId('users-import-dry-run')).toBeNull()
    expect(screen.getByTestId('users-import-confirm')).toBeDisabled()
    expect(clientMock.postRaw).toHaveBeenCalledTimes(1)
  })
  it('U16 duplicate email gets its own text in en, ru, kk and in the CSV', () => {
    const row = refused(3, 'user_duplicate_in_file', 'email')
    const want = { en: /email/i, ru: /почты/, kk: /пошта/ }
    for (const locale of ['en', 'ru', 'kk'] as const) {
      const csv = usersRefusedRowsCsv(locale, [row])
      expect(csv).toMatch(want[locale])
      expect(csv).not.toBe(usersRefusedRowsCsv(locale, [refused(3, 'user_duplicate_in_file', 'username')]))
    }
  })
})

describe('U11 whole-file refusals', () => {
  const cases: [string, unknown, RegExp][] = [
    ['413', apiError(413), /at most 2 MB and 200 data rows/],
    ['422 named duplicate header', apiError(422, { detail: 'xlsx header has a duplicate column', headers: ['email'] }), /These columns appear twice: email/],
    ['422 unknown header', apiError(422, { detail: 'xlsx header has a column that is not a field of the entity type', headers: ['password'] }), /not in the template: password/],
    ['422 missing header', apiError(422, { detail: 'xlsx file is missing a required column', code: 'xlsx_missing_header', headers: ['email', 'username'] }), /missing these columns: email, username/],
    ['403', apiError(403), /not permitted/],
    ['503', apiError(503), /server is busy/],
  ]
  it.each(cases)('%s', async (_n, err, text) => {
    clientMock.postRaw.mockRejectedValue(err)
    renderPage()
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('users-import-check'))
    expect(await screen.findByTestId('users-import-error')).toHaveTextContent(text)
    expect(screen.queryByTestId('users-import-dry-run')).toBeNull()
  })
  it('a file over 2 MiB is refused before any request', async () => {
    renderPage()
    chooseFile(xlsxFile('big.xlsx', 2_097_153))
    fireEvent.click(screen.getByTestId('users-import-check'))
    expect(await screen.findByTestId('users-import-error')).toHaveTextContent(/at most 2 MB/)
    expect(clientMock.postRaw).not.toHaveBeenCalled()
  })
})
