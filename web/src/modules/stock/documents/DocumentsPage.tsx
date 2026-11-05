/** DocumentsPage — GH 3769 / REQ-722. The list of stock documents: filters kind, state and org unit, Load more, and a
 *  record panel of the selected row (MasterDetail) with a link to the document view. Times in the tenant time zone. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Link, useNavigate } from 'react-router-dom'
import { useInfiniteQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { FilterBar } from '@/components/ui/FilterBar'
import { PageHeader } from '@/components/ui/PageHeader'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import { StockIntlProvider } from '../StockIntlProvider'
import { LoadMore, RegisterError } from '../register/RegisterShell'
import { stockQueryKeys } from '../register/stockQueryKeys'
import { useNames } from '../register/stockNames'
import { usePickerOptions } from '../register/stockPickers'
import { STOCK_POST } from '../stockPermissions'
import { documentsApi, type DocumentRow, type DocumentsPageBody } from './documents.api'
import { DOC_KINDS, DOC_STATES, formatEventTime } from './documentsModel'
import { stateTone } from './stateTone'

interface Filters {
  kind: string
  state: string
  org_unit_id: string
}
const EMPTY: Filters = { kind: '', state: '', org_unit_id: '' }

function DocumentsInner() {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { session } = useAuth()
  const { can } = useAccess()
  const navigate = useNavigate()
  const tenantId = session?.tenant_id ?? ''
  const [filters, setFilters] = useState<Filters>(EMPTY)
  const [openId, setOpenId] = useState<string | null>(null)
  const patch = (p: Partial<Filters>) => setFilters((f) => ({ ...f, ...p }))
  const orgUnits = usePickerOptions('org_unit')

  const params = Object.fromEntries(Object.entries(filters).filter(([, v]) => v !== ''))
  const query = useInfiniteQuery({
    queryKey: stockQueryKeys.documents(tenantId, JSON.stringify(params)),
    queryFn: ({ pageParam }) => documentsApi.list({ ...params, ...(pageParam ? { cursor: pageParam } : {}) }),
    initialPageParam: '' as string,
    getNextPageParam: (last: DocumentsPageBody, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })
  const pages = query.data?.pages ?? []
  const rows = pages.flatMap((p) => p.rows)
  const name = useNames(pages.map((p) => ({ org_unit: p.rows.map((r) => r.org_unit_id).filter((x): x is string => !!x) })))
  const opened = rows.find((r) => r.id === openId) ?? null
  const dash = t('stock.common.dash')
  const known = (list: readonly string[], prefix: string, v: string) => (list.includes(v) ? t(`${prefix}.${v}`) : v)
  const canPost = can(STOCK_POST)

  const columns: DataTableColumn<DocumentRow>[] = [
    { key: 'number', label: t('stock.doc.col.number'), render: (r) => r.number ?? t('stock.doc.draftMark'), mono: true },
    { key: 'kind', label: t('stock.doc.col.kind'), render: (r) => known(DOC_KINDS, 'stock.doc.kind', r.kind) },
    { key: 'time', label: t('stock.col.time'), render: (r) => formatEventTime(r.event_time, intl.locale, dash), mono: true },
    { key: 'org', label: t('stock.col.orgUnit'), render: (r) => name('org_unit', r.org_unit_id) || dash },
    {
      key: 'state',
      label: t('stock.doc.col.state'),
      hideStackLabel: true,
      render: (r) => (
        <StatusPill tone={stateTone(r.state).tone} glyph={stateTone(r.state).glyph}>
          {known(DOC_STATES, 'stock.doc.state', r.state)}
        </StatusPill>
      ),
    },
  ]

  const newAction = canPost ? (
    <Button variant="primary" onClick={() => navigate('/admin/stock/documents/new')}>
      {t('stock.doc.new')}
    </Button>
  ) : undefined

  return (
    <>
      <PageHeader eyebrow={t('stock.eyebrow')} title={t('stock.doc.title')} lede={t('stock.doc.lede')} actions={newAction} />
      <FilterBar
        activeCount={Object.keys(params).length}
        onClear={() => setFilters(EMPTY)}
        labels={{ clear: t('stock.common.clear'), remove: t('stock.common.remove') }}
      >
        <Select
          label={t('stock.doc.col.kind')}
          value={filters.kind}
          onChange={(kind) => patch({ kind })}
          options={DOC_KINDS.map((k) => ({ value: k, label: t(`stock.doc.kind.${k}`) }))}
          placeholder={t('stock.common.all')}
        />
        <Select
          label={t('stock.doc.col.state')}
          value={filters.state}
          onChange={(state) => patch({ state })}
          options={DOC_STATES.map((k) => ({ value: k, label: t(`stock.doc.state.${k}`) }))}
          placeholder={t('stock.common.all')}
        />
        <Select
          label={t('stock.col.orgUnit')}
          value={filters.org_unit_id}
          onChange={(org_unit_id) => patch({ org_unit_id })}
          options={orgUnits}
          placeholder={t('stock.common.all')}
        />
      </FilterBar>
      {query.isError ? (
        <RegisterError error={query.error} onRetry={() => void query.refetch()} />
      ) : (
        <>
          <DataTable
            columns={columns}
            data={rows}
            isLoading={query.isPending}
            getRowId={(r) => r.id}
            selectedId={openId}
            onRowClick={(r) => setOpenId(r.id === openId ? null : r.id)}
            emptyMessage={t('stock.doc.empty')}
            emptyText={t('stock.doc.emptyText')}
            emptyAction={
              canPost ? (
                <Button variant="primary" onClick={() => navigate('/admin/stock/documents/new')}>
                  {t('stock.doc.new')}
                </Button>
              ) : undefined
            }
            labels={{ loading: t('stock.common.loading'), retry: t('stock.common.retry') }}
          />
          {opened && (
            <section aria-label={t('stock.doc.panel')} data-testid="document-panel">
              <h2>{opened.number ?? t('stock.doc.draftMark')}</h2>
              <p>
                {known(DOC_KINDS, 'stock.doc.kind', opened.kind)} · {known(DOC_STATES, 'stock.doc.state', opened.state)}
              </p>
              <p className="mono">{formatEventTime(opened.event_time, intl.locale, dash)}</p>
              <p>{name('org_unit', opened.org_unit_id) || dash}</p>
              <Link to={`/admin/stock/documents/${encodeURIComponent(opened.id)}`}>{t('stock.doc.open')}</Link>
            </section>
          )}
          <LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />
        </>
      )}
    </>
  )
}

export default function DocumentsPage() {
  return (
    <StockIntlProvider>
      <DocumentsInner />
    </StockIntlProvider>
  )
}
