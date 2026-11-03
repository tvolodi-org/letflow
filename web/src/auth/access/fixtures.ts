/**
 * Test fixtures for the access module: one `AccessInfo` per built-in role, shaped like the
 * body of GET /api/v1/me/access. The permission lists are copied from the grant matrix
 * (`Letflow.Api.Authorization`, `has_permission_in_scope?/3` per role; `platform_tenant` is true
 * only for the platform admin). Drift against the matrix is not tested in this slice.
 *
 * This is one of the few files allowed to name a role (tests/guards/no-role-literals.spec.ts).
 * Other tests pick a fixture by key and never write a role name.
 */

import type { AccessInfo, AccessState } from './types'

const platformAdmin: AccessInfo = {
  roles: ['PLATFORM_ADMIN'],
  platform_tenant: true,
  permissions: [
    'AttachmentLinksIssue',
    'AttachmentsManage',
    'AttachmentsRead',
    'AuditRead',
    'DefinitionsRead',
    'DefinitionsRollback',
    'DefinitionsWrite',
    'DlqOperate',
    'DocumentPrintTemplatesManage',
    'EntitiesAggregate',
    'EntitiesAttachmentsManage',
    'EntitiesAttachmentsRead',
    'EntitiesDefinitionsRead',
    'EntitiesDefinitionsWrite',
    'EntitiesQuery',
    'EntitiesRecordsExport',
    'EntitiesRecordsExportUnredacted',
    'EntitiesRecordsImport',
    'EntitiesRecordsWrite',
    'EntitiesRestrictionsManage',
    'ExamAuthoringWrite',
    'ExamCertificateIssue',
    'ExamSessionRead',
    'ExamSessionReportEvent',
    'ExamSessionSave',
    'ExamSessionStart',
    'ExamSessionSubmit',
    'HelpRead',
    'InstancesAdvanceTimer',
    'InstancesCancel',
    'InstancesRead',
    'InstancesStart',
    'MembershipsRead',
    'MetricsRead',
    'ModulesManage',
    'MyAccessRead',
    'MyModulesRead',
    'PlatformServicesManage',
    'PromotionsManage',
    'PromotionsRead',
    'PublicReadHandlesIssue',
    'RolesManage',
    'ScriptsPublish',
    'ScriptsWrite',
    'SolutionOverridesManage',
    'TasksAssign',
    'TasksComplete',
    'TasksRead',
    'TenantSettingsManage',
    'TenantsManage',
    'TokensManage',
    'UsersGroupsRolesManage',
    'WebhooksManage',
  ],
}

const designer: AccessInfo = {
  roles: ['PROCESS_DESIGNER'],
  platform_tenant: false,
  permissions: [
    'AttachmentLinksIssue',
    'AttachmentsRead',
    'DefinitionsRead',
    'DefinitionsWrite',
    'EntitiesAggregate',
    'EntitiesAttachmentsRead',
    'EntitiesDefinitionsRead',
    'EntitiesDefinitionsWrite',
    'EntitiesQuery',
    'HelpRead',
    'InstancesRead',
    'InstancesStart',
    'MembershipsRead',
    'MyAccessRead',
    'MyModulesRead',
    'RolesManage',
    'ScriptsWrite',
    'TasksRead',
  ],
}

const operator: AccessInfo = {
  roles: ['PROCESS_OPERATOR'],
  platform_tenant: false,
  permissions: [
    'AttachmentLinksIssue',
    'AttachmentsManage',
    'AttachmentsRead',
    'AuditRead',
    'DefinitionsRead',
    'DlqOperate',
    'EntitiesAggregate',
    'EntitiesAttachmentsManage',
    'EntitiesAttachmentsRead',
    'EntitiesDefinitionsRead',
    'EntitiesQuery',
    'EntitiesRecordsWrite',
    'HelpRead',
    'InstancesAdvanceTimer',
    'InstancesCancel',
    'InstancesRead',
    'InstancesStart',
    'MembershipsRead',
    'MetricsRead',
    'MyAccessRead',
    'MyModulesRead',
    'TasksAssign',
    'TasksComplete',
    'TasksRead',
    'WebhooksManage',
  ],
}

