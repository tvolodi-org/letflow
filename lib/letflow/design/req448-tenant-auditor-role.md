# REQ-448 / Q-965 / GH #2236 -- TENANT_AUDITOR role and the docs/roles.md <-> Authorization parity test

Status: DESIGN (CODE-DESIGNER). Written against `origin/main` 334246f1 (branch `feat/Q-965-tenant-auditor-role`). Design only: signatures, shapes, algorithms in prose, tables, invariants. No implementation code, no tests, no `lib/` edits.

Authority: decision `docs/migration/decisions/0046-admin-scopes-and-role-charter.md` D3, D5, D6, D7, D10 and its appended correction and closure sections; `docs/roles.md` (matrix, TARGET state, format fixed by REQ-445); `lib/letflow/design/req446-named-scoped-permissions.md`, `req447-tenant-admin-role.md`, `req447-infra-realm-mapping.md`; `docs/agents/instructions/security-invariants.md` INV-1, INV-2, INV-5, INV-10.

Already decided by the supervisor (NOT reopened here): `:EntitiesRecordsExport` is NOT granted to the auditor. An auditor reads entity data through the query routes only.

Pre-condition verified on this branch: REQ-447 is `done`, both PRs merged (`Authorization.effective_roles/2` exists at `authorization.ex:~592`, the C6 switch is deleted, `@roles` has seven atoms, `is_task_worker_only?/1` already excludes `TENANT_ADMIN`). REQ-446 is merged (`:PromotionsRead`, `:PromotionsManage`, `:DefinitionsRollback`, `:TenantSettingsManage`, `:PlatformServicesManage` exist in `core_permissions/0`, 40 atoms).

---

## 0. Summary

1. `Letflow.Api.Authorization` gains `:TENANT_AUDITOR` as the EIGHTH and last element of `@roles`, one `role()` union member, one `role_from_string/1` clause, one explicit-list `core_role_allows?/2` clause (13 core atoms) plus the role-agnostic `:MyModulesRead` (14 effective grants, section 2). `is_task_worker_only?/1` is extended (see OQ-1).
2. Seeding is NOT a new mechanism. `RoleRegistry.seedable_role_names/1` derives from `Authorization.roles/0`, so every tenant (platform tenant included) is seeded a `TENANT_AUDITOR` group and `:platform_role` binding by `TenantOnboarding.provision_and_migrate/1` with no edit; existing tenants get it from the existing `Letflow.Identity.RoleBackfill.run/0` (`mix letflow.backfill_platform_roles`, on QA the release `rpc`), which already classifies a tenant as `:seeded` when any seedable name is missing. One real edit: the name-collision guard in `RoleRegistry` is widened from the single name `TENANT_ADMIN` to `TENANT_ADMIN` and `TENANT_AUDITOR` (section 4).
3. Realm file `priv/keycloak/realms/bpm-default.json`: realm role `TENANT_AUDITOR` and a seeded `auditor-user` (section 5). `authorization_role_realm_test.exs` passes unedited because it compares sorted name sets of the file and `roles/0` with no literal list or count, and both change in the same PR. A DIFFERENT test (`tenant_admin_seeding_test.exs:297-302`) hard-codes seven and `List.last == "TENANT_ADMIN"` and MUST be edited (section 8).
4. Parity test `test/letflow/api/roles_matrix_parity_test.exs`: parses the single fenced block of `docs/roles.md`, compares every cell and the scope column with the code, fails on a missing, extra, duplicate or malformed row, and proves its own sensitivity with in-memory one-cell-flip mutations (section 6). Finding: the matrix has NO `PlatformServicesManage` row (F16 of the REQ-447 design) so the test fails on first run until the row is added to `docs/roles.md` (a docs fix, not a test edit).
5. Router tests (section 7): all 23 routers mounted in `Letflow.Plugs.ApiPipeline` get a named entry, with a completeness guard that parses the pipeline's `forward` lines so a future router cannot ship without a decision.
6. Seven-to-eight statements: section 9 lists every place found by grep.

---

## 1. Facts established from the code (file:line on 334246f1)

| # | Fact | Evidence |
|---|---|---|
| F1 | `@roles` is a seven-atom list ending `:TENANT_ADMIN`; `role()` type has seven members; `role_from_string/1` is exact-match, case-sensitive, anything else is `nil`. | `lib/letflow/api/authorization.ex:272-281` (type), `:384-392` (`@roles`), `:630-638` (`role_from_string`) |
| F2 | `role_allows?/2` first clause grants `:MyModulesRead` to every role; then `core_role_allows?/2 or permission in Catalog.role_grants(role)`. A role absent from the core clauses and from every manifest holds nothing else. | `authorization.ex:1327-1335` |
| F3 | Per-role core clauses: `PLATFORM_ADMIN` catch-all `true`; `TENANT_ADMIN` = `permission_scope(p) == :tenant`; the four others are explicit atom lists. | `authorization.ex:1337-1470` |
| F4 | `permission_scope/1`: compile-time map over `core_permissions/0` (platform: `:TenantsManage`, `:PlatformServicesManage`; all else tenant), Catalog atoms tenant, any other atom `:platform` (fail closed). | `authorization.ex:434-442`, `:501-512` |
| F5 | `evaluate_access/2`: `:Unknown` denied for all; `:UnmatchedRoute` and `:UnmatchedPlatformPath` allowed only for platform-tenant `PLATFORM_ADMIN`; `:MetricsRead` as an ENDPOINT KEY is `:Allow` for everyone (the global `/metrics` route), distinct from the `:MetricsRead` PERMISSION; `PLATFORM_ADMIN` is dropped from the roles unless `platform_tenant?` is exactly `true`. | `authorization.ex:1018-1068` |
| F6 | `is_task_worker_only?/1` is true iff `TASK_WORKER` held and none of `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TENANT_ADMIN` held. It is the single switch for `GET /tasks` row filtering and for `GET /tasks/inbox` scope (`routers/tasks.ex:~256-266`, via `effective_roles/2`). A `TENANT_AUDITOR` alone is already NOT worker-only (no `TASK_WORKER`). | `authorization.ex:1147-1154`; `routers/tasks.ex:196-266` |
| F7 | `RoleRegistry.seedable_role_names/1`: all of `roles/0` for the platform tenant's schema, all but `PLATFORM_ADMIN` otherwise (fail closed). `seed_default_platform_role_groups/1` seeds those in `roles/0` order, after `check_tenant_admin_name_free/1`, which guards ONLY the name `TENANT_ADMIN` against a `:process_routing_role` row (F12 of REQ-447: `upsert_role/4` overwrites `kind` on name conflict). | `lib/letflow/identity/role_registry.ex:149-232` |
| F8 | `TenantOnboarding.provision_and_migrate/1` -> `seed_platform_roles/1` -> `seed_default_platform_role_groups/1`. A seeding failure leaves the tenant `:migrating`. | `lib/letflow/tenant_onboarding.ex:172-195` |
| F9 | `RoleBackfill.run/0`: per registration, reads held `:platform_role` names, seeds, classifies `:seeded` when any `seedable_role_names/1` name was missing (and then NULLs `role_claims_synced_at` for every user of that schema, ISS-0910), else `:unchanged`. Halts the sweep on the first `{:error, _}` or exception. Nothing calls it automatically; it is the mix task or, on a deployed container (no Mix), the release `rpc`. | `lib/letflow/identity/role_backfill.ex:129-228`; `req447-infra-realm-mapping.md:125-137`; `scripts/uat_preflight.sh:657` |
| F10 | `Identity` token issuance and the `POST /roles` built-in-name guard (H2) derive from `roles/0` (`@issuable_token_roles`, `Authorization.builtin_role_name?/1`), so `TENANT_AUDITOR` becomes an issuable token role and a protected binding name with no edit. | `lib/letflow/identity.ex:1380`; `authorization.ex:~640-660`; `routers/identity.ex` handle_upsert_role |
| F11 | Entity field restrictions are keyed by `user_id` grants; `FieldGrants` and `TypeAccess` contain no role parameter or role name (grep `role` over `lib/letflow/entities/query/field_grants.ex` and `lib/letflow/entities/type_access.ex`: no hit). So there is no role-based bypass for any role including the new one (INV-2). | grep on this branch |
| F12 | `docs/roles.md` matrix: 39 rows, 8 role columns, `scope` column; it has NO `PlatformServicesManage` row although `core_permissions/0` has it (scope platform). Every one of the 35 older rows and the four planned rows already has the TENANT_AUDITOR column; the auditor's `yes` cells are exactly the 14 atoms of D6 (13 core plus `MyModulesRead`; `PromotionsRead` included). I compared all non-auditor columns of the six existing roles with the code clauses by hand: they agree. | `docs/roles.md:74-113` |
| F13 | Tests that hard-code the role count or last role: `authorization_test.exs` (`roles/0` list at :22-31; grids at :636, :776-816, :1166-1203, :1548, :1681-1704, :1833-1871, :2227-2255; titles "7 roles x N" at :781, :1171, :1838, :2232; "28 pairs" at ~:655), `authorization_tenant_admin_test.exs:21-35`, `platform_admin_role_binding_test.exs:80-89`, `tenant_admin_seeding_test.exs:161, :297-302`, `role_backfill_test.exs:478-530`, `role_registry_test.exs:660-690`, `tenant_onboarding_test.exs:266-275, :318-330`, `identity_roles_guard_test.exs:6-15, :139`. | grep on this branch |
| F14 | `promotion_context_entries_scope_test.exs` "AC5" tripwire (~:360-420) lists `["TENANT_AUDITOR"]` among roles expected to get 403 on `GET /promotions/:id/context` and states that REQ-448 must move the row. `platform_scope_authorization_test.exs` ~:120-150 and ~:272-292 enumerate holders of `:PromotionsRead` as `PLATFORM_ADMIN` and `TENANT_ADMIN` only. These fail the moment the grant lands. | read on this branch |
| F15 | The 23 routers mounted in `Letflow.Plugs.ApiPipeline` (`api_pipeline.ex:141-222`): Identity, Tenants, TenantSettings, TenantModules, TenantSolutions, Modules, Instances, Definitions, Tasks, Promotions, Onboarding, SolutionPacks, Audit, Dlq, Webhooks, Services, AdminServices, Entities, PublicReadHandles, Help, PlatformMigrations, EventRetention, Me. Every one except `Modules` is an `AuthorizedRouter` exposing `__authz_routes__/0 :: [{method, local_path, policy_key}]`. | `api_pipeline.ex`; `test/letflow/routers/tenant_admin_routes_test.exs:~226-246` uses the same two mechanisms |

