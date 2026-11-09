/** DocumentForm — T-1469 / C14 part 2. The draft form of the four asset document kinds (commission, change of
 *  responsible or user, hand over, write off): create (POST) and edit (PUT, the whole header and the whole line list).
 *  Checks before sending mirror the server so the user is told early; the server stays the authority and its refusals
 *  are shown next to the named field or line, else in a banner. The lines are the LE1/LE2 editor (AssetLinesEditor).
 *  Assumptions (owner may change at GATE B): event time is entered in the tenant time zone (Asia/Almaty until the tenant
 *  setting exists); pickers list active records, first 200; the org unit of a saved draft cannot change (the server
 *  refuses it on replace). */
import { useEffect, useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { useNavigate } from 'react-router-dom'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { DocBar, DocCard, DocEdit, DocFields, useDocTabs } from '@/components/ui/doc/DocLayout'
import { firstProblemTab, paneOfKey, problemsByPane } from '@/components/ui/doc/docLayouts'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { DateTimeField } from '@/components/ui/DateField'
import { Field } from '@/components/ui/Field'
import { PermissionDenied } from '@/components/ui/PermissionDenied'
import { Select } from '@/components/ui/Select'
import { ASSETS_POST } from '../assetsPermissions'
import { linkedEmployeeId } from '@/lib/references'
import { usePickerOptions } from '../assetsPickers'
import { assetsQueryKeys } from '../assetsQueryKeys'
import { assetDocumentsApi, type AssetDocument } from './assetDocuments.api'
import { AssetLinesEditor } from './AssetLinesEditor'
import { AssetSideGroup } from './AssetSideGroup'
import { KindChangeLinesEditor } from './KindChangeLinesEditor'
import { DocumentTabs } from './DocumentTabs'
import { DOCUMENTS_PATH } from './DocumentList'
import { buildBody, emptyForm, formFromDocument, placeError, validateForm, type FormState, type SideForm } from './documentForm'
import { DOC_KINDS, WRITEOFF_REASONS, isTwoSide, type DocKind } from './documentsModel'

export interface DocumentFormProps {
  kind?: DocKind
  /** Edit mode: the loaded draft. */
  doc?: AssetDocument
  /** Called with the saved document. */
  onDone: (saved: AssetDocument) => void
  onCancel: () => void
  /** Title of the bar. */
  title: string
  /** Narrow screens: back to the list. */
  onBack?: () => void
  /** Create: shows the Kind select at the top of the header card. */
  onKindChange?: (kind: DocKind) => void
}

export function DocumentForm({ kind = 'commission', doc, onDone, onCancel, title, onBack, onKindChange }: DocumentFormProps) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { can, userId } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const qc = useQueryClient()
  const edit = doc !== undefined
  const [form, setForm] = useState<FormState>(() => (doc ? formFromDocument(doc) : emptyForm(kind)))
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [banner, setBanner] = useState<string | null>(null)
  const [attempted, setAttempted] = useState(false)
  const { tabsLayout, setTab } = useDocTabs()
  const orgUnits = usePickerOptions('org_unit')
  const locations = usePickerOptions('location_node')
  const employees = usePickerOptions('org_employee')
  const cards = usePickerOptions('assets_card')
  const patch = (p: Partial<FormState>) => setForm((f) => ({ ...f, ...p }))
  // Hand over: the To org unit and location start as the From ones until To is touched.
  const toTouched = useRef(edit)
  // T-1528: the signed-in user's linked employee is proposed as the From responsible (never the To side), once, until
  // the user touches the field.
  const respTouched = useRef(edit)
  const linked = linkedEmployeeId(userId, employees)
  useEffect(() => {
    if (respTouched.current || linked === null || form.kind === 'kind_change') return
    if (form.from.responsibleId === '') setForm((f) => ({ ...f, from: { ...f.from, responsibleId: linked } }))
  }, [linked, form.kind, form.from.responsibleId])
  const patchSide = (side: 'from' | 'to', p: Partial<SideForm>) =>
    setForm((f) => {
      if (side === 'from' && p.responsibleId !== undefined) respTouched.current = true
      if (side === 'to') toTouched.current = true
      const next = { ...f, [side]: { ...f[side], ...p } }
      if (side === 'from' && f.kind === 'handover' && !toTouched.current) {
        const copy: Partial<SideForm> = {}
        if (p.orgUnitId !== undefined) copy.orgUnitId = p.orgUnitId
        if (p.locationId !== undefined) copy.locationId = p.locationId
        next.to = { ...f.to, ...copy }
      }
      return next
    })

  const save = useMutation({
    mutationFn: (body: Record<string, unknown>) => (doc ? assetDocumentsApi.replace(doc.id, body) : assetDocumentsApi.create(body)),
    onSuccess: async (saved) => {
      await qc.invalidateQueries({ queryKey: assetsQueryKeys.documentsAll(tenantId) })
      if (doc) await qc.invalidateQueries({ queryKey: assetsQueryKeys.document(tenantId, doc.id) })
      onDone(saved)
    },
    onError: (e) => {
      const placed = placeError(e, form.kind)
      if (placed.key) {
        setErrors({ [placed.key]: placed.messageId })
        if (tabsLayout) setTab(paneOfKey(placed.key))
      } else setBanner(t(placed.messageId))
    },
  })

  if (!can(ASSETS_POST)) return <PermissionDenied />

  const cardOf = (id: string) => {
    const k = cards.find((c) => c.value === id)?.fields?.['kind']
    return typeof k === 'string' && k !== '' ? { kind: k } : undefined
  }
  const submit = () => {
    if (save.isPending) return
    setBanner(null)
    setAttempted(true)
    const check = validateForm(form, cardOf)
    setErrors(check.errors)
    if (Object.keys(check.errors).length > 0) {
      // Tab layout: Save moves to the first tab with a problem (the badge on the other tab keeps its count).
      const first = firstProblemTab(problemsByPane(check.errors))
      if (tabsLayout && first) setTab(first)
      return
    }
    save.mutate(buildBody(form, !edit))
  }
  const err = (key: string) => (errors[`header.${key}`] ? t(errors[`header.${key}`]) : undefined)
  const two = isTwoSide(form.kind)
  const kc = form.kind === 'kind_change'
  const sideProps = { orgUnits, locations, employees, errors }
  const E = DocEdit
  return (
    <>
      <DocBar
        editing
        title={<span>{title}</span>}
        onBack={onBack}
        backLabel={t('assets.doc.back')}
        actions={
          <>
            <Button variant="primary" loading={save.isPending} onClick={submit}>
              {t('assets.common.save')}
            </Button>
            <Button variant="ghost" onClick={onCancel}>
              {t('assets.doc.dialog.back')}
            </Button>
          </>
        }
      >
        {banner && <Banner tone="danger">{banner}</Banner>}
      </DocBar>
      <DocumentTabs lineCount={form.kind === 'kind_change' ? form.kcLines.length : form.lines.length} problems={problemsByPane(errors)} />
      <DocCard area="header" title={t('assets.doc.header')} data-testid="document-form">
        <DocFields editing>
          {onKindChange ? (
            <E full>
              <Select
                label={t('assets.doc.col.kind')}
                value={form.kind}
                onChange={(k) => onKindChange(k as DocKind)}
                options={DOC_KINDS.map((k) => ({ value: k, label: t(`assets.doc.kind.${k}`) }))}
              />
            </E>
          ) : (
            <E full>
              <p>{t(`assets.doc.kind.${form.kind}`)}</p>
            </E>
          )}
          <E full>
            <DateTimeField label={t('assets.reg.col.time')} error={err('eventTime')} value={form.eventTime} onChange={(eventTime) => patch({ eventTime })} />
          </E>
          {two && errors['sides'] && <p role="alert">{t(errors['sides'])}</p>}
          {form.kind === 'handover' && (['from', 'to'] as const).map((side) => (
            <AssetSideGroup
              key={side}
              side={side}
              value={form[side]}
              onChange={(p) => patchSide(side, p)}
              fields={['orgUnitId', 'locationId', 'responsibleId', 'userId']}
              orgUnitFixed={edit && side === 'from'}
              {...sideProps}
            />
          ))}
          {form.kind === 'change' && (
            <>
              <AssetSideGroup bare side="from" value={form.from} onChange={(p) => patchSide('from', p)} fields={['orgUnitId', 'locationId']} orgUnitFixed={edit} {...sideProps} />
              {(['from', 'to'] as const).map((side) => (
                <AssetSideGroup key={side} side={side} value={form[side]} onChange={(p) => patchSide(side, p)} fields={['responsibleId', 'userId']} {...sideProps} />
              ))}
            </>
          )}
          {kc && (
            <>
              <AssetSideGroup bare side="from" value={form.from} onChange={(p) => patchSide('from', p)} fields={['orgUnitId']} orgUnitFixed={edit} {...sideProps} />
              <E full>
                <Field label={t('assets.doc.field.reasonText')} error={err('reasonText')} optional>
                  <textarea rows={2} value={form.reasonText} onChange={(e) => patch({ reasonText: e.target.value })} />
                </Field>
              </E>
            </>
          )}
          {!two && !kc && (
            <AssetSideGroup bare side="from" value={form.from} onChange={(p) => patchSide('from', p)} fields={['orgUnitId', 'locationId', 'responsibleId', 'userId']} orgUnitFixed={edit} {...sideProps} />
          )}
          {form.kind === 'writeoff' && (
            <>
              <E full>
                <Select
                  label={t('assets.doc.field.reasonCode')}
                  value={form.reasonCode}
                  onChange={(reasonCode) => patch({ reasonCode })}
                  options={WRITEOFF_REASONS.map((r) => ({ value: r, label: t(`assets.doc.writeoffReason.${r}`) }))}
                  placeholder={t('assets.doc.pick')}
                  error={err('reasonCode')}
                />
              </E>
              <E full>
                <Field label={t('assets.doc.field.reasonText')} error={err('reasonText')} optional={form.reasonCode !== 'other'}>
                  <textarea rows={2} value={form.reasonText} onChange={(e) => patch({ reasonText: e.target.value })} />
                </Field>
              </E>
            </>
          )}
          <E full>
            <Field label={t('assets.doc.field.note')} error={err('note')} optional>
              <textarea rows={2} value={form.note} onChange={(e) => patch({ note: e.target.value })} />
            </Field>
          </E>
        </DocFields>
      </DocCard>
      {kc ? (
        <KindChangeLinesEditor lines={form.kcLines} errors={errors} onChange={(kcLines) => patch({ kcLines })} showErrors={attempted} />
      ) : (
        <AssetLinesEditor lines={form.lines} errors={errors} onChange={(lines) => patch({ lines })} showErrors={attempted} />
      )}
    </>
  )
}

/** Navigates to the saved document (used by the new-document page). */
export function useOpenDocument() {
  const navigate = useNavigate()
  return (saved: AssetDocument) => navigate(`${DOCUMENTS_PATH}/${encodeURIComponent(saved.id)}`)
}
