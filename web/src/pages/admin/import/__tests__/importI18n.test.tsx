// @vitest-environment jsdom
/** I1/I3/I5: GH 3650 / REQ-675 criterion 7, languages and no tenant identifier in a request. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen } from '@testing-library/react'
import { importMessages } from '@/i18n/importMessages'
import { chooseFile, clientMock, ok, renderPage, xlsxFile } from './importTestKit'

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
  clientMock.postBlob.mockReset()
})
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe('I1 catalog', () => {
  it('has the same keys in en, ru and kk', () => {
    const keys = Object.keys(importMessages.en).sort()
    expect(Object.keys(importMessages.ru).sort()).toEqual(keys)
    expect(Object.keys(importMessages.kk).sort()).toEqual(keys)
    for (const locale of ['en', 'ru', 'kk'] as const) {
      for (const key of keys) expect(importMessages[locale][key], `${locale} ${key}`).toBeTruthy()
    }
  })
})

describe('I3 locale', () => {
  it.each([
    ['ru', 'Импорт справочных данных'],
    ['kk', 'Анықтамалық деректерді импорттау'],
    ['en', 'Import master data'],
  ])('shows the title in %s', (lang, title) => {
    vi.stubGlobal('navigator', { languages: [lang], language: lang })
    renderPage()
    expect(screen.getByTestId('page-layout-title')).toHaveTextContent(title)
  })

  it('shows type labels in the page locale', () => {
    vi.stubGlobal('navigator', { languages: ['ru'], language: 'ru' })
    renderPage()
    expect(screen.getByRole('option', { name: 'Должности' })).toBeInTheDocument()
  })
})

describe('I5 no tenant identifier', () => {
  it('sends none in path, query or body', async () => {
    clientMock.postRaw.mockResolvedValue({ dry_run: true, results: [ok(2, 'created')] })
    clientMock.postBlob.mockResolvedValue({ blob: new Blob(['x']), contentType: 'x' })
    URL.createObjectURL = vi.fn(() => 'blob:t')
    URL.revokeObjectURL = vi.fn()
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
    renderPage()
    fireEvent.click(screen.getByTestId('import-template'))
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('import-check'))
    await screen.findByTestId('import-dry-run')
    fireEvent.click(screen.getByTestId('import-confirm'))
    await vi.waitFor(() => expect(clientMock.postRaw).toHaveBeenCalledTimes(2))
    const calls = [...clientMock.postBlob.mock.calls, ...clientMock.postRaw.mock.calls]
    expect(calls.length).toBe(3)
    for (const [path, body] of calls) {
      const text = `${path as string} ${body instanceof Blob ? '' : JSON.stringify(body)}`
      expect(text).not.toMatch(/tenant|tid-ci|acme/i)
    }
  })
})
