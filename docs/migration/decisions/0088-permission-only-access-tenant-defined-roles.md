# 0088 — Access is decided by permissions only; roles become tenant data (supersedes the closed role set)

Status: **PROPOSED until the owner confirms** (T-1849, PM D-131 (i), owner principle D-129). Until the owner confirms, records
0013, 0046 D10, 0081 D1 and 0084 stay in force as written, and nothing below changes code, data, QA, demo or production.
Stage 0 (`docs/design/roles-stage0-slices.md`) changes no access answer and keeps the nine compiled roles, so it does not need this
record to be confirmed; stage 1 and later do.
**REVIEWER sign-off:** pending; given by the T-1849 gate and recorded in the Gates block of the merged PR.
**SECURITY-REVIEWER sign-off:** pending; required before the owner confirms, because this record moves the rules of every access
decision. Each stage-0 slice and stages 2 to 4 get their own security review (D9).
The number 0088 was the next free one on origin/main at T-1849 (0087 is the MES posting-kernel record; no open team branch adds a
decision record).

Sources read for this record (V = read on this branch, origin/main `687f4242b`, 2026-11-13):
`docs/design/roles-architect-verdict.md` (T-1848, whole file, V), `docs/design/tenant-defined-roles.md` (T-1846, sections 0 and 1, V),
`docs/design/open-core-sockets.md` (T-1842, whole file, V); decision records `0013-authorization-role-set.md` (body and addendum
Decision, V), `0039-platform-module-solution-layering.md` D4 (V), `0046-admin-scopes-and-role-charter.md` D1 to D10 and sign-offs (V),
`0081-storekeeper-role.md` (whole, V), `0084-tenant-storekeeper-asset-grant.md` (whole, V), `0084-public-signup-part-1.md` (headings,
V), `0006-identity-tables-schema-per-tenant.md` D2 heading (V); code: `lib/letflow/api/authorization.ex`, `lib/letflow/api/scope.ex`, `lib/letflow/api/scope_gate.ex`, `lib/letflow/tasks.ex`,
`lib/letflow/routers/tasks.ex`, `lib/letflow/identity/scoped_approvers.ex`, `lib/letflow/routers/entities/record_import.ex`,
`lib/letflow/modules/ledger_registration.ex`, `lib/letflow/identity/scoped_grants.ex`, `web/src/auth/access/access.ts`,
`priv/permission_matrix/effective.golden` (header and rows quoted below, V).
Not read: the portfolio records D-129, D-126 and D-131 (not reachable from the worktree; the task text was used); decision 0055 (cited
through 0081 and 0084 only); 0048 and 0051 beyond their references in the records above.

## Context

D-129 (as given in the task text): access is checked against permissions only, never against role names; only the platform admin is
preinstalled; the owner side creates the tenant admin; the tenant admin creates every other role from the permissions the modules
declare. Four records say the opposite: the role set is a closed compiled list (0013 Decision and its addendum, "closed enum"), it
"stays closed" (0046 D10), STOREKEEPER is a ninth built-in role (0081 D1), and only STOREKEEPER may get a closed list of asset
permissions per tenant (0084 D1).

What the code does today (V): every route asks one question, "does one of the caller's roles allow permission P"
(`Authorization.evaluate_access/2`, `role_allows?/2`, `role_allows?/3`). What is closed is the list of nine role atoms (`@roles`,
`authorization.ex:474`) and the compiled mapping role to permissions (`core_role_allows?/2` clauses from `authorization.ex:1895`).
About a dozen sites outside that table still ask a role name directly (listed with file and line in
`docs/design/roles-stage0-slices.md`). The golden matrix (`priv/permission_matrix/effective.golden`) has 9 roles, 87 permissions,
783 rows.

## Decisions (proposed)

### D1. The principle

An access answer depends only on the permissions the caller holds, the scope in which they hold them, the tenant (platform tenant or
not) and the kind of credential. It never depends on the name or key of a role. Test for every site: "would renaming the role change
an access answer?" If yes, it is a role-name check and must be replaced.

### D2. Condition 1: names identify, never decide

A role key may still name a row: the seed that creates the tenant admin, the pending first-admin grant (`role_name` default
`"TENANT_ADMIN"`, 0048), an identity-provider claim that maps to a group, a template a tenant copies, a manifest's default grant.
It is never the reason a request is allowed or refused.

### D3. Condition 2: the two admins are protected rows with a rule

* Platform admin: a protected row with `grants = all`, honoured only in the platform tenant.
* Tenant admin: a protected row with `grants = all_tenant_scope` (every permission whose `permission_scope/1` is `:tenant`), created by
  provisioning for each tenant.
