/** LocationsShell — GH 3607 / REQ-671. The shared frame of the locations screens (page header, loading/error through
 *  QueryStateBoundary, toasts), the list query hook and the write-error pieces. */
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
import { fetchAllRecords } from './locations.api'
import { locationsQueryKeys } from './locationsQueryKeys'
import { errorMessageId, reasonOf, textOf } from './locationsModel'

/** All rows of a type matching the filters. `scope` names the filter set in the cache key. */
export function useLocationRows(
  type: string,
  scope: string,
  filters: EntityQueryFilterClause[],
  options: { sortField?: string; enabled?: boolean } = {},
): UseQueryResult<EntityRecord[]> {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  return useQuery({
    queryKey: locationsQueryKeys.list(tenantId, type, scope),
    queryFn: () => fetchAllRecords(type, filters, options.sortField),
    enabled: options.enabled ?? true,
    // a filter change keeps the old rows on screen until the new ones arrive
    placeholderData: keepPreviousData,
    retry: false,
  })
}

export function LocationsShell(props: {
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
              {intl.formatMessage({ id: 'locations.common.retry' })}
            </Button>
          }
        >
          {intl.formatMessage({ id: 'locations.common.loadFailed' })}
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
export function useErrorText(): (error: unknown, link?: boolean) => string {
  const intl = useIntl()
  return (error, link) =>
    intl.formatMessage(
      { id: errorMessageId(error, { link }) },
      { fields: (reasonOf(error).fields ?? []).join(', ') },
    )
}

/** The message of a failed write, as a danger banner. */
export function LocationsErrorAlert({ error, link }: { error: unknown; link?: boolean }) {
  const errorText = useErrorText()
  if (!error) return null
  return (
    <Banner tone="danger">
      <span id="locations-error">{errorText(error, link)}</span>
    </Banner>
  )
}

/** True when the error marks this input: field_invalid / field_not_allowed naming it, or record_payload_invalid
 *  whose field names include it. */
export function fieldMarked(error: unknown, name: string): boolean {
  const info = reasonOf(error)
  const named = info.field === name || (info.fields ?? []).includes(name)
  return (
    (info.reason === 'field_invalid' || info.reason === 'field_not_allowed' || info.reason === 'record_payload_invalid') &&
    named
  )
}

export function labelOf(rows: EntityRecord[], id: string, dash: string): string {
  const row = rows.find((r) => r.record_id === id)
  return row ? textOf(row, 'name') || textOf(row, 'code') : dash
}
