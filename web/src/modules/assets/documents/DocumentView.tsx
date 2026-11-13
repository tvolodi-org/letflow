/** DocumentView — T-1334 / C14. One asset document in the panel beside the list (header card and lines card on the
 *  platform document form): number, event time, the org unit, location and people of the kind's sides, the reason of a
 *  write off, the posting group, the lines (asset and quantity) and the banners (posting mismatch, waiting for the post
 *  task). Read-only; the actions are `DocumentActions`. A draft has an Edit action that swaps the view for the draft form
 *  (T-1469). Escape closes the document (not while a dialog is open, and not while the form is open). */
import { useEffect, useState } from 'react'
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
import { LFLinesEditor } from '@/components/ui/lines/LFLinesEditor'
import type { LeColumn } from '@/components/ui/lines/types'
import { useLinesMode } from '@/hooks/useLinesMode'
import { Button } from '@/components/ui/Button'
import { assetsQueryKeys } from '../assetsQueryKeys'
import { ASSETS_CARD_WRITE } from '../assetsPermissions'
import { cardHref } from '../cardActions'
import { textOf } from '../assetsModel'
import { useCardById } from '../AssetsShell'
import { useNames } from '../assetsNames'
import { RegisterError } from '../register/RegisterShell'
import { movementsLinkFor, type NameIds } from '../register/registerModel'
import { assetDocumentsApi, type AssetDocument, type AssetDocumentLine } from './assetDocuments.api'
import { DocumentActions } from './DocumentActions'
import { DocumentForm } from './DocumentForm'
import { DocumentTabs } from './DocumentTabs'
import { DOCUMENTS_PATH } from './DocumentList'
import { ASSET_DOCUMENTS_LAYOUT_SCREEN, kindChangeColumnSpecs, kindChangeLineColumns, lineColumnSpecs, lineColumns } from './lineColumns'
import { DOC_KINDS, DOC_STATES, WRITEOFF_REASONS, formatEventTime, isTwoSide, sidesOf } from './documentsModel'
import { documentStateTone as stateTone } from '@/lib/documentStateTone'

type AssetLine = AssetDocumentLine
const noop = () => undefined
/** The read-only editor never adds a line; the editor contract still asks for a blank one. */
const blankLine = (): AssetLine => ({ line_no: 0, asset_id: '', quantity: '' })

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
  for (const l of doc.lines) {
    add('assets_card', l.asset_id)
    // Change of kind: the stock side and the asset side of each line, and the card once posted.
    add('catalog_item', l.catalog_item_id)
    add('catalog_uom', l.catalog_uom_id)
    add('catalog_lot', l.catalog_lot_id)
    add('location_node', l.stock_location_id)
    add('location_node', l.asset_location_id)
    add('org_employee', l.stock_responsible_id)
    add('org_employee', l.material_responsible_id)
    add('org_employee', l.actual_user_id)
    add('org_unit', l.asset_org_unit_id)
    add('assets_card', l.asset_card_id)
  }
  return out
}

