/** stockRoutes — GH 3767 / REQ-724. Route objects of the stock module; registry.ts wraps them in ModuleGuard. */
import type { RouteObject } from 'react-router-dom'
import { RequirePermission } from '@/auth/access'
import BalancesPage from './register/BalancesPage'
import MovementsPage from './register/MovementsPage'
import { STOCK_READ } from './stockPermissions'

export const stockRouteObjects: RouteObject[] = [
  {
    path: 'admin/stock/balances',
    element: (
      <RequirePermission permission={STOCK_READ}>
        <BalancesPage />
      </RequirePermission>
    ),
  },
  {
    path: 'admin/stock/movements',
    element: (
      <RequirePermission permission={STOCK_READ}>
        <MovementsPage />
      </RequirePermission>
    ),
  },
]
