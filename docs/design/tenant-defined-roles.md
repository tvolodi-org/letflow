# Tenant-defined roles (design note)

Task T-1846. Owner model (PM D-129): one preinstalled role, platform admin; the owner side creates the tenant admin; the tenant admin creates every other role of the tenant and picks its permissions from the list the modules declare.
Design note only: no code, no migration, nothing on QA, production, demo, secrets, DNS, the public repository or money is changed. MES work is not touched.

Legend: **V** = verified by reading the file on this branch (merged with origin/main at `2ae0eb23e`, 2026-11-13); the commands are in section 9. **G** = guess or proposal. **D** = an item that was open when this note was written; every D item is now settled or placed in section 10.

> **Decided (T-1851): decision record `docs/migration/decisions/0088-permission-only-access-tenant-defined-roles.md` is ACCEPTED
> (D-131, corrected by D-132, 2026-11-13).** Permission-only checks and roles as data are decided. The **open build** ships the
> ready-made roles as read-only template rows (the tenant admin assigns users, cannot create or edit roles); creating, copying,
> editing and replacing roles (the editor described in this note) is the **closed** role editor package behind a socket (D-126).
> Sections 2 to 6 describe that editor; section 7 and section 10 are updated below.

## 0. Short answer

| Question | Answer |
|---|---|
| Can a tenant admin define roles and pick permissions? | Yes in the corporate build, through the closed role editor; the open build ships read-only template rows (0088 D10). The code already decides access by **permission**, through `role_allows?/2` in `lib/letflow/api/authorization.ex` (V). What is closed is the **list of role names** (nine atoms) and the mapping role to permissions, which is compiled in. Both become data. |
| Is the operator's list of role-name sites complete? | No. It is right on every item it names (V), but it misses about ten more sites, among them the task-worker scope grants (`tasks.ex`, `routers/tasks.ex`, `scoped_approvers.ex`), `is_task_worker_only?/1`, the reassign rule in `tasks.ex`, the token mint rules and the tenant-admin guard (section 1). |
| What already exists that we build on? | A per-tenant table `tenant_role` that binds a role **name** to a **group** (kinds `platform_role` and `process_routing_role`); users get role strings from group membership; scope grants (`role_scope_grants`) are keyed by role name (V). A tenant-defined role is a new kind of row on top of this, not a new assignment mechanism. |
| Does "stockmanager replaces storekeeper" work? | Yes, once three STOREKEEPER-named sites are made permission-based (section 2.5) and the nine become template rows. Stock, assets, counts and imports then follow the permission set, not the name. |
| Biggest risks | (1) Privilege escalation through role editing; (2) the last tenant admin; (3) the golden permission matrix and about 576 test files that name TENANT_ADMIN (V count, section 5); (4) tasks routing and scoped grants that key on role names. |
| Size | Seven slices, one at a time on the shared files, about L in total (section 6). Security review is mandatory on every slice that touches the access decision. |

## 1. Inventory of every role-name site (V)

"Today" is what the site guards. "Becomes" is the permission-based or key-based form. The list is exhaustive for `lib/`, `web/src` and the check tasks as far as the greps in section 9 reach; a site that only names a role in a comment or a doc string is left out.

### 1.1 The closed table and its parsers