---

## 2. BUILD item 1 -- `Letflow.Api.Authorization`

### 2.1 Role atom, type, string clause

* `@roles` gains `:TENANT_AUDITOR` as the eighth and LAST element. Order is `docs/roles.md`'s: the six existing roles, `TENANT_ADMIN`, `TENANT_AUDITOR`. The literal stays a plain atom list with no comment containing `]` between the brackets, because `web/tests/guards/role-set.spec.ts` extracts the list with the pattern `@roles \[([^\]]+)\]` from this very file.
* `role()` type union gains `:TENANT_AUDITOR`.
* `role_from_string/1` gains the exact clause for the string `"TENANT_AUDITOR"` returning `:TENANT_AUDITOR`. Exact match, case-sensitive, no trimming (`"tenant_auditor"`, `" TENANT_AUDITOR"`, `"TENANT-AUDITOR"` parse to nothing, like every other clause).
* `roles/0` `@doc`, the moduledoc heading "Seven roles (REQ-447)" and its prose are updated to eight and name `TENANT_AUDITOR`. New public surface: none besides the atom in `roles/0` and `role()`.
* Public functions that become correct with no edit because they derive from `roles/0`: `roles_from_strings/1`, `effective_roles/2`, `builtin_role_name?/1` (so `POST /roles` for the name `TENANT_AUDITOR` needs `:UsersGroupsRolesManage` for any `kind`, H2), `Identity.create_token/3` role validation, `Catalog.validate_role_grants_known/1`, `RoleRegistry.platform_role_names/0`, `IdentityMigration.platform_role_names/0`, `mix letflow.check_uat_scenario_schema` `known_role_names/0`.

### 2.2 Grant rule (exact permission list)

New private clause of `core_role_allows?(role, permission)` for `:TENANT_AUDITOR`: true iff `permission` is a member of the closed list below. Placed after the `:TENANT_ADMIN` clause and before `:PROCESS_DESIGNER` (any position before the catch-all-free tail is correct; clauses are per role). Everything not listed is `false` from the core clause; the Catalog fallback in `role_allows?/2` stays additive, so a module permission is held by the auditor only if some registered module's manifest `role_grants` names `:TENANT_AUDITOR` (none does today: `Catalog.role_grants(:TENANT_AUDITOR) == []`). There is deliberately NO `permission_scope == :tenant` rule for this role (that is `TENANT_ADMIN`'s).

| # | Permission | Why (D6) | Consumers (route class) |
|---|---|---|---|
| 1 | `:DefinitionsRead` | read definitions | `GET /definitions*`, `GET /services`, `POST /definitions/:id/validate`, `POST /solution-packs/export`, `POST /solution-packs/:id/update-review` (read-class POSTs, OQ-3) |
| 2 | `:InstancesRead` | read instances | `GET /instances*` |
| 3 | `:TasksRead` | read all tenant tasks | `GET /tasks`, `GET /tasks/inbox`, `GET /tasks/:id` |
| 4 | `:AuditRead` | audit chain | `GET /audit` |
| 5 | `:MetricsRead` | tenant metrics permission (the global `/metrics` endpoint key is unaffected, F5) | permission only |
| 6 | `:AttachmentsRead` | instance attachments | `GET /instances/:id/attachments*`, `POST .../link` (read-class POST, OQ-3) |
| 7 | `:EntitiesDefinitionsRead` | entity definitions | `GET /entities/definitions*` |
| 8 | `:EntitiesQuery` | query entity records | `POST /entities/query` |
| 9 | `:EntitiesAggregate` | aggregate | `POST /entities/query/aggregate` |
| 10 | `:EntitiesAttachmentsRead` | entity attachments | `GET /entities/records/:t/:id/attachments*` |
| 11 | `:HelpRead` | help | `GET /help/resolved` |
| 12 | `:MembershipsRead` | own memberships | `GET /me/memberships` |
| 13 | `:PromotionsRead` | promotion reads (D3 binding condition, section 3) | `GET /promotions`, `/:id`, `/:id/context`, `/platform-events` |
| - | `:MyModulesRead` | already granted to every role by the first `role_allows?/2` clause; NOT repeated in the list (same as the other four lists) | `GET /me/modules` |

Effective grant set: 14 atoms (13 listed plus `:MyModulesRead`). The other 26 core permissions are denied, in particular: every `*Write`, `*Manage`, `*Start`, `*Cancel`, `*Complete`, `*Assign`, `*Import`, `*Export`, `*ExportUnredacted`, `*Rollback`, `:DlqOperate`, `:InstancesAdvanceTimer`, `:PublicReadHandlesIssue`, `:TenantsManage`, `:PlatformServicesManage`.

### 2.3 Task scope

AC text: "GET /tasks returns all tasks of the tenant for this role (task_scope :all), because is_task_worker_only?/1 is false for it." For a caller holding `TENANT_AUDITOR` alone that is already true with no edit. For a caller holding `TENANT_AUDITOR` plus `TASK_WORKER` (an auditor who is also a worker) the current function would row-filter to own tasks. `req447-tenant-admin-role.md` section 3.1 states "REQ-448 will add `TENANT_AUDITOR` to the same exclusion list". Design (default of OQ-1): `is_task_worker_only?/1` gains `not has_role?(roles, :TENANT_AUDITOR)`. Effect: `GET /tasks` and `GET /tasks/inbox` are unfiltered for any caller who holds the auditor role. It grants nothing new: `:TasksRead` is already held; mutation permissions still come only from the other roles held.

