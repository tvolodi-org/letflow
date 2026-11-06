/** web/src/modules/assets/index.ts — T-1333 / C13
 *
 *  The assets module's ModuleDefinition (registered in web/src/modules/registry.ts). Screen of the asset cards.
 *
 *  SPA path: admin/assets/cards.
 *  `depends_on` is empty on purpose: the SPA module imports no org code (the backend manifest depends on org);
 *  the field only feeds the ESLint drift test (boundary-config.test.ts). No `importTypes` yet (the import is C17).
 */
import type { ModuleDefinition } from '@/modules/types'
import { assetsRouteObjects } from './assetsRoutes'
import { ASSETS_CARD_WRITE } from './assetsPermissions'

export const assetsModuleDefinition: ModuleDefinition = {
  id: 'assets',
  depends_on: [],
  routeObjects: assetsRouteObjects,
  navItems: [{ to: '/admin/assets/cards', label: 'Asset cards', permission: ASSETS_CARD_WRITE }],
}
