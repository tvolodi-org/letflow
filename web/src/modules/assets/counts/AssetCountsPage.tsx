/** AssetCountsPage — T-1933 / REQ-822 (K7a). Asset count orders in a ListDetail (rule 2a): the list with a status filter
 *  on the left; on the right the create form, or the order of the route's :id. Shown only when the tenant's module
 *  setting count_enabled is on: the server answers 404 to every count route otherwise, and a 404 on the list shows a
 *  "not switched on" card instead of the list. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { useNavigate, useParams } from 'react-router-dom'
import { useInfiniteQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access/useAccess'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { ListDetail } from '@/components/ui/listDetail'
import { PageHeader } from '@/components/ui/PageHeader'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { AssetsIntlProvider } from '../AssetsIntlProvider'
import { formatEventTime } from '../documents/documentsModel'
import { useNames } from '../assetsNames'
import { ASSETS_COUNT_ORDER } from '../assetsPermissions'
import { assetsQueryKeys } from '../assetsQueryKeys'
import type { NameIds } from '../register/registerModel'
import { LoadMore, RegisterError } from '../register/RegisterShell'
import { assetCountsApi, type AssetCountOrder, type CountPage } from './assetCounts.api'
import { AssetCountDetail } from './AssetCountDetail'
import { AssetCountOrderForm } from './AssetCountOrderForm'
import { COUNT_STATUSES, isFlagOff, statusTone } from './assetCountsModel'

const LIST = '/admin/assets/counts'

function orderNameIds(rows: AssetCountOrder[]): NameIds {
  const out: NameIds = {}
  for (const r of rows) (out.org_unit ??= []).push(r.org_unit_id)
  return out
}

function CountsInner() {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const locale = useUiLocale()
  const navigate = useNavigate()
  const { id } = useParams<{ id: string }>()
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const [status, setStatus] = useState('')
  const [creating, setCreating] = useState(false)

  const params: Record<string, string> = status === '' ? {} : { status }
  const query = useInfiniteQuery({
    queryKey: assetsQueryKeys.countList(tenantId, JSON.stringify(params)),
    queryFn: ({ pageParam }) => assetCountsApi.list({ ...params, ...(pageParam ? { cursor: pageParam } : {}) }),
    initialPageParam: '' as string,
    getNextPageParam: (last: CountPage<AssetCountOrder>, _all, lastParam) =>
      last.next_cursor && last.next_cursor !== lastParam ? last.next_cursor : undefined,
    retry: false,
  })
  const pages = query.data?.pages ?? []
  const rows = pages.flatMap((p) => p.rows)
  const name = useNames(pages.map((p) => orderNameIds(p.rows)))
  const dash = t('assets.common.dash')

  const flagOff = query.isError && isFlagOff(query.error)
  const canOrder = can(ASSETS_COUNT_ORDER) && !flagOff
  const panelOpen = creating || id !== undefined
  const closePanel = () => {
    setCreating(false)
    if (id !== undefined) navigate(LIST)
  }
  const columns: DataTableColumn<AssetCountOrder>[] = [
    {
      key: 'number',
      label: t('assets.count.col.number'),
      // The org unit, the kinds and the planned start ride on muted lines under the number, so the list is two columns.
      render: (r) => (
        <>
          <span className="mono">{r.number ?? dash}</span>
          <br />
          <span className="lf-hint">{[name('org_unit', r.org_unit_id), r.kinds.map((k) => t(`assets.kind.${k}`)).join(', ')].join(' · ')}</span>
          <br />
          <span className="lf-hint mono">{formatEventTime(r.planned_start, locale, dash)}</span>
        </>
      ),
    },
    {
      key: 'status',
      label: t('assets.count.col.status'),
      render: (r) => <StatusPill tone={statusTone(r.status)}>{t(`assets.count.status.${r.status}`)}</StatusPill>,
      hideStackLabel: true,
    },
  ]
  const master = query.isError ? (
    <RegisterError error={query.error} onRetry={() => void query.refetch()} />
  ) : (
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
      emptyMessage={t('assets.count.empty')}
      emptyText={t('assets.count.emptyText')}
      emptyAction={
        canOrder ? <Button variant="primary" size="md" onClick={() => setCreating(true)}>{t('assets.count.new')}</Button> : undefined
      }
      labels={{ loading: t('assets.count.loading'), retry: t('assets.count.retry') }}
    />
  )
  const listFooter = query.isError ? null : (
    <LoadMore visible={query.hasNextPage} loading={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()} />
  )
  const detail = creating ? (
    <AssetCountOrderForm
      onDiscard={closePanel}
      onSaved={(o) => {
        setCreating(false)
        navigate(`${LIST}/${o.id}`)
      }}
    />
  ) : id !== undefined ? (
    <AssetCountDetail key={id} id={id} onClose={closePanel} />
  ) : null
  const empty = (
    <div className="lf-card">
      <div className="lf-card__body">
        <p className="lf-hint">{t('assets.count.hint')}</p>
      </div>
    </div>
  )

  return (
    <>
      <PageHeader
        eyebrow={t('assets.page.eyebrow')}
        title={t('assets.count.title')}
        lede={t('assets.count.lede')}
        actions={
          canOrder ? (
            <Button variant="primary" size="md" onClick={() => setCreating(true)} data-testid="count-new">
              {t('assets.count.new')}
            </Button>
          ) : null
        }
      />
      {flagOff ? (
        <div className="lf-card" data-testid="count-flag-off">
          <div className="lf-card__body">
            <Banner tone="info">{t('assets.count.off')}</Banner>
          </div>
        </div>
      ) : (
        <ListDetail
          screen="assets.counts"
          listLabel={t('assets.count.listPane')}
          listDefault={40}
          listMin={380}
          tools={
            <Select
              label={t('assets.count.filter.status')}
              value={status}
              onChange={setStatus}
              options={COUNT_STATUSES.map((s) => ({ value: s, label: t(`assets.count.status.${s}`) }))}
              placeholder={t('assets.count.filter.all')}
            />
          }
          list={master}
          listFooter={listFooter}
          detail={
            // a dialog inside the record owns its Escape: mark the key handled so ListDetail does not close the record
            <div
              className="lf-card"
              onKeyDown={(e) => {
                if (e.key === 'Escape' && document.querySelector('[role="dialog"]') !== null) e.preventDefault()
              }}
            >
              {detail}
            </div>
          }
          empty={empty}
          detailOpen={panelOpen}
          onClose={closePanel}
        />
      )}
    </>
  )
}

export default function AssetCountsPage() {
  return (
    <AssetsIntlProvider>
      <CountsInner />
    </AssetsIntlProvider>
  )
}
