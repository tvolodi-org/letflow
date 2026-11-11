// @vitest-environment jsdom
/** I1-I3: T-1732 / REQ-809, the sign-in column of the users import result (answer shape of REQ-808). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { signInMessages } from '../../signInMessages'
import { clientMock } from './usersImportMocks'
import { chooseFile, ok, renderPage, xlsxFile } from './usersImportKit'

expect.extend(jestDomMatchers)

vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: (await import('./usersImportMocks')).clientMock }))
vi.mock('@/api/useTenantScopedQueryKeys', () => ({
  useTenantScopedQueryKeys: () => ({ admin: { users: (f?: object) => ['tenant', 't1', 'admin', 'users', f ?? {}] } }),
}))

beforeEach(() => {
  clientMock.postRaw.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(cleanup)

async function runImport(answer: unknown) {
  clientMock.postRaw.mockResolvedValueOnce({ dry_run: true, results: [ok(2, 'created'), ok(3, 'created')] }).mockResolvedValueOnce(answer)
  renderPage()
  chooseFile(xlsxFile())
  fireEvent.click(screen.getByTestId('users-import-check'))
  await waitFor(() => expect(screen.getByTestId('users-import-confirm')).toBeEnabled())
  fireEvent.click(screen.getByTestId('users-import-confirm'))
  await screen.findByTestId('users-import-summary')
}

describe('REQ-809 import sign-in column', () => {
  it('I1 shows the password of a created row and the reason of a refused one', async () => {
    await runImport({
      applied: true,
      results: [
        { ...ok(2, 'created'), sign_in: { created: true, temporary_password: 'Tmp-Pass-1' } },
        { ...ok(3, 'created'), sign_in: { created: false, reason: 'no_email' } },
        { ...ok(4, 'unchanged') },
      ],
    })
    expect(screen.getByTestId('users-import-sign-in-password')).toHaveTextContent('Tmp-Pass-1')
    expect(screen.getByTestId('users-import-sign-in-reason')).toHaveTextContent(signInMessages.en.reasons.no_email)
    expect(screen.getByTestId('users-import-sign-in-note')).toBeInTheDocument()
  })

  it('I2 an answer without sign_in has no column and no note', async () => {
    await runImport({ applied: true, results: [ok(2, 'created'), ok(3, 'created')] })
    expect(screen.queryByText('Sign-in')).toBeNull()
    expect(screen.queryByTestId('users-import-sign-in-note')).toBeNull()
    expect(screen.queryByTestId('users-import-hide-passwords')).toBeNull()
  })

  it('I3 Hide passwords removes every password from the page', async () => {
    await runImport({
      applied: true,
      results: [
        { ...ok(2, 'created'), sign_in: { created: true, temporary_password: 'Tmp-Pass-1' } },
        { ...ok(3, 'created'), sign_in: { created: false, reason: 'not_attempted' } },
      ],
    })
    fireEvent.click(screen.getByTestId('users-import-hide-passwords'))
    expect(screen.queryByTestId('users-import-sign-in-password')).toBeNull()
    expect(document.body.textContent).not.toContain('Tmp-Pass-1')
    expect(screen.getByTestId('users-import-sign-in-reason')).toHaveTextContent(signInMessages.en.reasons.not_attempted)
    expect(screen.queryByTestId('users-import-hide-passwords')).toBeNull()
  })
})
