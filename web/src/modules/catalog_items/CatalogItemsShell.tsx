/** CatalogItemsShell — GH 3605 / REQ-673. The frame of the catalog_items screen (title, loading/error through
 *  QueryStateBoundary), the list query hook and the small form pieces. */
import type { ReactNode } from 'react'
import { keepPreviousData, useQuery, type UseQueryResult } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { PageLayout } from '@/components/ui/PageLayout'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'
import { fetchAllRecords } from './catalogItems.api'
import { catalogItemsQueryKeys } from './catalogItemsQueryKeys'
import { errorMessageId } from './catalogItemsModel'

/** All rows of a type matching the filters. `scope` names the filter set in the cache key. */
export function useLotRows(
  type: string,
  scope: string,
  filters: EntityQueryFilterClause[],
  options: { sortField?: string; enabled?: boolean } = {},
): UseQueryResult<EntityRecord[]> {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  return useQuery({
    queryKey: catalogItemsQueryKeys.list(tenantId, type, scope),
    queryFn: () => fetchAllRecords(type, filters, options.sortField),
    enabled: options.enabled ?? true,
    placeholderData: keepPreviousData,
    retry: false,
  })
}

export function CatalogItemsShell(props: { title: string; queries: UseQueryResult<unknown>[]; children: ReactNode; header?: ReactNode }) {
  const failed = props.queries.find((q) => q.isError)
  const state: RendererState = failed
    ? classifyError(failed.error)
    : props.queries.some((q) => q.isPending && q.fetchStatus !== 'idle')
      ? 'loading'
      : 'success'
  return (
    <PageLayout title={props.title}>
      {props.header}
      <QueryStateBoundary state={state} onRetry={() => props.queries.forEach((q) => void q.refetch())}>
        {props.children}
      </QueryStateBoundary>
    </PageLayout>
  )
}

/** The message of a failed write, as an alert. */
export function CatalogItemsErrorAlert({ error, id = 'catalog-items-error' }: { error: unknown; id?: string }) {
  const intl = useIntl()
  if (!error) return null
  return (
    <div id={id} role="alert" style={{ color: 'var(--color-error-dark)', marginBottom: 'var(--space-3)' }}>
      {intl.formatMessage({ id: errorMessageId(error) })}
    </div>
  )
}

export function TextField(props: {
  name: string
  label: string
  value: string
  onChange: (v: string) => void
  invalid?: boolean
  readOnly?: boolean
}) {
  const id = `catalog-items-field-${props.name}`
  return (
    <div style={{ marginBottom: 'var(--space-3)' }}>
      <label htmlFor={id} style={{ display: 'block' }}>
        {props.label}
      </label>
      <input
        id={id}
        name={props.name}
        value={props.value}
        aria-invalid={props.invalid ? true : undefined}
        readOnly={props.readOnly}
        onChange={(e) => props.onChange(e.target.value)}
      />
    </div>
  )
}

export function SelectField(props: {
  name: string
  label: string
  value: string
  onChange: (v: string) => void
  options: { value: string; label: string }[]
  placeholder: string
}) {
  const id = `catalog-items-field-${props.name}`
  return (
    <div style={{ marginBottom: 'var(--space-3)' }}>
      <label htmlFor={id} style={{ display: 'block' }}>
        {props.label}
      </label>
      <select id={id} name={props.name} value={props.value} onChange={(e) => props.onChange(e.target.value)}>
        <option value="">{props.placeholder}</option>
        {props.options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </div>
  )
}

export function DateField(props: {
  name: string
  label: string
  value: string
  onChange: (v: string) => void
  invalid?: boolean
}) {
  const id = `catalog-items-field-${props.name}`
  return (
    <div style={{ marginBottom: 'var(--space-3)' }}>
      <label htmlFor={id} style={{ display: 'block' }}>
        {props.label}
      </label>
      <input
        id={id}
        name={props.name}
        type="date"
        value={props.value}
        aria-invalid={props.invalid ? true : undefined}
        onChange={(e) => props.onChange(e.target.value)}
      />
    </div>
  )
}
