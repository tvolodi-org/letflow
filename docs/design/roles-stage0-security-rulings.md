# Roles stage 0: security rulings for slices S0-2, S0-3 and S0-4

Task T-1859 (PM D-131 follow-up). Answers the two security rulings left open in `docs/design/roles-stage0-slices.md`
section 5 and in decision record `docs/migration/decisions/0088-permission-only-access-tenant-defined-roles.md` D9 (proposed).
Docs only: no code changes, and nothing in stage 0 changes behaviour. Slices S0-2, S0-3 and S0-4 are built in form (b),
which keeps today's answers exactly. UAT note: `docs/uat/ba-decisions/T-1859.md`.

Legend: **V** = verified by reading the file on this branch (base `abdcaee89`, 2026-11-13); the commands are in section 4.
**G** = guess or not traced to the end.

## 1. Rulings (plain English)

**Ruling 1: a scoped TENANT_ADMIN grant does not count for task work.**
1. Keep today's rule. To see, claim or complete a task under scope enforcement, a scoped user needs a TASK_WORKER grant that covers the task's unit. A scoped TENANT_ADMIN grant never replaces it.
2. Stage 0 (S0-2) keeps this answer with the two explicit `false` clauses of form (b), so the new task-work permission is held by TASK_WORKER only.
3. Why: letting it count would give every scoped tenant admin, in every company, approval authority over its units without anyone deciding that. This is a silent widening of the ruled approver rule (0051 Q3), and it would also change the approver counts.
4. Stage 2 is the earliest stage where this may change, when the admin catch-alls become row flags. Even then the task-work permission must be listed as excluded from the tenant-admin row. From stage 3 a company may put the permission into a role of its own choosing, on purpose and with an audit entry.
5. A tenant admin who has to work tasks on a unit gets an explicit TASK_WORKER grant for it. That works today and leaves a record.

