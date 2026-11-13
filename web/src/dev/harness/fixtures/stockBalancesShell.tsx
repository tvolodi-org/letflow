/** Harness fixtures of the collapsed-pane expander (task T-1884). Invented data only.
 *  `stock-balances-shell`: the real AppShell around the real balances screen (the Reset layout control lives in its footer).
 *  `stock-balances-shell-tall`: the same with a tall block above the grid, so the strip starts below the fold. */
import { lazy, Suspense, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import BalancesPage from '@/modules/stock/register/BalancesPage'
import type { HarnessScreen } from '../types'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { AuthContext } from '@/auth/AuthContext'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import { ACCESS } from './stockDocuments'
import { AUTH as SHELL_AUTH, makeRoutes } from './layoutBase'
import { layoutRoutes } from './stockBalancesLayout'

// Lazy: the real shell reads `window` at import (node-environment harness tests import the registry).
const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

function inShell(filler: boolean): ReactElement {
  return (
    <AuthContext.Provider value={SHELL_AUTH}>
      <BrandingProvider>
        <AccessStateProvider state={ACCESS}>
          <LayoutPrefsProvider>
            <Suspense fallback={null}>
              <Routes>
                <Route element={<AppShell fluid />}>
                  <Route
                    path="/*"
                    element={
                      <>
                        {filler && <div style={{ height: 1300 }} aria-hidden="true" />}
                        <BalancesPage />
                      </>
                    }
                  />
                </Route>
              </Routes>
            </Suspense>
          </LayoutPrefsProvider>
        </AccessStateProvider>
      </BrandingProvider>
    </AuthContext.Provider>
  )
}
const shellRoutes = [...makeRoutes(null), ...layoutRoutes]

export const stockBalancesShellScreens: HarnessScreen[] = [
  { name: 'stock-balances-shell', routes: shellRoutes, initialPath: '/balances', render: () => inShell(false) },
  { name: 'stock-balances-shell-tall', routes: shellRoutes, initialPath: '/balances', render: () => inShell(true) },
]
