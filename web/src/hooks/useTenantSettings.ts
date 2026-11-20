/** useTenantSettings — T-2403. The tenant's effective company name and time zone, `GET /api/v1/tenant/settings`. */
import { useQuery } from '@tanstack/react-query'
import { tenantSettingsApi } from '@/api/tenantSettings'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'

export function useTenantSettings() {
  const keys = useTenantScopedQueryKeys().me
  return useQuery({ queryKey: keys.tenantSettings(), queryFn: () => tenantSettingsApi.get(), retry: false })
}
