/** CountsPage — GH 3735 / REQ-702. Count orders in a MasterDetail (rule 2a): the list with a status filter on the
 *  left; on the right the create form, or the order (and from status counting on, its sheet) of the route's :id.
 *  Escape and the close button leave the panel. Names of masters come through the generic query route only. */
import { useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { useNavigate, useParams } from 'react-router-dom'
import { useInfiniteQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { MasterDetail } from '@/components/ui/MasterDetail'
import { PageHeader } from '@/components/ui/PageHeader'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import { StockIntlProvider } from '../StockIntlProvider'
import { LoadMore, RegisterError } from '../register/RegisterShell'
import { useNames } from '../register/stockNames'
import type { NameIds } from '../register/stockRegisterModel'
import { countsApi, type CountOrder, type CountPage } from './counts.api'
import { CountDetail } from './CountDetail'
import { CountOrderForm } from './CountOrderForm'
import { countsQueryKeys } from './countsQueryKeys'
import { COUNT_STATUSES, STOCK_COUNT_ORDER, formatInZone, statusTone } from './countsModel'

const LIST = '/admin/stock/counts'

function orderNameIds(rows: CountOrder[]): NameIds {
  const out: NameIds = {}
  for (const r of rows) {
    out.org_unit = [...(out.org_unit ?? []), r.org_unit_id]
    if (r.chair_employee_id) (out.org_employee ??= []).push(r.chair_employee_id)
  }
  return out
}

function CountsInner() {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const navigate = useNavigate()
  const { id } = useParams<{ id: string }>()
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [status, setStatus] = useState('')
  const [creating, setCreating] = useState(false)

  const params: Record<string, string> = status === '' ? {} : { status }
  const query = useInfiniteQuery({
    queryKey: countsQueryKeys.list(tenantId, JSON.stringify(params)),
    queryFn: ({ pageParam }) => countsApi.list({ ...params, ...(pageParam ? { cursor: pageParam } : {}) }),
    initialPageParam: '' as string,
    getNextPageParam: (last: CountPage<CountOrder>, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })
  const pages = query.data?.pages ?? []
  const rows = pages.flatMap((p) => p.rows)
  const name = useNames(pages.map((p) => orderNameIds(p.rows)))
  const dash = t('stock.common.dash')

  const panelOpen = creating || id !== undefined
  const closePanel = () => {
    setCreating(false)
    if (id !== undefined) navigate(LIST)
  }
  // Escape leaves the panel (a dialog on top handles its own Escape first).
  useEffect(() => {
    if (!panelOpen) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !e.defaultPrevented && document.querySelector('[role="dialog"]') === null) closePanel()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  })

  const columns: DataTableColumn<CountOrder>[] = [
    {
      key: 'number',
      label: t('counts.col.number'),
      // Org unit, kind and planned start ride on muted lines under the number, so the list is two columns (number,
      // status) and no pill is cut off at 1024 px (T-1399 R7 gui_review).
      render: (r) => (
        <>
          <span className="mono">{r.number ?? dash}</span>
          <br />
          <span className="lf-hint">{[name('org_unit', r.org_unit_id), t(`counts.kind.${r.kind}`)].join(' · ')}</span>
          <br />
          <span className="lf-hint mono">{formatInZone(r.planned_start) || dash}</span>
        </>
      ),
    },
    {
      key: 'status',
      label: t('counts.col.status'),
      render: (r) => <StatusPill tone={statusTone(r.status)}>{t(`counts.status.${r.status}`)}</StatusPill>,
      hideStackLabel: true,
    },
  ]
  const canOrder = can(STOCK_COUNT_ORDER)
  const master = query.isError ? (
    <RegisterError error={query.error} onRetry={() => void query.refetch()} />
  ) : (
    <>
      <DataTable
        columns={columns}
        data={rows}
        isLoading={query.isPending}
        getRowId={(r) => r.id}
        selectedId={creating ? null : (id ?? null)}
        onRowClick={(r) => {
          setCreating(false)
          navigate(`${LIST}/${r.id}`)
        }}
        emptyMessage={t('counts.empty')}
        emptyText={t('counts.emptyText')}
        emptyAction={
          canOrder ? <Button variant="primary" size="md" onClick={() => setCreating(true)}>{t('counts.new')}</Button> : undefined
        }
        labels={{ loading: t('stock.common.loading'), retry: t('stock.common.retry') }}
      />
      <LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />
    </>
  )
  const detail = creating ? (
    <CountOrderForm
      onDiscard={closePanel}
      onSaved={(o) => {
        setCreating(false)
        navigate(`${LIST}/${o.id}`)
      }}
    />
  ) : id !== undefined ? (
    <CountDetail key={id} id={id} onClose={closePanel} />
  ) : (
    <div className="lf-card__body">
      <p className="lf-hint">{t('counts.hint')}</p>
    </div>
  )

  return (
    <>
      <PageHeader
        eyebrow={t('stock.eyebrow')}
        title={t('counts.title')}
        lede={t('counts.lede')}
        actions={
          canOrder ? (
            <Button variant="primary" size="md" onClick={() => setCreating(true)} data-testid="count-new">
              {t('counts.new')}
            </Button>
          ) : undefined
        }
      />
      <MasterDetail
        masterWidth="wide"
        tools={
          <Select
            label={t('counts.filter.status')}
            value={status}
            onChange={setStatus}
            options={COUNT_STATUSES.map((s) => ({ value: s, label: t(`counts.status.${s}`) }))}
            placeholder={t('counts.filter.all')}
          />
        }
        master={master}
        detail={detail}
        detailOpen={panelOpen}
        onBack={closePanel}
      />
    </>
  )
}

export default function CountsPage() {
  return (
    <StockIntlProvider>
      <CountsInner />
    </StockIntlProvider>
  )
}
