# Letflow role charter

Decision record: `docs/migration/decisions/0046-admin-scopes-and-role-charter.md` (cite as "0046 D<n>").
This is the current state after REQ-446..448. Eight built-in roles, in the order of
`Letflow.Api.Authorization.roles/0` (the six existing roles, then TENANT_ADMIN, TENANT_AUDITOR).
The set is closed: a module cannot create a role (0046 D10).

Two scopes. Platform scope = the organisation operating Letflow. Tenant scope = one customer
organisation, inside its own tenant only. The platform tenant is the one tenant named by server
configuration; if that is missing, no tenant is the platform tenant (0046 D1, D2).

UAT and agents map each login actor to its built-in roles in one place only:
`test/fixtures/uat/actors.yaml`. Do not derive a role from a seed script, an e2e test or a
scenario file. A tenant-side actor holds TENANT_ADMIN or a tenant role, never PLATFORM_ADMIN.

## PLATFORM_ADMIN
- Scope: platform. Honoured only in the platform tenant; not seeded or issuable anywhere else.
- Who holds it: the staff of the organisation operating Letflow.
- Does: everything, including create, change and deactivate tenants, platform migrations, event retention.
- Must not: act inside a customer tenant or read a customer's business data.

## PROCESS_DESIGNER
- Scope: tenant.
- Who holds it: people who model processes and entities for their organisation.
- Does: create and change definitions and entity definitions, start instances, create custom role bindings (`POST /roles`). Re-posting an existing role name with a different group is refused; moving a role to another group is the TENANT_ADMIN's rebind action (PR #2537).
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
- Does: list the tenant's installed modules; exam-session actions come from the exam module's own grants. It can list its own finished sessions and certificate flags with `GET /modules/exam/exam-sessions/mine` (`:ExamSessionRead`, GH #3321).
- Must not: hold any core permission beyond that, so it cannot query entities.

## TENANT_ADMIN
- Scope: tenant. The owner role of one customer organisation.
- Who holds it: the customer's administrators (existing tenant admins are migrated here, 0046 D8).
- Does: every tenant-scope permission in its own tenant: users, groups, role bindings, API tokens, settings, modules and solutions, audit log. Only this role rebinds an existing role to another group: `POST /roles/:id/rebind` with `{group_id, reason}` (`:UsersGroupsRolesManage`). It needs a mandatory reason and writes one `role.rebound` audit entry with the old and new group. PROCESS_DESIGNER gets 403 (PR #2537, GH #2524). Minting API tokens (`POST /identity/tokens`, GH #2552): only an active user who holds TENANT_ADMIN through a group may mint. The token's roles must be held through groups by both the minter and the target user, and the issuer is recorded. Roles held only through a token never count, so a user whose only admin source is a token cannot mint. In the platform tenant, a PLATFORM_ADMIN may also mint, but only for themself, with an expiry of at most 90 days (advisor-confirmed exception to 0051 M2).
- Pending grant: the first administrator can be named by e-mail address at onboarding (`POST /onboarding` with `admin_email`). The grant is a pending record, not a membership. The person becomes TENANT_ADMIN, through a membership in the tenant's own `TENANT_ADMIN` group, at their first login through the tenant's own realm, only when the e-mail claim matches and `email_verified` is `true`. It binds once and is `TENANT_ADMIN` only (database CHECK); the operator has no route to add or replace an administrator afterwards (decision 0048).
- Number sequences (REQ-575): `:NumberSequencesManage` lets it define the human number of a record type (`POST` and `GET /number-sequences`); no other tenant role holds it.
- Must not: hold any platform-scope permission, or bypass the deactivated-tenant gate.

## TENANT_AUDITOR
- Scope: tenant, read-only.
- Who holds it: compliance officers, auditors, managers.
- Does: read definitions, instances, all tasks, audit, metrics, attachments, entity data, record history of a record (`GET /entities/records/:entity_type/:record_id/history`, restricted fields masked; REQ-516 S2, GH #2701), promotion reads (`PromotionsRead`, own-tenant, read-only; the stored-tenant check of ISS-1029 applies as for a tenant admin).
- Must not: write, export, import, issue attachment links, manage tokens, users, roles, modules or settings.

Record history consequence (REQ-516 S2, decision 0059 D2): the history route masks `field_values` with the caller's CURRENT restriction rows and grants, at read time. Restrictions are not stored per event. So if a restriction is removed later, the history written while it applied shows those values to an auditor who holds no grant. Restricted values in history follow the caller's current restrictions and grants, not the restrictions in force when each event was written. The history route reads the live events table only; archived or retention-removed events are not shown.

## The provisioner is a credential, not a role
The tenant provisioner (REQ-572, decision 0072 D6, QA only) is NOT one of the eight roles and adds no role, permission or `auth_context`. It is a hash-configured credential class
(`LETFLOW_PROVISIONER_CREDENTIAL_SHA256`, and a read-only class `LETFLOW_PROVISIONER_READONLY_CREDENTIAL_SHA256`) accepted only by the `/admin/v1` routes, outside `/api/v1`: create, get, suspend,
resume and expire a tenant. It cannot call any other route, read tenant data, act as an administrator or create a credential. The role count and the names above are unchanged. A PLATFORM_ADMIN outside the
platform tenant stays refused (0046 D1). Operating the credential: `docs/runbooks/tenant-provisioner-credential.md`.

## Known limitation: scoped approvers (stage 2)

Each task carries the scope node of the instance it was created for: `tasks.scope_node_id` is copied from `instance_projections.scope_node_id` when the task is created, and existing tasks were backfilled from their own instance (REQ-532 / GH #3091). A task of an instance with no scope node keeps NULL, which is fail-closed: a scoped caller never sees it, and a tenant-wide holder sees it as before. Scoped approvers therefore see the tasks of their scope, and the flip to `on` is no longer refused for scoped approvers.

Under scope enforcement a user who holds a task route only through scoped grants may see, claim or complete a task only if the user is in the task's routing role and holds a TASK_WORKER grant whose subtree covers the task's scope node. A grant of another role (PROCESS_OPERATOR, TENANT_ADMIN) never substitutes for the TASK_WORKER grant, and a task without a scope node is invisible to a scoped caller. Assigning and reassigning a task follow the route permission itself.

The RA-13 exemption is separate: a principal who holds the permission a task route is classified under tenant-wide (any role, a token principal, a platform admin) is exempt from the TASK_WORKER grant requirement, because tenant-wide on that permission is already tenant-wide authority over the route. The test is exactly whether the principal is allowed the route permission tenant-wide, never a role name. The routing-role checks stay in force for the exempt principal. A scoped TASK_WORKER whose grant does not cover the task is also exempt when the same user holds the permission tenant-wide through another role.

## Creating role bindings while scope enforcement is on

While a tenant's scope enforcement is `on`, no binding writer creates a tenant-wide grant row (REQ-519).

- `POST /roles` that would create a platform-role binding (a new binding, or a routing-role binding converted to a platform role) answers 409 `scope_required` and writes nothing except one `binding.refused` audit entry. Remedy: create the binding before enforcement is turned on, or set enforcement to off with a reason, create it, narrow its scope (stage-2 grants), and enable it again through the gate.
- Some writers still run but write NO grant row and say so: a repair of an existing binding that has no row, a rebind where no row moved, the platform-role seeding of a missing binding (the audit entry carries `rows = skipped_enforced`), the tenant-admin migration (the whole tenant is reported `skipped_enforced`), and the grant-row backfill (`skipped_enforced`, not an error). `POST /roles` and `POST /roles/:id/rebind` add `"grant_rows": "skipped_enforced"` to the body in that case only.
- Such a binding has no grant row, so its holders are denied until an admin grants scope. The integrity report (`GET /api/v1/tenant/scope-enforcement/integrity`, `bindings_without_row`) shows it, and it blocks a later flip to `on`.
- If the tenant's enforcement mode cannot be read, a binding write fails with a server error and writes nothing (it never proceeds as `off`).

## IdP role-claims sync while scope enforcement is on

While a tenant's scope enforcement is `on`, the login-time sync of IdP role claims never widens a user (REQ-519). A claimed role resolves to the group that binds it; if adding the user to that group would make the user tenant-wide for a role the user is not already tenant-wide for, the membership is withheld and login still succeeds.

- The WHOLE group is withheld when ANY platform role it binds would widen the user: a membership cannot be split by role, so the user does not receive the group's other roles either. The audit entries list only the widening roles. A group bound only as a process-routing role is never withheld.
- One audit entry per user and role records it, written in the sync's own transaction with the keys `user`, `group`, `role`, `trace_id` only (no IdP claim value): `grant.sync_suppressed` when the user already holds scoped grants for the role, `binding.pending_scope` when the user holds none. Repeated logins add no further entry for the same user, role and action.
- The user does not hold the withheld role (the coarse role check answers the existing 403). Remedy: an admin adds the user to a group whose grants for the role are scoped, and the user then holds exactly that scope.
- Admin `POST /groups/:id/members` and `DELETE /groups/:id/members/:user_id` write `group_member.added` / `group_member.removed` with a `scope_delta` (per role: from and to, at most 50 org-unit ids plus a count) in every mode.

## Turning scope enforcement on and off (operator procedure)

`PUT /api/v1/tenant/scope-enforcement` with `{"mode": "off" | "shadow" | "on", "reason": string?}` (REQ-519). Only an interactive (OIDC) user who holds TENANT_ADMIN tenant-wide can call it. API tokens, scoped admins, and a platform-tenant PLATFORM_ADMIN without TENANT_ADMIN get the uniform 403, for every transition (earlier releases let tokens and a platform admin move `off` to `shadow`; that is closed). The flag route for ANOTHER tenant from the platform scope is not built.

| From to | Result |
|---|---|
| `off` to `shadow` | the three stage-1 facts must hold (no binding without a grant row, scope tree consistent, no token above its owner) |
| `shadow` to `on` | the six gate facts below must hold |
| `off` to `on` | 409 `shadow_required`: `on` is reached only from `shadow` |
| `on` to `shadow` | no precondition; a `reason` is mandatory |
| `shadow` to `off`, `on` to `off` | no precondition; a `reason` is mandatory |

A refusal is a 409 `enforcement_precondition_failed` whose `failed` array lists every failing code, with the counts (`report`) and the evidence summary (`evidence`); a refused flip to `on` writes one `scope.enforcement_refused` audit entry. A successful flip writes `scope.enforcement_enabled` (the mode went up: off < shadow < on) or `scope.enforcement_disabled` (it went down) in the same transaction as the change.

The gate for `shadow` to `on`, stable codes: `bindings_without_row`, `org_inconsistent`, `tokens_exceed_owner` (tokens of a flagged service principal still count; the flagged-service-principal exemption covers only the mint subset check), `zero_tenant_wide_admins` (at least one active, interactive human with an explicit tenant-wide TENANT_ADMIN grant is required: token owners and flagged service principals do not count, because only such a user can turn enforcement off), `shadow_evidence_insufficient` (the tenant has been in `shadow` for at least `scope_shadow_min_days` days, default 7; at least `scope_shadow_min_requests` requests, default 100, over the window; requests on every date of the window; no `no_grant_rows` or `grants_unavailable` would-deny). The thresholds are server configuration only. `GET /api/v1/tenant/scope-enforcement/integrity` shows the same facts as a lock-free snapshot in its `on_gate` block (`findings` is the older informational list; `on_gate.blocking` is what the `on` flip will check).

The shadow period proves only the denials of tenant-wide and admin-plane routes; denials on the data path (compiler predicate, 404 equivalence, writes, bulk and import, F1) are proven by the REQ-518 tests and the end-to-end suite, not by shadow.

The flip request itself counts as a shadow request, and request counts include every authorized request of any principal, the flipping admin's own included, so the evidence rule is an operator-safety control, not an adversarial one.

## What `on` means in production today

Read this before flipping any tenant. Only pilot tenants may be flipped, and pilot use must wait for the open items: the tenant-level metadata reads for scoped users (RA-6, REQ-525..527, filed in #2862); the last-admin gap (#2869: a tenant stored `on` can end with nobody able to turn it off; the operator break-glass is built, GH #2883, and the guard that prevents the gap is built, GH #2869 part (a), 0051 A12); and the writer of `tasks.scope_node_id` (W3b, #2870), which REQ-532 (GH #3091) delivers, so it is no longer open. The decision-record amendment is 0051 A8-A10 (PR #2871); A11 records the GH #2883 break-glass; A12 records the GH #2869 last-admin guard.

1. A tenant that passes the gate can be set to `on` by an interactive tenant-wide TENANT_ADMIN, only from `shadow`, with an audit trail.
2. `on` delivers: the admin plane is closed to scoped admins, scoped users get a uniform 403 on every tenant-wide route, binding writers and IdP sync no longer widen anyone, and the grant tables fail closed.
3. `on` does NOT deliver data-level scoping in production. No installed module declares scope, so a scoped user sees no entity data. A task is visible to a scoped task worker only when its instance's scope node is in the worker's scope (`tasks.scope_node_id`, REQ-532); a task of an unscoped instance is visible only to tenant-wide holders.
4. The shadow period proves only the denials of tenant-wide and admin-plane routes (the sentence above).
5. Scoped users keep `GET /definitions`, `GET /definitions/search`, `GET /definitions/:id` and `GET /definitions/active/:name`; they still lose the other definition reads, entity-definition, instance and service reads until the tenant-level metadata follow-up (RA-6) ships. (The other definition reads are export, validation and delta.)
6. Do not scope the CANDIDATE binding: the exam routes stay tenant-wide, so a scoped CANDIDATE gets 403 and exam sessions break.
7. To turn `on` off: an interactive tenant-wide TENANT_ADMIN, with a mandatory reason. Tokens cannot. When no such admin can log in, use the platform-operator break-glass command `Letflow.Release.ScopeBreakGlass` (`mix letflow.scope_enforcement.break_glass`), which has no HTTP route and needs a mandatory reason and an operator label.
8. A platform tenant stored as `on` does not restrict its PLATFORM_ADMIN on platform-scope routes; grants never decide platform scope.

The scoped-approver count (`scoped_approvers`) is informational and never refuses the flip: it is shown in the `on_gate` counts of the integrity report, and a scoped task worker who holds no routing role is shown in `information`.

**Conditions and cautions for any flip** (they are not numbered items above and not limitations):

**Service accounts, several nodes, window restart.** They are the last three items of the section "Known limitations of an enforced tenant" below, and they are conditions for any flip.

**Refusal audit.** The `scope.enforcement_refused` entry is best-effort, written in its own transaction after the rollback. A refusal can therefore go unrecorded (the 409 is still returned and one constant log line `scope_enforcement_refusal_not_recorded` is written). A successful flip is audited in the same transaction and cannot go unrecorded.

**Gate #2869 (last admin).** In a tenant stored `on`, Letflow refuses (409 `last_interactive_tenant_wide_admin`) the removal, demotion, deactivation, rebinding, grant revocation or service-flagging of the last interactive explicit tenant-wide TENANT_ADMIN, counted exactly as gate fact `zero_tenant_wide_admins` counts. Token owners, flagged service principals and zero-row members do not count, because they cannot flip. The guard cannot see an administrator who exists in Letflow but can no longer log in at the identity provider; for that case see the operator break-glass (item 7). The other half, a platform-operator break-glass with no HTTP route, a mandatory reason and an audit entry, is delivered by GH #2883, and 0051 A11 and A12 record that the 0051 A7 token break-glass covers grant writes only.

## Known limitations of an enforced tenant

These hold for a tenant stored as `on` (REQ-519). The operator runbook `docs/runbooks/scope-enforcement-on.md` repeats them.

- LIMIT-IDP-SYNC-WHOLE-GROUP: in an `on` tenant the IdP role-claims sync adds NO membership to a group that binds a platform role which would make the user tenant-wide for that role. A membership cannot be split by role, so the non-widening roles of that group are withheld too (SEC A-7). The audit entry is `grant.sync_suppressed` when the user already holds scoped rows for the role and `binding.pending_scope` when the user holds none. Login still succeeds.
- LIMIT-POST-ROLES-409: `POST /roles` answers 409 `scope_required` in an enforced tenant for a new platform-role binding (or a routing-role binding converted to a platform role). Remedy: create the binding before enabling enforcement, or set enforcement to off with a reason, create it, narrow its scope, and enable again.
- LIMIT-IMPORT-UPSERT-404: a scoped caller's import in `upsert_by external_ref` mode is refused with the generic 404 (the generic not-found answer), even for rows inside its scope, because the upsert primitive (`Records.upsert_record_by_external_ref`) is not scope-aware. The refusal is in the entities router (`import_scope_check/6`, `lib/letflow/routers/entities/record_import.ex`, which does not match `create` for it and falls through to `:scope_refused`, mapped to the 404), not in the Records primitive, so tenant-wide callers are unchanged. Only `create` mode imports are offered to a scoped caller. A scope-aware upsert is not built.
- LIMIT-ON-FLAG: `on` is settable only from `shadow`, by an interactive tenant-wide TENANT_ADMIN, after the gate passes (REQ-519 2f-b); `off` to `on` is refused as `shadow_required`. The three limitations above still hold once `on` is settable.
- LIMIT-MULTI-NODE-SHADOW-FLUSH: the evidence flush before an `on` flip (`ShadowWindow.flush_evidence/0`) flushes only the local node's in-memory counters. With several nodes, the other nodes' unflushed would-deny counters are invisible to the gate (a failed flush only makes the gate stricter on that node). CONDITION: a multi-node deployment needs a cross-node flush of ShadowWindow counters before an `on` flip.
- LIMIT-IDP-SERVICE-ACCOUNT-ADMIN: "interactive" means the credential is `:oidc`. An unflagged IdP service account holding TENANT_ADMIN passes the flip PUT and is counted by gate fact 4 (`zero_tenant_wide_admins`) as an interactive admin. Flag every such account as a service principal (`PUT /users/:id/service-principal`) before any pilot.
- LIMIT-EMERGENCY-RESHADOW: the shadow window starts at the latest flip entry (both `scope.enforcement_enabled` and `scope.enforcement_disabled`), so an emergency `on` to `shadow` makes the shadow window restart: a full new window is needed before `on` can be set again. This is safe by design.

## Matrix

Format, parsed by the REQ-448 parity test: one row per permission; first column the permission atom
without the colon; then one column per role in `roles/0` order (eight columns); cells `yes` or `no`;
final column `scope` (`platform` or `tenant`); whitespace-separated, first line is the header.
PLATFORM_ADMIN `yes` means as evaluated in the platform tenant. The rows cover every core permission of
`Authorization.core_permissions/0` (REQ-446 names, `TenantSettingsManage` split, `PlatformServicesManage`,
REQ-448's `AttachmentLinksIssue`, which gates `POST /instances/:id/attachments/:attachment_id/link`, and REQ-536's `DocumentHold` and `DocumentsRetentionManage`, which gate the document hold and retention-policy routes, and REQ-551's `LabelsManage`, which gates the tenant label-override write routes `PUT` and `DELETE /labels/:message_id`, REQ-565's `IntegrationMappingsManage`, which gates the tenant integration-mapping routes, REQ-555's `EntitiesViewsManage`, which gates the create, update and delete routes of saved list views, REQ-563's `NotificationTemplatesManage`, which gates the tenant notification-template routes under `/notification-templates`, REQ-579's `DocumentPrintTemplatesManage`, which gates the tenant print-template override routes under `/documents/print-overrides` (TENANT_ADMIN only), REQ-561's `ScheduledJobsManage`, which gates the tenant scheduled-job routes under `/scheduled-jobs`, and REQ-575's `NumberSequencesManage`, which gates `POST` and `GET /number-sequences` (tenant number sequence definitions; TENANT_ADMIN only, the other tenant roles are refused)).
REQ-446 classified `GET /promotions/platform-events` as tenant scope under `PromotionsRead`
(see the correction note appended to decision 0046); no platform promotion permission exists.
Module (Catalog) permissions are all tenant scope and are not listed in the matrix below.

Module permissions. Module `procurement` (GH #3162, REQ-544) declares `ProcurementRequestWrite`,
`ProcurementRequestRead` and `ProcurementRequestDecide` (records an approve, reject or return of a
purchase request version), tenant scope. It declares no `role_grants`, so in this slice only
TENANT_ADMIN and PLATFORM_ADMIN hold them; a requester never decides their own request (the module
refuses it), and giving requesters write access or approvers the decide permission is a later
widening that needs per-tenant grant snapshots. The effective rows are in
`priv/permission_matrix/effective.golden`.
Conditional cells: the 0046 D3 binding condition (source-tenant ownership proven) is met by REQ-446
(`lib/letflow/routers/tenants.ex:451`, `lib/letflow/api/tenant_target.ex:31-39`); the TENANT_ADMIN `yes`
cells for PromotionsRead and PromotionsManage stand. The TENANT_AUDITOR `PromotionsRead` cell is `yes`
(0046 D6; the stored-tenant check of Q-1011 / ISS-1029 has merged, see the closure note of 0046).

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
MyAccessRead                    yes            yes              yes              yes         yes          yes       yes          yes            tenant
EntitiesRestrictionsManage      yes            no               no               no          no           no        yes          no             tenant
PromotionsRead                  yes            no               no               no          no           no        yes          yes            tenant
PromotionsManage                yes            no               no               no          no           no        yes          no             tenant
DefinitionsRollback             yes            no               no               no          no           no        yes          no             tenant
TenantSettingsManage            yes            no               no               no          no           no        yes          no             tenant
PlatformServicesManage          yes            no               no               no          no           no        no           no             platform
AttachmentLinksIssue            yes            yes              yes              yes         no           no        yes          no             tenant
ScriptsWrite                    yes            yes              no               no          no           no        yes          no             tenant
ScriptsPublish                  yes            no               no               no          no           no        yes          no             tenant
DocumentHold                    yes            no               no               no          no           no        yes          no             tenant
DocumentsRetentionManage        yes            no               no               no          no           no        yes          no             tenant
IntegrationMappingsManage       yes            no               no               no          no           no        yes          no             tenant
LabelsManage                    yes            no               no               no          no           no        yes          no             tenant
EntitiesViewsManage            yes            no               no               no          no           no        yes          no             tenant
NotificationTemplatesManage     yes            no               no               no          no           no        yes          no             tenant
NumberSequencesManage           yes            no               no               no          no           no        yes          no             tenant
ScheduledJobsManage             yes            no               no               no          no           no        yes          no             tenant
DocumentPrintTemplatesManage      yes            no               no               no          no           no        yes          no             tenant
```
