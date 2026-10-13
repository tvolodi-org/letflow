# REQ-448 / Q-965 / GH #2236 -- TENANT_AUDITOR role and the docs/roles.md <-> Authorization parity test

Status: DESIGN, revision 2 (CODE-DESIGNER, after CODE-DESIGN-VALIDATOR FAIL on 10dd282e). Written against `origin/main` 334246f1 (branch `feat/Q-965-tenant-auditor-role`). Design only: signatures, shapes, algorithms in prose, tables, invariants. No implementation code, no tests, no `lib/` edits.

Authority: decision `docs/migration/decisions/0046-admin-scopes-and-role-charter.md` D3, D5, D6, D7, D10 and its appended correction and closure sections; `docs/roles.md` (matrix, format fixed by REQ-445); `lib/letflow/design/req446-named-scoped-permissions.md`, `req447-tenant-admin-role.md`, `req447-infra-realm-mapping.md`; `docs/agents/instructions/security-invariants.md` INV-1, INV-2, INV-5, INV-10.

Already decided by the supervisor (NOT reopened): `:EntitiesRecordsExport` is NOT granted to the auditor.

## Revision 2: what changed and the INTERIM supervisor decisions it implements

Recorded by the supervisor in `letflow-supervisor reports/decisions/9a-batch-2026-10-13-req448.md`, pending review by the advisory session:

| Item | Interim decision | Effect on this design |
|---|---|---|
| OQ-1 | ACCEPT default | an auditor who also holds `TASK_WORKER` gets unfiltered `GET /tasks` and `GET /tasks/inbox`: `TENANT_AUDITOR` joins the `is_task_worker_only?/1` exclusion (section 2.3) |
| OQ-2 | WITHHOLD `:PromotionsRead` from `TENANT_AUDITOR` until Q-1011 merges | DELIBERATE INTERIM DEVIATION from 0046 D6 and REQ-448 BUILD item 1 (see section 3). The auditor's effective grant list is 13 atoms (12 explicit core atoms plus `:MyModulesRead`), i.e. D6 minus `PromotionsRead`. The `docs/roles.md` cell is `no` with a prose note. `promotions.ex` and the AC5 tripwire of `promotion_context_entries_scope_test.exs` are NOT touched |
| OQ-3 | allow pure reads and queries; DENY any route that persists state | verified route by route in section 2.5; the attachment-link route is denied through a new additive permission (section 2.6, labelled item L1; the choice is confirmed in OQ-8) |

Validator fixes folded in: B1 (complete literal-count test list in section 8, plus the derive-never-re-literal rule), N1 (non-GET probe for the four read-only routers, section 7.2), N2 (two missing consumers in section 2.2), N3 (`effective_roles/2` is at `authorization.ex:586`).

The effective grant list therefore DIFFERS from the literal text of REQ-448 BUILD item 1 and acceptance criterion 1 ("allowed exactly the listed permissions"): the listed set minus `:PromotionsRead`. The run report and PR body must state this explicitly.

---

## 0. Summary

1. `Letflow.Api.Authorization` gains `:TENANT_AUDITOR` as the EIGHTH and last element of `@roles`, one `role()` union member, one `role_from_string/1` clause, one explicit-list `core_role_allows?/2` clause (12 core atoms) plus the role-agnostic `:MyModulesRead` (13 effective grants, section 2). `is_task_worker_only?/1` is extended (OQ-1, accepted).
2. One new additive core permission, `:AttachmentLinksIssue` (item L1, section 2.6), granted to exactly the roles that today can reach `POST .../attachments/:attachment_id/link` through `:AttachmentsRead` except the new auditor. `core_permissions/0` goes from 40 to 41 atoms.
3. Seeding is NOT a new mechanism. `RoleRegistry.seedable_role_names/1` derives from `Authorization.roles/0`; every tenant gets a `TENANT_AUDITOR` group and binding through `TenantOnboarding.provision_and_migrate/1` with no edit; existing tenants through the existing `Letflow.Identity.RoleBackfill.run/0`. One real edit: the name-collision guard in `RoleRegistry` is widened to `TENANT_ADMIN` and `TENANT_AUDITOR` (section 4).
4. Realm file `priv/keycloak/realms/bpm-default.json`: role `TENANT_AUDITOR` and a seeded `auditor-user` (section 5).
5. Parity test `test/letflow/api/roles_matrix_parity_test.exs` (section 6). It fails on first run until `docs/roles.md` gets the `PlatformServicesManage` and `AttachmentLinksIssue` rows and the auditor's `PromotionsRead` cell is `no`.
6. Router tests (section 7), literal-count test edits (section 8), seven-to-eight statements (section 9), change list (section 10).

---

## 1. Facts established from the code (file:line on 334246f1)

