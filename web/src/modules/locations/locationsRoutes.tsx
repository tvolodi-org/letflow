/** locationsRoutes — GH 3607 / REQ-671. Route objects of the locations module; registry.ts wraps them in ModuleGuard. */
import type { ReactNode } from 'react'
import type { RouteObject } from 'react-router-dom'
import { RequirePermission } from '@/auth/access'
import LocationLinksPage from './LocationLinksPage'
import LocationTreePage from './LocationTreePage'
import { LOCATIONS_WRITE } from './locationsPermissions'

function guard(page: ReactNode) {
  return <RequirePermission permission={LOCATIONS_WRITE}>{page}</RequirePermission>
}

export const locationsRouteObjects: RouteObject[] = [
  {
    path: 'admin/locations',
    children: [
      { index: true, element: guard(<LocationTreePage />) },
      { path: 'links', element: guard(<LocationLinksPage />) },
    ],
  },
]
