import type { DefinitionStatus, InstanceStatus, TaskStatus } from '@/types/api'

type InstanceListFilters = {
  status?: InstanceStatus[]
  definition_id?: string
  cursor?: string
  page_size?: number
}

type DefinitionListFilters = {
  status?: DefinitionStatus
  name?: string
  cursor?: string
  page_size?: number
}

type TaskListFilters = {
  status?: TaskStatus
  instance_id?: string
  assignee_ref?: string
  cursor?: string
  page_size?: number
}

type AdminAuditFilters = {
  actor?: string
  resource_type?: string
  from?: string
  to?: string
  cursor?: string
  page_size?: number
}

type EventFilters = {
  event_type?: string
  from?: string
  to?: string
}

function sortStatuses(statuses?: InstanceStatus[]): InstanceStatus[] | undefined {
  if (!statuses || statuses.length === 0) return undefined
  return [...statuses].sort()
}

/**
 * REQ-384 §7.1 — tenant-keyed query-cache isolation.
 *
 * Every group backed by per-tenant-schema or per-tenant-filtered data takes
 * the active tenant id as its FIRST argument and leads its key array with
 * `['tenant', tenantId, ...]` — React Query matches/invalidates by key-array
 * PREFIX, so the tenant id must lead, not trail, for a single
 * `removeQueries({ queryKey: ['tenant', tenantId] })` call (AuthProvider's
 * `switchTenant`, see `web/src/auth/AuthProvider.tsx`) to address exactly one
 * tenant's whole cache subtree in one call.
 *
 * Call sites should almost never call these builders directly with a
 * hand-supplied `tenantId` — use `useTenantScopedQueryKeys()`
 * (`web/src/api/useTenantScopedQueryKeys.ts`), which partially applies the
 * active tenant id from `useAuth()` so every call site keeps the exact same
 * calling shape it had before this requirement (`queryKeys.instances.list(filters)`
 * with no `tenantId` parameter at the call site). The raw, tenant-parameterized
 * builders below exist so that partial application, and only that, has one
 * place to do it.
 *
 * Groups that are NOT tenant-scoped (unchanged shape, no tenant prefix) are
 * `admin.tenants`/`admin.tenantDetail` (the public-schema `tenants` list
 * itself — platform-wide, not "this tenant's business data"), `onboarding`
 * (pre-authentication, no tenant session exists yet), `admin.health`/
 * `admin.metrics` (infrastructure liveness/Prometheus exposition, no tenant
 * dimension in the response shape at all), and `me` (REQ-384 §6.1 — the
 * membership list a user consults in order to switch, not data scoped to
 * whichever tenant happens to be active).
 */
/**
 * REQ-384 §7.3.1 — the whole-tenant-subtree prefix key `AuthProvider`'s
 * `switchTenant` cancels/removes on a switch: every tenant-scoped group's
 * own `.all(tenantId)` is `[...tenantRoot(tenantId), <group>]`, so removing
 * this one key removes every tenant-scoped group in a single prefix-matched
 * call.
 */
export function tenantRoot(tenantId: string) {
  return ['tenant', tenantId] as const
}

