/** Harness fixtures of master-detail slice 3 (T-1889): the real AppShell around the codes screen and the lots screen,
 *  both on ListDetail. `*-shell` has no record open (empty state, collapse and reload); `*-shell-open` has one open
 *  (narrow Back). The data routes come from the registry (it owns the invented codes and lots). */
import { lazy, Suspense, useEffect, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import CodesPage from '@/modules/codes/CodesPage'
import LotsPage from '@/modules/catalog_items/LotsPage'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import { AuthContext } from '@/auth/AuthContext'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import type { FixtureRoute, HarnessScreen } from '../types'
import { AUTH as SHELL_AUTH, makeRoutes } from './layoutBase'

// Lazy: the real shell reads `window` at import (node-environment harness tests import the registry).
const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

const access = (permissions: string[]): AccessState => ({ status: 'ready', info: { roles: [], platform_tenant: false, permissions } })

function inShell(state: AccessState, page: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={SHELL_AUTH}>
      <BrandingProvider>
        <AccessStateProvider state={state}>
          <LayoutPrefsProvider>
            <Suspense fallback={null}>
              <Routes>
                <Route element={<AppShell fluid />}>
                  <Route path="/*" element={page} />
                </Route>
              </Routes>
            </Suspense>
          </LayoutPrefsProvider>
        </AccessStateProvider>
      </BrandingProvider>
    </AuthContext.Provider>
  )
}

/** Opens the create panel the way a user does, once the button exists. */
function LotsOpen() {
  useEffect(() => {
    let tries = 0
    const timer = window.setInterval(() => {
      const el = document.querySelector<HTMLElement>('[data-testid="create-lot"]')
      tries += 1
      if (el) el.click()
      if (el || tries > 60) window.clearInterval(timer)
    }, 50)
    return () => window.clearInterval(timer)
  }, [])
  return <LotsPage />
}

export function listDetailSlice3Screens(codesRoutes: FixtureRoute[], lotsRoutes: FixtureRoute[]): HarnessScreen[] {
  const codes = access(['CodesWrite'])
  const lots = access(['CatalogLotsWrite'])
  return [
    { name: 'codes-shell', routes: [...makeRoutes(null), ...codesRoutes], initialPath: '/admin/codes', render: () => inShell(codes, <CodesPage />) },
    {
      name: 'codes-shell-open',
      routes: [...makeRoutes(null), ...codesRoutes],
      initialPath: '/admin/codes',
      render: () => inShell(codes, <CodesPage initial={{ selectedId: 'c1' }} />),
    },
    { name: 'lots-shell', routes: [...makeRoutes(null), ...lotsRoutes], initialPath: '/admin/catalog/lots', render: () => inShell(lots, <LotsPage />) },
    { name: 'lots-shell-open', routes: [...makeRoutes(null), ...lotsRoutes], initialPath: '/admin/catalog/lots', render: () => inShell(lots, <LotsOpen />) },
  ]
}
