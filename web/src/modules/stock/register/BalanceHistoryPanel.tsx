/** BalanceHistoryPanel — T-1430 (GATE B R14). The detail panel of a stock balance row: the postings that make the
 *  balance, read from the movements route filtered by the row's five slots. One line per matching leg, oldest first
 *  (the route's order). No running balance: the quantities are decimal text, the route is ascending only and the
 *  as-of view would make a sum wrong. The hook is separate from the markup so a journal list can replace the table. */
import { useIntl } from 'react-intl'
import { Link } from 'react-router-dom'
import { X } from 'lucide-react'
import { useInfiniteQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { formatLocalInput } from '@/i18n/format'
import { formatQuantity } from '@/lib/formatQuantity'
import { LoadMore, RegisterError } from './RegisterShell'
import { stockApi, type BalanceRow, type MovementsPageBody } from './stock.api'
import { slotParams, toHistoryLines, type HistoryLine } from './balanceHistoryModel'
import { stockQueryKeys } from './stockQueryKeys'
import { CAUSES, DOCUMENT_TYPES, documentCell, formatStockDateTime } from './stockRegisterModel'
import { useNames } from './stockNames'

/** The data hook: the movements of one balance key, cursor-paged. */
export function useBalanceHistory(row: BalanceRow) {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const params = slotParams(row)
  const query = useInfiniteQuery({
    queryKey: stockQueryKeys.balanceHistory(tenantId, JSON.stringify(params)),
    queryFn: ({ pageParam }) => stockApi.movements({ ...params, ...(pageParam ? { cursor: pageParam } : {}) }),
    initialPageParam: '' as string,
    getNextPageParam: (last: MovementsPageBody, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })
  const pages = query.data?.pages ?? []
  return { query, lines: toHistoryLines(pages.flatMap((p) => p.rows), row) }
}

export interface BalanceHistoryPanelProps {
  row: BalanceRow
  /** The as-of day of the balances screen, when set: the panel says the movements are not cut at it. */
  asOf?: string
  onClose: () => void
  name: ReturnType<typeof useNames>
}

export function BalanceHistoryPanel({ row, asOf = '', onClose, name }: BalanceHistoryPanelProps) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { query, lines } = useBalanceHistory(row)
  const dash = t('stock.common.dash')
  const known = (list: readonly string[], prefix: string, v: string) => (list.includes(v) ? t(`${prefix}.${v}`) : v)
  const unit = name('catalog_uom', row.unit_ref)
  const amount = (q: string) => `${formatQuantity(q.replace(/^-/, ''))} ${unit}`.trim()

  const columns: DataTableColumn<HistoryLine>[] = [
    { key: 'time', label: t('stock.col.time'), render: (l) => (l.time ? formatStockDateTime(l.time, { locale: intl.locale }) : dash), mono: true },
    {
      key: 'doc',
      label: t('stock.col.document'),
      render: (l) => {
        const cell = documentCell(
          { document_type: l.documentType, document_id: l.documentId, document_number: l.documentNumber },
          (type) => known(DOCUMENT_TYPES, 'stock.docType', type),
        )
        if (!cell) return dash
        return cell.to ? <Link to={cell.to} data-testid="history-doc-link">{cell.text}</Link> : cell.text
      },
    },
    { key: 'cause', label: t('stock.col.cause'), render: (l) => known(CAUSES, 'stock.cause', l.cause) },
    { key: 'in', label: t('stock.history.col.in'), render: (l) => (l.isIn ? amount(l.quantity) : dash), align: 'end', mono: true },
    { key: 'out', label: t('stock.history.col.out'), render: (l) => (l.isOut ? amount(l.quantity) : dash), align: 'end', mono: true },
  ]

  return (
    <div data-testid="balance-history">
      <DetailHeader
        title={name('catalog_item', row.sku)}
        path={`${t('stock.history.title')} · ${name('location_node', row.location)}`}
        actions={
          <Button variant="ghost" size="sm" iconOnly label={t('stock.history.close')} icon={<X className="lf-icon" aria-hidden="true" />} onClick={onClose} data-testid="history-close" />
        }
      />
      <div className="lf-card__body">
      <dl className="lf-dl" data-testid="history-facts">
        <dt>{t('stock.col.orgUnit')}</dt>
        <dd>{name('org_unit', row.org_unit)}</dd>
        <dt>{t('stock.col.responsible')}</dt>
        <dd>{name('org_employee', row.responsible) || dash}</dd>
        <dt>{t('stock.col.lot')}</dt>
        <dd>{name('catalog_lot', row.lot) || dash}</dd>
        <dt>{t('stock.history.currentBalance')}</dt>
        <dd className="mono">{`${formatQuantity(row.quantity)} ${unit}`.trim()}</dd>
      </dl>
      {asOf !== '' && (
        <p className="caption" data-testid="history-as-of">
          {intl.formatMessage({ id: 'stock.history.asOfNote' }, { date: formatLocalInput(asOf, 'date', intl.locale) })}
        </p>
      )}
      {query.isError ? (
        <RegisterError error={query.error} onRetry={() => void query.refetch()} />
      ) : (
        <>
          <DataTable
            columns={columns}
            data={lines}
            density="compact"
            isLoading={query.isPending}
            getRowId={(l) => l.key}
            emptyMessage={t('stock.history.empty')}
            emptyText={t('stock.history.emptyText')}
            labels={{ loading: t('stock.common.loading'), retry: t('stock.common.retry') }}
          />
          <LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />
        </>
      )}
      </div>
    </div>
  )
}
