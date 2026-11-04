/** BalancesPage — GH 3767 / REQ-724. Current balances of the stock register: five filters, names instead of ids,
 *  quantity text as the route answers it, Load more. Reads the latest basis only (no basis / cutoff_seq key). */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { useInfiniteQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { FilterBar } from '@/components/ui/FilterBar'
import { PageHeader } from '@/components/ui/PageHeader'
import { Select } from '@/components/ui/Select'
import { StockIntlProvider } from '../StockIntlProvider'
import { LoadMore, RegisterError } from './RegisterShell'
import { stockApi, type BalanceRow, type BalancesPageBody } from './stock.api'
import { usePickerOptions } from './stockPickers'
import { stockQueryKeys } from './stockQueryKeys'
import { EMPTY_BALANCE_FILTERS, balanceNameIds, balanceParams, type BalanceFilters } from './stockRegisterModel'
import { useNames } from './stockNames'

const ACTIVE_ONLY: never[] = []

function BalancesInner() {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [filters, setFilters] = useState<BalanceFilters>(EMPTY_BALANCE_FILTERS)
  const set = (key: keyof BalanceFilters) => (value: string) =>
    setFilters((f) => ({ ...f, [key]: value, ...(key === 'sku' ? { lot: '' } : {}) }))

  const items = usePickerOptions('catalog_item', ACTIVE_ONLY)
  const locations = usePickerOptions('location_node', ACTIVE_ONLY)
  const units = usePickerOptions('org_unit', ACTIVE_ONLY)
  const people = usePickerOptions('org_employee', ACTIVE_ONLY)
  const lots = usePickerOptions('catalog_lot', [{ field: 'item_id', op: 'eq', value: filters.sku }], filters.sku !== '')

  const params = balanceParams(filters)
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
  const chips = (Object.keys(params) as (keyof BalanceFilters)[]).map((k) => ({
    id: k,
    label: `${t(`stock.filter.${k}`)}: ${
      [...items, ...locations, ...units, ...people, ...lots].find((o) => o.value === params[k])?.label ?? params[k]
    }`,
  }))

  return (
    <>
      <PageHeader eyebrow={t('stock.eyebrow')} title={t('stock.balances.title')} lede={t('stock.balances.lede')} />
      <FilterBar
        activeChips={chips}
        onRemoveChip={(id) => set(id as keyof BalanceFilters)('')}
        onClear={() => setFilters(EMPTY_BALANCE_FILTERS)}
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
      </FilterBar>
      {ledgerSeq != null && (
        <p className="caption" data-testid="ledger-seq">
          {intl.formatMessage({ id: 'stock.balances.readAt' }, { seq: ledgerSeq })}
        </p>
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
