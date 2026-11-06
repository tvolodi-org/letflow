/** BalanceHistoryPanel — T-1334 / C14. The detail panel of an asset balance row: the postings that make the balance.
 *  The movements route takes no slot keys, so the panel pages the unfiltered movements and keeps the legs whose five
 *  slots equal the row's (`balanceHistoryModel`); it says so while more pages exist. One line per matching leg, oldest
 *  first (the route's order). No running balance: quantities are decimal text. */
import { useRef } from 'react'
import { useIntl } from 'react-intl'
import { Link } from 'react-router-dom'
import { X } from 'lucide-react'
import { useInfiniteQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { useColResize } from '@/components/ui/layout/ColumnResize'
import { isWideHost } from '@/components/ui/layout/isWideHost'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { formatQuantity } from '@/lib/formatQuantity'
import { assetsQueryKeys } from '../assetsQueryKeys'
import { useNames } from '../assetsNames'
import { LoadMore, RegisterError } from './RegisterShell'
import { assetRegisterApi, type AssetBalanceRow, type AssetMovementsBody } from './assetRegister.api'
import { toHistoryLines, type HistoryLine } from './balanceHistoryModel'
import { CAUSES, DOCUMENT_TYPES, documentCell, formatAssetsDateTime } from './registerModel'

/** The data hook: the movements of the whole ledger (no slot filter exists), cursor-paged, matched on the client. */
export function useBalanceHistory(row: AssetBalanceRow) {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const query = useInfiniteQuery({
    queryKey: assetsQueryKeys.balanceHistory(tenantId, 'all'),
    queryFn: ({ pageParam }) => assetRegisterApi.movements(pageParam ? { cursor: pageParam } : {}),
    initialPageParam: '' as string,
    getNextPageParam: (last: AssetMovementsBody, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })
  const pages = query.data?.pages ?? []
  return { query, lines: toHistoryLines(pages.flatMap((p) => p.rows), row) }
}

/** Default widths (percent of the table, the last column is the flexible one) and smallest widths (px). The panel is
 *  about 420 px wide at 1440, so the smallest widths sum to less than that. */
const HISTORY_COLS = [
  { id: 'time', w: 32, min: 118 },
  { id: 'doc', w: 22, min: 80 },
  { id: 'cause', w: 18, min: 72 },
  { id: 'in', w: 14, min: 60 },
  { id: 'out', w: 0, min: 60 },
]

export interface BalanceHistoryPanelProps {
  row: AssetBalanceRow
  onClose: () => void
  name: ReturnType<typeof useNames>
}

export function BalanceHistoryPanel({ row, onClose, name }: BalanceHistoryPanelProps) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { query, lines } = useBalanceHistory(row)
  const tableRef = useRef<HTMLTableElement>(null)
  useColResize(tableRef, {
    id: 'history',
    screen: 'assets.balances',
    cols: HISTORY_COLS,
    minTable: true,
    enabled: () => isWideHost(tableRef.current?.closest<HTMLElement>('.lf-reg') ?? null),
  })
  const dash = t('assets.common.dash')
  const known = (list: readonly string[], prefix: string, v: string) => (list.includes(v) ? t(`${prefix}.${v}`) : v)
  const amount = (q: string) => `${formatQuantity(q.replace(/^-/, ''))} ${row.unit_ref}`.trim()

  const columns: DataTableColumn<HistoryLine>[] = [
    { key: 'time', label: t('assets.reg.col.time'), render: (l) => (l.time ? formatAssetsDateTime(l.time, { locale: intl.locale }) : dash), mono: true },
    {
      key: 'doc',
      label: t('assets.reg.col.document'),
      render: (l) => {
        const cell = documentCell({ document_type: l.documentType, document_id: l.documentId }, (type) => known(DOCUMENT_TYPES, 'assets.docType', type))
        if (!cell) return dash
        return cell.to ? <Link to={cell.to} data-testid="history-doc-link">{cell.text}</Link> : cell.text
      },
    },
    { key: 'cause', label: t('assets.reg.col.cause'), render: (l) => known(CAUSES, 'assets.cause', l.cause) },
    { key: 'in', label: t('assets.history.in'), render: (l) => (l.isIn ? amount(l.quantity) : dash), align: 'end', mono: true },
    { key: 'out', label: t('assets.history.out'), render: (l) => (l.isOut ? amount(l.quantity) : dash), align: 'end', mono: true },
  ]

  return (
    <div data-testid="balance-history">
      <DetailHeader
        title={name('assets_card', row.asset)}
        path={`${t('assets.history.title')} · ${name('org_unit', row.org_unit)}`}
        actions={
          <Button variant="ghost" size="sm" iconOnly label={t('assets.history.close')} icon={<X className="lf-icon" aria-hidden="true" />} onClick={onClose} data-testid="history-close" />
        }
      />
      <div className="lf-card__body lf-form">
        <dl className="lf-dl" data-testid="history-facts">
          <dt>{t('assets.reg.col.location')}</dt>
          <dd>{name('location_node', row.location) || dash}</dd>
          <dt>{t('assets.reg.col.responsible')}</dt>
          <dd>{name('org_employee', row.material_responsible) || dash}</dd>
          <dt>{t('assets.reg.col.user')}</dt>
          <dd>{name('org_employee', row.actual_user) || dash}</dd>
          <dt>{t('assets.history.currentBalance')}</dt>
          <dd className="mono">{`${formatQuantity(row.quantity)} ${row.unit_ref}`.trim()}</dd>
        </dl>
        {query.hasNextPage && (
          <p className="caption" data-testid="history-loaded-note">{t('assets.history.loadedNote')}</p>
        )}
        {query.isError ? (
          <RegisterError error={query.error} onRetry={() => void query.refetch()} />
        ) : (
          <>
            <DataTable
              columns={columns}
              data={lines}
              density="compact"
              tableRef={tableRef}
              isLoading={query.isPending}
              getRowId={(l) => l.key}
              emptyMessage={t('assets.history.empty')}
              emptyText={t('assets.history.emptyText')}
              labels={{ loading: t('assets.reg.loading'), retry: t('assets.reg.retry') }}
            />
            <LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />
          </>
        )}
      </div>
    </div>
  )
}
