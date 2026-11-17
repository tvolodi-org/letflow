/** Harness fixtures of the stock workbook button on the Balances screen (REQ-866): during the download and the two refusals. */
import { useEffect, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import BalancesPage from '@/modules/stock/register/BalancesPage'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'
import { stockScreens } from './stock'

const base = stockScreens[0]?.routes ?? []

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

/** Harness only: clicks the workbook button once it exists and is not disabled. */
function ClickWorkbook({ children }: { children: ReactElement }): ReactElement {
  useEffect(() => {
    const id = window.setInterval(() => {
      const el = document.querySelector<HTMLButtonElement>('[data-testid="stock-workbook-button"]')
      if (el && !el.disabled) {
        el.click()
        window.clearInterval(id)
      }
    }, 20)
    return () => window.clearInterval(id)
  }, [])
  return children
}

const page = (
  <AuthContext.Provider value={AUTH}>
    <div className="lf-main">
      <main className="lf-content">
        <ClickWorkbook>
          <BalancesPage />
        </ClickWorkbook>
      </main>
    </div>
  </AuthContext.Provider>
)

const workbook = (reply: FixtureRoute['reply'], pending = false): FixtureRoute[] => [
  ...base,
  { match: (path, method) => path === '/api/v1/modules/stock/stock-workbook' && method === 'GET', pending, reply },
]

export const stockWorkbookScreens: HarnessScreen[] = [
  { name: 'stock-workbook-busy', routes: workbook(() => ({ status: 200, body: {} }), true), render: () => page },
  {
    name: 'stock-workbook-too-large',
    routes: workbook(() => ({ status: 422, body: { title: 'request refused', status: 422, reason: 'workbook_too_large' } })),
    render: () => page,
  },
  { name: 'stock-workbook-no-access', routes: workbook(() => ({ status: 404, body: { title: 'not found', status: 404 } })), render: () => page },
]
