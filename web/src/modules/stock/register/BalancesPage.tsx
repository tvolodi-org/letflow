/** BalancesPage — GH 3767 / REQ-724. Current balances of the stock register: five filters, names instead of ids,
 *  quantity text as the route answers it, Load more. Reads the latest basis only (no basis / cutoff_seq key). */
import { useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { useInfiniteQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { FilterBar } from '@/components/ui/FilterBar'
import { PageHeader } from '@/components/ui/PageHeader'
import { StockHelpLink } from '@/modules/stock/help/StockHelpLink'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import { Banner } from '@/components/ui/Banner'
import { StockIntlProvider } from '../StockIntlProvider'
import { LoadMore, RegisterError } from './RegisterShell'
import { saveBlob } from '@/lib/saveBlob'
import { usePdfDownload } from './usePdfDownload'
import { parseFilename } from '../counts/countsModel'
import { getUiLocale } from '@/i18n/uiLocaleStore'
import { printErrorMessageId } from '../documents/documentsModel'
import { OfficialFormMenu } from '../forms/OfficialFormMenu'
import { officialFormLang } from '../forms/officialForms'
import { stockApi, type BalanceRow, type BalancesPageBody } from './stock.api'
import { usePickerOptions, anyPickerTruncated } from './stockPickers'
import { TruncatedNotice } from '@/components/ui/TruncatedNotice'
import { MAX_ROWS } from '@/lib/entities/fetchAllRecords'
import { stockQueryKeys } from './stockQueryKeys'
import { EMPTY_BALANCE_FILTERS, AS_OF_DATE, balanceNameIds, balanceParams, balanceQuery, todayIso, type BalanceFilters } from './stockRegisterModel'
import { isUuid } from '@/lib/references/referenceLabel'
import { useNames } from './stockNames'
import { DateValueHint } from '@/components/ui/DateValueHint'
import { formatLocalInput } from '@/i18n/format'
import { formatQuantity } from '@/lib/formatQuantity'
import { ListDetail } from '@/components/ui/listDetail'
import { EmptyState } from '@/components/ui/EmptyState'
import { useColResize } from '@/components/ui/layout/ColumnResize'
import { isWideHost } from '@/components/ui/layout/isWideHost'
import { BalanceHistoryPanel } from './BalanceHistoryPanel'

const ACTIVE_ONLY: never[] = []

/** Default widths (percent, the last column is the flexible one) and smallest widths (px) of the list columns. */
const LIST_COLS = [
  { id: 'sku', w: 22, min: 120 },
  { id: 'location', w: 17, min: 100 },
  { id: 'org_unit', w: 13, min: 90 },
  { id: 'responsible', w: 13, min: 90 },
  { id: 'lot', w: 10, min: 80 },
  { id: 'unit', w: 10, min: 110 },
  { id: 'quantity', w: 0, min: 100 },
]

const rowId = (r: BalanceRow) => `${r.sku}|${r.location}|${r.org_unit}|${r.responsible ?? ''}|${r.lot ?? ''}|${r.unit_ref}`

function BalancesInner({ initialSelectedId = null }: { initialSelectedId?: string | null }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [filters, setFilters] = useState<BalanceFilters>(EMPTY_BALANCE_FILTERS)
  const [asOf, setAsOf] = useState('')
  const [selected, setSelected] = useState<string | null>(initialSelectedId)
  const [exporting, setExporting] = useState(false)
  const [exportFailed, setExportFailed] = useState(false)
  const card = usePdfDownload(parseFilename)
  const set = (key: keyof BalanceFilters) => (value: string) => {
    setSelected(null)
    setFilters((f) => ({ ...f, [key]: value, ...(key === 'sku' ? { lot: '' } : {}) }))
  }

  const items = usePickerOptions('catalog_item', ACTIVE_ONLY)
  const locations = usePickerOptions('location_node', ACTIVE_ONLY)
  const units = usePickerOptions('org_unit', ACTIVE_ONLY)
  const people = usePickerOptions('org_employee', ACTIVE_ONLY)
  const lots = usePickerOptions('catalog_lot', [{ field: 'item_id', op: 'eq', value: filters.sku }], filters.sku !== '')

  const filterParams = balanceParams(filters)
  const params = balanceQuery(filters, asOf)
  const query = useInfiniteQuery({
    queryKey: stockQueryKeys.balances(tenantId, JSON.stringify(params)),
    queryFn: ({ pageParam }) => stockApi.balances({ ...params, ...(pageParam ? { cursor: pageParam } : {}) }),
    initialPageParam: '' as string,
    getNextPageParam: (last: BalancesPageBody, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })

  const pages = query.data?.pages ?? []
  const rows = pages.flatMap((p) => p.rows)
  const name = useNames(pages.map((p) => balanceNameIds(p.rows)))
  const ledgerSeq = pages[0]?.ledger_seq

  const dash = t('stock.common.dash')
  const columns: DataTableColumn<BalanceRow>[] = [
    { key: 'sku', label: t('stock.col.item'), render: (r) => name('catalog_item', r.sku) },
    { key: 'location', label: t('stock.col.location'), render: (r) => name('location_node', r.location) },
    { key: 'org_unit', label: t('stock.col.orgUnit'), render: (r) => name('org_unit', r.org_unit) },
    { key: 'responsible', label: t('stock.col.responsible'), render: (r) => name('org_employee', r.responsible) || dash },
    { key: 'lot', label: t('stock.col.lot'), render: (r) => name('catalog_lot', r.lot) || dash },
    { key: 'unit', label: t('stock.col.unit'), render: (r) => name('catalog_uom', r.unit_ref) },
    { key: 'quantity', label: t('stock.col.quantity'), render: (r) => formatQuantity(r.quantity), align: 'end', mono: true },
  ]
  const chips: { id: string; label: string }[] = (Object.keys(filterParams) as (keyof BalanceFilters)[]).map((k) => ({
    id: k,
    label: `${t(`stock.filter.${k}`)}: ${
      [...items, ...locations, ...units, ...people, ...lots].find((o) => o.value === filterParams[k])?.label ?? (isUuid(filterParams[k]) ? dash : filterParams[k])
    }`,
  }))
  if (params.as_of_date) chips.push({ id: 'as_of_date', label: `${t('stock.filter.asOf')}: ${formatLocalInput(params.as_of_date, 'date', intl.locale)}` })

  const onExport = async () => {
    setExporting(true)
    setExportFailed(false)
    try {
      const { blob } = await stockApi.balancesXlsx(params)
      saveBlob(blob, 'stock-balances.xlsx')
    } catch {
      setExportFailed(true)
    } finally {
      setExporting(false)
    }
  }
  const first = pages[0]
  const cardReady = filters.sku !== '' && filters.location !== ''
  const cardError = (err: unknown) => ((err as { status?: unknown } | null)?.status === 404 ? 'stock.balances.cardEmpty' : printErrorMessageId(err))
  const onCard = (format: 'pdf' | 'docx') =>
    void card.run(
      `form-z3-${format}`,
      () =>
        stockApi.stockCard({
          sku: filters.sku,
          location: filters.location,
          ...(filters.lot !== '' ? { lot: filters.lot } : {}),
          format,
          lang: officialFormLang(getUiLocale()),
        }),
      `stock-card_Z-3.${format}`,
      cardError,
    )
  const selectedRow = selected === null ? null : (rows.find((r) => rowId(r) === selected) ?? null)

  const tableRef = useRef<HTMLTableElement>(null)
  useColResize(tableRef, {
    id: 'list',
    screen: 'stock.balances',
    cols: LIST_COLS,
    minTable: true,
    enabled: () => isWideHost(tableRef.current),
  })

  const listBody = (
    <DataTable
      columns={columns}
      data={rows}
      isLoading={query.isPending}
      getRowId={rowId}
      onRowClick={(r) => setSelected(rowId(r))}
      selectedId={selected}
      emptyMessage={t('stock.balances.empty')}
      emptyText={t('stock.balances.emptyText')}
      labels={{ loading: t('stock.common.loading'), retry: t('stock.common.retry') }}
      tableRef={tableRef}
    />
  )
  const listFooter = <LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />
  const detail = selectedRow ? (
    <BalanceHistoryPanel row={selectedRow} asOf={asOf} onClose={() => setSelected(null)} name={name} />
  ) : null
  const empty = <EmptyState title={t('stock.balances.pickRow')} text={t('stock.balances.pickRowText')} data-testid="balances-pick-row" />

  return (
    <>
      {anyPickerTruncated(items, locations, units, people, lots) && <TruncatedNotice messageId="stock.pickers.truncated" count={MAX_ROWS} />}
      <PageHeader eyebrow={t('stock.eyebrow')} title={t('stock.balances.title')} lede={t('stock.balances.lede')}
        actions={
          <>
            <StockHelpLink topic="balances" />
            <Button variant="secondary" loading={exporting} disabled={query.isPending || query.isError} onClick={() => void onExport()}>
              {t('stock.balances.export')}
            </Button>
            <OfficialFormMenu
              forms={['z3']}
              busyKey={card.busyKey}
              disabledForms={cardReady ? undefined : { z3: 'stock.balances.cardHint' }}
              onPick={(_form, format) => onCard(format)}
            />
          </>
        }
      />
      {exportFailed && <Banner tone="danger">{t('stock.balances.exportFailed')}</Banner>}
      {card.error !== null && <Banner tone="danger">{t(card.error)}</Banner>}
      {!cardReady && <p className="caption" data-testid="stock-card-hint">{t('stock.balances.cardHint')}</p>}
      {query.hasNextPage && <p className="caption">{t('stock.balances.exportHint')}</p>}
      <FilterBar
        activeChips={chips}
        onRemoveChip={(id) => (id === 'as_of_date' ? setAsOf('') : set(id as keyof BalanceFilters)(''))}
        onClear={() => {
          setSelected(null)
          setFilters(EMPTY_BALANCE_FILTERS)
          setAsOf('')
        }}
        labels={{ clear: t('stock.common.clear'), remove: t('stock.common.remove') }}
      >
        <Select label={t('stock.filter.sku')} value={filters.sku} onChange={set('sku')} options={items} placeholder={t('stock.common.all')} />
        <Select label={t('stock.filter.location')} value={filters.location} onChange={set('location')} options={locations} placeholder={t('stock.common.all')} />
        <Select label={t('stock.filter.org_unit')} value={filters.org_unit} onChange={set('org_unit')} options={units} placeholder={t('stock.common.all')} />
        <Select label={t('stock.filter.responsible')} value={filters.responsible} onChange={set('responsible')} options={people} placeholder={t('stock.common.all')} />
        <Select
          label={t('stock.filter.lot')}
          value={filters.lot}
          onChange={set('lot')}
          options={lots}
          placeholder={t('stock.common.all')}
          disabled={filters.sku === ''}
          hint={filters.sku === '' ? t('stock.filter.lotHint') : undefined}
        />
        <Field
          label={t('stock.filter.asOf')}
          hint={t('stock.filter.asOfHint')}
          error={
            asOf !== '' && !AS_OF_DATE.test(asOf)
              ? t('stock.filter.asOfInvalid')
              : asOf > todayIso()
                ? t('stock.filter.asOfFuture')
                : undefined
          }
          mono
          width="m"
        >
          <input name="as-of-date" type="date" max={todayIso()} value={asOf} onChange={(e) => {
            setSelected(null)
            setAsOf(e.target.value)
          }} />
        </Field>
        <DateValueHint value={asOf} kind="date" />
      </FilterBar>
      {first?.as_of_date ? (
        <p className="caption" data-testid="as-of-read">
          {intl.formatMessage(
            { id: 'stock.balances.asOfRead' },
            { date: formatLocalInput(first.as_of_date, 'date', intl.locale), zone: first.timezone ?? '', seq: first.cutoff_seq ?? ledgerSeq ?? '' },
          )}
        </p>
      ) : (
        ledgerSeq != null && (
          <p className="caption" data-testid="ledger-seq">
            {intl.formatMessage({ id: 'stock.balances.readAt' }, { seq: ledgerSeq })}
          </p>
        )
      )}
      {query.isError && <RegisterError error={query.error} onRetry={() => void query.refetch()} />}
      {/* stays mounted on a load error (hidden) so the splitter keeps its container */}
      <div hidden={query.isError}>
        <ListDetail
          screen="stock.balances"
          listLabel={t('stock.balances.listPane')}
          listMin={320}
          listDefault={60}
          list={listBody}
          listFooter={listFooter}
          detail={detail ?? <></>}
          empty={empty}
          detailOpen={selectedRow != null}
          onClose={() => setSelected(null)}
        />
      </div>
    </>
  )
}

/** `initialSelectedId`: opens the history panel of one row at first render (the screen harness uses it). */
export default function BalancesPage({ initialSelectedId }: { initialSelectedId?: string } = {}) {
  return (
    <StockIntlProvider>
      <BalancesInner initialSelectedId={initialSelectedId ?? null} />
    </StockIntlProvider>
  )
}
