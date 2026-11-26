/** MyMaintenanceOrdersPage — GH 4801 / REQ-899. "My maintenance orders": the work orders given to the signed-in
 *  person, built on the task inbox, not on a maintenance route (so it needs no maintenance permission, only
 *  TasksRead, and sends no request to /api/v1/modules/maintenance). It reads the caller's GET /tasks/inbox page by
 *  page (200 a page, at most 5 pages; when more exist the screen says the list is cut), keeps the pending tasks of
 *  the node maintenance_work, reads each task's instance for the order facts and lists urgent first, then oldest
 *  first. A row opens the existing task screen (/tasks?task=<id>) where the technician enters work_done and
 *  completes the task; the row then leaves the list. A failed instance read keeps the row with a note. */
import { useQuery } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useNavigate } from 'react-router-dom'
import { instancesApi } from '@/api/instances'
import { tasksApi } from '@/api/tasks'
import { useAuth } from '@/auth/AuthContext'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { PageHeader } from '@/components/ui/PageHeader'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { StatusPill } from '@/components/ui/StatusPill'
import { classifyError } from '@/utils/classifyError'
import type { Task } from '@/types/api'
import { MaintenanceIntlProvider } from './MaintenanceIntlProvider'
import { maintenanceQueryKeys } from './maintenanceQueryKeys'
import {
  INBOX_MAX_PAGES,
  INBOX_PAGE_SIZE,
  WORK_NODE_ID,
  formatWhen,
  orderFactsOf,
  sortMyOrders,
  urgencyTone,
  type MyOrderRow,
} from './maintenanceModel'

interface MyOrders {
  rows: MyOrderRow[]
  cut: boolean
}

/** Reads the inbox page by page, keeps the pending maintenance_work tasks and reads their instances. */
async function loadMyOrders(): Promise<MyOrders> {
  const tasks: Task[] = []
  let cursor: string | undefined
  let cut = false
  for (let page = 1; page <= INBOX_MAX_PAGES; page += 1) {
    const result = await tasksApi.inbox({ cursor, page_size: INBOX_PAGE_SIZE })
    tasks.push(...result.items)
    cursor = result.next_cursor ?? undefined
    if (cursor === undefined) break
    if (page === INBOX_MAX_PAGES) cut = true
  }
  const mine = tasks.filter((t) => t.node_id === WORK_NODE_ID && String(t.status).toUpperCase() === 'PENDING')
  const rows = await Promise.all(
    mine.map(async (task): Promise<MyOrderRow> => {
      const base = { taskId: task.id, taskName: task.node_name, createdAt: task.created_at }
      try {
        const instance = await instancesApi.get(task.instance_id)
        return { ...base, ...orderFactsOf(instance.variables), instanceFailed: false }
      } catch {
        return {
          ...base,
          number: null,
          inventoryNumber: null,
          assetName: null,
          urgency: null,
          description: null,
          instanceFailed: true,
        }
      }
    }),
  )
  return { rows: sortMyOrders(rows), cut }
}

/** The screen inside the module's own IntlProvider (the labels come from the module's catalog). */
export default function MyMaintenanceOrdersPage() {
  return (
    <MaintenanceIntlProvider>
      <MyMaintenanceOrdersScreen />
    </MaintenanceIntlProvider>
  )
}

function MyMaintenanceOrdersScreen() {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const navigate = useNavigate()

  const mine = useQuery({
    queryKey: maintenanceQueryKeys.myOrders(tenantId),
    queryFn: loadMyOrders,
    retry: false,
  })
  const rows = mine.data?.rows ?? []
  const dash = t('maintenance.common.dash')
  const open = (row: MyOrderRow) => navigate(`/tasks?task=${encodeURIComponent(row.taskId)}`)

  const columns: DataTableColumn<MyOrderRow>[] = [
    { key: 'number', label: t('maintenance.my.number'), mono: true, render: (r) => r.number ?? dash },
    {
      key: 'asset',
      label: t('maintenance.my.asset'),
      render: (r) =>
        r.instanceFailed ? (
          <span data-testid={`my-row-note-${r.taskId}`}>
            {r.taskName} — {t('maintenance.my.instanceFailed')}
          </span>
        ) : (
          <span data-testid={`my-row-asset-${r.taskId}`}>
            {r.inventoryNumber ?? dash}
            {r.assetName != null ? ` · ${r.assetName}` : ''}
          </span>
        ),
    },
    {
      key: 'urgency',
      label: t('maintenance.my.urgency'),
      render: (r) =>
        r.urgency == null ? (
          dash
        ) : (
          <StatusPill tone={urgencyTone(r.urgency)}>
            {['low', 'normal', 'urgent'].includes(r.urgency) ? t(`maintenance.urgency.${r.urgency}`) : r.urgency}
          </StatusPill>
        ),
    },
    { key: 'description', label: t('maintenance.my.description'), render: (r) => r.description ?? dash },
    { key: 'created', label: t('maintenance.my.created'), mono: true, render: (r) => formatWhen(r.createdAt) },
    {
      key: 'open',
      label: t('maintenance.my.task'),
      hideStackLabel: true,
      render: (r) => (
        <Button variant="secondary" size="sm" onClick={() => open(r)} data-testid={`my-open-${r.taskId}`}>
          {t('maintenance.my.open')}
        </Button>
      ),
    },
  ]

  return (
    <>
      <PageHeader
        eyebrow={t('maintenance.common.eyebrow')}
        title={t('maintenance.my.title')}
        lede={t('maintenance.my.lede')}
      />
      <QueryStateBoundary state={mine.isError ? classifyError(mine.error) : 'success'} onRetry={() => void mine.refetch()}>
        {mine.data?.cut === true && (
          <div data-testid="my-cut-note">
            <Banner tone="warning">{t('maintenance.my.cut', { count: INBOX_MAX_PAGES * INBOX_PAGE_SIZE })}</Banner>
          </div>
        )}
        <DataTable
          columns={columns}
          data={rows}
          isLoading={mine.isPending}
          emptyMessage={t('maintenance.my.empty.title')}
          emptyText={t('maintenance.my.empty.text')}
          onRowClick={open}
          getRowId={(r) => r.taskId}
          error={mine.isError ? t('maintenance.my.loadError') : undefined}
          onRetry={() => void mine.refetch()}
          labels={{ loading: t('maintenance.common.loading'), retry: t('maintenance.common.retry') }}
        />
      </QueryStateBoundary>
    </>
  )
}