* Both rules are computed, not stored lists, because modules add permissions later. A row carries two flags that only platform code
  writes: `protected` (cannot be edited, deleted, renamed or copied over) and `grants` = `all` / `all_tenant_scope` / `listed`.
  No route can set either flag. The decision reads the flag, never the name.
* The platform-tenant condition (0046 D2, INV-10) is a tenant check and stays. The interactive-credential test of
  `Scope.require_interactive_tenant_admin/1` is an authentication check and stays.
* The last-admin guard counts interactive tenant-wide holders of the protected `all_tenant_scope` row, not holders of a name.

### D4. Condition 3: non-assignable permissions

Each permission carries a flag `assignable`. A permission with `assignable: false` is held only by a `grants = all` or
`grants = all_tenant_scope` row and can never be put into a tenant's own role. This replaces every "caller holds TENANT_ADMIN" test
by a permission and is the control against privilege escalation by role editing. Non-assignable without further choice: every
platform-scope permission; role and user management (`UsersGroupsRolesManage`); the two admin-only switches that stage 0 turns into a
permission (scope enforcement and service-principal flag, slice S0-3 of the slice list); taking a routed task away (slice S0-4).
Open point OP-A below for the three asset actions.

### D5. Condition 4: routing a task to a role is addressing, not access

"May you complete tasks" is a permission (`TasksComplete`). "Is this task addressed to you" is a fact about the task. A routing name
(`tenant_role` kind `process_routing_role`) is a label for a group of people and never grants a permission. 0081 D1's sentence
"routing roles carry no permissions" is kept as this rule. The routing comparisons in `tasks.ex` (`ref in scope.role_names`) stay as
data.

### D6. Roles become tenant data

Role rows live in each tenant's own schema (INV-1, 0006 D2), keyed by a string key that is never turned into an atom from input. The
nine roles of today become templates shipped with the code: core content from today's `core_role_allows?/2` clauses, module content
from the manifests' `role_grants`. A module still cannot create a role (the part of 0046 D10 and 0039 D4 that survives); its
`role_grants` mean "the default content of template K". Scope grants (`role_scope_grants`, 0051) stay keyed by role key; the check
becomes "a grant covering node N names a role whose set holds P".

### D7. No silent widening

A module upgrade or a new permission never enters a tenant's own role by itself (0084 D3 carried forward; owner choice O3 decides the
rest). Every role write is audited in the same transaction.

### D8. Order

Stage 0 first: every role-name decision site becomes a permission while the nine roles stay compiled in, one slice at a time
(`docs/design/roles-stage0-slices.md`). Proof per slice: the golden's old rows are byte identical and only rows of new permissions are
added. Stages 1 to 6 follow only after the owner confirms this record.

### D9. Security review

Every stage-0 slice, and stages 2, 3 and 4, are security-reviewed before merge (tenant isolation INV-1, INV-5 not-found equals
forbidden, INV-6 new data path, INV-10 cross-tenant negative test for every new route). A slice whose permission would also be held
by PLATFORM_ADMIN through its catch-all (`core_role_allows?(:PLATFORM_ADMIN, _) -> true`) names that row in its PR, and the reviewer
rules whether the platform admin may gain it inside the platform tenant (see the slice list, S0-3 and S0-4).

## What this record supersedes, and what stays valid

