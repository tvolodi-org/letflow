/** LocationsShell — GH 3607 / REQ-671. The shared frame of the locations screens (title, loading/error through
 *  QueryStateBoundary), the list query hook and the small form pieces. */
import type { ReactNode } from 'react'
import { keepPreviousData, useQuery, type UseQueryResult } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { PageLayout } from '@/components/ui/PageLayout'
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
  queries: UseQueryResult<unknown>[]
  showRetired?: boolean
  onShowRetired?: (v: boolean) => void
  actions?: ReactNode
  children: ReactNode
}) {
  const intl = useIntl()
  const failed = props.queries.find((q) => q.isError)
  const state: RendererState = failed
    ? classifyError(failed.error)
    : props.queries.some((q) => q.isPending && q.fetchStatus !== 'idle')
      ? 'loading'
      : 'success'
  return (
    <PageLayout title={props.title} actions={props.actions}>
      {props.onShowRetired && (
        <label style={{ display: 'inline-flex', gap: 'var(--space-2)', marginBottom: 'var(--space-4)' }}>
          <input
            type="checkbox"
            checked={props.showRetired ?? false}
            onChange={(e) => props.onShowRetired?.(e.target.checked)}
          />
          {intl.formatMessage({ id: 'locations.common.showRetired' })}
        </label>
      )}
      <QueryStateBoundary state={state} onRetry={() => props.queries.forEach((q) => void q.refetch())}>
        {props.children}
      </QueryStateBoundary>
    </PageLayout>
  )
}

/** The message of a failed write, as an alert. Names the fields of record_payload_invalid (no values). */
export function LocationsErrorAlert({ error, link }: { error: unknown; link?: boolean }) {
  const intl = useIntl()
  if (!error) return null
  const info = reasonOf(error)
  return (
    <div id="locations-error" role="alert" style={{ color: 'var(--color-error-dark)', marginBottom: 'var(--space-3)' }}>
      {intl.formatMessage({ id: errorMessageId(error, { link }) }, { fields: (info.fields ?? []).join(', ') })}
    </div>
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

export function TextField(props: {
  name: string
  label: string
  value: string
  onChange: (v: string) => void
  invalid?: boolean
  readOnly?: boolean
  list?: string
}) {
  const id = `locations-field-${props.name}`
  return (
    <div style={{ marginBottom: 'var(--space-3)' }}>
      <label htmlFor={id} style={{ display: 'block' }}>
        {props.label}
      </label>
      <input
        id={id}
        name={props.name}
        value={props.value}
        readOnly={props.readOnly}
        list={props.list}
        aria-invalid={props.invalid ? true : undefined}
        aria-describedby={props.invalid ? 'locations-error' : undefined}
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
  invalid?: boolean
}) {
  const id = `locations-field-${props.name}`
  return (
    <div style={{ marginBottom: 'var(--space-3)' }}>
      <label htmlFor={id} style={{ display: 'block' }}>
        {props.label}
      </label>
      <select
        id={id}
        name={props.name}
        value={props.value}
        aria-invalid={props.invalid ? true : undefined}
        aria-describedby={props.invalid ? 'locations-error' : undefined}
        onChange={(e) => props.onChange(e.target.value)}
      >
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

export function labelOf(rows: EntityRecord[], id: string, dash: string): string {
  const row = rows.find((r) => r.record_id === id)
  return row ? textOf(row, 'name') || textOf(row, 'code') : dash
}
