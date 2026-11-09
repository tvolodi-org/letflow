// @vitest-environment jsdom
/** T-1556 (BA batch 2 item 4): the clerk's import error report. Asset imports reachable from the real module registry
 *  (T-E1..E4), localized violations (T-V1..V3), rolled-back answers (T-D3), the CSV of refused rows (T-D5), the named
 *  wrong header (T-B5). The registry is the real one; nothing is injected. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen } from '@testing-library/react'
import { importMessages } from '@/i18n/importMessages'
import { classifyImportError, refusedRowsCsv, violationText } from '../importModel'
import { access, apiError, chooseFile, chooseType, clientMock, INSTALLED, ok, renderPage, xlsxFile } from './importTestKit'

expect.extend(jestDomMatchers)

const toastSuccess = vi.fn()
vi.mock('@/hooks/useToast', async (importOriginal) => {
  const original = await importOriginal<typeof import('@/hooks/useToast')>()
  return { ...original, useToast: () => ({ ...original.useToast(), success: toastSuccess }) }
})
vi.mock('@/hooks/useInstalledModules', async () => {
  const kit = await import('./importMocks')
  return { useInstalledModules: () => ({ data: kit.INSTALLED.value }) }
})
vi.mock('@/api/client', async (importOriginal) => {
  const kit = await import('./importMocks')
  return { ...(await importOriginal<object>()), client: kit.clientMock }
})

const ADMIN = access('EntitiesRecordsImport', 'EntitiesRecordsExport', 'AssetsCardWrite', 'AssetsPost')

beforeEach(() => {
  clientMock.postRaw.mockReset()
  toastSuccess.mockReset()
  INSTALLED.value = [{ module_id: 'assets', version: '1' }]
})
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

function lang(l: 'en' | 'ru' | 'kk') {
  vi.stubGlobal('navigator', { languages: [l], language: l })
}

describe('T-E1/T-E3 the asset imports in the picker', () => {
  it.each([
    ['en', 'Asset cards', 'Asset opening lines'],
    ['ru', 'Карточки активов', 'Начальные остатки активов'],
    ['kk', 'Активтер карточкалары', 'Активтердің бастапқы қалдықтары'],
  ] as const)('lists the card type, then the opening lines, in %s', (l, cards, lines) => {
    lang(l)
    renderPage(ADMIN)
    const radios = screen.getAllByRole('radio')
    expect(radios.map((r) => r.getAttribute('value'))).toEqual(['assets_card', 'assets_opening_line'])
    expect(radios[0]).toHaveAccessibleName(expect.stringContaining(cards))
    expect(radios[1]).toHaveAccessibleName(expect.stringContaining(lines))
  })

  it('a holder of neither atom sees no asset type; a holder of AssetsPost only sees the opening lines', () => {
    renderPage(access('EntitiesRecordsImport'))
    expect(screen.queryAllByRole('radio')).toHaveLength(0)
    cleanup()
    renderPage(access('EntitiesRecordsImport', 'AssetsPost'))
    expect(screen.getAllByRole('radio').map((r) => r.getAttribute('value'))).toEqual(['assets_opening_line'])
  })
})

describe('T-E2 the upload of each asset type is atomic', () => {
  it.each([['assets_card'], ['assets_opening_line']])('%s: the real import asks for atomic=true', async (type) => {
    clientMock.postRaw.mockResolvedValue({ dry_run: true, results: [ok(2, 'created')] })
    renderPage(ADMIN)
    chooseType(type)
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('import-check'))
    await screen.findByTestId('import-dry-run')
    expect(clientMock.postRaw.mock.calls[0]![0]).toBe(`/api/v1/entities/records/${type}/import?upsert_by=external_ref&dry_run=true`)
    clientMock.postRaw.mockResolvedValue({ applied: true, results: [ok(2, 'created')] })
    fireEvent.click(screen.getByTestId('import-confirm'))
    await screen.findByTestId('import-summary')
    expect(clientMock.postRaw.mock.calls[1]![0]).toBe(`/api/v1/entities/records/${type}/import?upsert_by=external_ref&atomic=true`)
  })
})

describe('T-E4/T-D3 a rolled-back answer', () => {
  const duplicate = {
    status: 'error',
    line: 3,
    reason: { type: 'asset_inventory_number_taken', header: 'inventory_number' },
  } as const

  async function importRolledBack(l: 'en' | 'ru' | 'kk') {
    lang(l)
    clientMock.postRaw.mockResolvedValueOnce({ dry_run: true, results: [ok(2, 'created')] })
    renderPage(ADMIN)
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('import-check'))
    await screen.findByTestId('import-dry-run')
    clientMock.postRaw.mockResolvedValueOnce({ applied: false, results: [ok(2, 'created'), duplicate, ok(4, 'updated')] })
    fireEvent.click(screen.getByTestId('import-confirm'))
    return screen.findByTestId('import-not-applied')
  }

  it.each(['en', 'ru', 'kk'] as const)('shows the row, column and reason in %s, says nothing was imported, no toast', async (l) => {
    const card = await importRolledBack(l)
    const cat = importMessages[l]
    expect(card).toHaveTextContent('inventory_number')
    expect(card).toHaveTextContent(cat['import.reason.asset_inventory_number_taken']!)
    expect(card).toHaveTextContent(cat['import.notApplied']!)
    expect(screen.getByTestId('import-reupload')).toHaveTextContent(cat['import.reupload']!)
    expect(card).toHaveTextContent(cat['import.counts.wouldCreated']!)
    expect(card).not.toHaveTextContent(cat['import.summary.done']!)
    expect(toastSuccess).not.toHaveBeenCalled()
  })

  it('clears the chosen file so the corrected one starts a new check', async () => {
    await importRolledBack('en')
    expect(screen.getByTestId('import-check')).toBeDisabled()
  })

  it('applied true (and an answer without applied) is the usual summary with the success toast', async () => {
    for (const answer of [{ applied: true, results: [ok(2, 'created')] }, { results: [ok(2, 'created')] }]) {
      toastSuccess.mockReset()
      clientMock.postRaw.mockResolvedValueOnce({ dry_run: true, results: [ok(2, 'created')] })
      renderPage(ADMIN)
      chooseFile(xlsxFile())
      fireEvent.click(screen.getByTestId('import-check'))
      await screen.findByTestId('import-dry-run')
      clientMock.postRaw.mockResolvedValueOnce(answer)
      fireEvent.click(screen.getByTestId('import-confirm'))
      await screen.findByTestId('import-summary')
      expect(toastSuccess).toHaveBeenCalledTimes(1)
      cleanup()
    }
  })
})

describe('T-V1..V4 localized violations', () => {
  const unique = { code: 'unique', path: ['code'], message: 'this value has already been taken' }
  const required = { code: 'required', path: ['name'], message: 'name violates required' }
  const enumV = { code: 'enum_membership', path: ['kind'], message: 'kind violates enum_membership' }

  it.each(['en', 'ru', 'kk'] as const)('T-V1 %s: real shapes read in the language, never the English message', (l) => {
    for (const v of [unique, required, enumV]) {
      const text = violationText(l, v)
      expect(text).toBe(importMessages[l][`import.violation.${v.code}`])
      expect(text).not.toContain(v.message)
    }
  })

  it('T-V2 an unknown code gets the generic text with the code, not the message', () => {
    const text = violationText('ru', { code: 'brand_new_rule', path: ['x'], message: 'English words' })
    expect(text).toContain('brand_new_rule')
    expect(text).not.toContain('English words')
  })

  it('T-V3 the page shows the localized violation in ru and kk', async () => {
    for (const l of ['ru', 'kk'] as const) {
      lang(l)
      clientMock.postRaw.mockResolvedValue({
        dry_run: true,
        results: [{ status: 'error', line: 2, reason: { type: 'record_payload_invalid', violations: [unique] } }],
      })
      renderPage(ADMIN)
      chooseFile(xlsxFile())
      fireEvent.click(screen.getByTestId('import-check'))
      const row = await screen.findByTestId('datatable-row')
      expect(row).toHaveTextContent(importMessages[l]['import.violation.unique']!)
      expect(row).not.toHaveTextContent('already been taken')
      cleanup()
    }
  })
})

describe('T-D5 the CSV of refused rows', () => {
  it('has a BOM, a localized header, quoting and the formula guard', () => {
    const rows = [
      ok(2, 'created'),
      { status: 'error' as const, line: 3, external_ref: { id: '=SUM(A1)' }, reason: { type: 'quantity_invalid', header: 'quantity' } },
      { status: 'error' as const, line: 4, external_ref: { id: 'a,"b"' }, reason: { type: 'asset_inventory_number_taken', header: 'inventory_number' } },
    ]
    const csv = refusedRowsCsv('ru', rows)
    expect(csv.startsWith('﻿')).toBe(true)
    const lines = csv.slice(1).split('\r\n')
    expect(lines[0]).toBe('Строка,Колонка,Причина,Внешний id')
    expect(lines[1]).toContain("'=SUM(A1)")
    expect(lines[1]).toContain('quantity')
    expect(lines[2]).toContain('"a,""b"""')
    expect(lines).toHaveLength(4)
  })
})

describe('T-B5 a wrong header is named', () => {
  it('classifies the headers member of the 422', () => {
    const err = apiError(422, { detail: 'xlsx header has a column that is not a field of the entity type', headers: ['Inv no'] })
    expect(classifyImportError(err)).toEqual({ kind: 'xlsx', code: 'xlsx_unknown_header', headers: ['Inv no'] })
  })

  it('the page shows the names', async () => {
    clientMock.postRaw.mockRejectedValue(apiError(422, { detail: 'xlsx header has a duplicate column', headers: ['code'] }))
    renderPage(ADMIN)
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('import-check'))
    expect(await screen.findByTestId('import-error')).toHaveTextContent('code')
  })
})
