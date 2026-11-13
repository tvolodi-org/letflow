# 0088 — Access is decided by permissions only; roles become tenant data (supersedes the closed role set)

Status: **ACCEPTED by the owner** (D-131, 2026-11-13; corrected by D-132, 2026-11-13). Written in T-1849 under owner principle D-129;
set to accepted in T-1851. The owner choices O1 to O6 are decided (section "Owner decisions"). From this record on, the passages of
0013, 0046 D10, 0081 D1 and 0084 named in the supersession table are superseded as that table says, per edition. Nothing in this
record changes code, data, QA, demo or production by itself: every stage is its own requirement, design, security review and PR.

Editions (D-126, D-132): the **open build** ships the ready-made roles as **read-only template rows**; the tenant admin assigns users to
them and cannot create, copy, edit or replace a role. The **role editor** (create, copy, edit, replace roles: the stage 3 routes and
screens) is a **closed feature** in the corporate package, behind the role editor socket of `docs/design/open-core-sockets.md` section 1.
Both editions decide access the same way (D1 to D5); no socket sits on the access decision.

Stage 0 (`docs/design/roles-stage0-slices.md`) keeps the nine compiled roles and, in the forms the slice list prescribes, changes
no access answer: S0-1 is exact as compiled; S0-2, S0-3 and S0-4 are exact only with explicit `false` clauses above the admin
catch-alls (`authorization.ex:1895` PLATFORM_ADMIN, `:1902` TENANT_ADMIN holds every tenant-scope permission), because compiled
plainly S0-2 would let a scoped TENANT_ADMIN grant count for task work in every tenant and S0-3/S0-4 would let a platform-tenant
platform admin pass; S0-5 changes an answer and follows its security ruling (`docs/design/storekeeper-task-visibility-ruling.md`, T-1850).
**REVIEWER sign-off:** the T-1849 gate passed and PR #4381 merged; that PR body carries no Gates block (read with `gh api .../pulls/4381`),
so no written REVIEWER verdict is on record. The edits of T-1851 are checked by its own gate.
**SECURITY-REVIEWER sign-off:** pending; required before stage 1 merges, because this record moves the rules of every access
decision. Each stage-0 slice, stages 2 and 4 and the closed role editor get their own security review (D9).
The number 0088 was the next free one on origin/main at T-1849 (0087 is the MES posting-kernel record; no open team branch adds a
decision record).

Sources read for this record (V = read on this branch, origin/main `687f4242b`, 2026-11-13; T-1851 re-read on `abdcaee89`):
`docs/design/roles-architect-verdict.md` (T-1848, whole file, V), `docs/design/tenant-defined-roles.md` (T-1846, sections 0 and 1, V),
`docs/design/open-core-sockets.md` (T-1842, whole file, V); decision records `0013-authorization-role-set.md` (body and addendum
Decision, V), `0039-platform-module-solution-layering.md` D4 (V), `0046-admin-scopes-and-role-charter.md` D1 to D10 and sign-offs (V),
`0081-storekeeper-role.md` (whole, V), `0084-tenant-storekeeper-asset-grant.md` (whole, V), `0084-public-signup-part-1.md` (headings,
V), `0006-identity-tables-schema-per-tenant.md` D2 heading (V); code: `lib/letflow/api/authorization.ex`, `lib/letflow/api/scope.ex`, `lib/letflow/api/scope_gate.ex`, `lib/letflow/tasks.ex`,
`lib/letflow/routers/tasks.ex`, `lib/letflow/identity/scoped_approvers.ex`, `lib/letflow/routers/entities/record_import.ex`,
`lib/letflow/modules/ledger_registration.ex`, `lib/letflow/identity/scoped_grants.ex`, `web/src/auth/access/access.ts`,
`priv/permission_matrix/effective.golden` (header and rows quoted below, V). T-1851 added: `web/src/auth/access/roleLabels.ts` (V),
`docs/roles.md` sections PLATFORM_ADMIN to CANDIDATE (V), `lib/letflow/routers/identity.ex` role and group routes (V),
`lib/letflow/identity.ex` `:platform_role` binding reads (V), `docs/design/storekeeper-task-visibility-ruling.md` (T-1850, ruling, V).
Not read: the portfolio records D-129, D-126, D-131 and D-132 (not reachable from the worktree; the task text was used); decision 0055
(cited through 0081 and 0084 only); 0048 and 0051 beyond their references in the records above.

## Context

