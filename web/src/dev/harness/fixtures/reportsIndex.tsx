/** Harness fixture of the Reports menu page (T-1874). Screen: reports-index (states default | empty | loading | error).
 *  Invented data only: the shipped "Asset list" report, a tenant-made asset report and a core-type report. */
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import ReportsIndexPage from '@/pages/entities/ReportsIndexPage'
import type { UserSession } from '@/types/api'
import type { HarnessScreen } from '../types'

const ME = '11111111-2222-4333-8444-555555555555'
const AUTH = {
  session: { token: 'h.' + btoa(JSON.stringify({ sub: ME })) + '.s', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, user_id: ME, permissions: ['EntitiesQuery'] },
}

const view = (id: string, entity_type: string, name: string) => ({
  id, entity_type, name, kind: 'report', columns: [], filter: [], sort: [], group_by: [], aggregates: [{ fn: 'count' }],
})

export const reportsIndexScreens: HarnessScreen[] = [
  {
    name: 'reports-index',
    routes: [
      {
        match: (p, m) => p === '/api/v1/entity-views' && m === 'GET',
        reply: (s) =>
          s === 'error'
            ? { status: 500, body: { title: 'internal_error', status: 500 } }
            : {
                status: 200,
                body: {
                  items:
                    s === 'empty'
                      ? []
                      : [
                          view('r1', 'assets_card', 'Asset list'),
                          view('r2', 'assets_commission', 'Commissions per month'),
                          view('r3', 'orders', 'Orders by status'),
                        ],
                },
              },
      },
      {
        match: (p, m) => p === '/api/v1/me/modules' && m === 'GET',
        reply: () => ({ status: 200, body: { installed_modules: [{ module_id: 'assets', version: '1' }] } }),
      },
    ],
    render: () => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <div className="lf-main">
            <main className="lf-content">
              <ReportsIndexPage />
            </main>
          </div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
]