| Site | Today | Becomes |
|---|---|---|
| `authorization.ex` `@roles` / `roles/0` (about line 475), `@type role` (305), `role_from_string/1` clauses (769-777) | The closed list of nine atoms; the text to atom conversion | Stays as the list of **built-in fixed keys** (PLATFORM_ADMIN, TENANT_ADMIN) plus the template keys. A tenant role key is a **string**, never an atom made from input (the moduledoc forbids `String.to_existing_atom`, V). The `role()` type gets a second form for tenant keys. |
| `roles_from_strings/1` (705), `effective_roles/2` (724) | Unknown names are dropped (fails closed) | Looks the name up in the tenant's role definitions (loaded once per request, keyed by tenant prefix). Still drops unknown names. PLATFORM_ADMIN is still dropped outside the platform tenant. About 17 callers of `effective_roles/2` (V grep) stay unchanged in shape. |
| `role_allows?/2` and `/3` (1844, 1887) | `core_role_allows?/2` clauses, then `Catalog.role_grants/1`, then the overlay | One lookup: the permission set of the role (built-in fixed rule for PLATFORM_ADMIN and TENANT_ADMIN, stored set for every other role). The overlay and the module-grant fallback disappear for stored roles (section 2). |
| `core_role_allows?/2` clauses for PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, AGENT_RUNNER, CANDIDATE, TENANT_AUDITOR, STOREKEEPER (1905-2074) | The compiled permission lists | Become the **content of the template rows** (section 2.3). TENANT_ADMIN keeps its rule "every tenant-scope permission" (1902); PLATFORM_ADMIN keeps "everything" (1895). |
| `is_task_worker_only?/1` (1567-1574) | True when TASK_WORKER is held and none of five other named roles; decides the task list row filter | Permission-based: "holds `TasksComplete` or `TasksRead` for own tasks only and none of the broad task permissions". Needs a design pass (open point D-3). |
| `platform_admin_name?/1` (746), `builtin_role_name?/1` (759-767) | Guard for `POST /roles`: no tenant role may carry a built-in name | Reserved-name check against the fixed keys and the template keys of the tenant; used by the new role create route as well. |
| `permission_scope/1` (649) | `:platform` or `:tenant` per atom; unknown atoms are `:platform` | Unchanged. It is the gate that keeps platform permissions out of tenant roles (section 3). |

### 1.2 Direct role-name checks outside the table (the operator's list plus what it missed)

