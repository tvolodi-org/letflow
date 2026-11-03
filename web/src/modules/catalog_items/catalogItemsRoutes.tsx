/** catalogItemsRoutes — GH 3605 / REQ-673. Route objects of the catalog_items module. */
import type { RouteObject } from 'react-router-dom'
import { RequirePermission } from '@/auth/access'
import LotsPage from './LotsPage'
import { CATALOG_LOTS_WRITE } from './catalogItemsPermissions'

export const catalogItemsRouteObjects: RouteObject[] = [
  {
    path: 'admin/catalog/lots',
    children: [
      {
        index: true,
        element: (
          <RequirePermission permission={CATALOG_LOTS_WRITE}>
            <LotsPage />
          </RequirePermission>
        ),
      },
    ],
  },
]
