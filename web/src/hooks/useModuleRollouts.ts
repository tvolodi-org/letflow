/** useModuleRollouts -- T-1660: hooks of the module rollout operator screen. No polling: one batch per call,
 *  the operator repeats the button (server doc of Fleet.resume). */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { platformModuleRolloutsApi } from '@/api/platformModuleRollouts'
import type { ModuleRolloutList, ModuleRolloutResult } from '@/api/platformModuleRollouts'
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
