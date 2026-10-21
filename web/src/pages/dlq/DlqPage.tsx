import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { dlqApi } from '@/api/dlq'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { P, useAccess } from '@/auth/access'
import type { DlqEntry } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { formatDateTime } from '@/i18n/format'
import { PageLayout } from '@/components/ui/PageLayout'
import { FilterBar } from '@/components/ui/FilterBar'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { PaginationControls } from '@/components/ui/PaginationControls'
import { JsonEditor } from '@/components/ui/JsonEditor'


function parseJsonLike(value: unknown): unknown {
  if (typeof value !== 'string') return value
  try {
    return JSON.parse(value) as unknown
  } catch {
    return value
  }
}

function asObject(value: unknown): Record<string, unknown> {
  const parsed = parseJsonLike(value)
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {}
  return parsed as Record<string, unknown>
}

function asArray(value: unknown): unknown[] {
  const parsed = parseJsonLike(value)
  return Array.isArray(parsed) ? parsed : []
}

function normalizeStatus(entry: DlqEntry, transientStatus?: string): string {
  if (transientStatus) return transientStatus
  if (entry.status) return entry.status

  const metadata = asObject(entry.processor_metadata)
  const rawStatus = metadata.status
  if (typeof rawStatus === 'string') return rawStatus.toLowerCase()

  if (entry.retry_count > 0 && entry.retry_limit && entry.retry_count < entry.retry_limit) {
    return 'retrying'
  }
  return 'pending'
}

function extractFailureReason(entry: DlqEntry): string {
  if (entry.full_reason && entry.full_reason.trim().length > 0) return entry.full_reason
  if (entry.reason && entry.reason.trim().length > 0) return entry.reason

  const chain = asArray(entry.error_chain)
  for (let idx = chain.length - 1; idx >= 0; idx -= 1) {
    const part = chain[idx]
    if (!part || typeof part !== 'object' || Array.isArray(part)) continue
    const candidate = (part as Record<string, unknown>).message
    if (typeof candidate === 'string' && candidate.trim().length > 0) return candidate
  }

  return 'No failure reason provided.'
}

function extractRetryHistory(entry: DlqEntry): Array<{ attemptNo: number; attemptedAt: string; outcome: string; errorMessage?: string }> {
  if (Array.isArray(entry.retry_history) && entry.retry_history.length > 0) {
    return entry.retry_history.map((attempt) => ({
      attemptNo: attempt.attempt_no,
      attemptedAt: attempt.attempted_at,
      outcome: attempt.outcome,
      errorMessage: attempt.error_message,
    }))
  }

  const metadata = asObject(entry.processor_metadata)
  const metadataHistory = asArray(metadata.retry_history)
  if (metadataHistory.length > 0) {
    return metadataHistory.map((item, index) => {
      const row = asObject(item)
      return {
        attemptNo: typeof row.attempt_no === 'number' ? row.attempt_no : index + 1,
        attemptedAt: typeof row.attempted_at === 'string' ? row.attempted_at : (entry.last_failed_at ?? entry.created_at),
        outcome: typeof row.outcome === 'string' ? row.outcome : 'failed',
        errorMessage: typeof row.error_message === 'string' ? row.error_message : undefined,
      }
    })
  }

  return asArray(entry.error_chain).map((item, index) => {
    const row = asObject(item)
    return {
      attemptNo: index + 1,
      attemptedAt: typeof row.timestamp === 'string' ? row.timestamp : (entry.last_failed_at ?? entry.created_at),
      outcome: 'failed',
      errorMessage: typeof row.message === 'string' ? row.message : undefined,
    }
  })
}

function toPrettyJson(value: unknown): string {
  const parsed = parseJsonLike(value)
  return JSON.stringify(parsed ?? {}, null, 2)
}

function toShortDate(value: string | undefined): string {
  if (!value) return '—'
  return formatDateTime(value)
}

function toRowTestId(id: string): string {
  return id.replace(/[^a-zA-Z0-9_-]/g, '-')
}

interface RetryAttempt {
  attemptNo: number
  attemptedAt: string
  outcome: string
  errorMessage?: string
}

