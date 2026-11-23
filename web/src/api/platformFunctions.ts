/** platformFunctions — T-2599 (pilot gap G5a): the READ route of the compiled platform function catalogue.
 *
 *  `GET /api/v1/platform-functions` (`lib/letflow/routers/platform_functions.ex`) is the only way to learn which
 *  platform functions a definition may call. The catalogue is compiled: there is no write route, no run-time
 *  registration and no table, so a new entry appears in the designer without screen code.
 *
 *  The answer shows only the entries the CALLER's tenant may use: an entry marked `platform_tenant_only` (the
 *  whole platform family today) is visible only in the platform tenant (INV-10). A caller from another tenant
 *  therefore cannot learn which platform functions exist — the route answers 403 for a caller without
 *  `TenantsManage`, and the designer shows that as "not available here", not as an empty list.
 */
import { client } from './client'
import type { PlatformFunctionCatalogue } from '@/types/api'

export const platformFunctionsApi = {
  list: () => client.get<PlatformFunctionCatalogue>('/api/v1/platform-functions'),
}
