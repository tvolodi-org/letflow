/** PlatformMigrationConsolePage — REQ-375: operator-facing rollout-status
 *  screen for REQ-374's platform-wide tenant-migration fanout runner.
 *
 *  Implements `lib/letflow/design/req375-rollout-status-screen.md` verbatim.
 *  Single route, single page: hosts both the start form (§6) and the status
 *  view (§2, §4, §5, §7) so an operator can re-submit the identical form
 *  values to exercise EO-005's no-op re-run path without a second route that
 *  cannot reconstruct `column_spec` from `GET .../:id` alone (§1.1).
 *
 *  Backend: REQ-374 (shipped, commit `eaa8abe6`, PR 1693) — no mock data, no
 *  new endpoint, no change to `lib/letflow/`.
 */

import React, { useMemo, useState } from 'react'
import { Navigate, useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAccess, AccessPending } from '@/auth/access'
import { useRolloutStatus, useStartRollout, useResumeRollout } from '@/hooks/usePlatformMigrations'
import type { RolloutOutcome, RolloutResult, StartRolloutRequest } from '@/api/platformMigrations'
import { tenantsApi } from '@/api/tenants'
import { queryKeys } from '@/api/queryKeys'
import type { ApiError } from '@/types/api'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { formatDateTime } from '@/i18n/format'

// §7 OQ-1 — a single, generously-sized page of the (paginated) tenant list is
// fetched to resolve tenant_id -> display_name for the outcome table. This is
// the graceful-degradation choice the design flags as acceptable (fall back
// to the raw UUID for anything not found on this page) rather than looping
// `next_cursor` to build an exhaustive index — no existing admin screen in
// web/src loops pagination client-side to build a full index, and REQ-375's
// acceptance criteria do not require resolving every tenant on a platform
// with more active companies than fit on one page.
const TENANT_LOOKUP_PAGE_SIZE = 200

type LastAction = 'none' | 'start' | 'resume'

/** §4 — resume-control visibility: outstanding means anything not yet
 *  `succeeded`. Computed purely from the already-fetched result, no separate
 *  server flag. */
function hasOutstandingCompanies(result: RolloutResult): boolean {
  return result.outcomes.some((o) => o.status !== 'succeeded')
}

/** §5 — a no-op re-run: EVERY outcome in the response already reports
 *  `already_current: true`. Applied only to the START mutation's own
 *  response — resume/status responses always report `already_current: false`
 *  per the design's own verified nuance (§5), so this function is never
 *  called against those. */
function isNoOpResult(result: RolloutResult): boolean {
  return result.outcomes.length > 0 && result.outcomes.every((o) => o.already_current === true)
}

function useTenantNameLookup(): Map<string, string> {
  const query = useQuery({
    queryKey: queryKeys.admin.tenants({ page_size: TENANT_LOOKUP_PAGE_SIZE }),
    queryFn: () => tenantsApi.list({ page_size: TENANT_LOOKUP_PAGE_SIZE }),
  })

  return useMemo(() => {
    const map = new Map<string, string>()
    for (const tenant of query.data?.items ?? []) {
      // §9 OQ-1(b) — tenant_id is typed optional on Tenant; skip entries
      // that don't carry it rather than asserting presence.
      if (tenant.tenant_id) {
        map.set(tenant.tenant_id, tenant.display_name)
      }
    }
    return map
  }, [query.data])
}

