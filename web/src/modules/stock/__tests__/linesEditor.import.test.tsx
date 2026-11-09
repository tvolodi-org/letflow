// @vitest-environment jsdom
/** LE2 (T-1449) T4, T5, T8: Import from Excel on the opening draft (the route writes the lines, the form reloads them). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { DOCS, LIST, fakeDocument, fakeMasters, renderStock, stockDoc, withPost } from './stockTestKit'
import { importErrorText, sameLines, summariseImport } from '../documents/openingImport'
import { reasonSentence } from '@/pages/admin/import/importModel'
import { emptyLine, MAX_LINES } from '../documents/documentsModel'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn(), postRaw: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const line = (n: number, q: string) => ({ line_id: `x${n}`, line_no: n, catalog_item_id: 'i1', catalog_uom_id: 'm1', quantity: q, location_id: 'l1', responsible_id: 'e1', received_on: '2026-09-15' })
const OPENING = (over: Record<string, unknown> = {}) =>
  stockDoc({ kind: 'opening', event_time: null, location_id: null, responsible_id: null, note: null, external_ref_system: 'erp', external_ref_id: 'OB-7', lines: [line(1, '3')], ...over })

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockResolvedValue({ rows: [], next_cursor: null })
  window.localStorage.clear()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  window.localStorage.clear()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

const importBtn = () => screen.getByRole('button', { name: 'Import lines from Excel' })
const xlsx = (size = 10) => new File([new Uint8Array(size)], 'lines.xlsx')
const choose = (file: File) => fireEvent.change(screen.getByTestId('lines-import-file'), { target: { files: [file] } })
async function openEdit(doc: Record<string, unknown>) {
  fakeDocument(clientMock, doc)
  renderStock(`${LIST}/d1`, withPost)
  fireEvent.click(await screen.findByRole('button', { name: 'Edit' }))
  await screen.findByTestId('document-form')
}

describe('LE2-T4 import on the opening draft', () => {
  it('a saved clean draft imports: the route is called, the lines are reloaded, the banner counts and lists the refused', async () => {
    const doc = OPENING()
    await openEdit(doc)
    await waitFor(() => expect(importBtn()).toBeEnabled())
    const fresh = OPENING({ lines: [line(1, '3'), line(2, '4'), line(3, '5')] })
    clientMock.get.mockImplementation(async (p: string) => (p === `${DOCS}/d1` ? fresh : { rows: [], next_cursor: null }))
    clientMock.postRaw.mockResolvedValue({
      results: [
        { status: 'ok', line: 1, outcome: 'created' },
        { status: 'ok', line: 2, outcome: 'created' },
        { status: 'error', line: 3, reason: { type: 'lines_count' } },
      ],
    })
    fireEvent.click(importBtn())
    choose(xlsx())
    const notice = await screen.findByTestId('lines-notice')
    expect(notice).toHaveTextContent('2 lines added, 1 refused')
    expect(clientMock.postRaw.mock.calls[0]![0]).toBe('/api/v1/entities/records/stock_opening_line/import?upsert_by=external_ref&atomic=true')
    expect(clientMock.postRaw.mock.calls[0]![0]).not.toContain('dry_run')
    await waitFor(() => expect(screen.getAllByTestId('line-editor-row')).toHaveLength(3))
    expect(notice).toHaveTextContent('A document holds at most 1000 lines.')
  })

  it('T-D4 a rolled-back answer says nothing was added, not "N lines added"', async () => {
    const doc = OPENING()
    await openEdit(doc)
    await waitFor(() => expect(importBtn()).toBeEnabled())
    clientMock.get.mockImplementation(async (p: string) => (p === `${DOCS}/d1` ? doc : { rows: [], next_cursor: null }))
    clientMock.postRaw.mockResolvedValue({
      applied: false,
      results: [
        { status: 'ok', line: 1, outcome: 'created' },
        { status: 'error', line: 2, reason: { type: 'quantity_invalid', header: 'quantity' } },
      ],
    })
    fireEvent.click(importBtn())
    choose(xlsx())
    const notice = await screen.findByTestId('lines-notice')
    expect(notice).toHaveTextContent('Nothing was added: 1 rows have a problem.')
    expect(notice).not.toHaveTextContent('lines added')
    expect(notice).toHaveTextContent('quantity')
  })

  it('a draft with unsaved edits has the button disabled with the reason, and sends nothing', async () => {
    await openEdit(OPENING())
    await waitFor(() => expect(importBtn()).toBeEnabled())
    fireEvent.change(screen.getByLabelText('Quantity'), { target: { value: '9' } })
    await waitFor(() => expect(importBtn()).toBeDisabled())
    expect(importBtn()).toHaveAttribute('title', expect.stringContaining('Save your changes first'))
    expect(clientMock.postRaw).not.toHaveBeenCalled()
  })

  it('a draft without the external reference pair says so', async () => {
    await openEdit(OPENING({ external_ref_system: null, external_ref_id: null }))
    await waitFor(() => expect(importBtn()).toBeDisabled())
    expect(importBtn()).toHaveAttribute('title', expect.stringContaining('external reference'))
  })

  it('a new draft says Save the draft first', async () => {
    renderStock(`${LIST}/new?kind=opening`, withPost)
    fireEvent.click(await screen.findByTestId('lines-empty-import'))
    // the empty state offers the import, disabled until the draft is saved
    expect(screen.getByTestId('lines-empty-import')).toBeDisabled()
    expect(screen.getByTestId('lines-empty-import')).toHaveAttribute('title', expect.stringContaining('Save the draft first'))
  })

  it('other kinds have no import button', async () => {
    await openEdit(stockDoc())
    expect(screen.queryByRole('button', { name: 'Import lines from Excel' })).not.toBeInTheDocument()
  })
})

describe('LE2-T5 import failures keep the lines', () => {
  it('413 shows the limits text and the lines stay', async () => {
    await openEdit(OPENING())
    await waitFor(() => expect(importBtn()).toBeEnabled())
    clientMock.postRaw.mockRejectedValue({ status: 413, message: 'x', code: '413' })
    fireEvent.click(importBtn())
    choose(xlsx())
    expect(await screen.findByTestId('lines-notice')).toHaveTextContent('over the limits')
    expect(screen.getAllByTestId('line-editor-row')).toHaveLength(1)
  })

  it('a file over 2 MB is refused before it is sent', async () => {
    await openEdit(OPENING())
    await waitFor(() => expect(importBtn()).toBeEnabled())
    fireEvent.click(importBtn())
    choose(xlsx(2_097_153))
    expect(await screen.findByTestId('lines-notice')).toHaveTextContent('larger than 2 MB')
    expect(clientMock.postRaw).not.toHaveBeenCalled()
  })

  it('the import worked but the reload fails: an error banner, the local lines stay', async () => {
    await openEdit(OPENING())
    await waitFor(() => expect(importBtn()).toBeEnabled())
    clientMock.postRaw.mockResolvedValue({ results: [{ status: 'ok', line: 1, outcome: 'created' }] })
    clientMock.get.mockRejectedValue({ status: 500, message: 'x', code: '500' })
    fireEvent.click(importBtn())
    choose(xlsx())
    expect(await screen.findByTestId('lines-notice')).toHaveTextContent('could not be reloaded')
    expect(screen.getAllByTestId('line-editor-row')).toHaveLength(1)
  })
})

describe('LE2-T1/T8 the cap and the pure helpers', () => {
  it('the cap is the server one', () => {
    expect(MAX_LINES).toBe(1000)
  })
  it('sameLines compares field by field', () => {
    const a = { ...emptyLine(), quantity: '1' }
    expect(sameLines([a], [{ ...a }])).toBe(true)
    expect(sameLines([a], [{ ...a, quantity: '2' }])).toBe(false)
    expect(sameLines([a], [a, a])).toBe(false)
  })
  it('summariseImport counts ok rows and names refused ones in the language', () => {
    const answer = { results: [{ status: 'ok' as const }, { status: 'error' as const, line: 7, reason: { type: 'lines_count', header: 'qty' } }] }
    const en = summariseImport('en', answer)
    expect(en.added).toBe(1)
    expect(en.refused).toEqual([{ row: 7, reason: expect.stringContaining('at most 1000 lines') }])
    expect(summariseImport('ru', answer).refused[0]!.reason).toContain('не более 1000')
    expect(summariseImport('kk', answer).refused[0]!.reason).toContain('1000')
  })
  it('importErrorText maps the kinds and falls back', () => {
    expect(importErrorText('en', { status: 403 })).toBe('This action is not permitted.')
    expect(importErrorText('en', new Error('x'))).toContain('failed')
  })
})

describe('T-1556 the shared texts of the import report', () => {
  const unique = { code: 'unique', path: ['code'], message: 'this value has already been taken' }

  it('T-V4 the lines editor reason equals the page sentence and never shows the English message', () => {
    const reason = { type: 'record_payload_invalid', violations: [unique] }
    const summary = summariseImport('ru', { results: [{ status: 'error', line: 5, reason }] })
    expect(summary.refused[0]!.reason).toContain(reasonSentence('ru', reason))
    expect(summary.refused[0]!.reason).not.toContain('already been taken')
  })

  it('T-D4 a rolled-back answer counts no added line and keeps the refused rows', () => {
    const answer = {
      applied: false,
      results: [
        { status: 'ok' as const, line: 2, outcome: 'created' as const },
        { status: 'error' as const, line: 3, reason: { type: 'quantity_invalid', header: 'quantity' } },
      ],
    }
    const s = summariseImport('en', answer)
    expect(s.added).toBe(0)
    expect(s.applied).toBe(false)
    expect(s.refused).toHaveLength(1)
    expect(s.refused[0]!.reason).toContain('quantity')
    expect(summariseImport('en', { applied: true, results: [{ status: 'ok', line: 2, outcome: 'created' }] })).toEqual({
      added: 1,
      refused: [],
      applied: true,
    })
  })

  it('T-B5 a wrong header names the columns in the editor error text', () => {
    const err = { status: 422, message: 'x', code: '422', details: { detail: 'xlsx header has a column that is not a field of the entity type', headers: ['Inv no'] } }
    for (const l of ['en', 'ru', 'kk'] as const) expect(importErrorText(l, err)).toContain('Inv no')
  })
})
