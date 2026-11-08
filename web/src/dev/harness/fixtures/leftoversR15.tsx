/** Harness screens of GATE B rework R15 (T-1435): Users list with roles, storekeeper dashboard, denied admin page.
 *  Invented data only. */
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { P, ROLES, RequirePermission } from '@/auth/access'
import type { AccessState } from '@/auth/access/types'
import { lazy, Suspense } from 'react'
import { Route, Routes } from 'react-router-dom'
import { CatalogItemsIntlProvider } from '@/modules/catalog_items/CatalogItemsIntlProvider'
import { ItemDetails } from '@/modules/catalog_items/items/ItemDetails'
import UsersPage from '@/pages/admin/UsersPage'
import TenantDashboardPage from '@/pages/dashboard/TenantDashboardPage'
import type { HarnessScreen } from '../types'

const auth = {
  session: { tenant_id: 'harness-tenant', token: 't', display_name: 'Dauren Omarov', loginSource: null, tenant_slug: 'demo', tenant_display_name: 'Demo warehouse', tenant_type: 'production' },
  isAuthenticated: true,
  isLoading: false,
  loginSource: null,
  login: async () => undefined,
  logout: () => undefined,
  setSession: () => undefined,
  switchTenant: async () => 'ok',
  switchingToTenantSlug: null,
} as unknown as AuthContextValue

const access = (permissions: string[]): AccessState => ({ status: 'ready', info: { roles: [], platform_tenant: false, permissions } })

const USERS = [
  { id: 'u1', username: 'aigerim', display_name: 'Aigerim Sarsenova', email: 'aigerim@example.test', status: 'active', roles: [ROLES[0]] },
  { id: 'u2', username: 'dauren', display_name: 'Dauren Omarov', email: 'dauren@example.test', status: 'active', roles: [ROLES[ROLES.length - 1]] },
  { id: 'u3', username: 'saule', display_name: 'Saule Nurpeisova', email: 'saule@example.test', status: 'inactive', roles: [] },
].map(u => ({ ...u, auth_source: 'local', inserted_at: '2026-11-06T09:00:00Z', updated_at: '2026-11-06T09:00:00Z' }))

const ASSET_DEFS = ['assets_kind_change', 'assets_writeoff', 'assets_handover', 'assets_change', 'assets_reversal'].map((name, i) => ({
  id: `d${i}`, name, description: null, version: 1, status: 'ACTIVE',
}))

export const leftoversR15Screens: HarnessScreen[] = [
  {
    name: 'r15-users',
    routes: [
      { match: p => p === '/api/v1/identity/users', reply: () => ({ status: 200, body: { items: USERS, next_cursor: null, count: USERS.length } }) },
      { match: p => p === '/api/v1/identity/roles', reply: () => ({ status: 200, body: { items: [], next_cursor: null } }) },
    ],
    render: () => (
      <AuthContext.Provider value={auth}>
        <AccessStateProvider state={access([P.UsersGroupsRolesManage])}>
          <main className="lf-content"><UsersPage /></main>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
  {
    name: 'r15-dashboard',
    routes: [
      { match: p => p.startsWith('/api/v1/instances'), reply: () => ({ status: 200, body: { items: [], next_cursor: null, count: 0 } }) },
      { match: p => p.startsWith('/api/v1/tasks'), reply: () => ({ status: 200, body: { items: [], next_cursor: null, count: 3 } }) },
    ],
    render: () => (
      <AuthContext.Provider value={auth}>
        <AccessStateProvider state={access([])}>
          <main className="lf-content"><TenantDashboardPage /></main>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
  ...[
    { name: 'r15-dashboard-defs', items: ASSET_DEFS },
    { name: 'r15-dashboard-empty', items: [] },
  ].map(({ name, items }): HarnessScreen => ({
    name,
    routes: [
      { match: p => p.startsWith('/api/v1/definitions'), reply: () => ({ status: 200, body: { items, next_cursor: null, count: items.length } }) },
      { match: p => p.startsWith('/api/v1/instances'), reply: () => ({ status: 200, body: { items: [], next_cursor: null, count: 0 } }) },
      { match: p => p.startsWith('/api/v1/tasks'), reply: () => ({ status: 200, body: { items: [], next_cursor: null, count: 3 } }) },
    ],
    render: () => (
      <AuthContext.Provider value={auth}>
        <AccessStateProvider state={access([P.DefinitionsRead])}>
          <main className="lf-content"><TenantDashboardPage /></main>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  })),
  {
    name: 'r15-denied',
    routes: [{ match: p => p === '/api/v1/me/modules', reply: () => ({ status: 200, body: { installed_modules: [] } }) }],
    render: () => (
      <AuthContext.Provider value={auth}>
        <AccessStateProvider state={access(FLOOR_PERMS)}>
          <Routes>
            <Route element={<Suspense fallback={null}><AppShell /></Suspense>}>
              <Route path="*" element={<RequirePermission permission={P.UsersGroupsRolesManage}><UsersPage /></RequirePermission>} />
            </Route>
          </Routes>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
]

// Lazy: AppShell's import chain reads `window` at load, and the build test imports this registry under node.
const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

const FLOOR_PERMS = ['TasksRead', 'StockRead', 'InstancesRead']
const MOVES = [
  { entry_id: 'e1', posting_seq: 3, cause: 'stock_receipt', document_type: 'stock_receipt', document_number: 'PR-2611-0007', event_time: '2026-11-06T09:15:00Z' },
  { entry_id: 'e2', posting_seq: 2, cause: 'stock_issue', document_type: 'stock_issue', document_number: 'IS-2611-0003', event_time: '2026-11-05T11:30:00Z' },
  { entry_id: 'e3', posting_seq: 1, cause: 'stock_count', document_type: 'stock_count', document_number: null, event_time: '2026-11-04T08:00:00Z' },
]

export const leftoversR15ShellScreens: HarnessScreen[] = [
  {
    name: 'r15-storekeeper',
    routes: [
      { match: p => p === '/api/v1/me/modules', reply: () => ({ status: 200, body: { installed_modules: [] } }) },
      { match: p => p.startsWith('/api/v1/instances'), reply: () => ({ status: 200, body: { items: [], next_cursor: null, count: 0 } }) },
      { match: p => p.startsWith('/api/v1/tasks'), reply: () => ({ status: 200, body: { items: [], next_cursor: null, count: 3 } }) },
    ],
    render: () => (
      <AuthContext.Provider value={auth}>
        <AccessStateProvider state={access(FLOOR_PERMS)}>
          <Routes>
            <Route element={<Suspense fallback={null}><AppShell /></Suspense>}>
              <Route path="*" element={<TenantDashboardPage />} />
            </Route>
          </Routes>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
  {
    name: 'r15-history',
    routes: [
      { match: p => p === '/api/v1/modules/stock/balances' || p.endsWith('/balances'), reply: () => ({ status: 200, body: { next_cursor: null, rows: [] } }) },
      { match: p => p.endsWith('/movements'), reply: () => ({ status: 200, body: { next_cursor: null, rows: MOVES } }) },
    ],
    render: () => (
      <AuthContext.Provider value={auth}>
        <AccessStateProvider state={access(['StockRead'])}>
          <main className="lf-content">
            <CatalogItemsIntlProvider>
              <ItemDetails
                item={{ id: 'SKU-1', code: 'SKU-1', name: 'Cement M500', uomId: '', kind: 'material', tracking: 'none', active: true, externalRef: '' }}
                onBack={() => undefined}
              />
            </CatalogItemsIntlProvider>
          </main>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
]