export const queryKeys = {
  instances: {
    all: (tenantId: string) => ['tenant', tenantId, 'instances'] as const,
    list: (tenantId: string, filters: InstanceListFilters) => [
      ...queryKeys.instances.all(tenantId),
      'list',
      {
        ...filters,
        status: sortStatuses(filters.status),
      },
    ] as const,
    detail: (tenantId: string, id: string) => [...queryKeys.instances.all(tenantId), 'detail', id] as const,
    events: (tenantId: string, id: string, filters?: EventFilters) =>
      [...queryKeys.instances.all(tenantId), 'events', id, filters ?? {}] as const,
    timeline: (tenantId: string, id: string, cursor: string | null, pageSize: number) =>
      [...queryKeys.instances.all(tenantId), 'timeline', id, cursor, pageSize] as const,
    attachments: (tenantId: string, instanceId: string) =>
      [...queryKeys.instances.all(tenantId), 'attachments', instanceId] as const,
    pins: (tenantId: string, instanceId: string) =>
      [...queryKeys.instances.all(tenantId), 'pins', instanceId] as const,
  },

  /** REQ-392 §5.2 — tenant-wide (not instance-scoped) storage-usage figure.
   *  A new top-level group, not nested under `instances`, since
   *  `Attachments.storage_summary/1` takes no `instance_id`. */
  attachments: {
    storageUsage: (tenantId: string) => ['tenant', tenantId, 'attachments', 'storage-usage'] as const,
  },

  definitions: {
    all: (tenantId: string) => ['tenant', tenantId, 'definitions'] as const,
    list: (tenantId: string, filters: DefinitionListFilters) =>
      [...queryKeys.definitions.all(tenantId), 'list', filters] as const,
    detail: (tenantId: string, id: string) => [...queryKeys.definitions.all(tenantId), 'detail', id] as const,
    active: (tenantId: string, name: string) => [...queryKeys.definitions.all(tenantId), 'active', name] as const,
    versions: (tenantId: string, name: string) => [...queryKeys.definitions.all(tenantId), 'versions', name] as const,
    search: (tenantId: string, query: string, page_size?: number, cursor?: string) =>
      [...queryKeys.definitions.all(tenantId), 'search', query, page_size, cursor] as const,
  },

  tasks: {
    all: (tenantId: string) => ['tenant', tenantId, 'tasks'] as const,
    list: (tenantId: string, filters: TaskListFilters) => [...queryKeys.tasks.all(tenantId), 'list', filters] as const,
    detail: (tenantId: string, id: string) => [...queryKeys.tasks.all(tenantId), 'detail', id] as const,
    inbox: (tenantId: string) => [...queryKeys.tasks.all(tenantId), 'inbox'] as const,
  },

  admin: {
    // Tenant-scoped admin sub-groups (per-tenant-schema/per-tenant-filtered data).
    audit: (tenantId: string, filters?: AdminAuditFilters) =>
      ['tenant', tenantId, 'admin', 'audit', filters ?? {}] as const,
    groups: (tenantId: string) => ['tenant', tenantId, 'admin', 'groups'] as const,
    groupMembers: (tenantId: string, groupId: string) =>
      ['tenant', tenantId, 'admin', 'group-members', groupId] as const,
    tokens: (tenantId: string) => ['tenant', tenantId, 'admin', 'tokens'] as const,
    users: (tenantId: string, filters?: { search?: string; status?: string; cursor?: string; page_size?: number }) =>
      ['tenant', tenantId, 'admin', 'users', filters ?? {}] as const,
    userDetail: (tenantId: string, id: string) => ['tenant', tenantId, 'admin', 'user', id] as const,
    roles: (tenantId: string) => ['tenant', tenantId, 'admin', 'roles'] as const,
    services: (tenantId: string, filters?: { after_id?: string; limit?: number }) =>
      ['tenant', tenantId, 'admin', 'services', filters ?? {}] as const,

    // NOT tenant-scoped — public-schema `tenants` list / infra-liveness endpoints.
    // See this file's moduledoc for why these stay exempt.
    all: ['admin'] as const,
    health: () => [...queryKeys.admin.all, 'health'] as const,
    metrics: () => [...queryKeys.admin.all, 'metrics'] as const,
    tenants: (filters?: { search?: string; cursor?: string; page_size?: number }) =>
      [...queryKeys.admin.all, 'tenants', filters ?? {}] as const,
    tenantDetail: (slug: string) => [...queryKeys.admin.all, 'tenant', slug] as const,
  },

  dlq: {
    all: (tenantId: string) => ['tenant', tenantId, 'dlq'] as const,
    list: (
      tenantId: string,
      filters?: { search?: string; status?: string; source_type?: string; cursor?: string; page_size?: number },
    ) => [...queryKeys.dlq.all(tenantId), 'list', filters ?? {}] as const,
    detail: (tenantId: string, id: string) => [...queryKeys.dlq.all(tenantId), 'detail', id] as const,
  },

  webhooks: {
    all: (tenantId: string) => ['tenant', tenantId, 'webhooks'] as const,
    list: (tenantId: string) => [...queryKeys.webhooks.all(tenantId), 'list'] as const,
    detail: (tenantId: string, id: string) => [...queryKeys.webhooks.all(tenantId), 'detail', id] as const,
    deliveries: (tenantId: string, id: string, limit = 20) =>
      [...queryKeys.webhooks.all(tenantId), 'deliveries', id, limit] as const,
  },

  // NOT tenant-scoped — pre-authentication, no tenant session exists yet.
  onboarding: {
    all: ['onboarding'] as const,
    status: (id: string) => ['onboarding', 'status', id] as const,
    hostname: (h: string) => ['onboarding', 'hostname', h] as const,
  },

  promotions: {
    all: (tenantId: string) => ['tenant', tenantId, 'promotions'] as const,
    context: (tenantId: string, reviewId: string) => [...queryKeys.promotions.all(tenantId), 'context', reviewId] as const,
    /** REQ-398 §3.2 — same shape as `dlq.list`. */
    list: (tenantId: string, filters?: { status?: string; def_id?: string; def_type?: string; cursor?: string; page_size?: number }) =>
      [...queryKeys.promotions.all(tenantId), 'list', filters ?? {}] as const,
  },

  entities: {
    all: (tenantId: string) => ['tenant', tenantId, 'entities'] as const,
    definition: (tenantId: string, entityType: string) =>
      [...queryKeys.entities.all(tenantId), 'definition', entityType] as const,
    records: (tenantId: string, entityType: string, filters?: { cursor?: string; page_size?: number; filters?: unknown }) =>
      [...queryKeys.entities.all(tenantId), 'records', entityType, filters ?? {}] as const,
    /** REQ-393 browser-query screen — separate from `records` to avoid cache
     *  collisions with EntityCrudPage (different filter shape, no EXCLUDE_DELETED). */
    browserRecords: (
      tenantId: string,
      entityType: string,
      params?: { filters?: unknown; sort?: unknown; pageSize?: number; cursor?: string },
    ) => [...queryKeys.entities.all(tenantId), 'browser', entityType, params ?? {}] as const,
    /** REQ-556 saved list views of one entity type. */
    views: (tenantId: string, entityType: string) =>
      [...queryKeys.entities.all(tenantId), 'views', entityType] as const,
  },

  modules: {
    all: (tenantId: string) => ['tenant', tenantId, 'modules'] as const,
    list: (tenantId: string, filters?: { cursor?: string; page_size?: number }) =>
      [...queryKeys.modules.all(tenantId), 'list', filters ?? {}] as const,
    detail: (tenantId: string, moduleId: string, version: string) =>
      [...queryKeys.modules.all(tenantId), 'detail', moduleId, version] as const,
    shares: (tenantId: string, moduleId: string) => [...queryKeys.modules.all(tenantId), 'shares', moduleId] as const,
  },

  help: {
    all: (tenantId: string) => ['tenant', tenantId, 'help'] as const,
    /** REQ-366 §2.2 — one key per (screenId, processDefinitionId) pair
     *  `useHelpContent` resolves. */
    resolved: (tenantId: string, screenId: string, processDefinitionId: string | null) =>
      [...queryKeys.help.all(tenantId), 'resolved', screenId, processDefinitionId] as const,
  },

  exam: {
    all: (tenantId: string) => ['tenant', tenantId, 'exam'] as const,
    session: (tenantId: string, sessionId: string) => [...queryKeys.exam.all(tenantId), 'session', sessionId] as const,
    /** ExamListPage's own list key (REQ-338) — deliberately not
     *  `queryKeys.entities.records(...)`: that group is REQ-336's own
     *  addition and REQ-338 does not depend on REQ-336 (see
     *  web/src/api/exam.ts's own moduledoc). */
    list: (tenantId: string, filters?: { page_size?: number }) =>
      [...queryKeys.exam.all(tenantId), 'list', filters ?? {}] as const,
    /** ExamMyResultsPage's key (GH 3321): the caller's own finished sessions, per page. */
    mine: (tenantId: string, filters?: { cursor?: string | null; page_size?: number }) =>
      [...queryKeys.exam.all(tenantId), 'mine', filters ?? {}] as const,
  },

  /** REQ-375 §3.1 — platform migration rollout console. */
  platformMigrations: {
    all: (tenantId: string) => ['tenant', tenantId, 'platform-migrations'] as const,
    status: (tenantId: string, rolloutId: string) => [...queryKeys.platformMigrations.all(tenantId), 'status', rolloutId] as const,
  },

  /** REQ-381 design §3.2 — solution-pack update review/apply screen. */
  solutionPackUpdate: {
    all: (tenantId: string) => ['tenant', tenantId, 'solutionPackUpdate'] as const,
    review: (tenantId: string, packId: string, targetVersion: string) =>
      [...queryKeys.solutionPackUpdate.all(tenantId), 'review', packId, targetVersion] as const,
  },

  /** REQ-377 §3.2 — operator-facing history-retirement screen. */
  eventRetention: {
    all: (tenantId: string) => ['tenant', tenantId, 'event-retention'] as const,
    summary: (tenantId: string) => [...queryKeys.eventRetention.all(tenantId), 'summary'] as const,
    retirement: (tenantId: string, id: string) => [...queryKeys.eventRetention.all(tenantId), 'retirement', id] as const,
  },

  /** REQ-614 — print-template override authoring screen. */
  printOverrides: {
    all: (tenantId: string) => ['tenant', tenantId, 'print-overrides'] as const,
    list: (tenantId: string, filters?: Record<string, unknown>) =>
      [...queryKeys.printOverrides.all(tenantId), 'list', filters ?? {}] as const,
    detail: (tenantId: string, id: string) => [...queryKeys.printOverrides.all(tenantId), 'detail', id] as const,
  },

  /** REQ-384 §6.1 — the membership list a user consults in order to switch.
   *  Deliberately NOT tenant-scoped — see this file's moduledoc. */
  me: {
    all: ['me'] as const,
    memberships: () => [...queryKeys.me.all, 'memberships'] as const,
    /** REQ-406 — installed-module list is tenant-scoped because it exposes
     *  per-tenant business data, even though the route lives under /me. */
    modules: (tenantId: string) => ['tenant', tenantId, 'me', 'modules'] as const,
  },
}
