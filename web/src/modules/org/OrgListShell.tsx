/** OrgListShell — GH 3609 / REQ-669. The shared list frame of the org screens (title, show-retired switch,
 *  loading/error through QueryStateBoundary), the list query hook and the small form pieces. */
import type { ReactNode } from 'react'
import { useQuery, type UseQueryResult } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { PageLayout } from '@/components/ui/PageLayout'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import type { EntityRecord } from '@/types/api'
import { ACTIVE_TRUE, DELETED_FALSE, fetchAllRecords } from './org.api'
import { orgQueryKeys } from './orgQueryKeys'
import { errorMessageId, reasonOf, textOf } from './orgModel'

/** All rows of a type (deleted rows excluded; retired rows only when asked). */
export function useOrgRows(type: string, includeRetired: boolean): UseQueryResult<EntityRecord[]> {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  return useQuery({
    queryKey: orgQueryKeys.list(tenantId, type, includeRetired),
    queryFn: () => fetchAllRecords(type, includeRetired ? [DELETED_FALSE] : [DELETED_FALSE, ACTIVE_TRUE]),
    retry: false,
  })
}

export function OrgListShell(props: {
  title: string
  queries: UseQueryResult<unknown>[]
  showRetired: boolean
  onShowRetired: (v: boolean) => void
  actions?: ReactNode
  children: ReactNode
}) {
  const intl = useIntl()
  const failed = props.queries.find((q) => q.isError)
  const state: RendererState = failed
    ? classifyError(failed.error)
    : props.queries.some((q) => q.isPending)
      ? 'loading'
      : 'success'
  return (
    <PageLayout title={props.title} actions={props.actions}>
      <label style={{ display: 'inline-flex', gap: 'var(--space-2)', marginBottom: 'var(--space-4)' }}>
        <input
          type="checkbox"
          checked={props.showRetired}
          onChange={(e) => props.onShowRetired(e.target.checked)}
        />
        {intl.formatMessage({ id: 'org.common.showRetired' })}
      </label>
      <QueryStateBoundary state={state} onRetry={() => props.queries.forEach((q) => void q.refetch())}>
        {props.children}
      </QueryStateBoundary>
    </PageLayout>
  )
}

/** The message of a failed write, as an alert. Names the fields of record_payload_invalid (no values). */
export function OrgErrorAlert({ error }: { error: unknown }) {
  const intl = useIntl()
  if (!error) return null
  const info = reasonOf(error)
  return (
    <div id="org-error" role="alert" style={{ color: 'var(--color-error-dark)', marginBottom: 'var(--space-3)' }}>
      {intl.formatMessage({ id: errorMessageId(error) }, { fields: (info.fields ?? []).join(', ') })}
    </div>
  )
}

/** True when the error marks this input (field_invalid / field_not_allowed naming it). */
export function fieldMarked(error: unknown, name: string): boolean {
  const info = reasonOf(error)
  return (
    (info.reason === 'field_invalid' || info.reason === 'field_not_allowed') &&
    (info.field === name || (info.fields ?? []).includes(name))
  )
}

export function OrgTextField(props: {
  name: string
  label: string
  value: string
  onChange: (v: string) => void
  invalid?: boolean
  readOnly?: boolean
  numeric?: boolean
  maxLength?: number
}) {
  const id = `org-field-${props.name}`
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
        inputMode={props.numeric ? 'numeric' : undefined}
        maxLength={props.maxLength}
        aria-invalid={props.invalid ? true : undefined}
        aria-describedby={props.invalid ? 'org-error' : undefined}
        onChange={(e) => props.onChange(e.target.value)}
      />
    </div>
  )
}

export function OrgSelectField(props: {
  name: string
  label: string
  value: string
  onChange: (v: string) => void
  options: { value: string; label: string }[]
  placeholder: string
  invalid?: boolean
}) {
  const id = `org-field-${props.name}`
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
        aria-describedby={props.invalid ? 'org-error' : undefined}
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
