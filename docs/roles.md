# Letflow role charter

Decision record: `docs/migration/decisions/0046-admin-scopes-and-role-charter.md` (cite as "0046 D<n>").
This is the current state after REQ-446..448. Eight built-in roles, in the order of
`Letflow.Api.Authorization.roles/0` (the six existing roles, then TENANT_ADMIN, TENANT_AUDITOR).
The set is closed: a module cannot create a role (0046 D10).

Two scopes. Platform scope = the organisation operating Letflow. Tenant scope = one customer
organisation, inside its own tenant only. The platform tenant is the one tenant named by server
configuration; if that is missing, no tenant is the platform tenant (0046 D1, D2).

## PLATFORM_ADMIN
- Scope: platform. Honoured only in the platform tenant; not seeded or issuable anywhere else.
- Who holds it: the staff of the organisation operating Letflow.
- Does: everything, including create, change and deactivate tenants, platform migrations, event retention.
- Must not: act inside a customer tenant or read a customer's business data.

## PROCESS_DESIGNER
- Scope: tenant.
- Who holds it: people who model processes and entities for their organisation.
- Does: create and change definitions and entity definitions, start instances, manage custom roles.
- Must not: cancel instances, complete tasks, manage users or tokens, read the audit log.

## PROCESS_OPERATOR
- Scope: tenant.
- Who holds it: people who run live processes day to day.
- Does: start, cancel and watch instances, assign and complete tasks, handle the dead-letter queue, webhooks, audit and metrics.
- Must not: change definitions, manage users, tokens or roles.

## TASK_WORKER
- Scope: tenant.
- Who holds it: ordinary staff who do assigned tasks.
- Does: read and complete their tasks, read definitions, query entity data they may see.
- Must not: start or cancel instances, assign tasks, change anything else.

## AGENT_RUNNER
- Scope: tenant.
- Who holds it: machine accounts for the (deferred) runtime-agent subsystem; no human.
- Does: read help and its memberships.
- Must not: touch processes, tasks or data.

## CANDIDATE
- Scope: tenant.
- Who holds it: external people sitting an exam.
- Does: list the tenant's installed modules; exam-session actions come from the exam module's own grants.
- Must not: hold any core permission beyond that, so it cannot query entities.

## TENANT_ADMIN
- Scope: tenant. The owner role of one customer organisation.
- Who holds it: the customer's administrators (existing tenant admins are migrated here, 0046 D8).
- Does: every tenant-scope permission in its own tenant: users, groups, role bindings, API tokens, settings, modules and solutions, audit log.
- Must not: hold any platform-scope permission, or bypass the deactivated-tenant gate.

## TENANT_AUDITOR
- Scope: tenant, read-only.
- Who holds it: compliance officers, auditors, managers.
- Does: read definitions, instances, all tasks, audit, metrics, attachments, entity data.
- Must not: write, export, import, issue attachment links, manage tokens, users, roles, modules or settings.
- Promotion reads (`PromotionsRead`) are withheld until the stored-tenant check of Q-1011 merges; a follow-up then grants them.

## Matrix

