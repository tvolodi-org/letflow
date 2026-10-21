/** EventRetentionPage — REQ-377: operator-facing history-retirement screen
 *  for REQ-376's whole-partition retirement mechanism.
 *
 *  Implements `lib/letflow/design/req377-history-retirement-screen.md` §3.4
 *  verbatim. Single route, single page: a retention summary card (AC2), a
 *  single retire-oldest-month action (AC1), and a status panel that polls
 *  without ever blocking the rest of the console (EO-001 -- see
 *  `useRetirementStatus`'s own comment in `hooks/useEventRetention.ts`).
 *
 *  Backend: REQ-377 itself (new -- `Letflow.Routers.EventRetention`, built
 *  as part of this same requirement per the design's §0 scope decision).
 *  No mock data.
 */

import React, { useEffect, useState } from 'react'
import { Navigate, useSearchParams } from 'react-router-dom'
import { useAccess, AccessPending } from '@/auth/access'
import { useRetentionSummary, useStartRetirement, useRetirementStatus } from '@/hooks/useEventRetention'
import type { RetentionSummary, RetirementOutcome, RetirementResult } from '@/api/eventRetention'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { useQueryClient } from '@tanstack/react-query'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { formatDateTime } from '@/i18n/format'

function RetentionSummaryCard(props: { summary: RetentionSummary | undefined; isLoading: boolean }): React.ReactElement {
  const { summary, isLoading } = props

  return (
    <div data-testid="retention-summary-card" style={{ display: 'flex', flexDirection: 'column', gap: '.5rem', padding: '1rem', border: '1px solid var(--border-default)', borderRadius: '6px', maxWidth: '480px' }}>
      <h3 style={{ margin: 0 }}>Retention summary</h3>
      {isLoading ? (
        <div data-testid="retention-summary-loading">Loading…</div>
      ) : summary ? (
        <>
          <div data-testid="retention-summary-oldest-month" style={{ fontSize: '.9rem' }}>
            Oldest eligible month:{' '}
            {summary.oldest_eligible_month
              ? `${summary.oldest_eligible_month.year}-${String(summary.oldest_eligible_month.month).padStart(2, '0')}`
              : 'None currently eligible'}
          </div>
          <div style={{ fontSize: '.9rem' }}>
            Protected records:{' '}
            <strong data-testid="retention-summary-protected-count">{summary.protected_record_count}</strong>
          </div>
          <div data-testid="retention-summary-tenant-count" style={{ fontSize: '.85rem', color: 'var(--text-secondary)' }}>
            {summary.tenant_schema_count} provisioned tenant schema{summary.tenant_schema_count === 1 ? '' : 's'}
          </div>
          <div style={{ fontSize: '.8rem', color: 'var(--text-secondary)' }}>
            Computed {formatDateTime(summary.computed_at)}
          </div>
        </>
      ) : null}
    </div>
  )
}

function RetireOldestMonthButton(props: { disabled: boolean; loading: boolean; onRetire: () => void }): React.ReactElement {
  const { disabled, loading, onRetire } = props
  return (
    <Button
      variant="primary"
      size="md"
      data-testid="retire-oldest-month-btn"
      disabled={disabled}
      loading={loading}
      onClick={onRetire}
    >
      Retire oldest eligible month
    </Button>
  )
}

function RetirementOutcomeRow(props: { outcome: RetirementOutcome }): React.ReactElement {
  const { outcome } = props
  return (
    <tr data-testid={`retirement-outcome-row-${outcome.tenant_id}`}>
      <td data-testid={`retirement-outcome-tenant-${outcome.tenant_id}`} style={{ padding: '.5rem .75rem', borderBottom: '1px solid var(--border-default)', fontFamily: 'var(--font-mono)' }}>
        {outcome.tenant_id}
      </td>
      <td data-testid={`retirement-outcome-status-${outcome.tenant_id}`} style={{ padding: '.5rem .75rem', borderBottom: '1px solid var(--border-default)' }}>
        <StatusBadge status={outcome.status} domain="event-retirement-outcome" size="sm" />
      </td>
      <td data-testid={`retirement-outcome-partition-${outcome.tenant_id}`} style={{ padding: '.5rem .75rem', borderBottom: '1px solid var(--border-default)' }}>
        {outcome.retired_partition ?? '—'}
      </td>
      <td data-testid={`retirement-outcome-protected-${outcome.tenant_id}`} style={{ padding: '.5rem .75rem', borderBottom: '1px solid var(--border-default)' }}>
        {outcome.protected_rows_relocated ?? '—'}
      </td>
      <td data-testid={`retirement-outcome-reason-${outcome.tenant_id}`} style={{ padding: '.5rem .75rem', borderBottom: '1px solid var(--border-default)' }}>
        {outcome.status === 'failed' ? (outcome.reason ?? '') : ''}
      </td>
    </tr>
  )
}