**Ruling 2: a platform admin in the platform tenant stays refused at the two admin-only switches and at taking a routed task away.**
1. Keep today's refusals. Only an interactive tenant-wide TENANT_ADMIN can flip scope enforcement or the service-principal flag. Only a TENANT_ADMIN, or a member of the routing role or group, can take a routed task away. A PLATFORM_ADMIN without these is refused, also in the platform tenant.
2. Stage 0 (S0-3, S0-4) keeps both answers with explicit `false` clauses for PLATFORM_ADMIN on the two new permissions (form (b)). This is the opposite of the slice list's tentative recommendation (a) for S0-3.
3. Why: the refusal at the switches was a deliberate security fix (REQ-519 2f-b, SEC S-3), and a test pins it. The last-admin gate counts only interactive tenant-wide TENANT_ADMINs as people who can flip the switch, so a second kind of holder would break that count. The reassign guard (GH #2931) exists so that a holder of a reassign permission cannot move a routed task to themselves. A platform admin holds that permission too.
4. Cost of keeping the refusals: low. A platform operator who needs these actions in the platform tenant can take TENANT_ADMIN or the routing role there, through the normal audited binding (G: not tested here).
5. Stage 2 makes both exceptions explicit exclusions from the platform-admin `grants = all` row. Any change after that is a separate change with its own requirement and security review. It is never a side effect of a catch-all.

## 2. Evidence for ruling 1 (scoped TENANT_ADMIN grant and task work)

### 2.1 What the code does today (V)

| Site | What it does | Status |
|---|---|---|
| `lib/letflow/tasks.ex` `f1_allowed?/3` (def at line 442) | Allows the caller if (1) `Scope.allowed?(principal, route_permission, :tenant_wide)` allows, or (2) `Scope.allowed_for_role?(principal, "TASK_WORKER", ScopeResolver.task_scope(task))` allows. Its doc says that a PROCESS_OPERATOR or TENANT_ADMIN grant never counts. | V |
| `lib/letflow/api/scope.ex` `allowed?/3` → `tenant_effective/2` → `decide_resource/3` | For a scoped TENANT_ADMIN, the candidates include TENANT_ADMIN (it holds every tenant-scope permission). Its effective scope is `{:nodes, ids}`, and `decide_resource({:nodes, _}, :tenant_wide, _)` returns `{:deny, :not_tenant_wide}`, so branch (1) refuses. Branch (2) reads only the TASK_WORKER rows (`effective_scope(principal, "TASK_WORKER")`). | V |
| `lib/letflow/routers/tasks.ex` lines 182, 245, 314, 353, 561 | `ScopeGate.scope_set_for_role(conn, <key>, "TASK_WORKER")`: list, inbox, get, complete and claim compute their node set from TASK_WORKER rows only (or `:all` under the RA-13 tenant-wide exemption, `scope_gate.ex` `scope_set_for_role/3`). | V |
| `lib/letflow/identity/scoped_approvers.ex` `@role "TASK_WORKER"` (line 40) | The informational approver count of the `on` gate counts only scoped TASK_WORKER holders. | V |
| `test/letflow/api/scope_for_role_test.exs` line 366 | Test "on: a scoped PROCESS_OPERATOR or TENANT_ADMIN WITHOUT a TASK_WORKER grant gets :none; with a covering TASK_WORKER grant it gets the set" pins today's answer. | V (name read; body not read) |
| `lib/letflow/api/authorization.ex:1902` | `core_role_allows?(:TENANT_ADMIN, permission) -> permission_scope(permission) == :tenant`: any new tenant-scope permission reaches TENANT_ADMIN, including every scoped TENANT_ADMIN grant. | V |

### 2.2 Sources for the rule (V)

- `docs/migration/decisions/0051-org-scoped-role-grants-and-enforcement.md`, "Approver resolution (F1 rule, Q3)" and "Q3. Task
  candidates": "a user can approve a task iff the user is in the task's routing role via a group AND holds a `TASK_WORKER` grant
  whose subtree covers the task's scope node" (RULED). The rule names TASK_WORKER, not "any role holding the task permission".
- Same record, D11 (M1): "a scoped TENANT_ADMIN is allowed domain actions only, never admin-plane ones". Task work is a domain
  action, so D11 alone would not forbid counting it. But D11 is a ceiling ("only domain actions"), not a grant. The specific
  approver rule Q3 is narrower and is the one in force. I read the two as consistent: D11 limits what a scoped admin may do,
  and Q3 says which grant decides approval.
- `docs/roles.md` "Known limitation: scoped approvers": "A grant of another role (PROCESS_OPERATOR, TENANT_ADMIN) never
  substitutes for the TASK_WORKER grant".
- 0088 D6 (proposed): in stage 2 the check becomes "a grant covering node N names a role whose set holds P". Under D3,
  `all_tenant_scope` would put the new permission into the tenant-admin row, and the widening would come back unless the
  permission is excluded. 0088 D9 already says such exceptions become explicit exclusions in stage 2.

### 2.3 Risks if a scoped TENANT_ADMIN grant counted

| Invariant or area | Effect |
|---|---|
| INV-1 tenant isolation | No effect. Grants and tasks are read with the caller's own prefix (`Scope.load_grants(user_id, prefix)` in `f1_recheck/3`, V), so the change stays inside one company. |
| INV-2 server-side authorisation | The decision stays on the server. The risk is the content of the rule, not where it runs. |
| Scope enforcement (0051) | A widening in every tenant stored `on`: each scoped TENANT_ADMIN gains see, claim and complete on its subtree. The routing-role check still applies (V, doc of `f1_allowed?/3`; `claim_task/3` and `authorize_completion/3`). So the real widening is for scoped admins who are also in a routing role, and they become approvers without a TASK_WORKER grant. |
| Separation of duties and approval authority | Approval authority would come from an admin grant that was given for administration, not for approving. 0051 M8 treats approval authority as something granted on purpose (the binding is a scope-granting act). |
| Gate counts | `scoped_approvers.ex` counts only TASK_WORKER. If the list of roles is derived from the permission, scoped TENANT_ADMIN holders would enter the count (slice list, S0-2, plain form). The count is informational and refuses nothing. |
| INV-5 | No change: refusals stay `{:error, :task_not_found}` (V, `f1_recheck/3`). |

### 2.4 Stage

- Stage 0: no change (form (b), S0-2).
- Stage 1: no change (shadow tables only).
- Stage 2: the `false` clause for TENANT_ADMIN becomes "`TasksWorkInScope` (working name) is excluded from `all_tenant_scope`".
  This keeps the answer. The PR of stage 2 names the exclusion.
- Stage 3 or later: a company may give the permission to a role of its own (for example a "unit approver" role). That is a
  choice the company makes on purpose, with an audit entry (0088 D7), not a side effect.

## 3. Evidence for ruling 2 (platform admin in the platform tenant)

### 3.1 Interactive tenant-admin switches (S0-3) (V)

| Site | What it does |
|---|---|
| `lib/letflow/api/scope.ex` `require_interactive_tenant_admin/1` (def at line 490) | In order: `:oidc` credential; `:UsersGroupsRolesManage` tenant-wide; `:TENANT_ADMIN in principal.roles` (line 494); `effective_scope(principal, "TENANT_ADMIN") == :tenant_wide` (line 495). Its doc says that a platform-tenant PLATFORM_ADMIN alone does not pass. |
| Callers | `lib/letflow/routers/tenant_scope_enforcement.ex:79` (`PUT /tenant/scope-enforcement`), `lib/letflow/routers/identity.ex:945` (`PUT /users/:id/service-principal`). |
| Pinning tests | `test/letflow/routers/tenant_scope_enforcement_test.exs:316` "a platform-tenant PLATFORM_ADMIN without TENANT_ADMIN is refused the PUT (403), also for off -> shadow". Its comment says: "REQ-519 2f-b (SEC S-3) ... Documented behaviour change". `test/letflow/routers/service_principal_route_test.exs:186` "a platform-tenant PLATFORM_ADMIN alone (no TENANT_ADMIN grant) is refused". |
| `docs/roles.md` line 110 | "Only an interactive (OIDC) user who holds TENANT_ADMIN tenant-wide can call it ... a platform-tenant PLATFORM_ADMIN without TENANT_ADMIN get the uniform 403 ... (earlier releases let tokens and a platform admin move `off` to `shadow`; that is closed)." |
| `docs/roles.md` line 122, gate fact `zero_tenant_wide_admins` | "at least one active, interactive human with an explicit tenant-wide TENANT_ADMIN grant is required ... because only such a user can turn enforcement off". The #2869 last-admin guard (line 149) counts the same set. |

Reasons to keep the refusal:
1. It was a security reviewer's deliberate narrowing (SEC S-3), and a test pins it. Reopening it needs a reason, and stage 0
   promises "every answer stays the same".
2. The last-admin gate and guard rest on the rule that only an interactive tenant-wide TENANT_ADMIN can flip. A platform admin
   who can flip but is not counted breaks the meaning of `zero_tenant_wide_admins` in the platform tenant.
3. 0051 D12 says that flipping "requires a tenant-wide TENANT_ADMIN or platform scope". So the decision record allows more than
   the code. The code is the stricter, later and reviewed form (REQ-519 2f-b), and this ruling keeps the stricter form. Platform
   scope from the platform tenant to another tenant's flag is not built (`docs/roles.md` line 110), and it is not part of this
   question.
4. 0088 D3 keeps the interactive-credential test as an authentication check. D4 lists the two switches as non-assignable,
   "held only by a `grants = all` or `grants = all_tenant_scope` row". Read literally, D4 would give them to the platform
   admin in stage 2. That contradicts this ruling, and it is listed as a finding for the owner's confirmation of 0088 (section 5).

### 3.2 Taking a routed task away (S0-4) (V)

| Site | What it does |
|---|---|
| `lib/letflow/tasks.ex` `authorize_reassign/3` (line 830; check at line 836) | For a ROLE- or GROUP-routed task with `:actor_id`: allowed when `"TENANT_ADMIN" in token_roles`; otherwise the actor must hold the routing role (`ref in token_roles or ref in scope.role_names`) or be in the routing group. Otherwise `{:error, :assignee_role_not_held}` or `{:error, :assignee_group_not_member}`. The comment cites GH #2931: "`:TasksReassign` alone (PROCESS_OPERATOR) is not enough: otherwise the operator reassigns the task to themselves and completes it without the routing role." |
| `lib/letflow/routers/tasks.ex:658` | `actor_roles: Map.get(conn.assigns.auth_context, :roles) || []`: these are the raw token role strings, not `Authorization.effective_roles/2`. |
| Effect today | A platform-tenant PLATFORM_ADMIN holds `TasksReassign` (catch-all, `authorization.ex:1895`), but it is refused unless it is in the routing role or group. The catch-all would give it the new `TasksReassignRouted`, which is why form (b) needs a `false` clause. |

Reasons to keep the refusal:
1. The reasoning of GH #2931 applies to anyone who holds the reassign permission, and the platform admin holds every
   permission in the platform tenant. Letting it pass reopens "reassign to self, then complete without the routing role" in
   that tenant.
2. The benefit is small: the platform tenant is the operator's own tenant, not a customer's business process. A platform operator
   who has to act can be given the routing role through the normal, audited binding (G: I did not check how many routed
   processes run in the platform tenant).
3. When S0-4 is built, the new check must read roles through `effective_roles/2` (the slice list says so). That does not change
   the TENANT_ADMIN answer. It only stops a PLATFORM_ADMIN string from counting outside the platform tenant, which it does not
   count for today anyway (the check is on the TENANT_ADMIN string).

### 3.3 Stage

- Stage 0: no change (form (b): `core_role_allows?(:PLATFORM_ADMIN, :TenantSecurityManage) -> false` and the same for
  `TasksReassignRouted`, working names, above `authorization.ex:1895`).
- Stage 2: both become explicit exclusions from the platform-admin `grants = all` row (0088 D9). D4's sentence on non-assignable
  permissions has to say "held only by the `all_tenant_scope` row" for these two (finding 1).
- Later: changing either refusal is a separate change with its own requirement, security review and a test that inverts the two
  pinning tests named above. It is not a stage-0 or stage-2 side effect.

## 4. Commands behind the facts (base `abdcaee89`)

| Fact | Command |
|---|---|
| F1 sites | `grep -n 'f1_allowed?\|def authorize_reassign\|authorize_reassign(' lib/letflow/tasks.ex`; `grep -n 'scope_set_for_role' lib/letflow/routers/tasks.ex lib/letflow/api/scope_gate.ex`; read `tasks.ex` 405-475 and 800-860, `scope_gate.ex` 120-170 |
| Scope decision | `grep -n 'def allowed_for_role?\|def allowed_set_for_role\|def allowed?\|def effective_scope\|def require_interactive_tenant_admin\|:PLATFORM_ADMIN in' lib/letflow/api/scope.ex`; read `scope.ex` 130-350 and 470-500 |
| Catch-alls | `grep -n 'core_role_allows?(:PLATFORM_ADMIN, _)\|core_role_allows?(:TENANT_ADMIN, permission)' lib/letflow/api/authorization.ex`; read 1890-1905 |
| effective_roles | `grep -n 'def effective_roles' -A22 lib/letflow/api/authorization.ex`; `grep -rn 'effective_roles(' lib --include=*.ex` |
| Token roles at reassign | `grep -n 'actor_roles' lib/letflow/routers/tasks.ex lib/letflow/tasks.ex` |
| Approver count | read `lib/letflow/identity/scoped_approvers.ex` 1-45 |
| Grant role rule | read `lib/letflow/identity/scoped_grants.ex` 100-135 (`parse_role/1` refuses only PLATFORM_ADMIN) |
| Pinning tests | `grep -n 'test "\|describe' test/letflow/api/scope_for_role_test.exs`; `sed -n 305,330p test/letflow/routers/tenant_scope_enforcement_test.exs`; `grep -n -i 'platform' test/letflow/routers/service_principal_route_test.exs` |
| Decision text | `grep -n -i 'TASK_WORKER grant\|F1\b\|scoped admin\|scoped TENANT_ADMIN' docs/migration/decisions/0051*.md`; read 0051 lines 45-52, 386-400, 430-470; 0088 lines 58-116 |
| roles.md | `grep -n -i 'scoped\|F1\|interactive\|reassign\|platform tenant' docs/roles.md` |

## 5. Verified vs guess, sources not read, findings

- Verified (V): every code line, test name and decision quote in sections 2 and 3.
- Guess (G): that a platform operator can hold TENANT_ADMIN or a routing role in the platform tenant through a normal binding (the
  pinning tests say "without TENANT_ADMIN", which suggests that with it the call passes; I did not find or run that test). How
  many routed processes run in the platform tenant.
- Not read: the bodies of the pinning tests (only their names and, for `tenant_scope_enforcement_test.exs`, lines 305-330);
  `ScopeGate.memoised_set` for a platform-tenant caller; the security report `security-0051.md` named in 0051 (not opened); the
  design `lib/letflow/design/req519-enforced-writers-and-flag-on.md` (only grep hits on `require_interactive_tenant_admin`).
  No reassign test with a platform-tenant PLATFORM_ADMIN was found:
  `grep -rn 'reassign' test/letflow/routers/tasks_test.exs | grep -i 'platform\|TENANT_ADMIN'` returns only line 1964 (a
  TENANT_ADMIN case). So S0-4's PLATFORM_ADMIN refusal is not pinned by a test today, and the S0-4 slice should add one
  (refused before and after the slice).
- Finding 1 (for the owner's confirmation of 0088): D4 says the two switches and "taking a routed task away" are held by a
  `grants = all` or `grants = all_tenant_scope` row. Under ruling 2, the `all` row (platform admin) must not hold them, so D4
  needs "`all_tenant_scope` only" for those permissions, or an exclusion list in D3. Proposed records change only by the owner.
- Finding 2: 0051 D12 ("tenant-wide TENANT_ADMIN or platform scope") is wider than the code and `docs/roles.md` line 110. The
  code is the reviewed, stricter form. The record text is stale on this point.
