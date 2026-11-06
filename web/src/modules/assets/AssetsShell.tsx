/** AssetsShell — T-1333 / C13. The shared frame of the asset card screen (page header, loading/error through
 *  QueryStateBoundary), the two list query hooks and the write-error pieces. */
import type { ReactNode } from 'react'
import { keepPreviousData, useQuery, type UseQueryResult } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { PageHeader } from '@/components/ui/PageHeader'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'
import { ACTIVE_TRUE, DELETED_FALSE, fetchAllRecords } from './assets.api'
import { assetsQueryKeys } from './assetsQueryKeys'
import { ASSET_CARD, ORG_UNIT, errorMessageId, reasonOf } from './assetsModel'

export interface CardFilters {
  kind: string
  orgUnitId: string
  showRetired: boolean
}

/** The cards matching the server-side filters (kind, org unit, retired). A filter change keeps the old rows on
 *  screen until the new ones arrive. */
export function useAssetRows(filters: CardFilters): UseQueryResult<EntityRecord[]> {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const clauses: EntityQueryFilterClause[] = [
    DELETED_FALSE,
    ...(filters.showRetired ? [] : [ACTIVE_TRUE]),
    ...(filters.kind !== '' ? [{ field: 'kind', op: 'eq' as const, value: filters.kind }] : []),
    ...(filters.orgUnitId !== '' ? [{ field: 'org_unit_id', op: 'eq' as const, value: filters.orgUnitId }] : []),
  ]
  const scope = [filters.showRetired ? 'all' : 'active', filters.kind, filters.orgUnitId].join('|')
  return useQuery({
    queryKey: assetsQueryKeys.list(tenantId, ASSET_CARD, scope),
    queryFn: () => fetchAllRecords(ASSET_CARD, clauses),
    placeholderData: keepPreviousData,
    retry: false,
  })
}

/** All org units (retired ones too, so a card of a retired unit still shows the unit's name). */
export function useOrgUnitRows(): UseQueryResult<EntityRecord[]> {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  return useQuery({
    queryKey: assetsQueryKeys.list(tenantId, ORG_UNIT, 'all'),
    queryFn: () => fetchAllRecords(ORG_UNIT, [DELETED_FALSE], 'code'),
    retry: false,
  })
}

export function AssetsShell(props: {
  title: string
  eyebrow?: string
  lede?: string
  queries: UseQueryResult<unknown>[]
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
