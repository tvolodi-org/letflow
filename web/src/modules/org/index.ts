/** web/src/modules/org/index.ts — GH 3609 / REQ-669
 *
 *  The org module's ModuleDefinition (registered in web/src/modules/registry.ts). Screens of the
 *  organisation structure: legal companies, sites, org unit tree, positions and employees (REQ-670).
 *
 *  SPA paths: admin/org/legal-entities, admin/org/sites, admin/org/units, admin/org/positions, admin/org/employees.
 *  Nav labels are English literals (ModuleNavItem.label is a plain string); the screens are en/ru/kk.
 */
import type { ModuleDefinition } from '@/modules/types'
import { orgMessages } from './orgMessages'
import { orgRouteObjects } from './orgRoutes'
import { ORG_EMPLOYEES_WRITE, ORG_STRUCTURE_WRITE } from './orgPermissions'

function importLabels(entityType: string) {
  const id = `import.type.${entityType}`
  return { en: orgMessages.en[id], ru: orgMessages.ru[id], kk: orgMessages.kk[id] }
}

export const orgModuleDefinition: ModuleDefinition = {
  id: 'org',
  depends_on: [],
  routeObjects: orgRouteObjects,
  importTypes: [
    { entityType: 'org_unit', labels: importLabels('org_unit') },
    { entityType: 'org_position', labels: importLabels('org_position') },
    { entityType: 'org_employee', labels: importLabels('org_employee') },
  ],
  navItems: [
    { to: '/admin/org/legal-entities', label: 'Legal companies', permission: ORG_STRUCTURE_WRITE },
    { to: '/admin/org/sites', label: 'Sites', permission: ORG_STRUCTURE_WRITE },
    { to: '/admin/org/units', label: 'Org units', permission: ORG_STRUCTURE_WRITE },
    { to: '/admin/org/positions', label: 'Positions', permission: ORG_EMPLOYEES_WRITE },
    { to: '/admin/org/employees', label: 'Employees', permission: ORG_EMPLOYEES_WRITE },
  ],
}
