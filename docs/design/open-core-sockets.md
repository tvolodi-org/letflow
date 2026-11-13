# Open core with a few closed features behind sockets (design note)

Task T-1842. Owner decision D-126 (open core, a few closed features behind sockets), as given in the task text. Updated by T-1849
and T-1851 for decision record `docs/migration/decisions/0088-permission-only-access-tenant-defined-roles.md` (ACCEPTED by the owner,
D-131, corrected by D-132, 2026-11-13).
Design note only: no code, no private repository, no package, nothing on QA, production, demo, secrets, money, DNS or the public repository is changed. MES work is not touched.

> **Decided (D-131, D-132; T-1851).** Access is checked against permissions only, and roles are data (0088 D1, D6). The **open build**
> ships the ready-made roles as **read-only template rows**: the tenant admin assigns users to them and cannot create, copy, edit or
> replace a role. The **role editor** (create, copy, edit, replace roles: stage 3 of `docs/design/roles-stage0-slices.md`, its routes and
> screens) is the **first closed feature**, behind the role editor socket of section 1.3. No socket sits on the access decision itself.
> Custom roles are not part of the open build. Sections 2 and 3 (build layout, tests per edition, isolation and audit identical in both
> builds) are T-1842's and stay. The list of further closed candidates is in `docs/design/open-core-closed-candidates.md`.

Legend: **V** = verified by reading the file on this branch (2026-11-13). **G** = guess. Commands behind the facts are in section 6.

## 0. Short answer

| Question | Answer |
|---|---|
| Is there a role socket? | Yes: the **role editor socket** (section 1.3). The open build answers it with "no editor": the tenant's roles are the read-only template rows. The closed package plugs in the editor. The access decision (`role_allows?`, `evaluate_access/2`) has no socket and is the same code in both builds (0088 D10). |
| What does an open-build tenant get? | The two protected admin rows and the seven ready-made roles (process designer, process operator, task worker, agent runner, candidate, auditor, storekeeper) as read-only template rows, with today's permissions and today's way of assigning users. No behaviour change for an existing tenant. |
| How does the closed package get in at build time? | One small private repo that depends on the open repo at a tag. The open repo never mentions it: it ships a default implementation of every socket. No submodule, no gitignore trick (section 2). |
| Do tenant isolation and audit change? | No. Both are in the core, below every socket. The role editor writes only through the core role write path, which keeps tenant prefix, escalation rules and audit (section 3). |
| What gets simpler compared with T-1521 section 4? | The "closed module package" and "second repo" mechanics are reused as they are; what is new is that a closed feature need not be a whole module. A socket is a few lines in the core. Details in section 5. |

## 1. Socket 1: the role editor

### 1.1 Where the core checks permissions today (V)

