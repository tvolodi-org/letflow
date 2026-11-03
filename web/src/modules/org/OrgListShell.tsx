/** OrgListShell — GH 3609 / REQ-669. The list query hook and the small form pieces shared by the org screens
 *  (the page frame is OrgScreen). The query hooks here only return results: OrgScreen shows their loading skeleton and
 *  load error itself, in place of a QueryStateBoundary. */
import { keepPreviousData, useQuery, type UseQueryResult } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { usersApi } from '@/api/identity'
import { useAuth } from '@/auth/AuthContext'
import { Banner } from '@/components/ui/Banner'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import type { EntityRecord, User } from '@/types/api'
import { ACTIVE_TRUE, DELETED_FALSE, fetchAllRecords } from './org.api'
import { orgQueryKeys } from './orgQueryKeys'
import { useOrgLocale } from './OrgIntlProvider'
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

/** The message of a failed write, as a danger banner. Names the fields of record_payload_invalid (no values). */
export function OrgErrorAlert({ error, userLinked }: { error: unknown; userLinked?: boolean }) {
  const intl = useIntl()
  if (!error) return null
  const info = reasonOf(error)
  return (
    <Banner tone="danger">
      {intl.formatMessage({ id: errorMessageId(error, { userLinked }) }, { fields: (info.fields ?? []).join(', ') })}
    </Banner>
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

/** A text input in the design system's Field. `invalid` marks it with the generic field message;
 *  `error` (a ready text) wins over it and is shown next to the field. */
export function OrgTextField(props: {
  name: string
  label: string
  value: string
  onChange: (v: string) => void
  invalid?: boolean
  error?: string
  hint?: string
  readOnly?: boolean
  numeric?: boolean
  mono?: boolean
  maxLength?: number
  width?: 's' | 'm' | 'l'
}) {
  const intl = useIntl()
  const locale = useOrgLocale()
  const error = props.error ?? (props.invalid ? intl.formatMessage({ id: 'org.error.field_invalid' }) : undefined)
  return (
    <Field
      label={props.label}
      error={error}
      hint={props.hint}
      readOnly={props.readOnly}
      mono={props.mono}
      width={props.width}
      locale={locale}
    >
      <input
        id={`org-field-${props.name}`}
        name={props.name}
        value={props.value}
        inputMode={props.numeric ? 'numeric' : undefined}
        maxLength={props.maxLength}
        onChange={(e) => props.onChange(e.target.value)}
      />
    </Field>
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
  disabled?: boolean
  hint?: string
  width?: 's' | 'm' | 'l'
}) {
  const intl = useIntl()
  const locale = useOrgLocale()
  return (
    <Select
      name={props.name}
      label={props.label}
      value={props.value}
      options={props.options}
      placeholder={props.placeholder}
      onChange={props.onChange}
      error={props.invalid ? intl.formatMessage({ id: 'org.error.field_invalid' }) : undefined}
      hint={props.hint}
      disabled={props.disabled}
      width={props.width}
      locale={locale}
    />
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
