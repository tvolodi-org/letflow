/** AssetCardsPage — T-1333 / C13. The asset card list on the left, the chosen card on the right (ListDetail; owner
 *  rule 2026-11-03: viewing and editing one record happens in the detail panel, not in a modal). Filters: kind and
 *  org unit go to the server, the text search runs on the server (number and name), the list is paged, "Show retired" lifts the active filter.
 *  Create and edit use the panel; retire is a short single-answer action, so it is a ConfirmDialog. A retired card
 *  is read-only. There is no "responsible" filter: the card holds no responsible person (the register does, C14). */
import { useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { useAccess } from '@/auth/access/useAccess'
import { Plus, X } from 'lucide-react'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Checkbox } from '@/components/ui/Checkbox'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { EmptyState } from '@/components/ui/EmptyState'
import { Field } from '@/components/ui/Field'
import { FilterBar } from '@/components/ui/FilterBar'
import { DetailTabs, ListDetail, useListSelection } from '@/components/ui/listDetail'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import { useToast } from '@/hooks/useToast'
import type { EntityRecord } from '@/types/api'
import { assetsApi } from './assets.api'
import { AssetCardFacts } from './AssetCardFacts'
import { AssetCardDepreciation } from './AssetCardDepreciation'
import { AssetCardHolder } from './AssetCardHolder'
import { AssetCardActionsMenu } from './AssetCardActionsMenu'
import { AssetCardSelectionBar } from './AssetCardSelectionBar'
import { usePdfDownload } from '@/hooks/usePdfDownload'
import { parseFilename } from '@/lib/parseFilename'
import { ASSETS_POST, ASSETS_READ } from './assetsPermissions'
import { AssetFormMenu } from './documents/AssetFormMenu'
import { ASSET_FORM_SUFFIX, CARD_FORMS, cardPrintErrorMessageId } from './documents/assetForms'
import { newDocumentHref } from './cardActions'
import { AssetCardForm, unitName, type Cmd } from './AssetCardForm'
import { AssetsIntlProvider } from './AssetsIntlProvider'
import { AssetsShell, useAssetRows, useCardById, useCardsFacts, useErrorText, useOrgUnitRows } from './AssetsShell'
import { AssetsHelpLink } from '@/modules/assets/help/AssetsHelpLink'
import { ASSET_KINDS, isActive, textOf } from './assetsModel'
import { MAX_LINES } from './documents/documentForm'
import { useAssetsWrite, type AssetsWriteResult } from './useAssetsWrite'

function run(cmd: Cmd, key: string) {
  if (cmd.op === 'create') return assetsApi.createCard(cmd.body, key)
  if (cmd.op === 'update') return assetsApi.updateCard(cmd.id, cmd.body, key)
  return assetsApi.retireCard(cmd.id, key)
}

