// @vitest-environment jsdom
/** T-1690: accessibility pass. Users import: announced answer, reason for the disabled confirm button.
 *  Shared Button: aria-describedby. Source scans: no `lf-faint` text (ink-faint is exempt from the contrast pairs,
 *  docs/design-system/accessibility.md) on the rollout screen, a named region for its detail, a persistent live
 *  region for the reset-password answer. */
import { readFileSync } from 'node:fs'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { Button } from '@/components/ui/Button'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { clientMock } from './usersImportMocks'
import { chooseFile, ok, refused, renderPage, xlsxFile } from './usersImportKit'

expect.extend(jestDomMatchers)

vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: (await import('./usersImportMocks')).clientMock }))
vi.mock('@/api/useTenantScopedQueryKeys', () => ({
  useTenantScopedQueryKeys: () => ({ admin: { users: (f?: object) => ['tenant', 't1', 'admin', 'users', f ?? {}] } }),
}))

beforeEach(() => {
  clientMock.postRaw.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

const read = (rel: string) => readFileSync(new URL(rel, import.meta.url), 'utf8')

describe('T-1690 accessibility pass', () => {
  it('A1 Button forwards aria-describedby', () => {
    render(<Button variant="primary" aria-describedby="why" disabled>Go</Button>)
    expect(screen.getByRole('button', { name: 'Go' })).toHaveAttribute('aria-describedby', 'why')
  })

  it('A2 users import: a dirty check announces counts and explains the disabled confirm button', async () => {
    clientMock.postRaw.mockResolvedValue({ dry_run: true, results: [ok(2, 'created'), refused(3, 'user_field_required', 'email')] })
    renderPage()
    expect(screen.getByTestId('users-import-announce')).toHaveTextContent('')
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('users-import-check'))
    await waitFor(() => expect(screen.getByTestId('users-import-why')).toBeInTheDocument())
    expect(screen.getByTestId('users-import-announce')).toHaveTextContent(/Row counts: .*1.*0.*1/)
    expect(screen.getByTestId('users-import-announce')).toHaveAttribute('role', 'status')
    expect(screen.getByTestId('users-import-confirm')).toBeDisabled()
    expect(screen.getByTestId('users-import-confirm')).toHaveAttribute('aria-describedby', screen.getByTestId('users-import-why').id)
  })

  it('A3 users import: the announcement is in ru and kk', async () => {
    for (const [loc, word] of [['ru', 'Количество строк'], ['kk', 'Жолдар саны']] as const) {
      useUiLocaleStore.getState().setLocaleTransient(loc)
      clientMock.postRaw.mockResolvedValue({ dry_run: true, results: [ok(2, 'created')] })
      renderPage()
      chooseFile(xlsxFile())
      fireEvent.click(screen.getByTestId('users-import-check'))
      await waitFor(() => expect(screen.getByTestId('users-import-announce')).toHaveTextContent(word))
      cleanup()
    }
  })

  it('A4 rollout screen: no ink-faint text, detail is a named region', () => {
    const src = read('../../module-rollouts/ModuleRolloutsPage.tsx')
    expect(src).not.toContain('lf-faint')
    expect(src).toContain('role="region" aria-label={rollout.module_id}')
  })

  it('A5 reset-password answer sits in an always-rendered live region', () => {
    const src = read('../../UserDetailPage.tsx')
    expect(src).toMatch(/aria-live="polite" data-testid="admin-user-reset-live"/)
  })
})