| Site (file:line) | What it guards | How it becomes permission-based | In operator's list? |
|---|---|---|---|
| `authorization.ex:1519, 1524, 1787` and `scope.ex:280` | The platform route family and platform-scope permissions need PLATFORM_ADMIN **and** the platform tenant | Stays. PLATFORM_ADMIN is the one preinstalled, fixed role (owner model). | yes (catch-all) |
| `platform_tenant.ex:156, 172` | Removes or tests PLATFORM_ADMIN outside the platform tenant | Stays. | yes |
| `scope.ex:494` (`require_interactive_tenant_admin/1`) | Two admin-only routes (tenant scope enforcement, service principal flag): caller holds TENANT_ADMIN tenant-wide, interactive credential | Becomes a permission: a new tenant-scope atom held only by TENANT_ADMIN (working name `TenantAdminActions`, G) that custom roles cannot hold. | yes |
| `tenant_grants.ex:59, 69, 78`, `routers/tenant_role_grants.ex:71`, `authorization.ex:1866` (`grantable/0`) | The per-tenant switch that lets STOREKEEPER read and post assets (D-097) | Replaced by role permission sets: a tenant puts the asset permissions into whatever role it wants. Existing switch values are backfilled (section 4). | yes |
| `routers/entities/record_import.ex:101-111` and `ScopeGate.scope_set_without_role/3` | Import of xlsx lines for module-managed types for STOREKEEPER only; STOREKEEPER's grant must not widen other roles' scoped import | Two permissions instead of one name: the existing `EntitiesRecordsImport` (all types) and a new narrow one for module-managed types (G). The router asks which of the two a role holds; `scope_set_without_role` becomes "scope set from the roles that hold the wide permission". | yes |
| `modules/ledger_registration.ex:405` | Registration of a ledger module is refused if the manifest grants post or reverse to TENANT_AUDITOR or CANDIDATE | Stays as a **manifest lint on template keys** (it runs when the module registers, not per request). Runtime protection is the permission check itself. Optional extra: a "read-only" flag on a role that forbids write-class permissions (D-5). | yes (candidate) |
| `modules/exam/router.ex` (moduledoc at 71-87), `exam.ex:62` `role_grants` CANDIDATE | Exam session permissions are granted to CANDIDATE by the manifest; some are manifest-only for admins | Manifest default grants name the template key CANDIDATE; the CANDIDATE template row carries them. Exam is a closed/held area (decision D-043: not a priority). | yes |
| Module manifests `role_grants` (`stock.ex:323` STOREKEEPER; `exam.ex:62` CANDIDATE; other modules `%{}`) and `Catalog.role_grants/1` (`catalog.ex:464`), `validate_role_grants_known` (`catalog.ex:681`), `validate_widens_grants_entries` (`catalog.ex:820`) | Which nine role atoms get which module permissions; manifest load refuses an unknown role key | Keys stay the template keys; validation checks against the template list, not a global atom list. The grants become the default content of a template row (section 2.4). | yes |
| `tasks.ex:446` (`f1_allowed?/3`), `routers/tasks.ex:182, 245, 314, 353, 561` (`ScopeGate.scope_set_for_role(... "TASK_WORKER")`), `identity/scoped_approvers.ex:40` (`@role "TASK_WORKER"`) | Scoped task rights: a TASK_WORKER grant on a scope node lets a user see and complete tasks of that node | The scope grant is keyed by the **role key**; "task worker" becomes "any role that holds `TasksComplete`". The grant row keeps the role key of the tenant role that was granted, and the check asks the permission of that role. Hardest site after the access decision itself (D-3). | **no** |
| `tasks.ex:836` (`authorize_reassign/3`) | A token carrying TENANT_ADMIN may reassign a ROLE or GROUP task without being in the role | Becomes "the caller holds the tenant admin permission" (same atom as `scope.ex:494`). | **no** |
| `identity.ex:2848, 2916, 2996, 3048` | Token minting: PLATFORM_ADMIN tokens only for oneself, expiring, platform tenant only | Stays (fixed role). | partly (platform_tenant) |
| `identity.ex:2658` (`@issuable_token_roles`), `2886-2896` (`check_roles_held`) | Which role names a token may carry; token roles must be a subset of the issuer's and the target's tenant-wide roles | The issuable set is the tenant's role keys (loaded, not a compile-time list). The subset rule is kept and is the base of the no-escalation rule (section 3). | **no** |
| `identity.ex:1546, 3211`, `identity/tenant_admin_guard.ex:56, 96`, `identity/role_registry.ex:84, 107, 741, 752, 993, 998`, `identity/scoped_grants.ex:34, 123, 164-257, 432`, `identity/pending_admin_grants.ex:58`, `identity/pending_admin_grant.ex:31`, `identity/tenant_admin_migration.ex:66-67` | "Last tenant-wide admin" guard, admin binding lock, pending admin invitation, legacy PLATFORM_ADMIN to TENANT_ADMIN migration, scoped grant parse (`parse_role`: any of the nine except PLATFORM_ADMIN) | Stay: TENANT_ADMIN remains a fixed key. `scoped_grants.ex:123` and `role_scope_grant.ex:58` check the role against the nine; they check the tenant's role keys instead. | **no** |
| `identity/api_token.ex:73`, `identity/platform_admin_tokens.ex:65`, `plugs/tenant_status.ex:9` | Non-expiring platform admin token flag, platform admin token listing, suspended tenant gate | Stay (fixed role). | partly |
| `routers/identity.ex:1282` (`builtin_role_name?` in the `POST /roles` handler), `identity/role_registry.ex:209-230` (`platform_role` binding must be one of the recognized names) | A name bound as `platform_role` must be one of the nine; built-in names need the manage permission | The recognized set becomes "fixed keys plus the tenant's own role definitions". | **no** |
| `api/permission_matrix.ex:48` (`@admin_roles`) and `permission_matrix.ex:210` | Matrix build over all roles; the classification of new atoms (admin-only list) | Matrix is built per **edition** and over the template rows only (section 5). | **no** |
| `routers/me.ex:293, 321` | `GET /me/access`: effective roles and "role-agnostic" permissions (true for every role) | `role_agnostic?` iterates `Authorization.roles()`; it iterates the tenant's role set instead. | **no** |
| `definitions/solution_pack.ex:2189`, `definitions/activator.ex:54` | Solution pack `required_roles` checklist compares with the nine names; activator resolves roles | Compare with the tenant's role keys. | **no** |
| `record_triggers/runner.ex:222` | A trigger's publisher is checked for `EntitiesRestrictionsManage` through the roles of the publisher | Works unchanged once `roles_from_strings/1` knows tenant roles. | **no** |
| `scheduler/scheduled_job_sweep.ex:181`, `ledger/authority.ex:52`, `routers/entities.ex:1848`, `routers/instances.ex:971`, `routers/webhooks.ex:239`, `routers/script_rules.ex:418`, `routers/solution_packs.ex:368`, `routers/tenant_config_bundle.ex:118`, `routers/tenant_modules.ex:114`, `modules/procurement/router.ex:382`, `plugs/authorize.ex:142` | Callers of `effective_roles/2` that then ask a permission | Unchanged in shape; they receive the new resolution. They are the reason the resolution must stay one shared function. | partly |
| `mix letflow.check_uat_scenario_schema` (`known_role_names/0`, lines 524, 728, 779) | UAT scenario actors must use known built-in role names | Reads the template keys plus the roster's custom roles (section 5). | **no** |
| Web: `web/src/auth/access/roles.ts` (`ROLES`), `roleLabels.ts`, `fixtures.ts`, `pages/admin/GroupsPage.tsx:153`, `dev/harness/navRoleAccess.ts`; `access.ts:26` (`CANDIDATE` check) | Role list, labels, one candidate-only screen switch, the groups page marks the TENANT_ADMIN binding | `ROLES` becomes the server's list (`GET` of the tenant's roles); labels come from the role record; `access.ts:26` becomes a permission or a flag. Role names stay allowed only inside `web/src/auth/access` (guard `no-role-literals`, V comment in `roles.ts`). | yes (partly) |

