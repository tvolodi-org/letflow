/** OrgListShell — GH 3609 / REQ-669. The shared list frame of the org screens (title, show-retired switch,
 *  loading/error through QueryStateBoundary), the list query hook and the small form pieces. */
import type { ReactNode } from 'react'
import { keepPreviousData, useQuery, type UseQueryResult } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { usersApi } from '@/api/identity'
import { useAuth } from '@/auth/AuthContext'
import { PageLayout } from '@/components/ui/PageLayout'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import type { EntityRecord, User } from '@/types/api'
import { ACTIVE_TRUE, DELETED_FALSE, fetchAllRecords } from './org.api'
import { orgQueryKeys } from './orgQueryKeys'
import { errorMessageId, reasonOf, textOf } from './orgModel'

/** All rows of a type (deleted rows excluded; retired rows only when asked). */
export function useOrgRows(type: string, includeRetired: boolean, unitId = ''): UseQueryResult<EntityRecord[]> {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  return useQuery({
    queryKey: orgQueryKeys.list(tenantId, type, includeRetired, unitId),
    queryFn: () =>
      fetchAllRecords(type, [
        DELETED_FALSE,
        ...(includeRetired ? [] : [ACTIVE_TRUE]),
        ...(unitId !== '' ? [{ field: 'org_unit_id', op: 'eq' as const, value: unitId }] : []),
      ]),
    // a filter change keeps the old rows on screen (and the filter mounted) until the new ones arrive
    placeholderData: keepPreviousData,
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
export function OrgErrorAlert({ error, userLinked }: { error: unknown; userLinked?: boolean }) {
  const intl = useIntl()
  if (!error) return null
  const info = reasonOf(error)
  return (
    <div id="org-error" role="alert" style={{ color: 'var(--color-error-dark)', marginBottom: 'var(--space-3)' }}>
      {intl.formatMessage({ id: errorMessageId(error, { userLinked }) }, { fields: (info.fields ?? []).join(', ') })}
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

/** The unit filter of the position and employee lists; empty value = all units. */
export function OrgUnitFilter(props: { value: string; onChange: (v: string) => void; options: { value: string; label: string }[] }) {
  const intl = useIntl()
  return (
    <OrgSelectField
      name="unit_filter"
      label={intl.formatMessage({ id: 'org.common.unitFilter' })}
      value={props.value}
      options={props.options}
      placeholder={intl.formatMessage({ id: 'org.common.allUnits' })}
      onChange={props.onChange}
    />
  )
}

/** Users of the tenant for the employee user picker. Kept out of the page's list queries: a 403 (no UsersManage)
 *  must not blank the screen. */
export function useUserSearch(search: string, enabled: boolean): UseQueryResult<User[]> {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  return useQuery({
    queryKey: orgQueryKeys.users(tenantId, search),
    queryFn: async () => (await usersApi.list({ search: search || undefined, page_size: 20 })).items,
    enabled,
    retry: false,
  })
}

export function labelOf(rows: EntityRecord[], id: string, dash: string): string {
  const row = rows.find((r) => r.record_id === id)
  return row ? textOf(row, 'name') || textOf(row, 'code') : dash
}
