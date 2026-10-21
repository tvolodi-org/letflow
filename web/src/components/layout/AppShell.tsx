import { Outlet, NavLink } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { P, useAccess, type Permission } from '@/auth/access'
import { ApiConnectivityBanner } from './ApiConnectivityBanner'
import { TestEnvironmentBanner } from './TestEnvironmentBanner'
import { TenantHeader } from './TenantHeader'
import { TenantSwitcher } from '@/auth/TenantSwitcher'
import { dlqApi } from '@/api/dlq'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { useBranding } from '@/theming/BrandingContext'
import { useInstalledModules } from '@/hooks/useInstalledModules'
import { getInstalledModuleNavItems } from '@/modules/registry'

interface NavItem {
  to: string
  label: string
  /** What the server enforces for the page's own calls (see the PR's element-to-permission table). */
  permission: Permission
  /** Also require the platform tenant (platform-only entries). */
  platformOnly?: boolean
}

const NAV_ITEMS: NavItem[] = [
  { to: '/instances',     label: 'Instances', permission: P.InstancesRead },
  { to: '/tasks',         label: 'My Tasks', permission: P.TasksRead },
  { to: '/definitions',  label: 'Definitions', permission: P.DefinitionsRead },
  // REQ-398: promotion-review list/queue page. Supersedes ISS-0730 §1's
  // "no nav entry, no contextual link -- direct URL only" decision for
  // PromotionReviewPage.tsx, now that REQ-397's list endpoint exists --
  // that decision's own stated rationale ("no list endpoint exists") no
  // longer holds, and this is a global nav entry to a list page, not the
  // contextual per-definition link ISS-0730 §1 separately declined. Same
  // platform-admin role-only class as REQ-397's server-side authorization and
  // this page's own client-side redirect (ISS-0730 §3.1 pattern, reused).
  { to: '/promotions',   label: 'Promotion Reviews', permission: P.PromotionsRead },
  { to: '/dlq',           label: 'DLQ', permission: P.DlqOperate },
  { to: '/webhooks',      label: 'Webhooks', permission: P.WebhooksManage },
  { to: '/admin/users',   label: 'Users', permission: P.UsersGroupsRolesManage },
  { to: '/admin/groups',  label: 'Groups', permission: P.UsersGroupsRolesManage },
  { to: '/admin/tokens',  label: 'Tokens', permission: P.TokensManage },
  { to: '/admin/audit',   label: 'Audit', permission: P.AuditRead },
  { to: '/admin/health',  label: 'Health', permission: P.TenantsManage, platformOnly: true },
  { to: '/admin/metrics', label: 'Metrics', permission: P.MetricsRead },
  { to: '/admin/onboarding/new', label: 'Register Tenant', permission: P.TenantsManage, platformOnly: true },
  { to: '/admin/tenants',       label: 'Tenants', permission: P.TenantsManage, platformOnly: true },
  { to: '/admin/services',       label: 'Services', permission: P.PlatformServicesManage, platformOnly: true },
  // REQ-375: operator-facing rollout-status screen for REQ-374's
  // platform-wide tenant-migration fanout runner. Same :TenantsManage
  // (platform-admin role-only) risk class as admin/tenants, admin/onboarding.
  { to: '/admin/platform-migrations', label: 'Platform Migrations', permission: P.TenantsManage, platformOnly: true },
  // REQ-381: solution-pack update review screen. `/solution-packs` needs a
  // discoverable nav link (unlike PromotionReviewPage.tsx's deliberate
  // no-nav-entry choice) -- REQ-381's own text requires the review screen
  // be "reachable from the company's pack screen," and the launcher page
  // serves that role (design §7). platform-admin role-only, same OQ-3 judgment
  // call as the launcher/review pages' own role gate (design §4.1).
  { to: '/solution-packs', label: 'Solution Packs', permission: P.ModulesManage },
  // REQ-377: operator-facing history-retirement screen for REQ-376's
  // whole-partition retirement mechanism. Same :TenantsManage
  // (platform-admin role-only) risk class as admin/platform-migrations.
  { to: '/admin/event-retention', label: 'Event Retention', permission: P.TenantsManage, platformOnly: true },
]

