/** DocumentForm — GH 3769 / REQ-722. The draft form of a receipt, an issue and a write off: create (POST) and edit
 *  (PUT, the whole header and the whole line list). Checks before sending mirror the server so the user is told
 *  early; the server stays the authority and its refusals are shown next to the named field or line, else in a banner.
 *  Assumptions (owner may change at GATE B): event time is entered in the tenant time zone (Asia/Almaty until the
 *  tenant setting exists); pickers list active records, first 200; the unit is the item's base unit. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { useNavigate } from 'react-router-dom'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { PermissionDenied } from '@/components/ui/PermissionDenied'
import { Select } from '@/components/ui/Select'
import { usePickerOptions } from '../register/stockPickers'
import { stockQueryKeys } from '../register/stockQueryKeys'
import { STOCK_POST } from '../stockPermissions'
import { documentsApi, type StockDocument } from './documents.api'
import { LinesEditor } from './LinesEditor'
import {
  WRITE_OFF_REASONS,
  buildBody,
  emptyForm,
  formFromDocument,
  placeError,
  validateForm,
  type DocKind,
  type FormState,
} from './documentsModel'

export interface DocumentFormProps {
  kind?: DocKind
  /** Edit mode: the loaded draft. */
  doc?: StockDocument
  /** Called with the saved document. */
  onDone: (saved: StockDocument) => void
  onCancel: () => void
}

export function DocumentForm({ kind = 'receipt', doc, onDone, onCancel }: DocumentFormProps) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const qc = useQueryClient()
  const [form, setForm] = useState<FormState>(() => (doc ? formFromDocument(doc) : emptyForm(kind)))
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [banner, setBanner] = useState<string | null>(null)
  const orgUnits = usePickerOptions('org_unit')
  const locations = usePickerOptions('location_node')
  const employees = usePickerOptions('org_employee')
  const counterparties = usePickerOptions('catalog_counterparty', [], form.kind === 'receipt')
  const patch = (p: Partial<FormState>) => setForm((f) => ({ ...f, ...p }))
  const edit = doc !== undefined

  const save = useMutation({
    mutationFn: (body: Record<string, unknown>) => (doc ? documentsApi.replace(doc.id, body) : documentsApi.create(body)),
    onSuccess: async (saved) => {
      await qc.invalidateQueries({ queryKey: stockQueryKeys.documentsAll(tenantId) })
      if (doc) await qc.invalidateQueries({ queryKey: stockQueryKeys.document(tenantId, doc.id) })
      onDone(saved)
    },
    onError: (e) => {
      const placed = placeError(e)
      if (placed.key) setErrors({ [placed.key]: placed.messageId })
      else setBanner(t(placed.messageId))
    },
  })

  if (!can(STOCK_POST)) return <PermissionDenied />

  const submit = () => {
    setBanner(null)
    const check = validateForm(form)
    setErrors(check.errors)
    if (Object.keys(check.errors).length > 0) return
    save.mutate(buildBody(form))
  }
  const err = (key: string) => (errors[`header.${key}`] ? t(errors[`header.${key}`]) : undefined)
  const receipt = form.kind === 'receipt'

  return (
    <form
      data-testid="document-form"
      onSubmit={(e) => {
        e.preventDefault()
        submit()
      }}
    >
      <p>{t(`stock.doc.kind.${form.kind}`)}</p>
      {banner && <Banner tone="danger">{banner}</Banner>}
      <Field label={t('stock.col.time')} error={err('eventTime')} mono>
        <input type="datetime-local" value={form.eventTime} onChange={(e) => patch({ eventTime: e.target.value })} />
      </Field>
      <Select
        label={t('stock.col.orgUnit')}
        value={form.orgUnitId}
        onChange={(orgUnitId) => patch({ orgUnitId })}
        options={orgUnits}
        placeholder={t('stock.doc.pick')}
        error={err('orgUnitId')}
        disabled={edit}
        hint={edit ? t('stock.doc.orgUnitFixed') : undefined}
      />
      <Select
        label={t('stock.col.location')}
        value={form.locationId}
        onChange={(locationId) => patch({ locationId })}
        options={locations}
        placeholder={t('stock.doc.pick')}
        error={err('locationId')}
      />
      <Select
        label={t('stock.col.responsible')}
        value={form.responsibleId}
        onChange={(responsibleId) => patch({ responsibleId })}
        options={employees}
        placeholder={t('stock.doc.pick')}
        error={err('responsibleId')}
      />
      {receipt && (
        <>
          <Select
            label={t('stock.doc.field.counterparty')}
            value={form.counterpartyId}
            onChange={(counterpartyId) => patch({ counterpartyId })}
            options={counterparties}
            placeholder={t('stock.doc.pickNone')}
            error={err('counterpartyId')}
            optional
          />
          <Field label={t('stock.doc.field.supplierRef')} error={err('supplierRef')} optional>
            <input type="text" value={form.supplierRef} onChange={(e) => patch({ supplierRef: e.target.value })} />
          </Field>
          <Field label={t('stock.doc.field.receivedOn')} error={err('receivedOn')} optional mono>
            <input type="date" value={form.receivedOn} onChange={(e) => patch({ receivedOn: e.target.value })} />
          </Field>
        </>
      )}
      {form.kind === 'write_off' && (
        <Select
          label={t('stock.doc.field.reasonCode')}
          value={form.reasonCode}
          onChange={(reasonCode) => patch({ reasonCode })}
          options={WRITE_OFF_REASONS.map((r) => ({ value: r, label: t(`stock.doc.writeOffReason.${r}`) }))}
          placeholder={t('stock.doc.pick')}
          error={err('reasonCode')}
        />
      )}
      {!receipt && (
        <Field label={t('stock.doc.field.reasonText')} error={err('reasonText')} optional={form.reasonCode !== 'other'}>
          <textarea rows={2} value={form.reasonText} onChange={(e) => patch({ reasonText: e.target.value })} />
        </Field>
      )}
      <Field label={t('stock.doc.field.note')} error={err('note')} optional>
        <textarea rows={2} value={form.note} onChange={(e) => patch({ note: e.target.value })} />
      </Field>
      <LinesEditor kind={form.kind} lines={form.lines} errors={errors} onChange={(lines) => patch({ lines })} />
      <div className="lf-btn-row">
        <Button variant="primary" type="submit" loading={save.isPending}>
          {t('stock.doc.save')}
        </Button>
        <Button variant="ghost" onClick={onCancel}>
          {t('stock.doc.dialog.back')}
        </Button>
      </div>
    </form>
  )
}

/** Navigates to the saved document (used by the new-document page). */
export function useOpenDocument() {
  const navigate = useNavigate()
  return (saved: StockDocument) => navigate(`/admin/stock/documents/${encodeURIComponent(saved.id)}`)
}