export default function DlqPage() {
  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState('')
  const [sourceTypeFilter, setSourceTypeFilter] = useState('')
  const [cursorStack, setCursorStack] = useState<string[]>([])
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [transientStatusById, setTransientStatusById] = useState<Record<string, string>>({})
  const [discardConfirmItem, setDiscardConfirmItem] = useState<DlqEntry | null>(null)

  const canOperate = useAccess().can(P.DlqOperate)
  const cursor = cursorStack.length > 0 ? cursorStack[cursorStack.length - 1] : undefined

  const { data, isLoading, isError, error, refetch } = useQuery({
    queryKey: tenantKeys.dlq.list({ search, status: statusFilter, source_type: sourceTypeFilter, cursor }),
    queryFn: () => dlqApi.list({
      search: search || undefined,
      status: statusFilter || undefined,
      source_type: sourceTypeFilter || undefined,
      cursor,
      page_size: 25,
    }),
  })

  const rows = useMemo(() => data?.items ?? [], [data?.items])
  const selected = useMemo(() => rows.find((entry) => entry.id === selectedId) ?? null, [rows, selectedId])

  const retry = useMutation({
    mutationFn: (id: string) => dlqApi.retry(id),
    onMutate: (id) => {
      setActionError(null)
      setTransientStatusById((prev) => ({ ...prev, [id]: 'retrying' }))
    },
    onError: (_err, id) => {
      setTransientStatusById((prev) => {
        const next = { ...prev }
        delete next[id]
        return next
      })
      setActionError('Retry failed. Please try again.')
    },
    onSuccess: (_result, id) => {
      qc.invalidateQueries({ queryKey: tenantKeys.dlq.list() })
      qc.invalidateQueries({ queryKey: tenantKeys.dlq.detail(id) })
    },
  })

  const discard = useMutation({
    mutationFn: (id: string) => dlqApi.discard(id),
    onMutate: (id) => {
      setActionError(null)
      setTransientStatusById((prev) => ({ ...prev, [id]: 'discarded' }))
    },
    onError: (_err, id) => {
      setTransientStatusById((prev) => {
        const next = { ...prev }
        delete next[id]
        return next
      })
      setActionError('Discard failed. Please try again.')
    },
    onSuccess: (_result, id) => {
      qc.invalidateQueries({ queryKey: tenantKeys.dlq.list() })
      qc.invalidateQueries({ queryKey: tenantKeys.dlq.detail(id) })
      if (selectedId === id) setSelectedId(null)
    },
  })

  const applyFilters = () => {
    setCursorStack([])
  }

  const goNext = () => {
    if (!data?.next_cursor) return
    setCursorStack((prev) => [...prev, data.next_cursor as string])
  }

  const goPrev = () => {
    setCursorStack((prev) => prev.slice(0, -1))
  }

  const clearSelection = () => setSelectedId(null)

  const confirmDiscard = () => {
    if (!discardConfirmItem) return
    discard.mutate(discardConfirmItem.id)
    setDiscardConfirmItem(null)
  }

  const page = cursorStack.length + 1
  const pageSize = 25
  const hasNextPage = data?.next_cursor != null

  const columns: DataTableColumn<DlqEntry>[] = [
    {
      id: 'source',
      header: 'Source',
      accessor: (e) => (
        <span
          style={{
            display: 'inline-flex',
            alignItems: 'center',
            borderRadius: '999px',
            padding: '.2rem .55rem',
            fontSize: '.75rem',
            fontWeight: 600,
            background: 'var(--color-neutral-200)',
            color: 'var(--text-primary)',
            textTransform: 'uppercase',
          }}
        >
          {e.entry_type ?? e.item_type ?? 'unknown'}
        </span>
      ),
    },
    {
      id: 'instance',
      header: 'Instance',
      accessor: (e) =>
        e.instance_id ? (
          <Link to={`/instances/${e.instance_id}`} onClick={(event) => event.stopPropagation()}>
            {e.instance_id.slice(0, 8)}...
          </Link>
        ) : (
          '—'
        ),
    },
    {
      id: 'reason',
      header: 'Reason',
      accessor: (e) => (
        <span style={{ maxWidth: '240px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', display: 'block' }}>
          {extractFailureReason(e)}
        </span>
      ),
    },
    {
      id: 'retry_count',
      header: 'Retry count',
      sortable: true,
      sortValue: (e) => e.retry_count,
      accessor: (e) => e.retry_count,
    },
    {
      id: 'created',
      header: 'Created',
      sortable: true,
      sortValue: (e) => e.created_at,
      accessor: (e) => toShortDate(e.created_at),
    },
    {
      id: 'status',
      header: 'Status',
      accessor: (e) => <StatusBadge status={normalizeStatus(e, transientStatusById[e.id])} domain="dlq" />,
    },
    {
      id: 'actions',
      header: 'Actions',
      accessor: (e) => {
        const status = normalizeStatus(e, transientStatusById[e.id])
        return (
          <div style={{ display: 'flex', gap: '.4rem' }} onClick={(event) => event.stopPropagation()}>
            <Button
              variant="secondary"
              size="sm"
              data-testid={`dlq-details-${toRowTestId(e.id)}`}
              onClick={() => setSelectedId(e.id)}
            >
              Details
            </Button>
            {canOperate && status !== 'resolved' && status !== 'discarded' && (
              <>
                <Button
                  variant="primary"
                  size="sm"
                  data-testid={`dlq-retry-${toRowTestId(e.id)}`}
                  onClick={() => retry.mutate(e.id)}
                  loading={retry.isPending}
                >
                  Retry
                </Button>
                <Button
                  variant="danger"
                  size="sm"
                  data-testid={`dlq-discard-${toRowTestId(e.id)}`}
                  onClick={() => setDiscardConfirmItem(e)}
                  loading={discard.isPending}
                >
                  Discard
                </Button>
              </>
            )}
          </div>
        )
      },
    },
  ]

  const retryHistoryColumns: DataTableColumn<RetryAttempt>[] = [
    { id: 'attempt', header: 'Attempt', accessor: (a) => a.attemptNo },
    { id: 'time', header: 'Time', accessor: (a) => toShortDate(a.attemptedAt) },
    { id: 'outcome', header: 'Outcome', accessor: (a) => a.outcome },
    { id: 'error', header: 'Error', accessor: (a) => a.errorMessage ?? '—' },
  ]

  return (
    <div data-testid="dlq-page">
      <PageLayout title="Dead-Letter Queue">
        <FilterBar
          activeCount={[search, statusFilter, sourceTypeFilter].filter(Boolean).length}
          onClear={() => { setSearch(''); setStatusFilter(''); setSourceTypeFilter(''); applyFilters() }}
        >
          <input
            data-testid="dlq-filter-search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="id, reason, or instance"
            style={{ minWidth: '240px', padding: '.35rem .6rem', border: '1px solid var(--border-default)', borderRadius: '4px' }}
          />
          <select
            data-testid="dlq-filter-status"
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            style={{ padding: '.35rem .6rem', border: '1px solid var(--border-default)', borderRadius: '4px' }}
          >
            <option value="">All statuses</option>
            <option value="pending">Pending</option>
            <option value="retrying">Retrying</option>
            <option value="resolved">Resolved</option>
            <option value="discarded">Discarded</option>
          </select>
          <select
            data-testid="dlq-filter-source"
            value={sourceTypeFilter}
            onChange={(e) => setSourceTypeFilter(e.target.value)}
            style={{ padding: '.35rem .6rem', border: '1px solid var(--border-default)', borderRadius: '4px' }}
          >
            <option value="">All sources</option>
            <option value="event">Event</option>
            <option value="timer">Timer</option>
            <option value="webhook">Webhook</option>
          </select>
          <Button variant="secondary" size="sm" data-testid="dlq-filter-apply" onClick={applyFilters}>
            Apply
          </Button>
        </FilterBar>

        <QueryStateBoundary
          state={(isLoading ? 'loading' : isError ? classifyError(error) : 'success') as RendererState}
          onRetry={() => { void refetch() }}
          columns={[{ widthPercent: 20 }, { widthPercent: 40 }, { widthPercent: 10 }, { widthPercent: 15 }, { widthPercent: 15 }]}
        >
        {actionError && <p style={{ color: 'var(--color-error-dark)' }}>{actionError}</p>}

        <DataTable<DlqEntry>
          columns={columns}
          data={rows}
          emptyMessage="Queue is empty."
          onRowClick={(e) => setSelectedId(e.id)}
        />

        <div style={{ marginTop: '.85rem' }}>
          <PaginationControls
            page={page}
            pageSize={pageSize}
            totalItems={null}
            hasNextPage={hasNextPage}
            onPageChange={(nextPage) => (nextPage > page ? goNext() : goPrev())}
          />
        </div>
        </QueryStateBoundary>

        {selected && (
          <section data-testid="dlq-detail-panel" style={{ marginTop: '1rem', border: '1px solid var(--border-default)', borderRadius: '6px', padding: '1rem', background: 'var(--surface-card)' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '.6rem' }}>
              <h3 style={{ margin: 0 }}>DLQ Item Detail</h3>
              <Button variant="secondary" size="sm" onClick={clearSelection}>
                Close
              </Button>
            </div>

            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem', marginBottom: '.8rem' }}>
              <tbody>
                <tr style={{ borderBottom: '1px solid var(--border-default)' }}>
                  <td style={{ width: '180px', color: 'var(--text-secondary)', padding: '.45rem .55rem' }}>Item ID</td>
                  <td style={{ padding: '.45rem .55rem', fontFamily: 'monospace' }}>{selected.id}</td>
                </tr>
                <tr style={{ borderBottom: '1px solid var(--border-default)' }}>
                  <td style={{ color: 'var(--text-secondary)', padding: '.45rem .55rem' }}>Source</td>
                  <td style={{ padding: '.45rem .55rem' }}>{selected.entry_type ?? selected.item_type ?? 'unknown'}</td>
                </tr>
                <tr style={{ borderBottom: '1px solid var(--border-default)' }}>
                  <td style={{ color: 'var(--text-secondary)', padding: '.45rem .55rem' }}>Instance</td>
                  <td style={{ padding: '.45rem .55rem' }}>{selected.instance_id ?? '—'}</td>
                </tr>
                <tr style={{ borderBottom: '1px solid var(--border-default)' }}>
                  <td style={{ color: 'var(--text-secondary)', padding: '.45rem .55rem' }}>Status</td>
                  <td style={{ padding: '.45rem .55rem' }}>
                    <StatusBadge status={normalizeStatus(selected, transientStatusById[selected.id])} domain="dlq" />
                  </td>
                </tr>
              </tbody>
            </table>

            <h4 style={{ margin: '.4rem 0' }}>Full failure reason</h4>
            <pre style={{ background: 'var(--surface-page)', border: '1px solid var(--border-default)', borderRadius: '4px', padding: '.65rem', overflow: 'auto', fontSize: '.8rem' }}>
              {extractFailureReason(selected)}
            </pre>

            <h4 style={{ margin: '.8rem 0 .4rem' }}>Retry history</h4>
            {extractRetryHistory(selected).length > 0 ? (
              <DataTable<RetryAttempt>
                columns={retryHistoryColumns}
                data={extractRetryHistory(selected)}
                emptyMessage="No retry history available."
              />
            ) : (
              <p style={{ margin: 0, color: 'var(--text-secondary)' }}>No retry history available.</p>
            )}

            <h4 style={{ margin: '.8rem 0 .4rem' }}>Context JSON</h4>
            <JsonEditor
              value={toPrettyJson(selected.context_json ?? selected.processor_metadata)}
              onChange={() => {}}
              label="Context JSON"
              readOnly
              height={160}
            />

            <div style={{ marginTop: '.8rem' }}>
              <JsonEditor
                value={toPrettyJson(selected.source_payload ?? selected.original_payload)}
                onChange={() => {}}
                label="Source payload"
                readOnly
                height={160}
              />
            </div>
          </section>
        )}

        {discardConfirmItem && (
          <div
            data-testid="dlq-discard-dialog"
            role="dialog"
            aria-modal="true"
            aria-label="Discard DLQ item"
            style={{
              position: 'fixed',
              inset: 0,
              background: 'var(--surface-overlay-slate)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              padding: '1rem',
              zIndex: 40,
            }}
          >
            <div style={{ background: 'var(--surface-card)', borderRadius: '6px', width: '100%', maxWidth: '520px', padding: '1rem', border: '1px solid var(--border-default)' }}>
              <h3 style={{ marginTop: 0 }}>Discard this DLQ item?</h3>
              <p style={{ marginTop: 0, color: 'var(--text-secondary)' }}>
                This action cannot be undone.
              </p>
              {discardConfirmItem.instance_id && (
                <p style={{ marginTop: 0, color: 'var(--color-warning-text)', background: 'var(--color-warning-tint)', border: '1px solid var(--color-warning-border)', borderRadius: '4px', padding: '.5rem .65rem' }}>
                  This item is tied to instance {discardConfirmItem.instance_id}. Discarding may cancel the associated instance.
                </p>
              )}

              <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '.5rem' }}>
                <button
                  type="button"
                  onClick={() => setDiscardConfirmItem(null)}
                  style={{ padding: '.38rem .82rem', border: '1px solid var(--border-default)', borderRadius: '4px', background: 'var(--surface-card)', cursor: 'pointer' }}
                >
                  Cancel
                </button>
                <button
                  data-testid="dlq-discard-confirm"
                  type="button"
                  onClick={confirmDiscard}
                  style={{ padding: '.38rem .82rem', border: 'none', borderRadius: '4px', background: 'var(--interactive-danger)', color: 'var(--text-inverse)', cursor: 'pointer' }}
                >
                  Discard
                </button>
              </div>
            </div>
          </div>
        )}
      </PageLayout>
    </div>
  )
}
