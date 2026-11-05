/** BalancesPage — GH 3767 / REQ-724. Current balances of the stock register: five filters, names instead of ids,
 *  quantity text as the route answers it, Load more. Reads the latest basis only (no basis / cutoff_seq key). */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { useInfiniteQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { FilterBar } from '@/components/ui/FilterBar'
import { PageHeader } from '@/components/ui/PageHeader'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import { Banner } from '@/components/ui/Banner'
import { StockIntlProvider } from '../StockIntlProvider'
import { LoadMore, RegisterError } from './RegisterShell'
import { saveBlob } from './saveBlob'
import { stockApi, type BalanceRow, type BalancesPageBody } from './stock.api'
import { usePickerOptions } from './stockPickers'
import { stockQueryKeys } from './stockQueryKeys'
import { EMPTY_BALANCE_FILTERS, AS_OF_DATE, balanceNameIds, balanceParams, balanceQuery, todayIso, type BalanceFilters } from './stockRegisterModel'
import { useNames } from './stockNames'

const ACTIVE_ONLY: never[] = []

function BalancesInner() {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [filters, setFilters] = useState<BalanceFilters>(EMPTY_BALANCE_FILTERS)
  const [asOf, setAsOf] = useState('')
  const [exporting, setExporting] = useState(false)
  const [exportFailed, setExportFailed] = useState(false)
  const set = (key: keyof BalanceFilters) => (value: string) =>
    setFilters((f) => ({ ...f, [key]: value, ...(key === 'sku' ? { lot: '' } : {}) }))

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
    { key: 'quantity', label: t('stock.col.quantity'), render: (r) => r.quantity, align: 'end', mono: true },
  ]
  const chips: { id: string; label: string }[] = (Object.keys(filterParams) as (keyof BalanceFilters)[]).map((k) => ({
    id: k,
    label: `${t(`stock.filter.${k}`)}: ${
      [...items, ...locations, ...units, ...people, ...lots].find((o) => o.value === filterParams[k])?.label ?? filterParams[k]
    }`,
  }))
  if (params.as_of_date) chips.push({ id: 'as_of_date', label: `${t('stock.filter.asOf')}: ${params.as_of_date}` })

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

  return (
    <>
      <PageHeader eyebrow={t('stock.eyebrow')} title={t('stock.balances.title')} lede={t('stock.balances.lede')}
        actions={
          <Button variant="secondary" loading={exporting} disabled={query.isPending || query.isError} onClick={() => void onExport()}>
            {t('stock.balances.export')}
          </Button>
        }
      />
      {exportFailed && <Banner tone="danger">{t('stock.balances.exportFailed')}</Banner>}
      {query.hasNextPage && <p className="caption">{t('stock.balances.exportHint')}</p>}
      <FilterBar
        activeChips={chips}
        onRemoveChip={(id) => (id === 'as_of_date' ? setAsOf('') : set(id as keyof BalanceFilters)(''))}
        onClear={() => {
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
          <input name="as-of-date" type="date" max={todayIso()} value={asOf} onChange={(e) => setAsOf(e.target.value)} />
        </Field>
      </FilterBar>
      {first?.as_of_date ? (
        <p className="caption" data-testid="as-of-read">
          {intl.formatMessage(
            { id: 'stock.balances.asOfRead' },
            { date: first.as_of_date, zone: first.timezone ?? '', seq: first.cutoff_seq ?? ledgerSeq ?? '' },
          )}
        </p>
      ) : (
        ledgerSeq != null && (
          <p className="caption" data-testid="ledger-seq">
            {intl.formatMessage({ id: 'stock.balances.readAt' }, { seq: ledgerSeq })}
          </p>
        )
      )}
      {query.isError ? (
        <RegisterError error={query.error} onRetry={() => void query.refetch()} />
      ) : (
        <>
          <DataTable
            columns={columns}
            data={rows}
            isLoading={query.isPending}
            getRowId={(r) => `${r.sku}|${r.location}|${r.org_unit}|${r.responsible ?? ''}|${r.lot ?? ''}|${r.unit_ref}`}
            emptyMessage={t('stock.balances.empty')}
            emptyText={t('stock.balances.emptyText')}
            labels={{ loading: t('stock.common.loading'), retry: t('stock.common.retry') }}
          />
          <LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />
        </>
      )}
    </>
  )
}

export default function BalancesPage() {
  return (
    <StockIntlProvider>
      <BalancesInner />
    </StockIntlProvider>
  )
}
