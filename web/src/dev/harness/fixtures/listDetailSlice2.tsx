/** Harness fixtures of master-detail slice 2 (T-1888): the real AppShell around the asset cards screen and the stock
 *  counts screen, both on ListDetail. `*-shell` has no record open (empty state, collapse and reload); `*-shell-open`
 *  has one open (narrow Back). Invented data only. */
import { lazy, Suspense, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import AssetCardsPage from '@/modules/assets/AssetCardsPage'
import CountsPage from '@/modules/stock/counts/CountsPage'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import { AuthContext } from '@/auth/AuthContext'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import type { HarnessScreen } from '../types'
import { AUTH as SHELL_AUTH, makeRoutes } from './layoutBase'
import { READER, routes as assetRoutes } from './assets'
import { routes as countRoutes } from './stockCounts'

// Lazy: the real shell reads `window` at import (node-environment harness tests import the registry).
const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

const COUNTS_ACCESS: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['StockRead', 'StockPost', 'StockCountOrder'] },
}

function inShell(access: AccessState, routes: ReactElement): ReactElement {
  return (
    <AuthContext.Provider value={SHELL_AUTH}>
      <BrandingProvider>
        <AccessStateProvider state={access}>
          <LayoutPrefsProvider>
            <Suspense fallback={null}>
              <Routes>
                <Route element={<AppShell fluid />}>{routes}</Route>
              </Routes>
            </Suspense>
          </LayoutPrefsProvider>
        </AccessStateProvider>
      </BrandingProvider>
    </AuthContext.Provider>
  )
}

const cards = () => inShell(READER, <Route path="/*" element={<AssetCardsPage />} />)
const cardsOpen = () => inShell(READER, <Route path="/*" element={<AssetCardsPage initialSelectedId="c-1" />} />)
const counts = () =>
  inShell(
    COUNTS_ACCESS,
    <>
      <Route path="/admin/stock/counts" element={<CountsPage />} />
      <Route path="/admin/stock/counts/:id" element={<CountsPage />} />
    </>,
  )

const cardRoutes = [...makeRoutes(null), ...assetRoutes]
const stockRoutes = [...makeRoutes(null), ...countRoutes]

export const listDetailSlice2Screens: HarnessScreen[] = [
  { name: 'asset-cards-shell', routes: cardRoutes, initialPath: '/admin/assets/cards', render: cards },
  { name: 'asset-cards-shell-open', routes: cardRoutes, initialPath: '/admin/assets/cards', render: cardsOpen },
  { name: 'stock-counts-shell', routes: stockRoutes, initialPath: '/admin/stock/counts', render: counts },
  { name: 'stock-counts-shell-open', routes: stockRoutes, initialPath: '/admin/stock/counts/c1', render: counts },
]