| What | Where | Note |
|---|---|---|
| The closed role list (nine atoms) | `@roles` and `roles/0` in `lib/letflow/api/authorization.ex` | PLATFORM_ADMIN, PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, AGENT_RUNNER, CANDIDATE, TENANT_ADMIN, TENANT_AUDITOR, STOREKEEPER |
| Text to atom conversion of a role string | `roles_from_strings/1` | An unknown string is dropped, never widened (fails closed). The comment says `String.to_existing_atom` is deliberately not used. |
| The one shared role resolution | `effective_roles/2` | Removes PLATFORM_ADMIN outside the platform tenant. Called from about 14 places (`plugs/authorize.ex`, `api/scope.ex`, `identity.ex`, `ledger/authority.ex`, `routers/me.ex`, `routers/instances.ex`, `routers/identity.ex`, `routers/script_rules.ex`, `routers/tenant_modules.ex`, `modules/procurement/router.ex`, `definitions/activator.ex`, `scheduler/scheduled_job_sweep.ex`, plus `roles_from_strings` in `record_import.ex`, `record_triggers/runner.ex`, `platform_tenant.ex`). |
| Role to permission mapping | `role_allows?/2` (three always-true clauses, then core mapping `core_role_allows?/2` or module grants `Catalog.role_grants/1`) and `role_allows?/3` (adds the tenant overlay) | `role_allows?/3` is called from `api/scope.ex`, `api/module_guard.ex`, `ledger.ex`, `ledger/authority.ex` |
| Module permission sets | `permissions:` and `role_grants:` in each module manifest (`lib/letflow/modules/module.ex`), read by `Catalog.role_grants/1` in `lib/letflow/modules/catalog.ex` | The role keys in `role_grants` are the nine atoms. |
| Per-tenant add-only grants | `grantable/0`, `sanitize_overlay/1` | Closed constant: only STOREKEEPER may get `:AssetsRead` and `:AssetsPost`. |
| Route to permission | `endpoint_policy_key/2` (a long list of clauses) and `evaluate_access/2` in `authorization.ex` | Not role related; stays in the core. |
| Role charter | `docs/roles.md` (nine roles; says "The set is closed: a module cannot create a role", decision 0046 D10) | Parity test: `test/letflow/api/roles_matrix_parity_test.exs`. |
| Permission matrix golden | `priv/permission_matrix/effective.golden` (header: 9 roles, 87 permissions, 783 rows, module versions in the header) | Regenerated with `mix letflow.permission_matrix --write`; code in `lib/letflow/api/permission_matrix.ex`. Test: `test/letflow/api/permission_matrix_test.exs`. |
| Tenant-auditor refused set | `@auditor_refused_core` in `test/letflow/api/authorization_tenant_auditor_test.exs` (a literal list that partitions `core_permissions/0`) | Any new core permission moves it. |
| Process-routing role bindings (existing; not permission roles) | `POST /roles`, `Letflow.Identity.RoleRegistry.upsert_role/4`, table kind `:process_routing_role` in `lib/letflow/identity/tenant_role.ex` | A name bound to a group, used to route workflow tasks. Names equal to a built-in are refused by `builtin_role_name?/1`. It grants **no permission** (G for the "no permission" claim: I read the kind split and the guard, not every reader of the table). |
| Where roles come from at runtime | The token or stored membership gives role strings; `effective_roles/2` converts them | Group membership to role atoms happens in `lib/letflow/identity.ex` (around the `effective_roles` call). |

### 1.2 What the two editions offer (decided, 0088 D10)

| | Open build | Corporate build (closed role editor package) |
|---|---|---|
| Role rows of a tenant | Two protected admin rows (platform admin in the platform tenant only; tenant admin per tenant) and seven read-only template rows | The same, plus the tenant's own roles; existing tenants keep their seven roles as ordinary editable rows (0088 O1 a) |
| Who writes role rows | Only platform code: provisioning and the stage 1 backfill | Platform code, and the tenant admin through the editor, always through the core role write path |
| Assigning users to roles | Yes, as today: a role is bound to a group (`tenant_role` kind `:platform_role`) and users are members of that group (`POST /groups/:id/members`, `GroupsManage`, `lib/letflow/routers/identity.ex`, V) | Same |
| Create, copy, edit, replace, retire a role | No | Yes (stage 3) |
| Storekeeper asset switch (0084, `GET`/`PUT /tenant/role-grants`) | Stays: it is today's behaviour | Retired once the editor has copied each tenant's switch into its storekeeper row |
| Access decision | Permission-only (0088 D1 to D5) | Identical code |
| Names of the template rows | Today's labels (0088 D11) | Same for templates; own roles carry the names the tenant gives them |

Why this is no behaviour change for open-build tenants: the read-only rows hold exactly what `core_role_allows?/2` and the manifests'
`role_grants` compile in today (0088 D6), and assignment works as today. The 0088 stage 0 to 2 proofs (golden rows byte identical, shadow
equality per tenant) apply to the open build unchanged.

### 1.3 The role editor socket (interface; working names are G)

A behaviour with three callbacks, one default module in the open repo, the implementation chosen by build configuration (section 2).

