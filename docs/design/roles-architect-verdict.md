# Architect verdict: permission-only access with tenant-defined roles

Task T-1848. Owner principle D-129 (as given in the task text; the D-129 record itself is in the portfolio and was not opened):
access is checked against **permissions only, never role names**; no built-in business roles; only the platform admin is
preinstalled; the owner side creates the tenant admin; the tenant admin creates all other roles from the permissions the
modules declare. This is a verdict, not a plan. Docs only: no code, nothing on QA, production, demo, secrets, DNS, the
public repository or money; MES work is not touched. Builds on and checks `docs/design/tenant-defined-roles.md` (T-1846).

Legend: **V** = verified by reading the file on this branch (origin/main `d3c4fc9b7`, 2026-11-13; commands in section E8).
**G** = architect's judgement or guess. **O** = the owner's call (all decided; see "Owner choices").

## VERDICT

**The principle is right for Letflow, and the code is closer to it than it looks.** Every route already asks one
question, "does one of the caller's roles allow permission P" (`evaluate_access/2` and `role_allows?/2` in
`lib/letflow/api/authorization.ex`, V). What is wrong today is not the shape of the check, it is that (a) the roles and
their permission lists are compiled into the code, and (b) about twenty places outside that table ask a role **name**
directly (section E3). Both can be removed. I would do it, with four conditions.

**Condition 1. Names may identify, never decide.** A role key may still *name a row*: the seed that creates the tenant
admin, the pending first-admin grant, the IdP claim that maps to a group, a template a tenant copies. It may never be the
reason a request is allowed or refused. That is the test for every site: "would renaming the role change an access
answer?" If yes, it is a role-name check and must go.

**Condition 2. The two admins are protected rows with a rule, not a name.** Platform admin = "all permissions", honoured
only in the platform tenant. Tenant admin = "every tenant-scope permission", created by provisioning. Both rules must be
*computed*, not stored lists, because modules add permissions later. So a role row carries two flags written only by the
platform: `protected` (cannot be edited, deleted, renamed or copied over) and `grants` = `all` / `all_tenant_scope` /
`listed`. The decision reads the flag, never the name. The platform-tenant condition (INV-10, decision 0046 D2) is a
**tenant** check, not a role check, and stays. Whether the caller signed in interactively or uses an API token is an
**authentication** check and stays too (`require_interactive_tenant_admin/1` keeps its credential test, V).

**Condition 3. Some permissions are not for custom roles.** Platform-scope permissions, role management, the two
admin-only switches (scope enforcement, service principal) and the admin-only asset actions (AssetsReverse,
AssetsReconcile, AssetsCardWrite, decision 0084 D1) carry a flag `assignable: false`. Only a `grants = all...` row has
them. This replaces every "caller holds TENANT_ADMIN" test with a permission and is what stops privilege escalation by
role editing.

**Condition 4. Routing a task to a role is addressing, not access.** "May you complete tasks" is a permission
(`TasksComplete`). "Is this task addressed to you" is a fact about the task, like "is this your record". A routing name
(`tenant_role` kind `process_routing_role`, V) is a label for a group of people; it never grants a permission. That is not
a second kind of access check, and it stays as data.

**The task-worker shortcut: not needed, and the owner is right to doubt it.** The three task-worker sites
(`is_task_worker_only?/1`; the scoped grants keyed `"TASK_WORKER"` in `tasks.ex`, `routers/tasks.ex`,
`scoped_approvers.ex`; V) each become one new permission held by exactly the roles that pass today: "see all tasks, not only
mine" (exact except the storekeeper case, point 4 below) and "work tasks inside a scope I am granted". A "task worker" then is just a starter template with those
permissions. No code path knows the word.

**Where I disagree with T-1846.**
1. *Order.* T-1846 starts with tables and backfill. I would start one step earlier: **replace every role-name site with a
   permission while the nine roles are still compiled in** (stage 0). It needs no table, no data, no flag; it is proven by
   the golden matrix (old rows identical, only new permission rows added) and by the existing tests; rollback is a revert.
   After it, the data model is a change of *where the permission lists live*, nothing else.
2. *TENANT_ADMIN as a "fixed key".* T-1846 keeps the last-admin guard and the pending admin grant keyed by the name
   TENANT_ADMIN. Acceptable only as identification (condition 1); the guard must count holders of the protected
   `all_tenant_scope` row, not holders of a name.
