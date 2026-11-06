// @vitest-environment jsdom
/** L5, L7 — "My settings": the user picks the document layout (PUT /me/preferences), states, ru and kk. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { mySettingsMessages } from '../mySettingsMessages'
import MySettingsPage from '../MySettingsPage'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-1' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ get: vi.fn(), put: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))
const toastMock = vi.hoisted(() => ({ success: vi.fn(), error: vi.fn(), info: vi.fn(), warning: vi.fn() }))
vi.mock('@/hooks/useToast', () => ({ useToast: () => toastMock }))

const PREFS = '/api/v1/me/preferences'
const answer = (own: string | null, effective: string, tenant = 'row') => ({
  preferences: own ? { 'ui.document_layout': own } : {},
  effective: { 'ui.document_layout': effective },
  tenant_defaults: { 'ui.document_layout_default': tenant },
})

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={['/me/settings']}>
        <Routes>
          <Route path="/me/settings" element={<MySettingsPage />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  clientMock.get.mockReset()
  clientMock.put.mockReset()
  for (const m of Object.values(toastMock)) m.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

describe('L5 My settings', () => {
  it('shows a skeleton while loading, then the effective value with a thumbnail per layout', async () => {
    clientMock.get.mockResolvedValue(answer(null, 'row'))
    renderPage()
    expect(screen.getByTestId('my-settings-loading')).toBeInTheDocument()
    await screen.findByTestId('my-layout-picker')
    expect(screen.getByLabelText(/Row/)).toBeChecked()
    expect(screen.getByTestId('layout-thumb-row')).toBeInTheDocument()
    expect(screen.getByTestId('layout-thumb-tabs')).toBeInTheDocument()
    expect(screen.queryByTestId('my-settings-use-default')).toBeNull()
  })

  it('choosing Tabs and Save sends PUT /me/preferences and shows the success toast', async () => {
    clientMock.get.mockResolvedValue(answer(null, 'row'))
    clientMock.put.mockResolvedValue(answer('tabs', 'tabs'))
    renderPage()
    await screen.findByTestId('my-layout-picker')
    expect(screen.getByTestId('my-settings-save')).toBeDisabled()
    fireEvent.click(screen.getByLabelText(/Tabs/))
    fireEvent.click(screen.getByTestId('my-settings-save'))
    await waitFor(() => expect(clientMock.put).toHaveBeenCalledWith(PREFS, { preferences: { 'ui.document_layout': 'tabs' } }))
    await waitFor(() => expect(toastMock.success).toHaveBeenCalledWith(mySettingsMessages.en.saved))
  })

  it('a 422 shows the server text in a banner and the picker goes back to the saved value', async () => {
    clientMock.get.mockResolvedValue(answer(null, 'row'))
    clientMock.put.mockRejectedValue({ status: 422, message: 'x', details: { detail: 'Layout is not allowed.' } })
    renderPage()
    await screen.findByTestId('my-layout-picker')
    fireEvent.click(screen.getByLabelText(/Tabs/))
    fireEvent.click(screen.getByTestId('my-settings-save'))
    expect(await screen.findByText('Layout is not allowed.')).toBeInTheDocument()
    expect(screen.getByLabelText(/Row/)).toBeChecked()
    expect(toastMock.success).not.toHaveBeenCalled()
  })

  it('a failed read shows the load error with a retry', async () => {
    clientMock.get.mockRejectedValueOnce({ status: 500, message: 'x' })
    clientMock.get.mockResolvedValue(answer(null, 'row'))
    renderPage()
    const retry = await screen.findByRole('button', { name: 'Retry' })
    fireEvent.click(retry)
    await screen.findByTestId('my-layout-picker')
    expect(clientMock.get).toHaveBeenCalledTimes(2)
  })

  it('"Use the tenant default" sends null and appears only with an own choice', async () => {
    clientMock.get.mockResolvedValue(answer('tabs', 'tabs', 'row'))
    clientMock.put.mockResolvedValue(answer(null, 'row'))
    renderPage()
    await screen.findByTestId('my-layout-picker')
    expect(screen.getByLabelText(/Tabs/)).toBeChecked()
    fireEvent.click(screen.getByTestId('my-settings-use-default'))
    await waitFor(() => expect(clientMock.put).toHaveBeenCalledWith(PREFS, { preferences: { 'ui.document_layout': null } }))
  })

  it.each([['ru'], ['kk']] as const)('renders in %s', async (lang) => {
    useUiLocaleStore.getState().setLocaleTransient(lang)
    clientMock.get.mockResolvedValue(answer(null, 'row'))
    renderPage()
    await screen.findByTestId('my-layout-picker')
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(mySettingsMessages[lang].title)
    expect(screen.getByTestId('my-settings-save')).toHaveTextContent(mySettingsMessages[lang].save)
  })
})
