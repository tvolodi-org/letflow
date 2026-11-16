/** NOTE: the harness URL is /__harness/<name>, so the path list of AppShell (FLUID_PATHS, unit-tested in AppShell.fluid.test)
 *  cannot match here; `fluid` is passed, which sets the same class (lf-content--fluid).
 *  Harness screens of the document screens inside the REAL AppShell (T-2020): the fluid width at 2560 px and the single
 *  Print menu on the count screen and the stock documents screen. Invented data only. */
import { lazy, Suspense, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import CountsPage from '@/modules/stock/counts/CountsPage'
import DocumentsPage from '@/modules/stock/documents/DocumentsPage'
import { StockIntlProvider } from '@/modules/stock/StockIntlProvider'
import { AuthContext } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import type { FixtureRoute, HarnessScreen } from '../types'
import { ACCESS, routes as docRoutes } from './stockDocuments'
import { routes as countRoutes } from './stockCounts'
import { AUTH, makeRoutes } from './layoutBase'

// Lazy: the real shell reads `window` at import (node-environment harness tests import the registry).
const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

function inShell(pattern: string, page: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <BrandingProvider>
        <AccessStateProvider state={ACCESS}>
          <LayoutPrefsProvider>
            <StockIntlProvider>
              <Suspense fallback={null}>
                <Routes>
                  <Route element={<AppShell fluid />}>
                    <Route path={pattern} element={page} />
                  </Route>
                </Routes>
              </Suspense>
            </StockIntlProvider>
          </LayoutPrefsProvider>
        </AccessStateProvider>
      </BrandingProvider>
    </AuthContext.Provider>
  )
}

const countShellRoutes: FixtureRoute[] = [...makeRoutes(null), ...countRoutes]
const docShellRoutes: FixtureRoute[] = [...makeRoutes(null), ...docRoutes]

export const docsShellT2020Screens: HarnessScreen[] = [
  {
    name: 'count-shell-t2020',
    routes: countShellRoutes,
    initialPath: '/admin/stock/counts/c2',
    render: () => inShell('/admin/stock/counts/:id', <CountsPage />),
  },
  {
    name: 'stock-docs-shell-t2020',
    routes: docShellRoutes,
    initialPath: '/admin/stock/documents',
    render: () => inShell('/admin/stock/documents', <DocumentsPage />),
  },
]
