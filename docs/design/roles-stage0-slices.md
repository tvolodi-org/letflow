# Roles, stage 0: replace every role-name decision site by a permission (slice list)

Task T-1849 (PM D-131 (i)). Companion of decision record `docs/migration/decisions/0088-permission-only-access-tenant-defined-roles.md`
(proposed). Builds on `docs/design/roles-architect-verdict.md` (T-1848, sections E3, E6) and `docs/design/tenant-defined-roles.md`
(T-1846). Docs only: this file builds nothing; each slice below is a later task with its own requirement, design, security review
and PR.

Legend: **V** = verified by reading the file on this branch (origin/main `687f4242b`, 2026-11-13); commands in section 6.
**G** = guess (sizes, working names, behaviour I did not trace to the end).

## 1. What stage 0 is

Every site that decides access by a role **name** is rewritten to ask for a **permission**. The nine roles stay compiled in
(`@roles`, `authorization.ex:474`), and each new permission is compiled into exactly the roles that pass the site today (with an
explicit `false` clause where an admin catch-all would add a holder, S0-2 to S0-4), so every access answer stays the same; S0-5 is
the exception and is BLOCKED. No table, no migration, no flag, no data. Stage 0 does not need decision 0088 to be confirmed: it
does not open the role set; it only removes names from decisions.

Rules for every slice:

| Rule | Detail |
|---|---|
| One slice at a time | Every slice touches the shared files `lib/letflow/api/authorization.ex`, `priv/permission_matrix/effective.golden`, `docs/roles.md` (matrix parity test `test/letflow/api/roles_matrix_parity_test.exs`) and the tenant-auditor refused set (`@auditor_refused_core`, `test/letflow/api/authorization_tenant_auditor_test.exs:46`, count pin at line 139). Two slices in flight collide on all four. The next slice starts after the previous one merged. |
| New permission is tenant scope | Add it to the compile-time scope table read by `permission_scope/1` (`authorization.ex:649`). An unclassified atom is `:platform` and fails closed, so a missing entry shows up as refusals, not widening (V). |
| Golden proof | `mix letflow.permission_matrix --write` after the last merge of main. The diff of `effective.golden` may only **add** rows of the new permission (9 rows, one per role) and change the header counts; every old row is byte identical. The PR quotes `git diff -U0 priv/permission_matrix/effective.golden | grep '^-' | grep -v '^---'` and shows that only header lines appear. |
| Route proof | The tests named in the slice run unchanged and green; any new test proves both branches (allowed and refused). |
| Security review | Mandatory for every slice (access decision). Review point named per slice. |
| Admin catch-alls (two clauses) | (1) `core_role_allows?(:PLATFORM_ADMIN, _) -> true` (`authorization.ex:1895`, V) gives every new permission to PLATFORM_ADMIN. Outside the platform tenant PLATFORM_ADMIN is dropped before the decision (`authorization.ex` around 1541-1544, V), so this clause matters only inside the platform tenant. (2) `core_role_allows?(:TENANT_ADMIN, permission) -> permission_scope(permission) == :tenant` (`authorization.ex:1902`, V) gives every new **tenant-scope** permission to TENANT_ADMIN, in every tenant, and so also to every **scoped** TENANT_ADMIN grant (`identity/scoped_grants.ex:123` refuses only PLATFORM_ADMIN as a grant role, V). Because the previous row makes every new permission tenant scope, both clauses always apply. Each slice states, for both rows, whether that changes an answer; where it would, the slice either names the explicit `false` clause placed above the catch-alls that keeps today's answer, or names the security ruling it waits for. |
| Rollback | Revert the PR. No data was written, so nothing else is needed. |

## 2. The slices, in order

Working names of permissions are G. "Holders" = the roles the new permission is compiled into, PLATFORM_ADMIN and TENANT_ADMIN
included (both catch-alls, section 1); an explicit `false` clause is named where a slice needs one.

