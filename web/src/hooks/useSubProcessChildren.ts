/** useSubProcessChildren — T-2847 (PILOT-SUB-4): the ACTIVE definitions the SUB_PROCESS picker offers, and the
 *  declared variables of the chosen one. Both reads are lazy (`enabled`): they happen when a SUB_PROCESS step's panel
 *  is open. The tenant id is an argument for the same reason as in `usePlatformFunctions` (the harness has no session). */
import { useQuery } from '@tanstack/react-query'
import { definitionsApi } from '@/api/definitions'
import { queryKeys } from '@/api/queryKeys'
import type { ApiError, CursorPage, ProcessDefinition } from '@/types/api'

const UNRESOLVED = 'unresolved'

export function useActiveDefinitions(tenantId: string | null, enabled: boolean) {
  return useQuery<CursorPage<ProcessDefinition>, ApiError>({
    queryKey: queryKeys.definitions.list(tenantId ?? UNRESOLVED, { status: 'ACTIVE', page_size: 200 }),
    queryFn: () => definitionsApi.list({ status: 'ACTIVE', page_size: 200 }),
    retry: false,
    enabled,
  })
}

export function useChildDefinition(tenantId: string | null, id: string | null) {
  return useQuery<ProcessDefinition, ApiError>({
    queryKey: queryKeys.definitions.detail(tenantId ?? UNRESOLVED, id ?? ''),
    queryFn: () => definitionsApi.get(id as string),
    retry: false,
    enabled: !!id,
  })
}
