import { Fragment, useMemo, useState } from 'react'
import { Navigate } from 'react-router-dom'
import { useQuery, type UseQueryResult } from '@tanstack/react-query'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { auditApi, type AuditEntry, type AuditLogFilters } from '@/api/audit'
import type { CursorPage } from '@/types/api'
import { JsonDiffView } from '@/components/ui/JsonDiffView'
import { P, useAccess, AccessPending } from '@/auth/access'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { PaginationControls } from '@/components/ui/PaginationControls'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { formatDateTime } from '@/i18n/format'

// NOTE: this table keeps native <table> markup rather than DataTable
// (REQ-274) because each row supports an inline expand-to-diff affordance
// (a second <tr> rendering JsonDiffView) that DataTable's column/row model
// has no concept of -- DataTable supports only sorting, not expandable
// sub-rows (see its moduledoc). Colours are still fully tokenized, and
// pagination is delegated to PaginationControls (cursor-based: totalItems
// is unknown, so hasNextPage drives the Next button per PaginationControls'
// own documented cursor-pagination case).

function isValidIsoDate(value?: string): boolean {
  if (!value) return true
  return !Number.isNaN(Date.parse(value))
}

function isFilterRangeValid(from?: string, to?: string): boolean {
  if (!from || !to) return true
  return new Date(from).getTime() <= new Date(to).getTime()
}

export function useAuditLog(filters: AuditLogFilters): UseQueryResult<CursorPage<AuditEntry>> {
  const adminKeys = useTenantScopedQueryKeys().admin
  return useQuery({
    queryKey: adminKeys.audit(filters),
    queryFn: () => auditApi.list(filters),
    refetchInterval: 30_000,
  })
}

