/** DocumentsWorkspace — T-1379 (GATE B rework R2). One screen for the three document routes (list, one document, new
 *  document) on the platform document form (`lf-doc`): list | header card | lines table on wide screens, list and header
 *  with lines below on medium ones, the open document replacing the list under 900 px. The record is never in a modal
 *  (rule 2a); the list stays mounted while the user clicks other rows; Escape closes a viewed document. */
import { useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { useQueries } from '@tanstack/react-query'
import { Printer } from 'lucide-react'
import { OfficialFormMenu } from '../forms/OfficialFormMenu'
import { formsForDocument, officialFormLang } from '../forms/officialForms'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { useUiLocale, getUiLocale } from '@/i18n/uiLocaleStore'
import { actorLabel } from '@/lib/references/actorLabel'
import { REFERENCE_MESSAGES } from '@/lib/references/referenceMessages'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { PageHeader } from '@/components/ui/PageHeader'
import { PermissionDenied } from '@/components/ui/PermissionDenied'
import { Skeleton } from '@/components/ui/Skeleton'
import { StatusPill } from '@/components/ui/StatusPill'
import { DocBar, DocBlank, DocCard, DocField, DocFields, DocGroup, DocLayout } from '@/components/ui/doc/DocLayout'
import { useDocumentLayout } from '@/hooks/useDocumentLayout'
import { DocumentTabs } from './DocumentTabs'
import { LinesEditor } from './LinesEditor'
import { RegisterError } from '../register/RegisterShell'
import { usePdfDownload } from '../register/usePdfDownload'
import { stockQueryKeys } from '../register/stockQueryKeys'
import { useNames } from '../register/stockNames'
import { STOCK_POST } from '../stockPermissions'
import { parseFilename } from '../counts/countsModel'
import { movementsLinkFor, type NameIds } from '../register/stockRegisterModel'
import { documentsApi, type StockDocument } from './documents.api'
import { DocumentActions } from './DocumentActions'
import { DocumentForm } from './DocumentForm'
import { DOCUMENTS_PATH, DocumentList } from './DocumentList'
import { DOCUMENTS_LAYOUT_SCREEN } from './lineColumns'
import { useLayoutPrefs } from '@/hooks/useLayoutPrefs'
import { useLayoutMessages } from '@/components/ui/layout/layoutMessages'
import {
  DOC_KINDS,
  DOC_STATES,
  documentHasZ5,
  documentPrintable,
  formatEventTime,
  isOpening,
  isTwoSide,
  printErrorMessageId,
  lineFromDocument,
  sidesOf,
  type DocKind,
} from './documentsModel'
import { stateTone } from './stateTone'

const NO_ERRORS: Record<string, string> = {}
const noop = (): void => undefined

export type WorkspaceMode = 'list' | 'view' | 'create'

function nameIds(doc: StockDocument): NameIds {
  const out: NameIds = {}
  const add = (type: keyof NameIds, id: string | null | undefined) => {
    if (id) (out[type] ??= []).push(id)
  }
  add('org_unit', doc.org_unit_id)
  add('location_node', doc.location_id)
  add('org_employee', doc.responsible_id)
  add('catalog_counterparty', doc.counterparty_id)
  if (isTwoSide(doc.kind)) {
    const { from, to } = sidesOf(doc)
    for (const side of [from, to]) {
      add('org_unit', side.orgUnitId)
      add('location_node', side.locationId)
      add('org_employee', side.responsibleId)
    }
  }
  for (const l of doc.lines) {
    add('catalog_item', l.catalog_item_id)
    add('catalog_uom', l.catalog_uom_id)
    add('catalog_lot', l.catalog_lot_id)
    add('location_node', l.location_id)
    add('org_employee', l.responsible_id)
  }
  return out
}

function DocumentView({ id, onBack }: { id: string; onBack: () => void }) {
  const intl = useIntl()
  const t = (m: string) => intl.formatMessage({ id: m })
  const { session } = useAuth()
  const access = useAccess()
  const tenantId = session?.tenant_id ?? ''
  const uiLocale = useUiLocale()
  const [editing, setEditing] = useState(false)
  const pdf = usePdfDownload(parseFilename)
  // useQueries (like the pickers): the pane draws its own loading and error states.
  const [query] = useQueries({ queries: [{
    queryKey: stockQueryKeys.document(tenantId, id),
    queryFn: () => documentsApi.get(id),
    retry: false,
  }] })
  const doc = query.data
  const name = useNames(doc ? [nameIds(doc)] : [])
  const dash = t('stock.common.dash')
  const when = (iso: string | null | undefined) => formatEventTime(iso, intl.locale, dash)
  const known = (list: readonly string[], prefix: string, v: string) => (list.includes(v) ? t(`${prefix}.${v}`) : v)

  // Escape closes the viewed document (not while editing or while a dialog is open).
  const navigate = useNavigate()
  useEffect(() => {
    if (editing) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape' || e.defaultPrevented) return
      if (document.querySelector('[role="dialog"], dialog[open]')) return
      navigate(DOCUMENTS_PATH)
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [editing, navigate])

  if (query.isPending) {
    return (
      <>
        <DocBar title={<Skeleton width="12em" />} onBack={onBack} backLabel={t('stock.doc.back')} />
        <div data-testid="document-loading" aria-busy="true" aria-label={t('stock.common.loading')} className="lf-card lf-doc__header">
          <Skeleton width="60%" />
        </div>
      </>
    )
  }
  if (query.isError || !doc) {
    return (
      <>
        <DocBar title={t('stock.doc.title')} onBack={onBack} backLabel={t('stock.doc.back')} />
        <div className="lf-card lf-doc__header">
          <RegisterError error={query.error} onRetry={() => void query.refetch()} />
        </div>
      </>
    )
  }
  const kindName = known(DOC_KINDS, 'stock.doc.kind', doc.kind)
  const lines = [...doc.lines].sort((a, b) => a.line_no - b.line_no)
  const tone = stateTone(doc.state)
  const isReceipt = doc.kind === 'receipt'
  const two = isTwoSide(doc.kind)
  const opening = isOpening(doc.kind)
  const sides = sidesOf(doc)

  if (editing) {
    return (
      <DocumentForm
        doc={doc}
        title={`${t('stock.doc.editTitle')}: ${kindName}${doc.number ? ` ${doc.number}` : ''}`}
        onBack={onBack}
        onDone={() => setEditing(false)}
        onCancel={() => setEditing(false)}
      />
    )
  }

  const refMsg = REFERENCE_MESSAGES[uiLocale]
  const actor = (ref: string | null | undefined, label?: string | null) =>
    ref && ref === access.userId ? refMsg.you : label || actorLabel(ref, access.userId, refMsg)
  const row = (label: string, value: string | null | undefined, mono = false, always = true) =>
    always || value ? <DocField label={label} value={value ? value : dash} mono={mono} empty={!value} /> : null
  const hasPosting = Boolean(doc.issued_at || doc.posted_at || doc.posted_by || doc.reversed_at || doc.reversed_by)
  const viewLines = lines.map(lineFromDocument)

  return (
    <>
      <DocBar
        title={
          <>
            <span>{kindName}</span>{' '}
            {doc.number ? <span className="lf-doc__num">{doc.number}</span> : <span>({t('stock.doc.draftMark').toLowerCase()})</span>}
          </>
        }
        status={
          <StatusPill tone={tone.tone} glyph={tone.glyph}>
            {known(DOC_STATES, 'stock.doc.state', doc.state)}
          </StatusPill>
        }
        onBack={onBack}
        backLabel={t('stock.doc.back')}
        actions={
          <>
            <DocumentActions doc={doc} onEdit={() => setEditing(true)} />
            {(doc.state === 'posted' || doc.state === 'reversed') && (
              <Link to={movementsLinkFor(doc.id)}>{t('stock.doc.movementsLink')}</Link>
            )}
            {documentPrintable(doc) && (
              <Button
                variant="secondary"
                icon={<Printer className="lf-icon" aria-hidden="true" />}
                loading={pdf.busyKey === 'print'}
                onClick={() => void pdf.run('print', () => documentsApi.print(doc.id, getUiLocale()), `${doc.number ?? doc.id}.pdf`, printErrorMessageId)}
                data-testid="document-print"
              >
                {t('stock.doc.print')}
              </Button>
            )}
            <OfficialFormMenu
              forms={formsForDocument(doc)}
              busyKey={pdf.busyKey}
              onPick={(form, format, lang) =>
                void pdf.run(`form-${form}-${format}`, () => documentsApi.printForm(doc.id, 'z2', format, lang), `${doc.number ?? doc.id}-Z-2.${format}`, printErrorMessageId)
              }
            />
            {documentHasZ5(doc) &&
              (['pdf', 'docx'] as const).map((format) => (
                <Button
                  key={format}
                  variant="secondary"
                  icon={<Printer className="lf-icon" aria-hidden="true" />}
                  loading={pdf.busyKey === `z5-${format}`}
                  onClick={() =>
                    void pdf.run(
                      `z5-${format}`,
                      () => documentsApi.printForm(doc.id, 'z5', format, officialFormLang(getUiLocale())),
                      `${doc.number ?? doc.id}_Z-5.${format}`,
                      printErrorMessageId,
                    )
                  }
                  data-testid={`document-print-z5-${format}`}
                >
                  {t(format === 'pdf' ? 'stock.doc.printZ5Pdf' : 'stock.doc.printZ5Docx')}
                </Button>
              ))}
          </>
        }
      >
        {pdf.error !== null && <Banner tone="danger">{t(pdf.error)}</Banner>}
        {doc.posting_check === 'mismatch' && (
          <Banner tone="warning" title={t('stock.doc.mismatch.title')}>
            {t('stock.doc.mismatch.body')}
          </Banner>
        )}
        {doc.state === 'issued' && (
          <Banner tone="info" action={<Link to="/tasks">{t('stock.doc.waiting.link')}</Link>}>
            {t(opening ? 'stock.doc.waiting.opening' : 'stock.doc.waiting.text')}
          </Banner>
        )}
      </DocBar>
      <DocumentTabs lineCount={lines.length} />
      <DocCard area="header" title={t('stock.doc.header')}>
        <DocFields data-testid="document-header">
          {row(t('stock.doc.col.number'), doc.number, true)}
          {!opening && row(t('stock.col.time'), when(doc.event_time), true)}
          {!two && row(t('stock.col.orgUnit'), name('org_unit', doc.org_unit_id))}
          {!two && !opening && row(t('stock.col.location'), name('location_node', doc.location_id))}
          {!two && !opening && row(t('stock.col.responsible'), name('org_employee', doc.responsible_id))}
          {isReceipt && row(t('stock.doc.field.counterparty'), name('catalog_counterparty', doc.counterparty_id), false, false)}
          {isReceipt && row(t('stock.doc.field.supplierRef'), doc.supplier_document_ref, true, false)}
          {isReceipt && row(t('stock.doc.field.receivedOn'), doc.received_on, true, false)}
          {doc.reason_code && row(t('stock.doc.field.reasonCode'), known(['lost', 'damaged', 'used_up', 'other'], 'stock.doc.writeOffReason', doc.reason_code))}
          {doc.reason_text && row(t('stock.doc.field.reasonText'), doc.reason_text)}
          {row(t('stock.doc.field.note'), doc.note, false, false)}
          {opening && doc.external_ref_id && row(t('stock.doc.field.externalRefSystem'), doc.external_ref_system, true)}
          {opening && doc.external_ref_id && row(t('stock.doc.field.externalRefId'), doc.external_ref_id, true)}
          {hasPosting && <DocGroup>{t('stock.doc.group.posting')}</DocGroup>}
          {row(t('stock.doc.field.issuedAt'), doc.issued_at ? when(doc.issued_at) : null, true, false)}
          {row(t('stock.doc.field.postedAt'), doc.posted_at ? when(doc.posted_at) : null, true, false)}
          {row(t('stock.doc.field.postedBy'), actor(doc.posted_by, doc.posted_by_label), false, false)}
          {row(t('stock.doc.field.reversedAt'), doc.reversed_at ? when(doc.reversed_at) : null, true, false)}
          {row(t('stock.doc.field.reversedBy'), actor(doc.reversed_by, doc.reversed_by_label), false, false)}
        </DocFields>
        {two && (['from', 'to'] as const).map((side) => (
          <section key={side} data-testid={`view-side-${side}`} aria-label={t(`stock.doc.side.${side}`)}>
            <DocFields>
              <DocGroup>{t(`stock.doc.side.${side}`)}</DocGroup>
              {row(t('stock.col.orgUnit'), name('org_unit', sides[side].orgUnitId))}
              {row(t('stock.col.location'), name('location_node', sides[side].locationId))}
              {row(t('stock.col.responsible'), name('org_employee', sides[side].responsibleId))}
            </DocFields>
          </section>
        ))}
      </DocCard>
      <LinesEditor
        kind={doc.kind as DocKind}
        lines={viewLines}
        errors={NO_ERRORS}
        onChange={noop}
        readOnly
        footer={
          <div className="lf-btn-row">
            <Button variant="ghost" onClick={() => void query.refetch()}>{t('stock.doc.reload')}</Button>
          </div>
        }
      />
    </>
  )
}

function DocumentCreate({ onBack }: { onBack: () => void }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const navigate = useNavigate()
  const [search, setSearch] = useSearchParams()
  const raw = search.get('kind') ?? ''
  const kind: DocKind = (DOC_KINDS as readonly string[]).includes(raw) ? (raw as DocKind) : 'receipt'
  // key: a kind change starts a fresh form (its fields differ).
  return (
    <DocumentForm
      key={kind}
      kind={kind}
      title={t('stock.doc.newTitle')}
      onBack={onBack}
      onKindChange={(k) => setSearch({ kind: k }, { replace: true })}
      onDone={(saved) => navigate(`${DOCUMENTS_PATH}/${encodeURIComponent(saved.id)}`)}
      onCancel={() => navigate(DOCUMENTS_PATH)}
    />
  )
}

export function DocumentsWorkspace({ mode }: { mode: WorkspaceMode }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { id } = useParams()
  const navigate = useNavigate()
  const { can } = useAccess()
  const back = () => navigate(DOCUMENTS_PATH)
  const layout = useDocumentLayout()
  const docState = mode === 'create' ? 'new' : mode === 'view' ? 'existing' : 'none'
  const store = useLayoutPrefs()
  const lm = useLayoutMessages()
  return (
    <>
      <PageHeader
        eyebrow={t('stock.eyebrow')}
        title={t('stock.doc.title')}
        lede={t('stock.doc.lede')}
        actions={
          <Button variant="ghost" onClick={() => store.resetScreen(DOCUMENTS_LAYOUT_SCREEN)} data-testid="reset-layout">
            {lm.resetLayout}
          </Button>
        }
      />
      <DocLayout screen={DOCUMENTS_LAYOUT_SCREEN} detailOpen={mode !== 'list'} layout={layout} docState={docState} docKey={`${mode}:${id ?? ''}`} data-testid="document-workspace">
        <DocumentList selectedId={mode === 'view' ? id : undefined} />
        {mode === 'list' && <DocBlank title={t('stock.doc.blank.title')} text={t('stock.doc.blank.text')} />}
        {mode === 'view' && id && <DocumentView key={id} id={id} onBack={back} />}
        {mode === 'create' && (can(STOCK_POST) ? <DocumentCreate onBack={back} /> : <section className="lf-card lf-doc__blank"><PermissionDenied /></section>)}
      </DocLayout>
    </>
  )
}
