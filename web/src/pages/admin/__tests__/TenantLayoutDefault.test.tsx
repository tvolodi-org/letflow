// @vitest-environment jsdom
/** L6 — the tenant default of the document layout on the appearance screen. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import AppearanceSettingsPage from '../AppearanceSettingsPage'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-1' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ get: vi.fn(), put: vi.fn(), patch: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))
const toastMock = vi.hoisted(() => ({ success: vi.fn(), error: vi.fn(), info: vi.fn(), warning: vi.fn() }))
vi.mock('@/hooks/useToast', () => ({ useToast: () => toastMock }))

const answer = (tenant?: string) => ({
  preferences: {},
  effective: { 'ui.document_layout': tenant ?? 'row' },
  tenant_defaults: tenant ? { 'ui.document_layout_default': tenant } : {},
})

function renderPage(state: ReturnType<typeof accessState>) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={state}>
        <MemoryRouter initialEntries={['/admin/appearance']}>
          <Routes>
            <Route path="/admin/appearance" element={<AppearanceSettingsPage />} />
            <Route path="/instances" element={<div data-testid="redirected" />} />
          </Routes>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  for (const m of [...Object.values(clientMock), ...Object.values(toastMock)]) m.mockReset()
})
afterEach(() => cleanup())

describe('L6 tenant default layout', () => {
  it('without TenantSettingsManage the page redirects and the section is absent', async () => {
    clientMock.get.mockResolvedValue(answer())
    renderPage(accessState('taskWorker'))
    await screen.findByTestId('redirected')
    expect(screen.queryByTestId('tenant-layout-default')).toBeNull()
  })

  it('starts from tenant_defaults, falls back to row, and Save patches the flat key', async () => {
    clientMock.get.mockResolvedValue(answer('row'))
    clientMock.patch.mockResolvedValue({ tenant_id: 't', settings: {} })
    renderPage(accessState('platformAdmin'))
    await screen.findByTestId('tenant-layout-default')
    const section = await screen.findByTestId('tenant-layout-save')
    expect(section).toBeDisabled()
    fireEvent.click(screen.getByLabelText(/Tabs/))
    fireEvent.click(screen.getByTestId('tenant-layout-save'))
    await waitFor(() =>
      expect(clientMock.patch).toHaveBeenCalledWith('/api/v1/tenant/settings', { 'ui.document_layout_default': 'tabs' }),
    )
    await waitFor(() => expect(toastMock.success).toHaveBeenCalled())
  })

  it('a 422 shows the server text in a banner', async () => {
    clientMock.get.mockResolvedValue(answer('row'))
    clientMock.patch.mockRejectedValue({ status: 422, message: 'x', details: { detail: 'Not a known layout.' } })
    renderPage(accessState('platformAdmin'))
    await screen.findByTestId('tenant-layout-save')
    fireEvent.click(screen.getByLabelText(/Tabs/))
    fireEvent.click(screen.getByTestId('tenant-layout-save'))
    expect(await screen.findByText('Not a known layout.')).toBeInTheDocument()
    expect(toastMock.success).not.toHaveBeenCalled()
  })
})