| Part | Open build (default module) | Closed package |
|---|---|---|
| `enabled?(prefix)` | `false` for every tenant | `true` for a tenant whose licence covers the editor (the licence check is its own socket, `docs/design/open-core-closed-candidates.md`) |
| `router()` | none: the core mounts nothing at the editor's mount point, so an editor request answers 404 like an unknown route (INV-5) | the editor's plug router (stage 3 routes; paths are named in the stage 3 requirement, not here) |
| `capabilities(prefix)` | `%{role_editor: false}`: the roles screen shows the rows read-only, no create or edit controls | `%{role_editor: true}` for a licensed tenant |

Where the open build calls it, and nowhere else:
1. The API pipeline, once: the mount point of the editor router (`Letflow.Plugs.ApiPipeline`, the forward list).
2. The access answer for the web app (`GET /me/access` or its successor, stage 4): one field that tells the roles screen whether to show
   edit controls. The server still checks every editor request by permission; the field is display only.
3. Never from `Authorization`, `Scope`, `ScopeGate` or any access check.

What stays in the core and cannot be changed by the package (0088 D3, D4, D7, D9): the core role write path (a planned stage 2
function, not yet on main) is the only code that inserts or changes a role row. It takes the caller's tenant prefix (INV-1), refuses
any write to a protected row, refuses a non-assignable or platform-scope permission, never adds a new module permission by itself,
writes the audit entry in the same transaction, and keeps the last-admin guard. The editor's routes are guarded by the existing
`UsersGroupsRolesManage` permission (held by PLATFORM_ADMIN and TENANT_ADMIN only, golden V; non-assignable, 0088 D4), so the package
adds no permission of its own.

Default selection: a build-time setting (for example `config :letflow, :role_editor, <module>`); unset means the open default. The
open repo never names the closed module.

How the open CI passes without the package: the default module is complete (not a failing stub). Open tests prove (a) the editor
mount answers 404 with the default; (b) an in-test fake editor in `test/support` that writes through the core role write path is
refused for every rule above, both branches tested, and its writes stay inside the caller's tenant (cross-tenant negative test,
INV-10); (c) the access decision is the same with the default and with the fake. The fake is not shipped.

Permission-matrix golden per edition: the golden lists template and admin rows only; a tenant's own roles are data and never in a
golden. Because the editor reuses `UsersGroupsRolesManage`, the template rows' golden is byte identical in both editions. The rule of
section 2.3 stays for any later closed package that declares permissions: it brings its own golden and pins, and the open pins cover
open permissions and routes only.

### 1.4 Size (G)

| Part | Edition | Size |
|---|---|---|
| Stage 0 (role-name sites become permissions), stage 1 (role rows and backfill), stage 2 (decision reads rows; protected, grants, assignable flags; core role write path) | open | unchanged from `docs/design/roles-stage0-slices.md` |
| Socket: behaviour, default module, one mount point, one capability field, the open tests (a) to (c) above | open | S to M |
| Stage 4 (tokens, identity-provider claims, solution packs, access answer on row keys) | open; the overlay retirement part goes to the closed package | M |
| Stage 5 (read-only roles screen, `isCandidate`) | open; the UAT actor with a custom role goes to the closed package | S |
| Stage 6 (remove the compiled lists) | open | M |
| Stage 3 role editor (routes, screens, escalation and last-admin tests, O6 limits) and the overlay retirement | closed | M to L |
| Per-edition pins (section 2.3), needed before the first closed package | open, test-only | M |

Risk: the core role write path and the decision on rows are security-critical; the socket is not, because it can only call the core
write path and cannot change an access answer.

### 1.5 Existing tenants and the closed package

| Case | Result |
|---|---|
| Existing tenants, open build | Unchanged: same nine rows (two admins, seven read-only templates), same permissions, same memberships. |
| Existing process-routing role bindings (`POST /roles`) | Unchanged; they are not permissions (0088 D5). |
| Existing storekeeper asset switch | Unchanged in the open build. |
| A tenant that gets the closed package | Its seven roles become ordinary editable rows (0088 O1 a); its own roles are new rows. |
| A tenant whose licence for the closed package ends | **Not decided here** (licence-expiry question of T-1521 section 4 point 3 and Q9; it changes customer access in production, so it belongs to the owner when the licence check is designed). |
| Production | Nothing is changed by this note. |

