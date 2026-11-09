/** AssetCardForm — T-1333 / C13. The create / edit form of the detail panel. Keyed by the record by the page, so a
 *  new selection starts from its values. Kind is chosen on create and read-only afterwards (a change of kind is its
 *  own specification). The depreciation values are typed information: strings, checked against the strict decimal
 *  form, never converted to numbers. The server stays the authority. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { DateField } from '@/components/ui/DateField'
import { Field } from '@/components/ui/Field'
import { FormActions, FormRow, FormSection } from '@/components/ui/FormSection'
import { Select } from '@/components/ui/Select'
import type { EntityRecord } from '@/types/api'
import type { CardBody } from './assets.api'
import {
  ASSET_KINDS,
  DECIMAL_KEYS,
  createBody,
  decimalError,
  fieldMarked,
  formOf,
  textOf,
  updateBody,
  type Form,
} from './assetsModel'
import type { AssetsWriteResult, useAssetsWrite } from './useAssetsWrite'

export type Cmd =
  | { op: 'create'; body: CardBody }
  | { op: 'update'; id: string; body: CardBody }
  | { op: 'retire'; id: string }

export type Write = ReturnType<typeof useAssetsWrite<Cmd>>

export const unitName = (unit: EntityRecord) => textOf(unit, 'name') || textOf(unit, 'code')

export function AssetCardForm(props: {
  record: EntityRecord | null
  write: Write
  onDone: (result: AssetsWriteResult) => void
  onCancel: () => void
}) {
  const { record, write } = props
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const [form, setForm] = useState<Form>(() => formOf(record))
  const initial = formOf(record)
  const isNew = record === null
  const dirty = JSON.stringify(form) !== JSON.stringify(initial)
  const intangible = form.kind === 'intangible'
  const patch = (p: Partial<Form>) => setForm({ ...form, ...p })

  const decimalProblem = (key: (typeof DECIMAL_KEYS)[number]) => {
    const fault = decimalError(form[key])
    return fault === null ? undefined : t(fault === 'format' ? 'assets.error.decimalFormat' : 'assets.error.decimalSize')
  }
  const blocked = DECIMAL_KEYS.some((k) => decimalError(form[k]) !== null)
  const requiredFilled = form.inventory_number.trim() !== '' && form.name.trim() !== ''
  const body = isNew ? createBody(form) : updateBody(initial, form)
  const canSave = !blocked && requiredFilled && (isNew || Object.keys(body).length > 0)

  const invalid = (name: string) => (fieldMarked(write.error, name) ? t('assets.common.fieldInvalid') : undefined)
  const decimalError_ = (key: (typeof DECIMAL_KEYS)[number]) => decimalProblem(key) ?? invalid(key)

  async function save() {
    if (!canSave || write.isPending) return
    const result = await write.submit(
      record === null ? { op: 'create', body } : { op: 'update', id: record.record_id, body },
      record?.record_id ?? '',
    )
    props.onDone(result)
  }

  const decimalField = (key: (typeof DECIMAL_KEYS)[number], label: string) => (
    <Field label={label} width="m" mono optional error={decimalError_(key)}>
      <input name={key} inputMode="decimal" value={form[key]} onChange={(e) => patch({ [key]: e.target.value })} />
    </Field>
  )

  return (
    <form
      className="lf-form"
      aria-label={isNew ? t('assets.page.createTitle') : form.name || form.inventory_number}
      onSubmit={(e) => {
        e.preventDefault()
        void save()
      }}
    >
      <FormSection title={t('assets.section.identity')}>
        <FormRow>
          <Field label={t('assets.field.number')} width="m" mono error={invalid('inventory_number')}>
            <input name="inventory_number" value={form.inventory_number} onChange={(e) => patch({ inventory_number: e.target.value })} />
          </Field>
          <Field label={t('assets.field.name')} width="l" error={invalid('name')}>
            <input name="name" value={form.name} onChange={(e) => patch({ name: e.target.value })} />
          </Field>
        </FormRow>
        <FormRow>
          <Select
            label={t('assets.field.kind')}
            width="m"
            name="kind"
            value={form.kind}
            disabled={!isNew}
            options={ASSET_KINDS.map((k) => ({ value: k, label: t(`assets.kind.${k}`) }))}
            error={invalid('kind')}
            onChange={(v) => patch({ kind: v, ...(v === 'intangible' ? {} : { valid_until: '' }) })}
          />
        </FormRow>
        {isNew && <p className="caption lf-faint">{t('assets.form.holderHint')}</p>}
      </FormSection>
      <FormSection title={t('assets.section.acquisition')}>
        <FormRow>
          <DateField
            label={t('assets.field.acquisitionDate')}
            optional
            value={form.acquisition_date}
            error={invalid('acquisition_date')}
            onChange={(v) => patch({ acquisition_date: v })}
          />
        </FormRow>
        <FormRow>
          <Field label={t('assets.field.currency')} width="s" mono optional hint={t('assets.field.currencyHint')} error={invalid('currency')}>
            <input name="currency" maxLength={3} value={form.currency} onChange={(e) => patch({ currency: e.target.value.toUpperCase() })} />
          </Field>
        </FormRow>
        {intangible && (
          <FormRow>
            <DateField
              label={t('assets.field.validUntil')}
              optional
              value={form.valid_until}
              error={invalid('valid_until')}
              onChange={(v) => patch({ valid_until: v })}
            />
          </FormRow>
        )}
      </FormSection>
      <FormSection title={t('assets.section.depreciation')}>
        <p className="caption lf-faint">{t('assets.section.depHint')}</p>
        <FormRow>
          {decimalField('acquisition_cost', t('assets.field.cost'))}
          {decimalField('accumulated_depreciation', t('assets.field.accumulated'))}
        </FormRow>
        <FormRow>
          {decimalField('book_value', t('assets.field.bookValue'))}
          <DateField
            label={t('assets.field.asOf')}
            optional
            value={form.depreciation_as_of}
            error={invalid('depreciation_as_of')}
            onChange={(v) => patch({ depreciation_as_of: v })}
          />
        </FormRow>
      </FormSection>
      <FormActions
        dirty={dirty}
        saving={write.isPending}
        primary={
          <Button variant="primary" size="md" type="submit" loading={write.isPending} disabled={write.isPending || !canSave} data-testid="asset-save">
            {t('assets.common.save')}
          </Button>
        }
        secondary={
          <Button variant="ghost" size="md" onClick={props.onCancel}>
            {t('assets.common.cancel')}
          </Button>
        }
      />
    </form>
  )
}
