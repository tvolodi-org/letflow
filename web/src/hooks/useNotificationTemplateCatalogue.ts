/** useNotificationTemplateCatalogue — T-2600 (pilot gap G5b): the catalogue the designer's template picker
 *  reads.
 *
 *  `GET /api/v1/notification-templates/catalogue` is a READ of the COMPILED catalogue: it changes only when the
 *  build changes, so the entry stays fresh for the length of a design session. The key is tenant-scoped (the read
 *  is a route of the tenant), so switching tenants drops the other tenant's answer.
 *
 *  `enabled` is false until a step panel actually needs the picker: the read is lazy, so a designer who never
 *  opens a service step never asks for the catalogue.
 *
 *  ## Why the tenant id is an argument
 *
 *  The step panel is rendered by the screen harness, which has no session, so it cannot read the tenant id
 *  itself. The PAGE resolves it once (from the session) and threads it down, exactly as it threads the
 *  definition itself.
 */
import { useQuery } from '@tanstack/react-query'
import { notificationTemplatesApi } from '@/api/notificationTemplates'
import { queryKeys } from '@/api/queryKeys'
import type { ApiError, NotificationTemplateCatalogue } from '@/types/api'

/** The catalogue is compiled: it changes with the build, not with the data. */
export const NOTIFICATION_TEMPLATES_STALE_MS = 5 * 60 * 1000

/** The key segment for a caller whose tenant id could not be resolved (the same one
 *  `useTenantScopedQueryKeys` uses). */
const UNRESOLVED_TENANT_SEGMENT = 'unresolved'

export function useNotificationTemplateCatalogue(tenantId: string | null, enabled = true) {
  return useQuery<NotificationTemplateCatalogue, ApiError>({
    queryKey: queryKeys.notificationTemplates.catalogue(tenantId ?? UNRESOLVED_TENANT_SEGMENT),
    queryFn: () => notificationTemplatesApi.catalogue(),
    staleTime: NOTIFICATION_TEMPLATES_STALE_MS,
    retry: false,
    enabled,
  })
}
