/** Harness fixtures for master-detail slice 4 (T-1890): the real AppShell around the locations tree and the
 *  org-legal-entities screen, both on ListDetail kind=tree. `*-shell` has no record open (empty state,
 *  collapse and reload); `*-shell-open` has one open (narrow Back). */
import { lazy, Suspense, useEffect, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import LocationTreePage from '@/modules/locations/LocationTreePage'
import LegalEntitiesPage from '@/modules/org/LegalEntitiesPage'
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

/** Opens the first tree row once it appears (used for the -shell-open fixture). */
function AutoSelectFirst({ selector }: { selector: string }) {
  useEffect(() => {
    let tries = 0
    const timer = window.setInterval(() => {
      const el = document.querySelector<HTMLElement>(selector)
      tries += 1
      if (el) el.click()
      if (el || tries > 120) window.clearInterval(timer)
    }, 50)
    return () => window.clearInterval(timer)
  }, [selector])
  return null
}

export function listDetailSlice4Screens(locationsRoutes: FixtureRoute[], orgRoutes: FixtureRoute[]): HarnessScreen[] {
  const locsAccess = access(['LocationsWrite'])
  const orgAccess = access(['OrgStructureWrite'])
  return [
    {
      name: 'locations-tree-shell',
      routes: [...makeRoutes(null), ...locationsRoutes],
      initialPath: '/admin/locations',
      render: () => inShell(locsAccess, <LocationTreePage />),
    },
    {
      name: 'locations-tree-shell-open',
      routes: [...makeRoutes(null), ...locationsRoutes],
      initialPath: '/admin/locations',
      render: () =>
        inShell(
          locsAccess,
          <>
            <LocationTreePage />
            <AutoSelectFirst selector=".lf-tree__row" />
          </>,
        ),
    },
    {
      name: 'org-legal-shell',
      routes: [...makeRoutes(null), ...orgRoutes],
      initialPath: '/admin/org/legal-entities',
      render: () => inShell(orgAccess, <LegalEntitiesPage />),
    },
    {
      name: 'org-legal-shell-open',
      routes: [...makeRoutes(null), ...orgRoutes],
      initialPath: '/admin/org/legal-entities',
      render: () =>
        inShell(
          orgAccess,
          <>
            <LegalEntitiesPage />
            <AutoSelectFirst selector=".lf-tree__row" />
          </>,
        ),
    },
  ]
}