D-129 (as given in the task text): access is checked against permissions only, never against role names; only the platform admin is
preinstalled; the owner side creates the tenant admin. D-132 (as given in the task text) corrects D-131 O5: "in the open source
application the tenant admin cannot create other roles"; creating and editing roles is the closed feature behind a socket (D-126
stands). Four records say the role set is closed and compiled: the role set is a closed compiled list (0013 Decision and its addendum,
"closed enum"), it "stays closed" (0046 D10), STOREKEEPER is a ninth built-in role (0081 D1), and only STOREKEEPER may get a closed
list of asset permissions per tenant (0084 D1).

What the code does today (V): every route asks one question, "does one of the caller's roles allow permission P"
(`Authorization.evaluate_access/2`, `role_allows?/2`, `role_allows?/3`). What is closed is the list of nine role atoms (`@roles`,
`authorization.ex:474`) and the compiled mapping role to permissions (`core_role_allows?/2` clauses from `authorization.ex:1895`).
About a dozen sites outside that table still ask a role name directly (listed with file and line in
`docs/design/roles-stage0-slices.md`). The golden matrix (`priv/permission_matrix/effective.golden`) has 9 roles, 87 permissions,
783 rows. A user gets a built-in role today by being a member of the group that a `tenant_role` row of kind `:platform_role` binds to
that role (`Identity` reads at `identity.ex:1374`, `:1509`; members through `POST /groups/:id/members`, `GroupsManage`, V).

## Decisions

### D1. The principle

An access answer depends only on the permissions the caller holds, the scope in which they hold them, the tenant (platform tenant or
not) and the kind of credential. It never depends on the name or key of a role. Test for every site: "would renaming the role change
an access answer?" If yes, it is a role-name check and must be replaced.

### D2. Condition 1: names identify, never decide

A role key may still name a row: the seed that creates the tenant admin, the pending first-admin grant (`role_name` default
`"TENANT_ADMIN"`, 0048), an identity-provider claim that maps to a group, a template a tenant copies (corporate build), a manifest's default grant.
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

A module upgrade or a new permission never enters a tenant's own role by itself (0084 D3 carried forward; owner decision O3 a). In the
open build the template rows follow the same rule: a new module permission reaches the two protected admin rows through their computed
rule (D3) and no template row, which is today's rule as well (0081 D2, last bullet: a `role_grants` widening is refused). Every role
write is audited in the same transaction.

### D8. Order

Stage 0 first: every role-name decision site becomes a permission while the nine roles stay compiled in, one slice at a time
(`docs/design/roles-stage0-slices.md`). Proof per slice: the golden's old rows are byte identical and only rows of new permissions are
added. Then stages 1, 2, 4, 5 and 6 in the open repository, in that order (the open build's read-only template rows, the decision on
rows, tokens and claims, the read-only roles screen, removal of the compiled lists). Stage 3 (the role editor) is built in the closed
package once stage 2 and the role editor socket are on main (`docs/design/open-core-sockets.md` section 1).

### D9. Security review

Every stage-0 slice, stages 2 and 4, and the closed role editor (stage 3) are security-reviewed before merge (tenant isolation INV-1, INV-5 not-found equals
forbidden, INV-6 new data path, INV-10 cross-tenant negative test for every new route). A slice whose permission would also be held
by PLATFORM_ADMIN through its catch-all (`core_role_allows?(:PLATFORM_ADMIN, _) -> true`) or by TENANT_ADMIN through its
tenant-scope clause (`core_role_allows?(:TENANT_ADMIN, p) -> permission_scope(p) == :tenant`, which also reaches every scoped
TENANT_ADMIN grant) names those rows in its PR. Where either would change an answer, the slice keeps today's answer with an explicit
`false` clause above the catch-all, and the reviewer rules whether that exception stays or the gain is accepted as a separate
change: S0-2 (scoped TENANT_ADMIN grant counting for task work, every tenant), S0-3 and S0-4 (platform admin inside the platform
tenant). In stage 2 every such exception becomes an explicit exclusion from the `all` / `all_tenant_scope` row flags (D3), or is
dropped by a ruling.

### D10. Two editions, one decision

* **Open build.** Each tenant has the two protected admin rows (D3) and the seven ready-made roles as **read-only template rows** with
  exactly today's permissions (PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, AGENT_RUNNER, CANDIDATE, TENANT_AUDITOR, STOREKEEPER).
  The tenant admin assigns users to them, as today (group membership of the group a role is bound to). No open route creates, copies,
  edits, renames, replaces or deletes a role row; only platform code writes them (provisioning, the stage 1 backfill). For an existing
  tenant this is no behaviour change: same roles, same permissions, same assignment. The storekeeper asset switch (0084, `GET` and
  `PUT /tenant/role-grants`) stays in the open build, because it is today's behaviour and the open build has no editor to replace it.