3. *Module grants per tenant.* T-1846 says the backfill copies the grants "of the modules installed in that tenant".
   Today `Catalog.role_grants/1` is global (all compiled modules, no tenant filter; `catalog.ex:464`, V). For no behaviour
   change the backfill copies the global grants; module routes are fenced by the module guard anyway.
4. *One site cannot be converted without a change, and it shows why names are dangerous.* `is_task_worker_only?/1`
   filters the task list only for a TASK_WORKER who holds none of five other named roles. STOREKEEPER (added later) is
   not one of the five and holds `TasksRead`, so a user who is only a storekeeper today sees **every task of the tenant**
   in `GET /tasks`, while a task worker sees only their own (V: `authorization.ex:1553, 1567, 1605`; golden). No set of
   permissions can reproduce that exactly. The permission form ("without the see-all-tasks permission you see only your
   own and your groups' tasks") narrows the storekeeper. I treat today's behaviour as a probable defect; the security
   reviewer rules on it before stage 0 touches this site.
5. *Counts.* "About 594 test files" does not reproduce (792 or 824 by my greps, section E8); the conclusion stands.

**What I would do:** stages 0 to 6 in section E6, one at a time on the shared files, security review on every stage that
touches the decision. Stage 0 first. Before stage 1 one decision record must supersede the "closed role set" records
(0013, 0046 D10, 0081 D1, 0084), because they say the opposite of D-129 (V). Total effort is large (about L to XL, G),
but every stage ships on its own and changes nothing a tenant can see until stage 3, except the
storekeeper task-list narrowing (point 4), which is ruled separately.

## Owner choices (decided: D-131, corrected by D-132, 2026-11-13; recorded in decision 0088)

| # | Question, in business terms | Architect's recommendation (T-1848) | Owner decision |
|---|---|---|---|
| O1 | Existing tenants have seven ready-made roles (storekeeper, task worker, auditor ...). What happens to them? | They stay as ordinary roles the admin may edit or remove | (a) in the corporate build; in the open build they stay as read-only template rows with today's permissions |
| O2 | A new tenant: does it start with no roles except its admin, or with starter roles already created? | Only its admin; templates to copy | (a): only its admin row; open build assigns users to the shipped template rows, corporate build copies templates |
| O3 | When a module update brings a new permission, do the tenant's own roles get it automatically? | Never | (a): never |
| O4 | May the tenant admin let someone else manage roles and users? | No, for now | (a): no |
| O5 | Is "create your own roles" free (open core) or paid (closed)? | Free | **Closed** (D-132): the role editor is the closed package behind a socket; the open build ships read-only template rows |
| O6 | Limits: how many roles per tenant, permissions per role? | None invented | No limits now; a number is needed before the closed role editor is built (reminder, 2026-11-13) |

---

# Evidence

## E1. Is permission-only right? Where it is hard (answer to question 1)

| Area | Today (V) | Hard or wrong? | Verdict |
|---|---|---|---|
| Platform admin "everything" | `core_role_allows?(:PLATFORM_ADMIN, _) -> true`; platform-scope permissions also need `has_role?(roles, :PLATFORM_ADMIN)` and the platform tenant (`has_permission_in_scope?/4`) | Hard only in form: "everything" is a rule, not a list | Protected row with `grants = all`; platform-scope permissions `assignable: false`; platform-tenant condition stays (tenant check) |
| Tenant admin "every tenant-scope permission" | `core_role_allows?(:TENANT_ADMIN, p) -> permission_scope(p) == :tenant`; golden: TENANT_ADMIN true on 84 of 87, false on `ModuleRolloutsManage`, `PlatformServicesManage`, `TenantsManage` | Same: computed from scope metadata | Protected row with `grants = all_tenant_scope`; `permission_scope/1` unchanged, it is the fence |
| Platform vs tenant scope | `permission_scope/1`: unknown atom is `:platform` (fails closed) | Not hard; already permission metadata | Keep exactly |
| Role-agnostic permissions | `role_allows?(_role, :MyModulesRead | :MyAccessRead | :MyPreferencesSet) -> true`; `evaluate_access` allows `:MyAccessRead`, `:MetricsRead` for any caller | Not a role check at all | Keep as "every signed-in member" baseline |
| Task engine routing | `resolve_principal_scope/2` reads `tenant_role` names of the caller's groups (both kinds); claim, complete and reassign compare `assignee_ref in role_names` (`tasks.ex:599, 689, 845`) | Not access; addressing (condition 4) | Stays as data. G: later, keep routing names and permission-role keys in separate namespaces so a rename of a permission role cannot re-route tasks |
| Exam candidate | CANDIDATE holds exactly 9 permissions (6 exam + 3 role-agnostic, golden); exam router checks permissions (`exam/router.ex` moduledoc); web `isCandidate` reads the role name, for a link only (`web/src/auth/access/access.ts:26`) | Easy | Template "candidate"; web link asks `ExamSessionStart` instead |
| Machine credentials | AGENT_RUNNER holds 5 permissions (golden); API tokens carry role names from `@issuable_token_roles` (`identity.ex:2658`), subset of issuer's roles (`check_roles_held`) | Moderate: tokens must carry role keys that are data | Token carries role keys, permissions re-read at request time (a role that loses a permission takes it from its tokens too); subset rule kept |
| Service principal flag | user attribute, not a role (`PUT /users/:id/service-principal`, `docs/roles.md`) | Not a role check | Keep |

**Principle holds with conditions 1 to 4.** I found no site that *must* stay a role-name check.

## E2. Target model (answer to question 2)

| Element | Target |
|---|---|
| Decision | Stays pure: `evaluate_access(ctx, endpoint)`. `AccessContext` gains one explicit input: the caller's resolved permission set (or role key -> permissions map), loaded at the request edge with the caller's own schema prefix. This is exactly the precedent of decision 0084 D2 (the overlay is loaded in `Plugs.Authorize` through `TenantGrants.load_for/2`, V `plugs/authorize.ex`) generalised. |
| Role rows (per tenant schema, INV-1, 0006 D2) | `role_definition`: key (string, never an atom from input), display name, `protected`, `grants` (`all` / `all_tenant_scope` / `listed`), `read_only`, retired time, origin template key. `role_permission`: role, permission (must exist in the catalogue and pass `permission_scope/1 == :tenant` and `assignable`). Working names from T-1846 section 2.2. |
| Preinstalled | Platform tenant: one platform-admin row (`protected`, `grants = all`). Every tenant: one tenant-admin row (`protected`, `grants = all_tenant_scope`) created by provisioning; the first admin is bound by the pending grant (decision 0048, V `pending_admin_grant.ex` default `role_name "TENANT_ADMIN"`: identification, condition 1). |
| Protection without a name check | Row flags written only by platform code (no route can set `protected` or `grants`); permission flag `assignable`; last-admin guard counts interactive tenant-wide holders of a protected `all_tenant_scope` row. |
| The nine | Templates shipped with the code (core lists from today's `core_role_allows?` clauses, module defaults from manifest `role_grants`). Existing tenants: backfilled as ordinary rows with the same keys and the same sets (O1). New tenants: none (O2). The template list replaces `@roles` as "the keys a manifest may name". |
| Scope grants | `role_scope_grants` stay keyed by role key (data). The check becomes "a grant of the caller covering node N names a role whose set holds P" (permission-based; `Scope.allowed_set/2` already works this way for other routes, V `scope.ex:175`). |
| Routing roles | Stay `process_routing_role` rows: a name for a group. Carry no permissions (decision 0081 D1 already says routing roles carry no permissions, V). |
| Module declarations | `permissions:` is the catalogue (with label, `assignable`, write-class marker). `role_grants:` means "default content of template K". Modules still cannot create roles (0046 D10, the part that survives). O3 decides upgrades. |
| Templates vs 0055 D7 | 0081 D2 notes a module `role_grants` widening is refused "until per-tenant grant snapshots exist (0055 D7)". The tenant's role rows **are** those snapshots, so that block is lifted by stage 2 (V 0081 text; 0055 not opened). |

## E3. Every role-name site and what it becomes (answer to question 3)

Sites from the T-1846 inventory, re-checked where marked V. "P" = becomes a permission, "S" = becomes a scope rule on
permissions, "F" = stays as a row flag / tenant check, "I" = stays as identification only.

| Site | Today | Becomes | Kind |
|---|---|---|---|
| `authorization.ex` `@roles` (474), `role_from_string/1`, `roles_from_strings/1` (705) | closed nine atoms (V) | template key list; tenant keys are strings looked up in the loaded rows; unknown dropped (fails closed as now) | I |
| `core_role_allows?/2` clauses (1893-2085) | compiled lists (V) | template content | data |
| `core_role_allows?(:PLATFORM_ADMIN, _)`, `has_role?(roles, :PLATFORM_ADMIN)` in `has_permission_in_scope?/4` and `:UnmatchedPlatformPath`/`:UnmatchedRoute` (V) | catch-all + platform tenant | `grants = all` flag + platform-tenant check; catch-all markers ask "holds a `grants = all` row in the platform tenant" | F |
| `core_role_allows?(:TENANT_ADMIN, p)` (1902, V) | every tenant-scope permission | `grants = all_tenant_scope` flag | F |
| `effective_roles/2`, `PlatformTenant.effective_role_strings` (V) | drop PLATFORM_ADMIN outside platform tenant | drop any `grants = all` row outside the platform tenant (that row exists only there) | F |
| `is_task_worker_only?/1` (1567, V) | TASK_WORKER and none of five names -> own tasks only; STOREKEEPER-only is not filtered (V, see verdict point 4) | permission "see all tasks" (G name `TasksReadAll`) held by the five roles; without it, own and group tasks only. **Not exact**: narrows a storekeeper-only user (security ruling first) | P |
| `f1_allowed?/3` (`tasks.ex:446`), `scope_set_for_role(..., "TASK_WORKER")` (`routers/tasks.ex` 182, 245, 314, 353, 561), `scoped_approvers.ex:40` (V) | a scoped TASK_WORKER grant covers the node; other roles' grants never count (`docs/roles.md` line 86) | permission "work tasks in a granted scope" (G `TasksWorkInScope`) held by TASK_WORKER only; check = a covering grant of a role holding it. Not plain `TasksComplete`: PROCESS_OPERATOR holds that and would start to count (behaviour change) | S |
| `authorize_reassign/3` `"TENANT_ADMIN" in token_roles` (`tasks.ex:836`, V) | admin may take a routed task away | permission (G `TasksReassignRouted`, `assignable: false` or admin-template only) | P |
| `scope.ex:494` `require_interactive_tenant_admin/1` (V) | interactive + `UsersGroupsRolesManage` tenant-wide + TENANT_ADMIN tenant-wide | interactive (kept) + new non-assignable permission (G `TenantSecurityManage`) tenant-wide | P + auth check |
| `scope.ex:280` `:PLATFORM_ADMIN in candidates` (V) | allow basis `:platform` | candidate row has `grants = all` in the platform tenant | F |
| `tenant_grants.ex`, `routers/tenant_role_grants.ex`, `grantable/0` (`authorization.ex:1866`, V) | STOREKEEPER asset overlay (0084) | gone: the tenant puts `AssetsRead`/`AssetsPost` into any role; backfill copies the switch into the storekeeper row; `PUT /tenant/role-grants` retired after stage 3 | data |
| `record_import.ex:101-111`, `ScopeGate.scope_set_without_role/3` (V) | STOREKEEPER-only import limited to module-managed types; its grant must not widen others' scope (0081 D4) | new narrow permission (G `EntitiesRecordsImportManaged`) for module-managed types; the wide `EntitiesRecordsImport` scope set is computed only from roles holding the wide one | P + S |
| `ledger_registration.ex:405` `check_auditor_or_candidate` (V) | manifest may not grant post/reverse to TENANT_AUDITOR or CANDIDATE | registration lint on template rows flagged `read_only` (auditor, candidate); at run time the `read_only` flag refuses write-class permissions on any role | F (lint) |
| Manifests `role_grants` (`stock.ex` STOREKEEPER, `exam.ex` CANDIDATE), `Catalog.role_grants/1` (global, `catalog.ex:464`, V), `validate_role_grants_known` | keyed by the nine | keyed by template keys | I |
| `identity.ex:2658` `@issuable_token_roles`, `check_roles_held` | token role names from the closed list | the tenant's role keys; subset rule kept (anti-escalation) | I |
| `identity.ex` token mint rules for PLATFORM_ADMIN (2848, 2916, 2996, 3048 per T-1846; not re-read) | own, expiring, platform tenant | same, keyed on `grants = all` row | F |
| `tenant_admin_guard.ex` (`@tenant_admin_role "TENANT_ADMIN"`, lock on that `tenant_role` row, V) | last admin, binding lock | the protected `all_tenant_scope` row; lock by row id | F |
| `pending_admin_grant.ex` (`role_name` default `"TENANT_ADMIN"`, V), `pending_admin_grants.ex`, `tenant_admin_migration.ex` | first admin, legacy migration | names the protected row | I |
| `identity.ex` `resolve_group_ids_for_role_names/2` (IdP claims, `kind == :platform_role`, PLATFORM_ADMIN dropped outside platform tenant, V) | claim -> group | unchanged: claim name maps to a group binding of an active role row; retired role maps to nothing | I |
| `routers/identity.ex` `builtin_role_name?`, `role_registry.ex` recognised names, `platform_admin_name?/1` (V for the predicates) | reserved names | reserved = protected rows + template keys + the platform-admin fold | I |
| `api/permission_matrix.ex` `@admin_roles`, golden | matrix over nine | matrix over templates and the two protected rows | data |
| `routers/me.ex` `role_agnostic?` over `Authorization.roles()` (per T-1846) | iterates nine | iterates the tenant's rows | data |
| `solution_pack.ex` `required_roles`, `activator.ex` (per T-1846) | compare with nine | compare with tenant keys | I |
| `exam/router.ex` | permissions already (V) | template | data |
| `check_uat_scenario_schema` `known_role_names/0` (per T-1846) | nine | template keys + roster custom roles | I |
| Web `roles.ts`, `roleLabels.ts`, `fixtures.ts`, `GroupsPage.tsx`, `access.ts:26` `isCandidate` (V for `access.ts`) | role lists and one name test | server list; `isCandidate` -> permission | P (web) |

**No site must stay a pure role-name check.** Two are borderline and I flag them: the ledger lint (it names templates at
registration time; acceptable as a lint on shipped defaults, the run-time guard is the `read_only` flag) and token mint for
the platform admin (a flag on the row, but in practice one row in one tenant).

## E4. The task-worker shortcut (answer to question 4)

Yes, a shortcut written as code ("if the user is a task worker, then ...") is a second kind of check; that is exactly
what `is_task_worker_only?/1` and the `"TASK_WORKER"` scoped grants are today (V). Cleanest alternative: the two
permissions in E3 (`TasksReadAll`, `TasksWorkInScope`, working names, G), compiled into today's roles in stage 0 (every answer unchanged
except the storekeeper-only task list, verdict point 4), and a starter template "task worker" in stage 1. The engine never sees the word.

## E5. Risks and what must be tested (answer to question 5)

| Risk | Control | Test that proves it |
|---|---|---|
| Privilege escalation by editing a role | A permission goes into a role only if the editor holds it tenant-wide; `assignable: false` never; editors need the non-assignable role-management permission (T-1846 S3, S4) | Role edit adding an unheld permission -> refused; adding a non-assignable one -> refused; a custom role cannot gain role management |
| Last admin | Protected `all_tenant_scope` row cannot be edited; guard counts interactive holders (existing guards, re-keyed) | Remove last admin membership -> refused, as today |
| Tenant isolation (INV-1) | Role tables per tenant schema, prefix on every query; loaded with the plug's own prefix as 0084 D2 does | Role id of tenant B from tenant A -> 404 (INV-5) |
| Cross-tenant (INV-10) | Role routes take the tenant from the token, never from input | INV-10 negative test per new route |
| Platform permission leak | `permission_scope/1` checked on write and again on read; `grants = all` only in platform tenant | Stored tenant row naming `TenantsManage` -> grants nothing |
| Behaviour change for existing tenants | Shadow comparison (stage 1): for every tenant fixture, every role, every permission, old answer = new answer | Equality test over the full golden; log line on any difference in shadow mode |
| Audit | Every role write audited in the same transaction (`Audit.append_multi`) | Audit failure rolls the change back |
| Performance | One extra indexed read per request (role keys -> permissions), as the overlay already costs (V `TenantGrants.load_for/2` per request); cache by tenant prefix + version only if measured (G) | Query count test on `Plugs.Authorize` |
| Tokens | Permissions re-read at request time; retired role grants nothing | Token of an edited role loses the removed permission on the next request |
| IdP claims | Claim maps only to active role bindings; PLATFORM_ADMIN claim dropped outside platform tenant (unchanged) | Claim of a retired role -> no membership |
| Scope enforcement `on` | Scoped grants count only for roles holding the permission; IdP sync non-widening unchanged (`docs/roles.md` LIMIT-IDP-SYNC-WHOLE-GROUP) | Existing REQ-518/519 tests run unchanged |

## E6. Staged migration, no behaviour change (answer to question 6)

| Stage | What | Proves | Rollback | Effort (G) |
|---|---|---|---|---|
| 0 (first) | Replace every role-name decision site in E3 marked P/S with a new permission compiled into exactly the roles that pass today: import, F1 scope, reassign, `scope.ex:494`, web `isCandidate`, and last `is_task_worker_only?` (after the security ruling). Several small PRs | Every route answer unchanged (existing route tests green); the golden diff is limited to the new permission rows and, for the import split, the STOREKEEPER `EntitiesRecordsImport` row, each named in the PR. Note: PLATFORM_ADMIN's catch-all makes it hold every new permission, which changes answers only inside the platform tenant (today `scope.ex:494` refuses a platform admin alone); the security reviewer accepts that or the permission is excluded from `grants = all` | revert | M (5 to 7 small PRs, each security-reviewed) |
| 0b | Decision record superseding 0013 (closed set), 0046 D10 (closed set; "modules cannot create roles" survives), 0081 D1, 0084, citing D-129 | Records no longer contradict the code to come | n/a (doc) | S |
| 1 | Tables per tenant schema, backfill = today's compiled answer, shadow comparison, flag default off | Equality over every tenant fixture | flag off; tables unused | M |
| 2 | Decision reads the rows (flag on in tests, then QA after the operator announces it), protected flags, `assignable`, templates as defaults | Same equality, now live | flag off | L (security review) |
| 3 | Role management routes: create, copy template, edit, retire; safety rules; audit | Escalation, last-admin, INV-5/INV-10 tests | routes unmounted by flag | L (security review) |
| 4 | Tokens, IdP claim sync, solution packs, `GET /me/access`, UAT schema check on tenant keys; retire the overlay route | Token/claim tests | revert | M |
| 5 | Web roles page and lists; UAT roster actor with a custom role; "stockmanager replaces storekeeper" scenario (T-1846 section 2.5) | UAT run with template and custom role, same outcomes | revert | M to L |
| 6 | Remove the compiled lists (templates remain as data in code) | Golden over templates only | database restore from pre-deploy backup; therefore last and alone | S to M |

Smallest safe first step: **stage 0, starting with the import site** (`record_import.ex` and
`ScopeGate.scope_set_without_role/3`): split `EntitiesRecordsImport` into the wide permission and a narrow one for
module-managed types, give STOREKEEPER only the narrow one, and the two STOREKEEPER-name tests disappear with identical
answers at the route (0081 D4 tests prove it). Not `is_task_worker_only?/1`: it is the one non-exact site. QA and demo data: unchanged by stages 0 and 1; stage 2 changes nothing visible because
the backfill reproduces today's answers; new tenants without starter roles (O2) affect only tenants created after the
owner's answer, and QA seeds then create their roles explicitly.

## E7. Open core: what is superseded (answer to question 7)

`docs/design/open-core-sockets.md` (T-1842) assumed the open build keeps nine fixed roles and custom roles come from a
closed package (section 1.6 option A, recommended; section 7 question 1; V). This verdict recommended making custom roles part of
the open build; the owner decided otherwise (D-132, O5 closed), and `open-core-sockets.md` is updated to the decision (T-1851):

- Open build: the nine roles become data (two protected admin rows, seven read-only template rows); the tenant admin assigns users
  and cannot create or edit roles.
- Section 1.3: **no socket sits on the access decision** (`role_allows?`, `resolve_roles`); this verdict's point stands. The decision
  is the most security-critical code; a replaceable implementation there is a risk with no business gain. The socket is the **role
  editor socket**: the closed package mounts the editor, which writes only through the core role write path.
- Sections 2 and 3 (build layout, tests per edition, isolation and audit identical) stay.
- For D-126: the role editor is the first closed feature. Further candidates: `docs/design/open-core-closed-candidates.md`.

## E8. Verified vs not verified

Commands run in the worktree (origin/main `d3c4fc9b7`):

| Claim | Command | Result |
|---|---|---|
| 87 permissions, 9 roles, 783 rows | `head priv/permission_matrix/effective.golden`; `grep -v '^#' ... | awk '{print $1}' | sort | uniq -c` | header `permissions: 87`, `rows: 783`; 87 rows per role (V) |
| Allowed counts per role | `awk '$3=="true"{print $1}' | uniq -c` | PLATFORM_ADMIN 87, TENANT_ADMIN 84, PROCESS_OPERATOR 26, PROCESS_DESIGNER 19, TENANT_AUDITOR 16, STOREKEEPER 15, TASK_WORKER 15, CANDIDATE 9, AGENT_RUNNER 5 (V) |
| TENANT_ADMIN refused set | `awk '$1=="TENANT_ADMIN" && $3=="false"'` | ModuleRolloutsManage, PlatformServicesManage, TenantsManage (V) |
| Decision shape | read `authorization.ex` 640-770, 1500-1580, 1780-1905 | as in E1/E3 (V) |
| Overlay precedent | read `plugs/authorize.ex` 125-160; `0084-tenant-storekeeper-asset-grant.md` Decision | V |
| Task sites | `grep -rn 'scope_set_for_role\|scope_set_without_role' lib`; read `tasks.ex` 377-397, 430-455, 815-860; `scope_gate.ex` 110-170 | V |
| `scope.ex` 270-290, 480-520 | read | V |
| Import | read `record_import.ex` 90-125 | V |
| Ledger lint | read `ledger_registration.ex` 395-415 | V |
| IdP claim path | read `identity.ex` 2095-2130 | V |
| Tokens | `grep -n '@issuable_token_roles' lib/letflow/identity.ex` | line 2658, used at 3036 (V) |
| Last admin, pending grant | read `tenant_admin_guard.ex` 45-100, `pending_admin_grant.ex` 25-35 | V |
| `role_grants` global | read `catalog.ex:464-470` | V |
| Exam | read `exam/router.ex` 68-90 | V |
| Web candidate test | read `web/src/auth/access/access.ts` 15-35 | V |
| Decisions | headings of 0013, 0046, 0081, 0084; read 0046 D1-D10, 0081 D1-D5, 0084 Decision | V |
| Test file counts | `grep -rlw <ROLE> test | wc -l` per role; `grep -rlE '<six roles>' test | wc -l`; `grep -rl CANDIDATE test | wc -l` | TENANT_ADMIN 576, TASK_WORKER 342, PLATFORM_ADMIN 331, PROCESS_DESIGNER 181, PROCESS_OPERATOR 145, TENANT_AUDITOR 118, CANDIDATE 92 (91 with `-w`), AGENT_RUNNER 67, STOREKEEPER 38; six-role union 792; nine-role union 824 (V); "594" not reproduced |
| Seeds | `grep -rl TENANT_ADMIN scripts priv config | wc -l` | 23 (V) |
| UAT roster | `grep -c builtin_roles test/fixtures/uat/actors.yaml` | 30 (V) |

**Taken from T-1846 without re-reading** (marked "per T-1846" above): `identity.ex` 2848/2916/2996/3048 mint rules,
`routers/me.ex`, `solution_pack.ex`, `activator.ex`, `permission_matrix.ex @admin_roles`, `check_uat_scenario_schema`,
`role_registry.ex` line numbers, `scoped_grants.ex`, the other web files.

**Sources not read:** the D-129 and D-126 records (portfolio, not reachable from the worktree; the task text was used);
decision 0055 (cited through 0081's text only); 0013 and 0051 bodies beyond headings; `docs/roles.md` beyond the grep
lines quoted; `Catalog.manifest_hash`; the T-1844 asset count spec (not on main); the contents of the test files counted.
All permission names marked G (`TasksReadAll`, `TasksWorkInScope`, `TasksReassignRouted`, `TenantSecurityManage`,
`EntitiesRecordsImportManaged`) are working names, not existing atoms.