export function AppShell() {
  const { session, logout } = useAuth()
  const access = useAccess()
  const tenantKeys = useTenantScopedQueryKeys()
  const { appName, logoUrl } = useBranding()
  const { data: installedModules = [] } = useInstalledModules()

  const dlqThreshold = Number(import.meta.env.VITE_DLQ_ALERT_THRESHOLD ?? '10')
  const { data: dlqSummary } = useQuery({
    queryKey: tenantKeys.dlq.list({ status: 'pending', page_size: 101 }),
    queryFn: () => dlqApi.list({ status: 'pending', page_size: 101 }),
    refetchInterval: 15000,
    enabled: access.can(P.DlqOperate),
  })

  const pendingDlqCount = dlqSummary?.items?.length ?? 0
  const dlqSeverity = pendingDlqCount <= 0 ? 'none' : (pendingDlqCount > dlqThreshold ? 'critical' : 'warning')

  const moduleNavItems = getInstalledModuleNavItems(installedModules)
  // Nothing gated renders until /me/access is ready: can() is false while loading or failed.
  const visibleNav = [...NAV_ITEMS, ...moduleNavItems].filter(
    (n) => access.can(n.permission) && (!n.platformOnly || access.isPlatformTenant),
  )

  return (
    <div style={{ display: 'flex', minHeight: '100vh', fontFamily: 'system-ui, sans-serif' }}>
      {/* Sidebar */}
      <aside
        style={{
          width: '220px',
          background: 'var(--surface-sidebar)',
          color: 'var(--color-neutral-400)',
          display: 'flex',
          flexDirection: 'column',
          padding: '1.5rem 0',
          flexShrink: 0,
        }}
      >
        <div style={{ padding: '0 1.25rem', marginBottom: '1.5rem', display: 'flex', alignItems: 'center', gap: '.5rem', fontWeight: 700, fontSize: '1.1rem', color: 'var(--color-neutral-100)' }}>
          {logoUrl != null && (
            <img src={logoUrl} alt={appName} style={{ height: '1.5rem', width: 'auto' }} />
          )}
          {appName}
        </div>

        <TenantHeader />
        <TenantSwitcher />

        <nav style={{ flex: 1 }}>
          {visibleNav.map((n) => (
            <NavLink
              key={n.to}
              to={n.to}
              style={({ isActive }) => ({
                display: 'block',
                padding: '.5rem 1.25rem',
                color: isActive ? 'var(--color-neutral-100)' : 'var(--color-neutral-500)',
                background: isActive ? 'var(--color-sidebar-active)' : 'transparent',
                textDecoration: 'none',
                fontSize: '.9rem',
                borderLeft: isActive ? '3px solid var(--interactive-primary)' : '3px solid transparent',
              })}
            >
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: '.5rem' }}>
                {n.label}
                {n.to === '/dlq' && dlqSeverity !== 'none' && (
                  <span
                    style={{
                      minWidth: '1.25rem',
                      padding: '0 .35rem',
                      borderRadius: '999px',
                      fontSize: '.72rem',
                      lineHeight: '1.15rem',
                      textAlign: 'center',
                      fontWeight: 700,
                      color: 'var(--text-primary)',
                      background: dlqSeverity === 'critical' ? 'var(--color-error)' : 'var(--color-warning)',
                    }}
                    aria-label={`DLQ pending count ${pendingDlqCount}`}
                  >
                    {pendingDlqCount}
                  </span>
                )}
              </span>
            </NavLink>
          ))}
        </nav>

        <div style={{ padding: '.75rem 1.25rem', borderTop: '1px solid var(--color-sidebar-active)', fontSize: '.8rem', color: 'var(--text-secondary)' }}>
          <div
            data-testid="user-display-name"
            style={{ marginBottom: '.25rem', color: 'var(--color-neutral-500)' }}
          >
            {session?.display_name}
          </div>
          <div
            data-testid="user-roles"
            style={{ marginBottom: '.5rem', color: 'var(--text-secondary)', fontSize: '.75rem' }}
          >
            {access.roles.join(', ')}
          </div>
          <button
            data-testid="logout-button"
            onClick={logout}
            style={{ background: 'none', border: 'none', color: 'var(--text-secondary)', cursor: 'pointer', padding: 0, fontSize: '.8rem' }}
          >
            Sign out
          </button>
        </div>
      </aside>

      {/* Main content */}
      <main style={{ flex: 1, overflow: 'auto', background: 'var(--surface-page)' }}>
        <TestEnvironmentBanner />
        <ApiConnectivityBanner />
        <Outlet />
      </main>
    </div>
  )
}
