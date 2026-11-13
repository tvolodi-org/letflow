/** BalancesPage — T-1334 / C14. Current balances of the assets register: the five slot filters and the org-unit
 *  subtree, names instead of ids, quantity text as the route answers it, Load more, and a history panel beside the
 *  list. Reads the latest basis only (no basis / cutoff_seq key). The scoped read is the server's: the screen shows
 *  `coverage` when the answer holds the reader's own units only, and never a total. */
import { useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { useInfiniteQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { FilterBar } from '@/components/ui/FilterBar'
import { PageHeader } from '@/components/ui/PageHeader'
import { AssetsHelpLink } from '@/modules/assets/help/AssetsHelpLink'
import { Button } from '@/components/ui/Button'
import { Select } from '@/components/ui/Select'
import { Banner } from '@/components/ui/Banner'
import { Registry } from '@/components/ui/registry/Registry'
import { EmptyState } from '@/components/ui/EmptyState'
import { SplitWrap, useSplit } from '@/components/ui/layout/Splitter'
import { useColResize } from '@/components/ui/layout/ColumnResize'
import { isWideHost } from '@/components/ui/layout/isWideHost'
import { useUiMessages } from '@/components/ui/uiMessages'
import { isUuid } from '@/lib/references/referenceLabel'
import { formatQuantity } from '@/lib/formatQuantity'
import { AssetsIntlProvider } from '../AssetsIntlProvider'
import { assetsQueryKeys } from '../assetsQueryKeys'
import { useNames } from '../assetsNames'
import { usePickerOptions, anyPickerTruncated } from '../assetsPickers'
import { TruncatedNotice } from '@/components/ui/TruncatedNotice'
import { MAX_ROWS } from '@/lib/entities/fetchAllRecords'
import { LoadMore, RegisterError } from './RegisterShell'
import { assetRegisterApi, type AssetBalanceRow, type AssetBalancesBody } from './assetRegister.api'
import { BalanceHistoryPanel } from './BalanceHistoryPanel'
import { EMPTY_BALANCE_FILTERS, balanceNameIds, balanceParams, type BalanceFilters } from './registerModel'

const ACTIVE_ONLY: never[] = []
const LAYOUT_SCREEN = 'assets.balances'

/** Default widths (percent, the last column is the flexible one) and smallest widths (px) of the list columns. */
const LIST_COLS = [
  { id: 'asset', w: 28, min: 140 },
  { id: 'org_unit', w: 17, min: 150 },
  { id: 'location', w: 17, min: 130 },
  { id: 'responsible', w: 16, min: 150 },
  { id: 'user', w: 14, min: 150 },
  { id: 'quantity', w: 0, min: 120 },
]

const rowId = (r: AssetBalanceRow) => `${r.asset}|${r.org_unit}|${r.location ?? ''}|${r.material_responsible}|${r.actual_user ?? ''}`

const FILTER_LABEL: Record<keyof BalanceFilters, string> = {
  asset: 'assets.reg.filter.asset',
  org_unit: 'assets.reg.filter.orgUnit',
  location: 'assets.reg.filter.location',
  material_responsible: 'assets.reg.filter.responsible',
  actual_user: 'assets.reg.filter.user',
  scope_subtree: 'assets.reg.filter.subtree',
}

function BalancesInner({ initialSelectedId = null, initialFilters }: { initialSelectedId?: string | null; initialFilters?: Partial<BalanceFilters> }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [filters, setFilters] = useState<BalanceFilters>({ ...EMPTY_BALANCE_FILTERS, ...initialFilters })
  const [selected, setSelected] = useState<string | null>(initialSelectedId)
  const set = (key: keyof BalanceFilters) => (value: string) => {
    setSelected(null)
    setFilters((f) => ({ ...f, [key]: value }))
  }

  const assets = usePickerOptions('assets_card', ACTIVE_ONLY)
  const locations = usePickerOptions('location_node', ACTIVE_ONLY)
  const units = usePickerOptions('org_unit', ACTIVE_ONLY)
  const people = usePickerOptions('org_employee', ACTIVE_ONLY)

  const params = balanceParams(filters)
  const query = useInfiniteQuery({
    queryKey: assetsQueryKeys.balances(tenantId, JSON.stringify(params)),
    queryFn: ({ pageParam }) => assetRegisterApi.balances({ ...params, ...(pageParam ? { cursor: pageParam } : {}) }),
    initialPageParam: '' as string,
    getNextPageParam: (last: AssetBalancesBody, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })

  const pages = query.data?.pages ?? []
  const rows = pages.flatMap((p) => p.rows)
  const name = useNames(pages.map((p) => balanceNameIds(p.rows)))
  const ledgerSeq = pages[0]?.ledger_seq
  const visibleOnly = pages[0]?.coverage === 'visible_only' && params['scope_subtree'] !== undefined

  const dash = t('assets.common.dash')
  const columns: DataTableColumn<AssetBalanceRow>[] = [
    { key: 'asset', label: t('assets.reg.col.asset'), render: (r) => name('assets_card', r.asset) },
    { key: 'org_unit', label: t('assets.reg.col.orgUnit'), render: (r) => name('org_unit', r.org_unit) },
    { key: 'location', label: t('assets.reg.col.location'), render: (r) => name('location_node', r.location) || dash },
    { key: 'responsible', label: t('assets.reg.col.responsible'), render: (r) => name('org_employee', r.material_responsible) },
    { key: 'user', label: t('assets.reg.col.user'), render: (r) => name('org_employee', r.actual_user) || dash },
    { key: 'quantity', label: t('assets.reg.col.quantity'), render: (r) => formatQuantity(r.quantity, intl.locale), align: 'end', mono: true },
  ]
  const chips: { id: string; label: string }[] = (Object.keys(params) as (keyof BalanceFilters)[]).map((k) => ({
    id: k,
    label: `${t(FILTER_LABEL[k])}: ${
      [...assets, ...locations, ...units, ...people].find((o) => o.value === params[k])?.label ?? (isUuid(params[k]) ? dash : params[k])
    }`,
  }))
  const selectedRow = selected === null ? null : (rows.find((r) => rowId(r) === selected) ?? null)

  const gridRef = useRef<HTMLDivElement>(null)
  const layerRef = useRef<HTMLDivElement>(null)
  const tableRef = useRef<HTMLTableElement>(null)
  const ui = useUiMessages()
  useSplit(gridRef, layerRef, {
    id: 'list',
    screen: LAYOUT_SCREEN,
    unit: 'pct',
    sized: 'before',
    vars: ['--lf-pane-1'],
    min: [320],
    flexMin: 360,
    collapsible: [0],
    labels: [t('assets.balances.listPane')],
    defaults: [60],
    panes: () => [
      gridRef.current?.querySelector<HTMLElement>(':scope > .lf-reg__list') ?? null,
      gridRef.current?.querySelector<HTMLElement>(':scope > .lf-reg__details') ?? null,
    ],
    enabled: () => isWideHost(gridRef.current),
  })
  useColResize(tableRef, {
    id: 'list',
    screen: LAYOUT_SCREEN,
    cols: LIST_COLS,
    minTable: true,
    enabled: () => isWideHost(gridRef.current),
  })

  const list = (
    <section className="lf-card lf-reg__list" aria-label={t('assets.balances.listPane')}>
      <div className="lf-reg__body">
        <DataTable
          columns={columns}
          data={rows}
          isLoading={query.isPending}
          getRowId={rowId}
          onRowClick={(r) => setSelected(rowId(r))}
          selectedId={selected}
          emptyMessage={t('assets.balances.empty')}
          emptyText={t('assets.balances.emptyText')}
          labels={{ loading: t('assets.reg.loading'), retry: t('assets.reg.retry') }}
          tableRef={tableRef}
        />
      </div>
      <div className="lf-reg__foot">
        <LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />
      </div>
    </section>
  )
  const details = selectedRow ? (
    <>
      <div className="lf-reg__backrow">
        <Button variant="ghost" size="sm" className="lf-reg__back" onClick={() => setSelected(null)} data-testid="master-detail-back">
          {ui.back}
        </Button>
      </div>
      <BalanceHistoryPanel row={selectedRow} onClose={() => setSelected(null)} name={name} />
    </>
  ) : (
    <EmptyState title={t('assets.balances.pickRow')} text={t('assets.balances.pickRowText')} data-testid="balances-pick-row" />
  )

  return (
    <>
      {anyPickerTruncated(assets, locations, units, people) && <TruncatedNotice messageId="assets.pickers.truncated" count={MAX_ROWS} />}
      <PageHeader eyebrow={t('assets.reg.eyebrow')} title={t('assets.balances.title')} lede={t('assets.balances.lede')} actions={<AssetsHelpLink topic="balances" />} />
      <FilterBar
        activeChips={chips}
        onRemoveChip={(id) => set(id as keyof BalanceFilters)('')}
        onClear={() => {
          setSelected(null)
          setFilters(EMPTY_BALANCE_FILTERS)
        }}
        labels={{ clear: t('assets.common.clear'), remove: t('assets.common.remove') }}
      >
        <Select label={t('assets.reg.filter.asset')} value={filters.asset} onChange={set('asset')} options={assets} placeholder={t('assets.reg.all')} />
        <Select label={t('assets.reg.filter.orgUnit')} value={filters.org_unit} onChange={set('org_unit')} options={units} placeholder={t('assets.reg.all')} />
        <Select label={t('assets.reg.filter.location')} value={filters.location} onChange={set('location')} options={locations} placeholder={t('assets.reg.all')} />
        <Select label={t('assets.reg.filter.responsible')} value={filters.material_responsible} onChange={set('material_responsible')} options={people} placeholder={t('assets.reg.all')} />
        <Select label={t('assets.reg.filter.user')} value={filters.actual_user} onChange={set('actual_user')} options={people} placeholder={t('assets.reg.all')} />
        <Select label={t('assets.reg.filter.subtree')} value={filters.scope_subtree} onChange={set('scope_subtree')} options={units} placeholder={t('assets.reg.all')} />
      </FilterBar>
      {ledgerSeq != null && (
        <p className="caption" data-testid="ledger-seq">
          {intl.formatMessage({ id: 'assets.balances.readAt' }, { seq: ledgerSeq })}
        </p>
      )}
      {visibleOnly && (
        <Banner tone="info">
          {t('assets.balances.coverageVisibleOnly')}
        </Banner>
      )}
      {query.isError && <RegisterError error={query.error} onRetry={() => void query.refetch()} />}
      {/* stays mounted on a load error (hidden) so the splitter keeps its container */}
      <div hidden={query.isError}>
        <SplitWrap layerRef={layerRef}>
          <Registry layout="split" list={list} details={details} detailOpen={selectedRow != null} onClose={() => setSelected(null)} gridRef={gridRef} />
        </SplitWrap>
      </div>
    </>
  )
}

/** `initialSelectedId`: opens the history panel of one row at first render; `initialFilters`: starts with filters set
 *  (the screen harness uses both). */
export default function BalancesPage({ initialSelectedId, initialFilters }: { initialSelectedId?: string; initialFilters?: Partial<BalanceFilters> } = {}) {
  return (
    <AssetsIntlProvider>
      <BalancesInner initialSelectedId={initialSelectedId ?? null} initialFilters={initialFilters} />
    </AssetsIntlProvider>
  )
}
