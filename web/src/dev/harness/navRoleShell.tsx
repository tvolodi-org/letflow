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

function Pages({ screen, at: fixedAt }: { screen: string; at?: string }) {
  const at = fixedAt ?? new URLSearchParams(window.location.search).get('at') ?? '/'
  const children = appRoutes.find((r) => r.path === '/')?.children ?? []
  return useRoutes([{ element: <AppShell />, children }], `/__harness/${screen}${at.startsWith('/') ? at : `/${at}`}`)
}

/** Under 900 px the sidebar is a drawer (class is-nav-open on .lf-app): open it so a shot of a narrow screen shows the menu.
 *  Set on the element, not through the toggle button: the shell closes the drawer on its first navigation effect. */
function useOpenDrawerWhenNarrow(enabled: boolean) {
  useEffect(() => {
    if (!enabled || !window.matchMedia?.('(max-width: 900px)').matches) return
    document.querySelector('.lf-app')?.classList.add('is-nav-open')
  }, [enabled])
}

/** T-2216: the drawer states of the phone menu on the page that is already shown. Drives the real controls: the menu button
 *  opens the drawer; for `tapped` a click on the entry of the page shown follows, with the navigation itself suppressed in the
 *  capture phase (the route does not change, which is the case the pathname effect never covered). */
export type DrawerStep = 'open' | 'tapped'

function useDrawerSteps(step: DrawerStep | undefined, currentPath: string) {
  useEffect(() => {
    if (step == null || !window.matchMedia?.('(max-width: 900px)').matches) return
    const stopNavigation = (e: MouseEvent) => {
      if ((e.target as Element | null)?.closest('.lf-sidenav__item')) e.preventDefault()
    }
    if (step === 'tapped') document.addEventListener('click', stopNavigation, true)
    let phase: 'menu' | 'entry' | 'done' = 'menu'
    const timer = window.setInterval(() => {
      if (phase === 'menu') {
        const button = document.querySelector<HTMLButtonElement>('[data-testid="topbar-menu"]')
        if (button == null) return
        button.click()
        phase = step === 'tapped' ? 'entry' : 'done'
      } else if (phase === 'entry') {
        const link = document.querySelector<HTMLAnchorElement>(`a.lf-sidenav__item[href="${currentPath}"]`)
        if (link == null || !document.querySelector('.lf-app')?.classList.contains('is-nav-open')) return
        link.click()
        phase = 'done'
      } else window.clearInterval(timer)
    }, 20)
    return () => {
      window.clearInterval(timer)
      document.removeEventListener('click', stopNavigation, true)
    }
  }, [step, currentPath])
}

export default function NavRoleShell({ screen, role, state, at, drawer }: { screen: string; role: NavRole; state: HarnessState; at?: string; drawer?: DrawerStep }) {
  useOpenDrawerWhenNarrow(drawer == null)
  useDrawerSteps(drawer, at ?? '/')
  return (
    <AuthContext.Provider value={auth}>
      <AccessStateProvider state={accessFor(role, state)}>
        <Pages screen={screen} at={at} />
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}