function AssetCardsInner({ initialSelectedId: given, initialCreating, initialCardTab }: { initialSelectedId?: string; initialCreating?: boolean; initialCardTab?: string }) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const navigate = useNavigate()
  const { can } = useAccess()
  const [searchParams] = useSearchParams()
  const initialSelectedId = given ?? searchParams.get('card') ?? undefined
  const errorText = useErrorText()
  const [kind, setKind] = useState('')
  const [orgUnitId, setOrgUnitId] = useState('')
  const [search, setSearch] = useState('')
  const [showRetired, setShowRetired] = useState(false)
  const assetRows = useAssetRows({ kind, orgUnitId, showRetired }, search)
  const unitsQuery = useOrgUnitRows()
  const write = useAssetsWrite<Cmd>(run)
  // T-1924: the official card form download; an error shows only on the card it was asked for.
  const pdf = usePdfDownload(parseFilename)
  const [printCardId, setPrintCardId] = useState<string | null>(null)
  const sel = useListSelection<true>(initialSelectedId ?? null, initialCreating ? true : null)
  const { selectedId } = sel
  const creating = sel.creating !== null
  // T-1954: the card tab survives row clicks, Save and Retire; it resets to Main when the panel closes
  const [cardTab, setCardTab] = useState(initialCardTab ?? 'main')
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)
  const [chosen, setChosen] = useState<EntityRecord[]>([])
  const chosenFacts = useCardsFacts(chosen, chosen.length > 0 && can(ASSETS_POST))
  const chosenWithFacts = chosen.map((c, i) => ({
    id: c.record_id,
    number: textOf(c, 'inventory_number'),
    facts: chosenFacts[i] ?? { active: true, kind: '', held: undefined, rows: undefined, canRead: true },
  }))

  const units = useMemo(() => unitsQuery.data ?? [], [unitsQuery.data])
  const cards = assetRows.rows
  // the list is paged and searched on the server: a chosen card may leave the loaded rows, so keep the clicked one
  // as a fallback (the loaded row wins, it is fresher after a save)
  const [picked, setPicked] = useState<EntityRecord | null>(null)
  // the deep link of "Back to card" (`?card=`): a card outside the first page is read by id
  const byId = useCardById(selectedId, !cards.some((c) => c.record_id === selectedId) && picked?.record_id !== selectedId)
  const selected =
    cards.find((c) => c.record_id === selectedId) ??
    (picked?.record_id === selectedId ? picked : null) ??
    (byId.data?.record_id === selectedId ? byId.data : null)
  const panelOpen = creating || selected !== null
  const dialogOpen = retiring !== null
  const unitLabel = (id: string) => {
    const unit = units.find((u) => u.record_id === id)
    return unit ? unitName(unit) : ''
  }
  const filtersActive = kind !== '' || orgUnitId !== '' || search.trim() !== ''

  function closePanel() {
    write.clearError()
    setCardTab('main')
    sel.close()
  }
  function select(card: EntityRecord) {
    write.clearError()
    sel.select(card.record_id)
    setPicked(card)
  }
  function startCreate() {
    write.clearError()
    sel.startCreate()
  }
  function clearFilters() {
    setKind('')
    setOrgUnitId('')
    setSearch('')
  }

  function formDone(result: AssetsWriteResult) {
    if (result === 'ok') {
      toast.success(t(creating ? 'assets.toast.created' : 'assets.toast.updated'))
      // T-1946: create selects the new card, edit keeps the same card selected
      sel.saved(creating ? { kind: 'create', id: write.lastId() } : { kind: 'edit' })
    } else if (result === 'notFound') {
      // the card is gone: close the panel but keep the error banner that says so
      sel.close()
    }
  }

  async function confirmRetire() {
    if (!retiring) return
    const result = await write.submit({ op: 'retire', id: retiring.record_id }, retiring.record_id)
    if (result !== 'error') {
      if (result === 'ok') {
        toast.success(t('assets.toast.retired'))
        sel.saved({ kind: 'delete' })
      }
      setRetiring(null)
    }
  }

  const columns: DataTableColumn<EntityRecord>[] = [
    ...(can(ASSETS_POST)
      ? [{
          key: 'select',
          label: t('assets.cardActions.select.column'),
          hideStackLabel: true,
          render: (c: EntityRecord) => {
            const isChosen = chosen.some((x) => x.record_id === c.record_id)
            const atCap = !isChosen && chosen.length >= MAX_LINES
            const stop = (e: React.SyntheticEvent) => e.stopPropagation()
            return (
              <span
                data-testid={`card-select-${c.record_id}`}
                onClick={stop}
                onMouseDown={stop}
                onKeyDown={stop}
              >
                <Checkbox
                  label={<span className="sr-only">{t('assets.cardActions.select.row', { number: textOf(c, 'inventory_number') })}</span>}
                  checked={isChosen}
                  disabled={atCap}
                  onChange={(checked) =>
                    setChosen((prev) =>
                      checked ? [...prev, c] : prev.filter((x) => x.record_id !== c.record_id),
                    )
                  }
                />
              </span>
            )
          },
        } satisfies DataTableColumn<EntityRecord>]
      : []),
    { key: 'number', label: t('assets.col.number'), render: (c) => textOf(c, 'inventory_number'), mono: true, sortable: true, sortValue: (c) => textOf(c, 'inventory_number') },
    {
      key: 'name',
      label: t('assets.col.name'),
      sortable: true,
      sortValue: (c) => textOf(c, 'name'),
      // kind and org unit sit under the name: five columns do not fit the list column
      render: (c) => (
        <>
          <div>{textOf(c, 'name')}</div>
          <div className="caption lf-faint">
            <span>{textOf(c, 'kind') === '' ? t('assets.common.dash') : t(`assets.kind.${textOf(c, 'kind')}`)}</span>
            {' · '}
            <span>{unitLabel(textOf(c, 'org_unit_id')) || t('assets.common.dash')}</span>
          </div>
          <StatusPill tone={isActive(c) ? 'success' : 'neutral'} glyph={isActive(c) ? 'dot' : 'dash'}>
            {t(isActive(c) ? 'assets.common.active' : 'assets.common.retired')}
          </StatusPill>
        </>
      ),
    },
    {
      key: 'actions',
      label: t('assets.cardActions.menu'),
      hideStackLabel: true,
      align: 'end',
      render: (c) => <AssetCardActionsMenu card={c} size="sm" />,
    },
  ]

  const closeButton = (
    <Button variant="ghost" size="sm" iconOnly label={t('assets.common.close')} icon={<X className="lf-icon" aria-hidden="true" />} onClick={closePanel} />
  )

  let detail
  if (creating) {
    detail = (
      <section className="lf-card">
        <DetailHeader title={t('assets.page.createTitle')} actions={closeButton} />
        <div className="lf-card__body">
          <AssetCardForm key="new" record={null} write={write} onDone={formDone} onCancel={closePanel} />
        </div>
      </section>
    )
  } else if (selected !== null) {
    const active = isActive(selected)
    detail = (
      <section className="lf-card">
        <DetailHeader
          title={textOf(selected, 'name') || textOf(selected, 'inventory_number')}
          path={textOf(selected, 'inventory_number') || undefined}
          status={
            <StatusPill tone={active ? 'success' : 'neutral'} glyph={active ? 'dot' : 'dash'}>
              {t(active ? 'assets.common.active' : 'assets.common.retired')}
            </StatusPill>
          }
          actions={
            <>
              <AssetCardActionsMenu card={selected} />
              {can(ASSETS_READ) && (
                <AssetFormMenu
                  forms={[...CARD_FORMS]}
                  busyKey={pdf.busyKey}
                  onPick={(form, format, lang) => {
                    setPrintCardId(selected.record_id)
                    void pdf.run(
                      `form-${form}-${format}`,
                      () => assetsApi.printCardForm(selected.record_id, form, format, lang),
                      `${textOf(selected, 'inventory_number') || selected.record_id}${ASSET_FORM_SUFFIX[form]}.${format}`,
                      cardPrintErrorMessageId,
                    )
                  }}
                />
              )}
              {active && (
                <Button variant="danger" size="sm" onClick={() => { write.clearError(); setRetiring(selected) }}>
                  {t('assets.common.retire')}
                </Button>
              )}
              {closeButton}
            </>
          }
        />
        <div className="lf-card__body lf-form">
          {pdf.error !== null && printCardId === selected.record_id && (
            <div data-testid="card-print-error">
              <Banner tone="danger">{t(pdf.error)}</Banner>
            </div>
          )}
          {active ? (
            <AssetCardForm
              key={selected.record_id}
              record={selected}
              write={write}
              onDone={formDone}
              onCancel={closePanel}
              tabs={{
                selected: cardTab,
                onChange: setCardTab,
                label: t('assets.tabs.label'),
                mainExtra: <AssetCardHolder cardId={selected.record_id} />,
                accountingExtra: <AssetCardDepreciation record={selected} />,
              }}
            />
          ) : (
            <DetailTabs
              aria-label={t('assets.tabs.label')}
              selected={cardTab}
              onChange={setCardTab}
              tabs={[
                { id: 'main', label: t('assets.tabs.main'), panel: <><AssetCardFacts record={selected} part="main" /><AssetCardHolder cardId={selected.record_id} /></> },
                { id: 'accounting', label: t('assets.tabs.accounting'), panel: <><AssetCardFacts record={selected} part="accounting" /><AssetCardDepreciation record={selected} /></> },
              ]}
            />
          )}
        </div>
      </section>
    )
  } else {
    detail = null
  }
  const pickHint = <EmptyState title={t('assets.page.pickTitle')} text={t('assets.page.pickHint')} data-testid="asset-pick-hint" />

  const createButton = (
    <Button variant="primary" size="md" icon={<Plus className="lf-icon" aria-hidden="true" />} onClick={startCreate} data-testid="asset-create">
      {t('assets.common.create')}
    </Button>
  )

  const tools = (
    <FilterBar
      onClear={clearFilters}
      activeCount={[kind, orgUnitId, search.trim()].filter((v) => v !== '').length}
      labels={{ clear: t('assets.common.clear'), remove: t('assets.common.remove') }}
    >
      <Select
        label={t('assets.filter.kind')}
        name="filter_kind"
        value={kind}
        options={ASSET_KINDS.map((k) => ({ value: k, label: t(`assets.kind.${k}`) }))}
        placeholder={t('assets.filter.allKinds')}
        onChange={setKind}
      />
      <Select
        label={t('assets.filter.orgUnit')}
        name="filter_org_unit"
        value={orgUnitId}
        options={units.map((u) => ({ value: u.record_id, label: unitName(u) }))}
        placeholder={t('assets.filter.allUnits')}
        onChange={setOrgUnitId}
      />
      <Field label={t('assets.filter.search')}>
        <input name="filter_search" type="search" value={search} onChange={(e) => setSearch(e.target.value)} />
      </Field>
      <div className="lf-btn-row lf-btn-row--between">
        <Checkbox label={t('assets.common.showRetired')} checked={showRetired} onChange={setShowRetired} />
        <span className="caption lf-faint">
          <span className="mono">{cards.length}{assetRows.truncated ? '+' : ''}</span> {t('assets.page.countUnit')}
        </span>
      </div>
    </FilterBar>
  )

  return (
    <AssetsShell
      title={t('assets.page.title')}
      eyebrow={t('assets.page.eyebrow')}
      lede={t('assets.page.lede')}
      queries={[...assetRows.queries, unitsQuery]}
      actions={
        <>
          <AssetsHelpLink topic="cards" />
          {can(ASSETS_POST) && (
            <Button variant="secondary" size="md" onClick={() => navigate(newDocumentHref('kind_change', []))} data-testid="asset-kind-change">
              {t('assets.cardActions.kindChange')}
            </Button>
          )}
          {createButton}
        </>
      }
    >
      {write.error && !dialogOpen ? (
        <Banner tone="danger">
          <span id="assets-error">{errorText(write.error)}</span>
        </Banner>
      ) : null}
      {cards.length === 0 && !panelOpen && !filtersActive && !showRetired ? (
        <EmptyState
          title={t('assets.page.emptyTitle')}
          text={t('assets.page.emptyText')}
          action={
            <Button variant="primary" size="md" onClick={startCreate}>
              {t('assets.common.create')}
            </Button>
          }
        />
      ) : (
        <ListDetail
          screen="assets.cards"
          defaultSelectId={cards[0]?.record_id ?? null}
          onDefaultSelect={sel.select}
          listLabel={t('assets.page.listPane')}
          listDefault={50}
          listMin={380}
          tools={tools}
          list={
            <>
              {can(ASSETS_POST) && chosen.length > 0 && (
                <AssetCardSelectionBar chosen={chosenWithFacts} onClear={() => setChosen([])} />
              )}
              {assetRows.truncated ? (
                <Banner tone="info">
                  <span data-testid="asset-truncated">
                    {t(assetRows.searching ? 'assets.page.truncatedSearch' : 'assets.page.truncatedList', { count: String(cards.length) })}
                  </span>
                </Banner>
              ) : null}
              <DataTable
                columns={columns}
                data={cards}
                getRowId={(c) => c.record_id}
                selectedId={selectedId}
                onRowClick={select}
                rowState={(c) => (isActive(c) ? undefined : 'retired')}
                emptyMessage={t('assets.page.noMatchTitle')}
                emptyText={t('assets.page.noMatchText')}
                emptyAction={
                  <Button variant="secondary" size="sm" onClick={clearFilters}>
                    {t('assets.common.clear')}
                  </Button>
                }
              />
            </>
          }
          listFooter={
            assetRows.hasMore ? (
              <div className="lf-btn-row">
                <Button variant="secondary" size="md" loading={assetRows.loadingMore} onClick={assetRows.loadMore} data-testid="asset-load-more">
                  {t('assets.page.loadMore')}
                </Button>
              </div>
            ) : null
          }
          detail={detail}
          empty={pickHint}
          detailOpen={panelOpen}
          onClose={closePanel}
          escapeCloses={!dialogOpen}
        />
      )}
      <ConfirmDialog
        open={retiring !== null}
        title={t('assets.retire.title')}
        body={t('assets.retire.body', { name: retiring ? textOf(retiring, 'name') : '' })}
        confirmText={t('assets.common.retire')}
        cancelText={t('assets.common.cancel')}
        confirmVariant="danger"
        isLoading={write.isPending}
        error={retiring !== null && write.error ? errorText(write.error) : null}
        onConfirm={() => void confirmRetire()}
        onCancel={() => setRetiring(null)}
      />
    </AssetsShell>
  )
}

/** `initialSelectedId` opens the detail panel on a card, `initialCreating` on the empty create form, at first render
 *  (the screen harness uses them); `initialCardTab` opens the card on a tab.
 *  T-1954: the card body is tabbed (Main, Accounting); the actions stay in the header, there is no Operations row. */
export default function AssetCardsPage({ initialSelectedId, initialCreating, initialCardTab }: { initialSelectedId?: string; initialCreating?: boolean; initialCardTab?: string } = {}) {
  return (
    <AssetsIntlProvider>
      <AssetCardsInner initialSelectedId={initialSelectedId} initialCreating={initialCreating} initialCardTab={initialCardTab} />
    </AssetsIntlProvider>
  )
}
