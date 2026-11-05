/** DocumentForm — GH 3769 / REQ-722. The draft form of a receipt, an issue and a write off: create (POST) and edit
 *  (PUT, the whole header and the whole line list). Checks before sending mirror the server so the user is told
 *  early; the server stays the authority and its refusals are shown next to the named field or line, else in a banner.
 *  Assumptions (owner may change at GATE B): event time is entered in the tenant time zone (Asia/Almaty until the
 *  tenant setting exists); pickers list active records, first 200; the unit is the item's base unit. */
import { useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { useNavigate } from 'react-router-dom'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { DocBar, DocCard, DocEdit, DocFields } from '@/components/ui/doc/DocLayout'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { DateField, DateTimeField } from '@/components/ui/DateField'
import { PermissionDenied } from '@/components/ui/PermissionDenied'
import { Select } from '@/components/ui/Select'
import { usePickerOptions } from '../register/stockPickers'
import { stockQueryKeys } from '../register/stockQueryKeys'
import { STOCK_POST } from '../stockPermissions'
import { documentsApi, type StockDocument } from './documents.api'
import { LinesEditor } from './LinesEditor'
import { SideGroup } from './SideGroup'
import {
  DOC_KINDS,
  WRITE_OFF_REASONS,
  buildBody,
  emptyForm,
  formFromDocument,
  isOpening,
  isTwoSide,
  placeError,
  validateForm,
  type DocKind,
  type FormState,
  type SideForm,
} from './documentsModel'

export interface DocumentFormProps {
  kind?: DocKind
  /** Edit mode: the loaded draft. */
  doc?: StockDocument
  /** Called with the saved document. */
  onDone: (saved: StockDocument) => void
  onCancel: () => void
  /** Title of the bar. */
  title: string
  /** Narrow screens: back to the list. */
  onBack?: () => void
  /** Create: shows the Kind select at the top of the header card. */
  onKindChange?: (kind: DocKind) => void
}

export function DocumentForm({ kind = 'receipt', doc, onDone, onCancel, ...props }: DocumentFormProps) {
  const onKindChange = props.onKindChange
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
  // Hand over (REQ-723, owner may change at GATE B): the To org unit and location start as the From ones until To is touched.
  const toTouched = useRef(doc !== undefined)
  const patchSide = (side: 'from' | 'to', p: Partial<SideForm>) =>
    setForm((f) => {
      if (side === 'to') toTouched.current = true
      const next = { ...f, [side]: { ...f[side], ...p } }
      if (side === 'from' && f.kind === 'hand_over' && !toTouched.current) {
        const copy: Partial<SideForm> = {}
        if (p.orgUnitId !== undefined) copy.orgUnitId = p.orgUnitId
        if (p.locationId !== undefined) copy.locationId = p.locationId
        next.to = { ...f.to, ...copy }
      }
      return next
    })
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
  const two = isTwoSide(form.kind)
  const opening = isOpening(form.kind)
  const orgFixedSide = form.kind === 'return' ? 'to' : 'from'

  const E = DocEdit
  return (
    <>
      <DocBar
        editing
        title={<span>{props.title}</span>}
        onBack={props.onBack}
        backLabel={t('stock.doc.back')}
        actions={
          <>
            <Button variant="primary" loading={save.isPending} onClick={submit}>
              {t('stock.doc.save')}
            </Button>
            <Button variant="ghost" onClick={onCancel}>
              {t('stock.doc.dialog.back')}
            </Button>
          </>
        }
      >
        {banner && <Banner tone="danger">{banner}</Banner>}
      </DocBar>
      <DocCard area="header" title={t('stock.doc.header')} data-testid="document-form">
        <DocFields editing>
          {onKindChange && (
            <E full>
              <Select
                label={t('stock.doc.col.kind')}
                value={form.kind}
                onChange={(k) => onKindChange(k as DocKind)}
                options={DOC_KINDS.map((k) => ({ value: k, label: t(`stock.doc.kind.${k}`) }))}
              />
            </E>
          )}
          {!onKindChange && (
            <E full>
              <p>{t(`stock.doc.kind.${form.kind}`)}</p>
            </E>
          )}
          {!opening && (
            <E full>
              <DateTimeField label={t('stock.col.time')} error={err('eventTime')} value={form.eventTime} onChange={(eventTime) => patch({ eventTime })} />
            </E>
          )}
          {two && errors['sides'] && <p role="alert">{t(errors['sides'])}</p>}
          {two && (['from', 'to'] as const).map((side) => (
            <SideGroup
              key={side}
              side={side}
              value={form[side]}
              onChange={(p) => patchSide(side, p)}
              errors={errors}
              orgUnits={orgUnits}
              locations={locations}
              employees={employees}
              orgUnitFixed={edit && side === orgFixedSide}
            />
          ))}
          {!two && (<>
          <E full>
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
          </E>
          {!opening && (<>
          <E full>
            <Select
              label={t('stock.col.location')}
              value={form.locationId}
              onChange={(locationId) => patch({ locationId })}
              options={locations}
              placeholder={t('stock.doc.pick')}
              error={err('locationId')}
            />
          </E>
          <E full>
            <Select
              label={t('stock.col.responsible')}
              value={form.responsibleId}
              onChange={(responsibleId) => patch({ responsibleId })}
              options={employees}
              placeholder={t('stock.doc.pick')}
              error={err('responsibleId')}
            />
          </E>
          </>)}
          </>)}
          {receipt && (
            <>
              <E full>
                <Select
                  label={t('stock.doc.field.counterparty')}
                  value={form.counterpartyId}
                  onChange={(counterpartyId) => patch({ counterpartyId })}
                  options={counterparties}
                  placeholder={t('stock.doc.pickNone')}
                  error={err('counterpartyId')}
                  optional
                />
              </E>
              <E full>
                <Field label={t('stock.doc.field.supplierRef')} error={err('supplierRef')} optional>
                  <input type="text" value={form.supplierRef} onChange={(e) => patch({ supplierRef: e.target.value })} />
                </Field>
              </E>
              <E full>
                <DateField label={t('stock.doc.field.receivedOn')} error={err('receivedOn')} optional value={form.receivedOn} onChange={(receivedOn) => patch({ receivedOn })} />
              </E>
            </>
          )}
          {form.kind === 'write_off' && (
            <E full>
              <Select
                label={t('stock.doc.field.reasonCode')}
                value={form.reasonCode}
                onChange={(reasonCode) => patch({ reasonCode })}
                options={WRITE_OFF_REASONS.map((r) => ({ value: r, label: t(`stock.doc.writeOffReason.${r}`) }))}
                placeholder={t('stock.doc.pick')}
                error={err('reasonCode')}
              />
            </E>
          )}
          {!receipt && !two && !opening && (
            <E full>
              <Field label={t('stock.doc.field.reasonText')} error={err('reasonText')} optional={form.reasonCode !== 'other'}>
                <textarea rows={2} value={form.reasonText} onChange={(e) => patch({ reasonText: e.target.value })} />
              </Field>
            </E>
          )}
          <E full>
            <Field label={t('stock.doc.field.note')} error={err('note')} optional>
              <textarea rows={2} value={form.note} onChange={(e) => patch({ note: e.target.value })} />
            </Field>
          </E>
          {opening && (
            <>
              <E full>
                <Field label={t('stock.doc.field.externalRefSystem')} error={err('externalRefSystem')} optional mono>
                  <input type="text" value={form.externalRefSystem} onChange={(e) => patch({ externalRefSystem: e.target.value })} />
                </Field>
              </E>
              <E full>
                <Field label={t('stock.doc.field.externalRefId')} hint={t('stock.doc.field.externalRefHint')} error={err('externalRefId')} optional mono>
                  <input type="text" value={form.externalRefId} onChange={(e) => patch({ externalRefId: e.target.value })} />
                </Field>
              </E>
            </>
          )}
        </DocFields>
      </DocCard>
      <LinesEditor kind={form.kind} lines={form.lines} errors={errors} onChange={(lines) => patch({ lines })} />
    </>
  )
}

/** Navigates to the saved document (used by the new-document page). */
export function useOpenDocument() {
  const navigate = useNavigate()
  return (saved: StockDocument) => navigate(`/admin/stock/documents/${encodeURIComponent(saved.id)}`)
}