| Order | Slice | Site (file:line, V) | What it guards today | New permission and holders | Exact? | Tests that prove it (V, exist) | Security review point | Size (G) |
|---|---|---|---|---|---|---|---|---|
| 1 | S0-1 import | `lib/letflow/routers/entities/record_import.ex:97-111` (`import_scope/2`, `storekeeper_only_import?/1`), `:137-142` (`storekeeper_managed_allowed/3`); `lib/letflow/api/scope_gate.ex:146` (`scope_set_without_role/3`) | A caller who holds `EntitiesRecordsImport` only through STOREKEEPER imports only `stock`/`stock_opening_line` (0081 D4 and its security ruling); STOREKEEPER's tenant-wide grant must not widen another role's scoped import | `EntitiesRecordsImportAnyType`: holders TENANT_ADMIN (and PLATFORM_ADMIN). STOREKEEPER **keeps** `EntitiesRecordsImport` and does not get the new one. New rule: "holds `EntitiesRecordsImport` but not `EntitiesRecordsImportAnyType`" replaces "STOREKEEPER-only"; the wide scope set is computed from roles holding `EntitiesRecordsImportAnyType` | Yes: today only PLATFORM_ADMIN, TENANT_ADMIN and STOREKEEPER hold `EntitiesRecordsImport` (golden, V), and modules cannot grant core permissions (0039 D4). TENANT_ADMIN clause (`:1902`): it is meant to hold the new permission, so the clause gives the intended holder; a scoped TENANT_ADMIN grant counts for the wide set today (`scope_set_without_role/3` only drops STOREKEEPER before `Scope.allowed_set/2`, `scope_gate.ex:212-214`, V) and counts the same way after. PLATFORM_ADMIN catch-all: intended holder too | `test/letflow/modules/stock/storekeeper_test.exs`, `test/letflow/modules/stock/opening_import_test.exs`, `test/letflow/api/scope_without_role_test.exs`, `test/letflow/api/gh2659_import_implies_write_test.exs` (its STOREKEEPER exception becomes "holders of `EntitiesRecordsImport` without `EntitiesRecordsImportAnyType`") | Scope-set union under `scope_enforcement :on`: the set without STOREKEEPER equals the set over holders of the new permission | S |
| 2 | S0-2 scoped task work | `lib/letflow/tasks.ex:446` (`f1_allowed?/3`); `lib/letflow/routers/tasks.ex:182, 245, 314, 353, 561` (`ScopeGate.scope_set_for_role(conn, _, "TASK_WORKER")`); `lib/letflow/identity/scoped_approvers.ex:40` (`@role "TASK_WORKER"`, counts) | Under scope enforcement a scoped caller works a task only through a TASK_WORKER grant covering the task's node; "other roles' grants and a PROCESS_OPERATOR or TENANT_ADMIN grant never count" (`tasks.ex`, doc of `f1_allowed?/3`, V) | `TasksWorkInScope`. Plain compiled form: holders TASK_WORKER, **TENANT_ADMIN** (tenant-scope clause, `authorization.ex:1902`) and PLATFORM_ADMIN (catch-all). Exact form (b), the one this slice is written in: two explicit clauses `core_role_allows?(:TENANT_ADMIN, :TasksWorkInScope) -> false` and `core_role_allows?(:PLATFORM_ADMIN, :TasksWorkInScope) -> false`, placed above `authorization.ex:1895` and `:1902`; holder then TASK_WORKER only, golden rows of the new permission: TASK_WORKER `true`, the other eight `false`. Check: "a scoped grant covering the node names a role that holds `TasksWorkInScope`". Not `TasksComplete`: PROCESS_OPERATOR and STOREKEEPER hold that (golden, V), so their scoped grants would start to count | **Plain form: No.** (1) A scoped TENANT_ADMIN grant on a node would start to count, so its holder could claim and complete tasks on that node, in every tenant: a widening (today the doc of `f1_allowed?/3` says a TENANT_ADMIN grant never counts). (2) The name list for the SQL approver counts derived as `Enum.filter(Authorization.roles(), &role_allows?(&1, :TasksWorkInScope))` would be `[PLATFORM_ADMIN, TENANT_ADMIN, TASK_WORKER]`, so scoped TENANT_ADMIN grants would be counted as approvers and the counts would change. **Form (b): Yes** (G until the implement step runs the tests): the derived list is `[TASK_WORKER]`, equal to `@role` today; PLATFORM_ADMIN is still exempt through the tenant-wide branch of `f1_allowed?/3`, which does not read the new permission (`ScopeGate.memoised_set` for a platform-tenant caller not traced, G) | `test/letflow/api/scope_for_role_test.exs`, `test/letflow/tasks/f1_context_test.exs`, `test/letflow/identity/scoped_approvers_test.exs`, `test/letflow/docs/roles_scoped_approvers_test.exs`, `test/letflow/scope_enforcement_on_test.exs`; new: a scoped TENANT_ADMIN grant on the task's node is refused (both before and after the slice) and the approver counts with a scoped TENANT_ADMIN grant present are unchanged | (1) The two `false` clauses are the first exceptions to the admin catch-alls; the reviewer confirms them, or rules (a) that a scoped TENANT_ADMIN grant may count for task work, which changes an answer in every tenant and is then a separate change with its own PR, not stage 0. Recommendation (G): (b) now; the question returns in stage 2, when the catch-alls become the `grants = all` / `all_tenant_scope` row flags (0088 D3) and `TasksWorkInScope` must be listed as excluded from `all_tenant_scope` or dropped. (2) `ScopeGate.scope_set_for_role/3` takes a role string; the new form takes a permission and must compute the same node set; the SQL counts in `scoped_approvers.ex` use the derived list and the PR proves the counts equal | M |
| 3 | S0-3 interactive tenant-admin switches | `lib/letflow/api/scope.ex:494-495` (`require_interactive_tenant_admin/1`: `:TENANT_ADMIN in principal.roles` and `effective_scope(principal, "TENANT_ADMIN")`); callers `lib/letflow/routers/tenant_scope_enforcement.ex:79`, `lib/letflow/routers/identity.ex:945` (service-principal flag) | Only an interactive user holding TENANT_ADMIN tenant-wide may flip scope enforcement or the service-principal flag | `TenantSecurityManage` (non-assignable under 0088 D4): holder TENANT_ADMIN. Interactive-credential test and `UsersGroupsRolesManage` tenant-wide check stay | **No, in one cell**: today a platform-tenant PLATFORM_ADMIN alone is refused (doc of the function; `docs/roles.md` line 110). By the catch-all it would hold the new permission and pass, inside the platform tenant only. TENANT_ADMIN clause (`:1902`): TENANT_ADMIN is the intended holder; the tenant-wide condition stays, so a scoped TENANT_ADMIN grant is refused as today (`effective_scope(principal, "TENANT_ADMIN")` must be tenant-wide, V) | `test/letflow/routers/tenant_scope_enforcement_on_test.exs`, `test/letflow/routers/tenant_scope_enforcement_test.exs`, `test/letflow/routers/tenant_scope_enforcement_refusal_kinds_test.exs`, `test/letflow/routers/service_principal_route_test.exs`, `test/letflow/routers/tenant_auditor_routes_test.exs` | Ruling needed: (a) accept that the platform admin may flip these switches for its own platform tenant (consistent with "platform admin = all permissions", 0088 D3), or (b) add an explicit `core_role_allows?(:PLATFORM_ADMIN, :TenantSecurityManage) -> false` clause, an exception to the catch-all like the two of S0-2 (golden row PLATFORM_ADMIN false). Recommendation (G): (a), with the PR naming the changed answer; until ruled, the slice is written as (b) so stage 0 changes nothing | S |
| 4 | S0-4 take a routed task away | `lib/letflow/tasks.ex:836` (`"TENANT_ADMIN" in token_roles` in `authorize_reassign/3`) | A tenant admin may reassign a task routed to a role or group without being in it; `TasksReassign` alone (PROCESS_OPERATOR) is not enough | `TasksReassignRouted` (non-assignable): holder TENANT_ADMIN. The routing-membership branches below it stay (addressing, 0088 D5) | **No, in one cell**: same platform-tenant PLATFORM_ADMIN case as S0-3 (today refused unless it is in the routing role). TENANT_ADMIN clause (`:1902`): TENANT_ADMIN is the intended holder; today's check reads token role strings, not scoped grants, and the permission check reads the same roles through `effective_roles/2`, so no scoped-grant cell changes (G: not run) | `test/letflow/routers/tasks_test.exs` (reassign tests, REQ-085 describe block), `test/letflow/engine_distinct_from_test.exs` | Same ruling as S0-3 (one ruling for both). Also: `actor_roles` are token role strings; the new check must go through `effective_roles/2` so a PLATFORM_ADMIN string outside the platform tenant still grants nothing | S |
| 5 | S0-5 task list filter: **BLOCKED** | `lib/letflow/api/authorization.ex:1553` (use), `:1567` (`is_task_worker_only?/1`) | `GET /tasks` shows only own and group tasks for a TASK_WORKER who holds none of PLATFORM_ADMIN, PROCESS_DESIGNER, PROCESS_OPERATOR, TENANT_ADMIN, TENANT_AUDITOR | `TasksReadAll`: holders the five roles. Without it, a `TasksRead` holder sees own and group tasks only | **No**: a user holding STOREKEEPER without TASK_WORKER (and without the five) is not filtered today and sees every task of the tenant (V: STOREKEEPER holds `TasksRead`, golden; `is_task_worker_only?/1` is false without TASK_WORKER). The permission form narrows that user to own and group tasks. Under `scope_enforcement :on` that user already gets an empty or refused set (0081 "Known limits"). TENANT_ADMIN clause (`:1902`) and PLATFORM_ADMIN catch-all: both are among the five intended holders, so neither changes an answer | `test/letflow/api/authorization_test.exs`, `test/letflow/api/authorization_tenant_admin_test.exs`, `test/letflow/api/authorization_tenant_auditor_test.exs`, `test/letflow/routers/tasks_test.exs` | **Blocked until the separate security ruling on the storekeeper task list lands.** Then the slice implements the ruling and nothing else | S |