Everything else in `lib/` that matches "TENANT_ADMIN" or "PLATFORM_ADMIN" in the grep is a comment, a design record or a doc string (classified, not listed).

## 2. Data model (proposal, G)

### 2.1 Principles

1. **Permission is the only thing that decides access.** A role is a named bundle of permissions inside one tenant. (Already how `role_allows?/2` is used; V.)
2. **Two fixed roles, everything else data.** PLATFORM_ADMIN (platform tenant only) and TENANT_ADMIN (the owner side creates it, the tenant admin cannot weaken it). The other seven become **starter templates**.
3. **Tenant isolation is by schema prefix** like every tenant table (INV-1; decision 0006 D2): the role tables live in each tenant schema; no `tenant_id` filtering as the only guard.
4. **Group membership stays the assignment mechanism.** A user holds a role by being in a group bound to that role (`tenant_role` kind `platform_role` today; V `identity.ex:1367`).

### 2.2 Tables (working names)

| Table (per tenant schema) | Columns in words | Notes |
|---|---|---|
| `role_definition` | id; key (string, unique per tenant, same format rules as today's role name, max 128 codepoints, no control characters); display name; origin (`fixed`, `template_copy`, `custom`); template_key (the template this role was copied from, or none); protected flag; retired time; created and changed time and actor | `fixed` rows: TENANT_ADMIN only (PLATFORM_ADMIN exists only in the platform tenant's schema). `protected` rows cannot be deleted or edited. |
| `role_permission` | role id; permission (string); granted time and actor | One row per permission. The permission must exist in the catalogue (2.4) and be tenant scope. |
| `tenant_role` (exists) | name, group, kind | A `platform_role` row's name must match an active `role_definition.key`. Kind `process_routing_role` is unchanged (names for routing tasks, not permissions). |
| `role_scope_grants` (exists) | principal, role (string), scope node, tenant-wide flag | Role value must match a `role_definition.key`; today it is checked against the nine names (V `role_scope_grant.ex:58`). |

A cached, versioned read ("roles of tenant X, version N") answers `effective_roles/2` and `role_allows?/3`; a role change bumps the version in the same transaction (G; cache design is slice 2).

### 2.3 The nine become starter templates

| Built-in today | Becomes | Editable by tenant? |
|---|---|---|
| PLATFORM_ADMIN | Fixed, platform tenant only | No |
| TENANT_ADMIN | Fixed, created by the owner side (provisioning, onboarding admin grant; V `pending_admin_grants.ex`) | No |
| PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, AGENT_RUNNER, CANDIDATE, TENANT_AUDITOR, STOREKEEPER | Template rows: a copy of each is written per tenant by the backfill (section 4) with the same key and the same permission set as the compiled rule today | Yes: the tenant may edit the row, copy it under a new key, or retire it. |

A **template** is a list shipped with the platform (core permissions from the `core_role_allows?` clauses, module permissions from `role_grants`). It lives in the code as defaults and is copied into the tenant's tables; the tenant's rows are the only live truth for decisions.

### 2.4 How modules declare permissions and default grants

