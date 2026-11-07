import { useQuery } from '@tanstack/react-query'
import { P, useAccess } from '@/auth/access'
import { useTenantContext } from '@/auth/useTenantContext'
import { definitionsApi } from '@/api/definitions'
import { instancesApi } from '@/api/instances'
import { tasksApi } from '@/api/tasks'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'

function SkeletonBox(): JSX.Element {
  return (
    <div
      style={{
        height: '4rem',
        background: 'var(--color-neutral-200)',
        borderRadius: '6px',
        animation: 'pulse 1.5s ease-in-out infinite',
      }}
    />
  )
}

export default function TenantDashboardPage(): JSX.Element {
  const { tenantDisplayName, isUnknown } = useTenantContext()
  const tenantKeys = useTenantScopedQueryKeys()
  const access = useAccess()
  // A role without DefinitionsRead (the storekeeper) would get 403 here and lose the whole dashboard.
  const canReadDefinitions = access.isReady && access.can(P.DefinitionsRead)

  const { data: definitions, isLoading: loadingDefs, isError: errorDefs, error: defsError, refetch: refetchDefs } = useQuery({
    queryKey: tenantKeys.definitions.list({ page_size: 5 }),
    queryFn: () => definitionsApi.list({ page_size: 5 }),
    enabled: canReadDefinitions,
  })

  const { data: instances, isLoading: loadingInstances } = useQuery({
    queryKey: tenantKeys.instances.list({ status: ['ACTIVE'], page_size: 1 }),
    queryFn: () => instancesApi.list({ status: ['ACTIVE'], page_size: 1 }),
  })

  const { data: tasks, isLoading: loadingTasks } = useQuery({
    queryKey: tenantKeys.tasks.list({ status: 'PENDING', page_size: 1 }),
    queryFn: () => tasksApi.list({ status: 'PENDING', page_size: 1 }),
  })

  const rendererState: RendererState = !canReadDefinitions ? 'success' : loadingDefs ? 'loading' : errorDefs ? classifyError(defsError) : 'success'

  return (
    <div style={{ padding: '2rem', maxWidth: '900px' }}>
      <h1
        data-testid="tenant-dashboard-heading"
        style={{ fontSize: '1.75rem', fontWeight: 700, color: 'var(--text-primary)', marginBottom: '0.5rem' }}
      >
        {tenantDisplayName}
      </h1>

      <p style={{ color: 'var(--text-secondary)', marginBottom: '2rem' }}>
        Welcome to your BPM workspace. Here is a summary of your current activity.
      </p>

      {isUnknown && (
        <div
          data-testid="tenant-unknown-banner"
          style={{
            marginBottom: '1.5rem',
            padding: '.75rem 1rem',
            background: 'var(--color-warning-light)',
            border: '1px solid var(--color-warning-border)',
            borderRadius: '6px',
            color: 'var(--color-warning-text)',
            fontSize: '.875rem',
          }}
        >
          Tenant name could not be loaded. Contact your administrator.
        </div>
      )}

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetchDefs() }}
        columns={[{ widthPercent: 33 }, { widthPercent: 33 }, { widthPercent: 34 }]}
      >
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '1.25rem' }}>
        {/* Recent Definitions */}
        {canReadDefinitions && (
        <div
          data-testid="tile-definitions"
          style={{
            background: 'var(--surface-card)',
            border: '1px solid var(--border-default)',
            borderRadius: '8px',
            padding: '1.25rem',
            boxShadow: 'var(--shadow-card)',
          }}
        >
          <div style={{ fontSize: '.75rem', fontWeight: 600, color: 'var(--text-secondary)', textTransform: 'uppercase', marginBottom: '.75rem' }}>
            Recent Definitions
          </div>
          {loadingDefs ? (
            <SkeletonBox />
          ) : (
            <div>
              {(definitions?.items ?? []).slice(0, 5).map((d) => (
                <div
                  key={d.id}
                  style={{ fontSize: '.875rem', color: 'var(--text-primary)', padding: '.25rem 0', borderBottom: '1px solid var(--color-neutral-100)' }}
                >
                  {d.name}
                </div>
              ))}
              {(!definitions?.items || definitions.items.length === 0) && (
                <div style={{ color: 'var(--text-disabled)', fontSize: '.875rem' }}>No definitions yet.</div>
              )}
            </div>
          )}
        </div>
        )}

        {/* Active Instances */}
        <div
          data-testid="tile-instances"
          style={{
            background: 'var(--surface-card)',
            border: '1px solid var(--border-default)',
            borderRadius: '8px',
            padding: '1.25rem',
            boxShadow: 'var(--shadow-card)',
          }}
        >
          <div style={{ fontSize: '.75rem', fontWeight: 600, color: 'var(--text-secondary)', textTransform: 'uppercase', marginBottom: '.75rem' }}>
            Active Instances
          </div>
          {loadingInstances ? (
            <SkeletonBox />
          ) : (
            <div
              data-testid="tile-instances-count"
              style={{ fontSize: '2.25rem', fontWeight: 700, color: 'var(--color-info)' }}
            >
              {instances?.items?.length ?? 0}
            </div>
          )}
        </div>

        {/* Pending Tasks */}
        <div
          data-testid="tile-tasks"
          style={{
            background: 'var(--surface-card)',
            border: '1px solid var(--border-default)',
            borderRadius: '8px',
            padding: '1.25rem',
            boxShadow: 'var(--shadow-card)',
          }}
        >
          <div style={{ fontSize: '.75rem', fontWeight: 600, color: 'var(--text-secondary)', textTransform: 'uppercase', marginBottom: '.75rem' }}>
            Pending Tasks
          </div>
          {loadingTasks ? (
            <SkeletonBox />
          ) : (
            <div
              data-testid="tile-tasks-count"
              style={{ fontSize: '2.25rem', fontWeight: 700, color: 'var(--color-warning-dark)' }}
            >
              {tasks?.items?.length ?? 0}
            </div>
          )}
        </div>
      </div>
      </QueryStateBoundary>
    </div>
  )
}