### 1.6 Two roles or nine (T-1842's question; answered)

T-1842 asked whether the open build has two fixed roles or nine. Answered by 0088 D10: nine rows, as data (two protected admin rows
and seven read-only templates), with today's names (0088 D11). The options A, B and C of T-1842 are withdrawn.

## 2. How a closed package is present at build time

### 2.1 Layout (proposal, G)

| Item | Rule |
|---|---|
| Repositories | The open repository (the product as it is). One small private repository with only the closed packages (the role editor first, section 1.3). No third repository. |
| Link | The private repo depends on the open repo **at a released tag** (a normal dependency on a git tag). The open repo has no reference to the private repo: no submodule, no ignored directory, no optional folder it looks into. T-1521 section 4 point 6 says the same. |
| Selection of the implementation | A build-time setting read in the config of the release build (for example which module implements each socket). The open default is compiled into the open repo and is used when nothing is set. The private repo sets it to its own modules in its release config. |
| Default implementation | Each socket ships with a complete working default in the open repo (section 1.3 column "Open build (default module)"). Not a stub that fails: the open product runs and passes with it. |
| Closed to open | Allowed later (a closed feature can be opened); the reverse needs the PM. |

### 2.2 The open CI passes without the package

| Point | Detail |
|---|---|
| Open CI steps | Same required checks as today (`Backend gate (mix letflow.check)`, `Frontend gate (npm run check)`). Nothing is skipped and nothing is "optional if the folder exists". |
| Tests of the socket in the open repo | They test the **behaviour contract** against the default implementation, and a small in-test fake editor that tries to write role rows through the core role write path, to prove the core refuses a role with a non-assignable or platform-scope permission, any write to a protected row, an unknown permission key, and a write into another tenant's schema. The fake lives in `test/support` and is not shipped. |
| Golden and pins | The open golden contains only the open build (the nine template and admin rows, open modules, no editor permission). |

### 2.3 The private repo runs the same tests plus its own

| Item | Rule |
|---|---|
| Same tests | The private CI checks out the open repo at the tag, adds the closed package, and runs the open test suite unchanged. Failure of an open test in the private build is a finding about the package (it must not change core behaviour for built-in roles). |
| Per-edition pins | Today there is one golden (`priv/permission_matrix/effective.golden`) and route-count pins (`length(snapshot) == N`, `test/fixtures/route_scope/tenant_wide_default_routes.txt`, named-forward counts) that the closed package would move. Rule: **the package adds its own pin files** (its own golden and counts) and the open pins are compared on the open permission set only, so that adding closed routes never fails the open pins. The open tests need one small change: read pins through a function that lists "open" routes or permissions. T-1521 section 4 point 7 calls this "the least visible cost"; it is real work (G: M, a test-only task before the first closed package). |
| New test IDs | Each package ships its own tests in the private repo. |

### 2.4 How releases combine

| Item | Rule |
|---|---|
| Open release | A tag in the open repo, built and published as today. |
| Corporate release | The private repo's pipeline builds the open tag plus the package into one release artifact. Version is a pair: open tag and package version, written in the release name. |
| Core fixes | Land in the open repo first (T-1521 section 4 point 6). |
| Signing, licence keys | As in T-1521 section 4 points 2 and 3; not decided here. |
| Upgrade of tenants | Same install and upgrade path as other module versions; a changed seed or migration is already deployed to QA by auto-CD (see the product rule), so the first socket PR must say how existing rows are handled (section 1.5). |

### 2.5 Licence obligations (state only; the LICENSE action stays with the PM)