| Today (V) | New |
|---|---|
| A module manifest declares `permissions:` and `role_grants:` keyed by the nine atoms (`module.ex:73`) | `permissions:` stays: it is the **catalogue** the tenant admin picks from (`Catalog.permissions/0` already exists, V `authorization.ex:655`). Each permission gets a short label and a flag: assignable to tenant roles (yes) or held only by TENANT_ADMIN (for example `AssetsReverse`, `AssetsReconcile`, `AssetsCardWrite`, which D-097 keeps administrator-only; V `authorization.ex:1862-1866`). |
| `role_grants:` gives permissions to a built-in role at install | `role_grants:` stays and means **default grants of a template key**. On install it writes into the tenant's template row of that key; it never touches a role the tenant copied or renamed (decision D-2: no silent widening). The role editor shows "new permissions available from module X" for copies. |
| A manifest naming a role that is not one of the nine is refused (`catalog.ex:681`) | Refused unless it names a template key. Modules cannot create roles (decision 0046 D10 stays: a module cannot create a role). |

### 2.5 "Stockmanager replaces storekeeper", step by step

Test case from the owner: a tenant does not use `storekeeper`, creates `stockmanager` with the same permissions, replaces storekeeper, everything works as if nothing changed.

| Step | What happens | What proves it |
|---|---|---|
| 1 | Tenant admin copies the STOREKEEPER template row under key `stockmanager`; permissions copied one by one. The admin may only copy permissions the admin holds (section 3). | Role create test; audit entry with before and after. |
| 2 | Tenant admin binds `stockmanager` to the group that held `storekeeper`, then retires `storekeeper` (the template row stays hidden, not deleted). | Group binding test. |
| 3 | **Stock** (`StockRead`, `StockPost`, `StockReverse`, `StockCountOrder`, `StockCountRecord`): routes ask the permission through `role_allows?` (V `stock.ex` route policies), so the new role passes. | Existing stock route tests run twice: once with the template role, once with `stockmanager`. |
| 4 | **Assets**: `AssetsRead`, `AssetsPost` are in the role's set; the D-097 switch is gone, the backfill copied its value into the template row (section 4). `AssetsReverse` and the others stay admin-only. | Asset route tests with `stockmanager`. |
| 5 | **Counts**: count orders and records are `StockCountOrder` and `StockCountRecord`; the count approval tasks are routed to a **routing role name**. A routing role named `storekeeper` is a `process_routing_role` row (a name bound to a group) and does not change; the tenant renames or re-points it in `tenant_role` (V kind exists). The task completion check uses the permission `TasksComplete` plus the routing role (V `tasks.ex` claim and completion checks, separate from the scope grants). | Count flow test with `stockmanager` as the counter and as the approver. |
| 6 | **Imports**: the new narrow import permission (section 1.2) is in the copied set; the import router asks the permission, not the name. | Import test for `stock_opening_line` with `stockmanager`, and a refusal for another type. |
| 7 | **Tasks and routing**: scoped grants `TASK_WORKER` rows keep working (the TASK_WORKER template is unchanged). A scoped grant for `stockmanager` on a scope node is a new row keyed by the new role key; `f1_allowed?` asks whether the role holds `TasksComplete` (D-3). | Scoped task test. |
| 8 | **UAT flows**: the roster (`test/fixtures/uat/actors.yaml`, 30 `builtin_roles` lines, V) has no storekeeper actor (V grep, no match); stock, assets and counts UAT scenarios that use a TENANT_ADMIN or TASK_WORKER actor are unaffected. A new roster actor holding `stockmanager` is added to run the stock scenarios with the replacement (section 5). | UAT scenarios run twice with the two actors; same outcomes. |

## 3. Safety rules

Each rule is a test (named in the slice that builds it). The rules are in force for every write to `role_definition`, `role_permission`, `tenant_role`, `role_scope_grants` and token issue.

