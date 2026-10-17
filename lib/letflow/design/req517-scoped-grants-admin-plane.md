# REQ-517: scoped grants admin plane (2a) and route plane (2b), org-scoped role grants stage 2 (GH #2535)

AGENT: CODE-DESIGNER. Workflow WF-02, run `WF02-REQ517-SCOPED-GRANTS-ADMIN-20261018`, step 02.
Base: `main` d206c83a8 (REQ-517/518/519 entries merged, docs only). Branch
`feature/WF02-REQ517-SCOPED-GRANTS-ADMIN-20261018`. Design only: signatures are `@spec`-shaped text,
SQL and queries are prose, no function bodies, no `.ex` blocks.

Sources read in full: `docs/requirements.yaml` REQ-517 (23 ACs, binding), REQ-518 and REQ-519
(boundaries, `depends_on`, amendment paragraphs, open questions), `gh issue view 2535 --comments`
(5 comments: optional platform flip route, `zero_tenant_wide_admins` blocking, the four carried-over
stage-1 items, two heartbeats), decision 0051 (D1-D12, Rollout 3 and 4, M2, M5, N1-N4, T1-T17,
D8 amendment of 2026-10-16), the stage-1 designs `req497-1a-...` (section 10) and
`req497-1b-allowed-flag-shadow-n1.md` (sections 1, 2, 4, 6, 9, 10, 13-17), `gh2586-permission-matrix-golden.md`
(section 1 D5-D7, D21), and the merged code: `Letflow.Api.Scope`, `.Scope.Shadow`, `Letflow.ScopeEnforcement`,
`Letflow.Identity.RoleScopeGrants`, `.RoleScopeGrant`, `.TenantAdminGuard`, `.TokenPreconditions`,
`Letflow.ScopeNodePaths`, `Letflow.Routers.TenantScopeEnforcement`, `.Identity`, `Letflow.Plugs.Authorize`,
`.AuthPipeline`, `Letflow.Api.AuthorizedRouter`, `Letflow.Api.Authorization` (policy keys,
`required_permission/1`), `Mix.Tasks.Letflow.CheckScopeNodePathsWriters`, migrations 20261014100002,
20261015025331, 20261015025332, `test/letflow/scope_node_paths/migration_test.exs`,
`test/letflow/api/scope_grants_route_walk_test.exs`, `test/letflow/supervisor/infrastructure_test.exs`,
`lib/letflow/routers/instances.ex` (attachment links), `lib/letflow/repository/attachment_links.ex`,
`docs/anti-patterns.md` (NAMEDATALEN, `@expected_tenant_tables`, grep-shaped ACs).

## Changelog

| Rev | Date (UTC) | Change |
|---|---|---|
| r0 | 2026-10-17 | Initial design, both PRs. |
| r1 | 2026-10-17 | CDV FAIL D1-D4 and SECURITY-REVIEWER design FAIL D-1 (blocker), D-2, D-3 amended: manifest anchor and exact entries (3.6.1); read signatures and owning modules (3.4.1); `route_row()`/`error()` types (4.1); test-contract sources (T-G1 fixture, enforce-denied telemetry observable, ShadowEvidence sandbox, `counts_between/3` semantics); group TENANT_ADMIN last-row refusal `last_admin_binding_row` (3.8, 3.9); flush schema binding (4.7.2); `credential` in audit payloads (3.11); gate rulings and requirement amendments (section 16). |

---

## 0. Findings against the requirement text (read first)

These are places where the AC text and the merged code disagree, or where the AC leaves a mechanism
unstated. Each has a design decision here and, where it needs a ruling, an open question in section 14.

| # | Finding | Decision |
|---|---|---|
| F1 | AC 8 `revoke_tenant_admin_grant`: deleting the tenant_wide row of the TENANT_ADMIN group never changes `Identity.count_tenant_wide_admins/1`, because `exclude_scoped_holders/2` still counts a member of a ZERO-row binding (identity.ex:1347 comment; REQ-517 OQ-4 forbids changing that count). A literal "count before and after" guard therefore can never fire for the delete. | New read `Identity.count_explicit_tenant_wide_admins/1` (section 3.9): same base query, but a group-sourced holder must have a `tenant_wide = true` TENANT_ADMIN row (user or bound group). `revoke_tenant_admin_grant` uses it; `scope_tenant_admin` keeps the existing count (its AC 8 reachability note needs the zero-row member counted BEFORE the write). OQ-1. |
| F2 | AC 5 race: the AC locks the node row FOR SHARE on the create side only. If the retire side reads `references_node?` BEFORE it locks the node row, the interleaving create-locks-node, retire-reads-no-grant, create-commits, retire-updates retires a node that now has a grant. | The retire side takes the node row `FOR NO KEY UPDATE` FIRST, then reads `references_node?` (READ COMMITTED: the read after the lock waits for and sees the committed grant). Section 3.7, lock table 3.5, test T-R3/T-R4. |
| F3 | `TenantAdminGuard.resource_type/1` has no clause for the two new actions. `refuse/4` rescues every exception and logs, so a missing clause would silently lose the audit event. | Add clauses (resource type `role_scope_grant`) and pin by a test per action (T-Z4). |
| F4 | `ScopeEnforcement.get_mode/1` guards `mode when mode in @modes` with `@modes [:off, :shadow]`. A stored `on` would make `GET /tenant/scope-enforcement` answer 500. | Split read modes (`stored_modes/0`: off, shadow, on) from settable modes (`modes/0`, unchanged `[:off, :shadow]`). Section 4.2. |
| F5 | AC 15 names only the REQ-497 AC15 route walk. `test/letflow/api/scope_grants_route_walk_test.exs` also pins, statically, T-RW1b (public function list of `RoleScopeGrants` is exactly the six writers plus readers) and T-RW1c (no public function takes `scope_node_id`, no `tenant_wide: false`). Both fail by construction after 2a. | They are edited in 2a with the walk (section 3.15), listed in the PR body. |
| F6 | AC 17 says "unclassified route fails the walk" and also "routes carry the default `:tenant_wide`". If the macro default is `:tenant_wide`, nothing can ever be unclassified. | Classification has three sources (declared option, key table, default). A default-sourced route is legal only if it is on a committed snapshot list; a default-sourced route NOT on the list fails the walk. Runtime treats the default exactly as `:tenant_wide` (fail closed, AC 19). Section 4.1. |
| F7 | `Letflow.Supervisor.Infrastructure` has a test pinning exactly 24 children (infrastructure_test.exs:136). The flush process of AC 22 is a 25th. | Test edited in 2b and listed in the PR body. Section 4.7. |
| F8 | `Audit.list_entries/1` has no `action` filter (params: from, to, actor_id, resource_id, resource_type, cursor). D8 amendment rule 3 asks for "the audit listing and any action filter". | The test uses `resource_type`/`resource_id` filters and the HTTP `GET /audit` mapping, and asserts that no `action` key exists in `list_params()` at implementation time (if one has appeared, it is exercised too). |
| F9 | AC 12 names the actor class "interactive user (credential `:oidc`)". `Scope.require_tenant_wide/2` alone lets a token principal through (`{:allow, :token}`). | The service-principal route checks `auth_context.credential == :oidc` BEFORE `require_tenant_wide/2`, and the holder must be a TENANT_ADMIN role holder (not a platform-tenant PLATFORM_ADMIN). OQ-4. |
| F10 | Under `on` (2b), `/me/*`, `/help` and other self-service routes carry no class that lets a scoped-only user through; the four classes of AC 17 do not include one. | Not invented here. They stay `:tenant_wide` (403 for a scoped-only caller in `on`), are listed in the PR body, and OQ-3 asks for a follow-up class. |

---

## 1. PR split and boundary

Order is fixed: 2a, then 2b. Each is independently mergeable and green on its own diff.

| | PR 2a: grant admin plane | PR 2b: route plane |
|---|---|---|
| Behavior change for a tenant that creates no scoped row | none, except AC 10 (a caller adding THEMSELVES to a group is refused) | none in `off`/`shadow` HTTP responses; shadow OBSERVATION changes (declared class, persisted counters); one new audit row per attachment link issue (all modes) |
| New routes | 5 (AC 1) | 0 |
| Migrations | 2 tenant-scoped: FK on `scope_node_id`; `users.admin_flagged_service_principal` | 2: public `tenants` CHECK widened to off/shadow/on; tenant-scoped `scope_shadow_counters` |
| New processes | none | `Letflow.Api.Scope.ShadowEvidence` (GenServer + ETS) under `Letflow.Supervisor.Infrastructure` |
| Depends on the other | none | needs 2a's routes and policy keys (the admin-plane key table names them) |
| Dead code while no tenant is `on` | none | the `on` branch of `Authorize` (nothing can set `on` until REQ-519); the retired-node rule of `Scope.allowed?/3` (no caller passes `{:node, _}` until REQ-518) |
| Not in either PR | data path, tasks, flip, scoped binding writers (REQ-518, REQ-519) | same |

