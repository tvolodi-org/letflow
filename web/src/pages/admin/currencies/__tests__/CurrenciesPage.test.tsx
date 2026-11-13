// @vitest-environment jsdom
/**
 * REQ-827 component tests: criteria 1 and 2.
 * Fake window.fetch; real react-query and CurrenciesPage run.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 'header.' + btoa(JSON.stringify({ sub: 'admin-id' })) + '.sig',
        display_name: 'Admin',
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: 'tenant-1',
        tenant_type: null,
      },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import CurrenciesPage from '@/pages/admin/currencies/CurrenciesPage'
import { renderWithAccess } from '@/auth/access/testing'

function kztEntry(active = true) {
  return {
    code: 'KZT',
    numeric_code: '398',
    minor_units: 2,
    names: { en: 'Kazakhstani Tenge', ru: 'Казахстанский тенге', kk: 'Қазақстан теңгесі' },
    active,
  }
}

function usdEntry(active = false) {
  return {
    code: 'USD',
    numeric_code: '840',
    minor_units: 2,
    names: { en: 'US Dollar', ru: 'Доллар США', kk: 'АҚШ доллары' },
    active,
  }
}

const BASE_REPLY = {
  tenant_currency: 'KZT',
  currencies: [kztEntry(true), usdEntry(false)],
}

interface Call {
  method: string
  url: string
  body: unknown
}
let calls: Call[]
let override: ((c: Call) => Response | undefined) | null

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

beforeEach(() => {
  calls = []
  override = null
  vi.spyOn(window, 'fetch').mockImplementation(async (input, init) => {
    const url = typeof input === 'string' ? input : (input as Request).url
    const method = (init?.method ?? (typeof input === 'string' ? 'GET' : (input as Request).method)).toUpperCase()
    const body = init?.body ? (JSON.parse(init.body as string) as unknown) : undefined
    const call: Call = { method, url, body }
    calls.push(call)
    const ov = override?.(call)
    if (ov) return ov
    if (url.endsWith('/api/v1/currencies') && method === 'GET') return json(200, BASE_REPLY)
    if (url.includes('/api/v1/currencies/') && method === 'PUT') return json(200, { ...BASE_REPLY, currencies: [kztEntry(true), usdEntry(true)] })
    return json(500, { status: 500, message: 'unexpected', code: 'unexpected' })
  })
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

function render() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <CurrenciesPage />
      </MemoryRouter>
    </QueryClientProvider>,
    'tenantAdmin',
  )
}

describe('REQ-827 criterion 1: list and interactions', () => {
  it('renders code, name in the UI language (en default) and a switch', async () => {
    render()
    await waitFor(() => expect(screen.getByTestId('currencies-table')).toBeInTheDocument())
    expect(screen.getByText('KZT', { selector: 'td' })).toBeInTheDocument()
    expect(screen.getByText('USD', { selector: 'td' })).toBeInTheDocument()
    // code is visible
    expect(screen.getAllByText('KZT').length).toBeGreaterThan(0)
    // en name
    expect(screen.getByText('Kazakhstani Tenge')).toBeInTheDocument()
    expect(screen.getByText('US Dollar')).toBeInTheDocument()
    // switches present
    expect(screen.getByTestId('switch-USD')).toBeInTheDocument()
  })

  it('typing "tenge" in the search keeps KZT row (en name match)', async () => {
    render()
    await waitFor(() => expect(screen.getByTestId('currencies-table')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('currencies-search'), { target: { value: 'tenge' } })
    expect(screen.getByText('KZT', { selector: 'td' })).toBeInTheDocument()
    expect(screen.queryByText('USD', { selector: 'td' })).toBeNull()
  })

  it('typing "теңге" in the search keeps KZT row (kk name match)', async () => {
    render()
    await waitFor(() => expect(screen.getByTestId('currencies-table')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('currencies-search'), { target: { value: 'теңге' } })
    expect(screen.getByText('KZT', { selector: 'td' })).toBeInTheDocument()
    expect(screen.queryByText('USD', { selector: 'td' })).toBeNull()
  })

  it('typing "KZT" in the search keeps KZT row (code match)', async () => {
    render()
    await waitFor(() => expect(screen.getByTestId('currencies-table')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('currencies-search'), { target: { value: 'KZT' } })
    expect(screen.getByText('KZT', { selector: 'td' })).toBeInTheDocument()
    expect(screen.queryByText('USD', { selector: 'td' })).toBeNull()
  })

  it('switching USD on sends PUT with active true', async () => {
    render()
    await waitFor(() => expect(screen.getByTestId('switch-USD')).toBeInTheDocument())
    const usdSwitch = screen.getByTestId('switch-USD').querySelector('input[type="checkbox"]') ?? screen.getByTestId('switch-USD')
    fireEvent.click(usdSwitch)
    await waitFor(() => {
      const put = calls.find((c) => c.method === 'PUT' && c.url.includes('/USD'))
      expect(put).toBeDefined()
      expect(put?.body).toEqual({ active: true })
    })
  })

  it('make tenant currency on USD sends PUT with active true and tenant_currency true; mark moves', async () => {
    render()
    await waitFor(() => expect(screen.getByTestId(`make-tenant-currency-USD`)).toBeInTheDocument())
    // Prepare server to reply with USD as tenant currency after the PUT
    const updatedReply = {
      tenant_currency: 'USD',
      currencies: [{ ...kztEntry(true) }, { ...usdEntry(true) }],
    }
    override = (c) => {
      if (c.method === 'PUT' && c.url.includes('/USD')) return json(200, updatedReply)
      if (c.method === 'GET' && c.url.endsWith('/api/v1/currencies')) return json(200, updatedReply)
    }
    fireEvent.click(screen.getByTestId('make-tenant-currency-USD'))
    await waitFor(() => {
      const put = calls.find((c) => c.method === 'PUT' && c.url.includes('/USD'))
      expect(put).toBeDefined()
      expect(put?.body).toEqual({ active: true, tenant_currency: true })
    })
    // After re-fetch (invalidateQueries), USD shows the mark
    await waitFor(() =>
      expect(screen.getByTestId('tenant-currency-mark-USD')).toBeInTheDocument(),
    )
  })
})

describe('REQ-827 criterion 2: tenant currency switch disabled and 422 error text', () => {
  it("tenant currency's switch is disabled with the hint", async () => {
    render()
    await waitFor(() => expect(screen.getByTestId('currencies-table')).toBeInTheDocument())
    const kztSwitchWrapper = screen.getByTestId('switch-KZT')
    // disabled attribute on the wrapper element
    const checkbox = kztSwitchWrapper.querySelector('input[type="checkbox"]')
    expect(checkbox).not.toBeNull()
    expect(checkbox).toBeDisabled()
    expect(kztSwitchWrapper).toHaveAttribute('title')
    expect(kztSwitchWrapper.getAttribute('title')).toMatch(/always on|всегда активна|әрқашан белсенді/i)
  })

  it('422 currency_is_tenant_currency shows its text in en', async () => {
    override = (c) => {
      if (c.method === 'PUT' && c.url.includes('/USD')) {
        return json(422, { status: 422, message: 'currency_is_tenant_currency', code: 'currency_is_tenant_currency' })
      }
    }
    render()
    await waitFor(() => expect(screen.getByTestId('make-tenant-currency-USD')).toBeInTheDocument())
    fireEvent.click(screen.getByTestId('make-tenant-currency-USD'))
    await waitFor(() =>
      expect(screen.getByTestId('switch-error')).toHaveTextContent(
        'This is the tenant currency and cannot be switched off.',
      ),
    )
  })

  it('422 currency_is_tenant_currency shows its text in ru', async () => {
    // Switch locale to ru
    const { useUiLocaleStore } = await import('@/i18n/uiLocaleStore')
    useUiLocaleStore.getState().setLocale('ru')
    override = (c) => {
      if (c.method === 'PUT' && c.url.includes('/USD')) {
        return json(422, { status: 422, message: 'currency_is_tenant_currency', code: 'currency_is_tenant_currency' })
      }
    }
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    renderWithAccess(
      <QueryClientProvider client={qc}>
        <MemoryRouter>
          <CurrenciesPage />
        </MemoryRouter>
      </QueryClientProvider>,
      'tenantAdmin',
    )
    await waitFor(() => expect(screen.getByTestId('make-tenant-currency-USD')).toBeInTheDocument())
    fireEvent.click(screen.getByTestId('make-tenant-currency-USD'))
    await waitFor(() =>
      expect(screen.getByTestId('switch-error')).toHaveTextContent(
        'Это валюта организации, её нельзя отключить.',
      ),
    )
    useUiLocaleStore.getState().setLocale('en')
  })

  it('422 currency_is_tenant_currency shows its text in kk', async () => {
    const { useUiLocaleStore } = await import('@/i18n/uiLocaleStore')
    useUiLocaleStore.getState().setLocale('kk')
    override = (c) => {
      if (c.method === 'PUT' && c.url.includes('/USD')) {
        return json(422, { status: 422, message: 'currency_is_tenant_currency', code: 'currency_is_tenant_currency' })
      }
    }
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    renderWithAccess(
      <QueryClientProvider client={qc}>
        <MemoryRouter>
          <CurrenciesPage />
        </MemoryRouter>
      </QueryClientProvider>,
      'tenantAdmin',
    )
    await waitFor(() => expect(screen.getByTestId('make-tenant-currency-USD')).toBeInTheDocument())
    fireEvent.click(screen.getByTestId('make-tenant-currency-USD'))
    await waitFor(() =>
      expect(screen.getByTestId('switch-error')).toHaveTextContent(
        'Бұл ұйым валютасы, оны өшіруге болмайды.',
      ),
    )
    useUiLocaleStore.getState().setLocale('en')
  })
})

describe('REQ-827 gui states: lede, empty text, toast', () => {
  it('renders eyebrow and lede from the catalog', async () => {
    render()
    await waitFor(() => expect(screen.getByTestId('currencies-table')).toBeInTheDocument())
    expect(screen.getByText(/Switch the currencies your organisation works with/)).toBeInTheDocument()
    expect(screen.getByText('Administration')).toBeInTheDocument()
  })

  it('search with no match shows the empty text, not an empty table', async () => {
    render()
    await waitFor(() => expect(screen.getByTestId('currencies-table')).toBeInTheDocument())
    fireEvent.change(screen.getByTestId('currencies-search'), { target: { value: 'zzzz' } })
    expect(screen.getByText('No currencies matched the search.')).toBeInTheDocument()
  })

  it('a successful switch shows the success toast', async () => {
    const { ToastContainer } = await import('@/components/ui/Toast')
    const { clearAllToasts } = await import('@/hooks/useToast')
    clearAllToasts()
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    renderWithAccess(
      <QueryClientProvider client={qc}>
        <MemoryRouter>
          <CurrenciesPage />
          <ToastContainer />
        </MemoryRouter>
      </QueryClientProvider>,
      'tenantAdmin',
    )
    await waitFor(() => expect(screen.getByTestId('switch-USD')).toBeInTheDocument())
    fireEvent.click(screen.getByTestId('switch-USD'))
    await waitFor(() => expect(screen.getByTestId('toast-message')).toHaveTextContent('Currency saved.'))
    clearAllToasts()
  })
})
