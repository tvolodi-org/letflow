/** DocumentView — T-1334 / C14. One asset document in the panel beside the list (header card and lines card on the
 *  platform document form): number, event time, the org unit, location and people of the kind's sides, the reason of a
 *  write off, the posting group, the lines (asset and quantity) and the banners (posting mismatch, waiting for the post
 *  task). Read-only; the actions are `DocumentActions`. Escape closes the document (not while a dialog is open). */
import { useEffect } from 'react'
import { useIntl } from 'react-intl'
import { Link, useNavigate } from 'react-router-dom'
import { useQueries } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { actorLabel } from '@/lib/references/actorLabel'
import { REFERENCE_MESSAGES } from '@/lib/references/referenceMessages'
import { formatQuantity } from '@/lib/formatQuantity'
import { Banner } from '@/components/ui/Banner'
import { Skeleton } from '@/components/ui/Skeleton'
import { StatusPill } from '@/components/ui/StatusPill'
import { DocBar, DocCard, DocField, DocFields, DocGroup } from '@/components/ui/doc/DocLayout'
import { DocLineItem, DocLinesTable, DocLinesTotal } from '@/components/ui/doc/DocLines'
import { Button } from '@/components/ui/Button'
import { assetsQueryKeys } from '../assetsQueryKeys'
import { useNames } from '../assetsNames'
import { RegisterError } from '../register/RegisterShell'
import { movementsLinkFor, type NameIds } from '../register/registerModel'
import { assetDocumentsApi, type AssetDocument } from './assetDocuments.api'
import { DocumentActions } from './DocumentActions'
import { DocumentTabs } from './DocumentTabs'
import { DOCUMENTS_PATH } from './DocumentList'
import { ASSET_DOCUMENTS_LAYOUT_SCREEN, lineColumnSpecs, lineColumns } from './lineColumns'
import { DOC_KINDS, DOC_STATES, WRITEOFF_REASONS, formatEventTime, isTwoSide, sidesOf } from './documentsModel'
import { stateTone } from './stateTone'

function nameIds(doc: AssetDocument): NameIds {
  const out: NameIds = {}
  const add = (type: keyof NameIds, id: string | null | undefined) => {
    if (id) (out[type] ??= []).push(id)
  }
  const { from, to } = sidesOf(doc)
  for (const side of [from, to]) {
    add('org_unit', side.orgUnitId)
    add('location_node', side.locationId)
    add('org_employee', side.responsibleId)
    add('org_employee', side.userId)
  }
  for (const l of doc.lines) add('assets_card', l.asset_id)
  return out
}

