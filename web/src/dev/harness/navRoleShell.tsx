/** One sidebar role screen (T-1522): the real AppShell and the real route tree (`appRoutes`, guards included) for a role's
 *  access set. `?at=/some/path` picks the page shown in the content area, so a walk can open every visible entry's page. */
import { useEffect } from 'react'
import { useRoutes } from 'react-router-dom'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ERROR_STATE, LOADING_STATE } from '@/auth/access/fixtures'
import type { AccessState } from '@/auth/access/types'
import { AppShell } from '@/components/layout/AppShell'
import { appRoutes } from '@/router'
import type { HarnessState } from './types'
import { NAV_ROLE_PERMISSIONS, type NavRole } from './navRoleAccess'

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

function accessFor(role: NavRole, state: HarnessState): AccessState {
  if (state === 'loading') return LOADING_STATE
  if (state === 'error') return ERROR_STATE
  return { status: 'ready', info: { roles: [], platform_tenant: false, permissions: [...NAV_ROLE_PERMISSIONS[role]] } }
}

function Pages({ screen }: { screen: string }) {
  const at = new URLSearchParams(window.location.search).get('at') ?? '/'
  const children = appRoutes.find((r) => r.path === '/')?.children ?? []
  return useRoutes([{ element: <AppShell />, children }], `/__harness/${screen}${at.startsWith('/') ? at : `/${at}`}`)
}

/** Under 900 px the sidebar is a drawer (class is-nav-open on .lf-app): open it so a shot of a narrow screen shows the menu.
 *  Set on the element, not through the toggle button: the shell closes the drawer on its first navigation effect. */
function useOpenDrawerWhenNarrow() {
  useEffect(() => {
    if (!window.matchMedia?.('(max-width: 900px)').matches) return
    document.querySelector('.lf-app')?.classList.add('is-nav-open')
  }, [])
}

export default function NavRoleShell({ screen, role, state }: { screen: string; role: NavRole; state: HarnessState }) {
  useOpenDrawerWhenNarrow()
  return (
    <AuthContext.Provider value={auth}>
      <AccessStateProvider state={accessFor(role, state)}>
        <Pages screen={screen} />
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}
