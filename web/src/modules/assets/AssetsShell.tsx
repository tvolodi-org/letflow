/** AssetsShell — T-1333 / C13. The shared frame of the asset card screen (page header, loading/error through
 *  QueryStateBoundary), the two list query hooks and the write-error pieces. */
import type { ReactNode } from 'react'
import { keepPreviousData, useInfiniteQuery, useQuery, type UseQueryResult } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { PageHeader } from '@/components/ui/PageHeader'
import { TruncatedNotice } from '@/components/ui/TruncatedNotice'
import { MAX_ROWS, anyTruncated } from '@/lib/entities/fetchAllRecords'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'
import { useDebounce } from '@/hooks/useDebounce'
import { ACTIVE_TRUE, DELETED_FALSE, fetchAllRecords, fetchCardsPage, searchCards } from './assets.api'
import { assetsQueryKeys } from './assetsQueryKeys'
import { ASSET_CARD, ORG_UNIT, errorMessageId, reasonOf } from './assetsModel'

export interface CardFilters {
  kind: string
  orgUnitId: string
  showRetired: boolean
}

/** What the boundary needs from a query (an infinite query result fits too). */
export type QueryLike = Pick<UseQueryResult<unknown>, 'isError' | 'error' | 'isPending' | 'fetchStatus'> & {
  refetch: () => unknown
  data?: unknown
}

export interface AssetRows {
  rows: EntityRecord[]
  /** the shown rows are not the whole result (more pages, or a search with more matches than one page) */
  truncated: boolean
  searching: boolean
  hasMore: boolean
  loadingMore: boolean
  loadMore: () => void
  queries: QueryLike[]
}

/** The cards matching the server-side filters (kind, org unit, retired) and the search text. No search: pages of
 *  100 with "Load more". A search term: one server-side search (number and name), first page of each (T-1793).
 *  A filter change keeps the old rows on screen until the new ones arrive. */
export function useAssetRows(filters: CardFilters, search = ''): AssetRows {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const term = useDebounce(search.trim(), 300)
  const searching = term !== ''
  const clauses: EntityQueryFilterClause[] = [
    DELETED_FALSE,
    ...(filters.showRetired ? [] : [ACTIVE_TRUE]),
    ...(filters.kind !== '' ? [{ field: 'kind', op: 'eq' as const, value: filters.kind }] : []),
    ...(filters.orgUnitId !== '' ? [{ field: 'org_unit_id', op: 'eq' as const, value: filters.orgUnitId }] : []),
  ]
  const scope = [filters.showRetired ? 'all' : 'active', filters.kind, filters.orgUnitId].join('|')
  const found = useQuery({
    queryKey: assetsQueryKeys.list(tenantId, ASSET_CARD, `search|${scope}|${term}`),
    queryFn: () => searchCards(ASSET_CARD, clauses, term),
    enabled: searching,
    placeholderData: keepPreviousData,
    retry: false,
  })
  const paged = useInfiniteQuery({
    queryKey: assetsQueryKeys.list(tenantId, ASSET_CARD, `page|${scope}`),
    queryFn: ({ pageParam }) => fetchCardsPage(ASSET_CARD, clauses, pageParam || undefined),
    initialPageParam: '' as string,
    getNextPageParam: (last, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    enabled: !searching || found.data === undefined,
    placeholderData: keepPreviousData,
    retry: false,
  })
  // until the first search answer arrives (or when typing starts) the list stays on screen: no skeleton flash
  if (searching && (found.data !== undefined || found.isError)) {
    return {
      rows: found.data?.items ?? [],
      truncated: found.data?.truncated ?? false,
      searching,
      hasMore: false,
      loadingMore: false,
      loadMore: () => undefined,
      queries: [found],
    }
  }
  const hasMore = paged.hasNextPage
  return {
    rows: paged.data?.pages.flatMap((p) => p.items) ?? [],
    truncated: hasMore,
    searching: false,
    hasMore,
    loadingMore: paged.isFetchingNextPage,
    loadMore: () => void paged.fetchNextPage(),
    queries: [paged],
  }
}

/** All org units (retired ones too, so a card of a retired unit still shows the unit's name). */
export function useOrgUnitRows(): UseQueryResult<EntityRecord[]> {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  return useQuery({
    queryKey: assetsQueryKeys.list(tenantId, ORG_UNIT, 'all'),
    queryFn: () => fetchAllRecords(ORG_UNIT, [DELETED_FALSE], 'code'),
    structuralSharing: false, // keeps `truncated` on the list
    retry: false,
  })
}

export function AssetsShell(props: {
  title: string
  eyebrow?: string
  lede?: string
  queries: QueryLike[]
  actions?: ReactNode
  children: ReactNode
}) {
  const intl = useIntl()
  const retry = () => props.queries.forEach((q) => void q.refetch())
  const failed = props.queries.find((q) => q.isError)
  const state: RendererState = failed
    ? classifyError(failed.error)
    : props.queries.some((q) => q.isPending && q.fetchStatus !== 'idle')
      ? 'loading'
      : 'success'
  return (
    <>
      <PageHeader title={props.title} eyebrow={props.eyebrow} lede={props.lede} actions={props.actions} />
      {state === 'fetch-failure' ? (
        <Banner
          tone="danger"
          action={
            <Button variant="secondary" size="sm" onClick={retry}>
              {intl.formatMessage({ id: 'assets.common.retry' })}
            </Button>
          }
        >
          {intl.formatMessage({ id: 'assets.common.loadFailed' })}
        </Banner>
      ) : (
        <QueryStateBoundary state={state} onRetry={retry}>
          {anyTruncated(props.queries) && <TruncatedNotice messageId="assets.common.truncated" count={MAX_ROWS} />}
          {props.children}
        </QueryStateBoundary>
      )}
    </>
  )
}

/** The text of a failed write (names the fields of record_payload_invalid, no values). */
export function useErrorText(): (error: unknown) => string {
  const intl = useIntl()
  return (error) =>
    intl.formatMessage({ id: errorMessageId(error) }, { fields: (reasonOf(error).fields ?? []).join(', ') })
}
