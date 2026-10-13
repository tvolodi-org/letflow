# 0046 -- Admin scopes and the role charter: platform scope vs tenant scope, eight built-in roles, PLATFORM_ADMIN only in the platform tenant

Status: RATIFIED by the user (repo owner) on 2026-10-05, after the role-system audit
AUDIT-ROLES-20261005 (ISS-0994). Decisions D1..D10 below are settled; this record writes them
down and does not re-decide them. D2 carries a ratified refinement (config-pinned, fail-closed
platform tenant), relayed by the supervisor session on 2026-10-06 as the user's ratified
definition; it supersedes ISS-0994's "config or column" option. ISS-0993's design only implements it.

Date: 2026-10-05. Drafted by `CODE-DESIGNER` (REQ-445, queue task Q-962, GH#2233). Owner: `ORCH`.

Supersedes / amends, by reference only. Precisely:
(1) the role COUNT of `0013-authorization-role-set.md` and its CANDIDATE addendum (six becomes
eight), and nothing else in 0013; (2) the `:ModulesManage` grant sentence of 0039 D5 ("Who may
install"), see C1; (3) 0013's addendum text calling `POST /users` and `POST /tokens`
"`PLATFORM_ADMIN`-only" is historical, the current grant is per D5, see C2; (4) 0039 review note R2
(the `PLATFORM_ADMIN` catch-all) is amended by D4, see C3. Where this record narrows or replaces a passage of another record,
the "Consistency" section names the passage and the decision. This record never edits 0013 or any
other existing record.

Reader's guide / citation. Decisions in this record are cited as "0046 D<n>" (for example
"0046 D4"). The role charter in plain language is `docs/roles.md`; its matrix is the machine-
readable form of D3-D6 and is the TARGET state after REQ-446, REQ-447 and REQ-448. Implementing
work: the platform-tenant mechanics are ISS-0993 (queue Q-960; ISS-0994 is its duplicate record,
and ISS-0993 cross-references this record by D-number and keeps only implementation notes);
named permissions are REQ-446; TENANT_ADMIN and the migration are REQ-447; TENANT_AUDITOR and the
parity test are REQ-448.

## Context

Verified in the audit. There are six built-in roles (`Letflow.Api.Authorization.roles/0`).
`PLATFORM_ADMIN` is seeded in every tenant and is allowed everything
(`lib/letflow/api/authorization.ex`, `core_role_allows?(:PLATFORM_ADMIN, _permission)`), so a
customer's own administrator holds platform-operator powers (ISS-0994, proven). No tenant-admin
role exists, yet docs and UAT scenarios speak of one. Decision 0013 settles which role NAMES exist,
not what each role is responsible for. Decision 0044 already uses the words "platform operator"
and "tenant admin" consistently with this model.

Security rationale. A role that can create and deactivate tenants, run platform migrations and
retire event partitions must not be obtainable by a customer. The rule is INV-10 (landing via
letflow-3's rules PR; "platform authority bound to the platform tenant"): platform authority is
bound to the platform tenant, and a platform-scope permission is never honoured for a caller of
any other tenant. This record does not edit `security-invariants.md`.

## Decisions

### D1. Two scopes

PLATFORM scope = the organisation operating Letflow; it acts on the tenant registry and on things
shared by all tenants. TENANT scope = one customer organisation; it acts only inside its own
tenant.

### D2. The platform tenant

The PLATFORM TENANT is the operator's own tenant: exactly one. It is CONFIG-PINNED: identified by
server-side configuration, never by any column or API a tenant can write. It FAILS CLOSED: if the
configuration is missing or invalid, no tenant is the platform tenant, so every platform-scope
permission is denied for every caller. The operator role is the EXISTING `PLATFORM_ADMIN` role,
honoured ONLY in the platform tenant; there is NO `PLATFORM_OPERATOR` role. A platform-scope
permission is honoured only for a caller of the platform tenant (INV-10, landing via letflow-3's
rules PR; INV-10 is not yet in force, and until it lands this record and ISS-0993's acceptance
criteria are the authority). The config-pinned, fail-closed definition is a USER-RATIFIED
refinement of D2 (relayed 2026-10-06), superseding ISS-0994's "config or column" option. The
implementing fix for these mechanics is ISS-0993 (Q-960), whose design only implements this
definition; TENANT_ADMIN (REQ-447) is not part of that fix.

Enforcement points. Every path that honours `PLATFORM_ADMIN` must be bound to the platform tenant
(ISS-0993 implements; paths verified by reading and grep on this branch):

1. `Authorization.evaluate_access/2`, the `:Unknown` branch (`authorization.ex` ~931-937).
2. The catch-all `core_role_allows?(:PLATFORM_ADMIN, _permission)` (`authorization.ex` ~1130).
   Until REQ-446 has proven or added the source-tenant ownership check (D3 binding condition),
   `:PromotionsRead`, `:PromotionsManage`, the promote route and the platform-events permission are
   treated as platform scope FOR THE CATCH-ALL: honoured only for `PLATFORM_ADMIN` in the platform
   tenant; a `PLATFORM_ADMIN` of any other tenant is denied them.
2a. `Authorization.is_task_worker_only?/1` (`authorization.ex` 964, used at ~950): it and every other
   reference to the `PLATFORM_ADMIN` role must use the platform-tenant-aware check.
3. `Letflow.Plugs.TenantStatus`: the deactivated-tenant exemption for `PLATFORM_ADMIN`
   (`plugs/tenant_status.ex` ~102).
4. Every hand-built `AccessContext`. Grep finds exactly two constructions:
   `Letflow.Plugs.Authorize` (`plugs/authorize.ex` ~103) and `routers/entities.ex` ~2238
   (`check_unredacted_permission/2`). Both must carry the platform-tenant flag.
5. Role-claim sync, token issuance (`Identity.create_token/3`), group-member add, role upsert and
   tenant provisioning: each must refuse to grant, seed or accept `PLATFORM_ADMIN` outside the
   platform tenant.

Rules for the flag. The platform-tenant flag on `AccessContext` defaults to false and is set only
from the server-side-configuration-resolved tenant, never from a request, token or claim value.
The platform tenant itself cannot be deactivated (409; ISS-0994 fix_direction 6). `TENANT_ADMIN`
is not allowed the `:Unknown` endpoint.

### D3. Every core permission has exactly one scope

The scope table below lists every atom of `Authorization.core_permissions/0` plus the permissions
REQ-446 names (marked planned). Platform scope: `:TenantsManage` and whatever REQ-446 classifies as
platform. Everything else, and every module (`Letflow.Modules.Catalog`) permission, is tenant scope.
Rule, not a list: every Catalog permission is tenant scope.

Binding condition on tenant classification. `:PromotionsRead`, `:PromotionsManage` and
`POST /tenants/:test_tenant_id/promote/:process_key` are tenant scope ONLY IF REQ-446 proves (citing
file:line) or adds a source-tenant ownership check. Today the code only rejects a `:production`
source (`lib/letflow/definitions/promotion.ex` ~171-176, `tenant_classifier.(source_tenant_id) ==
:production`) and `PromotionPlan.default_permission_checker/2` always returns `true`
(`lib/letflow/definitions/promotion_plan.ex` ~179-180; see also the "permission_checker gap"
section of `lib/letflow/routers/promotions.ex` ~145-160 and the route comment in
`lib/letflow/routers/tenants.ex` ~196-204, "`:test_tenant_id` is caller-supplied and IS a
cross-tenant read"). Until that holds, no role other than `PLATFORM_ADMIN` may be granted them, and
for the catch-all they are treated as platform scope (D2 enforcement point 2): a `PLATFORM_ADMIN` of
a non-platform tenant is denied them. REQ-446 must ship a test showing that denial, plus a
cross-tenant negative test (tenant A's admin promoting from tenant B's test tenant gets 403/404 per
INV-5). REQ-448 must treat the TENANT_ADMIN and TENANT_AUDITOR promotion cells as conditional on
those tests. If
neither proof nor check is achievable they are reclassified platform scope and the REQ-447 and
REQ-448 grants change.

Platform-events. `GET /promotions/platform-events` returns the platform sentinel stream whose
payloads name other tenants (`lib/letflow/design/iss0733-promotion-audit-and-platform-events-read.md`
section 2.3 point 2, ~lines 262-266: "payload names another tenant by id (`source_tenant_id`)"). It
is therefore expected PLATFORM scope under its OWN permission, `PLATFORM_ADMIN` only, and must never
be folded into `:PromotionsRead` unless REQ-446 proves it returns only the caller's rows.

### D4. PLATFORM_ADMIN

`PLATFORM_ADMIN` keeps its name and its allow-everything rule but exists only in the platform
tenant: it is not seeded, not issuable and not honoured in any other tenant. It has no power inside
a customer tenant and no access to a customer's business data.

Transition. D4 takes full effect when REQ-447 merges; between the Q-960 fix and REQ-447 a tenant PLATFORM_ADMIN holds tenant-scope powers only (own tenant; no platform-scope permission; no cross-tenant promotion; the deactivated-tenant exemption already ends with the Q-960 fix).

### D5. TENANT_ADMIN (new)

Every tenant-scope permission, core and module, in its own tenant; never a platform-scope
permission; no exemption from the deactivated-tenant gate. It is the tenant's owner role: users,
groups, role bindings, API tokens, settings and branding, module and solution install, audit log.

### D6. TENANT_AUDITOR (new)

Read-only inside its own tenant. The exact permission list is REQ-448's (build item 1), copied
here and into the table and `docs/roles.md`: `:DefinitionsRead`, `:InstancesRead`, `:TasksRead`,
`:AuditRead`, `:MetricsRead`, `:AttachmentsRead`, `:EntitiesDefinitionsRead`, `:EntitiesQuery`,
`:EntitiesAggregate`, `:EntitiesAttachmentsRead`, `:HelpRead`, `:MembershipsRead`, `:MyModulesRead`
(already granted to every role), and the read permission(s) REQ-446 introduces for promotions
(`:PromotionsRead`, subject to the binding condition under D3). Nothing else: no write, manage,
export, import, token, user, role, module or settings permission, and no module (Catalog)
permission unless a module's own manifest grants it. `GET /tasks` returns all tenant tasks for it.

### D7. Unchanged roles

`PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TASK_WORKER`, `CANDIDATE` and `AGENT_RUNNER` are unchanged.

### D8. Migration of existing admins

Existing non-platform-tenant `PLATFORM_ADMIN` members and API tokens are migrated to `TENANT_ADMIN`
(REQ-447). The migration is hygiene. The primary control is the evaluation-time binding of ISS-0993:
once it lands, a stale `PLATFORM_ADMIN` claim, row or token outside the platform tenant is denied
every platform-scope permission and the `:Unknown` endpoint at evaluation time, and keeps
tenant-scope powers in its own tenant only until REQ-447 migrates it (the D4 Transition). Order: ISS-0993 lands before or together with REQ-447; REQ-447 must not ship alone.

### D9. Deferred, NOT built

Deferred until a customer asks: a read-only platform support role and a delegated user-manager
role. Break-glass (supervised platform access into a customer tenant) is deferred with them; no
such access exists.

### D10. The role set stays closed

The role set stays closed (0013, 0039 D4): a module cannot create a role.

## Permission scope table (D3)

Caption. The code-derived rows were produced by RUNNING the code in the worktree
(`mix run --no-start -e 'IO.inspect(Letflow.Api.Authorization.core_permissions(), limit: :infinity)'`),
which returned 35 atoms; this was not read from documentation. Every atom has exactly one scope.
The CODE-DESIGN-VALIDATOR re-derives the list the same way.

| Permission | Scope | Reason |
|---|---|---|
| `:DefinitionsWrite` | tenant | create/change process definitions of the caller's tenant |
| `:DefinitionsRead` | tenant | read the caller's tenant definitions |
| `:InstancesStart` | tenant | start instances in the caller's tenant |
| `:InstancesCancel` | tenant | cancel instances in the caller's tenant |
| `:InstancesRead` | tenant | read the caller's tenant instances |
| `:TasksRead` | tenant | read the caller's tenant tasks |
| `:TasksComplete` | tenant | complete a task of the caller's tenant |
| `:TasksAssign` | tenant | assign tasks inside the caller's tenant |
| `:UsersGroupsRolesManage` | tenant | users and groups of one tenant |
| `:TokensManage` | tenant | API tokens of one tenant |
| `:AuditRead` | tenant | the tenant's own audit chain |
| `:DlqOperate` | tenant | the tenant's own dead-letter queue |
| `:MetricsRead` | tenant | the tenant's own metrics |
| `:WebhooksManage` | tenant | the tenant's own webhooks |
| `:TenantsManage` | platform | tenant registry, onboarding, platform migrations, event retention, cross-tenant operations |
| `:RolesManage` | tenant | custom role bindings of one tenant |
| `:AttachmentsManage` | tenant | attachments of the caller's tenant |
| `:AttachmentsRead` | tenant | attachments of the caller's tenant |
| `:InstancesAdvanceTimer` | tenant | timer control inside the caller's tenant |
| `:EntitiesDefinitionsRead` | tenant | the tenant's entity definitions |
| `:EntitiesDefinitionsWrite` | tenant | the tenant's entity definitions |
| `:EntitiesRecordsWrite` | tenant | the tenant's entity records |
| `:EntitiesQuery` | tenant | query the tenant's entity records |
| `:EntitiesAggregate` | tenant | aggregate the tenant's entity records |
| `:EntitiesRecordsExport` | tenant | redacted export of the tenant's records |
| `:EntitiesRecordsExportUnredacted` | tenant | unredacted export of the tenant's records |
| `:EntitiesRecordsImport` | tenant | import into the tenant's records |
| `:EntitiesAttachmentsManage` | tenant | entity attachments of the tenant |
| `:EntitiesAttachmentsRead` | tenant | entity attachments of the tenant |
| `:PublicReadHandlesIssue` | tenant | issue public read handles for the tenant's data |
| `:HelpRead` | tenant | read help content (no tenant data crosses) |
| `:MembershipsRead` | tenant | the caller's own memberships |
| `:ModulesManage` | tenant | install modules and solutions in the caller's own tenant (see Conflicts flagged, C1) |
| `:MyModulesRead` | tenant | list the caller's own tenant's installed modules |
| `:EntitiesRestrictionsManage` | tenant | field-level restrictions of the tenant |

Planned rows. NOT derived from code: they do not exist until REQ-446 / ISS-0993 land. Scope is
fixed here; names marked "proposed" may be adjusted by REQ-446 but must keep the read/write split.

| Permission (planned) | Scope | Reason |
|---|---|---|
| `:PromotionsRead` (proposed, REQ-446) | tenant | the GET promotion routes; subject to REQ-446 proving the caller's tenant owns the source test tenant |
| `:PromotionsManage` (proposed, REQ-446) | tenant | create, plan, approve, reject, apply, run-assertions and cross-tenant promote of the caller's own test/production pairing |
| `:DefinitionsRollback` (proposed, REQ-446) | tenant | roll back a definition of the caller's tenant |
| `:TenantSettingsManage` (name proposed, ISS-0993 split) | tenant | `PATCH /tenant/settings` is split off `:TenantsManage` so a tenant can edit its own settings; attributed to ISS-0993, not REQ-446 |
| platform-events permission, to be named by REQ-446 | platform | `GET /promotions/platform-events`; `PLATFORM_ADMIN` only (see D3 Platform-events) |
| route `POST /tenants/:test_tenant_id/promote/:process_key` (planned: takes `:PromotionsManage`) | tenant, conditional | route row; tenant scope only if the D3 binding condition is met |

## Consequences and limitations

Cross-tenant promotion becomes operator-only for now (product limitation): a customer cannot promote test -> production by itself until a tenant pairing model exists. A follow-up requirement for that model (a test tenant bound to its production tenant, verified server-side) is being drafted by `letflow-9a` and is NOT part of 0046; it changes no decision here.

## Open risks and questions

None of the six items is ratified. Items 1 to 3 are questions and carry their stated defaults;
items 4 to 6 are risks.

1. Last-admin protection. Removing the last `TENANT_ADMIN` member, or deactivating that user, locks
   a tenant out. OPEN RISK. Default: nothing is built by this series; the risk is recorded here.
2. Break-glass. Whether a platform operator ever needs supervised access into a customer tenant.
   DEFERRED with D9. Default: no such access exists.
3. Realm role names in existing tenant realms. Once ISS-0993's per-request binding lands, a stale
   `PLATFORM_ADMIN` claim, row or token outside the platform tenant is denied every platform-scope
   permission and the `:Unknown` endpoint, and keeps tenant-scope powers in its own tenant only
   until REQ-447 migrates it; the REQ-447 migration is hygiene (see
   D8 for the order). A realm that still issues `PLATFORM_ADMIN` leaves that tenant with no admin
   until it issues `TENANT_ADMIN`. Default: no alias. REQ-447 handles the data; the issuance paths
   in D2 enforcement point 5 close.
4. The platform tenant losing its last `PLATFORM_ADMIN`. OPEN RISK, same lockout class as risk 1.
5. A configuration typo fails closed and disables the operator console. Recovery path: fix the
   configuration and restart; there is no in-band override.
6. The migration can leave a tenant with zero admins (same lockout class as risk 1).

Checks for REQ-448. Field-level authorisation and redaction apply to `TENANT_AUDITOR`'s reads with no
role-based bypass (INV-2). Module-settings writes keep secrets by reference only (INV-4).

## Consistency with existing decision records

Passages quoted from the files as they stand in this worktree.

### 0013 (role set)

> "**Upward. The five-role matrix in `Letflow.Api.Authorization` is the contract. Every realm Letflow authenticates against must define all five roles, including `PROCESS_OPERATOR`.**"

SUPERSEDED as to the count by D5 and D6 via the addendum below; the principle (the matrix in
`Authorization` is the contract, realms must define every role) stays and now covers eight.

> "Read this addendum, not the body above it, for the current role count"

The addendum's "sixth role" count is SUPERSEDED by D5 and D6 (eight roles). This record is now
the place to read for the current count.

> "`POST /users` — `UsersGroupsRolesManage`, `PLATFORM_ADMIN`-only via the catch-all clause — and `POST /tokens` — `TokensManage`, `PLATFORM_ADMIN`-only"

Historical statement of fact at 2026-09-14. SUPERSEDED for the grant by D5 (TENANT_ADMIN holds
both in its own tenant) and D4.

> "The seeded operator account holds `PROCESS_OPERATOR`, **not** `PLATFORM_ADMIN`."

CONSISTENT (D7 leaves `PROCESS_OPERATOR` unchanged).

### 0029 (SolutionPack scope; role seeding out of the pack)

> "the SAME `:PROCESS_DESIGNER` actor who can install a pack already holds `:RolesManage` directly"

CONSISTENT (D7: `PROCESS_DESIGNER` unchanged). TENANT_ADMIN seeding (REQ-447) is done by tenant
provisioning and backfill, not by the pack, so 0029's title rule "role seeding both stay OUT of the
pack" is unaffected.

### 0038 (tenant membership lookup)

> "The `tenant_memberships` row that makes two per-tenant accounts cross-referenceable is created only by explicit `PLATFORM_ADMIN` action"

CONSISTENT with D1/D4: linking tenants is platform-scope work performed by the operator. At the
time of writing no HTTP write route for memberships exists (`/me/memberships` is read-only under
`:MembershipsRead`); any future write route must be platform scope (`:TenantsManage` or a new
platform permission).

### 0039 (platform / module / solution layering)

0039 D5 ("Who may install"):

> "**Who may install.** A new core permission `:ModulesManage`, granted to `PLATFORM_ADMIN` only (same pattern as `:TenantsManage`), gates module install, solution install (D6) and module-settings writes (D7)."

SUPERSEDED by D3 (`:ModulesManage` is tenant scope; "same pattern as `:TenantsManage`" no longer
holds) and D5 (TENANT_ADMIN holds module and solution install). See C1.

> "`PLATFORM_ADMIN`'s existing catch-all is unchanged."

AMENDED by D4: the clause and name stay, but it is honoured only in the platform tenant.

> "A module cannot create a role and cannot grant a core permission."

CONSISTENT with D10.

> "the platform role `CANDIDATE` is exam-specific ... recorded as an open item in the stage file"

CONSISTENT (D7: `CANDIDATE` unchanged; the open item is untouched).

### 0044 (hybrid identity model)

> "**Tenant-admin autonomy.** Full inside the realm if the platform operator hands a realm admin to the tenant, none by default; Letflow itself exposes no realm administration."

CONSISTENT: platform operator = platform scope (D1/D2); tenant admin = TENANT_ADMIN (D5), which does
not administer realms.

> "Post-login: the memberships switcher lists both only if a `PLATFORM_ADMIN` linked them (0038)."

CONSISTENT (see 0038 above).

> "Default: the platform operator ... with `PLATFORM_ADMIN` humans and a break-glass admin; tenant admins have no Keycloak admin rights."

CONSISTENT with D2/D5; the Keycloak break-glass admin is an infrastructure account, not a Letflow
role, and is separate from the deferred item in D9.

### Related records checked

- 0002 (OIDC integration): its only role passage is the custom role registry being uncoupled from
  `src/oidc/`; CONSISTENT (unchanged).
- 0006 (identity tables, schema per tenant): "cross-tenant admin/reporting queries against a
  superuser connection" is a quotation of 0003 about a database connection, not a role; CONSISTENT.
- 0035 (frontend login delegated to Keycloak): "the user's role set is decoded" is SH-01's text;
  CONSISTENT (the SPA still reads roles from the token; eight names instead of six).
- 0042 (email-first login): memberships are "admin-linked switch targets created only by
  `PLATFORM_ADMIN` action"; CONSISTENT (platform scope).
- 0043 (email-first login BA decisions): `tenants.login_disclosure_mode` is "Writable only by
  `PLATFORM_ADMIN`; never present in any tenant-admin-readable or pre-auth response"; CONSISTENT and
  reinforced: it is written through `PATCH /tenants/:slug` under platform-scope `:TenantsManage`,
  and the `:TenantsManage` split of `PATCH /tenant/settings` must keep that attribute out of the
  tenant-writable route.

### Conflicts flagged for REVIEWER

- C1. 0039 D5 ("Who may install") states `:ModulesManage` is "PLATFORM_ADMIN only (same pattern as `:TenantsManage`)".
  The ratified model (D3 "everything else is tenant scope", D5 "module and solution install" for
  TENANT_ADMIN) makes `:ModulesManage` tenant scope, granted to TENANT_ADMIN. This is a deliberate
  supersession of that sentence by 0046 D3/D5, not an accident; REVIEWER to confirm, and to decide
  whether 0039 needs a pointer line (a new commit, since this record never edits it).
- C2. 0013's addendum describes `POST /users` and `POST /tokens` as `PLATFORM_ADMIN`-only. After
  REQ-447 TENANT_ADMIN holds them in its own tenant. Historical text only; flagged so a reader of
  0013 is not misled (read 0046 first for the current grants).
- C3. 0039's "`PLATFORM_ADMIN` catch-all ... still covers module permissions" (review note R2)
  becomes true only in the platform tenant (D4); inside a customer tenant module permissions are
  covered by `TENANT_ADMIN` (D5) and by module `role_grants` (D10).
  Terminology note: 0039's "platform role `CANDIDATE`" means a built-in role, not platform scope.

## REVIEWER sign-off

REVIEWER (pass 3, 2026-10-06, REQ-445 / Q-962): PASS. D4 Transition, D8 and open risk 3 are consistent; the Transition leaves D4's end state unchanged; no unratified decision added; no contradiction with D1..D10, REQ-446/447/448 or 0047. Earlier passes failed on D2 provenance, 0039 D4/D5 citation, supersession header, D6 list, and Transition vs D8 wording; all fixed.
Note: D2's config-pinned/fail-closed refinement rests on the user's ratification as relayed by the supervisor session on 2026-10-06; ORCH keeps that traceable. Non-blocking: point 5 says "ISS-0993 implements" while REQ-447 build 2 owns the same refusals.

## SECURITY-REVIEWER sign-off

SECURITY-REVIEWER (pass 3, 2026-10-06, REQ-445 / Q-962): PASS. INV-1/INV-5/INV-10 reasoning checked against D2 (points 1-5, 2a), the D3 binding condition, the D4 Transition and the D8 order. Tenant PLATFORM_ADMIN promotion/platform-events exposure closed.
Conditions carried forward: REQ-446 must ship the tenant-PLATFORM_ADMIN denial test plus a cross-tenant negative test; REQ-448 promotion cells stay conditional on them; REQ-447 must not ship before ISS-0993; re-review required on the Q-960 code and on REQ-446 before any promotions permission goes to a non-platform role. Suggested (REQ-ANALYST): add those criteria to REQ-446.

## Correction of the D3 scope table (REQ-446), dated 2026-10-06 (UTC)

This is a CORRECTION of one row of the D3 permission scope table (the planned row "platform-events permission, to be named by REQ-446 | platform"), not an amendment of a decision. No decision text above is repeated or changed.

Route: `GET /promotions/platform-events`.

New classification: tenant scope, permission `:PromotionsRead`. No separate platform-events permission exists.

Evidence that the route reads only the caller's own schema: the handler takes `opts = conn.assigns.scoped_opts` and passes `prefix: Keyword.fetch!(opts, :prefix)` to the store (`lib/letflow/routers/promotions.ex:859,865`); `EventStore.list_platform_events/1` reads the prefix from its params and runs `Repo.all(prefix: prefix)` (`lib/letflow/event_store.ex:1111,1123`); `scoped_opts` is built from `auth_context.tenant_id` by `Context.scoped_repo_opts/1` and assigned in `lib/letflow/plugs/authorize.ex:103,132`. No request value selects the schema.

Residual: the event payload can name other tenants' ids. Tenant-id keys (any key ending in `tenant_id`, at any depth) are omitted from the response for every caller that is not a platform-tenant operator (REQ-446 design, sections 4a and 4b). Not closed by that rule, and tracked as an exception: Q-981 / GH #2266 / ISS-0999 (`source_definition_id`, `review_id`, `actor_id`; to be handled with an allowlist per event type).

The D3 binding condition for `:PromotionsRead`, `:PromotionsManage`, `:DefinitionsRollback` and the promote route is met by the source-tenant ownership check of REQ-446 design section 4, citing `lib/letflow/routers/tenants.ex:451` and `lib/letflow/api/tenant_target.ex:31-39`.

## Closure of the platform-events payload residual (ISS-0999 / Q-981), 2026-10-06

This section is appended; no earlier text in this record was changed and no decision text changed. It records that the residual stated in the REQ-446 correction above (the event payload can name other tenants' ids; `source_definition_id`, `review_id`, `actor_id` not closed by the key-suffix `tenant_id` rule; tracked as Q-981 / GH #2266 / ISS-0999) is closed for `GET /promotions/platform-events`.

Design: `lib/letflow/design/iss0999-platform-events-allowlist.md`. For this route it supersedes section 4a of the REQ-446 design (key-suffix matching).

Route scope is unchanged: tenant scope under `:PromotionsRead` (`lib/letflow/routers/promotions.ex:221`).

What a caller that is not a platform-tenant operator now sees:

- The payload is shaped by a per-event-type allowlist (`@platform_event_allowlist`, `lib/letflow/routers/promotions.ex:954`; applied in `shape_platform_event_payload/3`, line 999-1020). Only allowlisted scalar keys are kept (map or list values are omitted, fail closed).
- Tenant-id keys on the allowlist are kept only when the value is the caller's own tenant id.
- `source_definition_id`, `review_id` and the teardown `error` text are omitted.
- The item has no `actor_id` key (`platform_event_map/2`, line 980; the actor may be a user of another tenant).
- An event type with no allowlist entry returns payload `{}` (the event itself is kept).
- A platform-tenant operator sees the payload and `actor_id` unchanged.

Remaining tracked item: `GET /promotions/:id/context` keeps the key-suffix rule of the REQ-446 design (section 4b). Its allowlist follow-up is tracked as Q-1003 / GH #2291 / ISS-1021.

## Closure of the /context payload residual (ISS-1021 / Q-1003), 2026-10-06

This section is appended; no earlier text in this record was changed and no decision text changed. It records that the tracked item left open by the ISS-0999 closure section above (`GET /promotions/:id/context` keeping the key-suffix `tenant_id` rule of the REQ-446 design, section 4b) is closed by a top-level key allowlist on `serialised_plan` for every caller that is not a platform-tenant operator. Route scope and permission are unchanged (tenant scope, `:PromotionsRead`; `authz_get "/:id/context"`, `lib/letflow/routers/promotions.ex:232`).

Design: `lib/letflow/design/iss1021-context-plan-allowlist.md`. For this route it supersedes section 4b of the REQ-446 design (key-suffix matching).

What a non-operator now sees in `serialised_plan` (`shape_plan/2`, `lib/letflow/routers/promotions.ex:1080-1119`; allowlist `@plan_allowlist`, line 1054; applied in `review_context_map/2`, line 548):

- `process_key` and `base_version`, when scalar.
- `source_tenant_id` and `target_tenant_id`, only when the value is the caller's own tenant id.
- `source_definition_id` and `target_definition_id`, only when scalar and the same side's tenant id (`source_tenant_id` / `target_tenant_id`) is the caller's own tenant id.
- `entries`, as stored, forced to a list (`[]` when absent or not a list).
- Every other top-level key (unknown and legacy keys, including odd tenant-id spellings and a nested `meta`) is dropped.
- A plan that is not a map becomes `{"entries": []}` (`lib/letflow/routers/promotions.ex:1121`).

A platform-tenant operator sees the plan unchanged (`shape_plan(plan, :operator)`, line 1078). The other keys of the context envelope are unchanged, including `requested_by` (accepted, residual R5).

Remaining STANDING TRACKED exception R1 (INV-10), not closed here: `entries` is returned as stored. Plan `entries` carry both the source and the target graph content (`lib/letflow/definitions/promotion_plan.ex:199-243`), and an operator-created review that names foreign tenants lives in the platform tenant's schema. A non-operator reader of that schema, and legacy rows, can therefore read other tenants' graph content through `entries`. Tracked as Q-1005 / GH #2297 / ISS-1023.

## Closure of the plan entries residual (ISS-1023 / Q-1005), 2026-10-06

Design: `lib/letflow/design/iss1023-context-entries-own-sides.md`. Spec: `test/specs/ISS-1023.md`. No earlier text and no decision text above is changed; this section is appended. Route scope and permission are unchanged (`GET /promotions/:id/context`, tenant scope, `:PromotionsRead`, `lib/letflow/routers/promotions.ex:233`).

R1 of the ISS-1021 closure section above ("`entries` is returned as stored", tracked as Q-1005 / GH #2297 / ISS-1023) is closed for plans naming a foreign tenant. Plan `entries` carry both tenants' graph content (nodes, edges, variable schemas, service bindings, module refs), and an operator-created review naming foreign tenants B and C lives in the platform tenant P's schema, so a non-operator reader of P's schema could receive B's and C's content.

The rule (a non-operator only): `entries` is the stored list, unchanged, only when BOTH stored `source_tenant_id` and `target_tenant_id` are the caller's own tenant id (case-insensitive, the same `own_tenant_value?/2` test as the shown tenant ids); in every other case, including a missing, null or non-binary id, it is `[]` (fail closed). It is all-or-nothing, not per entry or per side, because an entry diffs the target graph against the source graph and has no single owner. `[]` was chosen over a 404 so the response keeps the shape the SPA reads (`serialised_plan.entries` as a list) and a 404 still means "not in your schema". The operator view is unchanged.

Evidence (`lib/letflow/routers/promotions.ex`, current line numbers):

- `entries_gate: ["source_tenant_id", "target_tenant_id"]` in `@plan_allowlist`: line 1064 (map starts at 1056; the comment above it was rewritten).
- `entries_visible?/2`: lines 1130-1138 (every gate key present and `own_tenant_value?/2` true; no database access, no logging).
- `shape_plan/2` entries step: lines 1116-1121 (stored list only when `entries_visible?(plan, own)`, else `[]`); the non-operator map clause starts at 1084, `shape_plan(plan, :operator)` is unchanged at 1082, the non-map clause at 1125.
- The route: `authz_get "/:id/context", :PromotionsRead` at line 233, unchanged.

AC5 finding (who can read P's reviews, established from code, not from the issue's assumption). Only `PLATFORM_ADMIN` holds `:PromotionsRead` today, through the unconditional catch-all `core_role_allows?(:PLATFORM_ADMIN, _permission), do: true` (`lib/letflow/api/authorization.ex:1301`); no other core role grants it (explicit lists below that line) and the Catalog fallback registers no such grant. The role set is closed at six atoms (`@roles`, `authorization.ex:376`); `TENANT_ADMIN` and `TENANT_AUDITOR` exist only as planned roles (`docs/roles.md` matrix; `role_from_string/1`, `authorization.ex:597-602`, maps every other string to no role), pending REQ-447. With the platform pin set to P, P's `PLATFORM_ADMIN` is the operator and sees the plan unchanged, so with a correctly pinned platform no non-operator can read P's operator-created reviews today. The exposure is real in three cases: the pin unset or pointing elsewhere (P's `PLATFORM_ADMIN` is then a non-operator); legacy rows naming foreign tenants in an ordinary tenant's schema, read by that tenant's `PLATFORM_ADMIN`; and as soon as REQ-447 grants `:PromotionsRead` below `PLATFORM_ADMIN`. Ordering note: REQ-447 must be ordered after this fix, because any such grant makes P's operator-created reviews readable by non-operators. `docs/requirements.yaml` is not edited here; a test pins the denied roles and fails when the matrix changes.

Remaining residuals (accepted, named here for REVIEWER and SECURITY-REVIEWER):

- R1b: when both stored ids are the caller's own, `entries` is returned as stored and nothing inside is scanned; it is the caller's own content, not a cross-tenant disclosure (the plan builder reads only the two named tenants' graphs).
- R3: `teardown_error` text on other review routes (unchanged from ISS-1021).
- R4 / R8: `process_key`, `base_version` and the envelope's `def_id` are still returned for a review naming foreign tenants; they are the name and version of the definition being promoted, in the reader's own schema.
- R5: `requested_by`, a user id of the review's own schema.
- R6: `plan_digest` covers the unshaped plan and cannot be verified from the shaped plan (already so).
- R9: a non-operator can infer from `entries == []` that the review names another tenant (a builder never stores an empty plan); already implied by the omitted tenant ids.

Tracked, not closed here: R10. `handle_approve` (`promotions.ex:572`) and `handle_reject` (`promotions.ex:609`) are not gated by the stored tenant ids; only `apply` (`promotions.ex:645`) and `run-assertions` (`promotions.ex:779`) call `stored_tenants_authorized?/3` (defined at 669). A non-operator `:PromotionsManage` holder can therefore approve or reject a foreign-named review in its own schema and learns only the status; the change touches the caller's own schema only and `apply` stays blocked. Tracked as Q-1008 / GH #2305 / ISS-1026.

INFO (optional hardening, not done): `own_tenant_value?/2` (`promotions.ex:1140`) returns true for an empty own id with an empty value; this is unreachable through the route because the authorization layer rejects a tenant id that cannot be resolved, so the gate cannot be satisfied by an empty id in practice.

## Closure of the approve/reject stored-id residual (ISS-1026 / Q-1008), 2026-10-06

Residual R10 is closed. Approve and reject on a review whose stored plan names
foreign tenants did not re-check the stored source/target tenant ids, unlike apply
and run-assertions. `handle_approve` and `handle_reject` in
`lib/letflow/routers/promotions.ex` now call `stored_tenants_authorized?/3` after
body validation and before the action (approx. lines 586 and 627), and a caller who
does not own both stored tenants gets the same zero-detail 404 as for a nonexistent
review. The operator path is unchanged.

The 0046 D3 binding condition for granting `:PromotionsManage` below
`PLATFORM_ADMIN` (REQ-447) is thereby met for approve and reject.

Remaining tracked item (read side, LOW): `GET /promotions/:id/context`,
`GET /promotions/:id` and `GET /promotions` still lack the stored-tenant check;
tracked as Q-1011 / GH #2311 / ISS-1029.

## Closure of the TENANT_AUDITOR role (REQ-448 / Q-965 / GH #2236), 2026-10-13

The `TENANT_AUDITOR` role is shipped as the eighth and last role of
`Letflow.Api.Authorization.roles/0`, with its realm role and a seeded
`auditor-user` in `priv/keycloak/realms/bpm-default.json`, and with the
`docs/roles.md` matrix enforced against the code by
`test/letflow/api/roles_matrix_parity_test.exs`. Seeding uses the existing
`RoleRegistry` / `RoleBackfill` mechanism unchanged; the `RoleRegistry`
name-collision guard now covers `TENANT_ADMIN` and `TENANT_AUDITOR`.

Deliberate interim deviations from D6, recorded here so the charter and the code
stay reconcilable:

- `:PromotionsRead` is WITHHELD from `TENANT_AUDITOR` (13 effective grants, D6's
  list minus `PromotionsRead`; the `docs/roles.md` cell is `no`). The read-side
  stored-tenant check of Q-1011 / GH #2311 / ISS-1029 is not merged, and a new
  role must not widen a surface whose check is open. Follow-up after Q-1011 merges:
  add `:PromotionsRead` to the auditor's explicit list, flip the one matrix cell to
  `yes`, flip the pinning test, and move the AC5 row of
  `promotion_context_entries_scope_test.exs` to the allowed side.
- `:EntitiesRecordsExport` is NOT granted (a supervisor decision).
- New additive core permission `:AttachmentLinksIssue` (core permissions 40 -> 41)
  now keys `POST /instances/:id/attachments/:attachment_id/link`. Issuing a link
  persists state (lazy signing-key write) and mints a bearer capability, so the
  read-only auditor must not reach it, while it shares `:AttachmentsRead` with
  reads the auditor needs. It is granted to exactly the roles that reached the
  route before: `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`,
  `TASK_WORKER`, `TENANT_ADMIN`; no existing role's behaviour changes (D7).
- `is_task_worker_only?/1` excludes `TENANT_AUDITOR`, so an auditor who also holds
  `TASK_WORKER` gets unfiltered task lists.
- The missing `PlatformServicesManage` row (platform scope) was added to the matrix.
