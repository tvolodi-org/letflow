# Open core with a few closed features behind sockets (design note)

Task T-1842. Owner decision D-126 (open core, a few closed features behind sockets), as given in the task text.
Design note only: no code, no private repository, no package, nothing on QA, production, demo, secrets, money, DNS or the public repository is changed. MES work is not touched.

> **Update (T-1849, 2026-11-13): assumption A of this note is SUPERSEDED.** This note assumed the open build keeps the nine
> built-in roles and that permission-bearing custom roles come only from a closed package (section 1.6, option A, "UAT
> assumption"). Under owner principle D-129 and decision record `docs/migration/decisions/0088-permission-only-access-tenant-defined-roles.md`
> (proposed, not yet confirmed by the owner), **tenant-defined roles are the base model of the open build**, pending owner choice
> O5 of 0088 (open or closed; recommendation: open). What changes here: section 0 row 1, sections 1.2 to 1.6, the socket list of
> 1.3, section 4 and question 1 of section 7 (each marked below). Sections 2 and 3 (build layout, tests per edition, isolation and
> audit identical in both builds) stay valid. Sources: `docs/design/roles-architect-verdict.md` section E7 (T-1848),
> `docs/design/tenant-defined-roles.md` (T-1846). Migration order: `docs/design/roles-stage0-slices.md`.

Legend: **V** = verified by reading the file on this branch (2026-11-13). **G** = guess. Commands behind the facts are in section 6.

## 0. Short answer

| Question | Answer |
|---|---|
| Is a role socket possible? | Yes, but the owner's picture ("open build answers from two fixed roles") does not match the code. Today the core has **nine** built-in roles, closed by design (V). "Custom roles" today are **routing names for process tasks**, not permission sets (V). So there is a decision for the PM (section 1.6): keep nine built-ins in the open build and put only *permission-bearing custom roles* behind the socket (recommended, size M), or collapse the open build to two roles (size L, high risk). |
| (T-1849) Superseded answer | Custom permission-bearing roles become the open base model (0088, pending O5). The role socket on the access decision is dropped; closed extras sit around role management (section 1.6 note). |
| How does the closed package get in at build time? | One small private repo that depends on the open repo at a tag. The open repo never mentions it: it ships a default implementation of every socket. No submodule, no gitignore trick (section 2). |
| Do tenant isolation and audit change? | No. Both are in the core, below every socket. The sockets only answer "which permissions does this role hold" and never see a database prefix (section 3). |
| What gets simpler compared with T-1521 section 4? | The "closed module package" and "second repo" mechanics are reused as they are; what is new is that a closed feature need not be a whole module. A socket is a few lines in the core. Details in section 5. |

## 1. Socket 1: role management

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
| Custom role bindings (existing) | `POST /roles`, `Letflow.Identity.RoleRegistry.upsert_role/4`, table kind `:process_routing_role` in `lib/letflow/identity/tenant_role.ex` | A name bound to a group, used to route workflow tasks. Names equal to a built-in are refused by `builtin_role_name?/1`. It grants **no permission** (G for the "no permission" claim: I read the kind split and the guard, not every reader of the table). |
| Where roles come from at runtime | The token or stored membership gives role strings; `effective_roles/2` converts them | Group membership to role atoms happens in `lib/letflow/identity.ex` (around the `effective_roles` call). |

### 1.2 What "custom roles" would mean (V for the facts, decision for the PM)

> **Superseded in part (T-1849), also for 1.4 and 1.5.** The facts in 1.2 stay (V). What changes: custom roles are built in the open
> core, not in a closed package; the size and risk of 1.4 now belong to stages 0 to 6 of `docs/design/roles-stage0-slices.md`; the
> 1.5 rows about "a tenant that later gets the closed package" and "licence ends" apply only if O5 is answered "closed".

Today a tenant cannot define "Warehouse supervisor may do X and Y". It can only name a routing role. The nine roles and their permissions are compiled in. So a closed package that "provides custom roles" must provide **a stored role with a set of permission atoms**, and the core must accept that set at the point of `role_allows?`. Role atoms are a closed set on purpose (an atom table cannot grow from input; `roles_from_strings/1` refuses unknown strings). A custom role therefore cannot be an atom; it has to be a binary role key with its own lookup path. That is the main size driver.

### 1.3 Interface shape (proposal, G)

> **Superseded (T-1849).** No socket sits on the access decision: `resolve_roles/2`, `role_allows?/3` and `custom_roles_enabled?/1` are
> withdrawn. The decision is the most security-critical code and a replaceable implementation there adds risk with no business gain
> (T-1848 E7). The core rules listed under the table stay, as rules of the open core itself (0088 D3, D4). A closed package may
> still add *role-management extras* (see 1.6 note); the table is kept as history.

Names are working names. A behaviour with a small number of callbacks, one default module in the open repo, selected by configuration at build time (section 2).

| Callback | Input | Open build returns | Closed package returns |
|---|---|---|---|
| `role_catalog/1` | tenant prefix | the nine built-in roles (see 1.6 for the alternative of two) | built-ins plus the tenant's custom roles |
| `resolve_roles/2` | role strings, platform-tenant flag | what `effective_roles/2` returns today | same, plus custom role keys the tenant owns |
| `role_allows?/3` | role key, permission, overlay | today's `role_allows?/3` | today's answer, or the stored permission set of a custom role |
| `custom_roles_enabled?/1` | tenant prefix | `false` | `true` for a licensed tenant |
| `manage_roles/…` (route handlers for create, change, retire) | request | not mounted; the route answers 404 like an unknown route (INV-5 style) | mounted |

Rules that stay in the core and cannot be overridden by a package (each is a test in section 3): PLATFORM_ADMIN only in the platform tenant; a custom role can never contain a platform-scope permission (`permission_scope/1` check); an unknown role key grants nothing; no custom role may carry a name that `builtin_role_name?/1` refuses; every change writes an audit entry through the core audit path.

### 1.4 Size of the change (G, sizes are guesses)

| Part | Files (V for the list, G for the count) | Size |
|---|---|---|
| Behaviour module and default (open) implementation | 2 new files in `lib/letflow/api/` | S |
| Route the ~14 callers of `effective_roles/2` and the 4 callers of `role_allows?/3` through the socket | about 18 files edited, mechanical | M |
| Role keys that are not atoms: the type `role()` is used in specs across the code; custom keys need a second type and a guard in every `Enum.map` over `Authorization.roles()` (for example `routers/me.ex` iterates `Authorization.roles()`) | 10 lib files mention `PROCESS_DESIGNER`; about 594 test files mention role names or `role_allows?` (V, by grep) but most need no edit if the open build keeps atoms | M to L |
| Storage of custom roles: new tenant table, migration, tenant table list pin (`@expected_tenant_tables` in `test/support/tenant_fixture.ex`) | migration, schema, pins | M |
| Matrix golden, role charter, parity test: the golden lists the nine roles; custom roles are per tenant and must not appear in the open golden | small | S |
| **Total for the recommended shape (socket in the core, custom roles code in the closed package)** | the core part only: about 20 files, 6 to 10 test files | **M** (G) |
| Risk | **High for security**: this is the one place that decides every access. A change that is "mechanical" can still widen access. Needs the security reviewer, a cross-tenant negative test, and a before/after comparison of the full golden (must be byte identical for the open build). | |

### 1.5 What happens to existing tenants and roles

| Case | Result |
|---|---|
| Existing tenants, nine built-in roles, existing memberships | Unchanged: the open default implementation is today's code moved behind the behaviour. The golden file is byte identical before and after; that is the acceptance test. |
| Existing process-routing role bindings (`POST /roles`) | Unchanged; they are not permissions. |
| Existing tenant overlay (STOREKEEPER read and post assets) | Unchanged, still applied after the socket. |
| A tenant that later gets the closed package | Its custom roles are new rows; built-ins are not edited. |
| A tenant whose licence for the closed package ends | **Not decided here** (this is the licence-expiry question of T-1521 section 4 point 3 and Q9; it changes customer access, so it belongs to the owner). A safe default to propose: custom roles keep existing but grant nothing (fail closed), users keep sign-in, data stays readable by the built-in admin. |
| Production | Nothing is changed by this note. |

### 1.6 Decision for the PM: two roles or nine (open question)

> **Superseded (T-1849).** Neither A, B nor C: under D-129 the open build has one preinstalled platform-admin row, a tenant-admin
> row per tenant, and the nine roles of today as templates (existing tenants keep them as ordinary rows, owner choice O1 of 0088).
> Whether role creation is open or closed is owner choice O5; recommendation open. Closed-feature candidates around role
> management, not on the decision (G list, T-1848 E7 and T-1846 section 7): second-person approval of role changes, periodic
> access-review reports, audit export of role changes, limits above the open cap (O6). The paragraph and table below are kept as
> history.

The task text says the open build answers "from two fixed roles (admin, user)". The code has nine built-ins, used by 594 test files, the UAT actor roster (`test/fixtures/uat/actors.yaml`), the golden, `docs/roles.md` and the web app. Reading the owner's sentence as "the open build still ships what it has; the closed package adds custom roles" is a **UAT assumption, to be confirmed by the PM**.

| Option | What the open build offers | Size and risk (G) |
|---|---|---|
| A (recommended) | Nine built-in roles as today. The socket allows custom permission-bearing roles only from the closed package. | M, security-sensitive but no behaviour change for open users. |
| B | Open build collapses to admin and user (for example TENANT_ADMIN and TASK_WORKER) and hides the others. | L: it removes behaviour modules and tests rely on (STOREKEEPER, TENANT_AUDITOR, CANDIDATE are used by assets and exam modules), changes the golden, breaks the UAT roster. Also the exam module (closed, T-1521) needs CANDIDATE, so it would move into the closed package with its role. |
| C | Two named "simple" role presets in the open UI over the nine roles. | S, but it is a UI choice, not a socket. |

## 2. How a closed package is present at build time

### 2.1 Layout (proposal, G)

| Item | Rule |
|---|---|
| Repositories | The open repository (the product as it is). One small private repository with only the closed packages (role management first). No third repository. |
| Link | The private repo depends on the open repo **at a released tag** (a normal dependency on a git tag). The open repo has no reference to the private repo: no submodule, no ignored directory, no optional folder it looks into. T-1521 section 4 point 6 says the same. |
| Selection of the implementation | A build-time setting read in the config of the release build (for example which module implements each socket). The open default is compiled into the open repo and is used when nothing is set. The private repo sets it to its own modules in its release config. |
| Default implementation | Each socket ships with a complete working default in the open repo (section 1.3 column "open build returns"). Not a stub that fails: the open product runs and passes with it. |
| Closed to open | Allowed later (a closed feature can be opened); the reverse needs the PM. |

### 2.2 The open CI passes without the package

| Point | Detail |
|---|---|
| Open CI steps | Same required checks as today (`Backend gate (mix letflow.check)`, `Frontend gate (npm run check)`). Nothing is skipped and nothing is "optional if the folder exists". |
| Tests of the socket in the open repo | They test the **behaviour contract** against the default implementation, and a small in-test fake implementation that returns a custom role, to prove the core refuses a custom role with a platform-scope permission, an unknown key, or a cross-tenant lookup. The fake lives in `test/support` and is not shipped. |
| Golden and pins | The open golden contains only the open build (nine roles, open modules). |

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
| Upgrade of tenants | Same install and upgrade path as other module versions; a changed seed or migration is already deployed to QA by auto-CD (see the product rule), so the first socket PR must say how existing rows are handled (section 1.5: nothing changes). |

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

The sockets sit **above** data access. A socket answers a question about roles; it never receives a repository handle, a prefix to query with, or an audit writer.

| Invariant (`docs/agents/instructions/security-invariants.md`) | Why a socket cannot change it | Proof in the open build | Proof in the corporate build |
|---|---|---|---|
| INV-1 tenant isolation by schema prefix | Role lookup for custom roles takes the tenant prefix as input and is stored in the tenant's own schema; no role query runs without a prefix | Existing tenant-isolation tests; a new test that the default socket and the in-test fake read only the caller's prefix | Same tests, plus package tests that tenant A's custom role is invisible to tenant B (a cross-tenant negative test) |
| INV-2 server-side field authorisation | The core still calls the socket for every decision; no route skips it | `authorization_enforcement_test.exs`, `authorization_test.exs` (V, exist) | Same files run unchanged |
| INV-5 not found equals forbidden | The socket-managed routes answer like unknown routes when the package is absent | A new test: with the default implementation, the role management routes answer 404 | A test that a caller without permission gets the same answer as for a missing role |
| INV-6 a new data access path proves its scoping | The custom-role table is a new tenant table | Not present in the open build (no table without the package) | The package migration adds the table and its scoping proof; the tenant table list pin moves there |
| INV-10 platform authority bound to the platform tenant | `effective_roles/2` rule stays in the core and wraps the socket result | `authorization_role_realm_test.exs`, `platform_scope_authorization_test.exs` (V, exist); a new test that a fake custom role cannot gain PLATFORM_ADMIN or any platform-scope permission | Same files plus the package's own negative test |
| Audit (event store, `Audit` entries, `role.rebound` and similar) | The core audit writer is called by the core handlers; the package calls the same function, it does not bring its own | Existing audit tests | Package tests: every role create, change or retire writes the same audit entry kind with actor and reason |
| Permission matrix golden | Open golden unchanged (byte identical before and after the socket change) | `permission_matrix_test.exs` | Package golden per edition (section 2.3) |

Reviewer note: the security reviewer is mandatory for the socket PR (tenant-data path, access decisions).

## 4. Next candidate closed-feature sockets (G for all sizes)

> **Update (T-1849).** The role-management socket is no longer the first closed feature; role management is open (pending O5).
> The order below becomes: licence check first, then audit export and retention, then the identity-provider seam (T-1846 section 7,
> T-1848 E7; G). The role-management extras of the 1.6 note join the list as one more candidate.

| Candidate | What it is | Why closed | Size |
|---|---|---|---|
| Identity provider seam | One operator-configured identity provider in the open build; per-company realm and provisioner contract in the closed one | Company-scale feature; T-1521 section 4 point 4 | M to L, security review for isolation |
| Audit export and retention | Open: event store and base audit. Closed: export, longer retention, tamper evidence | Sold feature; T-1521 section 4 point 5 | M |
| Licence and feature-flag check | A check "is this feature licensed for this tenant" with an open default of "yes, for open features only" | Needed by every closed feature; expiry behaviour is an owner decision | S to M |
| Module loader for packages outside the source tree | Today modules are compiled into the build (T-1521 section 4 point 1) | Needed to ship exam, procurement and the role package as closed packages | M to L |
| Signed packages | Verify a signature over the delivered package | Needed before customers install closed packages | M |
| Sign-in extras (single sign-on mapping, extra policies) | Optional | Company-scale | S to M |

Order proposed (G): licence check first (every other socket depends on it), then the role socket, then the module loader. (Superseded by the update at the top of this section: the role socket is dropped.)

## 5. Comparison with T-1521 section 4

Found: `docs/uat/ba-decisions/T-1521.md`, section 4 "How the corporate edition is built from the community one" (V, read). No other T-1521 note was searched for beyond `docs/`; the portfolio proposals folder was not reachable from this worktree (the path `../ai-dala-portfolio` does not exist here), so portfolio text is not quoted.

| T-1521 section 4 point | This note | What becomes simpler |
|---|---|---|
| 1 Closed module packages, loader is an open design item | Role management is not a module; it is a small socket in the core plus a package | A closed feature no longer needs a whole module with its own manifest, routes and install plan |
| 4 Identity provider seam, 5 audit seam: "the same seam idea" | Same pattern, now with a concrete shape: behaviour, default in the open repo, config selects at build | The pattern is written once and reused |
| 6 Build: private repo checks out the public core at a tag | Kept; adds "no submodule, no ignored folder, the open repo never names the closed one" | Nothing in the open repo has to be hidden or filtered; the open CI has no special case |
| 7 Tests: golden and pins must be split per edition (open design item) | Made concrete in 2.3: open pins cover open things only, each package brings its own pins | A package cannot break the open CI |
| 2 and 3 Signing, licence keys | Unchanged, still open | Not simpler; the role socket should wait for the licence check or ship with "always off" |

What is **not** simpler: custom roles are not an atom set (1.2), so the socket is not free. That is the one place the owner's simple picture hides real work.

## 6. Commands behind the facts (run on this branch, 2026-11-13)

| Fact | Command |
|---|---|
| Role list, role functions, `role_allows?` clauses, `grantable/0` | `grep -n "@roles\|def roles\|def effective_roles\|def roles_from_strings\|def role_allows?\|def grantable" lib/letflow/api/authorization.ex` and reading lines 470 to 580, 695 to 770, 1826 to 1900 |
| Callers | `grep -rn "effective_roles(\|roles_from_strings(" lib --include=*.ex` and `grep -rn "role_allows?(" lib --include=*.ex` (design markdown files under `lib/letflow/design/` were filtered out) |
| Test and web spread | `grep -rln "role_allows?\|Authorization.roles()\|:TENANT_ADMIN\|TENANT_ADMIN" test` (594 files); `grep -rln "PROCESS_DESIGNER" lib web/src` (10 files) |
| Module grants | `grep -n "def role_grants" -A8 lib/letflow/modules/catalog.ex`; `grep -n "role_grants" lib/letflow/modules/module.ex` |
| Golden header | `head -12 priv/permission_matrix/effective.golden` (9 roles, 87 permissions, 783 rows) |
| Custom role bindings | reading `lib/letflow/identity/tenant_role.ex` (kinds `:platform_role`, `:process_routing_role`) and `docs/roles.md` (PROCESS_DESIGNER, `POST /roles`) |
| Auditor refused set | `grep -n "refused" test/letflow/api/authorization_tenant_auditor_test.exs` |
| T-1521 | `grep -n "^## " docs/uat/ba-decisions/T-1521.md`; reading section 4 |
| Licence | `ls LICENSE*` (none); `grep -n "T-1521" docs/open-source/README.md` |

Not verified: the exact body of `core_role_allows?/2` for each role (not read in full); `docs/open-source/audit-report.md`; any code in `web/` that lists roles; the portfolio decision record D-126 itself (only the task text was read).

## 7. Open questions for the PM

1. Two roles or nine in the open build (section 1.6)? This note assumes nine (option A). **Superseded (T-1849):** replaced by owner choices O1, O2 and O5 of decision 0088.
2. What happens to custom roles when a licence ends (section 1.5)? Same question as T-1521 Q9. (T-1849: moot if O5 is answered "open"; stays open otherwise.)
3. Order of the first two sockets: licence check before role socket (section 4)?