| # | Rule | Source or reason |
|---|---|---|
| S1 | PLATFORM_ADMIN and TENANT_ADMIN rows are `protected`: cannot be edited, deleted, retired, renamed or copied over. Any create with a key that folds (trim + upper case) to a fixed or template key is refused. | Existing guard logic `builtin_role_name?/1` (V). |
| S2 | A permission of platform scope (`permission_scope/1` is `:platform`, including every unknown atom) can never be in a tenant role; checked on write and again when the set is read (fails closed). | `authorization.ex:649-659`, TENANT_ADMIN clause (V). |
| S3 | **No escalation:** a caller can put a permission into a role only if the caller holds it tenant-wide. A role edit cannot add a permission to a role the caller also holds beyond what the caller holds. | Mirrors the token rule "roles must be a subset of the issuer's" (V `identity.ex:2768-2896`). |
| S4 | Only TENANT_ADMIN (or PLATFORM_ADMIN in the platform tenant) may manage roles; the permission to manage roles is the existing `UsersGroupsRolesManage` or a new one held only by TENANT_ADMIN (D-1). A custom role may not hold the role-management permission (nobody else becomes a role manager). | G; D-1. |
| S5 | **At least one tenant admin always remains.** All existing guards (`last_tenant_wide_admin`, `last_interactive_tenant_wide_admin`, lock A) keep working because TENANT_ADMIN stays a fixed key (V `tenant_admin_guard.ex`). A role edit can never remove it. | V. |
| S6 | Tenant isolation: every query takes the schema prefix; a role id from another tenant is a 404, same as a missing one (INV-5). Cross-tenant negative test for every new route (INV-10). | `security-invariants.md`, skill rules. |
| S7 | Audit: every create, change of permission set, rename, retire, copy, and binding change writes an audit entry in the **same transaction**: who, what, before and after sets, reason (1 to 500 codepoints, like `rebind_role/4`, V). A failed audit rolls the change back. | V `role_registry.ex` pattern; `Audit.append_multi`. |
| S8 | Scope enforcement and stage-2 scoped grants: a scoped grant of a tenant role gives only the role's permissions inside the node; a retired role's grants stop counting. Grants never give platform scope (V comment `req519-...:480`). | Existing decision 0051 D1. |
| S9 | Tokens: mint still requires the roles to be held by issuer and target (V `check_roles_held`); a token's roles are role keys; a retired or edited role is re-read at request time, so a token cannot keep a permission the role lost. | V `identity.ex:2886`. |
| S10 | IdP role-claim sync: a claimed role name matches only `platform_role` bindings of the tenant (V `identity.ex:2105-2125`, ISS-0775 note); the claimed `PLATFORM_ADMIN` is dropped outside the platform tenant. With data roles, a claim naming a **retired** role maps to nothing. | V. |
| S11 | A role in use cannot be deleted: retire (hide, no new bindings) first; delete only when no binding, grant, token or open task routing refers to it. | G; protects tasks and history. |
| S12 | Limits: at most N roles per tenant and M permissions per role (numbers need a source: D-4, not invented here). | G. |

## 4. Migration of existing tenants and QA/demo data (G)

| Topic | Plan |
|---|---|
| No behaviour change | The backfill writes one `role_definition` row per template key and one `role_permission` row per permission **exactly as the compiled rule gives today** for each tenant, including module default grants of the modules installed in that tenant. A test compares, for every tenant fixture, the old `role_allows?/3` answer with the new one for every role and permission; the result must be identical (this is the acceptance test, like the byte-identical golden in T-1842 section 1.5). |
| STOREKEEPER overlay | Tenants whose assets settings hold the D-097 switch (V `tenant_grants.ex`) get those two permissions written into their STOREKEEPER template row. The old setting key is read but no longer written; removal is a later slice (rollback path). |
| Existing bindings | `tenant_role` rows of kind `platform_role` keep their name; each must match a new row (guaranteed by the backfill). Existing scope grants keep their role strings. |
| Order | Backfill first (tables exist, decisions still use the compiled table, the two answers are compared in shadow mode, a log line on any difference); then switch the decision to the stored rows behind a flag (default off, per the project rule for new flags); then remove the compiled lists. |
| New tenants | Created with the template rows by tenant provisioning (same code as the backfill). |
| Announce rule | The operator tells the PM before any backfill that changes real-tenant data; QA and demo are backfilled by the normal deploy only after that announcement. This note does not run anything. |
| Manifest hash and U1-U2 | The module manifest hash includes `role_grants` (to be confirmed by reading `Catalog.manifest_hash`, **not read**, G). Keys stay the template keys, so the hash does not change when the shape is kept. If a field (the assignable flag, labels) is added to the manifest, that is a new manifest version for every module: bump versions once, in one slice, then run `mix letflow.permission_matrix --write` (rule from the skill). Upgrade plan U1-U2 of the MES plan is **not read**; MES work is not touched. |
| Rollback | While the flag is off, nothing reads the new tables: switching back is the flag. After the compiled lists are removed rollback is a database restore from the pre-deploy backup; therefore the removal slice is last and separate. Dropping the tables is not part of the rollback (destroys the audit trail of role changes). |

