/** Harness fixtures of GATE B rework R7 (T-1399). Invented data only: the Movements screen with a document number
 *  and server-length quantities (9 decimals), and the top bar with the language menu open under the TEST banner. */
import { useEffect } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import MovementsPage from '@/modules/stock/register/MovementsPage'
import { TestEnvironmentBanner } from '@/components/layout/TestEnvironmentBanner'
import { LanguageSwitcher } from '@/components/ui/LanguageSwitcher'
import { TopBar } from '@/components/ui/TopBar'
import { UI_LOCALES, UI_LOCALE_LABELS, useUiLocale, useUiLocaleStore } from '@/i18n/uiLocaleStore'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const MOVEMENTS = [
  {
    entry_id: 'r7-1', posting_seq: 1042, cause: 'receipt', document_type: 'stock_receipt', document_id: 'doc-r7-1',
    document_number: 'RCP-2026-000001', event_time: '2026-11-05T11:24:00Z',
    legs: [{ leg_no: 1, quantity: '40.000000000', unit_ref: 'm1', sku: 'i1', location: 'l1', org_unit: 'u1', responsible: null, lot: null }],
  },
  {
    entry_id: 'r7-2', posting_seq: 1043, cause: 'issue', document_type: 'stock_issue', document_id: 'doc-r7-2',
    document_number: 'ISS-2026-000004', event_time: '2026-11-05T12:00:00Z',
    legs: [{ leg_no: 1, quantity: '-12.500000000', unit_ref: 'm1', sku: 'i1', location: 'l1', org_unit: 'u1', responsible: null, lot: null }],
  },
]

const routes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: () => ({ status: 200, body: { items: [], next_cursor: null } }),
  },
  {
    match: (path, method) => path === '/api/v1/modules/stock/movements' && method === 'GET',
    reply: (state) => ({ status: 200, body: { next_cursor: null, rows: state === 'empty' ? [] : MOVEMENTS } }),
  },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant', tenant_type: 'test' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

function BannerBar() {
  const locale = useUiLocale()
  useEffect(() => {
    const frame = requestAnimationFrame(() => document.querySelector<HTMLElement>('[data-testid="language-switcher-trigger"]')?.click())
    return () => cancelAnimationFrame(frame)
  }, [])
  const setLocale = useUiLocaleStore((s) => s.setLocale)
  return (
    <div className="lf-main">
      <TopBar
        end={
          <LanguageSwitcher
            locales={UI_LOCALES.map((code) => ({ code, label: UI_LOCALE_LABELS[code] }))}
            current={locale}
            onChange={(code) => setLocale(code as (typeof UI_LOCALES)[number])}
          />
        }
      />
      <main className="lf-content">
        <TestEnvironmentBanner />
      </main>
    </div>
  )
}

export const stockR7Screens: HarnessScreen[] = [
  {
    name: 'stock-r7-movements',
    routes,
    render: () => (
      <AuthContext.Provider value={AUTH}>
        <div className="lf-main">
          <main className="lf-content">
            <MovementsPage />
          </main>
        </div>
      </AuthContext.Provider>
    ),
  },
  {
    name: 'stock-r7-banner-menu',
    routes: [],
    render: () => (
      <AuthContext.Provider value={AUTH}>
        <BannerBar />
      </AuthContext.Provider>
    ),
  },
]