export function DocumentView({ id, onBack }: { id: string; onBack: () => void }) {
  const intl = useIntl()
  const t = (m: string) => intl.formatMessage({ id: m })
  const { session } = useAuth()
  const access = useAccess()
  const tenantId = session?.tenant_id ?? ''
  const uiLocale = useUiLocale()
  // useQueries (like the pickers): the pane draws its own loading and error states.
  const [query] = useQueries({ queries: [{
    queryKey: assetsQueryKeys.document(tenantId, id),
    queryFn: () => assetDocumentsApi.get(id),
    retry: false,
  }] })
  const doc = query.data
  const name = useNames(doc ? [nameIds(doc)] : [])
  const dash = t('assets.common.dash')
  const when = (iso: string | null | undefined) => formatEventTime(iso, intl.locale, dash)
  const known = (list: readonly string[], prefix: string, v: string) => (list.includes(v) ? t(`${prefix}.${v}`) : v)

  // Escape closes the viewed document (not while a dialog is open).
  const navigate = useNavigate()
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape' || e.defaultPrevented) return
      if (document.querySelector('[role="dialog"], dialog[open]')) return
      navigate(DOCUMENTS_PATH)
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [navigate])

  if (query.isPending) {
    return (
      <>
        <DocBar title={<Skeleton width="12em" />} onBack={onBack} backLabel={t('assets.doc.back')} />
        <div data-testid="document-loading" aria-busy="true" aria-label={t('assets.reg.loading')} className="lf-card lf-doc__header">
          <Skeleton width="60%" />
        </div>
      </>
    )
  }
  if (query.isError || !doc) {
    return (
      <>
        <DocBar title={t('assets.doc.title')} onBack={onBack} backLabel={t('assets.doc.back')} />
        <div className="lf-card lf-doc__header">
          <RegisterError error={query.error} onRetry={() => void query.refetch()} />
        </div>
      </>
    )
  }

  const kindName = known(DOC_KINDS, 'assets.doc.kind', doc.kind)
  const lines = [...doc.lines].sort((a, b) => a.line_no - b.line_no)
  const tone = stateTone(doc.state)
  const two = isTwoSide(doc.kind)
  const sides = sidesOf(doc)
  const columns = lineColumns(t)
  const refMsg = REFERENCE_MESSAGES[uiLocale]
  const actor = (ref: string | null | undefined, label?: string | null) =>
    ref && ref === access.userId ? refMsg.you : label || actorLabel(ref, access.userId, refMsg)
  const row = (label: string, value: string | null | undefined, mono = false, always = true) =>
    always || value ? <DocField label={label} value={value ? value : dash} mono={mono} empty={!value} /> : null
  const hasPosting = Boolean(doc.issued_at || doc.posted_at || doc.posted_by || doc.reversed_at || doc.reversed_by)
  // commission / writeoff: one group of four; change: unit and location in the header, people per side; handover: all four per side
  const sideRows = (s: ReturnType<typeof sidesOf>['from'], place: boolean) => (
    <>
      {place && row(t('assets.reg.col.orgUnit'), name('org_unit', s.orgUnitId))}
      {place && row(t('assets.reg.col.location'), name('location_node', s.locationId))}
      {row(t('assets.reg.col.responsible'), name('org_employee', s.responsibleId))}
      {row(t('assets.reg.col.user'), name('org_employee', s.userId))}
    </>
  )

  return (
    <>
      <DocBar
        title={
          <>
            <span>{kindName}</span>{' '}
            {doc.number ? <span className="lf-doc__num">{doc.number}</span> : <span>({t('assets.doc.draftMark').toLowerCase()})</span>}
          </>
        }
        status={
          <StatusPill tone={tone.tone} glyph={tone.glyph}>
            {known(DOC_STATES, 'assets.doc.state', doc.state)}
          </StatusPill>
        }
        onBack={onBack}
        backLabel={t('assets.doc.back')}
        actions={
          <>
            <DocumentActions doc={doc} />
            {(doc.state === 'posted' || doc.state === 'reversed') && (
              <Link to={movementsLinkFor(doc.id)}>{t('assets.doc.movementsLink')}</Link>
            )}
          </>
        }
      >
        {doc.posting_check === 'mismatch' && (
          <Banner tone="warning" title={t('assets.doc.mismatch.title')}>
            {t('assets.doc.mismatch.body')}
          </Banner>
        )}
        {doc.state === 'issued' && (
          <Banner tone="info" action={<Link to="/tasks">{t('assets.doc.waiting.link')}</Link>}>
            {t('assets.doc.waiting.text')}
          </Banner>
        )}
      </DocBar>
      <DocumentTabs lineCount={lines.length} />
      <DocCard area="header" title={t('assets.doc.header')}>
        <DocFields data-testid="document-header">
          {row(t('assets.doc.col.number'), doc.number, true)}
          {row(t('assets.reg.col.time'), when(doc.event_time), true)}
          {(!two || doc.kind === 'change') && row(t('assets.reg.col.orgUnit'), name('org_unit', sides.from.orgUnitId))}
          {(!two || doc.kind === 'change') && row(t('assets.reg.col.location'), name('location_node', sides.from.locationId))}
          {!two && sideRows(sides.from, false)}
          {doc.reason_code && row(t('assets.doc.field.reasonCode'), known(WRITEOFF_REASONS, 'assets.doc.writeoffReason', doc.reason_code))}
          {doc.reason_text && row(t('assets.doc.field.reasonText'), doc.reason_text)}
          {row(t('assets.doc.field.note'), doc.note, false, false)}
          {hasPosting && <DocGroup>{t('assets.doc.group.posting')}</DocGroup>}
          {row(t('assets.doc.field.issuedAt'), doc.issued_at ? when(doc.issued_at) : null, true, false)}
          {row(t('assets.doc.field.postedAt'), doc.posted_at ? when(doc.posted_at) : null, true, false)}
          {row(t('assets.doc.field.postedBy'), actor(doc.posted_by, doc.posted_by_label), false, false)}
          {row(t('assets.doc.field.reversedAt'), doc.reversed_at ? when(doc.reversed_at) : null, true, false)}
          {row(t('assets.doc.field.reversedBy'), actor(doc.reversed_by, doc.reversed_by_label), false, false)}
        </DocFields>
        {two && (['from', 'to'] as const).map((side) => (
          <section key={side} data-testid={`view-side-${side}`} aria-label={t(`assets.doc.side.${side}`)}>
            <DocFields>
              <DocGroup>{t(`assets.doc.side.${side}`)}</DocGroup>
              {sideRows(sides[side], doc.kind === 'handover')}
            </DocFields>
          </section>
        ))}
      </DocCard>
      <DocCard area="lines" title={t('assets.doc.lines')} count={lines.length}>
        {lines.length === 0 ? (
          <div className="lf-doc__empty">
            <div className="lf-empty">
              <p className="lf-empty__title">{t('assets.doc.lines.none')}</p>
            </div>
          </div>
        ) : (
          <DocLinesTable
            columns={columns}
            lineLabel={t('assets.doc.col.lineNo')}
            data-testid="document-lines"
            resize={{ id: 'lines', screen: ASSET_DOCUMENTS_LAYOUT_SCREEN, cols: lineColumnSpecs() }}
            footer={<DocLinesTotal labelSpan={columns.length + 1} label={`${t('assets.doc.lines.total')}: ${lines.length}`} cells={[]} />}
          >
            {lines.map((l, i) => (
              <DocLineItem key={l.line_no} index={i} lineLabel={t('assets.doc.col.lineNo')} messageId={`ln-${i}-err`} colSpan={columns.length + 1} testId="line-row">
                <td data-label={columns[0].label}>{name('assets_card', l.asset_id)}</td>
                <td className="is-num" data-label={columns[1].label}>{formatQuantity(l.quantity, intl.locale)}</td>
              </DocLineItem>
            ))}
          </DocLinesTable>
        )}
        <div className="lf-btn-row">
          <Button variant="ghost" onClick={() => void query.refetch()}>{t('assets.doc.reload')}</Button>
        </div>
      </DocCard>
    </>
  )
}
