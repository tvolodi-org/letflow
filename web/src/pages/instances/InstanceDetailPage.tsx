import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { useParams } from 'react-router-dom'
import { ReactFlow, Background, Controls, MiniMap, type Node, type Edge } from '@xyflow/react'
import '@xyflow/react/dist/style.css'
import { useInstance, useCancelInstance, useInstanceTimeline } from '@/hooks/useInstances'
import { useTasks } from '@/hooks/useTasks'
import { useDefinition } from '@/hooks/useDefinitions'
import { P, useAccess } from '@/auth/access'
import { usePolling } from '@/hooks/usePolling'
import { useHistoryScrubber } from '@/hooks/useHistoryScrubber'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { graphToFlow, type CanvasNodeData, type CanvasEdgeData } from '@/utils/canvas/graphToFlow'
import { mergeTimelineItems } from './timelineUtils'
import type { TimelineEntry } from '@/types/api'
import { EventHistoryPanel } from '@/components/instances/EventHistoryPanel'
import { AttachmentPanel } from '@/components/instances/AttachmentPanel'
import { InstancePinsPanel } from '@/components/instances/InstancePinsPanel'
import { TimelineFeed } from '@/components/instances/TimelineFeed'
import { HistoryScrubber } from '@/components/instances/HistoryScrubber'
import { ProcessGraphWithTokens } from '@/components/instances/ProcessGraphWithTokens'
import { CancelInstanceDialog } from '@/components/instances/CancelInstanceDialog'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { Button } from '@/components/ui/Button'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { useToast } from '@/hooks/useToast'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { formatDateTime as formatLocaleDateTime, formatTime as formatLocaleTime } from '@/i18n/format'


interface DetailRow {
  key: string
  value: ReactNode
}

interface PendingTaskRow {
  key: string
  taskId: string
  nodeId: string
  nodeName: string
  assignee: string
  createdAt: string | undefined
}

function formatDateTime(value: string | undefined): string {
  if (!value) return '—'
  return formatLocaleDateTime(value)
}

function toRefreshLabel(value: string | null): string {
  if (!value) return 'Not yet refreshed'
  return formatLocaleTime(value)
}

function useReadonlyGraph(
  definitionGraph: unknown,
  activeNodeIds: string[],
): { nodes: Node<CanvasNodeData>[]; edges: Edge<CanvasEdgeData>[] } {
  return useMemo(() => {
    if (!definitionGraph || typeof definitionGraph !== 'object') {
      return { nodes: [], edges: [] }
    }

    const asGraph = definitionGraph as { nodes?: unknown[]; edges?: unknown[] }
    if (!Array.isArray(asGraph.nodes) || !Array.isArray(asGraph.edges)) {
      return { nodes: [], edges: [] }
    }

    try {
      const { nodes, edges } = graphToFlow(definitionGraph as never)
      const highlighted = new Set(activeNodeIds)

      return {
        nodes: nodes.map((node) => {
          const isActive = highlighted.has(node.id)
          return {
            ...node,
            style: {
              ...(node.style ?? {}),
              border: isActive ? '2px solid var(--interactive-primary)' : '1px solid var(--border-default)',
              boxShadow: isActive ? 'var(--shadow-focus-blue)' : undefined,
            },
          }
        }),
        edges,
      }
    } catch {
      return { nodes: [], edges: [] }
    }
  }, [definitionGraph, activeNodeIds])
}

