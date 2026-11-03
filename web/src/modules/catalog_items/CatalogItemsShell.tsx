/** CatalogItemsShell — GH 3605 / REQ-673. The list query hook of the catalog_items screen and its state boundary.
 *  The page frame and the form pieces are the shared components (PageHeader, MasterDetail, DataTable, Field...). */
import type { ReactNode } from 'react'
import { keepPreviousData, useQuery, type UseQueryResult } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'
import { fetchAllRecords } from './catalogItems.api'
import { catalogItemsQueryKeys } from './catalogItemsQueryKeys'

/** All rows of a type matching the filters. `scope` names the filter set in the cache key. */
export function useLotRows(
  type: string,
  scope: string,
  filters: EntityQueryFilterClause[],
  options: { sortField?: string; sortDir?: 'asc' | 'desc'; enabled?: boolean } = {},
): UseQueryResult<EntityRecord[]> {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  return useQuery({
    queryKey: catalogItemsQueryKeys.list(tenantId, type, scope),
    queryFn: () => fetchAllRecords(type, filters, options.sortField, options.sortDir),
    enabled: options.enabled ?? true,
    placeholderData: keepPreviousData,
    retry: false,
  })
}

/** The shared boundary for the failure classes the table does not draw itself (no permission, rate limit,
 *  stale version). Loading and a plain fetch failure stay in the DataTable (skeleton rows, banner with retry). */
export function CatalogItemsBoundary(props: { queries: UseQueryResult<unknown>[]; children: ReactNode }) {
  const failed = props.queries.find((q) => q.isError)
  const cls: RendererState = failed ? classifyError(failed.error) : 'success'
  const state: RendererState = cls === 'fetch-failure' || cls === 'loading' ? 'success' : cls
  return (
    <QueryStateBoundary state={state} onRetry={() => props.queries.forEach((q) => void q.refetch())}>
      {props.children}
    </QueryStateBoundary>
  )
}
