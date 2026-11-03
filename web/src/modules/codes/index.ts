/** web/src/modules/codes/index.ts — GH 3606 / REQ-672
 *
 *  The codes module's ModuleDefinition (registered in web/src/modules/registry.ts). One admin screen of the
 *  tag codes: receive in bulk, list, assign, release, retire, change value, history.
 *
 *  SPA path: admin/codes. `depends_on` is empty on purpose: the SPA module imports no other module's code (the
 *  targets are read through the generic query route); the field only feeds the ESLint drift test.
 */
import type { ModuleDefinition } from '@/modules/types'
import { codesRouteObjects } from './codesRoutes'
import { CODES_WRITE } from './codesPermissions'

export const codesModuleDefinition: ModuleDefinition = {
  id: 'codes',
  depends_on: [],
  routeObjects: codesRouteObjects,
  navItems: [{ to: '/admin/codes', label: 'Codes', permission: CODES_WRITE }],
}
