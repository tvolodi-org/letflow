// @vitest-environment jsdom
/** W3, W7, W7b, W8, W8b (T-1950): the consent dialog of "Report a problem". */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { clearAllToasts, getToastSnapshot } from '@/hooks/useToast'
import { recordAction, recordRequest, resetCapture } from '@/lib/problemReport/capture'
import { problemReportsApi } from '@/api/problemReports'
import { ReportProblemDialog } from '../ReportProblemDialog'
import { reportProblemMessages as M } from '../reportProblemMessages'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 't', display_name: 'Aigerim Sarsenova', tenant_display_name: 'Demo Holding', tenant_id: 'tid' } }),
}))
vi.mock('@/api/problemReports', () => ({ problemReportsApi: { submit: vi.fn() } }))

const submit = vi.mocked(problemReportsApi.submit)

function mount(crash: Error | null = null, onClose = vi.fn()) {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={accessState('platformAdmin')}>
        <ReportProblemDialog crash={crash} onClose={onClose} />
      </AccessStateProvider>
    </QueryClientProvider>,
  )
  return onClose
}

beforeEach(() => {
  resetCapture()
  clearAllToasts()
  submit.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
  recordAction('nav', '/admin/assets/documents')
  recordAction('click', 'assets-commission-btn')
  recordRequest(null, 'GET', '/api/v1/assets/documents/123456', 500, 'trace-abc')
})
afterEach(() => cleanup())

const confirm = () => screen.getByTestId('report-dialog-confirm')

describe('consent (W3)', () => {
  it('Send is disabled without text, and without the tick; nothing is posted', async () => {
    mount()
    expect(confirm()).toBeDisabled()
    await userEvent.type(screen.getByTestId('report-text'), 'It fails')
    expect(confirm()).toBeDisabled()
    await userEvent.click(confirm())
    expect(submit).not.toHaveBeenCalled()
    await userEvent.click(screen.getByTestId('report-consent'))
    expect(confirm()).toBeEnabled()
  })
})

describe('what is sent (W7)', () => {
  it('the preview is exactly the posted body, masked; the server-adds list shows who sends', async () => {
    submit.mockResolvedValue({ id: '1', number: 'SR-7', received_at: 'x' })
    mount()
    await userEvent.type(screen.getByTestId('report-text'), 'Commission fails, mail ivan.petrov@example.kz')
    await userEvent.click(screen.getByTestId('report-consent'))
    const preview = screen.getByTestId('report-preview').textContent ?? ''
    expect(preview).toContain('[email]')
    expect(preview).not.toContain('ivan.petrov@')
    await userEvent.click(confirm())
    await waitFor(() => expect(submit).toHaveBeenCalledTimes(1))
    expect(submit.mock.calls[0][0]).toEqual(JSON.parse(preview))
    expect(submit.mock.calls[0][0].consent).toBe(true)
    const adds = screen.getByTestId('report-server-adds')
    expect(adds).toHaveTextContent('Aigerim Sarsenova')
    expect(adds).toHaveTextContent('Demo Holding')
    expect(adds).toHaveTextContent('PLATFORM_ADMIN')
    const summary = screen.getByTestId('report-summary')
    expect(summary).toHaveTextContent('2 recent actions')
    expect(summary).toHaveTextContent('1 recent requests, 1 with errors')
  })

  it('W7b: a click made after the dialog opened is not in the posted body', async () => {
    submit.mockResolvedValue({ id: '1', number: 'SR-7', received_at: 'x' })
    mount()
    recordAction('click', 'late-click')
    await userEvent.type(screen.getByTestId('report-text'), 'x')
    await userEvent.click(screen.getByTestId('report-consent'))
    await userEvent.click(confirm())
    await waitFor(() => expect(submit).toHaveBeenCalled())
    expect(JSON.stringify(submit.mock.calls[0][0])).not.toContain('late-click')
  })
})

describe('write errors and success (W8)', () => {
  it.each([
    [{ status: 422 }, M.en.errInvalid],
    [{ status: 429 }, M.en.errTooMany],
    [{ status: 503 }, M.en.errUnavailable],
    [new TypeError('Failed to fetch'), M.en.errGeneric],
  ])('%j shows the message, keeps the text, and Send works again', async (failure, message) => {
    submit.mockRejectedValue(failure)
    mount()
    await userEvent.type(screen.getByTestId('report-text'), 'It fails')
    await userEvent.click(screen.getByTestId('report-consent'))
    await userEvent.click(confirm())
    expect(await screen.findByTestId('report-dialog-error')).toHaveTextContent(message)
    expect(screen.getByTestId('report-text')).toHaveValue('It fails')
    await waitFor(() => expect(confirm()).toBeEnabled())
    await userEvent.click(confirm())
    await waitFor(() => expect(submit).toHaveBeenCalledTimes(2))
  })

  it('W8b: success closes the dialog and shows a toast with the number', async () => {
    submit.mockResolvedValue({ id: '1', number: 'SR-7', received_at: 'x' })
    const onClose = mount()
    await userEvent.type(screen.getByTestId('report-text'), 'It fails')
    await userEvent.click(screen.getByTestId('report-consent'))
    await userEvent.click(confirm())
    await waitFor(() => expect(onClose).toHaveBeenCalled())
    const toast = getToastSnapshot()[0]
    expect(toast.variant).toBe('success')
    expect(toast.message).toContain('SR-7')
  })
})

describe('crash prefill', () => {
  it('pre-fills the text and puts the crash into the body', async () => {
    mount(new Error('boom 12345'))
    expect(screen.getByTestId('report-text')).toHaveValue(M.en.crashPrefill)
    const body = JSON.parse(screen.getByTestId('report-preview').textContent ?? '')
    expect(body.context.crash).toEqual({ name: 'Error', message: 'boom 12345' })
    expect(screen.getByTestId('report-summary')).toHaveTextContent('Crash: Error')
  })
})
