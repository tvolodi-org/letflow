/** maintenanceRoutes — GH 4802 / REQ-898. Route objects of the maintenance module; registry.ts wraps them in
 *  ModuleGuard, so a tenant without the module installed gets the not-found page. */
import type { ReactNode } from 'react'
import type { RouteObject } from 'react-router-dom'
import { RequirePermission } from '@/auth/access'
import MaintenanceOrderFormPage from './MaintenanceOrderFormPage'
import MaintenanceOrdersPage from './MaintenanceOrdersPage'
import MyMaintenanceOrdersPage from './MyMaintenanceOrdersPage'
import MaintenanceRequestFormPage from './MaintenanceRequestFormPage'
import MaintenanceRequestsPage from './MaintenanceRequestsPage'
import { MAINTENANCE_ORDER_MANAGE, MAINTENANCE_READ, MAINTENANCE_REQUEST_CREATE, TASKS_READ } from './maintenancePermissions'

function guard(page: ReactNode, permission: string) {
  return <RequirePermission permission={permission}>{page}</RequirePermission>
}

export const maintenanceRouteObjects: RouteObject[] = [
  {
    path: 'admin/maintenance',
    children: [
      { path: 'requests', element: guard(<MaintenanceRequestsPage />, MAINTENANCE_READ) },
      { path: 'requests/new', element: guard(<MaintenanceRequestFormPage />, MAINTENANCE_REQUEST_CREATE) },
      { path: 'requests/:id', element: guard(<MaintenanceRequestsPage />, MAINTENANCE_READ) },
      // REQ-899: the work orders.
      { path: 'orders', element: guard(<MaintenanceOrdersPage />, MAINTENANCE_READ) },
      { path: 'orders/new', element: guard(<MaintenanceOrderFormPage />, MAINTENANCE_ORDER_MANAGE) },
      { path: 'orders/:id', element: guard(<MaintenanceOrdersPage />, MAINTENANCE_READ) },
    ],
  },
  // REQ-899: My maintenance orders needs no maintenance permission: it is the task inbox of the signed-in user.
  { path: 'maintenance/my-orders', element: guard(<MyMaintenanceOrdersPage />, TASKS_READ) },
]