* **Corporate build.** The closed role editor package adds the stage 3 routes and screens: create a role from the permissions the
  modules declare, copy a template, edit, replace, retire. It writes rows only through the core role write path, so D3 (protected rows),
  D4 (non-assignable permissions), D7 (no silent widening) and the audit stay core rules that no package can change. Existing tenants
  that get the package keep their seven roles as ordinary editable rows (O1 a); the storekeeper asset switch is retired in that build
  once the tenant's storekeeper row carries the switch's value (stage 4 of the corporate build).
* **Same in both.** D1 to D5, tenant isolation (INV-1), the audit, the platform-tenant rule (INV-10). The access decision itself has no
  socket (T-1848 E7).

### D11. Names of the template rows

The template rows keep today's keys and labels: platform administrator, organisation administrator, process designer, process operator,
task worker, agent runner, candidate, auditor, storekeeper (keys as in `Authorization.roles/0`; labels in `web/src/auth/access/roleLabels.ts`
for en, ru, kk; charter `docs/roles.md`). Reason: D1 forbids a name **deciding** access, not a name **labelling** a row; a label is what an
administrator reads when assigning users, and renaming it would break the UAT roster and every user's screen for no gain. Checked (V):
`roleLabels.ts` only maps a role id to a display name and description; `docs/roles.md` describes what each role holds; the one
web use of a name, `isCandidate` in `web/src/auth/access/access.ts`, picks the link shown on the "no access" page (display, stage 5 of
the slice list), and the server decides access by permission; `ledger_registration.ex:405` (`check_auditor_or_candidate`) is a
registration lint over manifest template keys, not a request-time decision (stage 2 turns it into a row flag). No neutral renaming is
needed; the rows are shipped and documented as templates.

## What this record supersedes, and what stays valid