## 5. What changes in tests, golden files, UAT roster, web lists, seeds

| Area | Today (V) | Change |
|---|---|---|
| Permission matrix golden | `priv/permission_matrix/effective.golden`, header "roles: 9", 791 lines, module versions in the header | The golden lists **fixed and template roles** only; tenant roles are data and never in the golden. Per edition: the role editor is closed and adds no permission (`open-core-sockets.md` section 1.3), so both editions share one golden. A new permission still moves it (`mix letflow.permission_matrix --write`). |
| Parity and pin tests | `roles_matrix_parity_test.exs`, `authorization_tenant_auditor_test.exs` (refused core set), `authorization_test.exs` number words, `permission_matrix_test.exs`; about 576 test files mention TENANT_ADMIN and 38 mention STOREKEEPER (V counts, **classification not done**) | Almost all keep working because the template keys do not change. Tests that call `role_allows?/2` with a hand-built role atom need the stored-role path or a test helper that builds a role set. New tests listed in each slice. |
| UAT roster | `test/fixtures/uat/actors.yaml`; `check_uat_scenario_schema` reads `known_role_names/0` | Add roster actors that hold a **tenant-defined role** (for example `stockmanager` in the stock tenant) and a `builtin_roles` equivalent for custom roles; the schema check reads the tenant's role keys. New scenario group: "tenant-defined roles" (create, edit, no escalation, last admin, replace storekeeper). |
| Web | `web/src/auth/access/roles.ts` (`ROLES`, kept equal to `@roles` by `tests/guards/role-set.spec.ts`), `roleLabels.ts`, `fixtures.ts` | The guard compares the web list with the **fixed and template keys** from the server; a new roles admin page (list, create, copy template, edit permissions with the catalogue, retire) in the admin area; role pickers on the groups page and the token page read the tenant's roles. Screen work needs the shots matrix of the design system skill. |
| Seeds | `mix letflow.seed.exam_fixtures` mints a CANDIDATE token (V `letflow.seed.exam_fixtures.ex:183`); provisioning seeds | Seeds that name a template key keep working (the template rows exist after provisioning). |

## 6. Effort slices (G for sizes; one at a time because the files are shared)

The shared files are `authorization.ex`, `identity.ex`, `catalog.ex`, `permission_matrix`, the golden and `web/src/auth/access`. Two slices must not run in parallel. Each slice is one requirement and one PR.

| # | Slice | Size | Depends on |
|---|---|---|---|
| R1 | Tables and backfill, shadow comparison, no decision change (flag off) | M | none |
| R2 | The decision reads stored rows (flag on in tests): `role_allows?/3`, `effective_roles/2`, cache with version, template defaults, manifests as defaults; golden per template | L (security review) | R1 |
| R3 | Role management routes (create, copy template, edit set, retire), safety rules S1 to S7 and S11, audit, last-admin interaction | L (security review) | R2 |
| R4 | Convert the three STOREKEEPER sites (import, overlay, replace `grantable/0`) and `scope.ex:494`, `tasks.ex:836` to permission-based; D-097 backfill | M | R2 |
| R5 | Scope grants and task-worker logic (`f1_allowed?`, `scope_set_for_role`, `is_task_worker_only?`, `scoped_approvers`) on role keys and permissions | M to L (security review) | R2, D-3 |
| R6 | Tokens, claim sync, solution packs, `me` access, UAT schema check on the new role set | M | R2 |
| R7 | Web roles page, role lists, labels, guard update, UAT roster and scenarios for the replace-storekeeper test | M to L | R3 |

Order: R1, R2, R3, then R4 and R5 one after the other, R6, R7; removal of the compiled lists after the UAT of R7 passes.

## 7. Effect on open core (D-126) and `docs/design/open-core-sockets.md`

Decided by D-132 (0088 D10); `open-core-sockets.md` is updated to match (T-1851).

