/** web/src/modules/assets/index.ts — T-1333 / C13, T-1334 / C14
 *
 *  The assets module's ModuleDefinition (registered in web/src/modules/registry.ts). Screens: the asset cards (C13), the
 *  asset documents, the balances and the movements (C14).
 *
 *  SPA paths: admin/assets/cards, admin/assets/documents[/:id], admin/assets/balances, admin/assets/movements.
 *  `depends_on` is empty on purpose: the SPA module imports no org code (the backend manifest depends on org);
 *  the field only feeds the ESLint drift test (boundary-config.test.ts). `importTypes` puts the asset cards and the asset opening
 *  lines on the "Import data" page (cards first: the opening lines refer to them); the server stays the authority.
 */
import type { ModuleDefinition } from '@/modules/types'
import { assetsRouteObjects } from './assetsRoutes'
import { ASSETS_CARD_WRITE, ASSETS_POST, ASSETS_READ } from './assetsPermissions'
import { assetsMessages } from './assetsMessages'

function importLabels(entityType: string) {
  const id = `import.type.${entityType}`
  return { en: assetsMessages.en[id], ru: assetsMessages.ru[id], kk: assetsMessages.kk[id] }
}

export const assetsModuleDefinition: ModuleDefinition = {
  id: 'assets',
  depends_on: [],
  routeObjects: assetsRouteObjects,
  importTypes: [
    { entityType: 'assets_card', labels: importLabels('assets_card'), permission: ASSETS_CARD_WRITE },
    { entityType: 'assets_opening_line', labels: importLabels('assets_opening_line'), permission: ASSETS_POST },
  ],
  navItems: [
    { to: '/admin/assets/cards', label: 'Asset cards', permission: ASSETS_CARD_WRITE },
    { to: '/admin/assets/documents', label: 'Asset documents', permission: ASSETS_READ },
    { to: '/admin/assets/balances', label: 'Asset balances', permission: ASSETS_READ },
    { to: '/admin/assets/movements', label: 'Asset movements', permission: ASSETS_READ },
  ],
}
