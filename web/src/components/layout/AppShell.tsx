import { ToastContainer } from '@/components/ui/Toast'
import { useEffect, useRef, useState } from 'react'
import { Link, Outlet, NavLink, useLocation } from 'react-router-dom'
import { ChevronsLeft, SlidersHorizontal } from 'lucide-react'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { P, useAccess, type Permission } from '@/auth/access'
import { ApiConnectivityBanner } from './ApiConnectivityBanner'
import { SessionNotice } from './SessionNotice'
import { TestEnvironmentBanner } from './TestEnvironmentBanner'
import { SkipLink } from './SkipLink'
import { TenantHeader } from './TenantHeader'
import { TopBar } from '@/components/ui/TopBar'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { LanguageSwitcher } from '@/components/ui/LanguageSwitcher'
import { UI_LOCALES, UI_LOCALE_LABELS, useUiLocale, useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { navLabel, navMessages } from './navMessages'
import { mySettingsMessages } from '@/pages/me/mySettingsMessages'
import { TenantSwitcher } from '@/auth/TenantSwitcher'
import { dlqApi } from '@/api/dlq'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { useBranding } from '@/theming/BrandingContext'
import { useInstalledModules } from '@/hooks/useInstalledModules'
import { getImportTypesFor, getInstalledModuleNavItems } from '@/modules/registry'
import { isModulesUninstallEnabled } from '@/config/modulesUninstallFlag'
import { useLayoutPrefs } from '@/hooks/useLayoutPrefs'
import { useSplit } from '@/components/ui/layout/Splitter'
import { layoutMessages } from '@/components/ui/layout/layoutMessages'
import { NavIcon } from './navIcons'
import { NotificationBell } from './NotificationBell'
import { visibleNavGroups, type NavGroup, type NavItem } from './navVisibility'

const NARROW_QUERY = '(max-width: 900px)'
const isNarrow = () => typeof window !== 'undefined' && !!window.matchMedia && window.matchMedia(NARROW_QUERY).matches
/** Width of the collapsed side nav: the design token, read from the computed style (64 px fallback). */
const collapsedNavWidth = () => {
  if (typeof document === 'undefined') return 64
  const v = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--sidenav-collapsed-width'))
  return Number.isFinite(v) ? v : 64
}

export type { NavGroup }

/** Sidebar groups in render order (REQ-450). A group renders only when it has a visible entry. */
export const NAV_GROUPS: { id: NavGroup; label: string }[] = [
  { id: 'work', label: 'Work' },
  { id: 'tenantAdmin', label: 'Tenant administration' },
  { id: 'platform', label: 'Platform' },
]

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
  { to: '/admin/module-rollouts', group: 'platform', label: 'Module rollouts', permission: P.ModuleRolloutsManage, platformOnly: true },
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

/** `fluid` lets the content fill wide windows (`lf-content--fluid`: no `--content-max-width` cap, clamp-token panes).
 *  Default off: prose and short forms keep the capped column; data screens opt in (I2..I5 decide how). */
/** Data screens that fill wide windows (one path per line, so sibling screens add theirs without a conflict). */
const FLUID_PATHS = [
  '/admin/catalog/items',
  '/admin/stock/movements',
  '/admin/stock/balances',
]

export function AppShell({ fluid: fluidProp = false }: { fluid?: boolean } = {}) {
  const { session, logout } = useAuth()
  const uiLocale = useUiLocale()
  const setUiLocale = useUiLocaleStore((s) => s.setLocale)
  const access = useAccess()
  const tenantKeys = useTenantScopedQueryKeys()
  const { appName, logoUrl } = useBranding()
  const [navOpen, setNavOpen] = useState(false)
  // Side nav: collapsed flag and width are remembered (ui.layout, shell.sidenav); the drawer under 900 px is unchanged.
  const store = useLayoutPrefs()
  const lm = layoutMessages[uiLocale]
  const appRef = useRef<HTMLDivElement>(null)
  const layerRef = useRef<HTMLDivElement>(null)
  const [navCollapsed, setNavCollapsed] = useState(() => !!store.getShell().collapsed)
  const [narrow, setNarrow] = useState(isNarrow)
  useEffect(() => {
    if (!window.matchMedia) return
    const mq = window.matchMedia(NARROW_QUERY)
    const on = () => setNarrow(mq.matches)
    mq.addEventListener?.('change', on)
    return () => mq.removeEventListener?.('change', on)
  }, [])
  const navSplit = useSplit(appRef, layerRef, {
    id: 'sidenav',
    shell: true,
    unit: 'px',
    vars: ['--sidenav-width'],
    sized: 'before',
    min: [200],
    max: [360],
    flexMin: 320,
    collapsible: [0],
    collapsedSize: collapsedNavWidth(),
    labels: [lm.navResize],
    panes: () => [document.getElementById('app-sidenav'), document.getElementById('app-main')],
    enabled: () => !isNarrow(),
    onCollapse: (c) => setNavCollapsed(!!c[0]),
  })
  const navState = narrow || !navCollapsed ? 'expanded' : 'collapsed'
  const { pathname } = useLocation()
  const fluid = fluidProp || FLUID_PATHS.some((p) => pathname === p || pathname.startsWith(`${p}/`))
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
  const importTypeCount = getImportTypesFor(installedModules, (p) => access.can(p as Permission)).length
  // Nothing gated renders until /me/access is ready: can() is false while loading or failed.
  const visibleGroups = visibleNavGroups({
    groups: NAV_GROUPS,
    items: NAV_ITEMS,
    moduleItems: moduleNavItems,
    can: (p) => access.can(p as Permission),
    isPlatformTenant: access.isPlatformTenant,
    importTypeCount,
  })

  return (
    <div ref={appRef} className={navOpen ? 'lf-app is-nav-open' : 'lf-app'} data-nav={navState}>
      <SkipLink label="Skip to main content" />
      {/* Sidebar: night in both themes; a drawer under 900px (is-nav-open on .lf-app). */}
      <aside className="lf-sidenav lf-night" id="app-sidenav" aria-label={navMessages[uiLocale].sidebar} data-testid="sidenav">
        <div className="lf-sidenav__brand">
          <div className="lf-sidenav__tenant">
            {logoUrl != null && <img src={logoUrl} alt={appName} height={24} />}
            {appName}
          </div>
          <TenantHeader />
          <TenantSwitcher />
        </div>

        <nav aria-label={navMessages[uiLocale].mainNav}>
          {visibleGroups.map((g) => (
            <div key={g.id} className="lf-sidenav__group" role="group" aria-label={navMessages[uiLocale].groups[g.id]} data-testid={`nav-group-${g.id}`}>
              <div className="lf-sidenav__label">{navMessages[uiLocale].groups[g.id]}</div>
              {g.items.map((n) => (
                <NavLink key={n.to} to={n.to} className="lf-sidenav__item" title={navLabel(uiLocale, n.to, n.label)}>
                  <NavIcon to={n.to} label={navLabel(uiLocale, n.to, n.label)} />
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
          <button
            type="button"
            className="lf-sidenav__toggle"
            data-testid="sidenav-toggle"
            aria-expanded={navState === 'expanded'}
            aria-controls="app-sidenav"
            aria-label={navState === 'collapsed' ? lm.navExpand : lm.navCollapse}
            title={navState === 'collapsed' ? lm.navExpand : lm.navCollapse}
            onClick={() => navSplit.current?.toggle(0)}
          >
            <ChevronsLeft className="lf-icon" aria-hidden="true" />
            {navState === 'expanded' && <span>{lm.navCollapse}</span>}
          </button>
          <div data-testid="user-display-name">{session?.display_name}</div>
          <div data-testid="user-roles">{access.roles.join(', ')}</div>
          <div className="lf-btn-row">
            <button type="button" data-testid="logout-button" className="lf-btn lf-btn--ghost lf-btn--s" onClick={logout}>
              {navMessages[uiLocale].signOut}
            </button>
            <button
              type="button"
              data-testid="reset-layout-all"
              className="lf-btn lf-btn--ghost lf-btn--s"
              title={lm.resetLayoutHint}
              onClick={() => store.resetAll()}
            >
              {lm.resetLayout}
            </button>
            <ThemeToggle />
          </div>
        </div>
      </aside>
      {navOpen && <div className="lf-scrim" data-testid="nav-scrim" onClick={() => setNavOpen(false)} aria-hidden="true" />}

      <div className="lf-main" id="app-main">
        <TopBar
          menuOpen={navOpen}
          onMenuToggle={() => setNavOpen((o) => !o)}
          menuControls="app-sidenav"
          end={
            <>
              <NotificationBell />
              <Link
                to="/me/settings"
                className="lf-btn lf-btn--ghost lf-btn--icon"
                aria-label={mySettingsMessages[uiLocale].link}
                title={mySettingsMessages[uiLocale].link}
                data-testid="topbar-my-settings"
              >
                <SlidersHorizontal className="lf-icon" aria-hidden="true" />
              </Link>
              <LanguageSwitcher
                locales={UI_LOCALES.map((code) => ({ code, label: UI_LOCALE_LABELS[code] }))}
                current={uiLocale}
                onChange={(code) => setUiLocale(code as (typeof UI_LOCALES)[number])}
              />
            </>
          }
        />
        <main id="main-content" className={fluid ? 'lf-content lf-content--fluid' : 'lf-content'} tabIndex={-1}>
          <TestEnvironmentBanner />
          <SessionNotice />
          <ApiConnectivityBanner />
          <Outlet />
        </main>
      </div>
      <ToastContainer />
      <div className="lf-split-layer" ref={layerRef} />
    </div>
  )
}
