import type { ReactNode } from 'react'
import { createBrowserRouter } from 'react-router-dom'
import { ProtectedRoute } from '@/auth/ProtectedRoute'
import { P, RequirePermission, type Permission } from '@/auth/access'
import OidcCallbackPage from '@/pages/OidcCallbackPage'
import { LoginRoute } from '@/pages/LoginPage'
import { AuthenticatedShellRoot } from '@/components/layout/AuthenticatedShellRoot'
// ISS-0822: ProcessModulesPage import removed — Letflow.Routers.ProcessModules is
// deferred to S5 (process-module packaging); no backend is mounted and the page
// would 404 on every request. Route removed until S5 is implemented.
import TenantDashboardPage from '@/pages/dashboard/TenantDashboardPage'
import PlatformDashboardPage from '@/pages/dashboard/PlatformDashboardPage'
import DefinitionListPage from '@/pages/definitions/DefinitionListPage'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'
import PromotionReviewPage from '@/pages/definitions/PromotionReviewPage'
import PromotionReviewListPage from '@/pages/promotions/PromotionReviewListPage'
import DefinitionRollbackPage from '@/pages/definitions/DefinitionRollbackPage'
import InstanceBoardPage from '@/pages/instances/InstanceBoardPage'
import InstanceDetailPage from '@/pages/instances/InstanceDetailPage'
import AttachmentViewerPage from '@/pages/instances/AttachmentViewerPage'
import TaskInboxPage from '@/pages/tasks/TaskInboxPage'
import UsersPage from '@/pages/admin/UsersPage'
import UserDetailPage from '@/pages/admin/UserDetailPage'
import GroupsPage from '@/pages/admin/GroupsPage'
import TokensPage from '@/pages/admin/TokensPage'
import AuditLogPage from '@/pages/admin/AuditLogPage'
import AppearanceSettingsPage from '@/pages/admin/AppearanceSettingsPage'
import HealthDashboardPage from '@/pages/admin/HealthDashboardPage'
import MetricsPage from '@/pages/admin/MetricsPage'
import DlqPage from '@/pages/dlq/DlqPage'
import WebhooksPage from '@/pages/dlq/WebhooksPage'
import RegisterTenantPage from '@/pages/admin/onboarding/RegisterTenantPage'
import OnboardingProgressPage from '@/pages/admin/onboarding/OnboardingProgressPage'
import OnboardingResultPage from '@/pages/admin/onboarding/OnboardingResultPage'
import TenantsPage from '@/pages/admin/tenants/TenantsPage'
import EditTenantPage from '@/pages/admin/tenants/EditTenantPage'
import ServicesPage from '@/pages/admin/services/ServicesPage'
import PlatformMigrationConsolePage from '@/pages/admin/platform-migrations/PlatformMigrationConsolePage'
import SolutionPackUpdateLauncherPage from '@/pages/solution-packs/SolutionPackUpdateLauncherPage'
import SolutionPackUpdateReviewPage from '@/pages/solution-packs/SolutionPackUpdateReviewPage'
import EventRetentionPage from '@/pages/admin/event-retention/EventRetentionPage'
import PrintTemplatesPage from '@/pages/admin/PrintTemplatesPage'
import EntityListBrowserPage from '@/pages/entities/EntityListBrowserPage'
import { NotFoundPage } from '@/pages/NotFoundPage'
import VerifyCertificatePage from '@/pages/VerifyCertificatePage'
import { REGISTERED_MODULE_ROUTE_OBJECTS } from '@/modules/registry'

/**
 * GH #2238 slice 2a (REQ-450): a platform page mounts only when the server-reported permission
 * and the platform tenant both grant it. A direct URL otherwise renders PermissionDenied and the
 * page's data hooks never run. Each call mirrors the platformOnly NAV_ITEMS entry for the route.
 */
function platformPage(permission: Permission, page: ReactNode) {
  return (
    <RequirePermission permission={permission} platformOnly>
      {page}
    </RequirePermission>
  )
}

