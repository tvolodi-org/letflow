/** SideGroup — GH 3853 / REQ-723. One side (From or To) of a transfer, hand over or return: org unit, location and
 *  responsible in a labelled group. A refusal that names the whole side (not_linked, employee_not_active) shows under
 *  the legend. The option lists come from the form, which loads each picker once for both groups. */
import { useIntl } from 'react-intl'
import { Select, type SelectOption } from '@/components/ui/Select'
import type { SideForm } from './documentsModel'

export interface SideGroupProps {
  side: 'from' | 'to'
  value: SideForm
  onChange: (patch: Partial<SideForm>) => void
  /** Message ids by key: `side.<side>` (whole group) and `side.<side>.<field>`. */
  errors: Record<string, string>
  orgUnits: SelectOption[]
  locations: SelectOption[]
  employees: SelectOption[]
  /** Edit mode: this side's org unit is the document's org unit and cannot change. */
  orgUnitFixed?: boolean
}

export function SideGroup({ side, value, onChange, errors, orgUnits, locations, employees, orgUnitFixed }: SideGroupProps) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const err = (field: string) => (errors[`side.${side}.${field}`] ? t(errors[`side.${side}.${field}`]) : undefined)
  const group = errors[`side.${side}`]
  const label = t(`stock.doc.side.${side}`)
  return (
    <fieldset data-testid={`side-${side}`} aria-label={label} className="lf-side-group">
      <legend>{label}</legend>
      {group && <p role="alert">{t(group)}</p>}
      <Select
        label={t('stock.col.orgUnit')}
        value={value.orgUnitId}
        onChange={(orgUnitId) => onChange({ orgUnitId })}
        options={orgUnits}
        placeholder={t('stock.doc.pick')}
        error={err('orgUnitId')}
        disabled={orgUnitFixed}
        hint={orgUnitFixed ? t('stock.doc.orgUnitFixed') : undefined}
      />
      <Select
        label={t('stock.col.location')}
        value={value.locationId}
        onChange={(locationId) => onChange({ locationId })}
        options={locations}
        placeholder={t('stock.doc.pick')}
        error={err('locationId')}
      />
      <Select
        label={t('stock.col.responsible')}
        value={value.responsibleId}
        onChange={(responsibleId) => onChange({ responsibleId })}
        options={employees}
        placeholder={t('stock.doc.pick')}
        error={err('responsibleId')}
      />
    </fieldset>
  )
}
