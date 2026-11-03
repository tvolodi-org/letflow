/** web/src/modules/org/index.ts — GH 3609 / REQ-669
 *
 *  The org module's ModuleDefinition (registered in web/src/modules/registry.ts). Screens of the
 *  organisation structure: legal companies, sites, org unit tree (positions and employees: REQ-670).
 *
 *  SPA paths: admin/org/legal-entities, admin/org/sites, admin/org/units.
 *  Nav labels are English literals (ModuleNavItem.label is a plain string); the screens are en/ru/kk.
 */
import type { ModuleDefinition } from '@/modules/types'
import { orgRouteObjects } from './orgRoutes'
import { ORG_STRUCTURE_WRITE } from './orgPermissions'

export const orgModuleDefinition: ModuleDefinition = {
  id: 'org',
  depends_on: [],
  routeObjects: orgRouteObjects,
  navItems: [
    { to: '/admin/org/legal-entities', label: 'Legal companies', permission: ORG_STRUCTURE_WRITE },
    { to: '/admin/org/sites', label: 'Sites', permission: ORG_STRUCTURE_WRITE },
    { to: '/admin/org/units', label: 'Org units', permission: ORG_STRUCTURE_WRITE },
  ],
}
