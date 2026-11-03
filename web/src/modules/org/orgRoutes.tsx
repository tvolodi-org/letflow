/** orgRoutes — GH 3609 / REQ-669. Route objects of the org module; registry.ts wraps them in ModuleGuard. */
import type { ReactNode } from 'react'
import type { RouteObject } from 'react-router-dom'
import { RequirePermission } from '@/auth/access'
import EmployeesPage from './EmployeesPage'
import LegalEntitiesPage from './LegalEntitiesPage'
import PositionsPage from './PositionsPage'
import SitesPage from './SitesPage'
import UnitsPage from './UnitsPage'
import { ORG_EMPLOYEES_WRITE, ORG_STRUCTURE_WRITE } from './orgPermissions'

/** The org-structure screens need OrgStructureWrite (the shell's forbidden page otherwise). */
function structureGuard(page: ReactNode) {
  return <RequirePermission permission={ORG_STRUCTURE_WRITE}>{page}</RequirePermission>
}

/** The position and employee screens need OrgEmployeesWrite. */
function employeesGuard(page: ReactNode) {
  return <RequirePermission permission={ORG_EMPLOYEES_WRITE}>{page}</RequirePermission>
}

export const orgRouteObjects: RouteObject[] = [
  {
    path: 'admin/org',
    children: [
      { path: 'legal-entities', element: structureGuard(<LegalEntitiesPage />) },
      { path: 'sites', element: structureGuard(<SitesPage />) },
      { path: 'units', element: structureGuard(<UnitsPage />) },
      { path: 'positions', element: employeesGuard(<PositionsPage />) },
      { path: 'employees', element: employeesGuard(<EmployeesPage />) },
    ],
  },
]