export const router = createBrowserRouter([
  {
    path: '/auth/callback',
    element: <OidcCallbackPage />,
  },
  {
    // REQ-438: public email-first login screen, outside ProtectedRoute. Only
    // reached when VITE_EMAIL_FIRST_LOGIN is on (ProtectedRoute routes here);
    // with the flag off nothing links to it.
    path: '/login',
    element: <LoginRoute />,
  },
  {
    // BilimBaga T4a: public certificate check keyed by the one-time public handle;
    // outside ProtectedRoute, no login.
    path: '/verify/:handle',
    element: <VerifyCertificatePage />,
  },
  {
    path: '/',
    element: (
      <ProtectedRoute>
        <AuthenticatedShellRoot />
      </ProtectedRoute>
    ),
    children: [
      { index: true, element: <TenantDashboardPage /> },
      { path: 'dashboard', element: <TenantDashboardPage /> },
      { path: 'platform-dashboard', element: <PlatformDashboardPage /> },
      { path: 'definitions', element: <DefinitionListPage /> },
      { path: 'definitions/new', element: <DefinitionEditorPage /> },
      { path: 'definitions/:id', element: <DefinitionEditorPage /> },
      { path: 'definitions/:id/promotions/:reviewId', element: <PromotionReviewPage /> },
      { path: 'definitions/:id/rollback', element: <DefinitionRollbackPage /> },
      // REQ-398: top-level promotion-review list/queue page, sibling to
      // /definitions and /instances — not nested under definitions/*
      // since it browses reviews across every definition.
      { path: 'promotions', element: <PromotionReviewListPage /> },
      { path: 'instances', element: <InstanceBoardPage /> },
      { path: 'instances/:id', element: <InstanceDetailPage /> },
      { path: 'instances/:id/attachments/:attachmentId', element: <AttachmentViewerPage /> },
      { path: 'tasks', element: <TaskInboxPage /> },
      { path: 'admin/users', element: <UsersPage /> },
      { path: 'admin/users/:userId', element: <UserDetailPage /> },
      { path: 'admin/groups', element: <GroupsPage /> },
      { path: 'admin/tokens', element: <TokensPage /> },
      { path: 'admin/audit', element: <AuditLogPage /> },
      { path: 'admin/appearance', element: <AppearanceSettingsPage /> },
      { path: 'admin/print-templates', element: <RequirePermission permission={P.DocumentPrintTemplatesManage}><PrintTemplatesPage /></RequirePermission> },
      { path: 'admin/health', element: platformPage(P.TenantsManage, <HealthDashboardPage />) },
      { path: 'admin/metrics', element: <MetricsPage /> },
      { path: 'admin/onboarding', element: platformPage(P.TenantsManage, <RegisterTenantPage />) },
      { path: 'admin/onboarding/new', element: platformPage(P.TenantsManage, <RegisterTenantPage />) },
      { path: 'admin/onboarding/:onboardingId/progress', element: <OnboardingProgressPage /> },
      { path: 'admin/onboarding/:onboardingId/result', element: <OnboardingResultPage /> },
      { path: 'admin/tenants', element: platformPage(P.TenantsManage, <TenantsPage />) },
      { path: 'admin/tenants/:slug/edit', element: platformPage(P.TenantsManage, <EditTenantPage />) },
      { path: 'admin/services', element: platformPage(P.PlatformServicesManage, <ServicesPage />) },
      // admin/modules route removed in ISS-0822: Letflow.Routers.ProcessModules is
      // deferred to S5 — no backend exists, every API call 404s. Restore this route
      // when S5's backend is implemented (see router.ex's deferred table).
      { path: 'admin/platform-migrations', element: platformPage(P.TenantsManage, <PlatformMigrationConsolePage />) },
      // REQ-381: solution-pack update review screen. `/solution-packs` IS
      // the minimal "company's pack screen" entry point (design §4.1, no
      // real pack inventory exists yet -- OQ-2); the review route is
      // direct-navigation-only (reached via the launcher's
      // navigate(..., { state })), same convention as
      // `definitions/:id/promotions/:reviewId`.
      { path: 'solution-packs', element: <SolutionPackUpdateLauncherPage /> },
      { path: 'solution-packs/:packId/update-review', element: <SolutionPackUpdateReviewPage /> },
      { path: 'admin/event-retention', element: platformPage(P.TenantsManage, <EventRetentionPage />) },
      { path: 'dlq', element: <DlqPage /> },
      { path: 'webhooks', element: <WebhooksPage /> },
      // REQ-393: tenant-agnostic entity-list browse screen (filter/sort/page-size)
      { path: 'entities/:entityType', element: <EntityListBrowserPage /> },
      // REQ-412 / ISS-0844: module-provided routes, wrapped in ModuleGuard by registry.ts.
      // Paths only render when the module is installed; uninstalled routes fall through.
      ...REGISTERED_MODULE_ROUTE_OBJECTS,
      // Catch-all: any path not matched above renders the not-found page.
      { path: '*', element: <NotFoundPage /> },
    ],
  },
])
