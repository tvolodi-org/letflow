/** useProblemReportsInbox -- T-2007: hooks of the owner inbox screen for problem reports. The list is paged by the
 *  server cursor `next_before`; a decision stores the answer (the updated detail) and refreshes the lists. */
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { platformProblemReportsApi } from '@/api/platformProblemReports'
import type { DecisionAction, InboxDetail, InboxFilter, InboxList } from '@/api/platformProblemReports'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { client } from '@/api/client'
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

const BASE_PROBLEM_REPORTS = '/api/v1/platform-problem-reports'

/** T-2015 — fetches the blob URL for one problem-report image. Returns isLoading/isError/data for
 *  the caller to render; the blob URL is kept for the lifetime of the query (staleTime: Infinity). */
export function useReportImage(reportId: string, imageId: string) {
  const keys = useTenantScopedQueryKeys().problemReportsInbox
  return useQuery<string, ApiError>({
    queryKey: keys.image(reportId, imageId),
    queryFn: async () => {
      const result = await client.getBlob(
        `${BASE_PROBLEM_REPORTS}/${encodeURIComponent(reportId)}/images/${encodeURIComponent(imageId)}`,
      )
      return URL.createObjectURL(result.blob)
    },
    staleTime: Infinity,
  })
}