export function DocumentView({ id, onBack, cardIds }: { id: string; onBack: () => void; cardIds?: string[] }) {
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
  const [editing, setEditing] = useState(false)
  const singleCardId = cardIds?.length === 1 ? (cardIds[0] ?? null) : null
  const cardQuery = useCardById(singleCardId)
  const cardNumber = cardQuery.data ? textOf(cardQuery.data, 'inventory_number') : null
  const [linesMode, setLinesMode] = useLinesMode('lf-asset-lines')
  const name = useNames(doc ? [nameIds(doc)] : [])
  const dash = t('assets.common.dash')
  const when = (iso: string | null | undefined) => formatEventTime(iso, intl.locale, dash)
  const known = (list: readonly string[], prefix: string, v: string) => (list.includes(v) ? t(`${prefix}.${v}`) : v)

  // Escape closes the viewed document (not while a dialog is open).
  const navigate = useNavigate()
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape' || e.defaultPrevented) return
      if (editing || document.querySelector('[role="dialog"], dialog[open]')) return
      navigate(DOCUMENTS_PATH)
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [navigate, editing])

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
  if (editing && doc.state === 'draft') {
    return <DocumentForm doc={doc} title={`${t('assets.doc.editTitle')}: ${kindName}`} onBack={onBack} onCancel={() => setEditing(false)} onDone={() => setEditing(false)} />
  }
  const lines = [...doc.lines].sort((a, b) => a.line_no - b.line_no)
  const tone = stateTone(doc.state)
  const two = isTwoSide(doc.kind)
  const sides = sidesOf(doc)
  const columns = lineColumns(t)
  const kc = doc.kind === 'kind_change'
  const ref = (type: Parameters<typeof name>[0], id: string | null | undefined) => (id ? name(type, id) : dash)
  const kcView: Record<string, (l: AssetLine) => string> = {
    item: (l) => ref('catalog_item', l.catalog_item_id),
    unit: (l) => ref('catalog_uom', l.catalog_uom_id),
    lot: (l) => ref('catalog_lot', l.catalog_lot_id),
    quantity: (l) => formatQuantity(l.quantity, intl.locale),
    stockLocation: (l) => ref('location_node', l.stock_location_id),
    stockResponsible: (l) => ref('org_employee', l.stock_responsible_id),
    targetKind: (l) => (l.target_kind ? t(`assets.doc.kc.target.${l.target_kind}`) : dash),
    inventoryNumber: (l) => l.inventory_number || dash,
    assetName: (l) => l.asset_name || dash,
    // A blank asset org unit was defaulted to the header unit by the server.
    assetOrgUnit: (l) => ref('org_unit', l.asset_org_unit_id ?? doc.org_unit_id),
    assetLocation: (l) => ref('location_node', l.asset_location_id),
    materialResponsible: (l) => ref('org_employee', l.material_responsible_id),
    actualUser: (l) => ref('org_employee', l.actual_user_id),
    assetCard: (l) => ref('assets_card', l.asset_card_id),
  }
  const editorColumns: LeColumn<AssetLine>[] = kc
    ? kindChangeLineColumns(t, true).map((c) => ({ key: c.key, colId: c.colId, label: c.label, num: c.num, grow: c.key === 'item', view: kcView[c.key]! }))
    : [
        { key: 'asset', colId: 'item', label: columns[0].label, grow: true, view: (l) => name('assets_card', l.asset_id) },
        { key: 'quantity', colId: 'qty', label: columns[1].label, num: true, view: (l) => formatQuantity(l.quantity, intl.locale) },
      ]
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
            <DocumentActions doc={doc} onEdit={() => setEditing(true)} />
            {cardIds && cardIds.length > 0 && access.can(ASSETS_CARD_WRITE) && (
              cardIds.length === 1 ? (
                <Link
                  to={cardHref(cardIds[0]!)}
                  data-testid="doc-back-to-card"
                >
                  {cardNumber
                    ? intl.formatMessage({ id: 'assets.cardActions.backToCardNo' }, { number: cardNumber })
                    : t('assets.cardActions.backToCard')}
                </Link>
              ) : (
                <Link
                  to="/admin/assets/cards"
                  data-testid="doc-back-to-card"
                >
                  {t('assets.cardActions.backToCards')}
                </Link>
              )
            )}
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
          {!kc && (!two || doc.kind === 'change') && row(t('assets.reg.col.location'), name('location_node', sides.from.locationId))}
          {!two && !kc && sideRows(sides.from, false)}
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
          <LFLinesEditor<AssetLine>
            screenId="lf-asset-lines"
            readOnly
            lines={lines}
            onChange={noop}
            columns={editorColumns}
            blank={blankLine}
            duplicate={(l) => l}
            isBlank={() => false}
            max={lines.length}
            mode={linesMode}
            onModeChange={setLinesMode}
            searchText={(l) => (kc ? `${kcView['item']!(l)} ${l.inventory_number ?? ''} ${l.asset_name ?? ''} ${l.quantity}` : `${name('assets_card', l.asset_id)} ${l.quantity}`)}
            totals={() => ({ col: kc ? 'item' : 'asset', node: `${t('assets.doc.lines.total')}: ${lines.length}` })}
            resize={{ id: kc ? 'kc-lines' : 'lines', screen: ASSET_DOCUMENTS_LAYOUT_SCREEN, cols: kc ? kindChangeColumnSpecs(true) : lineColumnSpecs() }}
          />
        )}
        <div className="lf-btn-row">
          <Button variant="ghost" onClick={() => void query.refetch()}>{t('assets.doc.reload')}</Button>
        </div>
      </DocCard>
    </>
  )
}
