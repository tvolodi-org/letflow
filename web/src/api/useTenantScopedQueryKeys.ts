/**
 * REQ-384 §7.2 — closes the "forgot to pass tenantId" hole.
 *
 * Requiring every tenant-scoped call site to remember to thread the active
 * tenant id into every `queryKeys.*` call is exactly the kind of thing one
 * call site forgets. This hook reads the active tenant id from
 * `useAuth().session.tenant_id` once and returns an object with the SAME
 * shape/call signature every existing call site already used before this
 * requirement (`queryKeys.instances.list(filters)`, no `tenantId` parameter
 * at the call site) by partially applying the active tenant id inside each
 * tenant-scoped builder. There is no code path to build a tenant-scoped key
 * without going through this hook and therefore without a resolved active
 * tenant — the scoping is structural, not a convention every hook author
 * must remember.
 *
 * Throws if called with no active session — this hook is only ever used from
 * authenticated screens/hooks, the same precondition every data hook already
 * has via `ProtectedRoute` (`web/src/auth/ProtectedRoute.tsx`).
 *
 * `admin.tenants`/`admin.tenantDetail`/`admin.health`/`admin.metrics`,
 * `onboarding`, and `me` are passed through UNCHANGED (not tenant-scoped —
 * see `queryKeys.ts`'s moduledoc for why).
 */
import { useAuth } from '@/auth/AuthContext'
import { queryKeys } from './queryKeys'

/** Segment used when a real session exists but its `tenant_id` could not be
 *  resolved (`UserSession.tenant_id` is `string | null` — e.g. tenant
 *  display-name/id lookup failed during `login()`, see `AuthProvider.tsx`).
 *  Still a stable, tenant-scoped-shaped key so `removeQueries`/`key={...}`
 *  remount semantics keep working rather than crashing render — distinct
 *  from having no session at all, which throws (below). */
const UNRESOLVED_TENANT_SEGMENT = 'unresolved'

export function useTenantScopedQueryKeys() {
  const { session } = useAuth()
  if (!session) {
    throw new Error('useTenantScopedQueryKeys: no active session — call only from authenticated screens/hooks')
  }
  const tenantId = session.tenant_id ?? UNRESOLVED_TENANT_SEGMENT

  return {
    instances: {
      all: () => queryKeys.instances.all(tenantId),
      list: queryKeys.instances.list.bind(null, tenantId),
      detail: queryKeys.instances.detail.bind(null, tenantId),
      events: queryKeys.instances.events.bind(null, tenantId),
      timeline: queryKeys.instances.timeline.bind(null, tenantId),
      attachments: queryKeys.instances.attachments.bind(null, tenantId),
      pins: queryKeys.instances.pins.bind(null, tenantId),
    },
    attachments: {
      storageUsage: queryKeys.attachments.storageUsage.bind(null, tenantId),
    },
    definitions: {
      all: () => queryKeys.definitions.all(tenantId),
      list: queryKeys.definitions.list.bind(null, tenantId),
      detail: queryKeys.definitions.detail.bind(null, tenantId),
      active: queryKeys.definitions.active.bind(null, tenantId),
      versions: queryKeys.definitions.versions.bind(null, tenantId),
      search: queryKeys.definitions.search.bind(null, tenantId),
    },
    tasks: {
      all: () => queryKeys.tasks.all(tenantId),
      list: queryKeys.tasks.list.bind(null, tenantId),
      detail: queryKeys.tasks.detail.bind(null, tenantId),
      inbox: () => queryKeys.tasks.inbox(tenantId),
    },
    admin: {
      // Tenant-scoped
      audit: queryKeys.admin.audit.bind(null, tenantId),
      groups: () => queryKeys.admin.groups(tenantId),
      groupMembers: queryKeys.admin.groupMembers.bind(null, tenantId),
      tokens: () => queryKeys.admin.tokens(tenantId),
      users: queryKeys.admin.users.bind(null, tenantId),
      userDetail: queryKeys.admin.userDetail.bind(null, tenantId),
      roles: () => queryKeys.admin.roles(tenantId),
      services: queryKeys.admin.services.bind(null, tenantId),
      // NOT tenant-scoped — passed through unchanged.
      all: queryKeys.admin.all,
      health: queryKeys.admin.health,
      metrics: queryKeys.admin.metrics,
      tenants: queryKeys.admin.tenants,
      tenantDetail: queryKeys.admin.tenantDetail,
    },
    dlq: {
      all: () => queryKeys.dlq.all(tenantId),
      list: queryKeys.dlq.list.bind(null, tenantId),
      detail: queryKeys.dlq.detail.bind(null, tenantId),
    },
    webhooks: {
      all: () => queryKeys.webhooks.all(tenantId),
      list: () => queryKeys.webhooks.list(tenantId),
      detail: queryKeys.webhooks.detail.bind(null, tenantId),
      deliveries: queryKeys.webhooks.deliveries.bind(null, tenantId),
    },
    promotions: {
      all: () => queryKeys.promotions.all(tenantId),
      context: queryKeys.promotions.context.bind(null, tenantId),
      list: queryKeys.promotions.list.bind(null, tenantId),
    },
    entities: {
      all: () => queryKeys.entities.all(tenantId),
      definition: queryKeys.entities.definition.bind(null, tenantId),
      records: queryKeys.entities.records.bind(null, tenantId),
      browserRecords: queryKeys.entities.browserRecords.bind(null, tenantId),
      views: queryKeys.entities.views.bind(null, tenantId),
    },
    modules: {
      all: () => queryKeys.modules.all(tenantId),
      list: queryKeys.modules.list.bind(null, tenantId),
      detail: queryKeys.modules.detail.bind(null, tenantId),
      shares: queryKeys.modules.shares.bind(null, tenantId),
    },
    help: {
      all: () => queryKeys.help.all(tenantId),
      resolved: queryKeys.help.resolved.bind(null, tenantId),
    },
    exam: {
      all: () => queryKeys.exam.all(tenantId),
      session: queryKeys.exam.session.bind(null, tenantId),
      list: queryKeys.exam.list.bind(null, tenantId),
      mine: queryKeys.exam.mine.bind(null, tenantId),
    },
    platformMigrations: {
      all: () => queryKeys.platformMigrations.all(tenantId),
      status: queryKeys.platformMigrations.status.bind(null, tenantId),
    },
    solutionPackUpdate: {
      all: () => queryKeys.solutionPackUpdate.all(tenantId),
      review: queryKeys.solutionPackUpdate.review.bind(null, tenantId),
    },
    eventRetention: {
      all: () => queryKeys.eventRetention.all(tenantId),
      summary: () => queryKeys.eventRetention.summary(tenantId),
      retirement: queryKeys.eventRetention.retirement.bind(null, tenantId),
    },
    printOverrides: {
      all: () => queryKeys.printOverrides.all(tenantId),
      list: (filters?: Record<string, unknown>) => queryKeys.printOverrides.list(tenantId, filters),
      detail: queryKeys.printOverrides.detail.bind(null, tenantId),
    },
    // NOT tenant-scoped — passed through unchanged.
    onboarding: queryKeys.onboarding,
    me: {
      memberships: queryKeys.me.memberships,
      modules: () => queryKeys.me.modules(tenantId),
    },
  }
}
