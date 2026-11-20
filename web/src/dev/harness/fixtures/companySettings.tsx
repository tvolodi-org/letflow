/** Harness fixtures of the "Company name and time zone" section (task T-2403). Invented data only. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { CompanyNameTimezone } from '@/pages/admin/CompanyNameTimezone'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const routes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/tenant/settings' && method === 'GET',
    reply: () => ({ status: 200, body: { tenant_id: 'harness-tenant', app_name: 'Steppe Supply LLP', timezone: 'Asia/Almaty' } }),
  },
]

const AUTH = { session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession, isAuthenticated: true } as unknown as AuthContextValue
const ACCESS = { status: 'ready' as const, info: { roles: [], platform_tenant: false, permissions: ['TenantSettingsManage'] } }

function withAuth(page: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={ACCESS}>
        <div className="lf-main">
          <main className="lf-content">{page}</main>
        </div>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

export const companySettingsScreens: HarnessScreen[] = [
  { name: 'company-name-timezone', routes, render: () => withAuth(<CompanyNameTimezone />) },
]
