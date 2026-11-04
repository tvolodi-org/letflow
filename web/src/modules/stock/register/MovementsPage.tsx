/** MovementsPage — GH 3767 / REQ-724. Posted ledger entries, newest first in posting order, with their legs.
 *  Filters cause, document and posting range; a leg the route answers with masked true shows its quantity and
 *  unit and the words hidden unit. Times are shown in the tenant time zone (constant until REQ-703). */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { useSearchParams } from 'react-router-dom'
import { useInfiniteQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { Field } from '@/components/ui/Field'
import { FilterBar } from '@/components/ui/FilterBar'
import { PageHeader } from '@/components/ui/PageHeader'
import { Select } from '@/components/ui/Select'
import { StockIntlProvider } from '../StockIntlProvider'
import { LoadMore, RegisterError } from './RegisterShell'
import { stockApi, type MovementRow, type MovementsPageBody } from './stock.api'
import { stockQueryKeys } from './stockQueryKeys'
import {
  CAUSES,
  DOCUMENT_TYPES,
  STOCK_TIME_ZONE,
  isMasked,
  movementNameIds,
  movementParams,
  rangeError,
  type MovementFilters,
} from './stockRegisterModel'
import { useNames } from './stockNames'

const digits = (v: string) => v.replace(/\D/g, '')

function MovementsInner() {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [search] = useSearchParams()
  const [filters, setFilters] = useState<MovementFilters>({
    cause: '',
    document_id: (search.get('document_id') ?? '').trim(),
    from_seq: '',
    to_seq: '',
  })
  const [openId, setOpenId] = useState<string | null>(null)
  const patch = (p: Partial<MovementFilters>) => setFilters((f) => ({ ...f, ...p }))
  const badRange = rangeError(filters.from_seq, filters.to_seq)

  const params = movementParams(filters)
  const query = useInfiniteQuery({
    queryKey: stockQueryKeys.movements(tenantId, JSON.stringify(params)),
    queryFn: ({ pageParam }) => stockApi.movements({ ...params, ...(pageParam ? { cursor: pageParam } : {}) }),
    initialPageParam: '' as string,
    getNextPageParam: (last: MovementsPageBody, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })
  const pages = query.data?.pages ?? []
  const rows = pages.flatMap((p) => p.rows)
  const name = useNames(pages.map((p) => movementNameIds(p.rows)))
  const opened = rows.find((r) => r.entry_id === openId) ?? null

  const dash = t('stock.common.dash')
  const when = (iso: string | null | undefined) => {
    if (!iso) return dash
    const d = new Date(iso)
    if (Number.isNaN(d.getTime())) return iso
    return new Intl.DateTimeFormat(intl.locale, {
      timeZone: STOCK_TIME_ZONE,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23',
    }).format(d)
  }
  const known = (list: readonly string[], prefix: string, v: string) => (list.includes(v) ? t(`${prefix}.${v}`) : v)

  const columns: DataTableColumn<MovementRow>[] = [
    { key: 'seq', label: t('stock.col.posting'), render: (r) => String(r.posting_seq), mono: true },
    { key: 'time', label: t('stock.col.time'), render: (r) => when(r.event_time), mono: true },
    { key: 'cause', label: t('stock.col.cause'), render: (r) => known(CAUSES, 'stock.cause', r.cause) },
    { key: 'reason', label: t('stock.col.reason'), render: (r) => r.reason_code || dash },
    {
      key: 'doc',
      label: t('stock.col.document'),
      render: (r) => (r.document_type ? known(DOCUMENT_TYPES, 'stock.docType', r.document_type) : dash),
    },
    {
      key: 'legs',
      label: t('stock.col.legs'),
      render: (r) => (
        <Button variant="ghost" size="sm" onClick={() => setOpenId(openId === r.entry_id ? null : r.entry_id)}>
          {t(openId === r.entry_id ? 'stock.legs.hide' : 'stock.legs.show')}
        </Button>
      ),
    },
  ]

  return (
    <>
      <PageHeader eyebrow={t('stock.eyebrow')} title={t('stock.movements.title')} lede={t('stock.movements.lede')} />
      <FilterBar
        activeCount={Object.keys(params).length}
        onClear={() => patch({ cause: '', document_id: '', from_seq: '', to_seq: '' })}
        labels={{ clear: t('stock.common.clear'), remove: t('stock.common.remove') }}
      >
        <Select
          label={t('stock.filter.cause')}
          value={filters.cause}
          onChange={(cause) => patch({ cause })}
          options={CAUSES.map((c) => ({ value: c, label: t(`stock.cause.${c}`) }))}
          placeholder={t('stock.common.all')}
        />
        <Field label={t('stock.filter.document')}>
          <input type="text" value={filters.document_id} onChange={(e) => patch({ document_id: e.target.value })} />
        </Field>
        <Field label={t('stock.filter.fromSeq')} error={badRange ? t('stock.filter.rangeError') : undefined}>
          <input
            type="text"
            inputMode="numeric"
            value={filters.from_seq}
            onChange={(e) => patch({ from_seq: digits(e.target.value) })}
          />
        </Field>
        <Field label={t('stock.filter.toSeq')} error={badRange ? t('stock.filter.rangeError') : undefined}>
          <input
            type="text"
            inputMode="numeric"
            value={filters.to_seq}
            onChange={(e) => patch({ to_seq: digits(e.target.value) })}
          />
        </Field>
      </FilterBar>
      {query.isError ? (
        <RegisterError error={query.error} onRetry={() => void query.refetch()} />
      ) : (
        <>
          <DataTable
            columns={columns}
            data={rows}
            isLoading={query.isPending}
            getRowId={(r) => r.entry_id}
            selectedId={openId}
            emptyMessage={t('stock.movements.empty')}
            emptyText={t('stock.movements.emptyText')}
            labels={{ loading: t('stock.common.loading'), retry: t('stock.common.retry') }}
          />
          {opened && (
            <section aria-label={t('stock.legs.title')} data-testid="legs-panel">
              <h2>{t('stock.legs.title')}</h2>
              <table className="lf-table">
                <thead>
                  <tr>
                    <th>{t('stock.col.leg')}</th>
                    <th>{t('stock.col.item')}</th>
                    <th>{t('stock.col.location')}</th>
                    <th>{t('stock.col.orgUnit')}</th>
                    <th>{t('stock.col.responsible')}</th>
                    <th>{t('stock.col.lot')}</th>
                    <th>{t('stock.col.unit')}</th>
                    <th>{t('stock.col.quantity')}</th>
                  </tr>
                </thead>
                <tbody>
                  {opened.legs.map((l) => (
                    <tr key={l.leg_no} data-testid="leg-row">
                      <td className="mono">{l.leg_no}</td>
                      {isMasked(l) ? (
                        <td colSpan={5}>{t('stock.leg.hiddenUnit')}</td>
                      ) : (
                        <>
                          <td>{name('catalog_item', l.sku)}</td>
                          <td>{name('location_node', l.location)}</td>
                          <td>{name('org_unit', l.org_unit)}</td>
                          <td>{name('org_employee', l.responsible) || dash}</td>
                          <td>{name('catalog_lot', l.lot) || dash}</td>
                        </>
                      )}
                      <td>{name('catalog_uom', l.unit_ref)}</td>
                      <td className="mono">{l.quantity}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </section>
          )}
          <LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />
        </>
      )}
    </>
  )
}

export default function MovementsPage() {
  return (
    <StockIntlProvider>
      <MovementsInner />
    </StockIntlProvider>
  )
}
