/** CountOrderForm — GH 3735 / REQ-702. Create and edit of a draft count order in the detail panel (never a modal).
 *  Sends the whole draft (every key of REQ-700 criterion 2) with the full lists. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Checkbox } from '@/components/ui/Checkbox'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { Field } from '@/components/ui/Field'
import { FormActions } from '@/components/ui/FormSection'
import { Select } from '@/components/ui/Select'
import { useToast } from '@/hooks/useToast'
import { usePickerOptions } from '../register/stockPickers'
import { countsApi, type CountOrder } from './counts.api'
import { COUNT_KINDS, EMPTY_ORDER_FORM, buildOrderBody, fieldOf, formFromOrder, orderFormProblems, reasonMessageId, type OrderField, type OrderForm } from './countsModel'
import { useCountsWrite } from './useCountsWrite'

const NONE: never[] = []
const FIELD_LABEL: Record<OrderField, string> = {
  org_unit_id: 'counts.form.orgUnit',
  planned_start: 'counts.form.plannedStart',
  planned_end: 'counts.form.plannedEnd',
  chair_employee_id: 'counts.form.chair',
  location_ids: 'counts.form.locations',
}

export function CountOrderForm({ order, onSaved, onDiscard }: { order?: CountOrder; onSaved: (o: CountOrder) => void; onDiscard: () => void }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const toast = useToast()
  const [form, setForm] = useState<OrderForm>(order ? formFromOrder(order) : EMPTY_ORDER_FORM)
  const [problems, setProblems] = useState<OrderField[]>([])
  const units = usePickerOptions('org_unit', NONE)
  const people = usePickerOptions('org_employee', NONE)
  const locations = usePickerOptions('location_node', NONE)
  const write = useCountsWrite((body: ReturnType<typeof buildOrderBody>) =>
    order ? countsApi.update(order.id, body) : countsApi.create(body),
  )
  const clear = (key: OrderField) => setProblems((p) => p.filter((x) => x !== key))
  const set = <K extends keyof OrderForm>(key: K) => (value: OrderForm[K]) => {
    setForm((f) => ({ ...f, [key]: value }))
    clear(key as OrderField)
    if (key === 'planned_start') clear('planned_end')
  }
  const toggle = (key: 'member_employee_ids' | 'location_ids', id: string, on: boolean) =>
    {
      setForm((f) => ({ ...f, [key]: on ? [...f[key], id] : f[key].filter((x) => x !== id) }))
      if (key === 'location_ids') clear('location_ids')
    }

  async function save() {
    const found = orderFormProblems(form)
    setProblems(found)
    if (found.length > 0) return
    const res = await write.submit(buildOrderBody(form))
    if (res.ok) {
      toast.success(t(order ? 'counts.toast.saved' : 'counts.toast.created'))
      onSaved(res.data)
    }
  }

  const field = fieldOf(write.error)
  const errorText = write.error ? t(reasonMessageId(write.error)) : undefined
  const localErr = (name: OrderField) => {
    if (!problems.includes(name)) return undefined
    const endOrder = name === 'planned_end' && form.planned_end !== '' && form.planned_start !== ''
    return t(endOrder ? 'counts.form.endBeforeStart' : `counts.form.err.${name}`)
  }
  const err = (name: string) => localErr(name as OrderField) ?? (field === name ? errorText : undefined)
  const memberChoices = people.filter((p) => p.value !== form.chair_employee_id)

  return (
    <>
      <DetailHeader
        title={t(order ? 'counts.form.titleEdit' : 'counts.form.titleCreate')}
        actions={<Button variant="ghost" size="sm" onClick={onDiscard}>{t('counts.form.discard')}</Button>}
      />
      <div className="lf-card__body lf-form" data-testid="count-order-form">
        {problems.length > 0 && (
          <Banner tone="warning">
            <span>{t('counts.form.required')}</span>{' '}
            <span>{intl.formatMessage({ id: 'counts.form.summary' }, { fields: problems.map((p) => t(FIELD_LABEL[p])).join(', ') })}</span>
          </Banner>
        )}
        {errorText !== undefined && <Banner tone="danger">{errorText}</Banner>}
        <Select
          name="org_unit_id"
          label={t('counts.form.orgUnit')}
          value={form.org_unit_id}
          onChange={set('org_unit_id')}
          options={units}
          placeholder={t('counts.form.select')}
          error={err('org_unit_id')}
        />
        <Select
          name="kind"
          label={t('counts.form.kind')}
          width="s"
          value={form.kind}
          onChange={set('kind')}
          options={COUNT_KINDS.map((k) => ({ value: k, label: t(`counts.kind.${k}`) }))}
          error={err('kind')}
        />
        <Field label={t('counts.form.plannedStart')} hint={t('counts.form.timeHint')} width="m" error={err('planned_start')}>
          <input type="datetime-local" name="planned_start" value={form.planned_start} onChange={(e) => set('planned_start')(e.target.value)} />
        </Field>
        <Field label={t('counts.form.plannedEnd')} width="m" error={err('planned_end')}>
          <input type="datetime-local" name="planned_end" value={form.planned_end} onChange={(e) => set('planned_end')(e.target.value)} />
        </Field>
        <Select
          name="chair_employee_id"
          label={t('counts.form.chair')}
          value={form.chair_employee_id}
          onChange={(v) => setForm((f) => ({ ...f, chair_employee_id: v, member_employee_ids: f.member_employee_ids.filter((m) => m !== v) }))}
          options={people}
          placeholder={t('counts.form.select')}
          error={err('chair_employee_id')}
        />
        <fieldset className="lf-field" data-testid="members">
          <legend className="lf-label">{t('counts.form.members')}</legend>
          {memberChoices.map((p) => (
            <Checkbox key={p.value} label={p.label} checked={form.member_employee_ids.includes(p.value)} onChange={(on) => toggle('member_employee_ids', p.value, on)} />
          ))}
          {field === 'member_employee_ids' && errorText && <span className="lf-error">{errorText}</span>}
        </fieldset>
        <fieldset className="lf-field" data-testid="locations">
          <legend className="lf-label">{t('counts.form.locations')}</legend>
          {locations.map((l) => (
            <Checkbox key={l.value} label={l.label} checked={form.location_ids.includes(l.value)} onChange={(on) => toggle('location_ids', l.value, on)} />
          ))}
          {err('location_ids') && <span className="lf-error">{err('location_ids')}</span>}
        </fieldset>
        <Field label={t('counts.form.note')} optional error={err('note')}>
          <textarea name="note" rows={3} value={form.note} onChange={(e) => set('note')(e.target.value)} />
        </Field>
        <FormActions
          primary={
            <Button variant="primary" size="md" loading={write.isPending} onClick={() => void save()} data-testid="count-save">
              {t('counts.form.save')}
            </Button>
          }
          saving={write.isPending}
        />
      </div>
    </>
  )
}