Order reason: S0-1 is exact, small and proven by existing 0081 D4 tests (the verdict's choice of first step, T-1848 E6). S0-2 is
exact only in form (b) (two explicit `false` clauses) and touches five routes and an SQL count. S0-3 and S0-4 share one ruling and
are written in form (b) until it is given. S0-5 waits for its ruling.

**Where I differ from T-1848.**
1. S0-1: the verdict splits `EntitiesRecordsImport` and takes it away from STOREKEEPER, which changes the STOREKEEPER row of the golden
   and the route's required permission. The additive form above (a new wider permission held by the admins; STOREKEEPER unchanged)
   keeps every old golden row identical, which is the stage-0 proof.
2. S0-5: the verdict says no set of permissions reproduces today's answer. One does: a restricting marker ("sees only own tasks",
   held by TASK_WORKER) combined with `TasksReadAll`. I reject it anyway, because a permission that **reduces** access breaks the
   additive model custom roles rely on (a tenant role holding it plus `TasksRead` would behave unexpectedly). So the conclusion
   stands: the site changes behaviour and needs the ruling.
3. Web `isCandidate` (`web/src/auth/access/access.ts:24-27`, used only by `web/src/components/ui/PermissionDenied.tsx:13` to choose
   the "go to exams" link): the verdict puts it in stage 0 as "ask `ExamSessionStart`". That is not exact: TENANT_ADMIN and
   PLATFORM_ADMIN also hold `ExamSessionStart` (golden, V) and would see the exam link instead of "my tasks". It is a display choice,
   not an access decision (the server decides). Moved to stage 5 (web roles page).