Format, parsed by the REQ-448 parity test: one row per permission; first column the permission atom
without the colon; then one column per role in `roles/0` order (eight columns); cells `yes` or `no`;
final column `scope` (`platform` or `tenant`); whitespace-separated, first line is the header.
PLATFORM_ADMIN `yes` means as evaluated in the platform tenant. The rows cover every core permission of
`Authorization.core_permissions/0` (REQ-446 names, `TenantSettingsManage` split, `PlatformServicesManage`,
and REQ-448's `AttachmentLinksIssue`, which gates `POST /instances/:id/attachments/:attachment_id/link`).
REQ-446 classified `GET /promotions/platform-events` as tenant scope under `PromotionsRead`
(see the correction note appended to decision 0046); no platform promotion permission exists.
Module (Catalog) permissions are all tenant scope and are not listed.
Conditional cells: the 0046 D3 binding condition (source-tenant ownership proven) is met by REQ-446
(`lib/letflow/routers/tenants.ex:451`, `lib/letflow/api/tenant_target.ex:31-39`); the TENANT_ADMIN `yes`
cells for PromotionsRead and PromotionsManage stand. The TENANT_AUDITOR `PromotionsRead` cell is `no`
(interim deviation from 0046 D6 until Q-1011's stored-tenant check merges; see the closure note of 0046).

```
permission                      PLATFORM_ADMIN PROCESS_DESIGNER PROCESS_OPERATOR TASK_WORKER AGENT_RUNNER CANDIDATE TENANT_ADMIN TENANT_AUDITOR scope
DefinitionsWrite                yes            yes              no               no          no           no        yes          no             tenant
DefinitionsRead                 yes            yes              yes              yes         no           no        yes          yes            tenant
InstancesStart                  yes            yes              yes              no          no           no        yes          no             tenant
InstancesCancel                 yes            no               yes              no          no           no        yes          no             tenant
InstancesRead                   yes            yes              yes              yes         no           no        yes          yes            tenant
TasksRead                       yes            yes              yes              yes         no           no        yes          yes            tenant
TasksComplete                   yes            no               yes              yes         no           no        yes          no             tenant
TasksAssign                     yes            no               yes              no          no           no        yes          no             tenant
UsersGroupsRolesManage          yes            no               no               no          no           no        yes          no             tenant
TokensManage                    yes            no               no               no          no           no        yes          no             tenant
AuditRead                       yes            no               yes              no          no           no        yes          yes            tenant
DlqOperate                      yes            no               yes              no          no           no        yes          no             tenant
MetricsRead                     yes            no               yes              no          no           no        yes          yes            tenant
WebhooksManage                  yes            no               yes              no          no           no        yes          no             tenant
TenantsManage                   yes            no               no               no          no           no        no           no             platform
RolesManage                     yes            yes              no               no          no           no        yes          no             tenant
AttachmentsManage               yes            no               yes              no          no           no        yes          no             tenant
AttachmentsRead                 yes            yes              yes              yes         no           no        yes          yes            tenant
InstancesAdvanceTimer           yes            no               yes              no          no           no        yes          no             tenant
EntitiesDefinitionsRead         yes            yes              yes              yes         no           no        yes          yes            tenant
EntitiesDefinitionsWrite        yes            yes              no               no          no           no        yes          no             tenant
EntitiesRecordsWrite            yes            no               yes              no          no           no        yes          no             tenant
EntitiesQuery                   yes            yes              yes              yes         no           no        yes          yes            tenant
EntitiesAggregate               yes            yes              yes              yes         no           no        yes          yes            tenant
EntitiesRecordsExport           yes            no               no               no          no           no        yes          no             tenant
EntitiesRecordsExportUnredacted yes            no               no               no          no           no        yes          no             tenant
EntitiesRecordsImport           yes            no               no               no          no           no        yes          no             tenant
EntitiesAttachmentsManage       yes            no               yes              no          no           no        yes          no             tenant
EntitiesAttachmentsRead         yes            yes              yes              yes         no           no        yes          yes            tenant
PublicReadHandlesIssue          yes            no               no               no          no           no        yes          no             tenant
HelpRead                        yes            yes              yes              yes         yes          no        yes          yes            tenant
MembershipsRead                 yes            yes              yes              yes         yes          no        yes          yes            tenant
ModulesManage                   yes            no               no               no          no           no        yes          no             tenant
MyModulesRead                   yes            yes              yes              yes         yes          yes       yes          yes            tenant
EntitiesRestrictionsManage      yes            no               no               no          no           no        yes          no             tenant
PromotionsRead                  yes            no               no               no          no           no        yes          no             tenant
PromotionsManage                yes            no               no               no          no           no        yes          no             tenant
DefinitionsRollback             yes            no               no               no          no           no        yes          no             tenant
TenantSettingsManage            yes            no               no               no          no           no        yes          no             tenant
PlatformServicesManage          yes            no               no               no          no           no        no           no             platform
AttachmentLinksIssue            yes            yes              yes              yes         no           no        yes          no             tenant
```
