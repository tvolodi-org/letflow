// @vitest-environment jsdom
/** T-2403 — the "Company name and time zone" section on the appearance screen. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import { companySettingsMessages } from '../companySettingsMessages'
import { CompanyNameTimezone } from '../CompanyNameTimezone'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-1' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ get: vi.fn(), put: vi.fn(), patch: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))
const toastMock = vi.hoisted(() => ({ success: vi.fn(), error: vi.fn(), info: vi.fn(), warning: vi.fn() }))
vi.mock('@/hooks/useToast', () => ({ useToast: () => toastMock }))

function renderIt() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={accessState('tenantAdmin')}>
        <CompanyNameTimezone />
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  for (const m of [...Object.values(clientMock), ...Object.values(toastMock)]) m.mockReset()
  clientMock.get.mockResolvedValue({ tenant_id: 't', app_name: 'Old Co', timezone: 'Asia/Almaty' })
})
afterEach(() => cleanup())

describe('company name and time zone', () => {
  it('shows the effective values and saves both through the PATCH', async () => {
    clientMock.patch.mockResolvedValue({ tenant_id: 't', settings: {} })
    renderIt()
    const input = (await screen.findByTestId('company-name-input')) as HTMLInputElement
    expect(input.value).toBe('Old Co')
    expect(screen.getByTestId('company-settings-save')).toBeDisabled()
    fireEvent.change(input, { target: { value: 'New Co' } })
    fireEvent.click(screen.getByTestId('company-settings-save'))
    await waitFor(() =>
      expect(clientMock.patch).toHaveBeenCalledWith('/api/v1/tenant/settings', { app_name: 'New Co', timezone: 'Asia/Almaty' }),
    )
    await waitFor(() => expect(toastMock.success).toHaveBeenCalled())
  })

  it('refuses an empty or over-long name on the screen and sends nothing', async () => {
    renderIt()
    const input = await screen.findByTestId('company-name-input')
    fireEvent.change(input, { target: { value: '   ' } })
    expect(screen.getByText(companySettingsMessages.en.nameError)).toBeInTheDocument()
    expect(screen.getByTestId('company-settings-save')).toBeDisabled()
    fireEvent.change(input, { target: { value: 'x'.repeat(101) } })
    expect(screen.getByTestId('company-settings-save')).toBeDisabled()
    expect(clientMock.patch).not.toHaveBeenCalled()
  })

  it('shows the server message for a refused value', async () => {
    clientMock.patch.mockRejectedValue({ message: 'x', details: { detail: 'timezone must be an IANA time zone name' } })
    renderIt()
    const input = await screen.findByTestId('company-name-input')
    fireEvent.change(input, { target: { value: 'Other' } })
    fireEvent.click(screen.getByTestId('company-settings-save'))
    expect(await screen.findByText('timezone must be an IANA time zone name')).toBeInTheDocument()
  })

  it('has the same keys in en, ru and kk', () => {
    const keys = Object.keys(companySettingsMessages.en).sort()
    expect(Object.keys(companySettingsMessages.ru).sort()).toEqual(keys)
    expect(Object.keys(companySettingsMessages.kk).sort()).toEqual(keys)
  })
})
