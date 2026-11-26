/** MaintenanceRequestsPage — GH 4802 / REQ-898. The list of the maintenance work requests and the record in the
 *  detail pane (skill rule 2a: one record is read in the panel of the list, never in a modal). The list shows the
 *  number, the equipment (inventory number and name), the urgency, the status and the time of the request; the
 *  status filter is a server-side filter. The primary action (Report a problem) sits in the page header. */
import { useEffect, useState } from 'react'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useLocation, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { Plus } from 'lucide-react'
import { useAccess } from '@/auth/access'
import { useAuth } from '@/auth/AuthContext'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { Dialog } from '@/components/ui/Dialog'
import { EmptyState } from '@/components/ui/EmptyState'
import { Field } from '@/components/ui/Field'
import { ListDetail } from '@/components/ui/listDetail'
import { PageHeader } from '@/components/ui/PageHeader'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Select } from '@/components/ui/Select'
import { classifyError } from '@/utils/classifyError'
import { StatusPill } from '@/components/ui/StatusPill'
import { MaintenanceIntlProvider } from './MaintenanceIntlProvider'
import { MaintenanceRequestDetail } from './MaintenanceRequestDetail'
import { maintenanceApi, REQUEST_STATUSES, type MaintenanceRequest } from './maintenance.api'
import { maintenanceQueryKeys } from './maintenanceQueryKeys'
import { MAINTENANCE_ORDER_MANAGE, MAINTENANCE_READ, MAINTENANCE_REQUEST_CREATE } from './maintenancePermissions'
import { errorMessageId, formatWhen, statusTone, urgencyTone } from './maintenanceModel'

const LIST_SCREEN = 'maintenance.requests'