function RolloutStartForm(props: {
  disabled: boolean
  onSubmit: (body: StartRolloutRequest) => void
}): React.ReactElement {
  const { disabled, onSubmit } = props
  const [entityType, setEntityType] = useState('')
  const [attribute, setAttribute] = useState('')
  const [pgType, setPgType] = useState('')
  const [referencesEntity, setReferencesEntity] = useState('')
  const [generatedAs, setGeneratedAs] = useState('')

  const canSubmit = entityType.trim() !== '' && attribute.trim() !== '' && pgType.trim() !== '' && !disabled

  const handleSubmit = () => {
    if (!canSubmit) return
    onSubmit({
      entity_type: entityType.trim(),
      attribute: attribute.trim(),
      column_spec: {
        pg_type: pgType.trim(),
        references_entity: referencesEntity.trim() === '' ? null : referencesEntity.trim(),
        generated_as: generatedAs.trim() === '' ? null : generatedAs.trim(),
      },
    })
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '.75rem', maxWidth: '480px' }}>
      <div>
        <label htmlFor="rollout-entity-type-input" style={{ display: 'block', fontSize: '.85rem', marginBottom: '.25rem', color: 'var(--text-primary)' }}>
          Entity type
        </label>
        <input
          id="rollout-entity-type-input"
          data-testid="rollout-entity-type-input"
          type="text"
          value={entityType}
          disabled={disabled}
          onChange={(e) => setEntityType(e.target.value)}
          style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)' }}
        />
      </div>
      <div>
        <label htmlFor="rollout-attribute-input" style={{ display: 'block', fontSize: '.85rem', marginBottom: '.25rem', color: 'var(--text-primary)' }}>
          Attribute
        </label>
        <input
          id="rollout-attribute-input"
          data-testid="rollout-attribute-input"
          type="text"
          value={attribute}
          disabled={disabled}
          onChange={(e) => setAttribute(e.target.value)}
          style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)' }}
        />
      </div>
      <div>
        <label htmlFor="rollout-pg-type-input" style={{ display: 'block', fontSize: '.85rem', marginBottom: '.25rem', color: 'var(--text-primary)' }}>
          Column PG type
        </label>
        <input
          id="rollout-pg-type-input"
          data-testid="rollout-pg-type-input"
          type="text"
          value={pgType}
          disabled={disabled}
          onChange={(e) => setPgType(e.target.value)}
          style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)' }}
        />
      </div>
      <div>
        <label htmlFor="rollout-references-entity-input" style={{ display: 'block', fontSize: '.85rem', marginBottom: '.25rem', color: 'var(--text-primary)' }}>
          References entity (optional)
        </label>
        <input
          id="rollout-references-entity-input"
          data-testid="rollout-references-entity-input"
          type="text"
          value={referencesEntity}
          disabled={disabled}
          onChange={(e) => setReferencesEntity(e.target.value)}
          style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)' }}
        />
      </div>
      <div>
        <label htmlFor="rollout-generated-as-input" style={{ display: 'block', fontSize: '.85rem', marginBottom: '.25rem', color: 'var(--text-primary)' }}>
          Generated-as expression (optional)
        </label>
        <input
          id="rollout-generated-as-input"
          data-testid="rollout-generated-as-input"
          type="text"
          value={generatedAs}
          disabled={disabled}
          onChange={(e) => setGeneratedAs(e.target.value)}
          style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)' }}
        />
      </div>
      <div>
        <Button
          variant="primary"
          size="md"
          data-testid="rollout-start-btn"
          disabled={!canSubmit}
          onClick={handleSubmit}
        >
          Start rollout
        </Button>
      </div>
    </div>
  )
}

function RolloutSummaryHeader(props: { rollout: RolloutResult['rollout'] }): React.ReactElement {
  const { rollout } = props
  return (
    <div data-testid="rollout-summary-header" style={{ display: 'flex', flexDirection: 'column', gap: '.35rem' }}>
      <div style={{ display: 'flex', gap: '.5rem', alignItems: 'center' }}>
        <h3 style={{ margin: 0 }}>
          {rollout.entity_type}.{rollout.attribute}
        </h3>
        <span data-testid="rollout-status-badge">
          {/* rollout.status is the ROLLOUT-level enum ('running'|'completed'),
              a disjoint set from outcome.status ('pending'|'succeeded'|'failed') —
              use the distinct `rollout` domain, not `rollout-outcome` (REVIEWER
              caught these being conflated under one table; see StatusBadge.tsx). */}
          <StatusBadge status={rollout.status} domain="rollout" size="sm" />
        </span>
      </div>
      <div data-testid="rollout-id-display" style={{ fontSize: '.8rem', color: 'var(--text-secondary)', fontFamily: 'var(--font-mono)' }}>
        {rollout.id}
      </div>
      <div style={{ fontSize: '.85rem', color: 'var(--text-secondary)' }}>
        Started {formatDateTime(rollout.started_at)}
        {rollout.completed_at && <> &middot; Completed {formatDateTime(rollout.completed_at)}</>}
      </div>
    </div>
  )
}

