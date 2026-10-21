import { Navigate, Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAccess, AccessPending } from '@/auth/access'
import { tenantsApi, type TenantListResponse } from '@/api/tenants'
import { queryKeys } from '@/api/queryKeys'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import type { ApiError } from '@/types/api'

/**
 * PlatformDashboardPage (REQ-369) -- platform-wide landing page for
 * platform-admin role, reached from OidcCallbackPage's role-conditional redirect.
 * Deliberately platform-scoped: no tenant context, no tenant-branded copy.
 * See lib/letflow/design/req369-platform-dashboard-page.md.
 *
 * Tenant-count tile reads `count` from tenantsApi.list()'s real response
 * envelope (ISS-0711 fix). This comment trips CD's per-commit path filter
 * so QA's next deploy actually picks up that fix's own commit -- CI never
 * succeeded on that commit's own diff (it hit the ISS-0712 vocabulary bug
 * fixed separately), so no deploy was ever triggered for it directly.
 */
export default function PlatformDashboardPage(): JSX.Element {
  const tenantsQuery = useQuery<TenantListResponse, ApiError>({
    queryKey: queryKeys.admin.tenants({}),
    queryFn: () => tenantsApi.list(),
  })

  const access = useAccess()
  const isAllowed = access.canManageTenants

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  const rendererState: RendererState = tenantsQuery.isLoading
    ? 'loading'
    : tenantsQuery.isError
      ? classifyError(tenantsQuery.error)
      : 'success'

  return (
    <div style={{ padding: '2rem', maxWidth: '900px' }}>
      <h1
        data-testid="platform-dashboard-heading"
        style={{ fontSize: '1.75rem', fontWeight: 700, color: 'var(--text-primary)', marginBottom: '1.5rem' }}
      >
        Platform Overview
      </h1>

      <QueryStateBoundary state={rendererState} onRetry={() => { void tenantsQuery.refetch() }}>
        <div
          data-testid="tile-tenant-count"
          style={{
            background: 'var(--surface-card)',
            border: '1px solid var(--border-default)',
            borderRadius: '8px',
            padding: '1.25rem',
            boxShadow: 'var(--shadow-card)',
            maxWidth: '260px',
            marginBottom: '2rem',
          }}
        >
          <div style={{ fontSize: '.75rem', fontWeight: 600, color: 'var(--text-secondary)', textTransform: 'uppercase', marginBottom: '.75rem' }}>
            Tenants
          </div>
          <div style={{ fontSize: '2.25rem', fontWeight: 700, color: 'var(--color-info)' }}>
            {String(tenantsQuery.data?.count ?? 0)}
          </div>
        </div>
      </QueryStateBoundary>

      <div style={{ fontSize: '.75rem', fontWeight: 600, color: 'var(--text-secondary)', textTransform: 'uppercase', marginBottom: '.75rem' }}>
        Platform Admin Links
      </div>
      <nav data-testid="platform-quick-links" style={{ display: 'flex', flexDirection: 'column', gap: '.5rem' }}>
        <Link to="/admin/tenants">Tenants</Link>
        <Link to="/admin/services">Services</Link>
        <Link to="/admin/health">Health</Link>
        <Link to="/admin/metrics">Metrics</Link>
        <Link to="/admin/users">Users</Link>
      </nav>
    </div>
  )
}
