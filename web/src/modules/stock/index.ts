/** web/src/modules/stock/index.ts — GH 3767 / REQ-724
 *
 *  The stock module's ModuleDefinition (it also offers the stock_opening_line import type, REQ-727) (registered in web/src/modules/registry.ts). The document screens
 *  (REQ-722: list, view with actions, draft forms) and the register screens: current balances and movements. `depends_on` is empty on purpose: names of masters are read through the generic
 *  query route, no other module's code is imported (0039 D3).
 */
import type { ModuleDefinition } from '@/modules/types'
import { stockRouteObjects } from './stockRoutes'
import { STOCK_READ } from './stockPermissions'
import { stockMessages } from './stockMessages'

function importLabels(entityType: string) {
  const id = `import.type.${entityType}`
  return { en: stockMessages.en[id], ru: stockMessages.ru[id], kk: stockMessages.kk[id] }
}

export const stockModuleDefinition: ModuleDefinition = {
  id: 'stock',
  depends_on: [],
  routeObjects: stockRouteObjects,
  importTypes: [{ entityType: 'stock_opening_line', labels: importLabels('stock_opening_line') }],
  navItems: [
    { to: '/admin/stock/documents', label: 'Stock documents', permission: STOCK_READ },
    { to: '/admin/stock/balances', label: 'Balances', permission: STOCK_READ },
    { to: '/admin/stock/movements', label: 'Movements', permission: STOCK_READ },
    { to: '/admin/stock/counts', label: 'Counts', permission: STOCK_READ },
  ],
}
