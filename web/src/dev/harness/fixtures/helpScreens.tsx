/** Harness fixtures of the static help pages and the Help link in a page header (task T-1560). Invented data only. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import AssetCardsPage from '@/modules/assets/AssetCardsPage'
import { AssetsIntlProvider } from '@/modules/assets/AssetsIntlProvider'
import { AssetsHelpLink } from '@/modules/assets/help/AssetsHelpLink'
import AssetsHelpPage from '@/modules/assets/help/AssetsHelpPage'
import CountsPage from '@/modules/stock/counts/CountsPage'
import CoreHelpPage from '@/pages/help/CoreHelpPage'
import { StockIntlProvider } from '@/modules/stock/StockIntlProvider'
import { StockHelpLink } from '@/modules/stock/help/StockHelpLink'
import StockHelpPage from '@/modules/stock/help/StockHelpPage'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const ORDERS = [
  { id: 'c2', number: 'CNT-0002', org_unit_id: 'u1', kind: 'selective', status: 'counting', planned_start: '2026-11-03T04:00:00Z', planned_end: '2026-11-04T12:00:00Z', chair_employee_id: 'e1', member_employee_ids: [], location_ids: [], note: null, issued_at: '2026-11-02T08:00:00Z' },
]

const routes: FixtureRoute[] = [
  { match: (path, method) => path === '/api/v1/entities/query' && method === 'POST', reply: () => ({ status: 200, body: { items: [], next_cursor: null } }) },
  { match: (path, method) => /\/counts$/.test(path) && method === 'GET', reply: (state) => ({ status: 200, body: { rows: state === 'empty' ? [] : ORDERS, next_cursor: null } }) },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

function withAuth(page: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider
        state={{ status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['AssetsRead', 'AssetsCardWrite', 'StockRead', 'StockCountOrder', 'StockCountRecord'] } }}
      >
        <div className="lf-main">
          <main className="lf-content">{page}</main>
        </div>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

export const helpScreens: HarnessScreen[] = [
  { name: 'help-assets-documents', initialPath: '/admin/assets/help/documents', routePattern: '/admin/assets/help/:topic', routes, render: () => withAuth(<AssetsHelpPage />) },
  { name: 'help-stock-counts', initialPath: '/admin/stock/help/counts', routePattern: '/admin/stock/help/:topic', routes, render: () => withAuth(<StockHelpPage />) },
  { name: 'help-core-long-lists', initialPath: '/help/longLists', routePattern: '/help/:topic', routes, render: () => withAuth(<CoreHelpPage />) },
  { name: 'help-unknown-topic', initialPath: '/admin/assets/help/nope', routePattern: '/admin/assets/help/:topic', routes, render: () => withAuth(<AssetsHelpPage />) },
  { name: 'help-link-stock-counts', initialPath: '/admin/stock/counts', routePattern: '/admin/stock/counts', routes, render: () => withAuth(<CountsPage />) },
  { name: 'help-link-assets-cards', initialPath: '/admin/assets/cards', routePattern: '/admin/assets/cards', routes, render: () => withAuth(<AssetCardsPage />) },
  // T-1872: the Help side panel, pre-opened over the real screen (the screen keeps its own Help button behind it).
  { name: 'help-panel-assets-cards', initialPath: '/admin/assets/cards', routePattern: '/admin/assets/cards', routes, render: () => withAuth(<><AssetCardsPage /><AssetsIntlProvider><AssetsHelpLink topic="cards" defaultOpen /></AssetsIntlProvider></>) },
  { name: 'help-panel-stock-counts', initialPath: '/admin/stock/counts', routePattern: '/admin/stock/counts', routes, render: () => withAuth(<><CountsPage /><StockIntlProvider><StockHelpLink topic="counts" defaultOpen /></StockIntlProvider></>) },
]
