/** Harness fixtures of GATE B rework I3 (T-1444): the Movements journal inside the REAL AppShell (fluid, collapsible side
 *  nav), with the divider between operations and legs, resizable columns and a remembered layout. Invented data only.
 *  The preferences route answers from an in-memory object: `-remembered` starts from a stored layout (side nav 320 px,
 *  details pane 38 %, narrower date column and legs place column), `-collapsed` from a collapsed side nav. */
import { lazy, Suspense, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import MovementsPage from '@/modules/stock/register/MovementsPage'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'
import { journalRoutes } from './stockJournal'

// Lazy: the real shell pulls the OIDC manager, which reads `window` at import (the registry is imported in node tests).
const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

const SEED_COLLAPSED = { v: 1, shell: { sidenav: { collapsed: true } }, screens: {} }
const SEED_REMEMBERED = {
  v: 1,
  shell: { sidenav: { w: 320 } },
  screens: { 'stock.journal': { panes: { details: [38] }, cols: { ops: { date: 12 }, legs: { loc: 30 } } } },
}

function routes(seed: object | null, forbidden = false): FixtureRoute[] {
  let stored: string | null = seed ? JSON.stringify(seed) : null
  const answer = () => ({ status: 200, body: { preferences: stored ? { 'ui.layout': stored } : {}, effective: {}, tenant_defaults: {} } })
  return [
    { match: (path) => path === '/health', reply: () => ({ status: 200, body: { status: 'ok' } }) },
    { match: (path, method) => path === '/api/v1/me/preferences' && method === 'GET', reply: answer },
    {
      match: (path, method) => path === '/api/v1/me/preferences' && method === 'PUT',
      reply: (_s, _p, body) => {
        stored = (body as { preferences?: Record<string, string | null> } | undefined)?.preferences?.['ui.layout'] ?? null
        return answer()
      },
    },
    ...(forbidden
      ? [{ match: (path: string, method: string) => path === '/api/v1/modules/stock/movements' && method === 'GET', reply: () => ({ status: 403, body: { type: 'about:blank', title: 'Forbidden', status: 403 } }) }]
      : []),
    ...journalRoutes,
  ]
}

const AUTH = {
  session: { token: 'harness', display_name: 'Aigerim Sarsenova', tenant_id: 'harness-tenant', tenant_slug: 'demo', tenant_display_name: 'Demo Holding', tenant_type: 'production' } as unknown as UserSession,
  isAuthenticated: true,
  isLoading: false,
  loginSource: null,
  login: async () => undefined,
  logout: () => undefined,
  setSession: () => undefined,
  switchTenant: async () => 'ok',
  switchingToTenantSlug: null,
} as AuthContextValue

function page(): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <BrandingProvider>
        <AccessStateProvider state={accessState('platformAdmin')}>
          <LayoutPrefsProvider>
            <Suspense fallback={null}>
              <Routes>
                <Route element={<AppShell fluid />}>
                  <Route path="*" element={<MovementsPage initialSelectedId="jr-1" />} />
                </Route>
              </Routes>
            </Suspense>
          </LayoutPrefsProvider>
        </AccessStateProvider>
      </BrandingProvider>
    </AuthContext.Provider>
  )
}

export const stockJournalLayoutScreens: HarnessScreen[] = [
  { name: 'stock-journal-layout', routes: routes(null), render: page },
  { name: 'stock-journal-layout-remembered', routes: routes(SEED_REMEMBERED), render: page },
  { name: 'stock-journal-layout-collapsed', routes: routes(SEED_COLLAPSED), render: page },
  { name: 'stock-journal-layout-noperm', routes: routes(null, true), render: page },
]
