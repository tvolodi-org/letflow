/** web/src/modules/stock/index.ts — GH 3767 / REQ-724
 *
 *  The stock module's ModuleDefinition (registered in web/src/modules/registry.ts). The register screens:
 *  current balances and movements. `depends_on` is empty on purpose: names of masters are read through the generic
 *  query route, no other module's code is imported (0039 D3).
 */
import type { ModuleDefinition } from '@/modules/types'
import { stockRouteObjects } from './stockRoutes'
import { STOCK_READ } from './stockPermissions'

export const stockModuleDefinition: ModuleDefinition = {
  id: 'stock',
  depends_on: [],
  routeObjects: stockRouteObjects,
  navItems: [
    { to: '/admin/stock/balances', label: 'Balances', permission: STOCK_READ },
    { to: '/admin/stock/movements', label: 'Movements', permission: STOCK_READ },
  ],
}