| # | Fact | Evidence |
|---|---|---|
| F1 | `@roles` is a seven-atom list ending `:TENANT_ADMIN`; `role()` type has seven members; `role_from_string/1` is exact-match, case-sensitive, anything else is `nil`. | `lib/letflow/api/authorization.ex:272-281` (type), `:383-392` (`@roles`), `:637` (`role_from_string("TENANT_ADMIN")`) |
| F2 | `role_allows?/2` first clause grants `:MyModulesRead` to every role; then `core_role_allows?/2 or permission in Catalog.role_grants(role)`. A role absent from the core clauses and from every manifest holds nothing else. | `authorization.ex:~1327-1335` |
| F3 | Per-role core clauses: `PLATFORM_ADMIN` catch-all `true`; `TENANT_ADMIN` = `permission_scope(p) == :tenant` (line 1354); the four others are explicit atom lists. | `authorization.ex:~1337-1470` |
| F4 | `permission_scope/1`: compile-time map over `core_permissions/0` (platform: `:TenantsManage`, `:PlatformServicesManage`; all else tenant), Catalog atoms tenant, any other atom `:platform` (fail closed). | `authorization.ex:434-442`, `:501-512` |
| F5 | `evaluate_access/2`: `:Unknown` denied for all; `:UnmatchedRoute` and `:UnmatchedPlatformPath` allowed only for platform-tenant `PLATFORM_ADMIN`, so every other caller (the auditor included) gets 403 for them; `:MetricsRead` as an ENDPOINT KEY is `:Allow` for everyone (global `/metrics`), distinct from the `:MetricsRead` PERMISSION; `PLATFORM_ADMIN` is dropped unless `platform_tenant?` is exactly `true`. | `authorization.ex:~1018-1068` |
| F6 | `is_task_worker_only?/1` is true iff `TASK_WORKER` held and none of `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TENANT_ADMIN` held. Single switch for `GET /tasks` row filtering and `GET /tasks/inbox` scope (`routers/tasks.ex:~256-266`, via `effective_roles/2`). A `TENANT_AUDITOR` alone is already NOT worker-only. | `authorization.ex:1147-1154`; `routers/tasks.ex:196-266` |
| F7 | `RoleRegistry.seedable_role_names/1`: all of `roles/0` for the platform tenant's schema, all but `PLATFORM_ADMIN` otherwise (fail closed). `seed_default_platform_role_groups/1` seeds in `roles/0` order after `check_tenant_admin_name_free/1`, which guards ONLY `TENANT_ADMIN` against a `:process_routing_role` row (`upsert_role/4` overwrites `kind` on a name conflict). | `lib/letflow/identity/role_registry.ex:149-232` |
| F8 | `TenantOnboarding.provision_and_migrate/1` -> `seed_platform_roles/1` -> `seed_default_platform_role_groups/1`; a seeding failure leaves the tenant `:migrating`. | `lib/letflow/tenant_onboarding.ex:172-195` |
| F9 | `RoleBackfill.run/0`: per registration, reads held `:platform_role` names, seeds, classifies `:seeded` when any `seedable_role_names/1` name was missing (and NULLs `role_claims_synced_at` for every user of that schema, ISS-0910), else `:unchanged`. Halts on the first error or exception. Nothing calls it automatically; mix task or, on a deployed container (no Mix), the release `rpc`. | `lib/letflow/identity/role_backfill.ex:129-228`; `req447-infra-realm-mapping.md:125-137`; `scripts/uat_preflight.sh:657` |
| F10 | Token issuance and the `POST /roles` built-in-name guard (H2) derive from `roles/0` (`@issuable_token_roles`, `Authorization.builtin_role_name?/1`): `TENANT_AUDITOR` becomes an issuable token role and a protected binding name with no edit. | `lib/letflow/identity.ex:1380`; `authorization.ex:~640-660` |
| F11 | Entity field restrictions are keyed by `user_id` grants; `FieldGrants` and `TypeAccess` have no role parameter or role name (grep `role` over `lib/letflow/entities/query/field_grants.ex` and `lib/letflow/entities/type_access.ex`: no hit). No role-based bypass (INV-2). | grep on this branch |
| F12 | `docs/roles.md` matrix: 39 rows, 8 role columns, `scope` column. No `PlatformServicesManage` row though `core_permissions/0` has it (platform). The auditor's current `yes` cells are the 14 atoms of D6; after revision 2 the `PromotionsRead` auditor cell must be `no`. Non-auditor columns of the six existing roles and `TENANT_ADMIN` agree with the code (compared by hand). | `docs/roles.md:74-113` |
| F13 | Literal role or row counts in tests: see the exhaustive list in section 8. | grep on this branch |
| F14 | The "AC5" tripwire of `promotion_context_entries_scope_test.exs` (~:360-420) lists `["TENANT_AUDITOR"]` among roles expected to get 403 on `GET /promotions/:id/context`. With `:PromotionsRead` withheld that expectation STAYS TRUE and the file is not edited in this PR; the follow-up (section 3) moves the row. | read on this branch |
| F15 | 23 routers are mounted in `Letflow.Plugs.ApiPipeline` (`api_pipeline.ex:141-222`); all but `Modules` are `AuthorizedRouter`s exposing `__authz_routes__/0 :: [{method, local_path, policy_key}]`. | `api_pipeline.ex`; `tenant_admin_routes_test.exs:~226-246` |
| F16 | The complete set of NON-GET routes whose permission the auditor holds (grep of `authz_post/put/patch/delete` against the auditor's atoms over `lib/`): `POST /definitions/:id/validate`, `POST /solution-packs/export`, `POST /solution-packs/:pack_id/update-review` (all `:DefinitionsRead`), `POST /instances/:id/attachments/:attachment_id/link` (`:AttachmentsRead`), `POST /entities/query`, `POST /entities/query/aggregate`. Section 2.5 verifies each. | grep + reads |
| F17 | The attachment-link route currently resolves through `endpoint_policy_key("POST", "/instances/:id/attachments/:attachment_id/link")` to `:AttachmentsRead` (`authorization.ex:887-892`) and is declared `authz_post ".../link", :AttachmentsRead` (`routers/instances.ex:406`). | read on this branch |

---

## 2. BUILD item 1 -- `Letflow.Api.Authorization`

### 2.1 Role atom, type, string clause

* `@roles` gains `:TENANT_AUDITOR` as the eighth and LAST element (`docs/roles.md` order: the six existing roles, `TENANT_ADMIN`, `TENANT_AUDITOR`). The literal stays a plain atom list with no comment containing `]` between the brackets, because `web/tests/guards/role-set.spec.ts` extracts it with the pattern `@roles \[([^\]]+)\]`.
* `role()` type union gains `:TENANT_AUDITOR`.
* `role_from_string/1` gains the exact clause `"TENANT_AUDITOR"` -> `:TENANT_AUDITOR` (exact, case-sensitive, no trimming; `"tenant_auditor"`, `" TENANT_AUDITOR"`, `"TENANT-AUDITOR"` parse to nothing).
* The moduledoc heading "Seven roles (REQ-447)" and its prose, and the `roles/0` `@doc`, become eight and name `TENANT_AUDITOR`.
* Functions that become correct with no edit because they derive from `roles/0`: `roles_from_strings/1`, `effective_roles/2` (`authorization.ex:586`), `builtin_role_name?/1` (so `POST /roles` for the name `TENANT_AUDITOR` needs `:UsersGroupsRolesManage`, H2), `Identity.create_token/3` role validation, `Catalog.validate_role_grants_known/1`, `RoleRegistry.platform_role_names/0`, `IdentityMigration.platform_role_names/0`, `mix letflow.check_uat_scenario_schema` `known_role_names/0`.

### 2.2 Grant rule (exact permission list)

New private clause of `core_role_allows?(role, permission)` for `:TENANT_AUDITOR`: true iff `permission` is a member of the closed 12-atom list below. Placed after the `:TENANT_ADMIN` clause. There is deliberately NO `permission_scope == :tenant` rule for this role. Everything else is `false` from the core clause; the Catalog fallback in `role_allows?/2` stays additive, so a module permission is held by the auditor only if a registered manifest `role_grants` names `:TENANT_AUDITOR` (none does: `Catalog.role_grants(:TENANT_AUDITOR) == []`).

| # | Permission | Why | Consumers |
|---|---|---|---|
| 1 | `:DefinitionsRead` | read definitions | `GET /definitions`, `/:id`, `/active/:name`, `/search`, `/delta`, `/:id/export`; `GET /services`; read-class POSTs of F16 |
| 2 | `:InstancesRead` | read instances | `GET /instances`, `/:id`, `/:id/history`, `/:id/timeline`, `/:id/pins` |
| 3 | `:TasksRead` | all tenant tasks | `GET /tasks`, `GET /tasks/inbox`, `GET /tasks/:id` |
| 4 | `:AuditRead` | audit chain | `GET /audit` |
| 5 | `:MetricsRead` | tenant metrics permission (the global `/metrics` endpoint key is unaffected, F5) | permission only |
| 6 | `:AttachmentsRead` | instance attachments | `GET /instances/:id/attachments`, `GET /instances/:id/attachments/:attachment_id`, `GET /instances/:id/attachments/:attachment_id/link-content` (`routers/instances.ex:410`), `GET /instances/storage-usage` (`routers/instances.ex:420`); the link-ISSUE route moves to `:AttachmentLinksIssue` (section 2.6) |
| 7 | `:EntitiesDefinitionsRead` | entity definitions | `GET /entities/definitions*` |
| 8 | `:EntitiesQuery` | query records | `POST /entities/query` |
| 9 | `:EntitiesAggregate` | aggregate | `POST /entities/query/aggregate` |
| 10 | `:EntitiesAttachmentsRead` | entity attachments | `GET /entities/records/:t/:id/attachments*` |
| 11 | `:HelpRead` | help | `GET /help/resolved` |
| 12 | `:MembershipsRead` | own memberships | `GET /me/memberships` |
| - | `:MyModulesRead` | granted to every role by the first `role_allows?/2` clause; NOT repeated in the list | `GET /me/modules` |
| - | `:PromotionsRead` | WITHHELD (section 3) | none |

Effective grant set: 13 atoms. Denied core permissions: 28 of 41 (all `*Write`, `*Manage`, `*Start`, `*Cancel`, `*Complete`, `*Assign`, `*Import`, `*Export*`, `:DlqOperate`, `:InstancesAdvanceTimer`, `:PublicReadHandlesIssue`, `:PromotionsRead`, `:PromotionsManage`, `:DefinitionsRollback`, `:AttachmentLinksIssue`, `:TenantsManage`, `:PlatformServicesManage`).

### 2.3 Task scope (OQ-1, accepted interim)

AC: "GET /tasks returns all tasks of the tenant for this role (task_scope :all), because is_task_worker_only?/1 is false for it." For `TENANT_AUDITOR` alone this already holds. For `TENANT_AUDITOR` + `TASK_WORKER` the current function would row-filter to own tasks. Design: `is_task_worker_only?/1` gains `not has_role?(roles, :TENANT_AUDITOR)`, as `req447-tenant-admin-role.md` section 3.1 announced. Effect: `GET /tasks` and `GET /tasks/inbox` are unfiltered for any caller holding the auditor role. No permission is added (`:TasksRead` is already held); mutation permissions still come only from other roles held.

### 2.4 No other change in this module beyond L1

`evaluate_access/2`, `has_permission_in_scope?/3`, `permission_scope/1` are unchanged (the new permission is tenant scope through the default rule).

### 2.5 Route-by-route verification of every non-GET route the auditor's permissions reach (OQ-3)

Rule applied (supervisor): allow pure reads and queries; deny any route that persists state. Each row was read in the code on this branch.

| Route | Router:line | Permission today | Verdict | Reason (evidence) |
|---|---|---|---|---|
| `POST /definitions/:id/validate` | `routers/definitions.ex:320` -> `Definitions.validate_definition_graph/2` (`definitions.ex:1272-1297`) | `:DefinitionsRead` | ALLOWED | reads one definition and its variable schemas, runs five validators and `ValidationWarnings.for_definitions`; no `Repo` write; response `validated_at` is `DateTime.utc_now`, not stored. The route comment itself says "read-only, non-mutating validation pass" |
| `POST /solution-packs/export` | `routers/solution_packs.ex:167` -> `SolutionPack.export/3` (`definitions/solution_pack.ex:363-430`) | `:DefinitionsRead` | ALLOWED | builds a pack document from stored definitions; the `Repo.transaction`/`Repo.insert` sites of that file (434+, 560+, 679, 817) belong to `install` and `apply_pack_update`, none to `export` |
| `POST /solution-packs/:pack_id/update-review` | `routers/solution_packs.ex:182` -> `compute_and_render_review` -> `Definitions.compute_pack_update_plan/5` (`definitions.ex:402-450`) | `:DefinitionsRead` | ALLOWED | the plan builder calls only `Repo.get_by` on `SolutionPackArtefactBase` and `PackUpdateResolution` (`fetch_base`, `resolution_exists?`, `definitions.ex:500-524`) and returns a map; nothing is written (the write route is `update-apply`, `:DefinitionsCreate`, denied) |
| `POST /entities/query` | `routers/entities.ex:345` | `:EntitiesQuery` | ALLOWED | query compiler and router contain no `Repo.insert/update/delete` or audit append (grep); field restrictions apply (F11) |
| `POST /entities/query/aggregate` | `routers/entities.ex:358` | `:EntitiesAggregate` | ALLOWED | same |
| `POST /instances/:id/attachments/:attachment_id/link` | `routers/instances.ex:406` -> `handle_issue_attachment_link` -> `Repository.AttachmentLinks.issue/3` (`repository/attachment_links.ex:95-117`) | `:AttachmentsRead` | DENIED | `issue/3` calls `get_or_create_signing_key`, which on the first call for a tenant does `Secrets.put` of a 32-byte signing key (`attachment_links.ex:191-206`, `{:error, {:secret_write_failed, _}}` is a documented result): it PERSISTS state; and it mints a bearer capability token for the attachment content |

Not changed and allowed (pure reads, listed so the PR body is complete): `GET /instances/:id/attachments/:attachment_id/link-content` verifies a token and streams content; `GET /instances/storage-usage` reads usage.

### 2.6 Item L1 -- denying the link-issue route: a new additive permission `:AttachmentLinksIssue`

Problem: the route's permission, `:AttachmentsRead`, is a READ permission the auditor needs for the GETs above. A route cannot be denied to one role while keeping its permission without a second permission or a role-specific guard.

Mechanism chosen (least invasive that keeps the matrix the single contract):

1. New core permission `:AttachmentLinksIssue`, appended to `@permissions` after `:DefinitionsRollback`; scope `:tenant` through the default rule (not in `@platform_permissions`).
2. Routing: the `endpoint_policy_key("POST", "/instances/:id/attachments/:attachment_id/link")` clause (`authorization.ex:890`) returns `:AttachmentLinksIssue`; `required_permission(:AttachmentLinksIssue)` is an explicit identity clause beside `:AttachmentsRead`'s (`:1211`); the route in `routers/instances.ex:406` is declared with `:AttachmentLinksIssue`. The `GET .../link-content` clause stays `:AttachmentsRead`.
3. Grants, chosen so NO existing role's behaviour changes: the new atom is added to the explicit lists of `:PROCESS_DESIGNER`, `:PROCESS_OPERATOR` and `:TASK_WORKER` (the three explicit-list roles that hold `:AttachmentsRead` today). `PLATFORM_ADMIN` (catch-all) and `TENANT_ADMIN` (every tenant-scope permission) hold it automatically. `AGENT_RUNNER` and `CANDIDATE` hold neither it nor `:AttachmentsRead` (unchanged: denied). `TENANT_AUDITOR`: not granted. No module manifest can grant a core permission (Catalog collision rule), so no Catalog path changes.
4. Before/after table of who may POST `.../link`: PLATFORM_ADMIN (platform tenant only), PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, TENANT_ADMIN: yes before and after. AGENT_RUNNER, CANDIDATE: no before and after. TENANT_AUDITOR: new role, denied. The evaluation order and the 403 body are unchanged.
5. Knock-on edits (all mechanical): `docs/roles.md` matrix row `AttachmentLinksIssue` (yes for PLATFORM_ADMIN, PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, TENANT_ADMIN; no for AGENT_RUNNER, CANDIDATE, TENANT_AUDITOR; scope tenant); the `core_permissions/0` `@doc` ("All forty ..."); `authorization_test.exs` `@core_permissions` literal and the count assertions (section 8); the route-declared-key allowlist of `authorization_enforcement_test.exs` if the route is listed there; `test/letflow/routers/req386_attachment_links_routes_test.exs` expectations are unchanged for the five roles above (re-run it).

Rejected alternatives (listed so the choice is reviewable):

* Re-key the route to `:AttachmentsManage`: designers and task workers do not hold it, so THEIR behaviour would change (forbidden by the brief).
* A role-specific deny inside the router or in `evaluate_access/2` ("auditor never POST"): bypasses the matrix, the parity test cannot see it, and the next read-class role would need another special case.
* Leave the route on `:AttachmentsRead`: persists state for an auditor; contrary to the interim decision.

Whether a new core permission is acceptable as part of REQ-448 (it widens the permission set REQ-446 fixed) is confirmed in OQ-8.

---

## 3. `:PromotionsRead` is WITHHELD (interim deviation, OQ-2) and the follow-up

Decision 0046 D6 and REQ-448 BUILD item 1 list `:PromotionsRead` for the auditor, "subject to the binding condition under D3". Status of the condition: the ownership proof on the promote route is met by REQ-446 (`lib/letflow/routers/tenants.ex` `handle_promote`, ~line 448, calling `TenantTarget.authorize_target_tenant/2`, `lib/letflow/api/tenant_target.ex:31-39`); plan and event payloads of `/context` and `/platform-events` are shaped by allowlists (ISS-0999, ISS-1021, ISS-1023); the stored-tenant check on `GET /promotions`, `GET /promotions/:id`, `GET /promotions/:id/context` is NOT done (Q-1011 / GH #2311 / ISS-1029; `handle_context` at `routers/promotions.ex:526` has no `stored_tenants_authorized?/3` call).

Interim decision: a NEW role must not widen a surface whose stored-tenant check is open. Therefore:

* The auditor's list omits `:PromotionsRead`. The `docs/roles.md` cell for `PromotionsRead` x `TENANT_AUDITOR` is `no`, and the auditor role section replaces "promotions reads once the ownership proof exists" with a one-sentence note: promotion reads are withheld until Q-1011 merges, then added by a follow-up.
* The parity test passes with the cell `no` (the code and the doc agree). A dedicated test pins the withholding so the follow-up must flip it on purpose (section 6.3).
* This is a DELIBERATE deviation from D6 and from AC1's "exactly the listed permissions". It is recorded in the appended closure section of 0046 (section 9) and in the PR body. `TENANT_ADMIN` keeps `:PromotionsRead` (unchanged).
* NOT touched: `lib/letflow/routers/promotions.ex`, the "AC5" describe of `promotion_context_entries_scope_test.exs` (its `["TENANT_AUDITOR"]` -> 403 row remains correct), `platform_scope_authorization_test.exs` holder lists (the auditor is among the denied roles there, which the existing loops already assert).

Follow-up (one line, tracked as a small requirement or an addition to Q-1011's PR): after Q-1011 merges, add `:PromotionsRead` to the auditor's explicit list, flip the one matrix cell to `yes`, change the pinning test, and move the AC5 row to the allowed side.

---

## 4. BUILD item 2 -- seeding and backfill

### 4.1 New tenants (no new code path)

`RoleRegistry.seedable_role_names/1` returns `TENANT_AUDITOR` last for every schema (platform tenant: eight names; any other schema: seven). `TenantOnboarding.provision_and_migrate/1` and `recover_provisioning/1` need no body change; a seeding error still yields `{:error, {:role_seeding_failed, reason}}` and leaves the tenant `:migrating`.

### 4.2 Collision guard (the one real edit in `RoleRegistry`)

The private `check_tenant_admin_name_free/1` becomes a guard over `["TENANT_ADMIN", "TENANT_AUDITOR"]` (module attribute): one read scoped by `prefix:`, `where name in ^names and kind == :process_routing_role`, first hit by name order. `seed_default_platform_role_groups/1`'s spec is unchanged: `{:error, {:role_name_taken_by_routing_role, name}}` with the colliding name, nothing written. The six older names need no guard (the ISS-0774 migration classified such rows as `:platform_role`; H2 forbids new ones since REQ-447). `TenantAdminMigration` is not touched.

### 4.3 Existing tenants (idempotent backfill, same mechanism as REQ-447 section 3.9)

* Module and function: `Letflow.Identity.RoleBackfill.run/0` (`lib/letflow/identity/role_backfill.ex`), return `{:ok, %{seeded, unchanged, role_claims_markers_reset}} | {:error, {:backfill_failed, tenant_id, reason}}`, unchanged. CLI: `mix letflow.backfill_platform_roles`; on a deployed container, `Letflow.Identity.RoleBackfill.run()` through the release `rpc` (`req447-infra-realm-mapping.md:137`).
* No code edit: `classify/4` treats a tenant as `:seeded` when any name of `seedable_role_names(schema_name)` is missing. After this change every existing tenant lacks `TENANT_AUDITOR`: `:seeded` on the first run, `:unchanged` on the second.
* Invariant: after one successful run every tenant holds exactly its seedable set (ordinary seven, platform tenant eight); a second run lists every tenant under `unchanged`, writes no row, resets no marker. It never deletes a binding and never writes `group_members`: a user gains the role by the claim sync at next login (realm role `TENANT_AUDITOR`) or `Identity.add_group_member/3`.
* Accepted properties (as REQ-447; OQ-6): the ISS-0910 reset NULLs `role_claims_synced_at` for every user of every tenant once (additive re-sync at next login); the sweep halts at the first failing tenant.
* QA step for the run report: after deployment run the backfill through `rpc`, quote the `seeded` count, then the second run's `unchanged` count. Until it runs, an existing tenant has no `TENANT_AUDITOR` binding, so a token claiming the role resolves to no role (fail closed).

### 4.4 No Ecto migration

All change is data change in `groups` and `tenant_role`. No file under `priv/repo/migrations/`; the ISS-0774 migration's six SQL literals are history and are not edited.

---

## 5. BUILD item 3 -- `priv/keycloak/realms/bpm-default.json`

* `roles.realm` gains `{ "name": "TENANT_AUDITOR" }` as the eighth entry.
* `users` gains `auditor-user` in the shape of `tenant-admin-user`: email `auditor@letflow.local`, `firstName` `Auditor`, `lastName` `User`, enabled, `emailVerified` true, `requiredActions` `[]`, a non-temporary `password` credential (development seed convention, e.g. `auditor-pass`), `realmRoles: ["TENANT_AUDITOR"]` only.
* `seedVersion` bumped to the merge date. No other user changes.

Why `authorization_role_realm_test.exs` passes WITHOUT edits: it compares the sorted `roles.realm[].name` set with `Authorization.roles()` mapped to strings and sorted; no literal list, no count (only the word "five" in a moduledoc and a failure message). Both sides change in the same PR (and the same commit as `authorization.ex`). It would fail only if one side landed alone.

Other tests that read the realm file and must change: `tenant_admin_seeding_test.exs:297-302` (asserts `length(names) == 7` and `List.last(names) == "TENANT_ADMIN"`). New assertion: `auditor-user` has exactly `["TENANT_AUDITOR"]`, `admin-user` still `["PLATFORM_ADMIN"]`, no other user holds `TENANT_AUDITOR`.

Other realms are not in the repository. Infra contract (PR description and run report, in the style of `req447-infra-realm-mapping.md`): every tenant realm that issues Letflow roles should define a realm role `TENANT_AUDITOR` and may assign it; no alias in code (OQ-7).

---

## 6. BUILD item 4 -- the parity test

File `test/letflow/api/roles_matrix_parity_test.exs`, module `Letflow.Api.RolesMatrixParityTest`, `use ExUnit.Case, async: true` (pure: reads a file, calls pure `Authorization` functions; no database, no pin). The path is resolved from `__DIR__` like `authorization_role_realm_test.exs`. All helpers are private to the test module (no `lib/` or `test/support` addition).

### 6.1 Parser contract (format fixed by REQ-445, `docs/roles.md` lines 62-66)

Input: text of `docs/roles.md`. Locate the heading line `## Matrix`; take the FIRST fenced block after it (zero or unterminated: `{:no_matrix_block}`). Within the block:

* Line 1 is the header: first token `permission`, last token `scope`, the tokens between equal `Authorization.roles/0` as strings in order (eight). Otherwise `{:header_mismatch, expected, actual}`.
* Every following non-blank line is a row of exactly 1 + 8 + 1 tokens, else `{:bad_row_width, line, count}`.
* Token 1 is the permission name without the colon; a repeat is `{:duplicate_row, permission}`.
* Tokens 2..9 are exactly `yes` or `no`, else `{:bad_cell, permission, role, raw}`. Token 10 is `platform` or `tenant`, else `{:bad_scope, permission, raw}`.

Parsed shape: `matrix = %{header: [String.t()], rows: [row]}`, `row = %{permission: String.t(), line: pos_integer(), cells: %{String.t() => boolean()}, scope: :platform | :tenant}`.

### 6.2 Comparison contract

`code_permissions` = `Authorization.core_permissions/0` as strings (41 atoms after L1). Module (Catalog) permissions are not in the matrix and are not iterated.

1. Row set equality: `{:missing_row, p}` and `{:extra_row, p}` (both fail).
2. For every row and role `r` (atoms from `roles/0`; never `String.to_existing_atom/1` on file input): `r != PLATFORM_ADMIN`: `Authorization.role_allows?(r, p)`. `r == PLATFORM_ADMIN`: `Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], p, true)` (the platform-tenant evaluation; `role_allows?(:PLATFORM_ADMIN, _)` is a vacuous `true`). Mismatch: `{:cell_mismatch, p, role, doc, code}`.
3. Scope column equals `Authorization.permission_scope(p)` else `{:scope_mismatch, ...}`; and the set of `platform` rows equals `Authorization.platform_permissions/0`.
4. Extra sanity (not cells): `PLATFORM_ADMIN` with `platform_tenant?` false is denied every core permission; for every other role `has_permission_in_scope?([r], p, true) == has_permission_in_scope?([r], p, false) == role_allows?(r, p)`.
5. `evaluate_access/2` is NOT used to derive cells (its `:MetricsRead` endpoint key is `:Allow` for everyone, F5).

### 6.3 Tests inside the file

| Test | Proves |
|---|---|
| "the repository's docs/roles.md has no violations against the code" | real file: header, 41 rows, 328 cells, scope column |
| "the matrix has exactly the core permissions: PlatformServicesManage (platform) and AttachmentLinksIssue (tenant) are present" | pins the two docs additions |
| "flipping one cell is detected: TENANT_AUDITOR / AuditRead yes -> no" | in-memory mutation of the real file text on exactly one row/column; result is exactly one `{:cell_mismatch, "AuditRead", "TENANT_AUDITOR", false, true}` |
| "flipping one cell is detected: PROCESS_OPERATOR / TenantsManage no -> yes" | flip to the permissive side |
| "flipping the PLATFORM_ADMIN / TenantsManage cell is detected through the platform-tenant evaluation" | non-vacuous PLATFORM_ADMIN path |
| "flipping one scope cell is detected: TenantsManage platform -> tenant" | scope column |
| "a missing row (EntitiesQuery removed) and an extra row (bogus permission appended) are detected" | row set both directions |
| "a swapped header, a duplicate row, a non-yes/no cell and a short row are each detected" | parser strictness |
| "the TENANT_AUDITOR column is exactly the 13 atoms of D6 minus PromotionsRead" | literal list written in the test (comment cites 0046 D6, the interim deviation of OQ-2, and the follow-up) |
| "PromotionsRead is no for TENANT_AUDITOR and yes for TENANT_ADMIN and PLATFORM_ADMIN" | pins the withholding; the follow-up flips this test on purpose |
| "every role in roles/0 has a column and every column is a role in roles/0" | no stale column |

Mutation tests operate on a string copy and never write a file.

### 6.4 The one-time on-disk demonstration (AC5)

The memory rule on destroyed uncommitted work applies: no `git checkout`, `git stash`, `git restore` on tracked files. (1) Commit everything. (2) With the Edit tool flip exactly one cell in `docs/roles.md` (the `TENANT_AUDITOR` cell of `AuditRead`, `yes` to `no`). (3) Run `mix test test/letflow/api/roles_matrix_parity_test.exs`, quote the failing output (a `{:cell_mismatch, "AuditRead", "TENANT_AUDITOR", ...}` line). (4) Revert with the Edit tool, re-run, quote the pass and `git diff --stat` showing no diff for `docs/roles.md` against the step-1 commit.

### 6.5 Charter and code disagreements, resolved against the decision record

| Finding | Resolution | Basis |
|---|---|---|
| `PlatformServicesManage` has no row | add the row: `yes` for PLATFORM_ADMIN, `no` for the seven others, scope `platform` | `@platform_permissions` (`authorization.ex:434`); 0046 D3 "whatever REQ-446 classifies as platform"; REQ-447 design F16/OQ-13 (assigned to REQ-448) |
| `AttachmentLinksIssue` is new (L1) | add the row (section 2.6 item 5) | this design |
| auditor `PromotionsRead` cell `yes` | change to `no` with a prose note | interim decision OQ-2; section 3 |
| prose: rows after `EntitiesRestrictionsManage` "are planned"; "TARGET state"; auditor "Does ... promotions reads once the ownership proof exists" | reword to current state; one-sentence note on the withheld promotion reads | docs fix |

---

## 7. Router tests (AC2)

File `test/letflow/routers/tenant_auditor_routes_test.exs`, modelled on `tenant_admin_routes_test.exs`: `use Letflow.DataCase, async: false` (VM-global pin); `setup` builds `Fixture.three_tenants!()` and `Fixture.pin!(p.tenant_id)`; direct dispatch with `Fixture.router_conn(method, path, fixture, ["TENANT_AUDITOR"], body)`; the full pipeline with `Fixture.mint_token!/2`, `Fixture.api_conn/5`, `Fixture.dispatch_api/1`.

### 7.1 200 block (AC2 first half)

| Request | Router | Expectation |
|---|---|---|
| `GET /definitions` | Definitions | 200 |
| `GET /instances` | Instances | 200 |
| `GET /tasks` | Tasks | 200 and UNFILTERED: seed tasks assigned to two other users in tenant A; both visible (`task_scope :all`); control: a `TASK_WORKER` alone sees only its own (`tasks_test.exs` describe "REQ-132 AC3" is the model); plus an auditor+`TASK_WORKER` caller is also unfiltered (OQ-1) |
| `GET /tasks/inbox` | Tasks | 200 and unfiltered (same fixture) |
| `GET /audit` | Audit | 200 |
| `POST /entities/query`, `POST /entities/query/aggregate` | Entities | 200 for an existing entity type with a valid minimal body (copy from `entities_test.exs`) |
| `POST /definitions/:id/validate` (a stored definition), `POST /solution-packs/export`, `POST /solution-packs/:pack_id/update-review` | Definitions, SolutionPacks | not 403 (2xx for valid bodies); asserted with a before/after row-count snapshot of definitions, pack bases and resolutions equal (state-free) |
| `GET /instances/:id/attachments`, `GET /instances/storage-usage` | Instances | 200 |
| `GET /me/memberships`, `GET /me/modules`, `GET /help/resolved`, `GET /services` | Me, Help, Services | 200 |

The same GETs through the full pipeline with a real API token for tenant A and for the platform tenant P (P's auditor is a non-operator: tenant routes 200, platform prefixes 403).

### 7.2 403 block: one named route per mounted router (AC2 second half)

Authorization precedes every lookup (ordering guarantee), so an unused UUID in a path yields 403, never 404. Each 403 also asserts the fixed `insufficient permissions` body and an unchanged row-count snapshot.

| # | Router (mount) | Named route (403) | Permission | Notes |
|---|---|---|---|---|
| 1 | Identity (`/identity`) | `POST /users` | `:UsersGroupsRolesManage` | also `GET /users`, `POST /tokens`, `POST /roles` |
| 2 | Tenants (`/tenants`) | `POST /` | `:TenantsManage` (platform) | also `POST /:test_tenant_id/promote/:process_key` |
| 3 | TenantSettings (`/tenant/settings`) | `PATCH /` | `:TenantSettingsManage` | |
| 4 | TenantModules (`/tenant/modules`) | `POST /` | `:ModulesManage` | |
| 5 | TenantSolutions (`/tenant/solutions`) | `POST /` | `:ModulesManage` | |
| 6 | Modules (`/modules`, plain Plug) | `POST /modules/exam/exam-sessions` with the exam module installed in tenant A | manifest policy `:ExamSessionStart` (CANDIDATE only) | install first (`Letflow.Modules.Installs`, as `modules_test.exs` ~:157), because the install gate answers 404 before any permission evaluation |
| 7 | Instances (`/instances`) | `POST /` | `:InstancesStart` | also `POST /:id/cancel`, and `POST /:id/attachments/:attachment_id/link` (`:AttachmentLinksIssue`, L1) |
| 8 | Definitions (`/definitions`) | `POST /` | `:DefinitionsWrite` | also `POST /:process_key/rollback` |
| 9 | Tasks (`/tasks`) | `POST /:id/complete` | `:TasksComplete` | also `/:id/claim`, `/:id/assign` |
| 10 | Promotions (`/promotions`) | `POST /` | `:PromotionsManage` | AND `GET /` 403 and `GET /platform-events` 403: `:PromotionsRead` is withheld (section 3); this pins the interim |
| 11 | Onboarding (`/onboarding`) | `POST /` | `:TenantsManage` (platform) | |
| 12 | SolutionPacks (`/solution-packs`) | `POST /install` | `:DefinitionsWrite` | and `POST /:pack_id/update-apply` 403; `export` and `update-review` are allowed (section 2.5) |
| 13 | Audit (`/audit`) | no write route; non-GET probe: `POST /api/v1/audit` (unmatched method) | unmatched marker | expected 403: an unmatched route under rule 1a (`:UnmatchedRoute`) is allowed only for a platform-tenant PLATFORM_ADMIN, so the auditor gets 403 (never 404). The test states explicitly that this probe is NOT a real route. Also asserts every `__authz_routes__/0` method of the router is `GET` |
| 14 | Dlq (`/dlq`) | `POST /:id/retry` | `:DlqOperate` | `GET /` and `GET /:id` also 403 |
| 15 | Webhooks (`/webhooks`) | `POST /subscriptions` | `:WebhooksManage` | `GET /subscriptions` also 403 |
| 16 | Services (`/services`) | no write route; non-GET probe: `POST /api/v1/services` | unmatched marker | same reasoning and assertion as row 13 |
| 17 | AdminServices (`/admin/services`) | `POST /` | `:AdminServicesManage` (platform) | |
| 18 | Entities (`/entities`) | `POST /records/:entity_type` | `:EntitiesRecordsWrite` | PLUS `POST /records/:entity_type/export` 403 (supervisor decision) and `POST /records/:entity_type/import` 403; `POST /definitions`, `POST /restrictions/import` 403 |
| 19 | PublicReadHandles (`/public-read-handles`) | `POST /` | `:PublicReadHandlesIssue` | |
| 20 | Help (`/help`) | no write route; non-GET probe: `POST /api/v1/help/resolved` | unmatched marker | same as row 13 (the path exists for GET; the verb does not) |
| 21 | PlatformMigrations (`/platform-migrations`) | `POST /rollouts` | `:TenantsManage` (platform) | |
| 22 | EventRetention (`/event-retention`) | `POST /retirements` | `:TenantsManage` (platform) | |
| 23 | Me (`/me`) | no write route; non-GET probe: `POST /api/v1/me/memberships` | unmatched marker | same as row 13 |

For rows 13, 16, 20 and 23 the AC's "403 on one representative write route" cannot be met by a real route because none exists; the test says so and uses the named non-GET probe, expecting 403 from rule 1a, instead of inventing a route. The test also asserts the probe path with its GET verb answers 200 (so the 403 is the verb, not a missing mount) where the GET is allowed to the auditor.

### 7.3 Completeness guards

1. Parse `lib/letflow/plugs/api_pipeline.ex` with the `forward("/prefix", to: Module)` regular expression of `tenant_admin_routes_test.exs`; the set of mounted routers equals the set named in the table (23); a new router without an entry fails.
2. For every table row naming a real route (not a probe), except `Modules`: the `{method, local_path}` is in `router.__authz_routes__()` and `Authorization.role_allows?(:TENANT_AUDITOR, Authorization.required_permission(key))` is `false` (platform keys also through `has_permission_in_scope?` with the flag true), so a row cannot pass by naming a permitted route.
3. Exhaustive sweep: for every route of every mounted `AuthorizedRouter`, if the auditor does not hold `required_permission(key)` the answer is 403; if it holds it the answer is not 403. The F16 allowed non-GET routes appear as a literal allowlist in the test, with the section 2.5 reason.

### 7.4 Other router-level proofs

* An auditor of an INACTIVE tenant is halted by `TenantStatus` with 403 `tenant_inactive`.
* Field-level restrictions apply like for any role (INV-2): with a restricted field and no `user_entity_grants` row for the caller, `POST /entities/query` redacts for the auditor exactly as for a `TASK_WORKER` and a `PROCESS_OPERATOR` caller in the same fixture (model: `entities_test.exs`, `entities_aggregate_test.exs`).
* The five roles that may issue an attachment link still get 2xx on `POST .../link` after L1 (`req386_attachment_links_routes_test.exs` stays green); the auditor gets 403 and no `Secrets` row is written for a tenant that had no signing key (row count of the secret store unchanged).

---

## 8. Test changes forced by the new role and the new permission

GENERAL RULE (binding on the implementer): any literal role count or row count in a test is DERIVED from `Authorization.roles/0`, `Authorization.core_permissions/0` or `RoleRegistry.seedable_role_names/1` (for example `length(RoleRegistry.seedable_role_names(schema_name))`), never re-literalled to the next number. Where an existing assertion is a deliberate hand-written regression snapshot (the grids of `authorization_test.exs`), keep the snapshot and add the new row by hand.

New files:

* `test/letflow/api/authorization_tenant_auditor_test.exs` (pure, `async: true`, mirror of `authorization_tenant_admin_test.exs`): "roles/0 returns eight atoms ending in TENANT_AUDITOR, the seven existing roles first and unchanged"; AC1 "for every p in `Authorization.permissions/0`, `role_allows?(:TENANT_AUDITOR, p)` is true exactly for the 13 literal atoms of section 2.2 and false for every other core AND Catalog permission" (iterates `permissions/0` as the AC says; asserts `Catalog.role_grants(:TENANT_AUDITOR) == []`; comment states the OQ-2 deviation from D6's 14); "refused set is literal (28 core permissions), `:PromotionsRead` among them"; "never a platform-scope permission, `:Unknown`, `:UnmatchedRoute`, `:UnmatchedPlatformPath`, with `platform_tenant?` true or false"; "`roles_from_strings` parses TENANT_AUDITOR exactly; lower-case, padded and hyphenated forms parse to nothing"; "`builtin_role_name?` true, `platform_admin_name?` false"; "`is_task_worker_only?` false for `TENANT_AUDITOR` and for `TENANT_AUDITOR + TASK_WORKER`, true for `TASK_WORKER` alone; `evaluate_access(:TasksList)` is `:Allow` with `task_scope :all`"; "`AttachmentLinksIssue` is held by PLATFORM_ADMIN (in the platform tenant), PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, TENANT_ADMIN and by no other role, and every role that held `:AttachmentsRead` before still reaches the link route except the auditor".
* `test/letflow/identity/tenant_auditor_seeding_test.exs` (`DataCase`, model: `tenant_admin_seeding_test.exs`): ordinary provisioned tenant has the binding and `seedable_role_names/1` ends with `TENANT_AUDITOR`; pinned platform tenant has all of `roles/0`; `RoleBackfill.run/0` on a tenant holding every seedable name but `TENANT_AUDITOR` adds the binding (`:seeded`), the second run is `:unchanged` with `groups`, `tenant_role`, `group_members` counts and every `role_claims_synced_at` unchanged; a `:process_routing_role` named `TENANT_AUDITOR` makes the seed return `{:error, {:role_name_taken_by_routing_role, "TENANT_AUDITOR"}}` with the row unchanged and `RoleBackfill.run/0` return `{:error, {:backfill_failed, tenant_id, {:role_name_taken_by_routing_role, "TENANT_AUDITOR"}}}`; the realm assertions of section 5.
* `test/letflow/api/roles_matrix_parity_test.exs` (section 6) and `test/letflow/routers/tenant_auditor_routes_test.exs` (section 7).

Existing tests that fail or become wrong and must be edited (line numbers as found on this branch; re-grep before editing):

| File:line | Edit |
|---|---|
| `test/letflow/api/authorization_test.exs:22-31` | `roles/0` list gains `:TENANT_AUDITOR` |
| `authorization_test.exs` `@core_permissions` (~:34-80), `:81`, the three "forty" maps (`40 => "forty"` at ~:458, :1009, :1486) and their `length(core_permissions())` asserts (:428, :985, :1466) | 40 -> 41 for L1: add `:AttachmentLinksIssue` to the literal list and the count words (derive the expected count from the literal list length) |
| `authorization_test.exs` grids with a `TENANT_ADMIN` row (:636-637, :776-778, :810-816, :1166-1168, :1203, :1548-1549, :1681-1683, :1704, :1833-1835, :1871, :2227-2229) | add a hand-transcribed `TENANT_AUDITOR` row (the 12 listed atoms intersected with each grid's permission set, `:MyModulesRead` where present); `grep -n "TENANT_ADMIN"` finds every site |
| `authorization_test.exs:781, :1171, :1838, :2232` and the "28 pairs" test at ~:647-655 | "7 roles x N" titles and pair counts become 8 roles (133 -> 152, 161 -> 184, 168 -> 192, 224 -> 256; 28 -> 32); derive the count from `length(Authorization.roles()) * length(permissions)` |
| `authorization_test.exs:1553-1560` (REQ-317 grid) | `assert length(pairs) == 14` becomes 16 (derive from `length(roles) * grid size`); the auditor row is `EntitiesAttachmentsManage: false, EntitiesAttachmentsRead: true` |
| `authorization_test.exs:1728-1738`, `:1921-1948` | the REQ-318 export/import test, the `:FixtureRead` test and the `:ModulesManage` test expect `TENANT_AUDITOR` denied |
| `authorization_test.exs:2121` | prose "six roles: 192 pairs" comment |
| `test/letflow/api/authorization_tenant_admin_test.exs:21-35` | "returns seven atoms ending in TENANT_ADMIN": become eight atoms, `TENANT_ADMIN` seventh, `TENANT_AUDITOR` last, first six unchanged |
| `test/letflow/api/platform_admin_role_binding_test.exs:80-89` | add `TENANT_AUDITOR` to the literal list; `length(roles()) == 8` (derive) |
| `test/letflow/identity/tenant_admin_seeding_test.exs:102` (title "all seven"), `:141-142` (`== 6` / `== 7`), `:161` and `@all_names` / `@non_platform_names` (should be derived), `:297-302` | counts become 7 / 8 derived from `seedable_role_names/1`; titles; realm test: 8 names, last `TENANT_AUDITOR`, still contains `TENANT_ADMIN` |
| `test/letflow/identity/role_backfill_test.exs:180-181` (`== 7`, `== 7`), `:200` (`length(roles) == 6`), `:207-208` (`== 6`, `== 6`), `:348` (`length(roles) == 6`), `:478-530` | 7 -> 8, 6 -> 7 (derived: legacy fixture = legacy PA row + every seedable name; ordinary tenant = `length(seedable_role_names/1)`; platform = `length(roles())`); titles "six seedable ... (seven in all)" |
| `test/letflow/role_registry_test.exs:660-690` | `length(roles) == 6` and the two `Repo.aggregate == 6` become derived (7) |
| `test/letflow/role_registry_test.exs:700-701`, `:722` (`length(roles) == 6` -> 7), `:725-727` (comment "6 (seeded) + 1" and `== 7` -> 8) | derived from `seedable_role_names/1`; routing row stays +1; test title "only the six platform-role names" -> derive wording |
| `test/letflow/identity_test.exs:1595` | `assert length(seedable) == 6` becomes 7 (hard assertion; derive: `length(roles()) - 1`) |
| `test/letflow/tenant_onboarding_test.exs:266-275, :318-330` | `length(rows) == 6` becomes derived (7) |
| `test/letflow/routers/identity_roles_guard_test.exs:6-15, :139` | prose "all seven" -> eight; if a literal role list, add `TENANT_AUDITOR` |
| `test/letflow/api/authorization_enforcement_test.exs` | route-declared-key allowlist: the link route is no longer `:AttachmentsRead` (L1); update the entry and the comment at :392-397 (AGENT_RUNNER still 403) |
| loops over `Authorization.roles()` expecting a denial (`tenant_modules_test.exs:66`, `tenant_modules_settings_test.exs:151`, `tenant_solutions_test.exs:61`, `me_test.exs:176-190`, `modules_test.exs:157-190`, `req442_tenants_mode_test.exs:260`, `bilimbaga_solution_e2e_test.exs:405`, `platform_scope_*`) | no edit expected (derived; the auditor is denied there); run them and edit only a failing one, with a comment citing this design |

NOT edited in this PR (removed from the previous revision): `promotion_context_entries_scope_test.exs` AC5, `platform_scope_authorization_test.exs` holder lists, `promotion_scope_test.exs`, `promotion_platform_events_shaping_test.exs`, `req077_promotion_pipeline_test.exs`: with `:PromotionsRead` withheld the auditor is simply one more denied role in their existing derived loops.

---

## 9. BUILD item 5 -- places that say six, seven, or enumerate the roles

Found by grep over `lib`, `test`, `docs`, `priv`, `web/src`, `README.md`, `CLAUDE.md`, `scripts`, `.claude` (historical records under `docs/migration/**`, `docs/issues/**`, `docs/status/**`, run reports, `test/specs/**`, `lib/letflow/design/**` are history and not edited).

Prose edits in `lib/` (docs and comments only):

| File:line | Current | New |
|---|---|---|
| `lib/letflow/api/authorization.ex:9-15` | "Seven roles (REQ-447)" | "Eight roles (REQ-448)"; names `TENANT_AUDITOR`, its closed 12-atom list and the withheld `PromotionsRead` |
| `authorization.ex:454` | `@doc "All seven Role values ..."` | eight; names `TENANT_AUDITOR` |
| `authorization.ex` `core_permissions/0` `@doc` ("All forty core ...") | forty | forty-one; names `:AttachmentLinksIssue` |
| `authorization.ex:184` | quotes design "granted to all six roles" | historical quotation; leave, add `TENANT_AUDITOR` to the holder list in the following sentence |
| `lib/letflow/identity/role_backfill.ex:97` | "seven roles, ..." | "eight roles ... seven elsewhere" |
| `lib/letflow/identity/role_registry.ex:81, 90, 151, 172-176` | seven; collision paragraph names `TENANT_ADMIN` only | eight / seven elsewhere; names both |
| `lib/letflow/identity/tenant_role.ex:39` | seven recognized literals | eight |
| `lib/letflow/identity_migration.ex:245` | "six recognized literals" (historical) | "the recognized literals (`roles/0`)" |
| `lib/letflow/routers/identity.ex:~60-90` | seven recognized literals | eight |
| `lib/letflow/tenant_onboarding.ex:132` | "all seven roles ..." | eight / seven; names `TENANT_AUDITOR` |
| `lib/mix/tasks/letflow.backfill_platform_roles.ex:6`, `letflow.seed.ex:20` | "seven ... six elsewhere" | eight / seven |
| router moduledoc holder enumerations | `audit.ex:108` (add `TENANT_AUDITOR` to `:AuditRead` holders), `dlq.ex:39`, `webhooks.ex:78` (non-holders), `help.ex:78`, `me.ex:~30-45` (holders: add `TENANT_ADMIN`, `TENANT_AUDITOR` if missing), `instances.ex:~280` (attachments holders; name `:AttachmentLinksIssue`), `services.ex:44` | re-grep `AGENT_RUNNER` under `lib/letflow/routers` and `lib/letflow/api`; make each enumeration complete for eight roles |
| `lib/letflow/plugs/tenant_status.ex` moduledoc | names `TENANT_ADMIN` as no exemption | add `TENANT_AUDITOR` (no code change) |

Test prose that says six/seven and is not in the failing list of section 8 (`authorization_role_realm_test.exs:14, 67` "five roles" stays untouched because the AC says it passes WITHOUT edits; `me_test.exs:163-168`, `tasks_test.exs:149`, `role_registry_test.exs:477-503`, `iss0778_platform_role_seeding_e2e_test.exs:215-277`, `identity_test.exs:1466`): comment hygiene only, edit where the file is already edited.

Docs: `docs/roles.md` (section 6.5); `docs/migration/decisions/0046-...md` gets ONE appended section "Closure of the TENANT_AUDITOR role (REQ-448 / Q-965), <UTC date>" (earlier text unchanged): role shipped; grant list = D6 minus `:PromotionsRead` as a DELIBERATE interim deviation pending Q-1011 with the one-line follow-up; `:AttachmentLinksIssue` added and why; `PlatformServicesManage` row added; the parity test location. Not edited: 0013, `docs/requirements.yaml` (DOC-UPDATER after RELEASE-VALIDATOR), `web/**` (REQ-450 owns web role literals; `role-set.spec.ts` is one-directional and keeps passing).

---

## 10. File-by-file change list for ELIXIR-DEV

`authorization.ex` and the realm file land in the SAME commit.

Production code:

1. `lib/letflow/api/authorization.ex`: `@roles` (+`:TENANT_AUDITOR` last), `role()` type, `role_from_string("TENANT_AUDITOR")`, `core_role_allows?(:TENANT_AUDITOR, p)` explicit 12-atom list (no `:PromotionsRead`), `is_task_worker_only?/1` (+ `not has_role?(roles, :TENANT_AUDITOR)`), L1: `@permissions` (+`:AttachmentLinksIssue`), `endpoint_policy_key("POST", ".../link")` returns it, `required_permission(:AttachmentLinksIssue)` identity clause, the atom appended to the explicit lists of `:PROCESS_DESIGNER`, `:PROCESS_OPERATOR`, `:TASK_WORKER`; prose per section 9.
2. `lib/letflow/routers/instances.ex`: the route at :406 declared with `:AttachmentLinksIssue`; moduledoc lines.
3. `lib/letflow/identity/role_registry.ex`: collision guard over two names (section 4.2); doc prose.
4. Prose only: `role_backfill.ex`, `tenant_onboarding.ex`, `tenant_role.ex`, `identity_migration.ex`, `routers/identity.ex`, the two mix tasks, router moduledocs, `plugs/tenant_status.ex`.
5. NOT touched: `lib/letflow/routers/promotions.ex` (Q-1011), `lib/letflow/identity.ex`, `TenantAdminMigration`, `PlatformTenant`, `Letflow.Plugs.*`, `priv/repo/migrations/`.

Data and docs:

6. `priv/keycloak/realms/bpm-default.json` (section 5).
7. `docs/roles.md`: rows `PlatformServicesManage` and `AttachmentLinksIssue`; auditor `PromotionsRead` cell `no`; role-section and matrix prose (section 6.5). Keep the single fenced block and header exactly as the parser contract states.
8. `docs/migration/decisions/0046-...md`: appended closure section.

Tests: section 8 (four new files plus the edit table).

Verification the run report must quote (AC6): `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test` (full), `mix letflow.check_boundaries`, the on-disk one-cell flip of section 6.4, and on QA after deploy the `RoleBackfill.run()` `seeded` count then the second run's `unchanged` count. Gates: CODE-DESIGN-VALIDATOR; SECURITY-REVIEWER MANDATORY (role grant, new permission, tenant-data read path, INV-1, INV-2, INV-5, INV-10); REVIEWER; TEST-DESIGNER and TEST-DESIGN-VALIDATOR; TEST-RUNNER; RELEASE-VALIDATOR; DOC-UPDATER flips REQ-448 only after RELEASE-VALIDATOR. REQ-448's own acceptance criterion 1 and BUILD item 1 are met only with the documented deviation; RELEASE-VALIDATOR must be told.

---

## 11. Invariants

* INV-A: `role_allows?(:TENANT_AUDITOR, p)` is true iff `p` is one of the 12 explicit atoms, `:MyModulesRead`, or a registered module manifest names `:TENANT_AUDITOR` for it. Never a platform-scope permission, `:Unknown`, any write, manage, export, import, token, user, role, module, settings, promotion, rollback or link-issue permission.
* INV-B (D7): no existing role gains or loses any effective route access. L1 only splits one route's permission and grants the new atom to exactly the roles that held the old one for that route.
* INV-C (INV-10): the auditor is never platform scope; `PLATFORM_ADMIN` handling is unchanged.
* INV-D (INV-1): every auditor read is scoped by the caller's own tenant prefix from `scoped_opts`; no request value selects a tenant; no new data-access path.
* INV-E (INV-2): no role-based bypass of field-level restrictions (F11).
* INV-F (INV-5): a denied auditor request is the same fixed 403 as for every role; unmatched paths are 403, not 404.
* INV-G: the deactivated-tenant gate has no exemption for the auditor.
* INV-H: seed and backfill are idempotent, never delete a binding, never write `group_members`, never overwrite a `:process_routing_role` row.
* INV-I: the matrix in `docs/roles.md` equals the code for every core permission, role and scope, enforced by the parity test on every `mix test`.
* INV-J: no route reachable by the auditor persists state (section 2.5); the sweep of section 7.3 plus the literal allowlist keeps it so.

---

## Open questions for the supervisor (each with a recommended default; nothing is silently decided)

Interim decisions already taken by the supervisor (listed so the advisory session sees them in one place): OQ-1 accepted; OQ-2 withheld; OQ-3 applied per section 2.5.

* OQ-8 (NEW). L1 adds a core permission, `:AttachmentLinksIssue`, to deny one route to the auditor while keeping `:AttachmentsRead` for its other GETs. It is additive and changes no existing role's access, but it is a charter-matrix change (a new row, 40 -> 41 core permissions, one more atom in three explicit role lists). RECOMMENDED DEFAULT: ship it in REQ-448 as designed. Alternatives and their cost: (a) re-key the route to `:AttachmentsManage` changes designers' and task workers' access (rejected); (b) an auditor-specific deny guard sits outside the matrix and the parity test (rejected); (c) leave link issuance allowed for the auditor in the interim, which contradicts the "deny anything that persists state" decision (would need your explicit approval). If you prefer to defer L1 to its own requirement, the auditor must then be shipped WITHOUT `:AttachmentsRead` as well, or with the known state-persisting route open; say which.
* OQ-9 (NEW). `POST .../link` for a tenant that has not yet created its signing key persists a secret even for the roles that keep access; with L1 that unchanged behaviour stays. RECOMMENDED DEFAULT: out of scope here.
* OQ-4. `docs/roles.md` charter text is reworded (auditor promotion note, "planned" wording, two new rows). RECOMMENDED DEFAULT: as designed; flagged because the charter is the ratified user-facing text.
* OQ-5. `promo-reader-uat` (QA realm `bilimbaga`) stays `TENANT_ADMIN` (REQ-447 OQ-9). RECOMMENDED DEFAULT: retargeting to `TENANT_AUDITOR` is an infra/UAT decision after this merges; note that an auditor will not see promotion reviews until the follow-up of section 3.
* OQ-6. The backfill resets `role_claims_synced_at` for every user of every tenant once and halts on the first failing tenant (existing behaviour, accepted by REQ-447). RECOMMENDED DEFAULT: accept unchanged; collision guard widened to two names only.
* OQ-7. Infra contract for tenant realms goes in the PR description and run report (single-file scope here). RECOMMENDED DEFAULT: ORCH forwards it to infra.

## Overlap with Q-1011 (files owned elsewhere)

With `:PromotionsRead` withheld there is NO file overlap: REQ-448 does not edit `lib/letflow/routers/promotions.ex` or any promotion test (section 8 "NOT edited"). The only coupling is the follow-up of section 3, to be sequenced after Q-1011 merges.