export default function InstanceDetailPage() {
  const { id } = useParams<{ id: string }>()
  const tenantKeys = useTenantScopedQueryKeys()

  const { data: instance, isLoading, isError, error, refetch } = useInstance(id!)
  const { data: definition } = useDefinition(instance?.definition_id ?? '')
  const { data: pendingTasks } = useTasks({ status: 'PENDING', instance_id: id })
  const cancel = useCancelInstance()

  const detailQueryKey = id ? tenantKeys.instances.detail(id) : tenantKeys.instances.all()
  const polling = usePolling({ queryKeyPrefix: detailQueryKey, enabled: !!id })

  const [activeTab, setActiveTab] = useState<'graph' | 'history' | 'timeline'>('history')
  const [timelineCursor, setTimelineCursor] = useState<string | undefined>(undefined)
  const [timelineItems, setTimelineItems] = useState<TimelineEntry[]>([])
  const [timelineRequested, setTimelineRequested] = useState(false)
  const [lastAppliedCursor, setLastAppliedCursor] = useState<string | null>(null)
  const [showCancelDialog, setShowCancelDialog] = useState(false)
  const [scrubbedSeqNum, setScrubbedSeqNum] = useState<number | undefined>(undefined)
  const toast = useToast()

  const scrubber = useHistoryScrubber(id!, scrubbedSeqNum)

  const timelineQuery = useInstanceTimeline(
    id!,
    { cursor: timelineCursor, page_size: 50 },
    timelineRequested,
  )

  const currentNodes = Array.isArray(instance?.current_nodes) ? instance.current_nodes : []
  const instanceVariables = instance?.variables && typeof instance.variables === 'object' ? instance.variables : {}
  const instanceGraph = instance?.definition_snapshot ?? definition?.graph
  const readonlyGraph = useReadonlyGraph(instanceGraph, currentNodes)
  const canCancel = useAccess().can(P.InstancesCancel)

  useEffect(() => {
    if (activeTab === 'timeline' && !timelineRequested) {
      setTimelineRequested(true)
      setTimelineCursor(undefined)
      setLastAppliedCursor(null)
      setTimelineItems([])
    }
  }, [activeTab, timelineRequested])

  useEffect(() => {
    if (!timelineQuery.data) return

    const cursorKey = timelineCursor ?? ''
    if (lastAppliedCursor === cursorKey) return

    setTimelineItems((current) =>
      mergeTimelineItems(current, timelineQuery.data.items, timelineCursor),
    )
    setLastAppliedCursor(cursorKey)
  }, [timelineCursor, timelineQuery.data, lastAppliedCursor])

  const onTimelineLoadMore = () => {
    if (!timelineQuery.data?.next_cursor) return
    setTimelineCursor(timelineQuery.data.next_cursor)
  }

  const onCancelConfirm = (reason?: string) => {
    if (!instance) return
    cancel.mutate(
      { id: instance.instance_id, reason },
      {
        onError: () => {
          toast.error('Failed to cancel instance. The status has been restored.')
        },
      },
    )
    setShowCancelDialog(false)
  }

  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  const detailColumns: DataTableColumn<DetailRow>[] = [
    { id: 'field', header: 'Field', accessor: (row) => row.key },
    { id: 'value', header: 'Value', accessor: (row) => row.value },
  ]

  const detailRows: DetailRow[] = instance
    ? [
        // `instance` has no definition_name/definition_version fields (the
        // backend's GET /api/v1/instances/:id response only carries
        // definition_id) — use the definition fetched separately above via
        // useDefinition(instance?.definition_id) instead. Render a neutral
        // placeholder while that fetch is still in flight rather than the
        // literal string "undefined".
        { key: 'Definition', value: definition ? `${definition.name} v${definition.version}` : '—' },
        {
          key: 'Status',
          value: <StatusBadge status={instance.status} domain="instance" size="sm" />,
        },
        { key: 'Active nodes', value: currentNodes.join(', ') || '—' },
        { key: 'Correlation key', value: instance.correlation_key ?? '—' },
        { key: 'Started at', value: formatDateTime(instance.started_at) },
        { key: 'Last updated', value: formatDateTime(instance.updated_at ?? instance.started_at) },
        { key: 'Completed at', value: formatDateTime(instance.completed_at) },
      ]
    : []

  const pendingTaskColumns: DataTableColumn<PendingTaskRow>[] = [
    { id: 'taskId', header: 'Task ID', accessor: (row) => (row.taskId ? `${row.taskId.slice(0, 8)}...` : '—') },
    { id: 'nodeId', header: 'Node', accessor: (row) => row.nodeId },
    { id: 'nodeName', header: 'Name', accessor: (row) => row.nodeName },
    { id: 'assignee', header: 'Assignee', accessor: (row) => row.assignee },
    {
      id: 'createdAt',
      header: 'Created',
      accessor: (row) => <span style={{ color: 'var(--text-secondary)' }}>{formatDateTime(row.createdAt)}</span>,
    },
  ]

  const pendingTaskRows: PendingTaskRow[] = (pendingTasks?.items ?? []).map((task, index) => {
    const taskId = typeof task.id === 'string'
      ? task.id
      : (typeof (task as unknown as { task_id?: unknown }).task_id === 'string'
        ? (task as unknown as { task_id: string }).task_id
        : '')
    return {
      key: taskId || `task-${index}`,
      taskId,
      nodeId: typeof task.node_id === 'string' ? task.node_id : '—',
      nodeName: typeof task.node_name === 'string' ? task.node_name : '—',
      assignee: typeof task.assignee_ref === 'string' ? task.assignee_ref : '—',
      createdAt: task.created_at,
    }
  })

  return (
    <div style={{ padding: '1.5rem', maxWidth: '900px' }}>
      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={
          rendererState === 'rate-limit' ? getRetryAfterSeconds(error) : undefined
        }
        columns={[{ widthPercent: 20 }, { widthPercent: 20 }, { widthPercent: 15 }, { widthPercent: 15 }, { widthPercent: 15 }, { widthPercent: 15 }]}
      >
      {instance && (<>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '1rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Instance</h2>
        <code style={{ fontSize: 'var(--text-sm)', color: 'var(--text-secondary)' }}>{instance.instance_id}</code>
        {instance.status === 'ACTIVE' && canCancel && (
          <span style={{ marginLeft: 'auto' }}>
            <Button
              variant="danger"
              size="sm"
              onClick={() => setShowCancelDialog(true)}
              disabled={cancel.isPending}
            >
              Cancel
            </Button>
          </span>
        )}
      </div>

      <div style={{ display: 'flex', justifyContent: 'flex-end', alignItems: 'center', gap: '.6rem', marginBottom: '.8rem' }}>
        <span style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>
          Last refreshed: {toRefreshLabel(polling.lastRefreshedAt)}
        </span>
        <Button
          variant="secondary"
          size="sm"
          onClick={() => void polling.refreshNow()}
          disabled={timelineQuery.isRefetching || cancel.isPending}
        >
          {timelineQuery.isRefetching ? 'Refreshing...' : 'Refresh'}
        </Button>
      </div>

      <DataTable columns={detailColumns} data={detailRows} emptyMessage="No instance details available." />

      <section style={{ marginTop: '1rem', marginBottom: '1rem' }}>
        <h3 style={{ marginBottom: '.5rem' }}>Definition Snapshot</h3>
        <div style={{ display: 'grid', gap: '.35rem', color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>
          <div>Definition ID: <code>{instance.definition_id}</code></div>
          <div>Source: {instance.definition_snapshot ? 'Stored snapshot' : 'Current definition version'}</div>
          <div>Active tokens: {currentNodes.join(', ') || '—'}</div>
        </div>

        <div style={{ marginTop: '.75rem', height: '320px', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', overflow: 'hidden' }}>
          {readonlyGraph.nodes.length === 0 ? (
            <div style={{ padding: '1rem', color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>
              No graph snapshot is available for this instance.
            </div>
          ) : (
            <ReactFlow
              data-testid="instance-readonly-graph"
              nodes={readonlyGraph.nodes}
              edges={readonlyGraph.edges}
              nodesDraggable={false}
              nodesConnectable={false}
              elementsSelectable={false}
              fitView
              proOptions={{ hideAttribution: true }}
            >
              <Background color="var(--border-default)" gap={20} />
              <MiniMap />
              <Controls />
            </ReactFlow>
          )}
        </div>
      </section>

      <h3 style={{ marginBottom: '.75rem' }}>Variables</h3>
      <pre style={{ background: 'var(--color-neutral-100)', padding: '1rem', borderRadius: 'var(--radius-sm)', fontSize: 'var(--text-xs)', overflow: 'auto', marginBottom: '1.5rem' }}>
        {JSON.stringify(instanceVariables, null, 2)}
      </pre>

      <section style={{ marginBottom: '1.25rem' }}>
        <h3 style={{ marginBottom: '.5rem' }}>Active Tasks</h3>
        <DataTable columns={pendingTaskColumns} data={pendingTaskRows} emptyMessage="No active tasks." />
      </section>

      <section style={{ marginBottom: '1.25rem' }}>
        <h3 style={{ marginBottom: '.5rem' }}>Attachments</h3>
        <AttachmentPanel instanceId={id!} />
      </section>

      <section style={{ marginBottom: '1.25rem' }}>
        <h3 style={{ marginBottom: '.5rem' }}>Dependency Versions</h3>
        <InstancePinsPanel instanceId={id!} />
      </section>

      <div style={{ display: 'flex', gap: '.5rem', borderBottom: '1px solid var(--border-default)', marginBottom: '1rem' }}>
        <Button variant="ghost" size="sm" pressed={activeTab === 'graph'} onClick={() => setActiveTab('graph')}>
          Graph
        </Button>
        <Button variant="ghost" size="sm" pressed={activeTab === 'history'} onClick={() => setActiveTab('history')}>
          History
        </Button>
        <Button variant="ghost" size="sm" pressed={activeTab === 'timeline'} onClick={() => setActiveTab('timeline')}>
          Timeline
        </Button>
      </div>

      {activeTab === 'graph' && (
        <>
          <h3 style={{ marginBottom: '.75rem' }}>Process Graph with Tokens</h3>
          <ProcessGraphWithTokens instanceId={id!} />
        </>
      )}

      {activeTab === 'history' && (
        <>
          <h3 style={{ marginBottom: '.75rem' }}>Event history</h3>
          <EventHistoryPanel instanceId={id!} />
        </>
      )}

      {activeTab === 'timeline' && (
        <>
          <h3 style={{ marginBottom: '.75rem' }}>Timeline</h3>
          {scrubber.error && (
            <p style={{ color: 'var(--color-error)', marginBottom: '.75rem' }}>Failed to load timeline scrubber.</p>
          )}
          <HistoryScrubber
            instanceId={id!}
            totalEvents={scrubber.totalEvents}
            currentPosition={scrubber.currentSeqNum}
            onPositionChange={setScrubbedSeqNum}
            isLoading={scrubber.isLoading}
            isLiveMode={scrubber.isLiveMode}
            onResumeLive={scrubber.resumeLive}
          />
          {timelineQuery.error && timelineItems.length === 0 && (
            <p style={{ color: 'var(--color-error)' }}>Failed to load timeline.</p>
          )}
          <TimelineFeed
            items={timelineItems}
            isLoading={timelineQuery.isLoading}
            hasMore={Boolean(timelineQuery.data?.next_cursor)}
            onLoadMore={onTimelineLoadMore}
            isFetchingMore={timelineQuery.isFetching}
          />
        </>
      )}

      <CancelInstanceDialog
        open={showCancelDialog}
        instanceId={instance.instance_id}
        instanceName={definition ? `${definition.name} v${definition.version}` : '—'}
        onConfirm={onCancelConfirm}
        onCancel={() => setShowCancelDialog(false)}
        isPending={cancel.isPending}
      />
      </>)}
      </QueryStateBoundary>
    </div>
  )
}