function RolloutOutcomeRow(props: { outcome: RolloutOutcome; tenantNames: Map<string, string> }): React.ReactElement {
  const { outcome, tenantNames } = props
  const companyName = tenantNames.get(outcome.tenant_id) ?? outcome.tenant_id

  return (
    <tr data-testid={`rollout-outcome-row-${outcome.tenant_id}`}>
      <td data-testid={`rollout-outcome-company-${outcome.tenant_id}`} style={{ padding: '.5rem .75rem', borderBottom: '1px solid var(--border-default)' }}>
        {companyName}
      </td>
      <td data-testid={`rollout-outcome-status-${outcome.tenant_id}`} style={{ padding: '.5rem .75rem', borderBottom: '1px solid var(--border-default)' }}>
        <StatusBadge status={outcome.status} domain="rollout-outcome" size="sm" />
      </td>
      <td data-testid={`rollout-outcome-completed-${outcome.tenant_id}`} style={{ padding: '.5rem .75rem', borderBottom: '1px solid var(--border-default)' }}>
        {outcome.completed_at ? formatDateTime(outcome.completed_at) : '—'}
      </td>
      <td data-testid={`rollout-outcome-reason-${outcome.tenant_id}`} style={{ padding: '.5rem .75rem', borderBottom: '1px solid var(--border-default)' }}>
        {outcome.status !== 'succeeded' ? (outcome.reason ?? '') : ''}
      </td>
    </tr>
  )
}

function RolloutOutcomeTable(props: { outcomes: RolloutOutcome[]; tenantNames: Map<string, string> }): React.ReactElement {
  const { outcomes, tenantNames } = props
  return (
    <table data-testid="rollout-outcome-table" style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem' }}>
      <thead>
        <tr>
          <th style={{ textAlign: 'left', padding: '.5rem .75rem', borderBottom: '2px solid var(--border-default)' }}>Company</th>
          <th style={{ textAlign: 'left', padding: '.5rem .75rem', borderBottom: '2px solid var(--border-default)' }}>Outcome</th>
          <th style={{ textAlign: 'left', padding: '.5rem .75rem', borderBottom: '2px solid var(--border-default)' }}>Completed at</th>
          <th style={{ textAlign: 'left', padding: '.5rem .75rem', borderBottom: '2px solid var(--border-default)' }}>Reason</th>
        </tr>
      </thead>
      <tbody>
        {outcomes.map((o) => (
          <RolloutOutcomeRow key={o.tenant_id} outcome={o} tenantNames={tenantNames} />
        ))}
      </tbody>
    </table>
  )
}

