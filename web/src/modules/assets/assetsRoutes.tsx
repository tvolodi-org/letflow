/** assetsRoutes — T-1333 / C13. Route objects of the assets module; registry.ts wraps them in ModuleGuard. */
import type { ReactNode } from 'react'
import type { RouteObject } from 'react-router-dom'
import { RequirePermission } from '@/auth/access'
import AssetCardsPage from './AssetCardsPage'
import { ASSETS_CARD_WRITE } from './assetsPermissions'

function guard(page: ReactNode) {
  return <RequirePermission permission={ASSETS_CARD_WRITE}>{page}</RequirePermission>
}

export const assetsRouteObjects: RouteObject[] = [
  {
    path: 'admin/assets',
    children: [{ path: 'cards', element: guard(<AssetCardsPage />) }],
  },
]