## 3. Sites that are not stage 0 (and why)

| Site (V) | Kind (T-1848 E3) | Stage |
|---|---|---|
| `authorization.ex:474` `@roles`, `role_from_string/1` (`:772-777`), `roles_from_strings/1` (`:705`), `effective_roles/2` (`:724`) | identification; template key list | 1 to 2 (rows), 6 (remove compiled lists) |
| `authorization.ex:1895` PLATFORM_ADMIN catch-all, `:1902` TENANT_ADMIN every tenant-scope permission; `scope.ex:280` `:PLATFORM_ADMIN in candidates` | row flag `grants = all` / `all_tenant_scope` | 2 |
| `identity.ex:2120, 2848, 2916, 2996, 3048, 3211`; `identity/api_token.ex:73`; `identity/platform_admin_tokens.ex:65`; `identity/scoped_grants.ex:123` (PLATFORM_ADMIN token and grant rules) | flag `grants = all` + platform tenant | 2 and 4 |
| `identity/tenant_admin_guard.ex:56` (`@tenant_admin_role "TENANT_ADMIN"`), `identity/pending_admin_grant.ex`, `identity/tenant_admin_migration.ex` | identification of the protected row; last-admin guard re-keyed to the row | 2 |
| `modules/ledger_registration.ex:405` (`check_auditor_or_candidate`) | registration lint over manifest template keys; run-time guard becomes a `read_only` flag | 2 |
| `identity.ex:2658` `@issuable_token_roles` | token role keys become the tenant's keys | 4 |
| `authorization.ex:1866` `grantable/0`, `api/tenant_grants.ex:59, 69, 78`, `routers/tenant_role_grants.ex:71` (STOREKEEPER overlay, 0084) | data | 3 (tenant edits roles), 4 (overlay retired) |
| `web/src/auth/access/access.ts:24` `isCandidate` | display | 5 |
| Routing comparisons in `tasks.ex` (`ref in scope.role_names`) | addressing (0088 D5) | stays |