function newKey(): string {
  return globalThis.crypto?.randomUUID?.() ?? `k-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

/** The screen inside the module's own IntlProvider (the labels come from the module's catalog). */
export default function MaintenanceRequestsPage() {
  return (
    <MaintenanceIntlProvider>
      <MaintenanceRequestsScreen />
    </MaintenanceIntlProvider>
  )
}

function MaintenanceRequestsScreen() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const { can } = useAccess()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const navigate = useNavigate()
  const location = useLocation()
  const params = useParams<{ id?: string }>()
  // The photos the form could not upload (REQ-898): the form hands them over with the navigation.
  const photoErrors = (location.state as { photoErrors?: { name: string; reason: string }[] } | null)?.photoErrors ?? []
  const [search, setSearch] = useSearchParams()
  const queryClient = useQueryClient()
  // The chosen request: the URL of the request page, else the row the user picked. The first row of the list is
  // chosen on first open (owner rule 2026-11-03) without changing the URL.
  const [picked, setPicked] = useState<string | null>(params.id ?? null)
  useEffect(() => {
    if (params.id != null) setPicked(params.id)
  }, [params.id])
  const selectedId = params.id ?? picked
  const status = search.get('status') ?? ''
  const [rejectOpen, setRejectOpen] = useState(false)
  const [rejectReason, setRejectReason] = useState('')
  const [rejectError, setRejectError] = useState<string | null>(null)
  const [rejectReasonError, setRejectReasonError] = useState<string | null>(null)
  const [orderOpen, setOrderOpen] = useState(false)

  const canRead = can(MAINTENANCE_READ)
  const canCreate = can(MAINTENANCE_REQUEST_CREATE)
  const canManage = can(MAINTENANCE_ORDER_MANAGE)

  const list = useInfiniteQuery({
    queryKey: maintenanceQueryKeys.list(tenantId, status),
    queryFn: ({ pageParam }) => maintenanceApi.list(status, pageParam as string | undefined),
    initialPageParam: '' as string,
    getNextPageParam: (last) => last.next_cursor ?? undefined,
    enabled: canRead,
    retry: false,
  })
  const rows: MaintenanceRequest[] = list.data?.pages.flatMap((p) => p.rows) ?? []

  const request = useQuery({
    queryKey: maintenanceQueryKeys.request(tenantId, selectedId ?? ''),
    queryFn: () => maintenanceApi.get(selectedId as string),
    enabled: canRead && selectedId != null,
    retry: false,
  })
  const photos = useQuery({
    queryKey: maintenanceQueryKeys.photos(tenantId, selectedId ?? ''),
    queryFn: () => maintenanceApi.listPhotos(selectedId as string),
    enabled: canRead && selectedId != null,
    retry: false,
  })

  const invalidate = async () => {
    await queryClient.invalidateQueries({ queryKey: maintenanceQueryKeys.all(tenantId) })
  }

  const reject = useMutation({
    mutationFn: (reason: string) => maintenanceApi.reject(selectedId as string, reason),
    onSuccess: async () => {
      setRejectOpen(false)
      setRejectReason('')
      setRejectError(null)
      await invalidate()
    },
    onError: (err) => setRejectError(t(errorMessageId(err))),
  })

  const makeOrder = useMutation({
    mutationFn: () => maintenanceApi.createOrder(selectedId as string, newKey()),
    onSuccess: async () => {
      setOrderOpen(false)
      await invalidate()
    },
  })

  const open = (id: string) => {
    setPicked(id)
    navigate({ pathname: `/admin/maintenance/requests/${id}`, search: search.toString() })
  }
  const close = () => {
    setPicked(null)
    navigate({ pathname: '/admin/maintenance/requests', search: search.toString() })
  }
  const setStatus = (value: string) => {
    const next = new URLSearchParams(search)
    if (value === '') next.delete('status')
    else next.set('status', value)
    setSearch(next, { replace: true })
  }

  const columns: DataTableColumn<MaintenanceRequest>[] = [
    {
      key: 'number',
      label: t('maintenance.requests.number'),
      mono: true,
      render: (r) => r.number ?? t('maintenance.common.dash'),
    },
    {
      key: 'asset',
      label: t('maintenance.requests.asset'),
      render: (r) => {
        const name = r.asset.name ?? ''
        const number = r.asset.inventory_number ?? ''
        return (
          <span data-testid={`request-row-asset-${r.id}`}>
            {number}
            {name !== '' ? ` · ${name}` : ''}
          </span>
        )
      },
    },
    {
      key: 'urgency',
      label: t('maintenance.requests.urgency'),
      render: (r) => (
        <StatusPill tone={urgencyTone(r.urgency)}>{t(`maintenance.urgency.${r.urgency}`)}</StatusPill>
      ),
    },
    {
      key: 'status',
      label: t('maintenance.requests.status'),
      render: (r) => (
        <StatusPill tone={statusTone(r.status)} data-testid={`request-row-status-${r.id}`}>
          {t(`maintenance.status.${r.status}`)}
        </StatusPill>
      ),
    },
    {
      key: 'created',
      label: t('maintenance.requests.created'),
      mono: true,
      render: (r) => formatWhen(r.created_at),
    },
  ]

  const listBody = (
    <DataTable
      columns={columns}
      data={rows}
      isLoading={list.isPending}
      emptyMessage={t('maintenance.requests.empty.title')}
      emptyText={t('maintenance.requests.empty.text')}
      emptyAction={
        canCreate ? (
          <Button
            variant="primary"
            size="md"
            icon={<Plus className="lf-icon" aria-hidden="true" />}
            onClick={() => navigate('/admin/maintenance/requests/new')}
            data-testid="request-empty-create"
          >
            {t('maintenance.requests.create')}
          </Button>
        ) : undefined
      }
      onRowClick={(r) => open(r.id)}
      selectedId={selectedId}
      getRowId={(r) => r.id}
      error={list.isError ? t('maintenance.common.loadError') : undefined}
      onRetry={() => void list.refetch()}
      labels={{ loading: t('maintenance.common.loading'), retry: t('maintenance.common.retry') }}
    />
  )

  const detail = request.data ? (
    <MaintenanceRequestDetail
      request={request.data}
      photos={photos.data?.photos ?? []}
      canManage={canManage}
      onReject={() => {
        setRejectError(null)
        setRejectReasonError(null)
        setRejectReason('')
        setRejectOpen(true)
      }}
      onMakeOrder={() => setOrderOpen(true)}
      onClose={close}
      error={reject.isError ? t(errorMessageId(reject.error)) : null}
    />
  ) : null

  return (
    <>
      <PageHeader
        eyebrow={t('maintenance.common.eyebrow')}
        title={t('maintenance.requests.title')}
        lede={t('maintenance.requests.lede')}
        actions={
          canCreate ? (
            <Button
              variant="primary"
              size="md"
              icon={<Plus className="lf-icon" aria-hidden="true" />}
              onClick={() => navigate('/admin/maintenance/requests/new')}
              data-testid="request-create"
            >
              {t('maintenance.requests.create')}
            </Button>
          ) : undefined
        }
      />
      <QueryStateBoundary
        state={list.isError ? classifyError(list.error) : 'success'}
        onRetry={() => void list.refetch()}
      >
        <ListDetail
          screen={LIST_SCREEN}
          listLabel={t('maintenance.requests.listPane')}
          listDefault={50}
          listMin={320}
          defaultSelectId={rows.length > 0 ? rows[0]!.id : null}
          onDefaultSelect={(id) => setPicked(id)}
          detailOpen={detail != null}
          onClose={close}
          list={listBody}
          listFooter={
            list.hasNextPage ? (
              <Button variant="secondary" size="sm" onClick={() => void list.fetchNextPage()} data-testid="request-load-more">
                {t('maintenance.common.loadMore')}
              </Button>
            ) : undefined
          }
          tools={
            <div className="lf-toolbar">
              <Select
                name="status"
                label={t('maintenance.requests.filter')}
                width="s"
                value={status}
                options={REQUEST_STATUSES.map((s) => ({ value: s, label: t(`maintenance.status.${s}`) }))}
                placeholder={t('maintenance.requests.filterAll')}
                onChange={setStatus}
              />
            </div>
          }
          detail={detail ?? <></>}
          empty={
            <div className="lf-card__body">
              <EmptyState
                data-testid="request-pick"
                title={t('maintenance.requests.pick.title')}
                text={t('maintenance.requests.pick.text')}
              />
            </div>
          }
        />
      </QueryStateBoundary>
      <Dialog
        open={rejectOpen}
        title={t('maintenance.requests.rejectTitle')}
        confirmText={t('maintenance.requests.reject')}
        cancelText={t('maintenance.common.cancel')}
        confirmVariant="danger"
        isLoading={reject.isPending}
        error={rejectError}
        onCancel={() => setRejectOpen(false)}
        onConfirm={() => {
          const reason = rejectReason.trim()
          if (reason === '') {
            setRejectReasonError(t('maintenance.requests.rejectReasonRequired'))
            return
          }
          setRejectReasonError(null)
          reject.mutate(reason)
        }}
        testId="reject-dialog"
      >
        <p>{t('maintenance.requests.rejectBody')}</p>
        <Field
          label={t('maintenance.requests.rejectReason')}
          error={rejectReasonError ?? undefined}
          data-testid="reject-reason-field"
        >
          <textarea
            name="reason"
            rows={3}
            value={rejectReason}
            onChange={(e) => setRejectReason(e.target.value)}
            data-testid="reject-reason"
          />
        </Field>
      </Dialog>
      {photoErrors.length > 0 && (
        <div data-testid="request-photo-errors">
          <Banner tone="warning">
            {photoErrors.map((p) => t('maintenance.photos.notUploaded', { name: p.name, reason: p.reason })).join(' ')}
          </Banner>
        </div>
      )}
      <Dialog
        open={orderOpen}
        title={t('maintenance.requests.makeOrderTitle')}
        confirmText={t('maintenance.requests.makeOrder')}
        cancelText={t('maintenance.common.cancel')}
        isLoading={makeOrder.isPending}
        error={makeOrder.isError ? t(errorMessageId(makeOrder.error)) : null}
        onCancel={() => setOrderOpen(false)}
        onConfirm={() => makeOrder.mutate()}
        testId="make-order-dialog"
      >
        <p>{t('maintenance.requests.makeOrderBody')}</p>
      </Dialog>
    </>
  )
}