export default function AuditLogPage() {
  const adminKeys = useTenantScopedQueryKeys().admin
  const access = useAccess()
  const isAllowed = access.can(P.AuditRead)

  const [actor, setActor] = useState('')
  const [resourceType, setResourceType] = useState('')
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [cursorStack, setCursorStack] = useState<string[]>([])
  const [expandedRows, setExpandedRows] = useState<Record<string, boolean>>({})
  const [pageSize, setPageSize] = useState<number>(25)

  const cursor = cursorStack[cursorStack.length - 1]
  const filters = useMemo<AuditLogFilters>(() => ({
    actor: actor || undefined,
    resource_type: resourceType || undefined,
    from: from || undefined,
    to: to || undefined,
    cursor,
    page_size: pageSize,
  }), [actor, resourceType, from, to, cursor, pageSize])

  const validFilters = isValidIsoDate(from) && isValidIsoDate(to) && isFilterRangeValid(from, to)
  const { data, isLoading, isError, error, isFetching, refetch } = useQuery({
    queryKey: adminKeys.audit(filters),
    queryFn: () => auditApi.list(filters),
    enabled: validFilters,
    refetchInterval: 30_000,
  })

  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  const nextCursor = data?.next_cursor
  const hasResults = (data?.items.length ?? 0) > 0

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Audit Log</h2>
        {isFetching && <span style={{ fontSize: 'var(--text-xs)', color: 'var(--color-info-dark)' }}>Refreshing…</span>}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: '.65rem', marginBottom: '1rem' }}>
        <input
          value={actor}
          onChange={(e) => {
            setActor(e.target.value)
            setCursorStack([])
          }}
          placeholder="Actor ID"
          style={{ padding: '.45rem .6rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)' }}
        />
        <input
          value={resourceType}
          onChange={(e) => {
            setResourceType(e.target.value)
            setCursorStack([])
          }}
          placeholder="Resource type"
          style={{ padding: '.45rem .6rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)' }}
        />
        <input
          value={from}
          onChange={(e) => {
            setFrom(e.target.value)
            setCursorStack([])
          }}
          placeholder="From (ISO8601)"
          style={{ padding: '.45rem .6rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)' }}
        />
        <input
          value={to}
          onChange={(e) => {
            setTo(e.target.value)
            setCursorStack([])
          }}
          placeholder="To (ISO8601)"
          style={{ padding: '.45rem .6rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)' }}
        />
        <select
          value={pageSize}
          onChange={(e) => {
            setPageSize(Number(e.target.value))
            setCursorStack([])
          }}
          style={{ padding: '.45rem .6rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)' }}
        >
          <option value={25}>25 / page</option>
          <option value={50}>50 / page</option>
          <option value={100}>100 / page</option>
        </select>
      </div>

      {!validFilters && (
        <div style={{ marginBottom: '1rem', padding: '.75rem .9rem', borderRadius: 'var(--radius-sm)', border: '1px solid var(--color-warning-border)', background: 'var(--color-warning-tint)', color: 'var(--color-warning-text)' }}>
          Please enter valid ISO8601 date filters and ensure from ≤ to.
        </div>
      )}

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={
          rendererState === 'rate-limit'
            ? getRetryAfterSeconds(error)
            : undefined
        }
        columns={[{ widthPercent: 5 }, { widthPercent: 20 }, { widthPercent: 20 }, { widthPercent: 25 }, { widthPercent: 20 }, { widthPercent: 10 }]}
      >
        {validFilters && !hasResults && (
          <div style={{ marginBottom: '1rem', color: 'var(--text-secondary)' }}>No audit entries matched the selected filters.</div>
        )}

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 'var(--text-sm)' }}>
        <thead>
          <tr style={{ background: 'var(--surface-page)', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}></th>
            <th style={{ padding: '.6rem .8rem' }}>Time</th>
            <th style={{ padding: '.6rem .8rem' }}>Actor</th>
            <th style={{ padding: '.6rem .8rem' }}>Action</th>
            <th style={{ padding: '.6rem .8rem' }}>Resource</th>
            <th style={{ padding: '.6rem .8rem' }}>IP</th>
          </tr>
        </thead>
        <tbody>
          {(data?.items ?? []).map((e: AuditEntry) => (
            <Fragment key={e.id}>
              <tr key={e.id} style={{ borderBottom: '1px solid var(--border-default)' }}>
                <td style={{ padding: '.5rem .8rem' }}>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => {
                      setExpandedRows((prev) => ({ ...prev, [e.id]: !prev[e.id] }))
                    }}
                  >
                    {expandedRows[e.id] ? '−' : '+'}
                  </Button>
                </td>
                <td style={{ padding: '.5rem .8rem', color: 'var(--text-secondary)', fontFamily: 'var(--font-mono)', fontSize: 'var(--text-xs)', whiteSpace: 'nowrap' }}>
                  {formatDateTime(e.occurred_at)}
                </td>
                <td style={{ padding: '.5rem .8rem', fontSize: 'var(--text-xs)', fontFamily: 'var(--font-mono)' }}>{e.actor_display_name ?? e.actor_id}</td>
                <td style={{ padding: '.5rem .8rem', fontFamily: 'var(--font-mono)', fontSize: 'var(--text-xs)', fontWeight: 600 }}>{e.action}</td>
                <td style={{ padding: '.5rem .8rem', fontSize: 'var(--text-xs)', color: 'var(--text-secondary)' }}>
                  {e.resource_type} / {e.resource_id}
                </td>
                <td style={{ padding: '.5rem .8rem', fontFamily: 'var(--font-mono)', fontSize: 'var(--text-xs)', color: 'var(--text-secondary)' }}>{e.ip_address ?? '—'}</td>
              </tr>
              {expandedRows[e.id] && (
                <tr>
                  <td colSpan={6} style={{ padding: '.6rem .8rem', background: 'var(--surface-page)', borderBottom: '1px solid var(--border-default)' }}>
                    <JsonDiffView before={e.before_state} after={e.after_state} />
                  </td>
                </tr>
              )}
            </Fragment>
          ))}
        </tbody>
      </table>

      <div style={{ marginTop: '1rem' }}>
        <PaginationControls
          page={cursorStack.length + 1}
          pageSize={pageSize}
          totalItems={null}
          hasNextPage={Boolean(nextCursor)}
          onPageChange={(newPage) => {
            if (newPage < cursorStack.length + 1) {
              setCursorStack((prev) => prev.slice(0, -1))
            } else if (nextCursor) {
              setCursorStack((prev) => [...prev, nextCursor])
            }
          }}
        />
      </div>
      </QueryStateBoundary>
    </div>
  )
}
