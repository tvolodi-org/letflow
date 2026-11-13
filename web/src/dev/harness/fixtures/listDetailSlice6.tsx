/** Harness fixtures of master-detail slice 6 (T-1892): the real AppShell around the catalog items screen on ListDetail.
 *  `items-shell` has no record open (empty state, collapse and reload); `items-shell-open` has the first item open
 *  (narrow Back). The data routes are the ones of the items fixture. */
import { lazy, Suspense, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import ItemsPage from '@/modules/catalog_items/items/ItemsPage'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { AuthContext } from '@/auth/AuthContext'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import type { HarnessScreen } from '../types'
import { AUTH as SHELL_AUTH, makeRoutes } from './layoutBase'
import { catalogItemsDataRoutes, catalogItemsSelectedId } from './catalogItems'

// Lazy: the real shell reads `window` at import (node-environment harness tests import the registry).
const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

function inShell(page: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={SHELL_AUTH}>
      <BrandingProvider>
        <AccessStateProvider state={{ status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['StockRead'] } }}>
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

export const listDetailSlice6Screens: HarnessScreen[] = [
  { name: 'items-shell', routes: [...makeRoutes(null), ...catalogItemsDataRoutes], initialPath: '/admin/catalog/items', render: () => inShell(<ItemsPage />) },
  {
    name: 'items-shell-open',
    routes: [...makeRoutes(null), ...catalogItemsDataRoutes],
    initialPath: '/admin/catalog/items',
    render: () => inShell(<ItemsPage initialItemId={catalogItemsSelectedId} />),
  },
]