### 2.4 No other change in this module

`evaluate_access/2`, `has_permission_in_scope?/3`, `permission_scope/1`, `endpoint_policy_key/2`, `required_permission/1` are unchanged. `TENANT_AUDITOR` holds no platform-scope permission by construction (explicit list, none platform) so INV-10 needs no new line; a test pins it (section 8).

---

## 3. The D3 binding condition for `:PromotionsRead` (explicit)

Decision 0046 D6 grants the auditor "the read permission(s) REQ-446 introduced for promotions (`:PromotionsRead`, subject to the binding condition under D3)". REQ-446 introduced exactly one read permission: `:PromotionsRead` (the correction section of 0046 folded `GET /promotions/platform-events` into it; no separate platform-events permission exists). The condition and its status:

| Part | Status | Evidence |
|---|---|---|
| Source-tenant ownership proof on the cross-tenant promote route | MET by REQ-446 | `lib/letflow/routers/tenants.ex` `handle_promote` (~line 448, comment "ISS-0993 row 34") calling `TenantTarget.authorize_target_tenant/2` (`lib/letflow/api/tenant_target.ex:31-39`). The auditor does not hold `:PromotionsManage`, so it never reaches that route (403 first). |
| Tenant-PLATFORM_ADMIN denial and cross-tenant negative tests | shipped with REQ-446 (`promotion_scope_test.exs`, `promote_source_tenant_test.exs`) | 0046 correction section |
| Plan content and tenant ids of the read routes | CLOSED for `/context` and `/platform-events` by allowlists (ISS-0999, ISS-1021, ISS-1023): non-operators see `entries == []` for a review naming foreign tenants | 0046 closure sections; `routers/promotions.ex:~1054-1140` |
| Stored-tenant check on `GET /promotions`, `GET /promotions/:id`, `GET /promotions/:id/context` | NOT done: tracked as Q-1011 / GH #2311 / ISS-1029 (LOW) | 0046 final section; `handle_context` at `promotions.ex:526` has no `stored_tenants_authorized?/3` call |

