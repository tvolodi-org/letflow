/** useModuleRollouts -- T-1660: hooks of the module rollout operator screen. No polling: one batch per call,
 *  the operator repeats the button (server doc of Fleet.resume). */
import { useMemo } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { platformModuleRolloutsApi } from '@/api/platformModuleRollouts'
import type { ModuleRolloutList, ModuleRolloutResult } from '@/api/platformModuleRollouts'
import { tenantsApi } from '@/api/tenants'
import { queryKeys } from '@/api/queryKeys'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import type { ApiError } from '@/types/api'

export function useModuleRolloutsList() {
  const keys = useTenantScopedQueryKeys().moduleRollouts
  return useQuery<ModuleRolloutList, ApiError>({
    queryKey: keys.list(),
    queryFn: () => platformModuleRolloutsApi.list(),
  })
}

export function useModuleRolloutStatus(id: string | null) {
  const keys = useTenantScopedQueryKeys().moduleRollouts
  return useQuery<ModuleRolloutResult, ApiError>({
    queryKey: keys.status(id ?? ''),
    queryFn: () => platformModuleRolloutsApi.status(id as string),
    enabled: !!id,
  })
}

function useInvalidateAfter() {
  const qc = useQueryClient()
  const keys = useTenantScopedQueryKeys().moduleRollouts
  return (data: ModuleRolloutResult) => {
    void qc.invalidateQueries({ queryKey: keys.list() })
    void qc.invalidateQueries({ queryKey: keys.status(data.rollout.id) })
  }
}

export function useStartModuleRollout() {
  const after = useInvalidateAfter()
  return useMutation<ModuleRolloutResult, ApiError, string>({
    mutationFn: (moduleId: string) => platformModuleRolloutsApi.start(moduleId),
    onSuccess: after,
  })
}

export function useResumeModuleRollout() {
  const after = useInvalidateAfter()
  return useMutation<ModuleRolloutResult, ApiError, string>({
    mutationFn: (id: string) => platformModuleRolloutsApi.resume(id),
    onSuccess: after,
  })
}

const TENANT_LOOKUP_PAGE_SIZE = 200

/** tenant_id -> display name; the platform's tenant list may be refused, then the raw id is shown. */
export function useTenantNames(): Map<string, string> {
  const query = useQuery({
    queryKey: queryKeys.admin.tenants({ page_size: TENANT_LOOKUP_PAGE_SIZE }),
    queryFn: () => tenantsApi.list({ page_size: TENANT_LOOKUP_PAGE_SIZE }),
    retry: false,
  })
  return useMemo(() => {
    const map = new Map<string, string>()
    for (const tenant of query.data?.items ?? []) if (tenant.tenant_id) map.set(tenant.tenant_id, tenant.display_name)
    return map
  }, [query.data])
}
