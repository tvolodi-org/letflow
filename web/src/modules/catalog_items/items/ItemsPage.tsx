/** ItemsPage — T-1402. The Items (catalog) screen on the lf-registry layout: a compact list on the left (code, title,
 *  unit, tracking, status; search, tracking filter, Show retired, sort, pager), the record on the right (Overview,
 *  Related, History). Under 900 px the selected record replaces the list (back button). The selected item lives in
 *  the URL (`?item=<record id>`), so Back and a reload keep it.
 *
 *  Read only: no write route exists for catalog_item (the generic entity routes answer 403 entity_type_managed and
 *  a new route needs a module manifest change), so the details head shows a view-only line and no Edit / Retire
 *  button. The in-pane edit and create form is the generic RegistryForm (tested there); wiring it to items waits
 *  for the backend routes. */
import { useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
import { useSearchParams } from 'react-router-dom'
import { PageHeader } from '@/components/ui/PageHeader'
import { StatusPill } from '@/components/ui/StatusPill'
import { Select } from '@/components/ui/Select'
import { Registry, RegistryDetailsSkeleton, RegistryList, type RegistryColumn, type RegistryChip } from '@/components/ui/registry'
import { useReferenceLabels } from '@/lib/references'
import { DELETED_FALSE } from '../catalogItems.api'
import { CatalogItemsIntlProvider } from '../CatalogItemsIntlProvider'
import { CatalogItemsBoundary, useLotRows } from '../CatalogItemsShell'
import { CATALOG_ITEM } from '../catalogItemsModel'
import { ItemBlank, ItemDetails, ItemNotFound } from './ItemDetails'
import {
  TRACKING_POLICIES, filterItems, pageCountOf, pageOf, sortItems, toItemRow,
  type ItemSortKey, type SortDir, type TrackingPolicy,
} from './itemsModel'

const ITEM_PARAM = 'item'
const FILTERS = [DELETED_FALSE]
// five columns share the 520 px list: the title is cut earlier than the design's 26ch (a width limit, no colour or spacing)
const TITLE_CUT = { maxWidth: '11ch' } as const

function ItemsInner({ initialItemId }: { initialItemId?: string }) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `catalog_items.items.${id}` }, values)
  const [params, setParams] = useSearchParams()
  // `initialItemId` opens one item before the user has picked any (the screen harness); the URL wins afterwards
  const [initial, setInitial] = useState(initialItemId ?? null)
  const selectedId = params.get(ITEM_PARAM) ?? initial

  const [q, setQ] = useState('')
  const [tracking, setTracking] = useState<TrackingPolicy | ''>('')
  const [showRetired, setShowRetired] = useState(false)
  const [sortKey, setSortKey] = useState<ItemSortKey>('code')
  const [sortDir, setSortDir] = useState<SortDir>('asc')
  const [page, setPage] = useState(1)

  const query = useLotRows(CATALOG_ITEM, 'items', FILTERS, { sortField: 'code' })
  const all = useMemo(() => (query.data ?? []).map(toItemRow), [query.data])
  const filtered = useMemo(() => filterItems(all, { q, tracking, showRetired }), [all, q, tracking, showRetired])
  const sorted = useMemo(() => sortItems(filtered, sortKey, sortDir), [filtered, sortKey, sortDir])
  const shown = pageOf(sorted, page)

  const label = useReferenceLabels([{ catalog_uom: shown.rows.map((r) => r.uomId).filter(Boolean) }])

  const reset = <A,>(set: (v: A) => void) => (v: A) => {
    set(v)
    setPage(1)
  }

  function open(id: string | null) {
    setInitial(null)
    const next = new URLSearchParams(params)
    if (id) next.set(ITEM_PARAM, id)
    else next.delete(ITEM_PARAM)
    setParams(next)
  }

  function sortBy(key: string) {
    const k = key as ItemSortKey
    if (k === sortKey) setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'))
    else {
      setSortKey(k)
      setSortDir('asc')
    }
    setPage(1)
  }

  function clearFilters() {
    setQ('')
    setTracking('')
    setPage(1)
  }

  const columns: RegistryColumn<(typeof all)[number]>[] = [
    { key: 'code', header: t('col.code'), mono: true, sortable: true, render: (r) => r.code },
    { key: 'name', header: t('col.title'), sortable: true, render: (r) => (
        <span className="lf-reg__title" style={TITLE_CUT} title={r.name}>
          {r.name}
        </span>
      ),
    },
    { key: 'unit', header: t('col.unit'), mono: true, optional: true, render: (r) => label('catalog_uom', r.uomId) },
    { key: 'tracking', header: t('col.tracking'), optional: true, render: (r) => t(`tracking.${r.tracking}`) },
    {
      key: 'status',
      header: t('col.status'),
      sortable: true,
      render: (r) => (
        <StatusPill tone={r.active ? 'success' : 'neutral'} glyph={r.active ? 'dot' : 'ring'}>
          {t(r.active ? 'status.active' : 'status.retired')}
        </StatusPill>
      ),
    },
  ]

  const chips: RegistryChip[] = tracking
    ? [{ id: 'tracking', label: `${t('filterTracking')}: ${t(`tracking.${tracking}`)}`, onRemove: () => reset(setTracking)('') }]
    : []

  const selected = selectedId ? all.find((r) => r.id === selectedId) : undefined
  const detailOpen = selectedId !== null

  const list = (
    <RegistryList
      title={t('listTitle')}
      titleId="catalog-items-list"
      labels={{
        search: t('search'),
        showRetired: t('showRetired'),
        clearFilters: t('clear'),
        removeFilter: t('removeFilter'),
        retry: t('retry'),
        pages: t('pages'),
        prev: t('prev'),
        next: t('next'),
      }}
      state={query.isPending ? 'loading' : query.isError && !query.data ? 'error' : 'ready'}
      errorTitle={t('error.title')}
      errorText={t('error.text')}
      onRetry={() => void query.refetch()}
      columns={columns}
      rows={shown.rows}
      rowId={(r) => r.id}
      isRetired={(r) => !r.active}
      selectedId={selectedId}
      onOpen={(r) => open(r.id)}
      query={q}
      onQuery={reset(setQ)}
      filters={
        <Select
          label={t('filterTracking')}
          hideLabel
          value={tracking}
          onChange={(v) => reset(setTracking)(v as TrackingPolicy | '')}
          placeholder={`${t('filterTracking')}: ${t('all')}`}
          options={TRACKING_POLICIES.map((p) => ({ value: p, label: t(`tracking.${p}`) }))}
        />
      }
      chips={chips}
      onClearFilters={clearFilters}
      filtered={q.trim() !== '' || tracking !== ''}
      showRetired={showRetired}
      onShowRetired={reset(setShowRetired)}
      sortKey={sortKey}
      sortDir={sortDir}
      onSort={sortBy}
      page={shown.page}
      pageCount={pageCountOf(sorted.length)}
      onPage={setPage}
      rangeText={t('range', { from: shown.from, to: shown.to, total: sorted.length })}
      empty={{ title: t('empty.title'), text: t('empty.text') }}
      noMatch={{ title: t('noMatch.title'), text: t('noMatch.text') }}
    />
  )

  let details
  if (!detailOpen) details = <ItemBlank />
  else if (query.isPending) details = <RegistryDetailsSkeleton />
  else if (!selected) details = <ItemNotFound />
  else details = <ItemDetails key={selected.id} item={selected} onBack={() => open(null)} />

  return <Registry layout="split" list={list} details={details} detailOpen={detailOpen} onClose={() => open(null)} />
}

export default function ItemsPage({ initialItemId }: { initialItemId?: string } = {}) {
  const query = useLotRows(CATALOG_ITEM, 'items', FILTERS, { sortField: 'code' })
  return (
    <CatalogItemsIntlProvider>
      <ItemsHeader />
      <CatalogItemsBoundary queries={[query]}>
        <ItemsInner initialItemId={initialItemId} />
      </CatalogItemsBoundary>
    </CatalogItemsIntlProvider>
  )
}

function ItemsHeader() {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id: `catalog_items.items.${id}` })
  return <PageHeader eyebrow={t('eyebrow')} title={t('title')} lede={t('lede')} />
}
