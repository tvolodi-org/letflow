// @vitest-environment jsdom
/** U7, U7b, U8: T-1633, the users import screen speaks en, ru and kk; no reason falls to the unknown text. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { USERS_IMPORT_REASON_TYPES, usersImportMessages } from '../usersImportMessages'
import { usersReasonSentence } from '../usersImportModel'
import { clientMock } from './usersImportMocks'
import { chooseFile, refused, renderPage, xlsxFile } from './usersImportKit'

expect.extend(jestDomMatchers)

vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: (await import('./usersImportMocks')).clientMock }))
vi.mock('@/api/useTenantScopedQueryKeys', () => ({
  useTenantScopedQueryKeys: () => ({ admin: { users: () => ['users'] } }),
}))

afterEach(() => {
  cleanup()
  useUiLocaleStore.getState().setLocaleTransient('en')
})

describe('U7 catalogs', () => {
  it('has the same id set in en, ru and kk, and no empty text', () => {
    const ids = Object.keys(usersImportMessages.en).sort()
    expect(Object.keys(usersImportMessages.ru).sort()).toEqual(ids)
    expect(Object.keys(usersImportMessages.kk).sort()).toEqual(ids)
    for (const l of ['en', 'ru', 'kk'] as const) for (const id of ids) expect(usersImportMessages[l][id]).toBeTruthy()
  })
  it('every one of the seven reason types has all three texts', () => {
    expect(USERS_IMPORT_REASON_TYPES).toHaveLength(7)
    for (const t of USERS_IMPORT_REASON_TYPES) for (const l of ['en', 'ru', 'kk'] as const) expect(usersImportMessages[l][`usersImport.reason.${t}`]).toBeTruthy()
  })
  it('U7b none of the seven reaches the unknown-reason fallback; a stranger does', () => {
    for (const t of USERS_IMPORT_REASON_TYPES) {
      for (const l of ['en', 'ru', 'kk'] as const) expect(usersReasonSentence(l, { type: t })).toBe(usersImportMessages[l][`usersImport.reason.${t}`])
    }
    expect(usersReasonSentence('en', { type: 'zzz' })).toBe('The row was refused (zzz).')
  })
})

describe('U8 the page in ru and kk', () => {
  it.each([
    ['ru', 'Импорт пользователей', 'Не заполнено обязательное значение. Заполните его.'],
    ['kk', 'Пайдаланушыларды импорттау', 'Міндетті мән бос. Толтырыңыз.'],
  ] as const)('%s: title and reason are localized, no raw ids', async (locale, title, reason) => {
    useUiLocaleStore.getState().setLocaleTransient(locale)
    clientMock.postRaw.mockResolvedValue({ dry_run: true, results: [refused(2, 'user_field_required', 'email')] })
    renderPage()
    expect(screen.getByText(title)).toBeInTheDocument()
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('users-import-check'))
    await screen.findByTestId('users-import-dry-run')
    expect(screen.getByTestId('datatable-row')).toHaveTextContent(reason)
    expect(document.body.textContent).not.toMatch(/usersImport\.|user_field_required/)
  })
})