function RetirementStatusPanel(props: { result: RetirementResult }): React.ReactElement {
  const { result } = props
  const { retirement, outcomes } = result
  const isRunning = retirement.status === 'running'
  const doneCount = outcomes.filter((o) => o.status !== 'pending').length

  return (
    <div data-testid="retirement-status-panel" style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: '.35rem' }}>
        <div style={{ display: 'flex', gap: '.5rem', alignItems: 'center' }}>
          <h3 style={{ margin: 0 }}>
            {retirement.year && retirement.month
              ? `${retirement.year}-${String(retirement.month).padStart(2, '0')}`
              : 'Retirement'}
          </h3>
          <span data-testid="retirement-status-badge">
            <StatusBadge status={retirement.status} domain="event-retirement" size="sm" />
          </span>
        </div>
        <div data-testid="retirement-id-display" style={{ fontSize: '.8rem', color: 'var(--text-secondary)', fontFamily: 'var(--font-mono)' }}>
          {retirement.id}
        </div>
        <div style={{ fontSize: '.85rem', color: 'var(--text-secondary)' }}>
          Started {formatDateTime(retirement.started_at)}
          {retirement.completed_at && <> &middot; Completed {formatDateTime(retirement.completed_at)}</>}
        </div>
        {/* Partial-progress line while running -- NOT a full-page blocking
            spinner tied to the retirement's own duration (EO-001). The rest
            of the console (nav, other pages) is untouched by this state. */}
        {isRunning && (
          <div data-testid="retirement-progress-line" style={{ fontSize: '.85rem', color: 'var(--text-secondary)' }}>
            Retiring… {doneCount} of {outcomes.length || '?'} tenants done
          </div>
        )}
      </div>

      <table data-testid="retirement-outcome-table" style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem' }}>
        <thead>
          <tr>
            <th style={{ textAlign: 'left', padding: '.5rem .75rem', borderBottom: '2px solid var(--border-default)' }}>Tenant</th>
            <th style={{ textAlign: 'left', padding: '.5rem .75rem', borderBottom: '2px solid var(--border-default)' }}>Outcome</th>
            <th style={{ textAlign: 'left', padding: '.5rem .75rem', borderBottom: '2px solid var(--border-default)' }}>Retired partition</th>
            <th style={{ textAlign: 'left', padding: '.5rem .75rem', borderBottom: '2px solid var(--border-default)' }}>Protected rows</th>
            <th style={{ textAlign: 'left', padding: '.5rem .75rem', borderBottom: '2px solid var(--border-default)' }}>Reason</th>
          </tr>
        </thead>
        <tbody>
          {outcomes.map((o) => (
            <RetirementOutcomeRow key={o.tenant_id} outcome={o} />
          ))}
        </tbody>
      </table>
    </div>
  )
}

export default function EventRetentionPage(): React.ReactElement {
  const access = useAccess()
  const isAllowed = access.canManageTenants

  const [searchParams, setSearchParams] = useSearchParams()
  const deepLinkRetirementId = searchParams.get('retirement')
  const [activeRetirementId, setActiveRetirementId] = useState<string | null>(deepLinkRetirementId)
  const [startError, setStartError] = useState<string | null>(null)

  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const summaryQuery = useRetentionSummary()
  const startRetirement = useStartRetirement()
  const statusQuery = useRetirementStatus(activeRetirementId)

  // §3.4 -- on transition to 'completed'/'failed', invalidate the summary so
  // the "after" summary (AC2/EO-002) reflects the just-finished retirement.
  const retirementStatus = statusQuery.data?.retirement.status
  useEffect(() => {
    if (retirementStatus === 'completed' || retirementStatus === 'failed') {
      void qc.invalidateQueries({ queryKey: tenantKeys.eventRetention.summary() })
    }
    // tenantKeys is a fresh object every render (useTenantScopedQueryKeys is
    // unmemoized) but derived only from the stable session tenant id — safe
    // to omit, re-including it would re-run this effect every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [retirementStatus, qc])

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  const handleRetire = () => {
    setStartError(null)
    startRetirement.mutate(undefined, {
      onSuccess: (data) => {
        setActiveRetirementId(data.id)
        const next = new URLSearchParams(searchParams)
        next.set('retirement', data.id)
        setSearchParams(next)
      },
      onError: (err) => {
        setStartError(err.message)
      },
    })
  }

  const statusState: RendererState = activeRetirementId
    ? statusQuery.isLoading && !statusQuery.data
      ? 'loading'
      : statusQuery.isError && !statusQuery.data
        ? classifyError(statusQuery.error)
        : 'success'
    : 'success'

  const retireDisabled =
    startRetirement.isPending ||
    summaryQuery.isLoading ||
    !summaryQuery.data?.oldest_eligible_month

  return (
    <PageLayout title="Event Retention">
      <div style={{ display: 'flex', flexDirection: 'column', gap: '1.5rem' }}>
        <RetentionSummaryCard summary={summaryQuery.data} isLoading={summaryQuery.isLoading} />

        <div>
          <RetireOldestMonthButton
            disabled={retireDisabled}
            loading={startRetirement.isPending}
            onRetire={handleRetire}
          />
        </div>

        {startError && (
          <div
            data-testid="retirement-start-error"
            style={{ padding: '.6rem .8rem', background: 'var(--color-error-light)', color: 'var(--color-error-dark)', borderRadius: '4px', fontSize: '.85rem' }}
          >
            The retirement could not be started ({startError}). No change was made — try again.
          </div>
        )}

        {activeRetirementId && (
          <QueryStateBoundary state={statusState} onRetry={() => { void statusQuery.refetch() }}>
            {statusQuery.data && <RetirementStatusPanel result={statusQuery.data} />}
          </QueryStateBoundary>
        )}
      </div>
    </PageLayout>
  )
}
