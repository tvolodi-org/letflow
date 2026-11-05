/** DocumentPage — GH 3769 / REQ-722. One stock document: header, lines in line_no order with master names, state,
 *  posting facts, the posting_check warning and the action bar. A draft can be edited in place (DocumentForm).
 *  States: loading, error (not found, forbidden, other), loaded. Assumption (owner may change at GATE B): the post
 *  task is not completed here, the view links to the task inbox. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Link, useParams } from 'react-router-dom'
import { useQueries } from '@tanstack/react-query'
import { Printer } from 'lucide-react'
import { useAuth } from '@/auth/AuthContext'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { PageHeader } from '@/components/ui/PageHeader'
import { Skeleton } from '@/components/ui/Skeleton'
import { StatusPill } from '@/components/ui/StatusPill'
import { getUiLocale } from '@/i18n/uiLocaleStore'
import { StockIntlProvider } from '../StockIntlProvider'
import { RegisterError } from '../register/RegisterShell'
import { usePdfDownload } from '../register/usePdfDownload'
import { stockQueryKeys } from '../register/stockQueryKeys'
import { useNames } from '../register/stockNames'
import { documentsApi, type StockDocument } from './documents.api'
import { DocumentActions } from './DocumentActions'
import { DocumentForm } from './DocumentForm'
import { DOC_KINDS, DOC_STATES, documentPrintable, formatEventTime, isOpening, isTwoSide, printErrorMessageId, sidesOf } from './documentsModel'
import { stateTone } from './stateTone'
import { parseFilename } from '../counts/countsModel'
import { movementsLinkFor, type NameIds } from '../register/stockRegisterModel'

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

function DocumentInner() {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { id = '' } = useParams()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [editing, setEditing] = useState(false)
  const pdf = usePdfDownload(parseFilename)
  // useQueries (like the pickers): the page draws its own loading and error states.
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

  if (query.isPending) return (
      <div data-testid="document-loading" aria-busy="true" aria-label={t('stock.common.loading')}>
        <Skeleton width="60%" />
      </div>
    )
  if (query.isError || !doc) {
    return (
      <>
        <PageHeader eyebrow={t('stock.eyebrow')} title={t('stock.doc.title')} />
        <RegisterError error={query.error} onRetry={() => void query.refetch()} />
      </>
    )
  }
  const lines = [...doc.lines].sort((a, b) => a.line_no - b.line_no)
  const tone = stateTone(doc.state)
  const isReceipt = doc.kind === 'receipt'
  const two = isTwoSide(doc.kind)
  const opening = isOpening(doc.kind)
  const sides = sidesOf(doc)

  if (editing) {
    return (
      <>
        <PageHeader eyebrow={t('stock.eyebrow')} title={t('stock.doc.editTitle')} />
        <DocumentForm doc={doc} onDone={() => setEditing(false)} onCancel={() => setEditing(false)} />
      </>
    )
  }

  const row = (label: string, value: string | null | undefined, mono = false) => (
    <div>
      <dt>{label}</dt>
      <dd className={mono ? 'mono' : undefined}>{value ? value : dash}</dd>
    </div>
  )

  return (
    <>
      <PageHeader
        eyebrow={t('stock.eyebrow')}
        title={doc.number ? `${known(DOC_KINDS, 'stock.doc.kind', doc.kind)} ${doc.number}` : `${known(DOC_KINDS, 'stock.doc.kind', doc.kind)} (${t('stock.doc.draftMark').toLowerCase()})`}
        lede={t('stock.doc.viewLede')}
        actions={
          <>
            {(doc.state === 'posted' || doc.state === 'reversed') && (
              <Link to={movementsLinkFor(doc.id)}>{t('stock.doc.movementsLink')}</Link>
            )}
            <Link to="/admin/stock/documents">{t('stock.doc.backToList')}</Link>
          </>
        }
      />
      <StatusPill tone={tone.tone} glyph={tone.glyph}>
        {known(DOC_STATES, 'stock.doc.state', doc.state)}
      </StatusPill>
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
      <DocumentActions doc={doc} onEdit={() => setEditing(true)} />
      {documentPrintable(doc) && (
        <>
          {pdf.error !== null && <Banner tone="danger">{t(pdf.error)}</Banner>}
          <div className="lf-btn-row">
            <Button
              variant="secondary"
              icon={<Printer className="lf-icon" aria-hidden="true" />}
              loading={pdf.busyKey === 'print'}
              onClick={() => void pdf.run('print', () => documentsApi.print(doc.id, getUiLocale()), `${doc.number ?? doc.id}.pdf`, printErrorMessageId)}
              data-testid="document-print"
            >
              {t('stock.doc.print')}
            </Button>
          </div>
        </>
      )}
      <dl data-testid="document-header">
        {row(t('stock.doc.col.number'), doc.number, true)}
        {!opening && row(t('stock.col.time'), when(doc.event_time), true)}
        {!two && row(t('stock.col.orgUnit'), name('org_unit', doc.org_unit_id))}
        {!two && !opening && row(t('stock.col.location'), name('location_node', doc.location_id))}
        {!two && !opening && row(t('stock.col.responsible'), name('org_employee', doc.responsible_id))}
        {isReceipt && row(t('stock.doc.field.counterparty'), name('catalog_counterparty', doc.counterparty_id))}
        {isReceipt && row(t('stock.doc.field.supplierRef'), doc.supplier_document_ref, true)}
        {isReceipt && row(t('stock.doc.field.receivedOn'), doc.received_on, true)}
        {doc.reason_code && row(t('stock.doc.field.reasonCode'), known(['lost', 'damaged', 'used_up', 'other'], 'stock.doc.writeOffReason', doc.reason_code))}
        {doc.reason_text && row(t('stock.doc.field.reasonText'), doc.reason_text)}
        {row(t('stock.doc.field.note'), doc.note)}
        {opening && doc.external_ref_id && row(t('stock.doc.field.externalRefSystem'), doc.external_ref_system, true)}
        {opening && doc.external_ref_id && row(t('stock.doc.field.externalRefId'), doc.external_ref_id, true)}
        {row(t('stock.doc.field.issuedAt'), doc.issued_at ? when(doc.issued_at) : null, true)}
        {row(t('stock.doc.field.postedAt'), doc.posted_at ? when(doc.posted_at) : null, true)}
        {row(t('stock.doc.field.postedBy'), doc.posted_by, true)}
        {row(t('stock.doc.field.reversedAt'), doc.reversed_at ? when(doc.reversed_at) : null, true)}
        {row(t('stock.doc.field.reversedBy'), doc.reversed_by, true)}
      </dl>
      {two && (['from', 'to'] as const).map((side) => (
        <section key={side} data-testid={`view-side-${side}`} aria-label={t(`stock.doc.side.${side}`)}>
          <h3>{t(`stock.doc.side.${side}`)}</h3>
          <dl>
            {row(t('stock.col.orgUnit'), name('org_unit', sides[side].orgUnitId))}
            {row(t('stock.col.location'), name('location_node', sides[side].locationId))}
            {row(t('stock.col.responsible'), name('org_employee', sides[side].responsibleId))}
          </dl>
        </section>
      ))}
      <table className="lf-table" data-testid="document-lines">
        <thead>
          <tr>
            <th>{t('stock.doc.col.lineNo')}</th>
            <th>{t('stock.col.item')}</th>
            <th>{t('stock.col.lot')}</th>
            <th>{t('stock.col.unit')}</th>
            <th>{t('stock.col.quantity')}</th>
            {opening && <th>{t('stock.col.location')}</th>}
            {opening && <th>{t('stock.col.responsible')}</th>}
            {opening && <th>{t('stock.doc.field.receivedOnReal')}</th>}
            {(isReceipt || opening) && <th>{t('stock.doc.field.unitPrice')}</th>}
            {(isReceipt || opening) && <th>{t('stock.doc.field.lineValue')}</th>}
          </tr>
        </thead>
        <tbody>
          {lines.map((l) => (
            <tr key={l.line_no} data-testid="line-row">
              <td className="mono">{l.line_no}</td>
              <td>{name('catalog_item', l.catalog_item_id)}</td>
              <td>{name('catalog_lot', l.catalog_lot_id) || dash}</td>
              <td>{name('catalog_uom', l.catalog_uom_id)}</td>
              <td className="mono">{l.quantity}</td>
              {opening && <td>{name('location_node', l.location_id) || dash}</td>}
              {opening && <td>{name('org_employee', l.responsible_id) || dash}</td>}
              {opening && <td className="mono">{l.received_on ?? dash}</td>}
              {(isReceipt || opening) && <td className="mono">{l.unit_price ?? dash}</td>}
              {(isReceipt || opening) && <td className="mono">{l.line_value ?? dash}</td>}
            </tr>
          ))}
        </tbody>
      </table>
      <div className="lf-btn-row">
        <Button variant="ghost" onClick={() => void query.refetch()}>{t('stock.doc.reload')}</Button>
      </div>
    </>
  )
}

export default function DocumentPage() {
  return (
    <StockIntlProvider>
      <DocumentInner />
    </StockIntlProvider>
  )
}
