/** CodesShell — GH 3606 / REQ-672. The frame of the codes screen (title, loading/error through QueryStateBoundary),
 *  the list query hook and the small form pieces. */
import type { ReactNode } from 'react'
import { keepPreviousData, useQuery, type UseQueryResult } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { PageLayout } from '@/components/ui/PageLayout'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
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

export function CodesShell(props: { title: string; queries: UseQueryResult<unknown>[]; children: ReactNode }) {
  const failed = props.queries.find((q) => q.isError)
  const state: RendererState = failed
    ? classifyError(failed.error)
    : props.queries.some((q) => q.isPending && q.fetchStatus !== 'idle')
      ? 'loading'
      : 'success'
  return (
    <PageLayout title={props.title}>
      <QueryStateBoundary state={state} onRetry={() => props.queries.forEach((q) => void q.refetch())}>
        {props.children}
      </QueryStateBoundary>
    </PageLayout>
  )
}

/** The message of a failed write, as an alert. Names the fields of record_payload_invalid (no values). */
export function CodesErrorAlert({ error, id = 'codes-error' }: { error: unknown; id?: string }) {
  const intl = useIntl()
  if (!error) return null
  const info = reasonOf(error)
  return (
    <div id={id} role="alert" style={{ color: 'var(--color-error-dark)', marginBottom: 'var(--space-3)' }}>
      {intl.formatMessage({ id: errorMessageId(error) }, { fields: (info.fields ?? []).join(', '), max: MAX_BATCH })}
    </div>
  )
}

export function TextField(props: {
  name: string
  label: string
  value: string
  onChange: (v: string) => void
  invalid?: boolean
}) {
  const id = `codes-field-${props.name}`
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
  const id = `codes-field-${props.name}`
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
