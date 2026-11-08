/** Harness fixtures of the runtime environment banner (T-1494): default text, custom label, 40-character label,
 *  and the empty label (no banner). The tenant config answer carries `env_label` (or not). */
import { useEffect, useState } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { fetchTenantConfig, resetTenantConfigCache } from '@/auth/tenantConfig'
import { TestEnvironmentBanner } from '@/components/layout/TestEnvironmentBanner'
import { TopBar } from '@/components/ui/TopBar'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant', tenant_type: 'test' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue

function bannerScreen(name: string, label: string | undefined): HarnessScreen {
  const routes: FixtureRoute[] = [
    {
      match: (path) => path === '/api/tenant-config',
      reply: () => ({
        status: 200,
        body: label === undefined ? { oidc_authority: 'a', client_id: 'c' } : { oidc_authority: 'a', client_id: 'c', env_label: label },
      }),
    },
  ]
  function Screen() {
    const [ready, setReady] = useState(false)
    useEffect(() => {
      resetTenantConfigCache()
      void fetchTenantConfig('harness').then(() => setReady(true))
    }, [])
    return (
      <AuthContext.Provider value={AUTH}>
        <div className="lf-main">
          <TopBar />
          <main className="lf-content">{ready ? <TestEnvironmentBanner /> : null}</main>
        </div>
      </AuthContext.Provider>
    )
  }
  return { name, routes, render: () => <Screen /> }
}

export const envBannerScreens: HarnessScreen[] = [
  bannerScreen('env-banner-default', undefined),
  bannerScreen('env-banner-custom', 'DEMO SANDBOX'),
  bannerScreen('env-banner-long', 'PARTNER PREVIEW ENVIRONMENT - NOT FOR LIVE'.slice(0, 40)),
  bannerScreen('env-banner-empty', ''),
]
