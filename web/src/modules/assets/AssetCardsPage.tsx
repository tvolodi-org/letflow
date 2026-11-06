/** AssetCardsPage — T-1333 / C13. The asset card list on the left, the chosen card on the right (MasterDetail; owner
 *  rule 2026-11-03: viewing and editing one record happens in the detail panel, not in a modal). Filters: kind and
 *  org unit go to the server, the text search narrows the loaded rows, "Show retired" lifts the active filter.
 *  Create and edit use the panel; retire is a short single-answer action, so it is a ConfirmDialog. A retired card
 *  is read-only. There is no "responsible" filter: the card holds no responsible person (the register does, C14). */
import { useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
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
import { MasterDetail } from '@/components/ui/MasterDetail'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import { useToast } from '@/hooks/useToast'
import type { EntityRecord } from '@/types/api'
import { assetsApi } from './assets.api'
import { AssetCardFacts } from './AssetCardFacts'
import { AssetCardForm, unitName, type Cmd } from './AssetCardForm'
import { AssetsIntlProvider } from './AssetsIntlProvider'
import { AssetsShell, useAssetRows, useErrorText, useOrgUnitRows } from './AssetsShell'
import { ASSET_KINDS, isActive, matchesSearch, textOf } from './assetsModel'
import { useAssetsWrite, type AssetsWriteResult } from './useAssetsWrite'

function run(cmd: Cmd, key: string) {
  if (cmd.op === 'create') return assetsApi.createCard(cmd.body, key)
  if (cmd.op === 'update') return assetsApi.updateCard(cmd.id, cmd.body, key)
  return assetsApi.retireCard(cmd.id, key)
}

function AssetCardsInner({ initialSelectedId, initialCreating }: { initialSelectedId?: string; initialCreating?: boolean }) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const errorText = useErrorText()
  const [kind, setKind] = useState('')
  const [orgUnitId, setOrgUnitId] = useState('')
  const [search, setSearch] = useState('')
  const [showRetired, setShowRetired] = useState(false)
  const rows = useAssetRows({ kind, orgUnitId, showRetired })
  const unitsQuery = useOrgUnitRows()
  const write = useAssetsWrite<Cmd>(run)
  const [selectedId, setSelectedId] = useState<string | null>(initialSelectedId ?? null)
  const [creating, setCreating] = useState(initialCreating ?? false)
  const [retiring, setRetiring] = useState<EntityRecord | null>(null)

  const units = useMemo(() => unitsQuery.data ?? [], [unitsQuery.data])
  const loaded = useMemo(() => rows.data ?? [], [rows.data])
  const cards = useMemo(() => loaded.filter((c) => matchesSearch(c, search)), [loaded, search])
  const selected = loaded.find((c) => c.record_id === selectedId) ?? null
  const panelOpen = creating || selected !== null
  const dialogOpen = retiring !== null
  const unitLabel = (id: string) => {
    const unit = units.find((u) => u.record_id === id)
    return unit ? unitName(unit) : ''
  }
  const filtersActive = kind !== '' || orgUnitId !== '' || search.trim() !== ''

  function closePanel() {
    write.clearError()
    setCreating(false)
    setSelectedId(null)
  }
  function select(card: EntityRecord) {
    write.clearError()
    setCreating(false)
    setSelectedId(card.record_id)
  }
  function startCreate() {
    write.clearError()
    setSelectedId(null)
    setCreating(true)
  }
  function clearFilters() {
    setKind('')
    setOrgUnitId('')
    setSearch('')
  }

  function formDone(result: AssetsWriteResult) {
    if (result === 'ok') {
      toast.success(t(creating ? 'assets.toast.created' : 'assets.toast.updated'))
      closePanel()
    } else if (result === 'notFound') {
      // the card is gone: close the panel but keep the error banner that says so
      setCreating(false)
      setSelectedId(null)
    }
  }

  async function confirmRetire() {
    if (!retiring) return
    const result = await write.submit({ op: 'retire', id: retiring.record_id }, retiring.record_id)
    if (result !== 'error') {
      if (result === 'ok') {
        toast.success(t('assets.toast.retired'))
        setSelectedId(null)
      }
      setRetiring(null)
    }
  }

  const columns: DataTableColumn<EntityRecord>[] = [
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
  ]

  const closeButton = (
    <Button variant="ghost" size="sm" iconOnly label={t('assets.common.close')} icon={<X className="lf-icon" aria-hidden="true" />} onClick={closePanel} />
  )

  let detail
  if (creating) {
    detail = (
      <>
        <DetailHeader title={t('assets.page.createTitle')} actions={closeButton} />
        <div className="lf-card__body">
          <AssetCardForm key="new" record={null} units={units} write={write} onDone={formDone} onCancel={closePanel} />
        </div>
      </>
    )
  } else if (selected !== null) {
    const active = isActive(selected)
    detail = (
      <>
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
              {active && (
                <Button variant="danger" size="sm" onClick={() => { write.clearError(); setRetiring(selected) }}>
                  {t('assets.common.retire')}
                </Button>
              )}
              {closeButton}
            </>
          }
        />
        <div className="lf-card__body">
          {active ? (
            <AssetCardForm key={selected.record_id} record={selected} units={units} write={write} onDone={formDone} onCancel={closePanel} />
          ) : (
            <AssetCardFacts record={selected} unitLabel={unitLabel(textOf(selected, 'org_unit_id'))} />
          )}
        </div>
      </>
    )
  } else {
    detail = (
      <div className="lf-card__body">
        <EmptyState title={t('assets.page.pickTitle')} text={t('assets.page.pickHint')} data-testid="asset-pick-hint" />
      </div>
    )
  }

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
          <span className="mono">{cards.length}</span> {t('assets.page.countUnit')}
        </span>
      </div>
    </FilterBar>
  )

  return (
    <AssetsShell
      title={t('assets.page.title')}
      eyebrow={t('assets.page.eyebrow')}
      lede={t('assets.page.lede')}
      queries={[rows, unitsQuery]}
      actions={createButton}
    >
      {write.error && !dialogOpen ? (
        <Banner tone="danger">
          <span id="assets-error">{errorText(write.error)}</span>
        </Banner>
      ) : null}
      {loaded.length === 0 && !panelOpen && !filtersActive && !showRetired ? (
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
        <div
          onKeyDown={(e) => {
            if (e.key === 'Escape' && !e.defaultPrevented && panelOpen && !dialogOpen) closePanel()
          }}
        >
          <MasterDetail
            masterWidth="wide"
            tools={tools}
            detailOpen={panelOpen}
            onBack={closePanel}
            master={
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
            }
            detail={detail}
          />
        </div>
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
 *  (the screen harness uses them). */
export default function AssetCardsPage({ initialSelectedId, initialCreating }: { initialSelectedId?: string; initialCreating?: boolean } = {}) {
  return (
    <AssetsIntlProvider>
      <AssetCardsInner initialSelectedId={initialSelectedId} initialCreating={initialCreating} />
    </AssetsIntlProvider>
  )
}
