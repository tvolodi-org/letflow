/** Harness fixture of T-2750: the Register Tenant screen with its note that the process creates the realm
 *  and the first administrator (no per-tenant infra text). The page makes no request before submit. */
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import RegisterTenantPage from '@/pages/admin/onboarding/RegisterTenantPage'
import type { UserSession } from '@/types/api'
import type { HarnessScreen } from '../types'

const AUTH = {
  session: { token: 'harness', display_name: 'Operator' } as unknown as UserSession,
} as unknown as AuthContextValue

export const registerTenantPageScreens: HarnessScreen[] = [
  {
    name: 'register-tenant-page',
    initialPath: '/admin/onboarding/new',
    routePattern: '/admin/onboarding/new',
    routes: [],
    render: () => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={accessState('platformAdmin')}>
          <RegisterTenantPage />
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
]
