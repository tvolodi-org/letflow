/** AssetCountOrderForm — T-1933 / REQ-822 (K7a). Create and edit of a draft asset count order in the detail panel (never
 *  a modal). Sends the whole draft (all nine keys) with the full lists; times are read in the tenant zone. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Checkbox } from '@/components/ui/Checkbox'
import { DateTimeField } from '@/components/ui/DateField'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { Field } from '@/components/ui/Field'
import { FormActions } from '@/components/ui/FormSection'
import { Select } from '@/components/ui/Select'
import { TruncatedNotice } from '@/components/ui/TruncatedNotice'
import { useToast } from '@/hooks/useToast'
import { MAX_ROWS } from '@/lib/entities/fetchAllRecords'
import { anyPickerTruncated, usePickerOptions } from '../assetsPickers'
import { assetCountsApi, type AssetCountOrder } from './assetCounts.api'
import {
  COUNT_KINDS, EMPTY_ORDER_FORM, buildOrderBody, fieldOf, formFromOrder, orderFormProblems, reasonMessageId,
  type OrderField, type OrderForm,
} from './assetCountsModel'
import { useAssetCountsWrite } from './useAssetCountsWrite'

const NONE: never[] = []
const RENDERED = ['org_unit_id', 'kinds', 'planned_start', 'planned_end', 'chair_employee_id', 'member_employee_ids', 'location_ids', 'note']
const FIELD_LABEL: Record<OrderField, string> = {
  org_unit_id: 'assets.count.form.orgUnit',
  kinds: 'assets.count.form.kinds',
  planned_start: 'assets.count.form.plannedStart',
  planned_end: 'assets.count.form.plannedEnd',
  chair_employee_id: 'assets.count.form.chair',
}

export function AssetCountOrderForm({ order, onSaved, onDiscard }: { order?: AssetCountOrder; onSaved: (o: AssetCountOrder) => void; onDiscard: () => void }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const toast = useToast()
  const [form, setForm] = useState<OrderForm>(order ? formFromOrder(order) : EMPTY_ORDER_FORM)
  const [problems, setProblems] = useState<OrderField[]>([])
  const units = usePickerOptions('org_unit', NONE)
  const people = usePickerOptions('org_employee', NONE)
  const locations = usePickerOptions('location_node', NONE)
  const write = useAssetCountsWrite((body: ReturnType<typeof buildOrderBody>) =>
    order ? assetCountsApi.update(order.id, body) : assetCountsApi.create(body),
  )
  const clear = (key: OrderField) => setProblems((p) => p.filter((x) => x !== key))
  const set = <K extends keyof OrderForm>(key: K) => (value: OrderForm[K]) => {
    setForm((f) => ({ ...f, [key]: value }))
    clear(key as OrderField)
    if (key === 'planned_start') clear('planned_end')
  }
  const toggle = (key: 'member_employee_ids' | 'location_ids' | 'kinds', id: string, on: boolean) => {
    setForm((f) => ({ ...f, [key]: on ? [...f[key], id] : f[key].filter((x) => x !== id) }))
    if (key === 'kinds') clear('kinds')
  }

  async function save() {
    const found = orderFormProblems(form)
    setProblems(found)
    if (found.length > 0) return
    const res = await write.submit(buildOrderBody(form))
    if (res.ok) {
      toast.success(t(order ? 'assets.count.toast.saved' : 'assets.count.toast.created'))
      onSaved(res.data)
    }
  }

  const field = fieldOf(write.error)
  const errorText = write.error ? t(reasonMessageId(write.error)) : undefined
  const localErr = (name: OrderField) => {
    if (!problems.includes(name)) return undefined
    const endOrder = name === 'planned_end' && form.planned_end !== '' && form.planned_start !== ''
    return t(endOrder ? 'assets.count.form.endOrder' : `assets.count.form.err.${name}`)
  }
  const err = (name: string) => localErr(name as OrderField) ?? (field === name ? errorText : undefined)
  const memberChoices = people.filter((p) => p.value !== form.chair_employee_id)
  // a server error that names no field of this form is shown once, in the banner
  const bannerError = errorText !== undefined && (field === null || !RENDERED.includes(field)) ? errorText : undefined

  return (
    <>
      {anyPickerTruncated(units, people, locations) && <TruncatedNotice messageId="assets.pickers.truncated" count={MAX_ROWS} />}
      <DetailHeader
        title={t(order ? 'assets.count.form.titleEdit' : 'assets.count.form.titleCreate')}
        actions={<Button variant="ghost" size="sm" onClick={onDiscard} data-testid="count-discard">{t('assets.count.form.discard')}</Button>}
      />
      <div className="lf-card__body lf-form" data-testid="count-order-form">
        {problems.length > 0 && (
          <Banner tone="warning">
            {intl.formatMessage({ id: 'assets.count.form.required' }, { fields: problems.map((p) => t(FIELD_LABEL[p])).join(', ') })}
          </Banner>
        )}
        {bannerError !== undefined && <Banner tone="danger">{bannerError}</Banner>}
        <Select
          name="org_unit_id"
          label={t('assets.count.form.orgUnit')}
          value={form.org_unit_id}
          onChange={set('org_unit_id')}
          options={units}
          placeholder={t('assets.count.form.select')}
          error={err('org_unit_id')}
        />
        <fieldset className="lf-field" data-testid="kinds">
          <legend className="lf-label">{t('assets.count.form.kinds')}</legend>
          {COUNT_KINDS.map((k) => (
            <Checkbox key={k} label={t(`assets.kind.${k}`)} checked={form.kinds.includes(k)} onChange={(on) => toggle('kinds', k, on)} data-testid={`kind-${k}`} />
          ))}
          {err('kinds') && <span className="lf-error">{err('kinds')}</span>}
        </fieldset>
        <DateTimeField label={t('assets.count.form.plannedStart')} error={err('planned_start')} value={form.planned_start} onChange={set('planned_start')} />
        <DateTimeField label={t('assets.count.form.plannedEnd')} error={err('planned_end')} value={form.planned_end} onChange={set('planned_end')} />
        <span className="lf-hint">{t('assets.count.form.timeHint')}</span>
        <Select
          name="chair_employee_id"
          label={t('assets.count.form.chair')}
          value={form.chair_employee_id}
          onChange={(v) => setForm((f) => ({ ...f, chair_employee_id: v, member_employee_ids: f.member_employee_ids.filter((m) => m !== v) }))}
          options={people}
          placeholder={t('assets.count.form.select')}
          error={err('chair_employee_id')}
        />
        <fieldset className="lf-field" data-testid="members">
          <legend className="lf-label">{t('assets.count.form.members')}</legend>
          {memberChoices.map((p) => (
            <Checkbox key={p.value} label={p.label} checked={form.member_employee_ids.includes(p.value)} onChange={(on) => toggle('member_employee_ids', p.value, on)} />
          ))}
          {err('member_employee_ids') && <span className="lf-error">{err('member_employee_ids')}</span>}
        </fieldset>
        <fieldset className="lf-field" data-testid="locations">
          <legend className="lf-label">{t('assets.count.form.locations')}</legend>
          <span className="lf-hint">{t('assets.count.form.locationsHint')}</span>
          {locations.map((l) => (
            <Checkbox key={l.value} label={l.label} checked={form.location_ids.includes(l.value)} onChange={(on) => toggle('location_ids', l.value, on)} />
          ))}
          {err('location_ids') && <span className="lf-error">{err('location_ids')}</span>}
        </fieldset>
        <Checkbox label={t('assets.count.form.freeze')} checked={form.freeze_locations} onChange={set('freeze_locations')} data-testid="freeze" />
        <Field label={t('assets.count.form.note')} optional error={err('note')}>
          <textarea name="note" rows={3} value={form.note} onChange={(e) => set('note')(e.target.value)} />
        </Field>
        <FormActions
          primary={
            <Button variant="primary" size="md" loading={write.isPending} onClick={() => void save()} data-testid="count-save">
              {t('assets.count.form.save')}
            </Button>
          }
          saving={write.isPending}
        />
      </div>
    </>
  )
}
