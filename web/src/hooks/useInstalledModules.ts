/** REQ-406 — thin useQuery wrapper over GET /api/v1/me/modules.
 *  The query key is tenant-scoped; the route itself still lives under /me,
 *  but the result is tenant business data, not a user-wide membership list. */
import { useQuery } from '@tanstack/react-query'
import { meApi } from '@/api/me'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { useAuth } from '@/auth/AuthContext'

export function useInstalledModules({ enabled = true }: { enabled?: boolean } = {}) {
  const { isAuthenticated } = useAuth()
  const meKeys = useTenantScopedQueryKeys().me

  return useQuery({
    queryKey: meKeys.modules(),
    queryFn: () => meApi.listInstalledModules(),
    enabled: isAuthenticated && enabled,
    select: (data) => data.installed_modules,
  })
}
