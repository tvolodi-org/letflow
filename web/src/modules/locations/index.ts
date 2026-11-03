/** web/src/modules/locations/index.ts — GH 3607 / REQ-671
 *
 *  The locations module's ModuleDefinition (registered in web/src/modules/registry.ts). Screens of the
 *  location tree and of the links between org units and locations.
 *
 *  SPA paths: admin/locations (tree), admin/locations/links (links).
 *  `depends_on` is empty on purpose: the SPA module imports no org code (the backend manifest depends on org);
 *  the field only feeds the ESLint drift test (boundary-config.test.ts).
 */
import type { ModuleDefinition } from '@/modules/types'
import { locationsRouteObjects } from './locationsRoutes'
import { LOCATIONS_WRITE } from './locationsPermissions'

export const locationsModuleDefinition: ModuleDefinition = {
  id: 'locations',
  depends_on: [],
  routeObjects: locationsRouteObjects,
  navItems: [
    { to: '/admin/locations', label: 'Locations', permission: LOCATIONS_WRITE },
    { to: '/admin/locations/links', label: 'Location links', permission: LOCATIONS_WRITE },
  ],
}
