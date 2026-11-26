/** MaintenanceOrdersPage — GH 4801 / REQ-899. The list of the work orders and the record in the detail pane
 *  (skill rule 2a). Columns: number, equipment, status, assignee, urgency, created; the status and the equipment
 *  are server-side filters. The primary action (New work order) sits in the page header for a holder of
 *  MaintenanceOrderManage. Assign opens a short dialog with the user picker. */
import { useEffect, useState } from 'react'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { Plus } from 'lucide-react'
import { useAccess } from '@/auth/access'
import { useAuth } from '@/auth/AuthContext'
import { useToast } from '@/hooks/useToast'
import { ACTIVE_TRUE, DELETED_FALSE, fetchCardsPage } from '@/modules/assets/assets.api'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { Dialog } from '@/components/ui/Dialog'
import { EmptyState } from '@/components/ui/EmptyState'
import { ListDetail } from '@/components/ui/listDetail'
import { PageHeader } from '@/components/ui/PageHeader'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import { classifyError } from '@/utils/classifyError'
import { MaintenanceAssigneeSelect, useAssignees, userLabel } from './MaintenanceAssigneeSelect'
import { MaintenanceIntlProvider } from './MaintenanceIntlProvider'
import { MaintenanceOrderDetail } from './MaintenanceOrderDetail'
import { maintenanceApi, ORDER_STATUSES, type MaintenanceOrder } from './maintenance.api'
import { maintenanceQueryKeys } from './maintenanceQueryKeys'
import { MAINTENANCE_ORDER_MANAGE, MAINTENANCE_READ } from './maintenancePermissions'
import { errorMessageId, formatWhen, orderStatusMessageId, orderStatusTone, urgencyTone } from './maintenanceModel'

const LIST_SCREEN = 'maintenance.orders'

/** The screen inside the module's own IntlProvider (the labels come from the module's catalog). */
export default function MaintenanceOrdersPage() {
  return (
    <MaintenanceIntlProvider>
      <MaintenanceOrdersScreen />
    </MaintenanceIntlProvider>
  )
}