Checked against the passages themselves in T-1851 (V): 0013 line 24 ("The five-role matrix in `Letflow.Api.Authorization` is the
contract"), the addendum's "closed enum" (lines 139, 144, 185); 0046 D10 (line 166, "The role set stays closed (0013, 0039 D4): a module
cannot create a role."); 0081 D1 (lines 6 to 10, "a ninth built-in role ... routing roles carry no permissions"); 0084
(`0084-tenant-storekeeper-asset-grant.md`) D1 to D5. In the open build the set of roles a tenant sees stays fixed (read-only templates);
what is superseded in both editions is that the set is **compiled code that decides by name**. Only the corporate build lets a tenant
change the set.

| Record and passage | Superseded | Stays valid |
|---|---|---|
| 0013 body, "Decision": "The five-role matrix in `Letflow.Api.Authorization` is the contract" | That the set of roles is a compiled contract. The roles become template rows (D6, D10). | The reasoning against widening by seed: a seeded account gets the least role that fits, never PLATFORM_ADMIN (0013 Consequences bullet 2). The history of PROCESS_OPERATOR. |
| 0013 addendum, "Decision": "Add a sixth role, `CANDIDATE`, to ... closed enum" | "Closed enum" as compiled code. In the open build the candidate row is a read-only template; in the corporate build a tenant may copy it. | CANDIDATE's content (exam permissions only, no `EntitiesQuery`) becomes the candidate template unchanged; the separation from TASK_WORKER stays. |
| 0013 Consequences, last bullet ("does not settle ... whether tenant-scoped roles ever feed the same matrix") | Settled: tenant role rows feed the decision (D6). | That routing names (`RoleRegistry`, process routing) are a separate thing (D5). |
| 0046 D10 "The role set stays closed (0013, 0039 D4): a module cannot create a role." | Open build: the tenant's set stays fixed, as read-only template rows (D10), so only the form changes (data, not code). Corporate build: "stays closed" is superseded; the tenant admin edits its set through the closed editor. | "A module cannot create a role" (D6), in both editions. |
| 0046 title and D5, D6, D7 (eight built-in roles, their lists) | That they are built-in code. | D5's content becomes the rule of the protected tenant-admin row (`all_tenant_scope`, D3). D6 and D7 become template content. D1 (two scopes), D2 (platform tenant, config-pinned, fails closed), D3 (every permission has one scope), D4 (PLATFORM_ADMIN only in the platform tenant), D8 (history), D9 (deferred roles; kept by O4 a) stay. |
| 0081 header ("Amends 0046 D10") and D1 "`STOREKEEPER` is appended to `roles/0`. It is a built-in role" | "Built-in role". STOREKEEPER becomes a template row: read-only in the open build, an ordinary editable row of existing tenants in the corporate build (O1 a). | D1 "routing roles carry no permissions" (D5). D2 (grant content of the template). D3 (matrix tool rule for a new role). D4 import guard: its outcome stays; its form changes in stage 0 from the role name to a permission (slice S0-1). D5 and "Known limits" stay. D2's last bullet (a `role_grants` widening is refused until per-tenant snapshots exist): in the corporate build the tenant's editable rows are those snapshots, so the block lifts there at stage 3; in the open build it stays (D7). |
| 0084 (`0084-tenant-storekeeper-asset-grant.md`) D1 (closed add-only overlay for STOREKEEPER only; `grantable/0`) and D5 (`GET`/`PUT /tenant/role-grants`) | Corporate build only: the editor lets a tenant put `AssetsRead`/`AssetsPost` into any of its roles, and the overlay and its routes are retired there after the backfill copies each tenant's switch into its storekeeper row. | Open build: all of D1 to D5 (the switch is the open build's one per-tenant permission choice). Both builds: D2 (`Authorization` stays pure; the per-tenant input is loaded at the request edge with the caller's own prefix), the pattern stage 2 generalises; D3 (an upgrade never widens or narrows a tenant silently), kept as D7; D4 (defaults). |
| 0084 (`0084-public-signup-part-1.md`) | Nothing. Same number, unrelated subject. | All of it. |
| 0039 D4 (role_grants keys "must be in `Authorization.roles/0`") | Not named in the task; read here because 0046 D10 cites it. Its key rule reads as "must be a template key" from stage 6; until then `roles/0` is the template key list, so nothing changes. | "A module cannot create a role and cannot grant a core permission". |

## Owner decisions (D-131, corrected by D-132, 2026-11-13)

| # | Question | Decision |
|---|---|---|
| O1 | Existing tenants have seven ready-made roles besides the two admins. What happens to them? | **(a), corporate build:** they stay as ordinary roles of that tenant, which its admin may edit or remove through the closed editor. **Open build:** they stay as read-only template rows with the same permissions as today; users stay assigned; no behaviour change. |
| O2 | Does a new tenant start with only its admin, or with starter roles already created? | **(a):** a new tenant has only its own tenant-admin row. Open build: the shipped template rows are what its admin assigns users to. Corporate build: its admin copies templates into its own roles. QA and UAT seeds assign their users to template rows (open) or create their roles explicitly (corporate). |
| O3 | When a module update brings a new permission, do the tenant's own roles get it automatically? | **(a):** never (D7). |
| O4 | May the tenant admin let someone else manage roles and users? | **(a):** no delegated role management (0046 D9 stays). |
| O5 | Is "create your own roles" open or closed? | **Closed (D-132, correcting D-131's (a)):** the role editor is the closed package behind the role editor socket (D-126). The open build ships read-only template rows (D10). |
| O6 | Limits: roles per tenant, permissions per role | **No limits now.** Reminder (2026-11-13): a number is needed before the closed role editor (stage 3) is built; the editor's requirement must carry it. |

## Open points

* **OP-A, for the owner (one line).** May a tenant's own role in the corporate editor hold the three admin asset actions `AssetsReverse`,
  `AssetsReconcile`, `AssetsCardWrite` (for example a chief accountant role)? Recommendation: keep them non-assignable until the editor's
  requirement is written, then decide with it. 0084 D1 does not settle it (it only keeps them out of the storekeeper overlay); today only
  PLATFORM_ADMIN and TENANT_ADMIN hold them (golden, V). In the open build the question does not arise (no editor). Until answered they
  are non-assignable (fails closed).
* **OP-B, ruled.** The storekeeper task-list behaviour (slice S0-5) was ruled by the security reviewer in T-1850
  (`docs/design/storekeeper-task-visibility-ruling.md`: a defect; fix with one permission "read all tasks of the company" held by the five
  roles that see all tasks today). This record adds nothing to that ruling.

## Not decided here

* Any table, migration, column name or route (stages 1, 2, 4, 5, 6 and the closed editor each get a requirement and a design).
* Licence rules for the closed package, and what a corporate tenant's own roles do if its licence ends (T-1521 Q9; open-core note
  section 1.5).
* The exact names of the new permissions (working names in the slice list).
* Production, QA and demo rollout; feature flag names.

## Verified vs guess

* V: the quotes of 0013, 0039 D4, 0046 D10, 0081 and 0084 above; the code sites and golden facts named in Context and D3 to D5; the
  label and display facts of D11; the role binding and group membership routes in Context.
* G: the stage plan, the flags `protected`, `grants`, `assignable` (working names from T-1848), the claim that no site must stay a
  role-name check (T-1848 E3; re-checked here only for the stage-0 sites).