export default function PlatformMigrationConsolePage(): React.ReactElement {
  const access = useAccess()
  const isAllowed = access.canManageTenants

  const [searchParams, setSearchParams] = useSearchParams()
  const deepLinkRolloutId = searchParams.get('rollout')

  const [activeRolloutId, setActiveRolloutId] = useState<string | null>(deepLinkRolloutId)
  const [displayResult, setDisplayResult] = useState<RolloutResult | null>(null)
  // §5 — isNoOpResult is evaluated against the START mutation's own response
  // ONLY, never resume/status responses (those always report
  // already_current: false per the design's own verified nuance).
  const [lastStartResult, setLastStartResult] = useState<RolloutResult | null>(null)
  const [lastAction, setLastAction] = useState<LastAction>('none')
  const [startError, setStartError] = useState<ApiError | null>(null)

  const startRollout = useStartRollout()
  const resumeRollout = useResumeRollout()
  const statusQuery = useRolloutStatus(activeRolloutId)
  const tenantNames = useTenantNameLookup()

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  const effectiveResult = displayResult ?? statusQuery.data ?? null

  const handleStartSubmit = (body: StartRolloutRequest) => {
    setStartError(null)
    startRollout.mutate(body, {
      onSuccess: (data) => {
        setActiveRolloutId(data.rollout.id)
        setDisplayResult(data)
        setLastStartResult(data)
        setLastAction('start')
      },
      onError: (err) => {
        setStartError(err)
      },
    })
  }

  const handleResume = () => {
    if (!activeRolloutId) return
    resumeRollout.mutate(activeRolloutId, {
      onSuccess: (data) => {
        setDisplayResult(data)
        setLastAction('resume')
      },
    })
  }

  const handleStartADifferentRollout = () => {
    setActiveRolloutId(null)
    setDisplayResult(null)
    setLastStartResult(null)
    setLastAction('none')
    const next = new URLSearchParams(searchParams)
    next.delete('rollout')
    setSearchParams(next)
  }

  // §1.1 — hide the start form area only while deep-linked and no local
  // start/resume action has happened yet on this page instance.
  const showForm = !deepLinkRolloutId || lastAction !== 'none'

  const showNoOpBanner = lastAction === 'start' && lastStartResult !== null && isNoOpResult(lastStartResult)
  const showFreshRunBanner = lastAction === 'start' && lastStartResult !== null && !isNoOpResult(lastStartResult)
  const freshRunSucceededCount = lastStartResult ? lastStartResult.outcomes.filter((o) => o.status === 'succeeded').length : 0
  const freshRunTotalCount = lastStartResult ? lastStartResult.outcomes.length : 0

  const statusState: RendererState = activeRolloutId
    ? statusQuery.isLoading && !displayResult
      ? 'loading'
      : statusQuery.isError && !displayResult
        ? classifyError(statusQuery.error)
        : 'success'
    : 'success'

  return (
    <PageLayout title="Platform Migrations">
      <div style={{ display: 'flex', flexDirection: 'column', gap: '1.5rem' }}>
        {showForm ? (
          <RolloutStartForm
            disabled={startRollout.isPending || resumeRollout.isPending}
            onSubmit={handleStartSubmit}
          />
        ) : (
          <div>
            <button
              type="button"
              data-testid="rollout-start-different-btn"
              onClick={handleStartADifferentRollout}
              style={{ background: 'none', border: 'none', color: 'var(--interactive-primary)', cursor: 'pointer', padding: 0, fontSize: '.85rem' }}
            >
              Start a different rollout
            </button>
          </div>
        )}

        {startError && (
          <div
            data-testid="rollout-start-error"
            style={{ padding: '.6rem .8rem', background: 'var(--color-error-light)', color: 'var(--color-error-dark)', borderRadius: '4px', fontSize: '.85rem' }}
          >
            The rollout could not be started ({startError.message}). No change was made — try
            again.
          </div>
        )}

        {activeRolloutId && (
          <QueryStateBoundary state={statusState} onRetry={() => { void statusQuery.refetch() }}>
            {effectiveResult && (
              <div data-testid="rollout-status-panel" style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
                <RolloutSummaryHeader rollout={effectiveResult.rollout} />

                {showFreshRunBanner && (
                  <div
                    data-testid="rollout-fresh-run-banner"
                    style={{ padding: '.6rem .8rem', background: 'var(--color-success-light)', color: 'var(--color-success-dark)', borderRadius: '4px', fontSize: '.85rem' }}
                  >
                    Rollout started — {freshRunSucceededCount} of {freshRunTotalCount} companies now hold the
                    change.
                  </div>
                )}

                {showNoOpBanner && (
                  <div
                    data-testid="rollout-noop-banner"
                    style={{ padding: '.6rem .8rem', background: 'var(--color-info-tint)', color: 'var(--color-info-dark)', borderRadius: '4px', fontSize: '.85rem' }}
                  >
                    Every company already holds this change — nothing was applied. This was a
                    repeat submission, not a first run.
                  </div>
                )}

                <RolloutOutcomeTable outcomes={effectiveResult.outcomes} tenantNames={tenantNames} />

                {hasOutstandingCompanies(effectiveResult) && (
                  <div>
                    <Button
                      variant="secondary"
                      size="md"
                      data-testid="rollout-resume-btn"
                      loading={resumeRollout.isPending}
                      disabled={resumeRollout.isPending}
                      onClick={handleResume}
                    >
                      Resume rollout
                    </Button>
                  </div>
                )}
              </div>
            )}
          </QueryStateBoundary>
        )}
      </div>
    </PageLayout>
  )
}
