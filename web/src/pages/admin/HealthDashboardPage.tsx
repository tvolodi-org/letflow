import { Navigate } from 'react-router-dom'
import { useQuery, type UseQueryResult } from '@tanstack/react-query'
import { healthReady } from '@/api/health'
import { queryKeys } from '@/api/queryKeys'
import { useAccess, AccessPending } from '@/auth/access'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { formatTime } from '@/i18n/format'

// NOTE (ISS-0532): this page used to render per-subsystem `database`/
// `scheduler` status sourced from `GET /health/ready`, a route the backend
// does not serve (see `docs/frontend/contract-gaps.md` row 15 — readiness
// requires S6 observability probes that do not exist yet). That 404 was
// silently mapped into a fabricated "degraded" snapshot with invented
// component statuses. Rather than keep inventing subsystem data the backend
// cannot provide, this page now degrades to an honest liveness-only view,
// backed by the real `GET /health` endpoint, and says plainly that
// per-subsystem readiness is not available yet.
export function useAdminHealthSnapshot(): UseQueryResult<boolean> {
  return useQuery({
    queryKey: queryKeys.admin.health(),
    queryFn: () => healthReady(),
    refetchInterval: 15_000,
  })
}

export default function HealthDashboardPage() {
  const access = useAccess()
  const isAllowed = access.canManageTenants
  const { data: isLive, isLoading, isFetching, isError, error, dataUpdatedAt, refetch } = useAdminHealthSnapshot()

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'
  const livenessLabel = isLive ? 'LIVE' : 'UNREACHABLE'
  const livenessColor = isLive ? 'var(--color-success-dark)' : 'var(--color-error-dark)'

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '1rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Health</h2>
        {dataUpdatedAt > 0 && (
          <span style={{ fontSize: 'var(--text-xs)', color: 'var(--text-secondary)' }}>
            Updated {formatTime(dataUpdatedAt)}
          </span>
        )}
        {isFetching && <span style={{ fontSize: 'var(--text-xs)', color: 'var(--color-info-dark)' }}>Refreshing…</span>}
        <span style={{ marginLeft: 'auto' }}>
          <Button variant="secondary" size="sm" onClick={() => { void refetch() }}>
            Refresh now
          </Button>
        </span>
      </div>

      <QueryStateBoundary state={rendererState} onRetry={() => { void refetch() }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1.25rem' }}>
          <span
            data-testid="liveness-badge"
            style={{ fontWeight: 700, fontSize: 'var(--text-lg)', color: livenessColor }}
          >
            {livenessLabel}
          </span>
          <span style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>Backend liveness (GET /health)</span>
        </div>

        <div
          data-testid="readiness-not-available"
          role="status"
          style={{
            padding: '.9rem 1rem',
            borderRadius: 'var(--radius-sm)',
            border: '1px solid var(--border-default)',
            background: 'var(--surface-page)',
            color: 'var(--text-secondary)',
            fontSize: 'var(--text-sm)',
          }}
        >
          Per-subsystem readiness (database, scheduler) is not available yet —
          it requires observability instrumentation planned for a later stage
          (S6) that has not been built. This page currently reports basic
          backend liveness only, from the real <code>GET /health</code>{' '}
          endpoint.
        </div>
      </QueryStateBoundary>
    </div>
  )
}
