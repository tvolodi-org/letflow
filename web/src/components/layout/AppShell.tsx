import { useEffect, useState } from 'react'
import { Outlet, NavLink, useLocation } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { P, useAccess, type Permission } from '@/auth/access'
import { ApiConnectivityBanner } from './ApiConnectivityBanner'
import { TestEnvironmentBanner } from './TestEnvironmentBanner'
import { SkipLink } from './SkipLink'
import { TenantHeader } from './TenantHeader'
import { TopBar } from '@/components/ui/TopBar'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { LanguageSwitcher } from '@/components/ui/LanguageSwitcher'
import { UI_LOCALES, UI_LOCALE_LABELS, useUiLocale, useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { navLabel, navMessages } from './navMessages'
import { TenantSwitcher } from '@/auth/TenantSwitcher'
import { dlqApi } from '@/api/dlq'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { useBranding } from '@/theming/BrandingContext'
import { useInstalledModules } from '@/hooks/useInstalledModules'
import { getInstalledImportTypes, getInstalledModuleNavItems } from '@/modules/registry'
import { isModulesUninstallEnabled } from '@/config/modulesUninstallFlag'

export type NavGroup = 'work' | 'tenantAdmin' | 'platform'

/** Sidebar groups in render order (REQ-450). A group renders only when it has a visible entry. */
export const NAV_GROUPS: { id: NavGroup; label: string }[] = [
  { id: 'work', label: 'Work' },
  { id: 'tenantAdmin', label: 'Tenant administration' },
  { id: 'platform', label: 'Platform' },
]

interface NavItem {
  to: string
  label: string
  /** Sidebar group; module entries (no group) go to Work. */
  group: NavGroup
  /** What the server enforces for the page's own calls (see the PR's element-to-permission table). */
  permission: Permission
  /** Also require the platform tenant (platform-only entries). */
  platformOnly?: boolean
  /** Build-time visibility switch, read when the nav is built (REQ-630). */
  enabled?: () => boolean
  /** Hidden when no installed module lists an importable type (REQ-675). */
  needsImportTypes?: boolean
}

export const NAV_ITEMS: NavItem[] = [
  { to: '/instances', group: 'work', label: 'Instances', permission: P.InstancesRead },
  { to: '/tasks', group: 'work', label: 'My Tasks', permission: P.TasksRead },
  { to: '/definitions', group: 'work', label: 'Definitions', permission: P.DefinitionsRead },
  // REQ-398: promotion-review list/queue page. Supersedes ISS-0730 §1's
  // "no nav entry, no contextual link -- direct URL only" decision for
  // PromotionReviewPage.tsx, now that REQ-397's list endpoint exists --
  // that decision's own stated rationale ("no list endpoint exists") no
  // longer holds, and this is a global nav entry to a list page, not the
  // contextual per-definition link ISS-0730 §1 separately declined. Same
  // platform-admin role-only class as REQ-397's server-side authorization and
  // this page's own client-side redirect (ISS-0730 §3.1 pattern, reused).
  { to: '/promotions', group: 'tenantAdmin', label: 'Promotion Reviews', permission: P.PromotionsRead },
  { to: '/dlq', group: 'tenantAdmin', label: 'DLQ', permission: P.DlqOperate },
  { to: '/webhooks', group: 'tenantAdmin', label: 'Webhooks', permission: P.WebhooksManage },
  { to: '/admin/users', group: 'tenantAdmin', label: 'Users', permission: P.UsersGroupsRolesManage },
  { to: '/admin/groups', group: 'tenantAdmin', label: 'Groups', permission: P.UsersGroupsRolesManage },
  { to: '/admin/tokens', group: 'tenantAdmin', label: 'Tokens', permission: P.TokensManage },
  { to: '/admin/audit', group: 'tenantAdmin', label: 'Audit', permission: P.AuditRead },
  { to: '/admin/print-templates', group: 'tenantAdmin', label: 'Print Templates', permission: P.DocumentPrintTemplatesManage },
  { to: '/admin/import', group: 'tenantAdmin', label: 'Import data', permission: P.EntitiesRecordsImport, needsImportTypes: true },
  { to: '/admin/module-lifecycle', group: 'tenantAdmin', label: 'Module lifecycle', permission: P.ModulesManage, enabled: isModulesUninstallEnabled },
  { to: '/admin/health', group: 'platform', label: 'Health', permission: P.TenantsManage, platformOnly: true },
  { to: '/admin/metrics', group: 'tenantAdmin', label: 'Metrics', permission: P.MetricsRead },
  { to: '/admin/onboarding/new', group: 'platform', label: 'Register Tenant', permission: P.TenantsManage, platformOnly: true },
  { to: '/admin/tenants', group: 'platform', label: 'Tenants', permission: P.TenantsManage, platformOnly: true },
  { to: '/admin/services', group: 'platform', label: 'Services', permission: P.PlatformServicesManage, platformOnly: true },
  // REQ-375: operator-facing rollout-status screen for REQ-374's
  // platform-wide tenant-migration fanout runner. Same :TenantsManage
  // (platform-admin role-only) risk class as admin/tenants, admin/onboarding.
  { to: '/admin/platform-migrations', group: 'platform', label: 'Platform Migrations', permission: P.TenantsManage, platformOnly: true },
  // REQ-381: solution-pack update review screen. `/solution-packs` needs a
  // discoverable nav link (unlike PromotionReviewPage.tsx's deliberate
  // no-nav-entry choice) -- REQ-381's own text requires the review screen
  // be "reachable from the company's pack screen," and the launcher page
  // serves that role (design §7). platform-admin role-only, same OQ-3 judgment
  // call as the launcher/review pages' own role gate (design §4.1).
  { to: '/solution-packs', group: 'tenantAdmin', label: 'Solution Packs', permission: P.ModulesManage },
  // REQ-377: operator-facing history-retirement screen for REQ-376's
  // whole-partition retirement mechanism. Same :TenantsManage
  // (platform-admin role-only) risk class as admin/platform-migrations.
  { to: '/admin/event-retention', group: 'platform', label: 'Event Retention', permission: P.TenantsManage, platformOnly: true },
]

export function AppShell() {
  const { session, logout } = useAuth()
  const uiLocale = useUiLocale()
  const setUiLocale = useUiLocaleStore((s) => s.setLocale)
  const access = useAccess()
  const tenantKeys = useTenantScopedQueryKeys()
  const { appName, logoUrl } = useBranding()
  const [navOpen, setNavOpen] = useState(false)
  const { pathname } = useLocation()
  // The drawer closes on navigation and on Escape.
  useEffect(() => setNavOpen(false), [pathname])
  useEffect(() => {
    if (!navOpen) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setNavOpen(false)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [navOpen])
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
  const hasImportTypes = getInstalledImportTypes(installedModules).length > 0
  // Nothing gated renders until /me/access is ready: can() is false while loading or failed.
  const visibleNav = [
    ...NAV_ITEMS,
    ...moduleNavItems.map((n) => ({ ...n, group: 'work' as const })),
  ].filter((n) => access.can(n.permission) && (!('enabled' in n) || !n.enabled || n.enabled()) && (!('needsImportTypes' in n) || !n.needsImportTypes || hasImportTypes) && (!n.platformOnly || access.isPlatformTenant))
  const visibleGroups = NAV_GROUPS
    .map((g) => ({ ...g, items: visibleNav.filter((n) => n.group === g.id) }))
    .filter((g) => g.items.length > 0)

  return (
    <div className={navOpen ? 'lf-app is-nav-open' : 'lf-app'}>
      <SkipLink label="Skip to main content" />
      {/* Sidebar: night in both themes; a drawer under 900px (is-nav-open on .lf-app). */}
      <aside className="lf-sidenav lf-night" id="app-sidenav" data-testid="sidenav">
        <div className="lf-sidenav__brand">
          <div className="lf-sidenav__tenant">
            {logoUrl != null && <img src={logoUrl} alt={appName} height={24} />}
            {appName}
          </div>
          <TenantHeader />
          <TenantSwitcher />
        </div>

        <nav aria-label="Main">
          {visibleGroups.map((g) => (
            <div key={g.id} className="lf-sidenav__group" role="group" aria-label={navMessages[uiLocale].groups[g.id]} data-testid={`nav-group-${g.id}`}>
              <div className="lf-sidenav__label">{navMessages[uiLocale].groups[g.id]}</div>
              {g.items.map((n) => (
                <NavLink key={n.to} to={n.to} className="lf-sidenav__item">
                  <span>{navLabel(uiLocale, n.to, n.label)}</span>
                  {n.to === '/dlq' && dlqSeverity !== 'none' && (
                    <span
                      className={dlqSeverity === 'critical' ? 'lf-pill lf-pill--danger' : 'lf-pill lf-pill--warning'}
                      aria-label={`DLQ pending count ${pendingDlqCount}`}
                    >
                      {pendingDlqCount}
                    </span>
                  )}
                </NavLink>
              ))}
            </div>
          ))}
        </nav>

        <div className="lf-sidenav__foot">
          <div data-testid="user-display-name">{session?.display_name}</div>
          <div data-testid="user-roles">{access.roles.join(', ')}</div>
          <div className="lf-btn-row">
            <button type="button" data-testid="logout-button" className="lf-btn lf-btn--ghost lf-btn--s" onClick={logout}>
              Sign out
            </button>
            <ThemeToggle />
          </div>
        </div>
      </aside>
      {navOpen && <div className="lf-scrim" data-testid="nav-scrim" onClick={() => setNavOpen(false)} aria-hidden="true" />}

      <div className="lf-main">
        <TopBar
          menuOpen={navOpen}
          onMenuToggle={() => setNavOpen((o) => !o)}
          menuControls="app-sidenav"
          end={
            <LanguageSwitcher
              locales={UI_LOCALES.map((code) => ({ code, label: UI_LOCALE_LABELS[code] }))}
              current={uiLocale}
              onChange={(code) => setUiLocale(code as (typeof UI_LOCALES)[number])}
            />
          }
        />
        <main id="main-content" className="lf-content" tabIndex={-1}>
          <TestEnvironmentBanner />
          <ApiConnectivityBanner />
          <Outlet />
        </main>
      </div>
    </div>
  )
}
