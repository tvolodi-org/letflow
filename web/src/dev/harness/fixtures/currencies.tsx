/** Harness fixtures for the Currencies admin screen (REQ-827, task T-1898). */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import CurrenciesPage from '@/pages/admin/currencies/CurrenciesPage'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const AUTH: AuthContextValue = {
  session: {
    token: 'harness.' + btoa(JSON.stringify({ sub: 'harness-id' })) + '.sig',
    tenant_id: 'harness-tenant',
    display_name: 'Harness Admin',
    loginSource: 'oidc',
    tenant_slug: 'harness',
    tenant_display_name: 'Harness Co',
    tenant_type: 'production',
  } as UserSession,
  isAuthenticated: true,
  isLoading: false,
  login: () => undefined,
  logout: () => undefined,
  setSession: () => undefined,
} as unknown as AuthContextValue

const ACCESS: AccessState = {
  status: 'ready',
  info: {
    roles: [],
    platform_tenant: false,
    permissions: ['CurrenciesManage', 'MyAccessRead'],
  },
}

const KZT = {
  code: 'KZT',
  numeric_code: '398',
  minor_units: 2,
  names: { en: 'Kazakhstani Tenge', ru: 'Казахстанский тенге', kk: 'Қазақстан теңгесі' },
  active: true,
}
const USD = {
  code: 'USD',
  numeric_code: '840',
  minor_units: 2,
  names: { en: 'US Dollar', ru: 'Доллар США', kk: 'АҚШ доллары' },
  active: false,
}
const EUR = {
  code: 'EUR',
  numeric_code: '978',
  minor_units: 2,
  names: { en: 'Euro', ru: 'Евро', kk: 'Еуро' },
  active: false,
}
const CNY = {
  code: 'CNY',
  numeric_code: '156',
  minor_units: 2,
  names: { en: 'Chinese Yuan', ru: 'Китайский юань', kk: 'Қытай юані' },
  active: false,
}

const BASE_CURRENCIES = [KZT, USD, EUR, CNY]
const SEARCH_RESULT = [KZT]

const routes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/currencies' && method === 'GET',
    reply: (state) => {
      if (state === 'error') {
        return { status: 500, body: { status: 500, message: 'internal_error', code: 'internal_error' } }
      }
      const currencies = state === 'empty' ? [] : BASE_CURRENCIES
      return { status: 200, body: { tenant_currency: 'KZT', currencies } }
    },
  },
  {
    match: (path, method) => path.startsWith('/api/v1/currencies/') && method === 'PUT',
    reply: () => ({ status: 200, body: { tenant_currency: 'KZT', currencies: BASE_CURRENCIES } }),
  },
]

/** Search-result fixture: API returns only one entry (simulates a "tenge" search match). */
const searchRoutes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/currencies' && method === 'GET',
    reply: () => ({ status: 200, body: { tenant_currency: 'KZT', currencies: SEARCH_RESULT } }),
  },
  {
    match: (path, method) => path.startsWith('/api/v1/currencies/') && method === 'PUT',
    reply: () => ({ status: 200, body: { tenant_currency: 'KZT', currencies: SEARCH_RESULT } }),
  },
]

function mkScreen(name: string, screenRoutes: FixtureRoute[]): HarnessScreen {
  return {
    name,
    routes: screenRoutes,
    render: ({ lang }): ReactElement => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <div className="lf-main">
            <main className="lf-content">
              <CurrenciesPage locale={lang} />
            </main>
          </div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  }
}

export const currenciesScreens: HarnessScreen[] = [
  mkScreen('currencies-list', routes),
  mkScreen('currencies-search-result', searchRoutes),
  mkScreen('currencies-error', routes),
  mkScreen('currencies-empty', routes),
  mkScreen('currencies-loading', routes),
]