| Question | Answer |
|---|---|
| What changes in T-1842's assumption A (nine fixed built-ins in the open build, custom roles closed)? | Its outcome stands with a new form: the open build keeps the nine roles, now as data (two protected admin rows and seven read-only template rows), and custom roles stay closed. Section 1.6 of `open-core-sockets.md` ("two roles or nine") is answered: nine rows as data. The test case "stockmanager replaces storekeeper" is a corporate-build case (closed role editor). |
| What is the role socket? | The role editor socket (`open-core-sockets.md` section 1.3): open default "no editor"; the closed package mounts the editor, which writes only through the core role write path. No socket on the access decision. |
| First closed features | 1. The role editor. Then the candidates in `docs/design/open-core-closed-candidates.md` (audit export and retention, several sign-in realms, print template designer, advanced reports); the licence check is a precondition. |

## 8. Effect on the fixed asset count spec (T-1844)

The T-1844 spec is **not on this branch** (no file named T-1844 under `docs/` on origin/main, V grep, section 9), so it was not read and no claim about its text is made. The consequence of this design for it: the **signer of an asset count must be a permission chosen by the tenant**, not a role name. The spec should say "the signer is whoever holds the signing permission of the count (a permission declared by the assets or stock module, assignable to tenant roles)", the tenant admin puts that permission into the role it wants (for example `stockmanager`), and the count never names STOREKEEPER or TENANT_ADMIN. If the spec requires a **second, different** person to sign, that is a rule on the permission holder (a different user), not on a role.

## 9. Verified and not verified

Commands run from the worktree (`git merge origin/main` first; HEAD `2ae0eb23e`):

| Claim | Command (shortened) | Result |
|---|---|---|
| Nine atoms, closed | `grep -nE ':(PLATFORM_ADMIN|...|STOREKEEPER)\b' lib` over `authorization.ex` | `@roles` lines 475-483; `role_from_string/1` 769-777 (V) |
| Decision through `role_allows?/2` | read `authorization.ex` 1825-1900, 2040-2085 | V |
| Unknown role names dropped | read `roles_from_strings/1`, 705-715 | V |
| Direct name sites | `grep -rnE '"(PLATFORM_ADMIN|TENANT_ADMIN|...)"' lib` and the atom form | table in section 1 (V) |
| `scope.ex` 280 and 494; `record_import.ex` 101-111; `ledger_registration.ex` 405; `tenant_grants.ex` 59/69/78 | read the lines | V |
| Manifests `role_grants` | `grep -rn role_grants lib/letflow/modules` | stock STOREKEEPER, exam CANDIDATE, others empty (V) |
| `tenant_role` and group membership | read `tenant_role.ex`, `identity.ex:1367` | V |
| Web | `grep -rnE` over `web/src`, read `roles.ts` | role names only under `auth/access` (V for non-test files) |
| Counts 30, 38, 576 | `grep -c builtin_roles actors.yaml`; `grep -rln STOREKEEPER test`; `grep -rln TENANT_ADMIN test` | file counts, **not classified** |
| T-1844 spec absent | `grep -rn "T-1844" docs` | no hit |

**Sources not read:** the T-1844 spec; `Catalog.manifest_hash` and the MES upgrade plan U1-U2 (so the hash effect in section 4 is a guess); the D-129, D-126 and D-097 texts themselves (taken from the task text and from the code comments that cite them); the contents of the 576 and 38 test files; `docs/roles.md` beyond the statement quoted in `open-core-sockets.md`; the portfolio repository (not reachable from the worktree).

## 10. Decisions on the former open points

| # | Question | Decision |
|---|---|---|
| D-1 | Which permission lets someone manage roles? | The existing `UsersGroupsRolesManage`, non-assignable (0088 D4); the closed editor's routes use it (`open-core-sockets.md` 1.3). |
| D-2 | Do module upgrades widen the roles a tenant copied? | No (0088 D7, O3 a). |
| D-3 | How are scoped task grants and "task worker only" expressed with permissions? | Scoped task work: slice S0-2 of `docs/design/roles-stage0-slices.md` (its security ruling is a reviewer's step). Task list: ruled in `docs/design/storekeeper-task-visibility-ruling.md` (T-1850). |
| D-4 | Limits on roles per tenant and permissions per role | No limits now (0088 O6). Reminder (2026-11-13): a number is needed before the closed role editor is built. |
| D-5 | Read-only flag on a role | Stage 2 of the slice list carries the `read_only` flag; the ledger lint stays on template keys. |
| D-6 | Is anything in the open build limited for a free edition? | Role creation and editing are closed (D-132, 0088 O5); nothing else is limited by this note. |
