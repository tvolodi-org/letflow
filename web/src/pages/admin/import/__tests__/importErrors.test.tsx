// @vitest-environment jsdom
/** E1-E4/R1: GH 3650 / REQ-675 criteria 5 and 6, whole-request answers and row reasons. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen } from '@testing-library/react'
import { importMessages } from '@/i18n/importMessages'
import { ROW_REASON_TYPES, UNPROCESSABLE_DETAILS, classifyImportError } from '../importModel'
import { apiError, chooseFile, clientMock, refused, renderPage, xlsxFile } from './importTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/hooks/useInstalledModules', async () => {
  const kit = await import('./importMocks')
  return { useInstalledModules: () => ({ data: kit.INSTALLED.value }) }
})
vi.mock('@/api/client', async (importOriginal) => {
  const kit = await import('./importMocks')
  return { ...(await importOriginal<object>()), client: kit.clientMock }
})

beforeEach(() => {
  clientMock.postRaw.mockReset()
})
afterEach(() => cleanup())

async function check() {
  chooseFile(xlsxFile())
  fireEvent.click(screen.getByTestId('import-check'))
  return screen.findByTestId('import-error')
}

describe('E1/E2 limits', () => {
  it('does not send a file over 2_097_152 bytes', async () => {
    renderPage()
    chooseFile(xlsxFile('big.xlsx', 2_097_153))
    fireEvent.click(screen.getByTestId('import-check'))
    const alert = await screen.findByTestId('import-error')
    expect(alert).toHaveTextContent('2 MB')
    expect(clientMock.postRaw).not.toHaveBeenCalled()
  })

  it('sends a file of exactly 2_097_152 bytes', async () => {
    clientMock.postRaw.mockResolvedValue({ dry_run: true, results: [] })
    renderPage()
    chooseFile(xlsxFile('edge.xlsx', 2_097_152))
    fireEvent.click(screen.getByTestId('import-check'))
    await screen.findByTestId('import-dry-run')
    expect(clientMock.postRaw).toHaveBeenCalledTimes(1)
  })

  it('shows the limits message on a 413', async () => {
    clientMock.postRaw.mockRejectedValue(apiError(413))
    renderPage()
    const alert = await check()
    expect(alert).toHaveTextContent('2 MB')
    expect(alert).toHaveTextContent('200')
  })
})

describe('E3 422 details', () => {
  it.each(Object.entries(UNPROCESSABLE_DETAILS))('%s has its own message', async (detail, code) => {
    clientMock.postRaw.mockRejectedValue(apiError(422, { detail }))
    renderPage()
    const alert = await check()
    expect(alert).toHaveTextContent(importMessages.en[`import.error.${code}`])
  })

  it('shows a generic message with the detail for another 422', async () => {
    clientMock.postRaw.mockRejectedValue(apiError(422, { detail: 'something new' }))
    renderPage()
    expect(await check()).toHaveTextContent('The file was refused: something new')
  })
})

describe('E4 404, 403, 503', () => {
  it.each([
    [404, 'import.error.notAvailable'],
    [403, 'import.error.forbidden'],
    [503, 'import.error.busy'],
    [500, 'import.error.other'],
  ])('status %s', async (status, id) => {
    clientMock.postRaw.mockImplementation(async () => { throw apiError(status, status === 503 ? { error: 'trigger_backlog_full' } : undefined) })
    renderPage()
    expect(await check()).toHaveTextContent(importMessages.en[id])
  })

  it('classifies a network failure as other', () => {
    expect(classifyImportError(new TypeError('Failed to fetch'))).toEqual({ kind: 'other' })
  })
})

describe('R1 row reasons', () => {
  it('has a message in every language for every reason type', () => {
    for (const locale of ['en', 'ru', 'kk'] as const) {
      for (const type of ROW_REASON_TYPES) {
        expect(importMessages[locale][`import.reason.${type}`], `${locale} ${type}`).toBeTruthy()
      }
    }
  })

  it('shows the translated message for each reason type', async () => {
    clientMock.postRaw.mockResolvedValue({ dry_run: true, results: ROW_REASON_TYPES.map((t, i) => refused(i + 2, t)) })
    renderPage()
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('import-check'))
    await screen.findByTestId('import-dry-run')
    const rows = screen.getAllByTestId('import-result-row')
    expect(rows).toHaveLength(ROW_REASON_TYPES.length)
    ROW_REASON_TYPES.forEach((type, i) => {
      expect(rows[i]).toHaveTextContent(importMessages.en[`import.reason.${type}`])
    })
  })

  it('shows a generic message with the code for an unknown type', async () => {
    clientMock.postRaw.mockResolvedValue({ dry_run: true, results: [refused(2, 'brand_new_reason')] })
    renderPage()
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('import-check'))
    expect(await screen.findByTestId('import-result-row')).toHaveTextContent('The row was refused (brand_new_reason).')
  })
})
