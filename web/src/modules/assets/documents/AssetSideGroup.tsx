/** AssetSideGroup — T-1469 / C14 part 2. One side (From or To) of a change or hand over: a labelled group of the fields it
 *  shows. `bare` renders the same fields without the group frame (the shared org unit and location of a change, and the
 *  single side of a commission or write off). A refusal that names the whole side shows under the legend. The option
 *  lists come from the form, which loads each picker once. */
import { Fragment, type ReactNode } from 'react'
import { useIntl } from 'react-intl'
import { DocEdit } from '@/components/ui/doc/DocLayout'
import { Select, type SelectOption } from '@/components/ui/Select'
import type { SideForm } from './documentForm'

export type SideField = keyof SideForm

export interface AssetSideGroupProps {
  side: 'from' | 'to'
  value: SideForm
  onChange: (patch: Partial<SideForm>) => void
  /** Message ids by key: `side.<side>` (whole group) and `side.<side>.<field>`. */
  errors: Record<string, string>
  fields: readonly SideField[]
  orgUnits: SelectOption[]
  locations: SelectOption[]
  employees: SelectOption[]
  bare?: boolean
  /** Edit mode: this side's org unit is the document's org unit and cannot change. */
  orgUnitFixed?: boolean
}

export function AssetSideGroup({ side, value, onChange, errors, fields, orgUnits, locations, employees, bare, orgUnitFixed }: AssetSideGroupProps) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const err = (field: string) => (errors[`side.${side}.${field}`] ? t(errors[`side.${side}.${field}`]) : undefined)
  const pick = t('assets.doc.pick')
  const none = t('assets.doc.pickNone')
  const controls: Record<SideField, ReactNode> = {
    orgUnitId: (
      <Select
        label={t('assets.reg.col.orgUnit')}
        value={value.orgUnitId}
        onChange={(orgUnitId) => onChange({ orgUnitId })}
        options={orgUnits}
        placeholder={pick}
        error={err('orgUnitId')}
        disabled={orgUnitFixed}
        hint={orgUnitFixed ? t('assets.doc.orgUnitFixed') : undefined}
      />
    ),
    locationId: (
      <Select label={t('assets.reg.col.location')} value={value.locationId} onChange={(locationId) => onChange({ locationId })} options={locations} placeholder={none} error={err('locationId')} optional />
    ),
    responsibleId: (
      <Select label={t('assets.reg.col.responsible')} value={value.responsibleId} onChange={(responsibleId) => onChange({ responsibleId })} options={employees} placeholder={pick} error={err('responsibleId')} />
    ),
    userId: (
      <Select label={t('assets.reg.col.user')} value={value.userId} onChange={(userId) => onChange({ userId })} options={employees} placeholder={none} error={err('userId')} optional />
    ),
  }
  if (bare) {
    return (
      <>
        {fields.map((f) => (
          <DocEdit key={f} full>{controls[f]}</DocEdit>
        ))}
      </>
    )
  }
  const group = errors[`side.${side}`]
  const label = t(`assets.doc.side.${side}`)
  return (
    <fieldset data-testid={`side-${side}`} aria-label={label} className="lf-doc__group">
      <legend>{label}</legend>
      {group && <p role="alert">{t(group)}</p>}
      <div className="lf-doc__fields">
        {fields.map((f) => (
          <Fragment key={f}>{controls[f]}</Fragment>
        ))}
      </div>
    </fieldset>
  )
}