## 4. Stages 1 to 6 (outline only; each needs the owner's confirmation of 0088 first)

| Stage | Content | Proof | Rollback |
|---|---|---|---|
| 1 | Role tables in each tenant schema, backfill equal to today's compiled answers, shadow comparison, flag default off | equality over every tenant fixture, every role, every permission | flag off |
| 2 | The decision reads the rows; `protected`, `grants`, `assignable`, `read_only` flags; last-admin guard on the protected row | same equality, live | flag off |
| 3 | Role management routes (create, copy template, edit, retire), escalation rules, audit; owner limits (O6) | escalation, last-admin, INV-5 and INV-10 tests | routes off by flag |
| 4 | Tokens, identity-provider claims, solution packs, `GET /me/access`, UAT schema check on tenant keys; retire the STOREKEEPER overlay route | token and claim tests | revert |
| 5 | Web roles page and lists, `isCandidate`, UAT roster actor with a custom role | UAT run | revert |
| 6 | Remove the compiled role lists (templates stay in code as data) | golden over templates only | restore from the pre-deploy backup, so last and alone |

## 5. Not decided here

The security rulings for S0-2 (whether a scoped TENANT_ADMIN grant may count for task work; until then form (b)), S0-3/S0-4 (platform
admin in the platform tenant) and S0-5 (storekeeper task list); final permission names;
owner choices O1 to O6 and OP-A of decision 0088.

## 6. Commands behind the facts (origin/main `687f4242b`)

| Fact | Command |
|---|---|
| Line numbers in `authorization.ex` | `grep -n '@roles\b\|def is_task_worker_only?\|is_task_worker_only?(\|def grantable\|def role_allows?\|def effective_roles\|def roles_from_strings\|def permission_scope' lib/letflow/api/authorization.ex`; `grep -n 'core_role_allows?(:' lib/letflow/api/authorization.ex`; read 1540-1575 |
| Role-name sites outside the table | `grep -rn '"TASK_WORKER"\|"STOREKEEPER"\|:STOREKEEPER\b' lib --include=*.ex`; `grep -n ... lib/letflow/tasks.ex lib/letflow/routers/tasks.ex lib/letflow/api/scope.ex lib/letflow/modules/ledger_registration.ex lib/letflow/identity/tenant_admin_guard.ex`; `grep -rn '"PLATFORM_ADMIN"\|:PLATFORM_ADMIN' lib --include=*.ex` (comments excluded) |
| Site bodies | read `record_import.ex` 95-142, `tasks.ex` 430-450 and 825-850, `scope.ex` 272-286 and 485-500, `scope_gate.ex` 126-160, `scoped_approvers.ex` 30-120, `ledger_registration.ex` 398-412, `access.ts` 20-32 |
| Holders | `grep -E ' (TasksRead|TasksComplete|TasksAssign|EntitiesRecordsImport|UsersGroupsRolesManage|ExamSessionStart|AssetsReverse|AssetsReconcile|AssetsCardWrite) ' priv/permission_matrix/effective.golden \| grep true` |
| Golden header | `head -8 priv/permission_matrix/effective.golden` (9 roles, 87 permissions, 783 rows) |
| Tests | `grep -rl '<symbol>' test` for `f1_allowed?`, `scope_set_for_role`, `scope_set_without_role`, `ScopedApprovers`, `require_interactive_tenant_admin\|service-principal`, `is_task_worker_only?`, `reassign`; `git ls-files test \| grep -E 'gh2659\|storekeeper'` |

Not read: the bodies of the listed tests (only that they exist and name the symbol); `ScopeGate.memoised_set` for the
platform-tenant case (S0-2, marked G); `docs/roles.md` beyond line 110.
