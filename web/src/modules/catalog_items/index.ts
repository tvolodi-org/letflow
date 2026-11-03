/** web/src/modules/catalog_items/index.ts — GH 3605 / REQ-673
 *
 *  The catalog_items module's ModuleDefinition (registered in web/src/modules/registry.ts). One admin screen
 *  of catalog lots: list by item, create, edit, retire.
 *
 *  SPA path: admin/catalog/lots. `depends_on` is empty on purpose: the SPA module imports no other module's
 *  code (entities are read through the generic query route); the field only feeds the ESLint drift test.
 */
import type { ModuleDefinition } from '@/modules/types'
import { catalogItemsRouteObjects } from './catalogItemsRoutes'
import { CATALOG_LOTS_WRITE } from './catalogItemsPermissions'

export const catalogItemsModuleDefinition: ModuleDefinition = {
  id: 'catalog_items',
  depends_on: [],
  routeObjects: catalogItemsRouteObjects,
  navItems: [{ to: '/admin/catalog/lots', label: 'Lots', permission: CATALOG_LOTS_WRITE }],
}
