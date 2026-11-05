/** catalogItemsRoutes — GH 3605 / REQ-673. Route objects of the catalog_items module. */
import type { RouteObject } from 'react-router-dom'
import { RequirePermission } from '@/auth/access'
import LotsPage from './LotsPage'
import ItemsPage from './items/ItemsPage'
import { CATALOG_LOTS_WRITE, STOCK_READ_ATOM } from './catalogItemsPermissions'

export const catalogItemsRouteObjects: RouteObject[] = [
  {
    path: 'admin/catalog/items',
    children: [
      {
        index: true,
        element: (
          <RequirePermission permission={STOCK_READ_ATOM}>
            <ItemsPage />
          </RequirePermission>
        ),
      },
    ],
  },
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