2a does not touch `Authorize`, `AuthPipeline`, `Tenant` or the shadow observer. 2b does not touch any grant
write function, the guard, the mint check or the identity router. The files both PRs edit are
`lib/letflow/scope_node_paths.ex` (2a: retire guard and share-lock read; 2b: `resolve/2`; different functions) and
`lib/letflow/tenant_provisioning.ex` (manifest, one entry each). `lib/letflow/api/authorization.ex` and
`test/letflow/api/scope_grants_route_walk_test.exs` are 2a only. 2b needs from 2a only the three policy keys
(named in 2b's admin-plane key table, whose completeness test fails if one is missing) and the routes themselves
(the AC 18 table is generated from the route table). 2a alone is green because nothing in it reads a route class,
and 2b alone cannot exist because the key table names 2a's keys, hence the fixed order.

---

## 2. Decision summary

| # | Decision |
|---|---|
| D1 | Grant routes live in a new router `Letflow.Routers.TenantRoleScopeGrants` mounted at `/tenant/role-scope-grants`; the service-principal route is added to `Letflow.Routers.Identity` as `PUT /users/:id/service-principal`. Handlers are thin: parse, call the service, map errors. |
| D2 | The write logic is the new service `Letflow.Identity.ScopedGrants` (not on the writer allowlist). Table access happens ONLY through new functions in `Letflow.Identity.RoleScopeGrants` (on the allowlist), so the AC 14 scan and T-RW1a stay true. |
| D3 | Every grant write is one transaction that takes the tenant admin lock A first. This serialises every grant writer of a tenant with every binding writer, which is what makes "last scoped row" and "tenant_wide vs scoped" race-free. |
| D4 | No new permission atom, no `role_allows?/2` change: the three new policy keys map to the existing `:UsersGroupsRolesManage`. The effective-permission golden is unchanged (section 12). |
| D5 | The admin-flagged service principal is a boolean column on the tenant `users` table, written by exactly one module (`Letflow.Identity.ServicePrincipal`), read by the mint check and the token-precondition listing. It relaxes only the target side of `check_roles_held`. |
| D6 | Route class is a declared option on the `authz_*` macros plus a table keyed by policy key for the admin plane; `__authz_routes__/0` keeps its 3-tuple shape; a second accumulator carries the options. |
| D7 | `Authorize` enforces under `on` only for `:admin_plane`, `:tenant_wide` and default-sourced routes, by `Scope.allowed?(principal, permission, :tenant_wide)`; `{:resolver, _}` and `:filter` pass through. |
| D8 | Shadow evidence is an ETS counter family keyed by tenant prefix, UTC day and metric, flushed by a GenServer every 30 s into a tenant table; never on the request path. |
| D9 | Attachment-link routes are explicitly declared `:tenant_wide` and pinned by a route-walk rule; issuing writes `attachment_link.issued` before the response and fails closed. |

---

# PART A: PR 2a, grant admin plane

## 3.1 Module map (2a)

| File | New / changed | Content |
|---|---|---|
| `lib/letflow/routers/tenant_role_scope_grants.ex` | new | `Letflow.Routers.TenantRoleScopeGrants`, four routes (AC 1 a-d) |
| `lib/letflow/routers/identity.ex` | changed | + `PUT /users/:id/service-principal`; `POST /groups/:id/members` passes `refuse_self_add: true` and maps `:self_grant_refused` |
| `lib/letflow/plugs/api_pipeline.ex` | changed | + `forward("/tenant/role-scope-grants", to: Letflow.Routers.TenantRoleScopeGrants)` |
| `lib/letflow/identity/scoped_grants.ex` | new | `Letflow.Identity.ScopedGrants`: parse, validate, transaction, guard, audit |
| `lib/letflow/identity/role_scope_grants.ex` | changed | + low-level writers and readers (3.4) |
| `lib/letflow/identity/role_scope_grant.ex` | changed | `foreign_key_constraint(:scope_node_id, name: :role_scope_grants_scope_node_id_fkey)` on `changeset/2`; moduledoc "no FK in 1a" sentence replaced |
| `lib/letflow/identity/service_principal.ex` | new | `Letflow.Identity.ServicePrincipal`, the only writer of the flag column |
| `lib/letflow/identity/user.ex` | changed | + `field(:admin_flagged_service_principal, :boolean, default: false)`; in NO cast list |
| `lib/letflow/identity.ex` | changed | `check_roles_held` target-flag rule; `count_explicit_tenant_wide_admins/1`; `add_group_member/3` option `:refuse_self_add`; `list_tokens/1` + `owner_flagged` |
| `lib/letflow/identity/tenant_admin_guard.ex` | changed | + actions `scope_tenant_admin`, `revoke_tenant_admin_grant`; counter option |
| `lib/letflow/identity/token_preconditions.ex` | changed | + category `service_principal_owner` |
| `lib/letflow/routers/tenant_scope_enforcement.ex` | changed | token-preconditions body shows the new information category |
| `lib/letflow/scope_node_paths.ex` | changed | retire guard, `lock_active_node_for_share!/2`, moduledoc lock sentence (`resolve/2` is a 2b addition, section 4.4) |
| `lib/letflow/api/authorization.ex` | changed | + 3 policy keys, `endpoint_policy_key/2` clauses, `required_permission/1` clause |
| `lib/mix/tasks/letflow.check_role_scope_grants_writers.ex` | new | AC 14 |
| `mix.exs` | changed | `@check_static_steps` + the new task, next to `letflow.check_scope_node_paths_writers` (mix.exs:172) |
| `lib/letflow/tenant_provisioning.ex` | changed | manifest + 2 entries; the count sentence in the moduledoc |
| `priv/repo/migrations/20261018100001_add_scope_node_fkey_to_role_scope_grants.exs` | new | AC 3 |
| `priv/repo/migrations/20261018100002_add_admin_flagged_service_principal_to_users.exs` | new | AC 12 |

`ScopeNodePaths.resolve/2` is a 2b addition (section 4.4); 2a adds only the retire guard and the share-lock
read. Both PRs edit `scope_node_paths.ex` in different functions, so 2b rebases cleanly.

## 3.2 Route inventory (AC 1: the ONE place)

All five are admin-plane. Tenant comes only from `auth_context.tenant_id` and `scoped_opts[:prefix]`
(no tenant segment, no tenant body field, INV-1). Request bodies are parsed field by field; any key outside
the listed set is `invalid_body`. Response bodies are built field by field (INV-2).

Common gate, in this order, for every route: (1) the unchanged plug check of the policy key (403);
(2) the handler calls `Scope.require_tenant_wide(conn, :UsersGroupsRolesManage)` and answers the same
uniform 403 `insufficient permissions` on `{:error, _, :not_tenant_wide}` (a scoped-only holder, a holder
of the permission but not the role tenant-wide). Route (e) adds the credential and role rule of section 3.12.

| Route | Policy key | Permission (via `required_permission/1`) | Body / query | Success | Errors |
|---|---|---|---|---|---|
| (a) `POST /tenant/role-scope-grants` | `:RoleScopeGrantsManage` | `:UsersGroupsRolesManage` | `{principal_type: "user"\|"group", principal_id: uuid-string, role: string, scope_node_id: string}`; exactly these four keys | 201 `{id, principal_type, principal_id, role, scope_node_id, tenant_wide: false, effective}` | 403; 409 `grant_exists`, `tenant_wide_row_exists`, `self_grant_refused`, `last_tenant_wide_admin`; 422 `invalid_role`, `invalid_principal`, `invalid_scope_node`, `no_binding`, `invalid_body` |
| (b) `GET /tenant/role-scope-grants` | `:RoleScopeGrantsRead` | same | query `principal_type`, `principal_id`, `role`, `limit` (1..200, default 50), `cursor` | 200 `Pagination.page_response(items, next_cursor)`, each item the (a) shape; tenant_wide rows have `tenant_wide: true`, `scope_node_id: null` | 403; 422 `invalid_principal`, `invalid_role` for a bad filter value; 400 `invalid limit`, `invalid cursor` (designer addition, mirrors the group-members list) |
| (c) `DELETE /tenant/role-scope-grants/:id` | `:RoleScopeGrantsManage` | same | none | 204, empty | 403; 404 `not_found` (unknown id, and an id that is not a UUID); 409 `last_scoped_row`, `last_admin_binding_row`, `last_tenant_wide_admin` |
| (d) `POST /tenant/role-scope-grants/make-tenant-wide` | `:RoleScopeGrantsManage` | same | `{principal_type, principal_id, role}`; exactly these three keys | 200 `{id, tenant_wide: true, removed_scoped_ids: [uuid]}` (sorted) | 403; 409 `tenant_wide_row_exists`, `self_grant_refused`; 422 `invalid_role`, `invalid_principal`, `no_binding`, `invalid_body` |
| (e) `PUT /users/:id/service-principal` | `:ServicePrincipalManage` | same | `{flagged: boolean, reason: string}`; exactly these two keys | 200 `{user_id, admin_flagged_service_principal}` | 403 (uniform: not an interactive TENANT_ADMIN holder tenant-wide); 404 `not_found` (unknown user, non-UUID id); 422 `invalid_body` (missing or non-boolean `flagged`, extra key), `reason_required` (missing, non-string or blank after trim), `invalid_reason` (designer addition: fails `Letflow.Audit.Reason`, control or format characters, over 500 codepoints) |

Notes: `effective` is `true` when the row currently applies to someone: a `group` row whose group is bound to the
role as a `:platform_role`; a `user` row whose user is a member of a group bound to the role as a
`:platform_role`. A `user` row for a role the user does not hold through a group is accepted with
`effective: false` (D1 "no effect"). `409` bodies carry the stable code in `detail` (`Response.conflict/2`).
There is no PATCH and no PUT on a grant row (a scoped row's node is never edited; delete and create).
`mix letflow.permission_matrix --check` is unchanged (section 12).

## 3.3 Validation order and error mapping (create, make-tenant-wide)

Pure steps first (`ScopedGrants.parse_create/1`, `parse_make_tenant_wide/1`; no DB), then one transaction:

| Step | Check | Error |
|---|---|---|
| 1 | body is a map; keys exactly the allowed set; types (strings) | 422 `invalid_body` |
| 2 | `role` is a member of `Authorization.roles/0` as a string and is not `"PLATFORM_ADMIN"`; a routing-role name is not in the closed set | 422 `invalid_role` |
| 3 | `principal_type` in `{"user","group"}`; `principal_id` casts as UUID | 422 `invalid_principal` |
| 4 | lock A; (role is `"TENANT_ADMIN"`) lock R | (none) |
| 5 | principal exists (users / groups row); for `group`: a `tenant_role` row with `group_id`, `name == role`, `kind == :platform_role` exists | 422 `invalid_principal` / `no_binding` |
| 6 | create only: `ScopeNodePaths.lock_active_node_for_share!(scope_node_id, prefix)`; not found, retired or malformed id | 422 `invalid_scope_node` |
| 7 | self-grant: principal is the caller, or a group the caller is a member of | 409 `self_grant_refused` (+ audit in its own transaction after rollback) |
| 8 | create: a `tenant_wide` row exists for (principal, role) | 409 `tenant_wide_row_exists` |
| 9 | create: the scoped row exists | 409 `grant_exists` |
| 10 | create, role TA: `before = Identity.count_tenant_wide_admins/1`; insert; `TenantAdminGuard.ensure_admins_remain!(prefix, :scope_tenant_admin, principal_id, before)` | 409 `last_tenant_wide_admin` (+ `tenant_admin.guard_refused` in its own transaction) |
| 11 | audit `grant.created` in the same transaction | rollback, 500 on audit failure |

**Delete mapping (route c):** unknown id -> 404 `not_found`; sole remaining row of (principal, role) and scoped -> 409 `last_scoped_row`; sole remaining row of a GROUP principal's TENANT_ADMIN set and tenant_wide -> 409 `last_admin_binding_row`; TA guard transition -> 409 `last_tenant_wide_admin`; audit failure -> 500.

make-tenant-wide: steps 1-5, 7 (it widens), then: `tenant_wide_row_exists` when the tenant_wide row exists (409);
otherwise delete every scoped row of (principal, role), insert ONE tenant_wide row, audit
`grant.made_tenant_wide` (lists the removed ids). No guard (it never reduces counted admins; a scoped-only
admin becomes counted). A principal with zero rows becomes tenant-wide by this explicit act (the documented
repair of the zero-row state); `removed_scoped_ids` is `[]`.

Steps 7-9 order is deliberate: self-grant is evaluated before state-revealing conflicts so the audit entry
records the attempt whatever the state. A DB error anywhere raises into `{:error, {:transaction_failed, e}}`
and 500 (INV-8).

## 3.4 Services and low-level functions (signatures)

`Letflow.Identity.ScopedGrants` (orchestration; it never touches `role_scope_grants` directly, every access to that table goes through `RoleScopeGrants`; its reads of the identity tables go through the `Letflow.Identity` read functions of 3.4.1, and it takes locks through `Identity.lock_tenant_admins!/1`, `TenantAdminGuard.lock_admin_binding!/1` and `ScopeNodePaths.lock_active_node_for_share!/2`):

```
@type principal_type :: :user | :group
@type actor :: %{user_id: Ecto.UUID.t(), trace_id: String.t() | nil}
@type grant_view :: %{id: Ecto.UUID.t(), principal_type: principal_type(), principal_id: Ecto.UUID.t(),
                      role: String.t(), scope_node_id: String.t() | nil, tenant_wide: boolean(), effective: boolean()}
@type write_error :: :invalid_body | :invalid_role | :invalid_principal | :no_binding | :invalid_scope_node
                   | :tenant_wide_row_exists | :grant_exists | :self_grant_refused | :last_scoped_row | :last_admin_binding_row
                   | :last_tenant_wide_admin | :not_found | {:audit_failed, term()}
                   | {:transaction_failed, Exception.t()}

parse_create(body :: term())            :: {:ok, map()} | {:error, :invalid_body | :invalid_role | :invalid_principal}
parse_make_tenant_wide(body :: term())  :: {:ok, map()} | {:error, :invalid_body | :invalid_role | :invalid_principal}
create(attrs :: map(), actor(), prefix :: String.t())            :: {:ok, grant_view()} | {:error, write_error()}
delete(row_id :: String.t(), actor(), prefix :: String.t())      :: :ok | {:error, write_error()}
make_tenant_wide(attrs :: map(), actor(), prefix :: String.t())  :: {:ok, %{id: Ecto.UUID.t(), removed_scoped_ids: [Ecto.UUID.t()]}} | {:error, write_error()}
list(filters :: map(), limit :: pos_integer(), cursor :: term() | nil, prefix :: String.t())
                                                                 :: {:ok, %{items: [grant_view()], next_cursor: String.t() | nil}} | {:error, :invalid_role | :invalid_principal | :invalid_cursor}
```

`create/3`, `delete/3`, `make_tenant_wide/3` open the transaction (`Repo.transaction(..., prefix: prefix)`),
take lock A as the FIRST statement, and return refusals as `Repo.rollback/1` values; after the transaction
returned, `{:error, :last_tenant_wide_admin}` goes through `TenantAdminGuard.refuse/3` and
`{:error, :self_grant_refused}` through `ScopedGrants.record_self_grant_refused/3` (own transaction, never
raises, constant log line on failure, no ids, same shape as `refuse/4`).

New functions in `Letflow.Identity.RoleScopeGrants` (the only module that touches the table, all with an
explicit `prefix`, all values bound):

```
# writers: raise ArgumentError outside a transaction (same rule as the 1a writers)
insert_scoped(principal_type, principal_id, role, scope_node_id, prefix)
    :: {:ok, RoleScopeGrant.t()} | {:error, :grant_exists | :invalid_scope_node}
insert_tenant_wide(principal_type, principal_id, role, prefix)
    :: {:ok, RoleScopeGrant.t()} | {:error, :tenant_wide_row_exists}
delete_row!(row_id, prefix)                                   :: :ok
delete_scoped_rows!(principal_type, principal_id, role, prefix) :: [Ecto.UUID.t()]   # sorted ids removed

# readers (plain reads; inside a transaction they see its own writes)
get_row(row_id, prefix)                                       :: RoleScopeGrant.t() | nil
rows_for(principal_type, principal_id, role, prefix)          :: [RoleScopeGrant.t()]
references_node?(node_id, prefix)                             :: boolean()          # AC 5
list_page(filters, limit, after_key, prefix)
    :: %{rows: [%{row: RoleScopeGrant.t(), effective: boolean()}], next_key: {DateTime.t(), Ecto.UUID.t()} | nil}
```

### 3.4.1 Read signatures and owning modules (steps 5, 7 of 3.3 and the `effective` flag)

All plain reads, explicit `prefix` (INV-1), every value bound (INV-7); inside a transaction they see its own writes.

```
# Letflow.Identity (owner of the users, groups, group_members and tenant_role reads)
user_exists?(user_id :: Ecto.UUID.t(), prefix :: String.t())                          :: boolean()   # users row
group_exists?(group_id :: Ecto.UUID.t(), prefix :: String.t())                        :: boolean()   # groups row
group_bound_to_platform_role?(group_id :: Ecto.UUID.t(), role :: String.t(), prefix)  :: boolean()   # tenant_role: group_id, name == role, kind == :platform_role
group_member?(group_id :: Ecto.UUID.t(), user_id :: Ecto.UUID.t(), prefix)            :: boolean()   # group_members row (self-grant: caller in the group)
user_holds_role_through_group?(user_id :: Ecto.UUID.t(), role :: String.t(), prefix)  :: boolean()   # member of a group bound to role as :platform_role

# Letflow.Identity.RoleScopeGrants (the grants module)
effective?(principal_type :: :user | :group, principal_id :: Ecto.UUID.t(), role :: String.t(), prefix) :: boolean()
    # group: the group_bound_to_platform_role? shape; user: the user_holds_role_through_group? shape. Used for the 201 body
    # of create and the make-tenant-wide path; list_page/4 computes the same predicate in SQL (two exists subqueries), no N+1
```

Mapping to 3.3: step 5 uses `user_exists?/2`, `group_exists?/2`, `group_bound_to_platform_role?/3`; step 7 uses
`group_member?/3` (caller membership) and compares the caller id for a user principal; the response `effective`
uses `RoleScopeGrants.effective?/4`. The five Identity functions are new public read-only functions in
`lib/letflow/identity.ex`; the single-writer scan is unaffected (they read other tables).

`insert_scoped/5` builds the row through `RoleScopeGrant.changeset/2` (`tenant_wide: false`) and maps the
constraint names `role_scope_grants_scoped_uniq` to `:grant_exists` and `role_scope_grants_scope_node_id_fkey`
to `:invalid_scope_node`; a Postgres constraint error aborts the surrounding transaction, which is fine because
every caller rolls back on an error. The pre-checks of steps 8-9 give the deterministic codes; the constraints
are the race backstop (unreachable while lock A is held).

`list_page/4` orders by `(inserted_at, id)` ascending, `limit + 1` rows, filters are bound parameters,
`effective` is two `exists` subqueries in the same select (group: bound `:platform_role` binding; user:
member of a group bound to the role), so there is no N+1. The router encodes `next_key` with the same
`Pagination` helpers as `list_group_members/3` (cursor prefix `RG:`, expiry slot at mint time).

## 3.5 Lock order (2a)

Ranks, extending 1b section 10: **A** tenant admin advisory lock < **R** TENANT_ADMIN `tenant_role` row
(`FOR UPDATE`, `TenantAdminGuard.lock_admin_binding!/1`) < **G** group row < **N** `scope_node_paths` node row
< **B** business rows (`role_scope_grants`, `users`, `group_members`) < **T** `tenants` row (flip only) <
**S** `scope_node_paths` table lock (tree writers, flip) < **C** audit chain.

| Operation | Order |
|---|---|
| create | A; R (role TA only); N (`FOR SHARE`, re-read `retired_at`); reads of principal/binding/rows; before-count; insert (B); guard count; audit (C) |
| delete | A; read row; R (row.role TA only); before-count (explicit, tenant_wide row of TA); delete (B); guard count; audit (C) |
| make-tenant-wide | A; reads; delete scoped rows, insert tenant_wide row (B); audit (C) |
| service-principal flag | A; user row `FOR UPDATE` (B); update; audit (C) |
| mint (unchanged) | A; users `FOR SHARE` (B) ...; the flag is read from that locked row |
| retire (tree writer) | S (`ScopeNodePaths.write/2` table lock); N (`FOR NO KEY UPDATE` on the node row); `references_node?` (plain read); update; no A, no audit inside `write/2` |
| move (tree writer) | S; row updates of the subtree (N rows); no A |

Why this is deadlock-free: no path takes N and then A, R, G or S; no path takes S after N; creators hold at most
A, R and one N share lock while they wait on a retire/move that holds S and N rows and waits for nothing the
creator holds (retire/move take no A, R, G, B locks). The Postgres lock modes also matter: `FOR SHARE` on the node
row takes a `ROW SHARE` table lock, which does not conflict with S (`SHARE ROW EXCLUSIVE`), so a grant create is
not blocked by the flip's tree lock; the flip is serialised against grant writers by A (flip takes A first).
The FK's own `FOR KEY SHARE` is compatible with the retire's `FOR NO KEY UPDATE` (retire changes `retired_at`,
not the key), so the FK alone would NOT serialise create and retire; the explicit locks above do (finding F2).
`Letflow.ScopeNodePaths`'s moduledoc gets one sentence: "a grant writer holds A and a node share lock; a tree
writer never takes A".

## 3.6 Migrations (2a)

### 3.6.1 FK (AC 3): `20261018100001_add_scope_node_fkey_to_role_scope_grants.exs`

| Item | Shape |
|---|---|
| Placement | tenant-scoped, `if prefix() do` guard (mandatory), registered in `@tenant_scoped_migration_manifest` (tenant_provisioning.ex:706) AFTER the last existing entry `{20_261_016_120_001, Letflow.Repo.Migrations.AllowExamManagedByStamp, ...}`. (`20261017100001` is the GLOBAL catalog endpoint guard, deliberately not in the manifest; it is not an anchor.) Exact entries added by 2a: `{20_261_018_100_001, Letflow.Repo.Migrations.AddScopeNodeFkeyToRoleScopeGrants, "20261018100001_add_scope_node_fkey_to_role_scope_grants.exs"}` and `{20_261_018_100_002, Letflow.Repo.Migrations.AddAdminFlaggedServicePrincipalToUsers, "20261018100002_add_admin_flagged_service_principal_to_users.exs"}`. 2b adds exactly one: `{20_261_018_200_002, Letflow.Repo.Migrations.CreateScopeShadowCounters, "20261018200002_create_scope_shadow_counters.exs"}`; the public `20261018200001_widen_tenants_scope_enforcement_check.exs` is NOT registered (not tenant-scoped). Moduledoc counts updated |
| Step 0 | take lock A first (`Identity.tenant_admin_lock_key/1`, bound parameter), as migration 20261015025331 does |
| Step 1 | frozen SQL precheck (not a call into application code): count of rows with `scope_node_id IS NOT NULL` and no `scope_node_paths.node_id` equal to it; if non-zero, raise `RuntimeError` with prefix `"role_scope_grants fk precheck:"` and the COUNT only (INV-4), aborting the migration |
| Step 2 | `ALTER TABLE "<schema>".role_scope_grants ADD CONSTRAINT role_scope_grants_scope_node_id_fkey FOREIGN KEY (scope_node_id) REFERENCES "<schema>".scope_node_paths (node_id) ON DELETE RESTRICT` (name is 36 bytes, under the 63-byte NAMEDATALEN limit; the only interpolation is the schema from `prefix()`, INV-7) |
| Indexes | none new: `role_scope_grants_scope_node_id_idx` (partial, `scope_node_id IS NOT NULL`) already supports the RESTRICT check and `references_node?/2` |
| `down` | `ALTER TABLE ... DROP CONSTRAINT role_scope_grants_scope_node_id_fkey`, guarded by `to_regclass` on both tables (a replay may find neither) |
| Replay | stage-1 wrote no scoped row, so every existing tenant passes the precheck; `tenant_template` and the test clone path (`Letflow.Test.TenantTemplate` re-adds foreign keys) carry the FK, asserted by a `pg_constraint` test on BOTH a replayed tenant and a clone |

### 3.6.2 Flag column (AC 12): `20261018100002_add_admin_flagged_service_principal_to_users.exs`

Tenant-scoped, guarded, registered. `ALTER TABLE "<schema>".users ADD COLUMN admin_flagged_service_principal boolean NOT NULL DEFAULT false`
(26 bytes of name, no index: it is read by primary key). `down` drops the column. Backfill: none (default false).
No change to `@expected_tenant_tables` (no new table). No other table or view reads `users.*` positionally
(ELIXIR-DEV greps `INSERT INTO users` in lib/ and test/support; the default covers raw inserts).

### 3.6.3 `scope_node_paths` `:down` (AC 4)

`test/letflow/scope_node_paths/migration_test.exs` calls `:down` of `CreateScopeNodePaths` alone
(out of reverse-version order), which `drop table` refuses while the FK exists. Decision: the ORDER is fixed in the
test, not by editing the historical migration (a replayed migration keeps its semantics):

1. the existing scope test keeps its steps and additionally inserts, before `:down`, a scoped
   `role_scope_grants` row referencing node `"a"` (direct SQL fixture);
2. it first runs `migrate(schema, @fk_version, @fk_migration, :down)` and asserts the constraint is absent
   (`pg_constraint`);
3. then the existing `:down` of `CreateScopeNodePaths`, then `:up` (table empty, the grant row now references a
   node that does not exist);
4. it re-inserts nodes `r`, `a`, then `:up` of the FK migration succeeds and the constraint exists again
   (this also exercises the precheck on both sides: before re-inserting `a` the same `:up` raises the precheck
   error, asserted).

No `@tag :skip`, no removed assertion (`git diff` shows additions only to that test). OQ-11 records the
alternative (drop the FK inside `CreateScopeNodePaths.down`).

## 3.7 Retire guard (AC 5)

`Letflow.ScopeNodePaths` changes (module remains the only writer of its table):

```
@type write_error :: ... | :node_has_grants          # appended to the existing union
lock_active_node_for_share!(node_id, prefix) :: {:ok, Node.t()} | {:error, :invalid_node_id | :node_not_found | :node_retired}
    # SELECT ... FOR SHARE of the node row in the caller's transaction; raises ArgumentError outside one;
    # reads retired_at from the locked row (READ COMMITTED sees a retire that committed while waiting)
write({:retire, node_id}, prefix)
    # unchanged for an already-retired node (idempotent, no guard)
    # for a live node, in this order inside the table-locked transaction:
    #   1. select the node row FOR NO KEY UPDATE (blocks while a grant creator holds the share lock)
    #   2. Letflow.Identity.RoleScopeGrants.references_node?(node_id, prefix)
    #   3. true  -> {:error, :node_has_grants}, retired_at stays NULL, nothing written
    #      false -> set retired_at (as today)
```

A refusal is detected by reads before the first write, so the "never calls Repo.rollback inside a caller's
transaction" rule holds. A `:move` of a referenced node is NOT refused (S1 belongs to the org module). The
module dependency `ScopeNodePaths -> RoleScopeGrants -> ScopeNodePaths` is a runtime call cycle with no
compile-time struct dependency; `mix letflow.check_boundaries` is not affected (no module-subdir file).

Interleavings pinned by tests (T-R3, T-R4, both with a held lock in a second connection, async false):
(i) create holds the share lock and has not committed; retire blocks at step 1, and after the create commits
step 2 sees the row and answers `:node_has_grants`; (ii) retire holds step 1 and has committed `retired_at`;
the create blocked on the share lock wakes, re-reads `retired_at`, answers `invalid_scope_node` and writes nothing.

## 3.8 Tenant-wide versus scoped, last row (AC 6, 7)

| Rule | Mechanism |
|---|---|
| Scoped row while a tenant_wide row exists for (principal, role) | 409 `tenant_wide_row_exists`, nothing written, no replace option (step 8). Between "delete the tenant_wide row" and "create the scoped row", `allowed?/3` for a group principal returns `{:deny, :no_grant_rows}`; T-W3 asserts it. |
| make-tenant-wide when the tenant_wide row exists | 409 `tenant_wide_row_exists` |
| make-tenant-wide otherwise | delete scoped rows + insert ONE tenant_wide row in one transaction; `grant.made_tenant_wide` lists `removed_scoped_ids`; a forced failure after the delete restores the scoped rows (T-W5) |
| Delete of the only remaining row of (principal, role), that row scoped | 409 `last_scoped_row`, for group and user principals alike; the unchanged effective scope is asserted with `allowed?/3` |
| Delete of a scoped row when any other row of (principal, role) remains | allowed |
| Delete of the only remaining row of a GROUP principal's `TENANT_ADMIN` set | 409 `last_admin_binding_row` ONLY when that sole row is tenant_wide; when the sole row is scoped the row above wins and the code is `last_scoped_row` (precedence: `last_scoped_row` first) (SEC D-1): it would leave a zero-row TENANT_ADMIN binding, whose members every other admin-set guard still counts (`count_tenant_wide_admins/1`, identity.ex:1342) but `allowed?/3` denies under `on` (`rows_scope([])` is `:deny`), making a total admin lockout reachable. The operator unbinds the role through the existing route instead, which cascades the rows AND runs the existing N1 guards. A rule refusal, not a count refusal: no `tenant_admin.guard_refused` event |
| Delete of any other tenant_wide row | allowed, subject to the TA guard (3.9). For a non-TA role a group principal is then denied (zero rows), never widened; a user principal falls back to its groups' rows; `GET /tenant/scope-enforcement/integrity` shows the zero-row binding (T-L4) |
| The role binding is removed | existing cascade (`remove_group_rows!/3`), unchanged and not reachable through these routes |

## 3.9 Zero-admin guard (AC 8)

The guard applies only when the row's `role` is `"TENANT_ADMIN"`. Protocol (1b section 6 rules): lock A first, then
`lock_admin_binding!/1`, count before, write, count after, refuse only on the `> 0 -> 0` transition,
`Repo.rollback({:tenant_admin_guard, refusal})`, then `TenantAdminGuard.refuse/3` writes
`tenant_admin.guard_refused` in its own transaction with exactly the six existing keys.

| Action value | Fired by | Counter | Reachable from |
|---|---|---|---|
| `scope_tenant_admin` | create of a scoped TA row | `Identity.count_tenant_wide_admins/1` (existing) | only a zero-row TENANT_ADMIN binding (step 8 already refuses while a tenant_wide row exists); its test seeds that state with a direct-SQL fixture and says so |
| `revoke_tenant_admin_grant` | delete of a tenant_wide TA row of a USER principal, or of a group principal's tenant_wide row while other rows of that group's TA set remain (anomalous state) | `Identity.count_explicit_tenant_wide_admins/1` (new, finding F1) | a user whose tenant_wide TA row is the last explicit source; "delete the only row of the admin group" never reaches the guard because `last_admin_binding_row` refuses it first (3.8) |

`TenantAdminGuard` changes: `@type action` gains the two atoms; `resource_type/1` gains the clause
`role_scope_grant` for both (finding F3); `count_before!/2` and `ensure_admins_remain!/5` take a counter
(`:counted` default, `:explicit`); the existing arities delegate with `:counted`, so no existing path changes.

`Identity.count_explicit_tenant_wide_admins(prefix) :: non_neg_integer()`: shares `tenant_wide_admins_query/2`
for the active-user and live-token parts so the two counts cannot diverge; the group part replaces
`exclude_scoped_holders/2` by "the member has a `tenant_wide = true` TENANT_ADMIN row as user principal or the
bound group has one". The token part is unchanged. Read-only, no lock, same transaction visibility as the
existing count.

Counted versus explicit after a delete attempt (SEC D-1 (c)): with the group-row refusal in place no path of this requirement produces a zero-row TENANT_ADMIN binding from a non-zero state, so `count_tenant_wide_admins/1` and `count_explicit_tenant_wide_admins/1` agree after every refused or accepted delete (T-Z7). A zero-row binding that pre-exists (a T9 gap, direct SQL) is the only state where they differ.

Target id in the event: the principal id (user or group uuid string). Both tests per action, plus a concurrent
holder of `lock_tenant_admins!/1` blocking the route until released (T-Z5), plus "succeeds while another counted
admin exists" (T-Z3).

## 3.10 Self-grant and self-add (AC 9, 10)

`self?(principal_type, principal_id, caller_id, prefix)` (private to `ScopedGrants`): `principal_type == :user` and `principal_id == caller_id`,
or `principal_type == :group` and `Identity.group_member?(principal_id, caller_id, prefix)` (plain read under lock A,
so a concurrent membership change is serialised). Applies to create and make-tenant-wide (widening);
delete is exempt ("narrowing or deleting is not widen"; AC 7/8 still apply). A token principal is checked as its
owner (`auth_context.user_id`).

`Identity.add_group_member/3` gains the option `refuse_self_add: boolean()` (default false). When true and
`user_id == AuditContext.actor_id`, the transaction rolls back with `:self_grant_refused` before any insert
(after lock A). Only `POST /groups/:id/members` passes it; `PendingAdminGrants.bind_on_login`, the JIT/IdP sync and
every other caller are unchanged. The router maps the result to 409 `self_grant_refused` and writes the audit
through `ScopedGrants.record_self_grant_refused/3` with `act: "add_member"`. Adding another user is unchanged.
Existing tests that add the caller to a group (grep `test/letflow/routers/identity*`, `test/letflow/identity*`
for the TA caller adding itself) are edited to add a different user or to use the context function, and are
listed in the PR body (AC 10).

## 3.11 Audit events (AC 11)

Written with `Audit.insert_entry(Repo, attrs, prefix)` in the SAME transaction as the change (so a forced
audit failure rolls the row back), except the two refusal events which use their own transaction. No token
value, hash, prefix or IdP claim value in any payload (INV-4).

| Action | resource_type / resource_id | before_state | after_state (keys) |
|---|---|---|---|
| `grant.created` | `role_scope_grant` / row id | `nil` | `id, principal_type, principal_id, role, scope_node_id, tenant_wide, trace_id` |
| `grant.revoked` | same | the row keys | `nil` |
| `grant.made_tenant_wide` | same, id of the NEW tenant_wide row | `removed` = list of `{id, scope_node_id}` | `id, principal_type, principal_id, role, tenant_wide, removed_scoped_ids, trace_id` |
| `grant.self_grant_refused` | `role_scope_grant` / principal id | `nil` | `act` (`create`, `make_tenant_wide`, `add_member`), `actor`, `principal_type`, `principal_id`, `role`, `scope_node_id` (nil when absent), `trace_id`; own transaction after the rollback |
| `service_principal.flagged` / `.unflagged` | `user` / user id | `{flagged}` | `{flagged, reason, actor, trace_id}` |
| `tenant_admin.guard_refused` | existing, with the two new `action` values | | the exact existing six keys |

Every `grant.*` and `service_principal.*` `after_state` also carries `credential` (`"oidc"` or `"api_token"`, from `auth_context.credential`; SEC D-3: grant writes by a token principal are attributable to their mechanism), including `grant.revoked` and `grant.self_grant_refused`. `service_principal.unflagged` additionally carries `tokens_exceeding_owner` (count only, advisory A-2: live tokens of that owner whose roles exceed the owner's tenant-wide roles at unflag time; never ids or values; NOT in the HTTP response, whose body stays the AC 1 shape). `actor_id` column = the authenticated user; `trace_id` from the request. Names follow the D8 amendment naming
rule (`<subject>.<past_tense_verb>`). `attachment_link.issued` is AC 21 (2b).
Consumers test (T-U6): for each action, `Audit.list_entries/1` with `resource_type` filter, and `GET /audit`
mapping, return the entry without error (finding F8).

## 3.12 Admin-flagged service principal (AC 12, 13)

`Letflow.Identity.ServicePrincipal` (the only writer; calls from the identity router only):

```
set_flag(user_id :: String.t(), flagged :: boolean(), reason :: term(), actor(), prefix :: String.t())
    :: {:ok, %{user_id: Ecto.UUID.t(), flagged: boolean(), changed: boolean()}}
     | {:error, :not_found | :reason_required | :invalid_reason | {:audit_failed, term()} | {:transaction_failed, Exception.t()}}
flagged?(user :: User.t()) :: boolean()          # pure field read, used by the mint check
```

Order: reason check first (missing, non-string or blank after trim: `:reason_required`; fails `Audit.Reason`:
`:invalid_reason`), so a bad reason never reveals whether the user exists; then the transaction: lock A; user row
`FOR UPDATE` (`:not_found` when absent or id not a UUID); a request that equals the current value returns
`changed: false` with no write and no audit; otherwise update and write `service_principal.flagged|unflagged`
in the same transaction. Serialises with mint through lock A and the users row lock (mint reads the flag from the
users row it already locks `FOR SHARE`).

Route gate (finding F9): (1) plug allow; (2) `auth_context.credential == :oidc` else the uniform 403 (so an API
token, even holding TENANT_ADMIN, is refused); (3) `Scope.principal_from_conn/1` then `"TENANT_ADMIN"` among
`principal.roles` with `Scope.effective_scope(principal, "TENANT_ADMIN") == :tenant_wide` else the uniform 403.
The flag has no other write path: `User` changesets do not cast it, `PATCH /users/:id` and the JIT path cannot set
it, and `user_map/1` does not render it (OQ-13).

Mint effect (AC 13), in `Identity.check_roles_held/4` (step 7 of the mint): the signature takes the locked target
`User` instead of only its id. Target flagged: roles must be a subset of the ISSUER's tenant-wide role names only.
Target unflagged: unchanged (subset of issuer AND target). The issuer is still authorized by step 3. Nothing else
in the mint changes (PLATFORM_ADMIN rules, expiry, active checks). The flag is not inferred from any token
category, not set by a mint, a refusal, a token creation or a revoke (T-P5 reads it before/after).

Flip rule stays 0051's: a token whose roles exceed its owner's tenant-wide roles remains in the BLOCKING
category `roles_exceed_owner` of `TokenPreconditions` even when the owner is flagged (the category predicate does
not read the flag; T-E5). `Scope.allowed?/3` has no input from the flag (T-E6: same decision for a flagged and an
unflagged user with the same rows).

`TokenPreconditions.findings/1` gains `service_principal_owner :: [%{user_id, token_ids}]`: for each owner with
the flag set and at least one listed (active or owner_inactive) token, the owner id and that owner's token ids
(never a value). `Identity.list_tokens/1` adds `owner_flagged` to the map it already builds from the existing
owner join (no extra query). The route body adds `"service_principal_owner"` under `"information"`; the
`token.listed` audit entry's `token_ids` and `count` include these ids. `flip_blocked` is unchanged.

## 3.13 Single-writer scan: `mix letflow.check_role_scope_grants_writers` (AC 14)

`Mix.Tasks.Letflow.CheckRoleScopeGrantsWriters`, same public shape as the precedent
(`run/1`, `scan(roots)`, `audit(content, path)`, `violation()` type) and wired into `@check_static_steps` next to
`letflow.check_scope_node_paths_writers`.

| Item | Rule |
|---|---|
| Roots | `lib/**/*.ex` and every regular file under `priv/modules`; NOT `test/`, NOT `priv/repo/migrations/`; a missing root is skipped |
| Allowlist (moduledoc and `@allowlist`) | `lib/letflow/identity/role_scope_grants.ex`, `lib/letflow/identity/role_scope_grants/backfill.ex`, `lib/letflow/identity/role_scope_grant.ex`, and the task's own file `lib/mix/tasks/letflow.check_role_scope_grants_writers.ex` (it names the patterns) |
| Schema name | the whole word `RoleScopeGrant` (`\bRoleScopeGrant\b`): `RoleScopeGrants` (trailing s) never matches, so a call `RoleScopeGrants.<fun>(` is by construction the legal way to write |
| Table name | the whole word `role_scope_grants` (`_` is a word character, so index and constraint names such as `role_scope_grants_scoped_uniq` do not match) |
| (i) | a call `Repo.insert`, `insert!`, `insert_all`, `update`, `update!`, `update_all`, `delete`, `delete!`, `delete_all` whose text on the same line and the next two lines contains the schema name or the table name |
| (ii) | an `Ecto.Multi` `insert`, `update`, `delete`, `insert_all`, `update_all`, `delete_all` call with the same window rule |
| (iii) | raw SQL: `INSERT INTO`, `UPDATE` or `DELETE FROM` followed by optional schema qualifier (`"<anything>".`) and the table name, case-insensitive, one line |
| (iv) | a struct literal `%RoleScopeGrant{` (with or without module prefix) or a call `RoleScopeGrant.changeset(` |
| Comments | lines whose trimmed text starts with `#` are skipped; doc text inside heredocs is NOT skipped (an AC phrased as a grep is tripped by prose; anti-patterns.md, "A grep-shaped acceptance criterion can be tripped by the module's own moduledoc"): prose in non-allowlisted files avoids the exact words, and a violation there is reworded, never allowlisted |
| Reads | `from(g in RoleScopeGrant)` with `Repo.all/one/exists?/aggregate`, the manifest entry and docs mentions are allowed |
| Output | `Mix.raise/1` listing `path:line [rule] text`; success prints one line |
| Known limit | a schema aliased into a variable (`schema = RoleScopeGrant`) or a name split across a string concatenation is not caught; stated in the moduledoc, left to REVIEWER |

Tests (`test/mix/tasks/letflow.check_role_scope_grants_writers_test.exs`, fixtures under
`test/fixtures/role_scope_grants_writers/`): the real tree passes (this includes identity.ex:1355 and :2394,
scope.ex, auth_pipeline.ex, tenant_provisioning.ex, both mix tasks); four violating fixtures each fail with the
expected rule (Repo.insert_all of the schema, Multi.delete of the schema, raw `DELETE FROM role_scope_grants`,
struct literal); four must-pass fixtures pass: two read-only queries, and the two sites on main that a substring
match would flag, copied VERBATIM as files: identity.ex lines 1000-1002 (`Repo.delete_all` followed by
`RoleScopeGrants.delete_group_principal_rows!`) and tenant_admin_migration.ex lines 395-398 (`Repo.delete_all` of a
`TenantRole` query followed by `RoleScopeGrants.reconcile_binding!`). Also: a mutated copy of the first
must-pass fixture with `RoleScopeGrants` replaced by `RoleScopeGrant` fails (proves the whole-word rule, mutant M11).

## 3.14 Policy keys (AC 1) and #2612

`Letflow.Api.Authorization` (only file touched for authorization):

```
@type endpoint_policy_key :: ... | :RoleScopeGrantsRead | :RoleScopeGrantsManage | :ServicePrincipalManage
endpoint_policy_key("GET",    "/tenant/role-scope-grants")                    :: :RoleScopeGrantsRead
endpoint_policy_key("POST",   "/tenant/role-scope-grants")                    :: :RoleScopeGrantsManage
endpoint_policy_key("DELETE", "/tenant/role-scope-grants/:id")                :: :RoleScopeGrantsManage
endpoint_policy_key("POST",   "/tenant/role-scope-grants/make-tenant-wide")   :: :RoleScopeGrantsManage
endpoint_policy_key("PUT",    "/users/:id/service-principal")                 :: :ServicePrincipalManage
required_permission(key) when key in [:RoleScopeGrantsRead, :RoleScopeGrantsManage, :ServicePrincipalManage]
    :: :UsersGroupsRolesManage
```

The `required_permission/1` clause is REQUIRED, not optional: without it the identity fallback returns the key
itself, and `permission_scope/1` would classify the unknown atom as platform (1b design section 3.4, the same
trap that made the `:Scope*` keys explicit). The new router is added to `@routers` and `@mount_prefix`
(`"/tenant/role-scope-grants"`) of `authorization_enforcement_test.exs`, and the platform-scope inventory tests
pick it up through the `forward` regex. Test T-K1: for each new key,
`Authorization.permission_scope(Authorization.required_permission(key)) == :tenant`.

#2612 / the permission-matrix golden (`priv/permission_matrix/effective.golden`, 8 roles x 49 permissions = 392
rows): a new PERMISSION atom or a `role_allows?/2` change would be a core matrix change (report marker
`CORE MATRIX CHANGE`, mandatory SECURITY-REVIEWER scope, golden regeneration). This design adds NONE: AC 1 forbids
a new permission atom, the three keys are policy keys mapped to an existing atom, no role gains or loses a
permission, no module `role_grants` entry changes. Verification step for ELIXIR-DEV: `MIX_ENV=dev mix
letflow.permission_matrix --check` exits 0 with the golden file byte-identical and no `CORE MATRIX CHANGE`
line; if that ever fails, STOP and re-route to CODE-DESIGNER (a new atom was introduced by mistake). Independently
of the golden, editing `lib/letflow/api/authorization.ex` is in SECURITY-REVIEWER's mandatory scope
(`.claude/agents/security-reviewer.md` boundary paths), which this requirement requires anyway.

## 3.15 Stage-1 route walk amended (AC 15)

`test/letflow/api/scope_grants_route_walk_test.exs`:

| Test | Change |
|---|---|
| T-RW1a | unchanged (writers == the `RoleScopeGrants` file only: all new table access is inside it) |
| T-RW1b | the expected function list gains the new writers (`insert_scoped/5`, `insert_tenant_wide/4`, `delete_row!/2`, `delete_scoped_rows!/4`) and readers (`get_row/2`, `rows_for/4`, `references_node?/2`, `list_page/4`) |
| T-RW1c | narrowed to: only `insert_scoped` and `rows_for/list_page` filters may take `scope_node_id`; `tenant_wide: false` appears only in `insert_scoped`; no other public function does either |
| T-RW2a | unchanged (empty-body calls of every route, including the five new ones, leave the full row set identical: all five answer 422/404 before writing) |
| T-RW2b | unchanged for its routes |
| T-RW2c (new) | with valid fixture bodies, ONLY `POST /tenant/role-scope-grants`, `DELETE /tenant/role-scope-grants/:id` and `POST /tenant/role-scope-grants/make-tenant-wide` change scoped rows; the tripwire trigger is parametrised by an allowed route list; a SEEDED fixture route (test-support router that inserts a scoped row by SQL) is reported as a mismatch, proving the walk still fails for any other route |

---

# PART B: PR 2b, route plane

## 4.0 Module map (2b)

| File | New / changed | Content |
|---|---|---|
| `lib/letflow/api/authorized_router.ex` | changed | `scope:` option, second accumulator, `__authz_route_scopes__/0` (4.1) |
| `lib/letflow/api/route_scope.ex` | new | `Letflow.Api.RouteScope`: classes, key table, `class_of/1`, `audit_routes/2` |
| `lib/letflow/api/scope/enforce.ex` | new | `Letflow.Api.Scope.Enforce.check/3` (4.3) |
| `lib/letflow/plugs/authorize.ex` | changed | third branch for stored mode `:on` |
| `lib/letflow/plugs/auth_pipeline.ex` | changed | `scope_enforcement/1` maps `:on` |
| `lib/letflow/identity/tenant.ex` | changed | enum `[:off, :shadow, :on]` |
| `lib/letflow/scope_enforcement.ex` | changed | `stored_modes/0`, `get_mode/1` (4.2) |
| `lib/letflow/api/scope.ex` | changed | retired-node rule, moduledoc sentence (4.4) |
| `lib/letflow/scope_node_paths.ex` | changed | `resolve/2` (4.4) |
| `lib/letflow/api/scope/shadow.ex` | changed | declared class, `ShadowEvidence.record/2,3` (4.8) |
| `lib/letflow/api/scope/shadow_evidence.ex` | new | GenServer + ETS + flush (4.7) |
| `lib/letflow/api/scope/shadow_evidence/counter.ex` | new | `Ecto.Schema` of `scope_shadow_counters` (written only by `ShadowEvidence`) |
| `lib/letflow/supervisor/infrastructure.ex` | changed | + child after `Letflow.Metrics.Registry`; moduledoc list |
| `lib/letflow/routers/instances.ex` | changed | `scope: :tenant_wide` on both link routes; `attachment_link.issued` audit (4.6) |
| every other router | none | default-sourced routes stay unannotated in 2b |
| `lib/letflow/tenant_provisioning.ex` | changed | manifest + 1 entry (`scope_shadow_counters`) |
| `priv/repo/migrations/20261018200001_widen_tenants_scope_enforcement_check.exs` | new | public (4.2) |
| `priv/repo/migrations/20261018200002_create_scope_shadow_counters.exs` | new | tenant-scoped (4.7.1) |
| `test/support/scope_enforcement_fixture.ex`, `test/support/route_inventory.ex`, `test/support/tenant_fixture.ex` | new / changed | helper, route discovery, oracle |

## 4.1 Route classification (AC 17)

Classes: `:admin_plane`, `:tenant_wide`, `{:resolver, {module, function}}` (function/1 maps the loaded resource
to a `Scope.resource_scope()`; REQ-518 defines the resolvers; arity pinned by a constant in the walk, OQ-8),
`:filter` (list endpoints).

`Letflow.Api.AuthorizedRouter` changes (keeping `__authz_routes__/0` as 3-tuples; existing tests assert that exact
shape):

```
authz_get / authz_post / authz_put / authz_patch / authz_delete  gain an arity-4 form:
    authz_get "/path", :PolicyKey, scope: <class> do ... end
  - <class> must be a compile-time literal of one of the four shapes, else CompileError
  - the route's private map becomes %{policy_key: key, scope_class: class} (scope_class absent when not declared)
  - a second accumulator @authz_route_scopes records {method, path, class} for DECLARED routes only
__authz_route_scopes__() :: [{String.t(), String.t(), class()}]       # generated in @before_compile
```

`Letflow.Api.RouteScope` (new, `lib/letflow/api/route_scope.ex`, pure):

```
@type class :: :admin_plane | :tenant_wide | :filter | {:resolver, {module(), atom()}}
@type source :: :declared | :key_table | :default
admin_plane_keys() :: [atom()]            # the key table
class_of(private :: map()) :: {class(), source()}     # declared > key table > default (:tenant_wide)
@type route_row :: %{router: module(), method: String.t(), path: String.t(),   # path = FULL mounted path
                     key: atom(), declared: class() | nil, class: class(), source: source()}
@type error :: {:unclassified, route_row()} | {:stale_snapshot, String.t()}
            | {:declared_conflicts_with_key_table, route_row()} | {:resolver_not_exported, route_row()}
            | {:admin_key_not_in_table, atom()} | {:link_route_reclassified, route_row()}
audit_routes(routes :: [route_row()], default_snapshot :: [String.t()]) :: [error()]    # the walk logic, pure; [] = pass
# a snapshot line is "METHOD FULL_PATH KEY"; the informational list of `:filter` routes is a separate
# filter_routes(routes :: [route_row()]) :: [route_row()], not an error
```

Admin-plane key table (D11): `:GroupsManage`, `:UsersManage` (includes `GET /pending-admin-grants`), `:TokensManage`,
`:RolesManage`, `:RolesRebind`, `:ScopeNodePathsConsistencyRead`, `:ScopeEnforcementRead`,
`:ScopeEnforcementManage`, `:ScopeGrantsIntegrityRead`, `:ScopeEnforcementTokensRead`, `:RoleScopeGrantsRead`,
`:RoleScopeGrantsManage`, `:ServicePrincipalManage`. "`:UsersGroupsRolesManage`" in the AC is a permission, not a key; the
completeness test derives the set instead of trusting a hand list: every policy key whose `required_permission/1` is
`:UsersGroupsRolesManage`, plus `:TokensManage` and `:RolesManage`, must be in the table.

Walk (`test/letflow/api/route_scope_walk_test.exs`, async true, no DB): routes come from a new test-support
module `Letflow.Support.RouteInventory` (extracts the mount discovery of `platform_scope_inventory_test.exs`
helpers: `forward(...)` regex over `api_pipeline.ex`, module routers from `Catalog.entry_modules/0`); every route of
every mounted core and module router. It asserts, via `RouteScope.audit_routes/2`:

| Error | Condition |
|---|---|
| `:unclassified` | source `:default` and the route is not in the committed snapshot `test/fixtures/route_scope/tenant_wide_default_routes.txt` (sorted lines `METHOD FULL_PATH KEY`); a seeded fixture router (test-support) with an unlisted route proves it fails |
| `:stale_snapshot` | a snapshot line whose route is no longer default-sourced (REQ-518 shrinks the snapshot as it reclassifies; its AC 19/20 tests then assert "no data route is default") |
| `:declared_conflicts_with_key_table` | a route declares a class and its key is in the admin-plane table (an option cannot weaken the admin plane) |
| `:resolver_not_exported` | `{:resolver, {m, f}}` with `function_exported?(m, f, 1)` false after `Code.ensure_loaded/1` |
| (not an error) | `filter_routes/1` lists every `:filter` route; the walk asserts it equals the committed expectation (empty in 2b) |
| `:admin_key_not_in_table` | completeness rule above |
| `:link_route_reclassified` | `POST /instances/:id/attachments/:attachment_id/link` or `GET .../link-content` with a class other than `:tenant_wide` while the constant `RouteScope.issue_time_parent_lookup?/0` is `false` (0051 M7); a seeded reclassification row in the test proves it |

The snapshot file is also the "listed in the PR body" artefact: the PR body pastes the diff-free list.
Runtime treatment of every default-sourced route is exactly `:tenant_wide` (finding F6).

The two attachment-link routes declare `scope: :tenant_wide` EXPLICITLY (source `:declared`), so they are never
silently default. All other instance, attachment, task, entity-data, webhook, module and self-service routes stay
default-sourced in 2b (REQ-518 AC 18-20 reclassify the data and task routes; finding F10 for `/me` and `/help`).

## 4.2 Stored value `on` (AC 16)

| Item | Change |
|---|---|
| Migration | `priv/repo/migrations/20261018200001_widen_tenants_scope_enforcement_check.exs`, PUBLIC (not tenant-scoped, not in the manifest): drop `tenants_scope_enforcement_check`, re-create with `scope_enforcement IN ('off', 'shadow', 'on')`. `down`: raises if any tenant is `on` (an operator must flip it off first; it never silently de-escalates), else restores the two-value check |
| `Tenant` | `Ecto.Enum` values `[:off, :shadow, :on]`; `scope_enforcement_changeset/2` spec accepts `:on` (only `flip/4` calls it) |
| `ScopeEnforcement` | `modes/0` stays `[:off, :shadow]` (the GET body's `available_modes` is unchanged); new `stored_modes/0 :: [:off, :shadow, :on]` used by `get_mode/1` (finding F4); `parse_mode/1` and `check_target/1` unchanged, so `flip(..., :on, _)` is `{:error, :invalid_mode}` and `PUT {"mode":"on"}` is 422 `invalid_enforcement_mode`; `@type mode` gains a `stored_mode` sibling for `previous`/`get_mode`. A tenant stored as `on` can still be flipped `off` with a reason through the existing path (and `shadow`, whose stage-1 gating bug REQ-519 AC 13 owns) |
| `AuthPipeline` | `scope_enforcement/1` gains `defp` clause mapping `%Tenant{scope_enforcement: :on}` to `:on`; both the OIDC and the API-token branch already call it from the tenant row they load, so query counts are unchanged (T-O3 pins them equal across off/shadow/on) |
| Test support | `test/support/scope_enforcement_fixture.ex`, `Letflow.Support.ScopeEnforcementFixture.set_stored_mode!(tenant_id, :off \| :shadow \| :on)` by direct SQL UPDATE of the public row. Not under `lib/`. REQ-518 reuses it. A lib/ scan test asserts `scope_enforcement_changeset(` is called only from `lib/letflow/scope_enforcement.ex` (REQ-519 AC 8 owns the authoritative flip-authority scan) |
| Moduledocs | `ScopeEnforcement`: "`on` does not exist" sentence replaced; `Tenant` field comment replaced |

## 4.3 `Authorize` under `on` (AC 18, 19)

`Letflow.Plugs.Authorize.call/2`, allow branch, after the two assigns:

| Stored mode | Action |
|---|---|
| `:off` or key absent | nothing (unchanged) |
| `:shadow` | `Scope.Shadow.observe/3` (4.8) |
| `:on` | `Scope.Enforce.check(conn, ctx, policy_key)` (new module `Letflow.Api.Scope.Enforce`), may halt |

`Enforce.check/3` returns the conn or a halted 403/500 conn:

1. policy key in the skipped set (`:Unknown`, `:UnmatchedRoute`, `:UnmatchedPlatformPath`, `:MetricsRead`): return the conn (keep their handling).
2. `class = RouteScope.class_of(conn.private)`.
3. `{:resolver, _}` or `:filter`: return the conn (the handler applies the scope: REQ-518).
4. `:admin_plane`, `:tenant_wide`, or default-sourced (a route with no classification): `Scope.principal_from_conn/1`
   then `Scope.allowed?(principal, Authorization.required_permission(policy_key), :tenant_wide)`;
   `{:allow, _}`: return the conn; `{:deny, _}` or `{:error, :no_principal}`: emit `[:letflow, :scope, :enforce, :denied]`, `AuthzDenyLog.log_denial/3` and the
   unchanged `Response.forbidden(conn, "insufficient permissions")`, halted (route-level answer, no resource
   revealed, no existence oracle).
5. Any raise, exit or throw: one constant line `scope_enforcement_failed class=<error|exit|throw> exception=<module|none>`
   (no ids, no values, every occurrence), then a halted detail-free `Response.internal_error/1`. Never an allow (AC 20).

Behavior that follows without special cases: a tenant-wide principal passes; a token principal is `{:allow, :token}`
(tenant-wide by rule); a platform-tenant PLATFORM_ADMIN is `{:allow, :platform}`; a platform-scope permission is
decided by the platform branch of `allowed?/3` (grants never read, INV-10); a principal holding the role only
through scoped rows is `{:deny, :not_tenant_wide}`; a binding with zero rows is `{:deny, :no_grant_rows}`; a
failed grants load is `{:deny, :grants_unavailable}`. `:admin_plane` and `:tenant_wide` decide identically in the
plug; the difference is declarative (D11 inventory, walk rules, and the handlers' own defense-in-depth
`require_tenant_wide/2`). `off` and `shadow` HTTP responses are byte-identical to today (T-G1, T-G8); the shadow
OBSERVATION changes (4.8).

AC 18 table test (`admin_plane_under_on_test.exs`): rows are generated from the route table (every route whose
class is `:admin_plane`); for each: a caller whose TENANT_ADMIN is held only through a directly inserted scoped
row gets the uniform 403 with the tenant stored `on`; with the tenant `off` or `shadow` the plug does not halt it
(the observable is a NEW telemetry event `[:letflow, :scope, :enforce, :denied]` (`%{count: 1}`, metadata `policy`, `reason`), emitted by `Enforce.check/3` only on a deny and attached by the test; it has no metrics-registry family. `AuthzDenyLog.log_denial/3` is the same function the coarse deny uses, so it cannot serve as the marker. The assertion: under `off`/`shadow` no such event fires and, on
handler-gated routes — the stage-1 scope-enforcement routes and the 2a routes, which call `require_tenant_wide/2`
themselves — an explicit expected 403 listed in the test); a tenant-wide TENANT_ADMIN passes in all three modes.

## 4.4 `Scope.allowed?/3` and retired nodes (AC 19, T6)

`Letflow.ScopeNodePaths.resolve(node_id, prefix) :: {:ok, %{node: Node.t(), ancestors: [Node.t()]}} | {:error, :invalid_node_id | :node_not_found | :invalid_schema_name}`
(new; `ancestors/2` is re-expressed over it, same two queries). In `Scope.decide_resource/3` for `{:node, id}`:
tenant-wide principal: allow with no read (unchanged, so a retired node is allowed for a tenant-wide holder); scoped
principal: `resolve/2`; the resource node itself has `retired_at` set: `{:deny, :unresolvable}`; otherwise the
subtree test as today. Only the resource node's own `retired_at` is considered (a grant can never reference a
retired node after 2a, so a retired ancestor holding a grant is unreachable; OQ-7). The `Scope` moduledoc sentence
"Retired nodes are not considered in stage 1" is replaced. Nothing in 2b calls `allowed?/3` with `{:node, _}`;
the rule is exercised by unit tests and used by REQ-518.

## 4.5 DB error path (AC 20)

Covered by step 5 of 4.3; no test hook is added to `lib/`. Two ways to produce a raise inside the plug, both
listed in T-I1:

1. (mandatory) the test calls `Enforce.check/3` with a hand-built conn whose `auth_context.scope_grants` is a
   malformed `Grants` struct (`rows_by_role` not a map), so `effective_scope/2` raises inside the decision;
2. (end to end) a conn built with an `auth_context` that lacks the `scope_grants` key (a context that did not come
   from the pipeline), in a dedicated tenant whose `role_scope_grants` table was dropped, so the lazy
   `load_grants/2` of `principal_from_conn/1` raises.

Both assert a halted non-2xx response (500, detail-free), exactly one captured `scope_enforcement_failed` line, and
that the downstream handler never ran. A grants load that fails INSIDE `AuthPipeline` is already `:not_loaded`
(auth_pipeline.ex:426 comment), which the decision turns into `{:deny, :grants_unavailable}` (403, not a raise).


## 4.6 Attachment links (AC 21, T15)

| Item | Design |
|---|---|
| Classification | both `POST /instances/:id/attachments/:attachment_id/link` (`:AttachmentLinksIssue`) and `GET .../link-content` (`:AttachmentsRead`) declare `scope: :tenant_wide` explicitly. In `on`, a scoped-only holder of a role with `AttachmentLinksIssue` is refused 403 on issue; presenting a valid link issued by a tenant-wide user is refused 403 at link-content because that route re-runs the whole pipeline (auth, `Authorize`, `Enforce`) before it verifies the token. A tenant-wide caller is unchanged (TTL 300 s, one attachment per link) |
| Audit | `handle_issue_attachment_link/3` writes `attachment_link.issued` AFTER `AttachmentLinks.issue/3` succeeded and BEFORE the response is built: `Audit.insert_entry(Repo, attrs, prefix)`, `resource_type: "attachment"`, `resource_id: attachment id`, `after_state`: `issuer` (user id), `instance_id`, `attachment_id`, `scope_node` (`nil` while instances carry none), `trace_id`; never the token value, the url or the expiry. No row to roll back with (issue persists nothing but the lazily created signing secret), so the audit is the only write; an audit failure or raise answers the detail-free 500 with NO token in the body (fail closed, one constant log line), as `token.listed` does. Written in every mode (`off`, `shadow`, `on`) |
| Revoke-then-serve | issue a link as a tenant-wide user, make the serving principal scoped-only (insert a scoped row, delete the tenant_wide row) or remove their role, `Letflow.Support.ScopeEnforcementFixture.set_stored_mode!(.., :on)`: the next `link-content` request is 403 immediately (T-K4); in `off` the same link is still served until expiry (control) |
| Route-walk rule | `:link_route_reclassified` (4.1), proven by a seeded reclassification |
| Existing tests | instance attachment tests that count audit rows are adjusted and listed in the PR body |

## 4.7 Persisted shadow evidence (AC 22)

### 4.7.1 Table

Migration `priv/repo/migrations/20261018200002_create_scope_shadow_counters.exs`: tenant-scoped, guarded,
registered, no `tenant_id` column (0006 D2). Table `scope_shadow_counters` (21 bytes):

| Column | Type | Notes |
|---|---|---|
| `day` | `date` NOT NULL | UTC date of the observation |
| `metric` | `text` NOT NULL | `requests` or one of the six reasons: `role_not_held`, `no_grant_rows`, `not_tenant_wide`, `out_of_scope`, `unresolvable`, `grants_unavailable` |
| `count` | `bigint` NOT NULL DEFAULT 0 | CHECK `count >= 0` (`scope_shadow_counters_count_check`) |
| `updated_at` | `utc_datetime_usec` NOT NULL | |

PK `(day, metric)` (`scope_shadow_counters_pkey`), CHECK `scope_shadow_counters_metric_check` (the 7-value set).
All names are explicit and under 63 bytes. `@expected_tenant_tables` in `test/support/tenant_fixture.ex` gains
`"scope_shadow_counters"` in sorted position and the paired count assertion in
`test/letflow/support/tenant_fixture_test.exs` moves by one, in the SAME change (anti-patterns.md, third entry on
the oracle). `down` drops the table. Replay and clone are asserted by the existing C6 oracle test.

### 4.7.2 Process and counters

`Letflow.Api.Scope.ShadowEvidence` (new GenServer, `trap_exit`, child spec `shutdown: 10_000`), started by
`Letflow.Supervisor.Infrastructure` right after `Letflow.Metrics.Registry` (a leaf with no ordering dependency;
the moduledoc child list and `infrastructure_test.exs` move from 24 to 25 and gain the id; finding F7).

```
record(prefix :: String.t(), metric :: :requests | Scope.deny_reason()) :: :ok          # day = UTC today
record(prefix :: String.t(), metric :: :requests | Scope.deny_reason(), day :: Date.t()) :: :ok   # explicit day (tests); never raises
flush() :: :ok | {:error, term()}                      # synchronous; used at shutdown and by tests; never raises into callers
counts_between(prefix :: String.t(), from :: Date.t(), to :: Date.t()) :: %{metric => non_neg_integer()}
    # reads the TABLE only (persisted, flushed counts); unflushed ETS counts are NOT included. A caller that needs the
    # live view calls flush() first (tests do). For REQ-519 this is intended: the gate uses persisted evidence, and the
    # 30 s window or a crash can only make the counts lower (see the crash residual).
```

`record/3` does `:ets.update_counter` on the public named table `:letflow_scope_shadow_evidence` with the key
`{prefix, day, metric}` in the CALLER's process (no GenServer call, no DB), wrapped so a missing table or any error is
swallowed (`:ok`). The prefix is the plug's own `scoped_opts[:prefix]` (INV-1); the ETS key and table are never
logged or labelled. The process flushes every `:scope_shadow_flush_interval_ms` (default 30_000) and in
`terminate/2`: for each distinct prefix it snapshots the keys it will write, upserts one multi-row statement per
prefix (`ON CONFLICT (day, metric) DO UPDATE SET count = table.count + EXCLUDED.count, updated_at = EXCLUDED.updated_at`,
a constant fragment, INV-7), and on success subtracts exactly the flushed amount from the ETS counter (increments
made during the flush are kept); on failure it leaves the counters, logs one constant line
`scope_shadow_flush_failed class=<kind>` (no tenant, no ids) and retries at the next tick; an
`undefined_table`/invalid schema error discards that prefix's counters (a dropped tenant cannot leak memory).
INV-7 binding of the schema: the flush writes with `Repo.insert_all(Counter, rows, prefix: prefix, on_conflict: ..., conflict_target: [:day, :metric])`, so Ecto binds the tenant schema; the prefix string is never concatenated into SQL and never taken unchecked from the ETS key: before each flush the prefix is validated with `TenantProvisioning.tenant_id_for_schema_name/1` (the same validator `ScopeNodePaths` applies at scope_node_paths.ex:231), and ETS entries whose prefix fails it are DROPPED, not flushed (a test inserts a hostile key directly into the table and asserts it is dropped and nothing executes). The ETS table is created `:public, :named_table, :set, {:write_concurrency, true}`. A once-a-day step deletes rows older than `:scope_shadow_retention_days` (default 90, must be at least the largest
`:scope_shadow_min_days` REQ-519 may configure; OQ-12). The flush never runs on the request path and never raises
into it. Crash residual (documented in the moduledoc): at most one flush interval of counts is lost, which can only
make REQ-519's gate more lenient.

### 4.7.3 Which requests count

Only requests of a tenant in `shadow` (the `Authorize` branch is only entered for `:shadow`), after the unchanged
coarse allow, excluding the skipped keys. `off` and `on` tenants write no row (T-H6).

## 4.8 Shadow observer re-wired (AC 22, 19)

`Letflow.Api.Scope.Shadow.observe/3` (spec unchanged): for every non-skipped key it first calls
`ShadowEvidence.record(prefix, :requests)`; then, by `class_of/1`: `:tenant_wide`, `:admin_plane` and default-sourced
routes are evaluated against `:tenant_wide` (as today) and a would-deny additionally records its reason metric
(`record(prefix, reason)`) beside the existing telemetry and sampled log; `{:resolver, _}` and `:filter` routes are
counted as requests only and not evaluated (shadow cannot evaluate them; the limitation is recorded in REQ-519
AC 12). No principal counts as `:grants_unavailable`. The in-memory metric family
`letflow_scope_shadow_would_deny_total` is unchanged and is not used for gating. Metric labels and log lines gain
no tenant slug, user id or prefix (T-H5 capture-log assertion).
Expected-to-change existing tests (AC 19): `test/letflow/api/scope_shadow_test.exs`,
`test/letflow/plugs/auth_pipeline_scope_test.exs`, the shadow cases of `test/letflow/scope_enforcement_test.exs` and
`test/letflow/routers/tenant_scope_enforcement_test.exs`; plus `test/letflow/supervisor/infrastructure_test.exs` and
the tenant fixture oracle; each is listed in the PR body with its reason.

---

# PART C: acceptance criteria map, tests, mutants, cost, security

## 5. AC map

Locks: "A" = lock A first; see 3.5. Migration shapes: 3.6, 4.2, 4.7.1.

| AC | PR | Design element | Specs / sections | Locks | Error codes | Tests |
|---|---|---|---|---|---|---|
| 1 | 2a | five routes, router, three policy keys, no new atom | 3.2, 3.4, 3.14 | A (writes) | 403; 404 `not_found`; 409 `grant_exists`, `tenant_wide_row_exists`, `last_scoped_row`, `last_admin_binding_row`, `last_tenant_wide_admin`, `self_grant_refused`; 422 `invalid_role`, `invalid_principal`, `invalid_scope_node`, `no_binding`, `invalid_body`, `reason_required` | T-A1..T-A9, T-K1 |
| 2 | 2a | validation order, `ScopedGrants.parse_*`, `RoleScopeGrants.insert_scoped/5` | 3.3, 3.4 | A, R, N | `invalid_role`, `invalid_principal`, `no_binding`, `invalid_scope_node`, `grant_exists`, `invalid_body` | T-V1..T-V10 |
| 3 | 2a | FK migration, changeset constraint, precheck | 3.6.1 | migration takes A | `invalid_scope_node` | T-F1..T-F5 |
| 4 | 2a | test-side ordering of the `:down` | 3.6.3 | n/a | n/a | T-D1, git-diff review item |
| 5 | 2a | `references_node?/2`, retire guard, share lock, F2 | 3.7 | S then N (retire); A, N (create) | `:node_has_grants` (stable `write/2` error) | T-R1..T-R5 |
| 6 | 2a | tenant_wide vs scoped, make-tenant-wide | 3.3, 3.8 | A | `tenant_wide_row_exists` | T-W1..T-W5 |
| 7 | 2a | last scoped row, delete semantics | 3.8 | A, R(TA) | `last_scoped_row`, `last_admin_binding_row` | T-L1..T-L7 |
| 8 | 2a | TenantAdminGuard, two new actions, explicit count (F1, F3) | 3.9 | A, R | `last_tenant_wide_admin` | T-Z1..T-Z7 |
| 9 | 2a | self-grant for create and make-tenant-wide | 3.10 | A | `self_grant_refused` | T-S1..T-S4 |
| 10 | 2a | `refuse_self_add` | 3.10 | A | `self_grant_refused` | T-M1..T-M3 |
| 11 | 2a | audit events in the same transaction | 3.11 | C last | n/a (500 on failure) | T-U1..T-U6 |
| 12 | 2a | flag column, `ServicePrincipal`, route gate (F9), informational category | 3.6.2, 3.12 | A, users row | 403, 404, 422 `reason_required`, `invalid_body` | T-P1..T-P8 |
| 13 | 2a | mint target-side relaxation, flip rule untouched, scan | 3.12 | A, users share | `roles_not_held` (existing) | T-E1..T-E7 |
| 14 | 2a | `mix letflow.check_role_scope_grants_writers` | 3.13 | n/a | `Mix.raise` | T-X1..T-X7 |
| 15 | 2a | walk amended | 3.15 | n/a | n/a | T-RW1b, T-RW1c, T-RW2c |
| 16 | 2b | CHECK widened, enum, `parse_mode` unchanged, AuthPipeline `:on`, helper | 4.2 | n/a | `invalid_enforcement_mode` | T-O1..T-O6 |
| 17 | 2b | classification mechanism, key table, snapshot, walk | 4.1 | n/a | n/a | T-C1..T-C9 |
| 18 | 2b | admin plane under `on` | 4.3 | n/a | 403 | T-N1 (table-driven) |
| 19 | 2b | `Enforce.check/3`, retired node, byte-identical off/shadow | 4.3, 4.4 | n/a | 403 | T-G1..T-G9 |
| 20 | 2b | fail closed on raise | 4.3 step 5, 4.5 | n/a | 500 + constant log | T-I1, T-I2 |
| 21 | 2b | link routes pinned, audit, revoke-then-serve | 4.6 | C | 403, 500 | T-K2..T-K6 |
| 22 | 2b | counters table, ETS, flush, observer re-wired | 4.7, 4.8 | none on request path | n/a | T-H1..T-H10 |
| 23 | both | gates | section 11 | n/a | n/a | gate output |

## 6. Tests (TEST-DESIGNER writes them; ids are the contract; one per AC at minimum)

Test files (2a): `test/letflow/routers/tenant_role_scope_grants_test.exs`, `test/letflow/identity/scoped_grants_test.exs`,
`test/letflow/identity/role_scope_grants_admin_test.exs`, `test/letflow/identity/service_principal_test.exs`,
`test/letflow/identity/mint_service_principal_test.exs`, `test/letflow/identity/tenant_admin_guard_scoped_test.exs`,
`test/letflow/scope_node_paths/retire_guard_test.exs`, the edited `migration_test.exs`,
`test/mix/tasks/letflow.check_role_scope_grants_writers_test.exs`, the edited `scope_grants_route_walk_test.exs`,
the edited `authorization_enforcement_test.exs` (router registered). Real HTTP through the router with real
tenants (`async: false` where DDL, triggers or held locks are used).

### 6.1 PR 2a

| Id | AC | Test |
|---|---|---|
| T-A1 | 1 | (a) happy: 201 with exactly the eight listed keys, no extra field; row exists; `effective: true` for a group with the binding |
| T-A2 | 1 | (b) list: filters (`principal_type`, `principal_id`, `role`), `limit`, `cursor` second page, tenant_wide rows included with `scope_node_id: null`, another tenant's rows absent |
| T-A3 | 1 | (c) delete: 204 empty body; row gone; unknown id and a non-UUID id are 404 `not_found` |
| T-A4 | 1 | (d) make-tenant-wide: 200 with `{id, tenant_wide: true, removed_scoped_ids}` sorted |
| T-A5 | 1 | (e) flag route 200 body keys exactly `{user_id, admin_flagged_service_principal}` |
| T-A6 | 1 | 403 uniform (same bytes) for: caller without the permission, a scoped-only TENANT_ADMIN, a non-admin, on all five routes |
| T-A7 | 1 | each listed 404/409/422 code returned once per route that lists it (table-driven, code asserted in `detail`) |
| T-A8 | 1 | no tenant segment or body/query field is read: a body `tenant_id` is `invalid_body`; a query `tenant` param changes nothing (INV-1) |
| T-A9 | 1 | `mix letflow.permission_matrix --check` output has no `CORE MATRIX CHANGE` and the golden is unchanged |
| T-V1..V10 | 2 | PLATFORM_ADMIN role; a routing-role name; unknown role; group without binding (`no_binding`); group with only a routing-kind binding; unknown user; unknown group; retired node; unknown node and a malformed id; duplicate scoped row; unknown/extra key; `user` row for a role not held via a group accepted with `effective: false`; hostile strings (`'; DROP`, `%`, `_`) are only ever bound values (SQL capture shows no interpolation) |
| T-F1 | 3 | an unknown node is rejected by the FK at SQL level (direct insert) and mapped to `invalid_scope_node` by the service |
| T-F2 | 3 | `DELETE FROM scope_node_paths` of a referenced row is rejected (RESTRICT) |
| T-F3 | 3 | apply and rollback: `pg_constraint` shows the FK after `:up`, absent after `:down`; the constraint name and `confdeltype = 'r'` asserted |
| T-F4 | 3 | precheck: a tenant with a scoped row naming an unknown node aborts the migration with the count-only message (no node id in it) |
| T-F5 | 3 | the FK exists on a replayed tenant AND on a cloned test tenant (template path re-adds foreign keys) |
| T-D1 | 4 | the edited migration test passes with a scoped grant row present; no `@tag :skip`; `git diff` removes no assertion |
| T-R1 | 5 | `references_node?/2` true/false; retire of a referenced node returns `{:error, :node_has_grants}` with `retired_at` NULL; after the last row is deleted the retire succeeds |
| T-R2 | 5 | a move of a referenced node is allowed; the grant keeps referencing it |
| T-R3 | 5 | (T-R3 and T-R4 first assert `SHOW transaction_isolation` is `read committed` on the connections used, since REPEATABLE READ would break the argument) held lock: a create in progress (share lock held, uncommitted) makes the concurrent retire wait, then refuse (interleaving i) |
| T-R4 | 5 | held lock: a retire in progress makes the concurrent create wait, then answer `invalid_scope_node` and write nothing (interleaving ii) |
| T-R5 | 5 | retire of an already-retired node is idempotent `{:ok, node}` and does not consult grants |
| T-W1 | 6 | scoped create while a tenant_wide row exists: 409 `tenant_wide_row_exists`, nothing written, rows unchanged |
| T-W2 | 6 | make-tenant-wide when the tenant_wide row exists: 409 |
| T-W3 | 6 | delete tenant_wide row then, before the scoped create, `allowed?/3` is `{:deny, :no_grant_rows}`; after the scoped create it is `:allow`/`:subtree` per node |
| T-W4 | 6 | make-tenant-wide with two scoped rows: one tenant_wide row, scoped rows gone, response lists both ids, `grant.made_tenant_wide` lists them |
| T-W5 | 6 | forced failure after the scoped delete (audit trigger) restores both scoped rows |
| T-L1 | 7 | delete the only scoped row of a group principal: 409 `last_scoped_row`, row present, `allowed?/3` unchanged |
| T-L2 | 7 | same for a user principal whose only row is scoped |
| T-L3 | 7 | delete one of two scoped rows: 204 |
| T-L4 | 7 | delete a tenant_wide row: 204; a group principal then `{:deny, :no_grant_rows}`, a user principal falls back to its groups' rows; `GET .../integrity` lists the zero-row binding |
| T-L5 | 7 | removing the role binding still cascades all rows (existing route, unchanged) |
| T-L6 | 7 | SEC D-1: deleting the only row of a group's `TENANT_ADMIN` set (tenant_wide) while another admin exists: 409 `last_admin_binding_row`, row present, no zero-row binding; the sequence "A via G1, B via G2: delete G2's row, deactivate A" is refused at the first step (lockout unreachable); unbinding the role through the existing route still works and cascades |
| T-L7 | 7 | precedence: the sole remaining row of a group's TENANT_ADMIN set is SCOPED: delete answers 409 `last_scoped_row` (not `last_admin_binding_row`); the same set with a sole tenant_wide row answers `last_admin_binding_row` |
| T-Z7 | 8 | after every delete attempt in T-L6 and T-Z1 `count_tenant_wide_admins/1` equals `count_explicit_tenant_wide_admins/1` |
| T-Z1 | 8 | `revoke_tenant_admin_grant` (user principal): deleting the tenant_wide TA row of the user that is the last explicit admin source: 409 `last_tenant_wide_admin`, row present, one `tenant_admin.guard_refused` with exactly the six keys and `action: "revoke_tenant_admin_grant"` |
| T-Z2 | 8 | `scope_tenant_admin`: seeded zero-row admin binding by direct SQL (stated in the test), create scoped TA row: 409, event with `action: "scope_tenant_admin"` |
| T-Z3 | 8 | the same changes succeed while another counted admin exists |
| T-Z4 | 8 | both events carry `resource_type: "role_scope_grant"` (finding F3) and exist in the chain |
| T-Z5 | 8 | a concurrent holder of `lock_tenant_admins!/1` blocks both routes until released |
| T-Z6 | 8 | the explicit count: a zero-row admin binding counts 0 explicit and 1 counted; a token owner counts in both |
| T-S1..S4 | 9 | create for self (user) refused; create for a group the caller belongs to refused; make-tenant-wide for self refused; each: 409, no row, `grant.self_grant_refused` in its own transaction (still present when the main transaction rolled back); delete of the caller's own scoped row (with another remaining) allowed |
| T-M1..M3 | 10 | caller adding themselves: 409 `self_grant_refused`, no membership, audit; adding another user unchanged (201); `bind_on_login` and IdP sync still add the user themselves (option default false) |
| T-U1..U6 | 11 | each of the six actions written in the same transaction (trigger-forced audit failure rolls the row/flag back); payload key sets exact; no token/claim value; `list_entries` and `GET /audit` filter by `resource_type` return each; F8 note |
| T-P1 | 12 | flag and unflag by a tenant-wide OIDC TENANT_ADMIN: 200, column value, audit entry with actor, user, reason, trace |
| T-P2 | 12 | uniform 403 for a scoped admin, a non-admin, and an API-token principal holding TENANT_ADMIN (nothing written) |
| T-P3 | 12 | `reason` missing, blank, non-string: 422 `reason_required`, nothing written, for flag and unflag; control-char reason 422 `invalid_reason` |
| T-P4 | 12 | forced audit failure rolls the flag back; same-value request: 200, `changed` false path writes no audit |
| T-P5 | 12 | the flag is unchanged by successful and refused mints, token create/revoke, user PATCH |
| T-P6 | 12 | held `lock_tenant_admins!/1` blocks the route; a concurrent mint waits for the flag change |
| T-P7 | 12 | `GET token-preconditions` lists `service_principal_owner` {owner id, token ids} under `information`, no token value, `token.listed` includes the ids |
| T-P8 | 12 | unknown user and non-UUID id: 404 |
| T-E1..E4 | 13 | before the flag: mint for roles beyond the target's tenant-wide roles refused `:roles_not_held`; after the flag: succeeds when the ISSUER holds them, refused when the issuer does not; after unflagging refused again; an unflagged owner never gets the exemption whoever minted the token |
| T-E5 | 13 | a token exceeding its flagged owner stays in `roles_exceed_owner` (BLOCKING), `flip_blocked` true |
| T-E6 | 13 | `Scope.allowed?/3` identical for a flagged and an unflagged user with the same rows |
| T-E7 | 13 | static scan: the column name is written in `lib/` only by `Letflow.Identity.ServicePrincipal` (patterns: `cast`/`change`/`put_change`/`update_all set:`/raw `SET`), `User` changesets do not cast it |
| T-X1..X7 | 14 | real tree passes; four violating fixtures each fail with the right rule; four must-pass fixtures pass (incl. the two verbatim sites); the whole-word mutation fixture fails; allowlisted file with a violation passes; the task's own file is exempt; wired in `@check_static_steps` (assert the alias list) |
| T-K1 | 1 | `required_permission(key) == :UsersGroupsRolesManage` exactly (so `permission_scope == :tenant`) for the three keys; `authorization_enforcement_test` covers the five routes |
| T-RW1b/c, T-RW2c | 15 | section 3.15 |

### 6.2 PR 2b

| Id | AC | Test |
|---|---|---|
| T-O1 | 16 | migration: CHECK allows off, shadow, on and rejects `ON`, `x`; `Tenant` enum accepts `:on`; apply/rollback; `down` raises when a tenant is `on` |
| T-O2 | 16 | `parse_mode/1` rejects `"on"`; `flip(..., :on, _)` is `{:error, :invalid_mode}`; `PUT {"mode":"on"}` is 422 `invalid_enforcement_mode`; the column unchanged |
| T-O3 | 16 | query-count test (Ecto telemetry) of the OIDC and API-token paths equal for off, shadow and on; a direct column change (helper) takes effect on the next request without restart; both paths set `scope_enforcement: :on` |
| T-O4 | 16 | `GET /tenant/scope-enforcement` for an `on` tenant answers `"mode":"on"`, `available_modes` unchanged `["off","shadow"]` (finding F4) |
| T-O5 | 16 | the helper lives under `test/support`, not `lib/` (path assertion); lib/ scan: `scope_enforcement_changeset(` only in `scope_enforcement.ex` |
| T-O6 | 16 | `flip(.., :off, reason)` from a stored `on` succeeds and audits |
| T-C1 | 17 | walk over all routes of all mounted routers (core and module, attachments, tasks, instances included): none unclassified; a seeded fixture route fails with `:unclassified` |
| T-C2 | 17 | every `{:resolver, _}` route has an exported resolver (seeded one without fails); `:filter` routes listed (empty) |
| T-C3 | 17 | key-table completeness (derived from `required_permission/1`), including the three 2a keys |
| T-C4 | 17 | `__authz_routes__/0` shape unchanged (existing assertions pass unedited); `__authz_route_scopes__/0` lists only declared routes |
| T-C5 | 17 | macro validation: a non-literal or unknown class is a CompileError (compile a fixture module) |
| T-C6 | 17 | `:declared_conflicts_with_key_table` fires for an admin key with a declared `:filter` |
| T-C7 | 17 | snapshot freshness: `:stale_snapshot` fires for a seeded stale line |
| T-C8 | 17 | the PR-body list equals the snapshot file |
| T-C9 | 17 | runtime: a default-sourced route and an explicit `:tenant_wide` route behave identically in `on` |
| T-N1 | 18 | the table-driven admin-plane test (4.3) |
| T-G1 | 19 | `off` and `shadow` responses (status, headers, body) byte-identical to a COMMITTED fixture `test/fixtures/route_scope/off_shadow_responses.json`, captured on this branch BEFORE any 2b lib change (first commit of PR 2b, from the unchanged `main` behavior): about 12 requests (tenant-wide TA and scoped-only caller, admin-plane, default, `AllowWithRowFilter` task list, unmatched route), each recorded as status, headers with request id and date removed, and body; the test replays them under `off` and under `shadow` and compares |
| T-G2 | 19 | `:tenant_wide`/default route, scoped-only holder, `on`: 403 same bytes as the coarse deny; tenant-wide holder: handler runs |
| T-G3 | 19 | a route with no classification: 403 for a non-tenant-wide principal, unaffected for a tenant-wide one |
| T-G4 | 19 | seeded `{:resolver, _}` and `:filter` fixture routes pass through to their handler in `on` |
| T-G5 | 19 | `:Unknown`, unmatched-route, metrics keys keep their handling in `on` |
| T-G6 | 19 | platform-tenant PLATFORM_ADMIN and a token principal pass (tenant-wide per D1); zero-row binding denied; failed grants load denied |
| T-G7 | 19 | `allowed?/3` retired node: scoped principal `{:deny, :unresolvable}`, tenant-wide `{:allow, :tenant_wide}`; moduledoc sentence replaced |
| T-G8 | 19 | the listed expected-to-change shadow tests are edited and nothing else (diff review item) |
| T-G9 | 19 | `AllowWithRowFilter` task list for a tenant-wide TASK_WORKER in `on`: row filter unchanged |
| T-I1 | 20 | forced raise inside `Enforce.check/3`: non-2xx, exactly one `scope_enforcement_failed` line, never an allow |
| T-I2 | 20 | the captured log contains no id, slug or value |
| T-K2 | 21 | both link routes are `:tenant_wide` and `source: :declared`; the seeded reclassification fails `:link_route_reclassified` |
| T-K3 | 21 | `on`: scoped-only holder refused 403 on issue; tenant-wide holder issues (TTL 300 s, one attachment) |
| T-K4 | 21 | revoke-then-serve: link issued by a tenant-wide user, serving principal made scoped-only, next `link-content` 403 immediately; in `off` still served (control) |
| T-K5 | 21 | `attachment_link.issued` in the issue request with exactly `issuer, instance_id, attachment_id, scope_node, trace_id`; no token value/url; forced audit failure answers 500 and the body carries no token |
| T-K6 | 21 | audit written in `off`, `shadow` and `on` |
| T-H1 | 22 | a shadow request increments `requests` (ETS) and, after `flush/0`, the table row for today |
| T-H2 | 22 | a seeded would-deny increments its reason; both persisted by the flush |
| T-H3 | 22 | another tenant's counters untouched; `off` and `on` tenants write no row |
| T-H4b | 22 | a hostile prefix key placed in the ETS table is dropped by the validator and never reaches SQL (SEC D-2) |
| T-H4 | 22 | a flush failure (table dropped) does not fail the request, logs one constant line, counters retained and retried; undefined-table discards |
| T-H5 | 22 | no tenant slug, prefix or user id in metric labels or captured logs |
| T-H6 | 22 | no DB query on the request path from the evidence code (Ecto telemetry count equal to a shadow-off baseline) |
| T-H7 | 22 | resolver/filter fixture routes count as requests only (no reason metric) |
| T-H8 | 22 | additive upsert: two flushes sum; concurrent increments during a flush are not lost |
| T-H9 | 22 | shutdown flushes (`terminate/2`); the child is in Infrastructure (25 ids, ordering test edited). ALL ShadowEvidence test files are `async: false` with the SQL sandbox in `{:shared, test_pid}` mode (or `Sandbox.allow/3` of the named GenServer pid), because the flush process writes to the database from its own process |
| T-H10 | 22 | day rollover: `record/3` with explicit days writes separate rows; retention prune deletes only older rows |

## 7. Mutants (the suite must kill each; >= 8 per PR)

### PR 2a

| Id | Mutant | Killed by |
|---|---|---|
| M1 | retire reads `references_node?` BEFORE locking the node row (finding F2) | T-R3 |
| M2 | create does not re-read `retired_at` after the share lock | T-R4 |
| M3 | scoped create silently deletes the tenant_wide row (narrow) or keeps both | T-W1, T-W3 |
| M4 | last-scoped-row check only for group principals | T-L2 |
| M5 | revoke guard uses the existing (non-explicit) count, so the delete is never refused | T-Z1 |
| M18 | the group-row `last_admin_binding_row` refusal is dropped (lockout reachable) | T-L6 |
| M19 | the flush builds the schema from the raw ETS key | T-H4b |
| M20 | `credential` missing from a grant audit payload | T-U1 |
| M6 | `resource_type/1` clause missing for a new action (audit silently lost) | T-Z4 |
| M7 | self-grant ignores group membership of the caller | T-S2 |
| M8 | make-tenant-wide deletes scoped rows outside the transaction | T-W5 |
| M9 | flag route accepts an API-token principal, or reads only `require_tenant_wide/2` | T-P2 |
| M10 | the flag also relaxes the issuer side of the mint | T-E3 |
| M11 | the scan uses a substring match (flags `RoleScopeGrants.`) or drops the whole-word rule | T-X (must-pass fixtures, whole-word mutation fixture) |
| M12 | audit written outside the transaction (best effort) | T-U (trigger-forced failure keeps the row) |
| M13 | `PLATFORM_ADMIN` or a routing-role name accepted as `role` | T-V1, T-V2 |
| M14 | list query without the filter/prefix (returns another tenant's rows) | T-A2 |
| M15 | the FK precheck is skipped, so a bad row is silently carried | T-F4 |
| M16 | `refuse_self_add` defaults to true (breaks `bind_on_login`) | T-M3 |
| M17 | the flag is set by token creation/mint (inferred, not explicit) | T-P5, T-E7 |

### PR 2b

| Id | Mutant | Killed by |
|---|---|---|
| N1 | `Enforce` runs under `shadow` (denies) | T-G1 |
| N2 | an unclassified route is allowed instead of failing closed | T-G3, T-C9 |
| N3 | `{:resolver, _}` / `:filter` routes are enforced as `:tenant_wide` | T-G4 |
| N4 | a retired node is allowed for a scoped principal | T-G7 |
| N5 | a raise inside `Enforce` allows the request | T-I1 |
| N6 | `parse_mode/1` accepts `"on"` | T-O2 |
| N7 | `AuthPipeline` maps `:on` on the OIDC path only | T-O3 |
| N8 | the link is issued before/without the audit entry, or an audit failure still returns the token | T-K5 |
| N9 | `link-content` skips the pipeline `Enforce` (token alone suffices) | T-K4 |
| N10 | `record/3` writes to the DB synchronously on the request path | T-H6 |
| N11 | counters written for `off` and `on` tenants | T-H3 |
| N12 | a declared option overrides an admin-plane key | T-C6 |
| N13 | flush discards counters on a transient error | T-H4 |
| N14 | the stale snapshot is ignored | T-C7 |
| N15 | `get_mode/1` keeps the two-value guard (500 for an `on` tenant) | T-O4 |

## 8. Cost (extra queries per request)

| Path | 2a | 2b |
|---|---|---|
| Any authenticated request, tenant `off` | 0 | 0 |
| OIDC request, tenant `shadow` | 0 | 0 DB queries (two ETS increments) |
| OIDC request, tenant `on` | 0 | 0 beyond the grants load that already happens on every OIDC request (1b section 2); the `:tenant_wide` decision reads no table |
| API-token request | 0 | 0 (single-query shape preserved; T-O3) |
| Mint | 0 (flag read from the users row already locked) | 0 |
| Token-preconditions listing | 0 (flag in the existing owner join) | 0 |
| Grant routes (admin only) | create 12-16 statements incl. lock, audit chain; list 1 | 0 |
| Attachment link issue | 0 | +1 audit insert (+ its chain lock) per issue, every mode |
| Background | 0 | one multi-row upsert per active shadow tenant per 30 s; one prune per day |

`ScopeNodePaths.resolve/2` replaces the two reads of `ancestors/2` with the same two reads (no change).

## 9. Security: INV analysis

| INV | 2a | 2b |
|---|---|---|
| INV-1 tenant from auth only | prefix from `scoped_opts`; no tenant in path/body/query (T-A8); every new query takes `prefix:` | counters keyed by the plug's prefix; `tenants` row by `auth_context.tenant_id` |
| INV-2 field-by-field shaping | bodies built field by field; list item keys fixed; `user_map` unchanged (flag not rendered); `evaluate_access/2` untouched | the plug adds a route-level 403 only; shadow log/metrics unchanged; counters hold counts only |
| INV-4 no secrets | audit payloads without token/claim values; precheck message count-only | link audit without token/url; flush log constant |
| INV-5 not-found/forbidden | admin routes are tenant-wide-only, 404 for an unknown grant/user id is visible only to tenant-wide admins (documented: an existence signal confined to that audience); a scoped caller gets the uniform 403 BEFORE any lookup (handler gate first) | route-level 403 before any lookup, no resource revealed, no oracle; link-content re-checks per request |
| INV-6 new data-access paths prove their scoping | table access only in `RoleScopeGrants` (scan T-X, walk T-RW1); explicit prefix | `scope_shadow_counters` written only by `ShadowEvidence`; reads by prefix |
| INV-7 no interpolation | all values bound; the only interpolation is the schema in migrations and the constant `EXCLUDED` fragment | same |
| INV-8 no unhandled crashes | typed 4xx/409; transaction exceptions mapped to 500; audit failure rolls back; guard `refuse/4` never raises | `Enforce` fail-closed; shadow and flush never raise into the request; link audit fails closed |
| INV-10 platform authority | grants never decide PLATFORM_ADMIN; the flag route refuses PLATFORM_ADMIN-only callers; platform branch of `allowed?/3` first | platform-scope permissions decided before grants under `on` (T-G6) |

Residual risks recorded for SECURITY-REVIEWER: (1) token principals may call the grant write routes (OQ-15);
(2) the explicit count is a second definition of "admin" (F1); (3) default-sourced routes are denied to scoped
callers by fail-closed behavior, not by declaration (F6); (4) `/me` and `/help` regress for scoped-only users in `on`
(F10); (5) shadow evidence loses at most 30 s on crash.

## 10. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | boot-time replay of the FK migration aborts a tenant that somehow holds a bad scoped row | the precheck reports a count and aborts only that tenant's replay (`MigrationReplayBoot` logs); stage 1 wrote none |
| R2 | admin deadlock between grant writers and tree writers | rank table 3.5; T-R3/T-R4 held-lock tests |
| R3 | the line-window scan false-positives on prose in a future file | known limit documented; rewording rule |
| R4 | the default snapshot is large and churns when REQ-518 reclassifies | it is generated, sorted, and `:stale_snapshot` makes the removal mandatory |
| R5 | UTC day rollover flakes in T-H tests | tests pass explicit days to `record/3`; the request-path test accepts today or yesterday |
| R6 | existing tests that add the caller to a group (AC 10) or count audit rows around attachment links | found by running the scoped suites; listed in the PR body |
| R7 | CRLF working tree: new files are LF; `.gitattributes` handles checkout | no action |
| R8 | the `on` CHECK `down` raising on a rollback in production | intended; documented in the migration header |
| R9 | the lazily created attachment signing secret is the only DB write of a link issue | unchanged |

## 11. Gates and commands (AC 23)

Each PR: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix letflow.check` (includes
the new scan in 2a), `mix letflow.check_boundaries`, `mix letflow.permission_matrix --check`
(`MIX_ENV=dev`), `mix letflow.check_requirements_registration`, and the scoped `mix test` over
`test/letflow/identity*`, `test/letflow/routers/identity*`, `test/letflow/routers/onboarding*`,
`test/letflow/plugs`, `test/letflow/api`, `test/letflow/scope_node_paths`,
`test/letflow/scope_enforcement_test.exs`, `test/letflow/metrics` (2b), plus the directories this design adds or
edits that AC 23 does not list: `test/mix/tasks` (2a), `test/letflow/supervisor` and `test/letflow/support` (2b),
`test/letflow/routers/instances*` (2b links), `test/letflow/routers/tenant_scope_enforcement*`. Real output quoted.
SECURITY-REVIEWER required on both (INV-1, 2, 4, 5, 6, 7, 8, 10); REVIEWER required. Anti-pattern checks for
ELIXIR-DEV: migration versions `20261018100001/2` and `20261018200001/2` collide with nothing in `test/` or
`priv/` (checked on main d206c83a8); explicit short constraint names; the oracle edit in the same commit.

## 12. Decision-record amendments (letflow-2 records; not edited here)

Used by this design and required by the requirement text: audit actions `service_principal.flagged`,
`service_principal.unflagged`, `attachment_link.issued` (D8 amendment rule 1); 0051 D12/Rollout 4 sentence "tokens
of a flagged service principal still block the flip". Extra stable codes `invalid_reason` and list 400s are
designer additions inside the route inventory, not decision-record items.

---

## 13. Handoff to later requirements (interfaces this design fixes)

| For | Fixed here |
|---|---|
| REQ-518 | `RouteScope` classes and the `scope:` option; `{:resolver, {module, function}}` with function/1; `:filter`; the snapshot file to shrink; `Letflow.Support.ScopeEnforcementFixture.set_stored_mode!/2`; `ScopeNodePaths.resolve/2` and the retired-node rule |
| REQ-519 | `ShadowEvidence.counts_between/3` and the table; the stored `on` and `stored_modes/0`; REQ-519 AC 9's `zero_tenant_wide_admins` flip blocker MUST use `Identity.count_explicit_tenant_wide_admins/1` (or require both counts to agree), see amendment RA-1 in section 16; the flag column and category for AC 9's explicit test |

---

## 16. Requirement amendments required (for letflow-2 / REQ-ANALYST; not edited here) and gate rulings recorded

| # | Amendment | Source |
|---|---|---|
| RA-1 | REQ-519 AC 9: the `zero_tenant_wide_admins` BLOCKING precondition (and the integrity finding for the `on` target) counts admins with `Identity.count_explicit_tenant_wide_admins/1`; `count_tenant_wide_admins/1` counts zero-row members that `allowed?/3` denies under `on`, so it over-counts | SEC D-1 (b) |
| RA-2 | REQ-517 AC 8 and OQ-4: for `revoke_tenant_admin_grant`, "counted" means an EXPLICIT tenant-wide source: a `tenant_wide = true` TENANT_ADMIN row for the user or for the bound group, or a live TENANT_ADMIN token owner. AC 7/8 also gain the typed refusal `last_admin_binding_row` | CDV clarification, SEC D-1 (a) |
| RA-3 | REQ-518 or REQ-519 (letflow-2 to assign): a route class for self-service routes (`/me/*`, `/help`); REQ-519's flip is BLOCKED until it exists. 2b ships without it only because nothing can set `on` before REQ-519 | SEC ruling on OQ-3/F10 |
| RA-4 | REQ-519 AC 11: the shadow-evidence gate also requires `requests > 0` on every UTC day of the window, not only a total of 100 | SEC |
| RA-5 | GOVERNANCE (full chain, not an inline edit): add `lib/letflow/api/route_scope.ex`, `lib/letflow/api/scope/enforce.ex` and `lib/letflow/api/authorized_router.ex` to the mandatory #2612 trigger path list (`.claude/agents/security-reviewer.md`, WF-02 Step 2c) | SEC A-1 |

Gate rulings recorded (SECURITY-REVIEWER design gate): the admin gate and lock order A, R, G, N, B, C pass; **OQ-15 resolved: API-token principals MAY call the grant WRITE routes** (tokens are tenant-wide by D1, break-glass under `on`), while the flag route stays OIDC-only (credential recorded in the audit, D-3); OQ-3/F10 accepted for 2b subject to RA-3; shadow counters are an ETS increment only, no DB write on the request path; the `required_permission/1` clause of the three new keys maps to exactly `:UsersGroupsRolesManage`; a retire of a node whose DESCENDANTS carry grants is allowed (only the node itself is checked; subtree grants on live descendants stay valid).

## 14. Open questions (with the default this design builds)

| # | Question | Default built | Needs |
|---|---|---|---|
| OQ-1 | AC 8 as written cannot fire for the delete (F1). Is the explicit count the intended reading? | Yes: `count_explicit_tenant_wide_admins/1` for `revoke_tenant_admin_grant`; existing count for `scope_tenant_admin` | REQ-VALIDATOR/SECURITY confirmation; if rejected, AC 8's revoke test is unimplementable |
| OQ-2 | AC 17 "unclassified fails" versus "default `:tenant_wide`" (F6) | three sources plus committed snapshot; runtime fail-closed | CDV confirmation |
| OQ-3 | Self-service routes (`/me/*`, `/help`) under `on` for scoped-only users (F10); ACCEPTED for 2b, REQ-519's flip blocked until a class exists (RA-3) | stay `:tenant_wide` (403), listed in the PR body | a follow-up class (`:self_service`) owned by a requirement amendment |
| OQ-4 | May a platform-tenant PLATFORM_ADMIN flag a service principal in the platform tenant? | No: TENANT_ADMIN role holders only (AC wording) | SECURITY |
| OQ-5 | `service_principal_owner` lists only owners with at least one active/owner_inactive token | Yes (derived from the existing listing, zero extra query) | none |
| OQ-6 | `Enforce` DB error answer: 500 or 403? | 500 detail-free (a fault, not a refusal), never an allow | SECURITY |
| OQ-7 | Retired ancestor holding a grant | unreachable after 2a; only the resource node's `retired_at` is checked | none |
| OQ-8 | Resolver arity | `{module, function}` with function/1 over the loaded resource | REQ-518 may widen; the walk constant is the single place |
| OQ-9 | Designer-added codes `invalid_reason` (422) and list 400s | built | none |
| OQ-10 | Self-grant check for token principals uses the owner id | yes | SECURITY |
| OQ-11 | `:down` ordering fixed in the test rather than inside `CreateScopeNodePaths.down` | test-side (3.6.3) | none |
| OQ-12 | Evidence retention | 90 days, `:scope_shadow_retention_days`; must be >= REQ-519's `:scope_shadow_min_days` | REQ-519 |
| OQ-13 | Expose the flag on `GET /users/:id`? | No (existing user tests unedited; visible via token-preconditions) | product |
| OQ-14 | A same-value flag request writes no audit | yes | none |
| OQ-15 | RESOLVED (SECURITY): API-token principals may call the grant WRITE routes; the flag route stays OIDC-only | allowed | none |
| OQ-16 | A fault-injection seam for T-I1 without a lib/ test hook | none added; the mandatory test drives `Enforce.check/3` with a malformed grants memo | none |

## 15. Self-review against the brief

All 23 ACs map to a design element in section 5. The route inventory is pinned once (3.2). Lock order is in 3.5
and the per-AC table. Migration shapes: 3.6, 4.2, 4.7.1. Error codes: 3.2 and section 5. Tests: section 6 (at
least one per AC). Mutants: section 7 (20 for 2a, 15 for 2b). PR boundary: section 1. Cost: section 8. INV: section 9. #2612:
section 3.14 (no new permission atom, golden unchanged, verification step). Risks and open questions with
defaults: sections 10 and 14. No implementation code appears in this file.
