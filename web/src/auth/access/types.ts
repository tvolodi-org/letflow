/** Shapes of the access module. The server (GET /api/v1/me/access) is the only source of truth. */

/** Permission atoms the server reports (`Letflow.Api.Authorization`), as strings. */
export type Permission = string

/** The permissions the SPA names, so call sites carry no string literals and typos fail type-check.
 *  Module permissions (e.g. the exam module's) are not core permissions and are plain strings. */
export const P = {
  InstancesRead: 'InstancesRead',
  InstancesStart: 'InstancesStart',
  InstancesCancel: 'InstancesCancel',
  TasksRead: 'TasksRead',
  TasksAssign: 'TasksAssign',
  TasksComplete: 'TasksComplete',
  DefinitionsRead: 'DefinitionsRead',
  DefinitionsWrite: 'DefinitionsWrite',
  DefinitionsRollback: 'DefinitionsRollback',
  PromotionsRead: 'PromotionsRead',
  PromotionsManage: 'PromotionsManage',
  DlqOperate: 'DlqOperate',
  DocumentPrintTemplatesManage: 'DocumentPrintTemplatesManage',
  WebhooksManage: 'WebhooksManage',
  UsersGroupsRolesManage: 'UsersGroupsRolesManage',
  TokensManage: 'TokensManage',
  AuditRead: 'AuditRead',
  MetricsRead: 'MetricsRead',
  TenantsManage: 'TenantsManage',
  PlatformServicesManage: 'PlatformServicesManage',
  ModulesManage: 'ModulesManage',
  TenantSettingsManage: 'TenantSettingsManage',
  EntitiesDefinitionsRead: 'EntitiesDefinitionsRead',
  EntitiesRecordsWrite: 'EntitiesRecordsWrite',
  EntitiesViewsManage: 'EntitiesViewsManage',
  EntitiesQuery: 'EntitiesQuery',
  EntitiesAggregate: 'EntitiesAggregate',
  SolutionOverridesManage: 'SolutionOverridesManage',
} as const

/** Body of GET /api/v1/me/access. */
export interface AccessInfo {
  roles: string[]
  permissions: string[]
  platform_tenant: boolean
}

export type AccessState =
  | { status: 'loading' }
  | { status: 'error'; error: unknown; retry: () => void }
  | { status: 'ready'; info: AccessInfo }
