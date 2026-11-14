// @vitest-environment jsdom
/** W9, W9b, W9c (T-1950): a crash of the shell shows the localised panel with "Report this problem". */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { resetCapture } from '@/lib/problemReport/capture'
import { AuthenticatedShellRoot } from '../AuthenticatedShellRoot'
import { reportProblemMessages as M } from '../reportProblemMessages'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 't', display_name: 'U', tenant_id: 'tid' }, switchingToTenantSlug: null }),
}))
vi.mock('@/hooks/useLayoutPrefs', () => ({ LayoutPrefsProvider: ({ children }: { children: unknown }) => children }))
vi.mock('@/api/problemReports', () => ({ problemReportsApi: { submit: vi.fn() } }))

let crashing = true
vi.mock('../AppShell', () => ({
  AppShell: () => {
    if (crashing) throw new Error('boom 12345')
    return <div data-testid="app-shell-double">shell</div>
  },
}))

function mount() {
  render(
    <QueryClientProvider client={new QueryClient()}>
      <AccessStateProvider state={accessState('platformAdmin')}>
        <AuthenticatedShellRoot />
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  crashing = true
  resetCapture()
  useUiLocaleStore.getState().setLocaleTransient('en')
  vi.spyOn(console, 'error').mockImplementation(() => undefined)
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('ShellCrashPanel', () => {
  it('W9: keeps the e2e testid, reports with the crash pre-filled, and resets', async () => {
    mount()
    expect(screen.getByTestId('error-boundary-panel')).toBeInTheDocument()
    await userEvent.click(screen.getByTestId('error-boundary-report'))
    expect(screen.getByTestId('report-dialog')).toBeInTheDocument()
    expect(screen.getByTestId('report-text')).toHaveValue(M.en.crashPrefill)
    const body = JSON.parse(screen.getByTestId('report-preview').textContent ?? '')
    expect(body.context.crash).toEqual({ name: 'Error', message: 'boom 12345' })
    await userEvent.click(screen.getByTestId('report-dialog-cancel'))
    crashing = false
    await userEvent.click(screen.getByTestId('error-boundary-reset'))
    expect(screen.getByTestId('app-shell-double')).toBeInTheDocument()
  })

  it('W9b: texts follow the UI language', () => {
    useUiLocaleStore.getState().setLocaleTransient('ru')
    mount()
    expect(screen.getByText(M.ru.crashTitle)).toBeInTheDocument()
    expect(screen.getByTestId('error-boundary-report')).toHaveTextContent(M.ru.crashButton)
  })

  it('W9c: the DEV details keep their summary and pre (what the e2e helper clicks and reads)', () => {
    mount()
    const details = screen.getByTestId('error-boundary-details')
    expect(details.querySelector('summary')).toHaveTextContent(M.en.crashDetails)
    expect(details.querySelector('pre')).toHaveTextContent('boom 12345')
  })
})