| Fact | Source |
|---|---|
| The owner chose MIT for the open repository. | `docs/open-source/README.md` (line about T-1521 recommending Apache-2.0 and the owner choosing MIT) |
| No `LICENSE` file exists on this branch yet. | `ls LICENSE*` returned nothing (V). |
| MIT requires keeping the copyright and permission notice in copies or substantial portions. The closed package that links to open code ships the open code under MIT, so the corporate release must carry the MIT notice for the open part. It does not have to publish the closed package. | General MIT terms (G: not legal advice). |
| MIT carries no patent grant and no trademark right. | `docs/open-source/README.md` and `TRADEMARK.draft.md` exist as drafts. |
| Third-party licences of dependencies apply in both builds. | Not audited here; `docs/open-source/audit-report.md` exists (not read for this note). |
| Contributions from outsiders to the open repo are under MIT; they cannot be pulled into the closed package under another licence without their consent. | G. |

## 3. Tenant isolation and audit stay identical in both builds

The sockets sit **above** data access. The role editor socket never receives a repository handle or an audit writer of its own; it
calls the core role write path, which takes the caller's tenant prefix and writes the audit entry.

| Invariant (`docs/agents/instructions/security-invariants.md`) | Why a socket cannot change it | Proof in the open build | Proof in the corporate build |
|---|---|---|---|
| INV-1 tenant isolation by schema prefix | Role rows live in the tenant's own schema (0088 D6); the core role write path takes the caller's prefix; no role query runs without one | Existing tenant-isolation tests; a new test that the core role write path, called by the in-test fake editor, reads and writes only the caller's prefix | Same tests, plus package tests that tenant A's own role is invisible to tenant B (a cross-tenant negative test) |
| INV-2 server-side field authorisation | The access decision has no socket; every route still asks `evaluate_access/2` | `authorization_enforcement_test.exs`, `authorization_test.exs` (V, exist) | Same files run unchanged |
| INV-5 not found equals forbidden | Without the package the editor mount answers like an unknown route | A new test: with the default module, an editor request answers 404 | A test that a caller without `UsersGroupsRolesManage` gets the same answer as for a missing role |
| INV-6 a new data access path proves its scoping | The role table is a new tenant table (stage 1, open) | Stage 1 brings the table and its scoping proof; the tenant table list pin moves there | The editor adds no table; its writes go through the stage 1 table |
| INV-10 platform authority bound to the platform tenant | The platform-tenant rule (`effective_roles/2`, later the `grants = all` row flag) stays in the core | `authorization_role_realm_test.exs`, `platform_scope_authorization_test.exs` (V, exist); a new test that the fake editor cannot put a platform-scope or non-assignable permission into any row | Same files plus the package's own negative test |
| Audit (event store, `Audit` entries, `role.rebound` and similar) | The core role write path writes the audit entry; the package calls it, it does not bring its own | Existing audit tests; a test that a backfill or provisioning write is audited | Package tests: every role create, change or retire writes the same audit entry kind with actor and reason |
| Permission matrix golden | Template and admin rows only; tenant roles are data | `permission_matrix_test.exs` | Same golden (the editor adds no permission, section 1.3) |

Reviewer note: the security reviewer is mandatory for the socket PR, the core role write path and the editor package (tenant-data
path, access rules).

## 4. Further closed-feature candidates