function MaintenanceOrdersScreen() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const navigate = useNavigate()
  const params = useParams<{ id?: string }>()
  const [search, setSearch] = useSearchParams()
  const queryClient = useQueryClient()
  const toast = useToast()
  const [picked, setPicked] = useState<string | null>(params.id ?? null)
  useEffect(() => {
    if (params.id != null) setPicked(params.id)
  }, [params.id])
  const selectedId = params.id ?? picked
  const status = search.get('status') ?? ''
  const card = search.get('card') ?? ''
  const [assignOpen, setAssignOpen] = useState(false)
  const [assignee, setAssignee] = useState('')
  const [assigneeError, setAssigneeError] = useState<string | null>(null)

  const canRead = can(MAINTENANCE_READ)
  const canManage = can(MAINTENANCE_ORDER_MANAGE)
  const assignees = useAssignees()
  const nameOf = (id: string | null) => {
    if (id == null) return null
    const u = assignees.users.find((x) => x.id === id)
    return u ? userLabel(u) : null
  }

  const list = useInfiniteQuery({
    queryKey: maintenanceQueryKeys.orders(tenantId, status, card),
    queryFn: ({ pageParam }) =>
      maintenanceApi.listOrders({ status, assetCardId: card }, pageParam === '' ? undefined : (pageParam as string)),
    initialPageParam: '' as string,
    getNextPageParam: (last) => last.next_cursor ?? undefined,
    enabled: canRead,
    retry: false,
  })
  const rows: MaintenanceOrder[] = list.data?.pages.flatMap((p) => p.rows) ?? []

  const cards = useQuery({
    queryKey: maintenanceQueryKeys.list(tenantId, 'cards|orders-filter'),
    queryFn: async () => (await fetchCardsPage('assets_card', [DELETED_FALSE, ACTIVE_TRUE], undefined, 200)).items,
    enabled: canRead,
    retry: false,
  })

  const order = useQuery({
    queryKey: maintenanceQueryKeys.order(tenantId, selectedId ?? ''),
    queryFn: () => maintenanceApi.getOrder(selectedId as string),
    enabled: canRead && selectedId != null,
    retry: false,
  })

  const assign = useMutation({
    mutationFn: (userId: string) => maintenanceApi.assignOrder(selectedId as string, userId),
    onSuccess: async (after, userId) => {
      setAssignOpen(false)
      setAssignee('')
      await queryClient.invalidateQueries({ queryKey: maintenanceQueryKeys.all(tenantId) })
      toast.success(
        t('maintenance.orders.assigned', {
          number: after.number ?? after.id,
          name: nameOf(userId) ?? t('maintenance.orders.userUnknown'),
        }),
      )
    },
  })

  const open = (id: string) => {
    setPicked(id)
    navigate({ pathname: `/admin/maintenance/orders/${id}`, search: search.toString() })
  }
  const close = () => {
    setPicked(null)
    navigate({ pathname: '/admin/maintenance/orders', search: search.toString() })
  }
  const setFilter = (key: 'status' | 'card', value: string) => {
    const next = new URLSearchParams(search)
    if (value === '') next.delete(key)
    else next.set(key, value)
    setSearch(next, { replace: true })
  }

  const columns: DataTableColumn<MaintenanceOrder>[] = [
    { key: 'number', label: t('maintenance.orders.number'), mono: true, render: (r) => r.number ?? t('maintenance.common.dash') },
    {
      key: 'asset',
      label: t('maintenance.orders.asset'),
      render: (r) => (
        <span data-testid={`order-row-asset-${r.id}`}>
          {r.asset.inventory_number ?? ''}
          {r.asset.name != null && r.asset.name !== '' ? ` · ${r.asset.name}` : ''}
        </span>
      ),
    },
    {
      key: 'status',
      label: t('maintenance.orders.status'),
      render: (r) => (
        <StatusPill tone={orderStatusTone(r.status)} data-testid={`order-row-status-${r.id}`}>
          {t(orderStatusMessageId(r.status))}
        </StatusPill>
      ),
    },
    {
      key: 'assignee',
      label: t('maintenance.orders.assignee'),
      render: (r) =>
        r.assignee_user_id == null
          ? t('maintenance.orders.unassigned')
          : (nameOf(r.assignee_user_id) ?? t('maintenance.orders.userUnknown')),
    },
    {
      key: 'urgency',
      label: t('maintenance.orders.urgency'),
      render: (r) => <StatusPill tone={urgencyTone(r.urgency)}>{t(`maintenance.urgency.${r.urgency}`)}</StatusPill>,
    },
    { key: 'created', label: t('maintenance.orders.created'), mono: true, render: (r) => formatWhen(r.created_at) },
  ]

  const newOrderButton = canManage ? (
    <Button
      variant="primary"
      size="md"
      icon={<Plus className="lf-icon" aria-hidden="true" />}
      onClick={() => navigate('/admin/maintenance/orders/new')}
      data-testid="order-create"
    >
      {t('maintenance.orders.create')}
    </Button>
  ) : undefined

  const listBody = (
    <DataTable
      columns={columns}
      data={rows}
      isLoading={list.isPending}
      emptyMessage={t('maintenance.orders.empty.title')}
      emptyText={t('maintenance.orders.empty.text')}
      emptyAction={newOrderButton}
      onRowClick={(r) => open(r.id)}
      selectedId={selectedId}
      getRowId={(r) => r.id}
      error={list.isError ? t('maintenance.orders.loadError') : undefined}
      onRetry={() => void list.refetch()}
      labels={{ loading: t('maintenance.common.loading'), retry: t('maintenance.common.retry') }}
    />
  )

  const detail = order.data ? (
    <MaintenanceOrderDetail
      order={order.data}
      nameOf={nameOf}
      canManage={canManage}
      onAssign={() => {
        assign.reset()
        setAssigneeError(null)
        setAssignee(order.data?.assignee_user_id ?? '')
        setAssignOpen(true)
      }}
      onClose={close}
    />
  ) : null

  return (
    <>
      <PageHeader
        eyebrow={t('maintenance.common.eyebrow')}
        title={t('maintenance.orders.title')}
        lede={t('maintenance.orders.lede')}
        actions={newOrderButton}
      />
      <QueryStateBoundary state={list.isError ? classifyError(list.error) : 'success'} onRetry={() => void list.refetch()}>
        <ListDetail
          screen={LIST_SCREEN}
          listLabel={t('maintenance.orders.listPane')}
          listDefault={55}
          listMin={360}
          defaultSelectId={rows.length > 0 ? rows[0]!.id : null}
          onDefaultSelect={(id) => setPicked(id)}
          detailOpen={detail != null}
          onClose={close}
          list={listBody}
          listFooter={
            list.hasNextPage ? (
              <Button variant="secondary" size="sm" onClick={() => void list.fetchNextPage()} data-testid="order-load-more">
                {t('maintenance.common.loadMore')}
              </Button>
            ) : undefined
          }
          tools={
            <div className="lf-toolbar">
              <Select
                name="status"
                label={t('maintenance.orders.filter')}
                width="s"
                value={status}
                options={ORDER_STATUSES.map((s) => ({ value: s, label: t(`maintenance.orders.status.${s}`) }))}
                placeholder={t('maintenance.orders.filterAll')}
                onChange={(v) => setFilter('status', v)}
              />
              <Select
                name="card"
                label={t('maintenance.orders.filterCard')}
                width="m"
                value={card}
                options={(cards.data ?? []).map((c) => {
                  const number = String(c.field_values['inventory_number'] ?? '')
                  const name = String(c.field_values['name'] ?? '')
                  return { value: c.record_id, label: name === '' ? number : `${number} · ${name}` }
                })}
                placeholder={t('maintenance.orders.filterAll')}
                onChange={(v) => setFilter('card', v)}
              />
            </div>
          }
          detail={detail ?? <></>}
          empty={
            <div className="lf-card__body">
              <EmptyState
                data-testid="order-pick"
                title={t('maintenance.orders.pick.title')}
                text={t('maintenance.orders.pick.text')}
              />
            </div>
          }
        />
      </QueryStateBoundary>
      <Dialog
        open={assignOpen}
        title={t('maintenance.orders.assignTitle')}
        confirmText={t('maintenance.orders.assign')}
        cancelText={t('maintenance.common.cancel')}
        isLoading={assign.isPending}
        error={assign.isError ? t(errorMessageId(assign.error)) : null}
        onCancel={() => setAssignOpen(false)}
        onConfirm={() => {
          if (assignee === '') {
            setAssigneeError(t('maintenance.orders.assignRequired'))
            return
          }
          setAssigneeError(null)
          assign.mutate(assignee)
        }}
        testId="assign-dialog"
      >
        <p>{t('maintenance.orders.assignBody')}</p>
        <MaintenanceAssigneeSelect
          value={assignee}
          onChange={setAssignee}
          users={assignees.users}
          isError={assignees.isError}
          error={assigneeError ?? undefined}
        />
      </Dialog>
    </>
  )
}
