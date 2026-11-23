/** usePlatformFunctions — T-2599 (pilot gap G5a): the catalogue the designer's function picker reads.
 *
 *  `GET /api/v1/platform-functions` is a READ of the COMPILED catalogue: it changes only when the build changes,
 *  so the entry stays fresh for the length of a design session. The key is tenant-scoped (the platform family is
 *  visible only in the platform tenant — INV-10), so switching tenants drops the other tenant's catalogue.
 *
 *  A caller without `TenantsManage` gets 403: the hook reports the status so the picker can say "not available
 *  here" instead of showing an empty palette (which would read as "this tenant has no platform functions").
 *
 *  `enabled` is false until a step panel actually needs the palette: the read is lazy, so a designer who never
 *  opens a service step never asks for the catalogue (and a company tenant, which may not read it at all, is
 *  never asked).
 *
 *  ## Why the tenant id is an argument
 *
 *  The step panel is rendered by the screen harness, which has no session, so it cannot read the tenant id
 *  itself. The PAGE resolves it once (from the session) and threads it down, exactly as it threads the
 *  definition itself; the key is then built with the same builder every other tenant-scoped key uses
 *  (`queryKeys.platformFunctions.list/1`). A tenant switch therefore drops the other tenant's catalogue.
 */
import { useQuery } from '@tanstack/react-query'
import { platformFunctionsApi } from '@/api/platformFunctions'
import { queryKeys } from '@/api/queryKeys'
import type { ApiError, PlatformFunctionCatalogue } from '@/types/api'

/** The catalogue is compiled: it changes with the build, not with the data. */
export const PLATFORM_FUNCTIONS_STALE_MS = 5 * 60 * 1000

/** The key segment for a caller whose tenant id could not be resolved (the same one
 *  `useTenantScopedQueryKeys` uses). */
const UNRESOLVED_TENANT_SEGMENT = 'unresolved'

export function usePlatformFunctions(tenantId: string | null, enabled = true) {
  return useQuery<PlatformFunctionCatalogue, ApiError>({
    queryKey: queryKeys.platformFunctions.list(tenantId ?? UNRESOLVED_TENANT_SEGMENT),
    queryFn: () => platformFunctionsApi.list(),
    staleTime: PLATFORM_FUNCTIONS_STALE_MS,
    retry: false,
    enabled,
  })
}
