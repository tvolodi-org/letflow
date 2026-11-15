/** useProblemReportsInbox -- T-2007: hooks of the owner inbox screen for problem reports. The list is paged by the
 *  server cursor `next_before`; a decision stores the answer (the updated detail) and refreshes the lists. */
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { platformProblemReportsApi } from '@/api/platformProblemReports'
import type { DecisionAction, InboxDetail, InboxFilter, InboxList } from '@/api/platformProblemReports'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import type { ApiError } from '@/types/api'

export function useInboxList(status: InboxFilter) {
  const keys = useTenantScopedQueryKeys().problemReportsInbox
  return useInfiniteQuery<InboxList, ApiError, { pages: InboxList[] }, readonly unknown[], number | null>({
    queryKey: keys.list(status),
    initialPageParam: null,
    queryFn: ({ pageParam }) => platformProblemReportsApi.list({ status, before: pageParam }),
    getNextPageParam: (last) => last.next_before ?? undefined,
  })
}

export function useInboxReport(id: string | null) {
  const keys = useTenantScopedQueryKeys().problemReportsInbox
  return useQuery<InboxDetail, ApiError>({
    queryKey: keys.detail(id ?? ''),
    queryFn: () => platformProblemReportsApi.get(id as string),
    enabled: !!id,
  })
}

export function useDecideReport() {
  const qc = useQueryClient()
  const keys = useTenantScopedQueryKeys().problemReportsInbox
  return useMutation<InboxDetail, ApiError, { id: string; action: DecisionAction; text: string }>({
    mutationFn: ({ id, action, text }) =>
      platformProblemReportsApi.decide(id, text === '' ? { action } : { action, text }),
    onSuccess: (detail, vars) => {
      qc.setQueryData(keys.detail(vars.id), detail)
      void qc.invalidateQueries({ queryKey: keys.lists() })
    },
  })
}