| Record and passage | Superseded (effective when the owner confirms) | Stays valid |
|---|---|---|
| 0013 body, "Decision": "The five-role matrix in `Letflow.Api.Authorization` is the contract" | That the set of roles is a compiled contract. The roles become templates (D6). | The reasoning against widening by seed: a seeded account gets the least role that fits, never PLATFORM_ADMIN (0013 Consequences bullet 2). The history of PROCESS_OPERATOR. |
| 0013 addendum, "Decision": "Add a sixth role, `CANDIDATE`, to ... closed enum" | "Closed enum". | CANDIDATE's content (exam permissions only, no `EntitiesQuery`) becomes the candidate template unchanged; the separation from TASK_WORKER stays. |
| 0013 Consequences, last bullet ("does not settle ... whether tenant-scoped roles ever feed the same matrix") | Now settled: tenant role rows feed the decision (D6). | That routing names (`RoleRegistry`, process routing) are a separate thing (D5). |
| 0046 D10 "The role set stays closed (0013, 0039 D4): a module cannot create a role." | "The role set stays closed". | "A module cannot create a role" (D6). |
| 0046 title and D5, D6, D7 (eight built-in roles, their lists) | That they are built-in. | D5's content becomes the rule of the protected tenant-admin row (`all_tenant_scope`, D3). D6 and D7 become template content. D1 (two scopes), D2 (platform tenant, config-pinned, fails closed), D3 (every permission has one scope), D4 (PLATFORM_ADMIN only in the platform tenant), D8 (history), D9 (deferred roles, see O4) stay. |
| 0081 header ("Amends 0046 D10") and D1 "`STOREKEEPER` is appended to `roles/0`. It is a built-in role" | "Built-in role". STOREKEEPER becomes a template (an ordinary role of existing tenants under O1). | D1 "routing roles carry no permissions" (D5). D2 (grant content of the template). D3 (matrix tool rule for a new role). D4 import guard: its outcome stays; its form changes in stage 0 from the role name to a permission (slice S0-1). D5 and "Known limits" stay. D2's last bullet (a `role_grants` widening is refused until per-tenant snapshots exist): the tenant's role rows are those snapshots, so the block lifts at stage 2, not before. |
| 0084 (`0084-tenant-storekeeper-asset-grant.md`) D1 (closed add-only overlay for STOREKEEPER only; `grantable/0`) and D5 (`GET`/`PUT /tenant/role-grants`) | At stage 3 a tenant puts `AssetsRead`/`AssetsPost` into any of its roles; the overlay and its routes are retired in stage 4 after the backfill copies each tenant's switch into its storekeeper row. | D2 (`Authorization` stays pure; the per-tenant input is loaded at the request edge with the caller's own prefix): this is the pattern stage 2 generalises. D3 (an upgrade never widens or narrows a tenant silently): kept as D7. D4 (defaults) until stage 3. |
| 0084 (`0084-public-signup-part-1.md`) | Nothing. Same number, unrelated subject. | All of it. |
| 0039 D4 (role_grants keys "must be in `Authorization.roles/0`") | Not named in the task; read here because 0046 D10 cites it. Its key rule is read as "must be a template key" from stage 6; until then `roles/0` is the template key list, so nothing changes. Flagged for REVIEWER. | "A module cannot create a role and cannot grant a core permission". |

## Owner choices (OPEN; the recommendation is the architect's, T-1848, and is not decided)

| # | Question | Choices | Recommendation (not decided) |
|---|---|---|---|
| O1 | Existing tenants have the seven ready-made roles besides the two admins. What happens to them? | (a) they stay as ordinary roles of that tenant, which its admin may edit or remove; (b) they are removed | (a): no behaviour change; only new tenants start without them |
| O2 | Does a new tenant start with only its admin, or with starter roles already created? | (a) only the admin, who copies from templates; (b) the starter roles are created | (a), as D-129 says; QA and UAT seeds then create their roles explicitly |
| O3 | When a module update brings a new permission, do the tenant's own roles get it automatically? | (a) never, the admin switches it on; (b) yes | (a) (D7, 0084 D3) |
| O4 | May the tenant admin let someone else manage roles and users? | (a) no; (b) a delegated user manager | (a) for now (0046 D9 deferred it); (b) a later change |
| O5 | Is "create your own roles" in the open core or a paid closed feature? | (a) open; (b) closed | (a): it is the base model; paid extras sit around role management, not on the decision |
| O6 | Limits: roles per tenant, permissions per role | numbers | none proposed; a number is needed before stage 3 |

Further open points found while writing this record:

* **OP-A (disagreement with T-1848 condition 3).** The verdict makes `AssetsReverse`, `AssetsReconcile` and `AssetsCardWrite`
  non-assignable "per 0084 D1". 0084 D1 only says they are not in the storekeeper's overlay; it does not make them admin-only for all
  time. Today only PLATFORM_ADMIN and TENANT_ADMIN hold them (golden, V). Whether a tenant may give them to its own role (for
  example a chief accountant) is a business and money question for the owner, not a consequence of 0084. Until answered, treat them
  as non-assignable (fails closed).
* **OP-B.** The storekeeper task-list behaviour (a user holding only STOREKEEPER sees every task of the tenant; slice S0-5) is a
  separate security ruling; this record does not decide it.

## Not decided here

* Any table, migration, column name or route (stages 1 to 4 each get a requirement and a design).
* Licence or edition rules (open-core note, D-126); what happens to custom roles if a licence ends.
* The exact names of the new permissions (working names in the slice list).
* Production, QA and demo rollout; feature flag names.

## Verified vs guess

* V: the quotes of 0013, 0039 D4, 0046 D10, 0081 and 0084 above; the code sites and golden facts named in Context and D3 to D5.
* G: the stage plan, the flags `protected`, `grants`, `assignable` (working names from T-1848), the claim that no site must stay a
  role-name check (T-1848 E3; re-checked here only for the stage-0 sites).
