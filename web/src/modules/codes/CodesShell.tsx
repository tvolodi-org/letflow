/** CodesShell — GH 3606 / REQ-672, restyled in S4. The frame of the codes screen (page header with the one primary
 *  action), the list query hook and the text of a failed write. Layout, fields, table, pills and dialogs come
 *  from the shared components; nothing here sets a colour or a spacing. */
import type { ReactNode } from 'react'
import { keepPreviousData, useQuery, type UseQueryResult } from '@tanstack/react-query'
import type { IntlShape } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { PageHeader } from '@/components/ui/PageHeader'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import type { RendererState } from '@/utils/classifyError'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'
import { fetchAllRecords } from './codes.api'
import { codesQueryKeys } from './codesQueryKeys'
import { MAX_BATCH, errorMessageId, reasonOf } from './codesModel'

/** All rows of a type matching the filters. `scope` names the filter set in the cache key. */
export function useCodeRows(
  type: string,
  scope: string,
  filters: EntityQueryFilterClause[],
  options: { sortField?: string; enabled?: boolean } = {},
): UseQueryResult<EntityRecord[]> {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  return useQuery({
    queryKey: codesQueryKeys.list(tenantId, type, scope),
    queryFn: () => fetchAllRecords(type, filters, options.sortField),
    enabled: options.enabled ?? true,
    // a filter change keeps the old rows on screen until the new ones arrive
    placeholderData: keepPreviousData,
    retry: false,
  })
}

export function CodesShell(props: {
  eyebrow: string
  title: string
  lede: string
  actions?: ReactNode
  /** The class of a failed load. Loading and a plain fetch failure are drawn by the list itself (skeleton rows,
   *  banner with retry); the boundary answers the rest (no permission, rate limit). */
  state: RendererState
  onRetry: () => void
  children: ReactNode
}) {
  const boundaryState = props.state === 'fetch-failure' || props.state === 'loading' ? 'success' : props.state
  return (
    <>
      <PageHeader eyebrow={props.eyebrow} title={props.title} lede={props.lede} actions={props.actions} />
      <QueryStateBoundary state={boundaryState} onRetry={props.onRetry}>
        {props.children}
      </QueryStateBoundary>
    </>
  )
}

/** The message of a failed write. Names the fields of record_payload_invalid (no values). */
export function errorText(intl: IntlShape, error: unknown): string | null {
  if (!error) return null
  const info = reasonOf(error)
  return intl.formatMessage({ id: errorMessageId(error) }, { fields: (info.fields ?? []).join(', '), max: MAX_BATCH })
}
