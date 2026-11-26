/** web/src/modules/maintenance/index.ts — GH 4802 / REQ-898 (CMMS slice 1 part 6)
 *
 *  The maintenance module's ModuleDefinition (registered in web/src/modules/registry.ts). Screens of the work
 *  requests: the list with the request in the detail pane, the request page and the form of a new request.
 *
 *  SPA paths: admin/maintenance/requests, admin/maintenance/requests/new, admin/maintenance/requests/:id.
 *  `depends_on` is ['assets'] (as the backend manifest of the module says): the request names the equipment of
 *  an asset card and the card action of the assets module opens the form of a request. The field only feeds the
 *  ESLint drift test (boundary-config.test.ts).
 */
import type { ModuleDefinition } from '@/modules/types'
import { maintenanceRouteObjects } from './maintenanceRoutes'
import { MAINTENANCE_READ } from './maintenancePermissions'

export const maintenanceModuleDefinition: ModuleDefinition = {
  id: 'maintenance',
  depends_on: ['assets'],
  routeObjects: maintenanceRouteObjects,
  navItems: [{ to: '/admin/maintenance/requests', label: 'Maintenance requests', permission: MAINTENANCE_READ }],
}