const taskWorker: AccessInfo = {
  roles: ['TASK_WORKER'],
  platform_tenant: false,
  permissions: [
    'AttachmentLinksIssue',
    'AttachmentsRead',
    'DefinitionsRead',
    'EntitiesAggregate',
    'EntitiesAttachmentsRead',
    'EntitiesDefinitionsRead',
    'EntitiesQuery',
    'HelpRead',
    'InstancesRead',
    'MembershipsRead',
    'MyAccessRead',
    'MyModulesRead',
    'TasksComplete',
    'TasksRead',
  ],
}

const agentRunner: AccessInfo = {
  roles: ['AGENT_RUNNER'],
  platform_tenant: false,
  permissions: [
    'HelpRead',
    'MembershipsRead',
    'MyAccessRead',
    'MyModulesRead',
  ],
}

const candidate: AccessInfo = {
  roles: ['CANDIDATE'],
  platform_tenant: false,
  permissions: [
    'ExamCertificateIssue',
    'ExamSessionRead',
    'ExamSessionReportEvent',
    'ExamSessionSave',
    'ExamSessionStart',
    'ExamSessionSubmit',
    'MyAccessRead',
    'MyModulesRead',
  ],
}

const tenantAdmin: AccessInfo = {
  roles: ['TENANT_ADMIN'],
  platform_tenant: false,
  permissions: [
    'AttachmentLinksIssue',
    'AttachmentsManage',
    'AttachmentsRead',
    'AuditRead',
    'DefinitionsRead',
    'DefinitionsRollback',
    'DefinitionsWrite',
    'DlqOperate',
    'DocumentPrintTemplatesManage',
    'EntitiesAggregate',
    'EntitiesAttachmentsManage',
    'EntitiesAttachmentsRead',
    'EntitiesDefinitionsRead',
    'EntitiesDefinitionsWrite',
    'EntitiesQuery',
    'EntitiesRecordsExport',
    'EntitiesRecordsExportUnredacted',
    'EntitiesRecordsImport',
    'EntitiesRecordsWrite',
    'EntitiesRestrictionsManage',
    'ExamAuthoringWrite',
    'ExamCertificateIssue',
    'ExamSessionRead',
    'ExamSessionReportEvent',
    'ExamSessionSave',
    'ExamSessionStart',
    'ExamSessionSubmit',
    'HelpRead',
    'InstancesAdvanceTimer',
    'InstancesCancel',
    'InstancesRead',
    'InstancesStart',
    'MembershipsRead',
    'MetricsRead',
    'ModulesManage',
    'MyAccessRead',
    'MyModulesRead',
    'PromotionsManage',
    'PromotionsRead',
    'PublicReadHandlesIssue',
    'RolesManage',
    'ScriptsPublish',
    'ScriptsWrite',
    'SolutionOverridesManage',
    'TasksAssign',
    'TasksComplete',
    'TasksRead',
    'TenantSettingsManage',
    'TokensManage',
    'UsersGroupsRolesManage',
    'WebhooksManage',
  ],
}

const auditor: AccessInfo = {
  roles: ['TENANT_AUDITOR'],
  platform_tenant: false,
  permissions: [
    'AttachmentsRead',
    'AuditRead',
    'DefinitionsRead',
    'EntitiesAggregate',
    'EntitiesAttachmentsRead',
    'EntitiesDefinitionsRead',
    'EntitiesQuery',
    'HelpRead',
    'InstancesRead',
    'MembershipsRead',
    'MetricsRead',
    'MyAccessRead',
    'MyModulesRead',
    'PromotionsRead',
    'TasksRead',
  ],
}

export const ACCESS_FIXTURES = {
  platformAdmin,
  designer,
  operator,
  taskWorker,
  agentRunner,
  candidate,
  tenantAdmin,
  auditor,
} as const satisfies Record<string, AccessInfo>

export type AccessFixtureName = keyof typeof ACCESS_FIXTURES

export function accessState(name: AccessFixtureName): AccessState {
  return { status: 'ready', info: ACCESS_FIXTURES[name] }
}

export const LOADING_STATE: AccessState = { status: 'loading' }

export const ERROR_STATE: AccessState = { status: 'error', error: new Error('access failed'), retry: () => {} }