The role editor is candidate number 1 and the first closed feature (sections 1.2 and 1.3). The other candidates, with what each is,
why it fits closed, the open socket it needs, a size guess and what the open build keeps, are in
`docs/design/open-core-closed-candidates.md`. Two items from T-1842's list stay preconditions rather than features: the **licence and
feature-flag check** (every closed feature asks it; the editor's `enabled?/1` does) and the **module loader / signed packages** for
packages outside the source tree (T-1521 section 4 point 1). Order (G): licence check, then the role editor socket and package, then
the module loader once a second package exists.

## 5. Comparison with T-1521 section 4

Found: `docs/uat/ba-decisions/T-1521.md`, section 4 "How the corporate edition is built from the community one" (V, read). No other T-1521 note was searched for beyond `docs/`; the portfolio proposals folder was not reachable from this worktree (the path `../ai-dala-portfolio` does not exist here), so portfolio text is not quoted.

| T-1521 section 4 point | This note | What becomes simpler |
|---|---|---|
| 1 Closed module packages, loader is an open design item | The role editor is not a module; it is a small socket in the core plus a package | A closed feature no longer needs a whole module with its own manifest, routes and install plan |
| 4 Identity provider seam, 5 audit seam: "the same seam idea" | Same pattern, now with a concrete shape: behaviour, default in the open repo, config selects at build | The pattern is written once and reused |
| 6 Build: private repo checks out the public core at a tag | Kept; adds "no submodule, no ignored folder, the open repo never names the closed one" | Nothing in the open repo has to be hidden or filtered; the open CI has no special case |
| 7 Tests: golden and pins must be split per edition (open design item) | Made concrete in 2.3: open pins cover open things only, each package brings its own pins | A package cannot break the open CI |
| 2 and 3 Signing, licence keys | Unchanged, still open | Not simpler; the role editor package waits for the licence check (its `enabled?/1` asks it) |

What is **not** simpler: the editor socket is small only because the open build first turns roles into data (stages 0 to 2 of `docs/design/roles-stage0-slices.md`; role keys cannot be atoms made from input). That open work is the real cost, and it is needed in the open build anyway for the read-only template rows.

## 6. Commands behind the facts (run on this branch, 2026-11-13)

| Fact | Command |
|---|---|
| Role list, role functions, `role_allows?` clauses, `grantable/0` | `grep -n "@roles\|def roles\|def effective_roles\|def roles_from_strings\|def role_allows?\|def grantable" lib/letflow/api/authorization.ex` and reading lines 470 to 580, 695 to 770, 1826 to 1900 |
| Callers | `grep -rn "effective_roles(\|roles_from_strings(" lib --include=*.ex` and `grep -rn "role_allows?(" lib --include=*.ex` (design markdown files under `lib/letflow/design/` were filtered out) |
| Test and web spread | `grep -rln "role_allows?\|Authorization.roles()\|:TENANT_ADMIN\|TENANT_ADMIN" test` (594 files); `grep -rln "PROCESS_DESIGNER" lib web/src` (10 files) |
| Module grants | `grep -n "def role_grants" -A8 lib/letflow/modules/catalog.ex`; `grep -n "role_grants" lib/letflow/modules/module.ex` |
| Golden header | `head -12 priv/permission_matrix/effective.golden` (9 roles, 87 permissions, 783 rows) |
| Process-routing role bindings | reading `lib/letflow/identity/tenant_role.ex` (kinds `:platform_role`, `:process_routing_role`) and `docs/roles.md` (PROCESS_DESIGNER, `POST /roles`) |
| Auditor refused set | `grep -n "refused" test/letflow/api/authorization_tenant_auditor_test.exs` |
| T-1521 | `grep -n "^## " docs/uat/ba-decisions/T-1521.md`; reading section 4 |
| Licence | `ls LICENSE*` (none); `grep -n "T-1521" docs/open-source/README.md` |

| (T-1851) Holders of `UsersGroupsRolesManage` | `grep ' UsersGroupsRolesManage ' priv/permission_matrix/effective.golden` (true for PLATFORM_ADMIN and TENANT_ADMIN only) |
| (T-1851) Assignment of users to roles | `grep -n -E '"/(groups|users|roles)[^"]*"' lib/letflow/routers/identity.ex`; `grep -rn ':platform_role' lib --include=*.ex` |
| (T-1851) Web labels | read `web/src/auth/access/roleLabels.ts` (display names only) and `web/src/auth/access/access.ts` 20-32 (`isCandidate`) |
| (T-1851) Access answer route and pipeline | `grep -n '/me/access' lib/letflow/routers/me.ex`; `grep -n defmodule lib/letflow/plugs/api_pipeline.ex` |

Not verified: the exact body of `core_role_allows?/2` for each role (not read in full); `docs/open-source/audit-report.md`; the portfolio decision records D-126, D-131 and D-132 themselves (only the task text was read).

## 7. Questions for the PM

1. Two roles or nine in the open build: answered (section 1.6, 0088 D10).
2. What happens to a corporate tenant's own roles when its licence ends (section 1.5): same question as T-1521 Q9; it is asked when the
   licence check is designed, before the editor package ships.
3. Order of the first sockets: licence check, then the role editor (section 4).
