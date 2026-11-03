/** web/src/modules/catalog_items/index.ts — GH 3605 / REQ-673
 *
 *  The catalog_items module's ModuleDefinition (registered in web/src/modules/registry.ts). One admin screen
 *  of catalog lots: list by item, create, edit, retire.
 *
 *  SPA path: admin/catalog/lots. `depends_on` is empty on purpose: the SPA module imports no other module's
 *  code (entities are read through the generic query route); the field only feeds the ESLint drift test.
 */
import type { ModuleDefinition } from '@/modules/types'
import { catalogItemsMessages } from './catalogItemsMessages'
import { catalogItemsRouteObjects } from './catalogItemsRoutes'
import { CATALOG_LOTS_WRITE } from './catalogItemsPermissions'

function importLabels(entityType: string) {
  const id = `import.type.${entityType}`
  return { en: catalogItemsMessages.en[id], ru: catalogItemsMessages.ru[id], kk: catalogItemsMessages.kk[id] }
}

export const catalogItemsModuleDefinition: ModuleDefinition = {
  id: 'catalog_items',
  depends_on: [],
  routeObjects: catalogItemsRouteObjects,
  importTypes: [
    { entityType: 'catalog_uom', labels: importLabels('catalog_uom') },
    { entityType: 'catalog_item', labels: importLabels('catalog_item') },
    { entityType: 'catalog_counterparty', labels: importLabels('catalog_counterparty') },
    { entityType: 'catalog_lot', labels: importLabels('catalog_lot') },
  ],
  navItems: [{ to: '/admin/catalog/lots', label: 'Lots', permission: CATALOG_LOTS_WRITE }],
}