Consequence for REQ-448: the auditor's `PromotionsRead` cell is `yes`, as already printed in `docs/roles.md` and as `TENANT_ADMIN` already holds it. The remaining exposure is identical in kind to `TENANT_ADMIN`'s (a non-operator reader of the platform tenant's own schema reading operator-created reviews; own schema only, so INV-1 holds, and the plan is shaped). REQ-448 adds NO edit to `lib/letflow/routers/promotions.ex` (file owned by Q-1011). Sequencing is OQ-2. A tripwire test proves the shaped behaviour for the auditor (section 8, F14 rows).

---

## 4. BUILD item 2 -- seeding and backfill

### 4.1 New tenants (no new code path)

* `RoleRegistry.seedable_role_names/1`: no edit; it returns `TENANT_AUDITOR` last, for every tenant schema (platform tenant: all eight; any other schema: seven).
* `TenantOnboarding.provision_and_migrate/1` and `recover_provisioning/1`: no signature or body change; docs updated (section 9). A newly provisioned non-platform tenant ends with seven `:platform_role` bindings (no `PLATFORM_ADMIN`), the platform tenant with eight. A seeding error (including the collision below) still yields `{:error, {:role_seeding_failed, reason}}` and leaves the tenant `:migrating`.

### 4.2 Collision guard (the one real edit in `RoleRegistry`)

Problem (F7): `tenant_role.name` is unique across kinds and `upsert_role/4` overwrites `kind` and `group_id` on conflict. A tenant that already owns a `:process_routing_role` row called `TENANT_AUDITOR` (a process definition naming a routing role "TENANT_AUDITOR" is legal: `:process_routing_role` has only format checks) would be silently converted into a platform binding. REQ-447 guarded only `TENANT_ADMIN`.

Change: the private function `check_tenant_admin_name_free/1` becomes a guard over the set of names introduced after the ISS-0774 `kind` backfill: `["TENANT_ADMIN", "TENANT_AUDITOR"]` (module attribute). One read, scoped by `prefix:`, `where name in ^names and kind == :process_routing_role`, first hit by name order. Return type of `seed_default_platform_role_groups/1` is unchanged: `{:error, {:role_name_taken_by_routing_role, name}}` with the colliding name, nothing written. The six older names need no guard: the ISS-0774 migration classified every row with those names as `:platform_role`, and H2 (`routers/identity.ex`) forbids creating a `:process_routing_role` with any built-in name since REQ-447 (default of OQ-6: do not widen further).

`TenantAdminMigration` (REQ-447) is NOT touched: its own step-1 collision check concerns `TENANT_ADMIN` and `PLATFORM_ADMIN` only and the migration does not seed the auditor.

### 4.3 Existing tenants (idempotent backfill, same mechanism as REQ-447 section 3.9)

* Module and function: `Letflow.Identity.RoleBackfill.run/0` (`lib/letflow/identity/role_backfill.ex`), unchanged signature `{:ok, %{seeded, unchanged, role_claims_markers_reset}} | {:error, {:backfill_failed, tenant_id, reason}}`. CLI: `Mix.Tasks.Letflow.BackfillPlatformRoles` (`mix letflow.backfill_platform_roles`); on a deployed container, `Letflow.Identity.RoleBackfill.run()` through the release `rpc` exactly as `req447-infra-realm-mapping.md` line 137 shows.
* Why no code edit is needed in `RoleBackfill`: `classify/4` already computes "missing" as any name of `RoleRegistry.seedable_role_names(schema_name)` absent from the held `:platform_role` names. After this change every existing tenant lacks `TENANT_AUDITOR`, so every tenant is `:seeded` on the first run and `:unchanged` on the second. Moduledoc and mix-task text that say "seven" are updated (section 9).
* Idempotency invariant: after one successful run every tenant holds exactly its seedable set (ordinary: seven names, platform tenant: eight); a second `run/0` reports every tenant under `unchanged`, writes no row and resets no marker. It never deletes a binding and never writes `group_members` (INV-BF2): a user obtains the auditor role only by the claim sync at next login (realm role `TENANT_AUDITOR`, binding now present) or by `Identity.add_group_member/3`.
* Two accepted properties (same as REQ-447, listed so SECURITY-REVIEWER sees them; defaults in OQ-6): (a) because every tenant is `:seeded`, the ISS-0910 reset NULLs `role_claims_synced_at` for every user of every tenant once; users re-run the additive claim sync at next login, so no role is lost or widened beyond the realm's claims; (b) the sweep halts at the first failing tenant (collision or a vanished schema), reported with its tenant id; a retry converges.
* QA operating step (recorded in the run report): after the deployment containing this change, run the backfill through `rpc`, quote the `seeded` count and then the second run's `unchanged` count. Until it runs, an existing tenant has no `TENANT_AUDITOR` binding, so a token claiming the role resolves to no role (fail closed, 403), never to a wider role.

### 4.4 No Ecto migration, no new table, column, index or constraint

All change is data change in the existing per-tenant `groups` and `tenant_role` tables. No file under `priv/repo/migrations/`. The historical migration `20260921000002_add_kind_to_tenant_role.exs` names six literals in SQL; it is immutable history and is not edited.

---

## 5. BUILD item 3 -- `priv/keycloak/realms/bpm-default.json`

Edits (data only):

* `roles.realm` gains `{ "name": "TENANT_AUDITOR" }` as the eighth entry, same shape as the seven others.
* `users` gains a seeded user, in the shape of `tenant-admin-user`: `username` `auditor-user`, `email` `auditor@letflow.local`, `firstName` `Auditor`, `lastName` `User`, `enabled` true, `emailVerified` true, `requiredActions` `[]`, one `password` credential (non-temporary; a fixed development password following the file's convention, e.g. `auditor-pass`; this file is a development seed, not a QA secret), `realmRoles: ["TENANT_AUDITOR"]` and nothing else.
* `seedVersion` is bumped to the merge date.
* No other user changes: `admin-user` stays `PLATFORM_ADMIN`, `tenant-admin-user` stays `TENANT_ADMIN`.

Why `test/letflow/api/authorization_role_realm_test.exs` passes WITHOUT edits: it reads `roles.realm[].name` from the file, sorts, and asserts equality with `Authorization.roles()` mapped to strings and sorted. It contains no literal role list and no count (only the word "five" in a moduledoc and an error message). Adding the name to both sides in the same PR keeps the equality; the file is not touched. It would fail only if one side landed alone, which is why section 10 puts `authorization.ex` and the realm file in the same change.

Tests in OTHER files that read the same realm file and must be updated: `test/letflow/identity/tenant_admin_seeding_test.exs:297-302` ("TENANT_ADMIN is a realm role and the realm role list equals roles/0 (seven)": asserts `length(names) == 7` and `List.last(names) == "TENANT_ADMIN"`; both become false) and the neighbouring "no other user holds TENANT_ADMIN" test stays valid. New assertion (in that file or the new auditor seeding test, section 8): `auditor-user` exists with exactly `["TENANT_AUDITOR"]`, `admin-user` still `["PLATFORM_ADMIN"]`, no other user holds `TENANT_AUDITOR`.

Realms other than `bpm-default` are not in the repository. Infra contract (stated here because this task may write only one file; the implementer places it in the PR description and the run report, in the style of `req447-infra-realm-mapping.md`): every tenant realm that issues Letflow roles should define a realm role `TENANT_AUDITOR` (0013 principle: a realm defines every built-in role) and may assign it to chosen users; nothing in Letflow requires it to exist, and there is no alias in code (a realm that does not define it simply issues no such claim).

---

## 6. BUILD item 4 -- the parity test

File: `test/letflow/api/roles_matrix_parity_test.exs`, module `Letflow.Api.RolesMatrixParityTest`, `use ExUnit.Case, async: true` (pure: reads a file, calls pure `Authorization` functions; no database, no pin, no application env). The file path is resolved from `__DIR__` like `authorization_role_realm_test.exs` (not from the working directory). All helper functions are private to the test module (no `lib/` or `test/support` addition, so the check cannot be bypassed by editing production code).

### 6.1 Parser contract (the format fixed by REQ-445, stated by `docs/roles.md` lines 62-66)

Input: the text of `docs/roles.md`. Locate the heading line `## Matrix`; take the FIRST fenced block (triple backtick open and close) after it. Exactly one such block must exist after the heading; zero or an unterminated fence is a violation `{:no_matrix_block}`. Within the block:

* Line 1 is the header: whitespace-separated tokens; first token `permission`, last token `scope`, the tokens between are role names and must equal `Authorization.roles/0` mapped to strings, same order (eight). Otherwise `{:header_mismatch, expected_tokens, actual_tokens}`.
* Every following non-blank line is a row: split on runs of whitespace; must have 1 + 8 + 1 = 10 tokens, else `{:bad_row_width, line_number, token_count}`.
* Token 1 is the permission atom name without the colon. A name appearing twice is `{:duplicate_row, permission}`.
* Tokens 2..9 are cells and must be exactly `yes` or `no`, else `{:bad_cell, permission, role, raw}`.
* Token 10 is `platform` or `tenant`, else `{:bad_scope, permission, raw}`.

Parsed shape (types only): `matrix = %{header: [String.t()], rows: [row]}`, `row = %{permission: String.t(), line: pos_integer(), cells: %{String.t() => boolean()}, scope: :platform | :tenant}`.

### 6.2 Comparison contract

Let `code_permissions = Authorization.core_permissions()` mapped to strings (40 atoms). Module (Catalog) permissions are NOT in the matrix (docs state so) and are not iterated.

1. Row set equality: a code permission without a row is `{:missing_row, permission}`; a row whose name is not in `code_permissions` is `{:extra_row, permission}`. Both directions fail (AC "a missing or extra row fails").
2. For every row and every role string `r` (atoms obtained from `Authorization.roles/0`, never from `String.to_existing_atom/1` on file input):
   * `r != PLATFORM_ADMIN`: code value `Authorization.role_allows?(r_atom, p_atom)` (this includes the Catalog fallback, which cannot affect a core atom because Catalog validation forbids core-atom collisions).
   * `r == PLATFORM_ADMIN`: code value is evaluated IN THE PLATFORM TENANT: `Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], p_atom, true)`. (`role_allows?(:PLATFORM_ADMIN, _)` is a vacuous `true`; the platform-tenant evaluation is what the charter's "yes means as evaluated in the platform tenant" requires and is not vacuous for the platform-scope rows.)
   * Mismatch: `{:cell_mismatch, permission, role, doc_value, code_value}`.
3. Scope column: doc scope must equal `Authorization.permission_scope(p_atom)`, else `{:scope_mismatch, permission, doc, code}`. Plus one set check: the set of rows marked `platform` equals `Authorization.platform_permissions/0` as strings (guards a scope table edited without `permission_scope/1`'s consumers noticing).
4. Two extra sanity assertions that are NOT matrix cells and carry the D4 meaning: for every permission, `PLATFORM_ADMIN` evaluated with `platform_tenant?` false is denied for every permission (tenant and platform scope), and for every non-`PLATFORM_ADMIN` role `has_permission_in_scope?([r], p, true) == has_permission_in_scope?([r], p, false) == role_allows?(r, p)` for core permissions (a role's cell does not depend on the platform flag).
5. `evaluate_access/2` is deliberately NOT used to derive cells: its `:MetricsRead` ENDPOINT key is `:Allow` for every caller (F5), which would falsely contradict the permission column.

### 6.3 Tests inside the file (names)

| Test | Proves |
|---|---|
| "the repository's docs/roles.md has no violations against the code" | the real file passes: header, 40 rows, 320 cells, scope column |
| "the matrix has exactly the 40 core permissions: PlatformServicesManage is present and scope platform" | closes F12 (the docs fix is pinned) |
| "flipping one cell is detected: TENANT_AUDITOR / PromotionsRead yes -> no" | in-memory textual mutation of the real file text on exactly one row/column; result is exactly one `{:cell_mismatch, "PromotionsRead", "TENANT_AUDITOR", false, true}` |
| "flipping one cell is detected: PROCESS_OPERATOR / TenantsManage no -> yes" | a cell flipped to the permissive side |
| "flipping the PLATFORM_ADMIN / TenantsManage cell is detected through the platform-tenant evaluation" | the non-vacuous PLATFORM_ADMIN path |
| "flipping one scope cell is detected: TenantsManage platform -> tenant" | scope column |
| "a missing row is detected: EntitiesQuery removed", "an extra row is detected: a bogus permission appended" | row-set both directions |
| "a swapped header (two role columns exchanged) is detected" | header order |
| "a duplicate row, a non-yes/no cell and a short row are each detected" | parser strictness |
| "the TENANT_AUDITOR column is exactly the 14 atoms of 0046 D6" | pins the decision-record list literally, independent of the code (so a code and docs change that drift together from D6 still fails): the 14 names are written as a literal list in the test with a comment citing D6 |
| "every role in roles/0 has a column and every column is a role in roles/0" | no stale column |

The mutation tests operate on a string copy; they never write a file. They make the AC "fails when one cell of the matrix is flipped" a permanent, automated proof.

### 6.4 The one-time on-disk demonstration (AC5, "shown once in the test run report, then reverted")

Procedure for ELIXIR-DEV / TEST-RUNNER (the memory rule "subagent destroyed uncommitted work" applies: no `git checkout`, no `git stash`, no `git restore` on tracked files):

1. Commit all work first, so the tree is clean.
2. With the Edit tool, flip exactly one cell in `docs/roles.md` (the `TENANT_AUDITOR` cell of `PromotionsRead`, `yes` to `no`).
3. Run `mix test test/letflow/api/roles_matrix_parity_test.exs` and quote the failing output (the first test fails with the `{:cell_mismatch, ...}` line naming `PromotionsRead` and `TENANT_AUDITOR`; the mutation tests still pass).
4. Revert with the Edit tool (flip the cell back), re-run the file and quote the pass, and quote `git diff --stat` showing no diff for `docs/roles.md` relative to the commit of step 1.

### 6.5 "If the charter and the code disagree, fix whichever is wrong against the decision record"

Disagreements found and the decision-record resolution:

| Finding | Resolution | Basis |
|---|---|---|
| `PlatformServicesManage` has no row in `docs/roles.md` | add the row: `PlatformServicesManage` with `yes` for `PLATFORM_ADMIN`, `no` for all seven others, scope `platform` (placed after `EntitiesRestrictionsManage`) | `@platform_permissions` (`authorization.ex:434`); 0046 D3 "Platform scope: `:TenantsManage` and whatever REQ-446 classifies as platform"; ISS-0993 design section 5; REQ-447 design F16 and OQ-13 (assigned to REQ-448) |
| matrix prose says rows after `EntitiesRestrictionsManage` "are planned permissions" and the file calls itself "the TARGET state" | reword: all rows are current code after REQ-448; keep the pointer to 0046 | docs fix; no behavioural content |
| role sections "Does" for TENANT_AUDITOR says "promotions reads once the ownership proof exists" | reword to state it exists (REQ-446) | 0046 correction section |

No code cell is wrong. The six existing roles' columns and the `TENANT_ADMIN` column agree with the code (F12).

---

## 7. Router tests (AC2): one named write route per mounted router

File: `test/letflow/routers/tenant_auditor_routes_test.exs`, modelled on `tenant_admin_routes_test.exs`: `use Letflow.DataCase, async: false` (the platform pin is VM-global); `setup` builds `Fixture.three_tenants!()` (p, a, b) and `Fixture.pin!(p.tenant_id)`; direct dispatch with `Fixture.router_conn(method, path, fixture, ["TENANT_AUDITOR"], body)` for the per-router table, and the FULL pipeline (`Fixture.mint_token!(fixture, ["TENANT_AUDITOR"])`, `Fixture.api_conn/5`, `Fixture.dispatch_api/1`) for the pipeline block. Reuse `Scope` helpers (`Letflow.Support.PromotionScopeFixture`) and the seeding helpers of `tasks_test.exs` and `entities_test.exs`.

### 7.1 200 block (AC2 first half)

| Request | Router | Expectation |
|---|---|---|
| `GET /definitions` | Definitions | 200 |
| `GET /instances` | Instances | 200 |
| `GET /tasks` | Tasks | 200 and UNFILTERED: seed tasks assigned to two different other users in tenant A; the auditor sees both (`task_scope :all`); control in the same test: a `TASK_WORKER` alone sees only its own (file `tasks_test.exs` describe "REQ-132 AC3" is the model) |
| `GET /tasks/inbox` | Tasks | 200 and unfiltered (same fixture) |
| `GET /audit` | Audit | 200 |
| `POST /entities/query` | Entities | 200 for an existing entity type with a valid minimal body (copy the body from `entities_test.exs` POST /query happy path) |
| `POST /entities/query/aggregate` | Entities | 200 |
| `GET /promotions` | Promotions | 200 (tenant A empty list) |
| `GET /me/memberships`, `GET /me/modules`, `GET /help/resolved`, `GET /services` | Me, Help, Services | 200 |

The same GETs are repeated through the full pipeline with a real API token for tenant A and for the platform tenant P (P's `TENANT_AUDITOR` is a non-operator: tenant routes 200, platform prefixes 403).

### 7.2 403 block: representative write route per router (AC2 second half, "the test names the route per router")

Authorization precedes every lookup (the "ordering guarantee" of `AuthorizedRouter`), so an unused UUID in a path is enough: the answer is 403, never 404. A `403` also asserts that the response body is the fixed `insufficient permissions` shape and, for the router table, that a row count snapshot (tenants, definitions, instances, tokens, entity records) is unchanged.

| # | Router (mount) | Named representative route | Policy key to permission | Notes |
|---|---|---|---|---|
| 1 | Identity (`/identity`) | `POST /users` | `:UsersManage` to `:UsersGroupsRolesManage` | also `GET /users` 403, `POST /tokens` 403, `POST /roles` 403 |
| 2 | Tenants (`/tenants`) | `POST /` | `:TenantsManage` (platform) | also `POST /:test_tenant_id/promote/:process_key` 403 (`:PromotionsManage`) |
| 3 | TenantSettings (`/tenant/settings`) | `PATCH /` | `:TenantSettingsManage` | |
| 4 | TenantModules (`/tenant/modules`) | `POST /` | `:ModulesManage` | |
| 5 | TenantSolutions (`/tenant/solutions`) | `POST /` | `:ModulesManage` | |
| 6 | Modules (`/modules`, plain Plug) | `POST /modules/exam/exam-sessions` with the exam module installed in tenant A | manifest `route_policies` to `:ExamSessionStart` (granted to `CANDIDATE` only) | install first (`Letflow.Modules.Installs`, as `modules_test.exs` does around line 157), because the D5 install gate answers 404 before any permission is evaluated; the 403 comes from the module router's own `Authorize` |
| 7 | Instances (`/instances`) | `POST /` | `:InstancesStart` | also `POST /:id/cancel` 403 |
| 8 | Definitions (`/definitions`) | `POST /` | `:DefinitionsCreate` to `:DefinitionsWrite` | also `POST /:process_key/rollback` 403 (`:DefinitionsRollback`) |
| 9 | Tasks (`/tasks`) | `POST /:id/complete` | `:TasksComplete` | also `POST /:id/claim` (maps to `:TasksComplete`), `POST /:id/assign` 403 |
| 10 | Promotions (`/promotions`) | `POST /` | `:PromotionsManage` | positive control in the same test: `GET /` 200 |
| 11 | Onboarding (`/onboarding`) | `POST /` | `:TenantsManage` (platform) | |
| 12 | SolutionPacks (`/solution-packs`) | `POST /install` | `:DefinitionsCreate` to `:DefinitionsWrite` | `POST /export` and `POST /:pack_id/update-review` map to `:DefinitionsRead` (OQ-3) and are NOT 403 |
| 13 | Audit (`/audit`) | no write route: `__authz_routes__/0` holds only `GET /` | | test asserts every route of the router has method `GET`; if a write route is ever added the test fails and forces a named entry |
| 14 | Dlq (`/dlq`) | `POST /:id/retry` | `:DlqReadRetryDiscard` to `:DlqOperate` | `GET /` and `GET /:id` are also 403 (the auditor does not hold `:DlqOperate`; D6 list) |
| 15 | Webhooks (`/webhooks`) | `POST /subscriptions` | `:WebhookSubscriptionsManage` to `:WebhooksManage` | `GET /subscriptions` also 403 |
| 16 | Services (`/services`) | no write route (`GET /` only) | | same read-only assertion as Audit |
| 17 | AdminServices (`/admin/services`) | `POST /` | `:AdminServicesManage` (platform) | |
| 18 | Entities (`/entities`) | `POST /records/:entity_type` | `:EntitiesRecordsWrite` | PLUS the two decision-bearing denials: `POST /records/:entity_type/export` 403 (`:EntitiesRecordsExport`, supervisor decision) and `POST /records/:entity_type/import` 403; also `POST /definitions` 403, `POST /restrictions/import` 403 |
| 19 | PublicReadHandles (`/public-read-handles`) | `POST /` | `:PublicReadHandlesIssue` | |
| 20 | Help (`/help`) | no write route (`GET /resolved` only) | | read-only assertion |
| 21 | PlatformMigrations (`/platform-migrations`) | `POST /rollouts` | `:TenantsManage` (platform) | |
| 22 | EventRetention (`/event-retention`) | `POST /retirements` | `:TenantsManage` (platform) | |
| 23 | Me (`/me`) | no write route (`GET /memberships`, `GET /modules`) | | read-only assertion |

For read-only routers the AC's "403 on one representative write route" cannot be met literally because none exists; the test states that with the `__authz_routes__/0` assertion instead of inventing a route. Unmatched ordinary path on an authorized router (`GET /api/v1/identity/no-such-route`) answers 403, not 404, for the auditor (rule 1a).

### 7.3 Completeness guards (so the table cannot rot)

1. Parse `lib/letflow/plugs/api_pipeline.ex` with the same `forward("/prefix", to: Module)` regular expression `tenant_admin_routes_test.exs` uses; assert the set of mounted router modules equals the set named in the table (23). A router added to the pipeline without a table entry fails the test.
2. For every table row except `Modules`: assert the named `{method, local_path}` is present in `router.__authz_routes__()` and that `Authorization.role_allows?(:TENANT_AUDITOR, Authorization.required_permission(key))` is `false` for the key it resolves to (platform keys through `has_permission_in_scope?` with `platform_tenant?` true as well). A row that names a route the auditor is actually allowed fails the test (cannot "pass" by naming a permitted route).
3. Exhaustive sweep (recommended, cheap): for every route of every mounted `AuthorizedRouter`, derive `permission = required_permission(key)`; if the auditor does not hold it (platform scope evaluated with the flag true) the response is 403; if the auditor holds it the response is not 403 (no 2xx asserted, bodies are not built). The read-class POST routes of OQ-3 appear in the second set, listed as a literal allowlist in the test with the reason.

### 7.4 Other router-level proofs (named tests)

* "an auditor of an INACTIVE tenant is halted by `TenantStatus` with 403 `tenant_inactive`" (no exemption by construction: only `platform_scope?` is exempt; one line, same assertion as the `TENANT_ADMIN` case of REQ-447 AC6).
* "field-level restrictions apply to the auditor like to any other role" (INV-2): with an entity type that has a restricted field and no `user_entity_grants` row for the caller, `POST /entities/query` returns the field redacted/omitted for the auditor exactly as for a `TASK_WORKER` and a `PROCESS_OPERATOR` caller in the same fixture; the three responses are equal on the restricted field. Fixture model: the restriction tests under `test/letflow/routers/entities_test.exs` and `entities_aggregate_test.exs`.
* "the platform tenant's own TENANT_AUDITOR reads an operator-created review naming foreign tenants B and C with `entries == []`, none of B's or C's ids or graph content": this is the moved AC5 tripwire of F14 (section 8).

---

## 8. Test changes forced by the new role (file-by-file, exact)

New files:

* `test/letflow/api/authorization_tenant_auditor_test.exs` (pure, `async: true`, mirror of `authorization_tenant_admin_test.exs`): "roles/0 returns eight atoms ending in TENANT_AUDITOR, the seven existing roles first and unchanged"; AC1 "for every p in `Authorization.permissions/0`, `role_allows?(:TENANT_AUDITOR, p)` is true exactly for the 14 literal atoms of D6 and false for every other core AND Catalog permission" (iterates `permissions/0` as the AC says; asserts `Catalog.role_grants(:TENANT_AUDITOR) == []` so the Catalog half is explained); "refused set is literal: 26 core permissions"; "TENANT_AUDITOR never holds a platform-scope permission with `platform_tenant?` true or false, and `:Unknown`, `:UnmatchedRoute`, `:UnmatchedPlatformPath` are denied"; "`roles_from_strings` parses TENANT_AUDITOR exactly; lower-case, padded and hyphenated forms parse to nothing"; "`builtin_role_name?("TENANT_AUDITOR")` is true and `platform_admin_name?` is false"; "`is_task_worker_only?` is false for `TENANT_AUDITOR` and for `TENANT_AUDITOR + TASK_WORKER`, true for `TASK_WORKER` alone; `evaluate_access(:TasksList)` is `:Allow` with `task_scope :all`" (OQ-1); "`evaluate_access` allows each of the 14 permissions' keys and denies a write key, in and out of the platform tenant" (PLATFORM_ADMIN-style drop does not apply: the auditor is not dropped outside the platform tenant).
* `test/letflow/identity/tenant_auditor_seeding_test.exs` (`DataCase`, model: `tenant_admin_seeding_test.exs`): a provisioned non-platform tenant has a `TENANT_AUDITOR` `:platform_role` binding and `seedable_role_names/1` last element is `TENANT_AUDITOR`; the pinned platform tenant has all eight; `RoleBackfill.run/0` on an ordinary tenant holding exactly the seven pre-REQ-448 names (all but `TENANT_AUDITOR`, the legacy-state fixture of `role_backfill_test.exs` `seed_pre_req447_six_roles!` extended) adds the binding and lists the tenant under `:seeded`; the second run lists it under `:unchanged` and the `groups`, `tenant_role`, `group_members` row counts and every `role_claims_synced_at` are unchanged (idempotency); a `:process_routing_role` named `TENANT_AUDITOR` makes `seed_default_platform_role_groups/1` return `{:error, {:role_name_taken_by_routing_role, "TENANT_AUDITOR"}}` with the row unchanged and `RoleBackfill.run/0` return `{:error, {:backfill_failed, tenant_id, {:role_name_taken_by_routing_role, "TENANT_AUDITOR"}}}`; the realm assertions of section 5.
* `test/letflow/api/roles_matrix_parity_test.exs` (section 6).
* `test/letflow/routers/tenant_auditor_routes_test.exs` (section 7).

Existing tests that fail or become wrong and must be edited (all prose/number/row additions, none weakens an assertion):

| File | Edit |
|---|---|
| `test/letflow/api/authorization_test.exs` | `roles/0` list (:22-31) gains `:TENANT_AUDITOR`; every regression grid that has a `TENANT_ADMIN` row gains a `TENANT_AUDITOR` row of hand-transcribed expected values (the 13 listed core atoms intersected with each grid's permission set; `:MyModulesRead` where the grid has it); pair-count tests and their titles move from "7 roles" to "8 roles" (:781 133 to 152, :1171 161 to 184, :1838 168 to 192, :2232 224 to 256; the "28 pairs" new-permission grid at ~:655 becomes 32); `:FixtureRead` and `:ModulesManage` tests (:1921-1948) expect `TENANT_AUDITOR` denied; the REQ-318 test at :1728 expects `TENANT_AUDITOR` denied the three export/import atoms. Find sites with `grep -n "TENANT_ADMIN"`. |
| `test/letflow/api/authorization_tenant_admin_test.exs:21-35` | "returns seven atoms ending in TENANT_ADMIN" becomes: eight atoms, `TENANT_ADMIN` seventh, `TENANT_AUDITOR` last, first six unchanged |
| `test/letflow/api/platform_admin_role_binding_test.exs:80-89` | add `TENANT_AUDITOR` to the literal list; `length(Authorization.roles()) == 8` |
| `test/letflow/api/platform_scope_authorization_test.exs` | ~:120-150 holders of `:PromotionsRead` add `:TENANT_AUDITOR` (only that permission; the other `@new_permissions` stay `[:PLATFORM_ADMIN, :TENANT_ADMIN]`); ~:272-292 "tenant keys" test splits `:PromotionsRead` (allowed also for `TENANT_AUDITOR`) from the other three keys |
| `test/letflow/identity/tenant_admin_seeding_test.exs:297-302` | realm-role test: 8 names, last `TENANT_AUDITOR`, still contains `TENANT_ADMIN`; `@all_names` and `@non_platform_names` should be derived from `roles/0` if they are literals |
| `test/letflow/identity/role_backfill_test.exs:478-530` | counts: legacy ordinary tenant `length(names) == 7` becomes 8 (the legacy `PLATFORM_ADMIN` row, six old, plus `TENANT_ADMIN` and `TENANT_AUDITOR`); empty ordinary tenant 6 becomes 7; the "exactly its seedable set is unchanged" test: ordinary 7, platform 8; titles say "seven/eight". Prefer assertions derived from `RoleRegistry.seedable_role_names/1` over new literals. |
| `test/letflow/role_registry_test.exs:660-690` | `length(roles) == 6` becomes 7 and the two `Repo.aggregate` counts 6 become 7; titles |
| `test/letflow/tenant_onboarding_test.exs:266-275, :318-330` | `length(rows) == 6` becomes 7 (derive from `seedable_role_names/1`) |
| `test/letflow/routers/identity_roles_guard_test.exs:6-15, :139` | prose "all seven" becomes eight; if the loops are derived from `roles/0` nothing else; add `TENANT_AUDITOR` to the "PROCESS_DESIGNER cannot bind" matrix if it is a literal list |
| `test/letflow/routers/promotion_context_entries_scope_test.exs` "AC5" (~:360-420) | MOVE `["TENANT_AUDITOR"]` out of the 403 list (`non_admin_core_roles_in_the_platform_tenant_are_denied_promotions_read`); add a test beside "tenant_admin_of_the_platform_tenant_reads_a_foreign_review_without_entries" for `["TENANT_AUDITOR"]`: status 200, `serialised_plan.entries == []`, no B or C marker, keys within `@allowlisted`, with and without the pin; update the comment that says TENANT_AUDITOR "still resolves to no role". Overlap note: Q-1011 may touch the same file; the edit is confined to the AC5 describe. |
| other promotion suites | grep `PromotionsRead` together with a role list in `promotion_scope_test.exs`, `promotion_platform_events_shaping_test.exs`, `req077_promotion_pipeline_test.exs`, `tenant_settings_scope_test.exs`: any list of "roles denied PromotionsRead" that iterates `roles/0` must exclude the auditor; literal lists naming `TENANT_AUDITOR` as denied (none found besides AC5) move to the allowed side |
| loops over `Authorization.roles()` expecting a denial for "every role but TENANT_ADMIN/PLATFORM_ADMIN" (`tenant_modules_test.exs:66`, `tenant_modules_settings_test.exs:151`, `tenant_solutions_test.exs:61`, `me_test.exs:176-190`, `modules_test.exs:157-190`, `req442_tenants_mode_test.exs:260`, `bilimbaga_solution_e2e_test.exs:405`, `platform_scope_*`) | no edit expected: they derive from `roles/0` and the auditor is denied there; they become extra coverage. The implementer runs them and edits only a failing one, with a comment citing this design. |

---

## 9. BUILD item 5 -- places that say six, seven, or enumerate the roles

Found by grep over `lib`, `test`, `docs`, `priv`, `web/src`, `README.md`, `CLAUDE.md`, `scripts`, `.claude` (historical records `docs/migration/**`, `docs/issues/**`, `docs/status/**`, run reports, `test/specs/**` and `lib/letflow/design/**` are history and are not edited).

Prose edits in `lib/` (docs and comments only; no behaviour):

| File:line | Current text | New |
|---|---|---|
| `lib/letflow/api/authorization.ex:9-15` | heading "Seven roles (REQ-447)", `role/0` has seven members | "Eight roles (REQ-448)", names `TENANT_AUDITOR` and its closed explicit list; points to `docs/roles.md` and the parity test |
| `authorization.ex:454` | `@doc "All seven Role values ..."` | eight; names `TENANT_AUDITOR` (read-only, 14 permissions) |
| `authorization.ex:184` | quotes design "granted to all six roles" | historical quotation of REQ-366's design; leave, and add `TENANT_AUDITOR` to the list of holders in the deviation sentence that follows |
| `lib/letflow/identity/role_backfill.ex:97` | "seven roles, PLATFORM_ADMIN only in the platform tenant" | "eight roles ... seven elsewhere" |
| `lib/letflow/identity/role_registry.ex:81, 90, 151, 172-176` | "seven literal strings / seven recognized literals / all seven roles"; collision paragraph names `TENANT_ADMIN` only | eight / seven elsewhere; collision paragraph names both names |
| `lib/letflow/identity/tenant_role.ex:39` | "of the seven recognized literals" | eight |
| `lib/letflow/identity_migration.ex:245` | "six recognized literals" (historical ISS-0774 comment) | "the recognized literals (`roles/0`)" |
| `lib/letflow/routers/identity.ex:~60-90` | "seven recognized literals" | eight |
| `lib/letflow/tenant_onboarding.ex:132` | "all seven roles ... so every tenant gets a TENANT_ADMIN binding" | eight / seven; names `TENANT_AUDITOR` |
| `lib/mix/tasks/letflow.backfill_platform_roles.ex:6` and `letflow.seed.ex:20` | "seven roles in the platform tenant, six elsewhere" | eight / seven |
| holders/non-holders enumerations in router moduledocs | `routers/audit.ex:108` (add `TENANT_AUDITOR` to holders of `:AuditRead`), `dlq.ex:39` (non-holders), `webhooks.ex:78` (non-holders), `help.ex:78` and `me.ex:~30-45` (holders of `:HelpRead` / `:MembershipsRead`: add `TENANT_ADMIN` and `TENANT_AUDITOR` if missing), `services.ex:44` ("held by every role except AGENT_RUNNER": CANDIDATE is also excluded; leave the existing wording unless wrong, add nothing false), `instances.ex:280` (attachments holders) | re-grep `AGENT_RUNNER` under `lib/letflow/routers` and `lib/letflow/api`; make each enumeration complete for eight |
| `lib/letflow/plugs/tenant_status.ex` moduledoc | names `TENANT_ADMIN` as having no exemption | add `TENANT_AUDITOR` to that sentence (no code change) |

Test prose that says "six"/"seven" and is not covered by the failing-test list of section 8: `authorization_test.exs:2121` ("six roles: 192 pairs"), `authorization_role_realm_test.exs:14, 67` ("five roles", a stale moduledoc and failure message of a file the AC says must pass WITHOUT edits: leave it untouched, not part of this change), `me_test.exs:163-168` ("all six roles" title), `tasks_test.exs:149`, `role_registry_test.exs:477-503`, `iss0778_platform_role_seeding_e2e_test.exs:215-277`, `identity_test.exs:1466`. Edit titles/comments only where they are in a file already edited; the rest are optional comment hygiene and must not be mixed into the PR if they would touch a file Q-1011 or another in-flight branch owns.

Docs: `docs/roles.md` (section 6.5), and `docs/migration/decisions/0046-admin-scopes-and-role-charter.md` gets ONE appended section "Closure of the TENANT_AUDITOR role (REQ-448 / Q-965), <UTC date>" in the style of the existing closure sections (no earlier text changed): the role shipped, grant list equals D6, `PromotionsRead` binding condition status (section 3 of this design), the `PlatformServicesManage` row added to the matrix, the parity test location. Not edited: decision 0013 (superseded by 0046 already), `docs/requirements.yaml` (status flip and history are DOC-UPDATER's after RELEASE-VALIDATOR), `web/**` (REQ-450 owns every web role literal; `web/tests/guards/role-set.spec.ts` is one-directional and keeps passing; `web/src/modules/types.ts` `ModuleRole` union is REQ-450's).

---

## 10. File-by-file change list for ELIXIR-DEV

Order matters in one place: the `authorization.ex` change and the realm file change land in the SAME commit (otherwise `authorization_role_realm_test.exs` fails).

Production code:

1. `lib/letflow/api/authorization.ex`: `@roles` (+`:TENANT_AUDITOR` last), `role()` type, `role_from_string("TENANT_AUDITOR")`, `core_role_allows?(:TENANT_AUDITOR, p)` explicit 13-atom list, `is_task_worker_only?/1` (+ `not has_role?(roles, :TENANT_AUDITOR)`, OQ-1), moduledoc/`@doc` prose (section 9). Nothing else.
2. `lib/letflow/identity/role_registry.ex`: generalise the name-collision guard to `TENANT_ADMIN` and `TENANT_AUDITOR` (section 4.2); doc prose.
3. `lib/letflow/identity/role_backfill.ex`, `lib/letflow/tenant_onboarding.ex`, `lib/letflow/identity/tenant_role.ex`, `lib/letflow/identity_migration.ex`, `lib/letflow/routers/identity.ex`, `lib/mix/tasks/letflow.backfill_platform_roles.ex`, `lib/mix/tasks/letflow.seed.ex`, the router moduledocs and `plugs/tenant_status.ex` of section 9: prose only.
4. NOT touched: `lib/letflow/routers/promotions.ex` (Q-1011), `lib/letflow/identity.ex` (derives from `roles/0`), `Letflow.Identity.TenantAdminMigration`, `Letflow.PlatformTenant`, `Letflow.Plugs.*`, any file under `priv/repo/migrations/`.

Data and docs:

5. `priv/keycloak/realms/bpm-default.json` (section 5).
6. `docs/roles.md`: add the `PlatformServicesManage` row, reword the "planned"/"TARGET" sentences and the auditor "Does" line (section 6.5). Keep the single fenced block and the header line exactly as the parser contract states.
7. `docs/migration/decisions/0046-...md`: appended closure section (section 9).

Tests (section 8): the four new files and the edits to the listed existing files.

Verification the run report must quote (AC6): `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test` (full), `mix letflow.check_boundaries`, plus the on-disk one-cell-flip demonstration of section 6.4, plus (QA, after deploy) the `RoleBackfill.run()` `seeded` count and the second-run `unchanged` count. Gates: CODE-DESIGN-VALIDATOR on this file; SECURITY-REVIEWER MANDATORY (role grant, tenant-data read path, INV-1, INV-2, INV-5, INV-10); REVIEWER; TEST-DESIGNER and TEST-DESIGN-VALIDATOR; TEST-RUNNER; RELEASE-VALIDATOR; DOC-UPDATER flips REQ-448 only after RELEASE-VALIDATOR.

---

## 11. Invariants

* INV-A: `role_allows?(:TENANT_AUDITOR, p)` is true iff `p` is one of the 14 atoms of 0046 D6 (13 explicit plus `:MyModulesRead`) or a registered module manifest names `:TENANT_AUDITOR` for `p`. It is never true for a platform-scope permission, `:Unknown`, or any `*Write`, `*Manage`, `*Export*`, `*Import`, token, user, role, module or settings permission.
* INV-B (D7): no other role gains or loses any grant. The only existing-role behaviour touched by this requirement is none (the `is_task_worker_only?` extension widens only the auditor's own listing scope).
* INV-C (INV-10): the auditor is never platform scope, in or out of the platform tenant; `PLATFORM_ADMIN` handling is unchanged.
* INV-D (INV-1): every auditor read is scoped by the caller's own tenant prefix from `scoped_opts`; no request value selects a tenant. No new data-access path is added.
* INV-E (INV-2): no role-based bypass of field-level restrictions (F11); the auditor receives the same redaction as any other role without a grant.
* INV-F (INV-5): a denied auditor request is the same fixed 403 body as for every role; unmatched paths are 403, not 404.
* INV-G: the deactivated-tenant gate has no exemption for the auditor.
* INV-H: the seed and backfill are idempotent, never delete a binding, never write `group_members`, and never overwrite a `:process_routing_role` row.
* INV-I: the matrix in `docs/roles.md` equals the code for every core permission, every role and the scope column, enforced by the parity test on every `mix test`.

---

## Open questions for the supervisor (each with a recommended default; nothing here is silently decided)

Role-semantics questions (beyond the already-decided `:EntitiesRecordsExport`):

* OQ-1. Auditor who also holds `TASK_WORKER`: should `GET /tasks` and `GET /tasks/inbox` be unfiltered (all tenant tasks) or row-filtered to the caller's own tasks? REQ-448 text only covers the auditor alone. RECOMMENDED DEFAULT: unfiltered, by adding `TENANT_AUDITOR` to the `is_task_worker_only?/1` exclusion list, as `req447-tenant-admin-role.md` section 3.1 announced. It grants no new permission (the auditor already holds `:TasksRead`); the alternative would give an auditor who is also a worker a silently narrower view than an auditor alone.
* OQ-2. Sequencing of `:PromotionsRead` for the auditor against Q-1011 / GH #2311 / ISS-1029 (stored-tenant check on `GET /promotions`, `/:id`, `/:id/context` is not merged). 0046 and `docs/roles.md` already print the cell as `yes` and `TENANT_ADMIN` already holds it with the same residual. RECOMMENDED DEFAULT: grant now (no gate on Q-1011), with the moved AC5 tripwire proving `entries == []` and no foreign ids for the platform tenant's auditor, and record in the run report that Q-1011 closes the residual for both roles. If you prefer to gate: the only change is removing `:PromotionsRead` from the auditor list and flipping one matrix cell, which the parity test then enforces.
* OQ-3. POST routes whose permission is a READ permission, which the auditor therefore can call: `POST /definitions/:id/validate`, `POST /solution-packs/export`, `POST /solution-packs/:pack_id/update-review` (all `:DefinitionsRead`), `POST /instances/:id/attachments/:attachment_id/link` (`:AttachmentsRead`; `AttachmentLinks.issue/2` can lazily write a per-tenant signing secret, `{:secret_write_failed, _}` is one of its results), `POST /entities/query` and `/entities/query/aggregate` (the AC itself requires 200). RECOMMENDED DEFAULT: allowed. They are read-class by their permission (the matrix, not the HTTP verb, is the contract), none mutates business data, and denying them would need new permissions or a router-level verb rule that D6 does not state. The route test lists them as an explicit allowlist so a change is visible.
* OQ-4. `docs/roles.md` role-section line "Does: ... promotions reads once the ownership proof exists" and the matrix prose are reworded (section 6.5). RECOMMENDED DEFAULT: as designed; flagged because the charter is the ratified user-facing text.

Operational (not role semantics):

* OQ-5. `promo-reader-uat` (QA realm `bilimbaga`) was set to `TENANT_ADMIN` by REQ-447 OQ-9 pending REQ-448 and T-0169. RECOMMENDED DEFAULT: REQ-448 changes no realm user outside `bpm-default`; retargeting that account to `TENANT_AUDITOR` is an infra/UAT decision after this merges.
* OQ-6. The backfill (a) resets `role_claims_synced_at` for every user of every tenant once, and (b) halts on the first failing tenant. Both are existing behaviours of `RoleBackfill` (ISS-0910, ISS-0886) that REQ-447 accepted. RECOMMENDED DEFAULT: accept both unchanged; the collision guard widened to two names (not all eight) so the legacy six names keep their current behaviour.
* OQ-7. Infra contract for tenant realms (define the `TENANT_AUDITOR` realm role, optional user assignment): no new design file is written by this task (single-file scope). RECOMMENDED DEFAULT: the implementer puts the contract of section 5 in the PR description and the run report; ORCH forwards it to infra.

## Overlap with Q-1011 (files owned elsewhere)

| File | Owner | REQ-448 touches it? |
|---|---|---|
| `lib/letflow/routers/promotions.ex` (read handlers `handle_context`, get, list) | Q-1011 / ISS-1029 | NO |
| `test/letflow/routers/promotion_context_entries_scope_test.exs` | Q-1011 likely adds tests here | YES, only the "AC5" describe (forced: it fails the moment the grant lands). Whoever merges second rebases; no logic overlap. |
| `test/letflow/routers/promotion_scope_test.exs`, `promotion_platform_events_shaping_test.exs` | Q-1011 | only if a role-list there fails after the change (section 8 last rows) |

If Q-1011 merges first, the AC5 edit is unchanged except that the auditor's `GET /promotions/:id` and list also become subject to the stored-tenant check, which the new route test (200 on `GET /promotions` for an empty tenant) is not affected by.
