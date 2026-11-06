/** Harness fixtures of the remembered layout on the stock document screen (task T-1443). Invented data only.
 *  The real screen with a stored layout: panes and line columns narrower than the defaults, and a collapsed list.
 *  The store is the local one (localStorage), seeded before the first render. */
import { lazy, Suspense, useState, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import DocumentPage from '@/modules/stock/documents/DocumentPage'
import { LAYOUT_STORAGE_KEY } from '@/lib/layoutStore'
import { resetDefaultLayoutStore } from '@/hooks/useLayoutPrefs'
import type { HarnessScreen } from '../types'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { AuthContext } from '@/auth/AuthContext'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import { ACCESS, routes, withAuth } from './stockDocuments'
import { AUTH as SHELL_AUTH, makeRoutes } from './layoutBase'

// Lazy: the real shell reads `window` at import (node-environment harness tests import the registry).
const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

/** The real fluid AppShell around the real document screen (the wide views 1920 / 2560 / 3440, rule 12). */
function inShell(): ReactElement {
  return (
    <AuthContext.Provider value={SHELL_AUTH}>
      <BrandingProvider>
        <AccessStateProvider state={ACCESS}>
          <LayoutPrefsProvider>
            <Suspense fallback={null}>
              <Routes>
                <Route element={<AppShell fluid />}>
                  <Route path="/:id" element={<DocumentPage />} />
                </Route>
              </Routes>
            </Suspense>
          </LayoutPrefsProvider>
        </AccessStateProvider>
      </BrandingProvider>
    </AuthContext.Provider>
  )
}
const shellRoutes = [...makeRoutes(null), ...routes]

const REMEMBERED = { v: 1, shell: {}, screens: { 'stock.documents': { panes: { row: [16, 30] }, cols: { lines: { item: 24, lot: 12, qty: 10, price: 12 } } } } }
const COLLAPSED = { v: 1, shell: {}, screens: { 'stock.documents': { collapsed: { row: [0] } } } }

function Seeded({ layout, children }: { layout: object; children: ReactElement }): ReactElement {
  useState(() => {
    localStorage.setItem(`${LAYOUT_STORAGE_KEY}.anon`, JSON.stringify(layout))
    resetDefaultLayoutStore()
    return null
  })
  return children
}

export const stockDocumentsLayoutScreens: HarnessScreen[] = [
  { name: 'stock-docs-layout-remembered', routes, initialPath: '/doc-posted', routePattern: '/:id', render: () => withAuth(<Seeded layout={REMEMBERED}><DocumentPage /></Seeded>) },
  { name: 'stock-docs-layout-collapsed', routes, initialPath: '/doc-posted', routePattern: '/:id', render: () => withAuth(<Seeded layout={COLLAPSED}><DocumentPage /></Seeded>) },
  { name: 'stock-docs-shell', routes: shellRoutes, initialPath: '/doc-posted', render: inShell },
]
