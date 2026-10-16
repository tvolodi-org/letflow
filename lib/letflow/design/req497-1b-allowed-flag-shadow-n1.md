# REQ-497 PR 1b: `allowed?/3`, grants load, flag off|shadow, shadow counters, N1 guard, token listing (GH #2533)

AGENT: CODE-DESIGNER. Workflow WF-02, run `WF02-GH2533-SCOPE-GRANTS-20261015`, step 03 (1b).
Base: `main` c55baa4f5 (PR 1a #2592 merged). Scope: REQ-497 acceptance criteria **[1b] AC5-AC16
and AC17 for 1b**. [1a] AC1-AC4 are delivered and are not re-designed here.

Sources read: REQ-497 (`docs/requirements.yaml:36039-36258`), GH #2533 with its Stage-1 cut and its
three comments (heartbeats; no AC revision), decision 0051 (D1, D3, D4, D8 incl. the
`tenant_admin.guard_refused` amendment, D11, D12, Rollout, N1-N4), the 1a design
(`lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md`, especially section 10),
the merged 1a code (`lib/letflow/identity/role_scope_grants.ex`, `.../role_scope_grants/backfill.ex`,
`priv/repo/migrations/20261015025331_create_role_scope_grants.exs`), the #2547 helpers
(`lib/letflow/identity.ex:1011-1113`) and their design
(`lib/letflow/design/gh2547-tenant-admin-audit-and-count.md` sections 6.2a, 6.4, 6.6),
`lib/letflow/scope_node_paths.ex`, `lib/letflow/scope_node_paths/consistency.ex`,
`docs/agents/instructions/security-invariants.md`, `docs/anti-patterns.md`, the supervisor
rulings and the #2552 contract (dispatch input `req497-inputs.md`), the open PR #2594 diff (head
`eaef79c0c`), GH #2575, and ORCH's mid-task input on `test/support/token_mint_fixture.ex`.

Design only. No function bodies. Signatures are `@spec`-shaped text; SQL and queries are prose.

## Changelog

| Rev | Date (UTC) | Change |
|---|---|---|
| r0 | 2026-10-14 | Initial design. |
| r1 | 2026-10-14 | ORCH revision 1 after CDV FAIL and SECURITY-REVIEWER FAIL. **CDV B1:** the OIDC path loads grants on EVERY request in the same step as `list_effective_role_names/2`, no flag condition (section 2, T-P1, T-P3). **CDV B2:** the revoke_token guard runs only when the token was COUNTED at lock time (6.2 (f); T-G6 gains expired and inactive-owner cases). **CDV B3 + SEC A3:** revoke_token takes `lock_admin_binding!/1` unconditionally after A, before the token row. **SEC B1:** pending-grant revoke refusal writes a tenant-chain entry with nil actor/trace and a companion PLATFORM-chain entry with the operator (`refuse/4`, 6.1; T-G5). **SEC A1 (binding, pinned with #2564):** HTTP 409 `last_tenant_wide_admin`; `reason_code` `"last_tenant_wide_admin"`; action values `unbind_tenant_admin`, `remove_tenant_admin_member`, `rebind_tenant_admin`, `revoke_pending_grant`, `revoke_token` (#2564: `deactivate_user`), section 6.1. Advisories: SEC A2 (T-L2), A4 (section 10 T-lock sentence), A5 (section 15), A6 (4.1 prefix), A7 (1.4 step 0), ScopeNodePaths moduledoc note (section 10); CDV adv 1 (`update_user_profile/3`), adv 2 (return shapes, private fixture function), adv 3 (T-RW2), adv 4 (6.2 already-0 refusals). OQ-1..OQ-4 ruled (section 17). |

---

## 0. Binding inputs and dependency

| # | Input (not re-decided) |
|---|---|
| B1 | Stage-1 cut: flag values `off` and `shadow` only; `on` does not exist. No route creates a scoped (`tenant_wide = false`) row. Shadow computes `allowed?` from rows, denies nothing. |
| B2 | N1 paths (supervisor 2026-10-15): POST /roles kind change of the TENANT_ADMIN binding; removing a member from the TENANT_ADMIN group; delete_group (existing structural refusal, NO event); rebind of the TENANT_ADMIN binding; pending-grant revoke (last OPEN grant while the count is 0); `revoke_token` (Option A: refuse only when the owner is the last counted admin through tokens alone); reactivation and pending-grant revoke take `lock_tenant_admins!/1` first. Deactivation, incl. PATCH /users/:id, is #2564's. |
| B3 | Every count refusal writes `tenant_admin.guard_refused` {action, actor, target id, reason code, counted_admins, trace_id} in its OWN transaction after the rollback (0051 D8 amendment). |
| B4 | Moved to #2535: the enforced-tenant writer branch, `binding.pending_scope`, `grant.sync_suppressed`, the last-scoped-row refusal, and the 1a section 10 item 1b-2 cases (routing -> platform re-creation, `nil -> P` in an enforced tenant, IdP sync into a tenant-wide group). This design references them only (section 15). |
| B5 | Only "token roles exceed the owner's tenant-wide roles" blocks off -> shadow. Non-expiring PLATFORM_ADMIN tokens and NULL-issuer tokens are listed for information. |
| B6 | #2552 contract: `Identity.token_effective_status/3`, `Identity.list_tokens/1` returning `{:ok, [%{token: ApiToken.t(), owner_active: boolean()}]}`, `Identity.tenant_wide_role_names/2` returning `MapSet.t(String.t())`, private `exclude_scoped_role_names/3`, the per-token map keys {id, name, user_id, issuer_user_id, roles, status, created_at, expires_at, revoked_at, last_used_at}. |

**Dependency.** 1b branches from `main` AFTER #2594 (GH #2552) merges. Every #2552 name below is
taken from the #2594 diff at head `eaef79c0c`. Section 16 states exactly what changes if the merged
shape differs.

---

## 1. `Letflow.Api.Scope` (AC5) - new file `lib/letflow/api/scope.ex`

The only place a scope decision is made (0051 D4). Pure except for the two reads named below.
`evaluate_access/2` (`lib/letflow/api/authorization.ex:1179`) is NOT changed; `allowed?/3` is
called after it (INV-2 structural argument kept).

### 1.1 Types

```
@type node_id :: String.t()                       # = Letflow.ScopeNodePaths.node_id()
@type resource_scope :: :tenant_wide | {:node, node_id()} | :unresolvable
@type allow_basis :: :tenant_wide | :subtree | :token | :platform
@type deny_reason ::
        :role_not_held | :no_grant_rows | :not_tenant_wide | :out_of_scope
        | :unresolvable | :grants_unavailable
@type decision :: {:allow, allow_basis()} | {:deny, deny_reason()}
@type effective :: :tenant_wide | {:nodes, [node_id()]} | :deny
```

`Letflow.Api.Scope.Grants` (struct, same file):

| Field | Type | Meaning |
|---|---|---|
| `user_id` | `Ecto.UUID.t()` | whose grants these are |
| `rows_by_role` | `%{String.t() => [%{principal_type: :user \| :group, tenant_wide: boolean(), scope_node_id: node_id() \| nil}]}` | the APPLICABLE rows per role name (D1 step 2), already filtered as in 1.3 |

`Letflow.Api.Scope.Principal` (struct, same file), `@enforce_keys` all:

| Field | Type | Source |
|---|---|---|
| `kind` | `:user \| :token` | `auth_context.credential` (`:oidc` -> `:user`, `:api_token` -> `:token`); any other value -> no principal (1.5) |
| `user_id` | `Ecto.UUID.t()` | `auth_context.user_id` |
| `prefix` | `String.t()` | `conn.assigns.scoped_opts[:prefix]`, set by `Letflow.Plugs.Authorize` from `Context.scoped_repo_opts/1` (r1, SEC A6: never re-derived; absent -> `{:error, :no_principal}`) |
| `platform_tenant?` | `boolean()` | RECOMPUTED with `PlatformTenant.platform_tenant?/1` from `tenant_id` (ISS-0993 rule; never the stored fact) |
| `roles` | `[Authorization.role()]` | `Authorization.effective_roles(auth_context.roles, platform_tenant?)` |
| `grants` | `Grants.t() \| :token \| :not_loaded` | `:token` for a token principal; the memo for a user (section 2) |

A `script` principal (0051 D1) is NOT constructed in stage 1 (no caller); the type excludes it on
purpose, so a future caller must extend the type and the decision table together.

### 1.2 Public functions

| Function | Spec | Contract |
|---|---|---|
| `allowed?/3` | `@spec allowed?(Principal.t(), permission :: Authorization.permission() \| atom(), resource_scope()) :: decision()` | The decision of 1.4. Never raises on a missing or malformed node (returns `{:deny, :unresolvable}`); a DB error from the node read propagates (INV-8: loud, not swallowed). Reads the DB only for `{:node, id}` (one `ScopeNodePaths.ancestors/2` call). |
| `effective_scope/2` | `@spec effective_scope(Principal.t(), role :: String.t()) :: effective()` | D1 resolution for one role: `:deny` when the role is not in `principal.roles` (as a string), when `grants` is not a `Grants` struct, or when the role has zero applicable rows; `:tenant_wide` when any applicable row is tenant-wide; else `{:nodes, ids}` (sorted, deduplicated). Pure. |
| `load_grants/2` | `@spec load_grants(user_id :: Ecto.UUID.t(), prefix :: String.t()) :: Grants.t()` | ONE query (1.3). Reads through `Letflow.Identity.RoleScopeGrants` (new read function `applicable_rows_for_user/2`, 1.3), never the table directly. |
| `principal_from_conn/1` | `@spec principal_from_conn(Plug.Conn.t()) :: {:ok, Plug.Conn.t(), Principal.t()} \| {:error, :no_principal}` | Builds the principal. For a `:user` whose `auth_context.scope_grants` is `:not_loaded`, calls `load_grants/2` ONCE and stores the result in `conn.assigns.auth_context.scope_grants` (the request-local memo, AC6); a second call on the returned conn issues no query. `{:error, :no_principal}` when `auth_context` is absent, `credential` is not `:oidc`/`:api_token`, or the tenant id does not derive a schema (fail closed). |
| `require_tenant_wide/2` | `@spec require_tenant_wide(Plug.Conn.t(), permission :: atom()) :: {:ok, Plug.Conn.t()} \| {:error, Plug.Conn.t(), :not_tenant_wide}` | Admin-plane gate (D11) used ONLY by the section 3 and 7/8 routes in stage 1: `principal_from_conn/1`, then `allowed?(p, permission, :tenant_wide)`; `{:allow, _}` -> ok; `{:deny, _}` or `:no_principal` -> error. The caller answers 403 with the unchanged `forbid_insufficient` body. |

`Letflow.Identity.RoleScopeGrants.applicable_rows_for_user/2` (new, read-only, in the 1a module so
it stays the single reader/writer of the table):
`@spec applicable_rows_for_user(user_id :: Ecto.UUID.t(), prefix :: String.t()) :: [%{principal_type: :user | :group, role: String.t(), tenant_wide: boolean(), scope_node_id: String.t() | nil}]`.

### 1.3 The grants query (D1 step 2, D3)

One `Repo.all` with bound parameters (INV-7), `prefix:` explicit (INV-1). Rows of
`role_scope_grants` where EITHER `principal_type = 'user' AND principal_id = U`, OR
`principal_type = 'group'` AND there EXISTS a `group_members` row (user U, group
`principal_id`) joined to a `tenant_role` row with `group_id = principal_id`, `name = role` and
`kind = :platform_role`. The `exists` clause makes a group row applicable only when U holds that
role THROUGH that group (D1 step 1 and 2): a stray row of a group for a role it does not bind never
applies. `Grants.rows_by_role` groups the result by `role`. Selected columns only (no ids).

### 1.4 Decision order of `allowed?/3` (prose; the table-driven test pins each line)

0. **Unclassified permission** (r1, SEC A7): `permission` not a member of
   `Authorization.permissions/0` (core plus Catalog) -> `{:deny, :role_not_held}`, before anything
   else (otherwise `permission_scope/1` would classify it `:platform` and the PLATFORM_ADMIN
   catch-all of `role_allows?/2` would allow it). Test T-A13.
1. **Platform-scope permission** (`Authorization.permission_scope(permission) == :platform`):
   `{:allow, :platform}` iff `Authorization.has_permission_in_scope?(roles, permission,
   platform_tenant?)`, else `{:deny, :role_not_held}`. `grants` and `resource_scope` are NOT read
   (1a section 10 item 1b-1; INV-10; 0046 D2).
2. **`:unresolvable`** -> `{:deny, :unresolvable}` (D4, AC5, T6), for every principal.
3. **Candidate roles** = members of `roles` with `Authorization.role_allows?(role, permission)`.
   None -> `{:deny, :role_not_held}`.
4. **PLATFORM_ADMIN** among the candidates and `platform_tenant? == true` -> `{:allow, :platform}`
   (PLATFORM_ADMIN is outside grants, D1; its rows are never read).
5. **Token principal** (`kind: :token`) -> `{:allow, :token}` (D1: "a token principal is tenant-wide
   for its token roles; there is no scoped token"). Its rows are never read (there are none).
6. **Grants unavailable** (`grants == :not_loaded`) -> `{:deny, :grants_unavailable}`.
7. **Combine**: `effective_scope/2` per candidate role (as string). Any `:tenant_wide` ->
   combined `:tenant_wide` (tenant-wide wins within a principal and across principals, D1 (3)-(4));
   else the union of all `{:nodes, ids}`; all `:deny` -> `{:deny, :no_grant_rows}` (fail closed:
   a binding with zero rows is denied, never tenant-wide).
8. **Resource `:tenant_wide`**: combined `:tenant_wide` -> `{:allow, :tenant_wide}`; nodes ->
   `{:deny, :not_tenant_wide}`.
9. **Resource `{:node, id}`**: combined `:tenant_wide` -> `{:allow, :tenant_wide}` (no read).
   Otherwise `ScopeNodePaths.ancestors(id, prefix)` (the 0050 D8 interface, the ONLY tree access):
   `{:ok, ancestors}` and (`id` in the node set or any ancestor's `node_id` in it) ->
   `{:allow, :subtree}`; `{:ok, _}` otherwise -> `{:deny, :out_of_scope}`;
   `{:error, :node_not_found | :invalid_node_id | :invalid_schema_name}` -> `{:deny, :unresolvable}`.

Retired nodes: not considered in stage 1 (`ancestors/2` includes retired ancestors; no scoped row
can exist outside tests). #2535 adds retirement handling with the FK (1a S2-1).

### 1.5 What stage 1 calls `allowed?/3` from

Only (a) the shadow observer (section 4), (b) `require_tenant_wide/2` on the four new routes
(sections 3, 7, 8). No existing route is re-gated (D11 classification of every route is #2535).

---

## 2. AuthPipeline grants load and memo (AC6, D3)

File `lib/letflow/plugs/auth_pipeline.ex`.

| Change | Where | Detail |
|---|---|---|
| Flag carried | `authenticate_oidc/2` (:131-152) and `authenticate_api_token/2` (:156-165) | Both already hold the `%Tenant{}` loaded by `Identity.resolve_tenant_by_realm/1` / `get_tenant_by_slug/1` (uncached `Repo.get_by`, `identity.ex:172`, `:1486`). The new column `tenants.scope_enforcement` (section 3.1) comes with that row: the flag is read per request with ZERO extra queries. `attach_auth_context/5` gains a `scope_enforcement :: :off \| :shadow` argument taken from `tenant.scope_enforcement`. |
| OIDC grants load | `verify_local_account_state/2` (:401-416) | Signature becomes `verify_local_account_state(provisioned, tenant)` (private). In the SAME step, right after `list_effective_role_names/2` (:407), ALWAYS (r1, CDV B1; no condition on the flag): `Letflow.Api.Scope.load_grants(user_id, schema_name)`, exactly one more query per authenticated active OIDC request. An inactive user short-circuits before both reads, as today. Returns `{:ok, {roles, grants}}`. |
| Token path | `authenticate_api_token/2` | No grants query (a token principal has no rows, D1). `scope_grants: :token`. `verify_api_token/2` is unchanged. |
| `auth_context` keys | `attach_auth_context` (:422-442) | Adds `scope_enforcement: :off \| :shadow` and `scope_grants: Grants.t() \| :token`. Every existing key unchanged. A hand-assigned context (tests, other plugs) without these keys reads as `:off` / `:not_loaded` (fail closed: shadow off; `principal_from_conn/1` then loads once and memoises). |

Decision recorded (r1, ORCH on CDV B1): the OIDC load runs on every request in the same pipeline
step, whatever the flag (0051 D3 accepts the second query: "a second query, or one joined query").
The memo in `auth_context.scope_grants` serves every later consumer of the request (the shadow
observer, `require_tenant_wide/2`) with no further query (T-P1). `principal_from_conn/1`'s lazy
load remains only for a context that did not come from the pipeline.

**API-token path query count (AC6): unchanged, no restatement needed.** The flag rides on the
tenant row the path already reads; no grants query is added. T-P2 pins the count under `off` and
`shadow` as equal to each other and to the literal measured on the path today (TEST-DESIGNER pins
the literal: `get_tenant_by_slug`, the `verify_api_token` select, the best-effort `last_used_at`
update).

---

## 3. The per-tenant flag (AC7, D12)

### 3.1 Storage: a column on PUBLIC `tenants` (decided)

- Migration `priv/repo/migrations/20261015025332_add_scope_enforcement_to_tenants.exs`, module
  `Letflow.Repo.Migrations.AddScopeEnforcementToTenants`, PUBLIC schema only (precedent
  `20261005000001_add_login_disclosure_mode_to_tenants.exs`; NOT in the tenant manifest).
  `up/0`: add `scope_enforcement :string, null: false, default: "off"`; CHECK
  `tenants_scope_enforcement_check`: `scope_enforcement IN ('off', 'shadow')`. `down/0` drops both.
  Version check before commit (ELIXIR-DEV): `grep -rn "20261015025332\|20_261_015_025_332" lib test
  priv config` empty (checked 2026-10-15: empty), and no open PR adds that version (#2594 adds
  `20261015000001`, #2593 `20261014000003`).
- Why a column and not a tenant-schema table: (a) both auth paths already read the tenant row
  uncached, so "read per request" costs nothing and keeps the API-token query count (AC6); (b) the
  DB CHECK makes `on` unrepresentable until stage 2 widens it (stage 2 alters the CHECK in its own
  migration); (c) `tenant_config` / `tenant_settings` write only the `settings` embed and
  `admin_patch_changeset/2` casts only `display_name, login_disclosure_mode`
  (`lib/letflow/identity/tenant.ex`), so the generic APIs cannot reach it; entities cannot reach a
  public table at all.
- `Letflow.Identity.Tenant`: `field(:scope_enforcement, Ecto.Enum, values: [:off, :shadow],
  default: :off)`; new `@spec scope_enforcement_changeset(t(), %{scope_enforcement: :off | :shadow})
  :: Ecto.Changeset.t()` that casts ONLY that field and adds `check_constraint` for the CHECK name.
  No other changeset casts it (T-F7 asserts `create_changeset/3`, `admin_patch_changeset/2`,
  `settings_changeset/2`, `realm_bind_changeset/2`, `status_changeset/2` drop the key).
- Pooled test tenants: `TenantFixture`'s pool snapshots `public.tenants` rows
  (`test/support/tenant_fixture.ex:1572`), so a flipped pooled tenant is detected and re-cloned.
  Flip tests use a dedicated `TenantFixture.provisioned_tenant!/1` tenant.

### 3.2 `Letflow.ScopeEnforcement` - new file `lib/letflow/scope_enforcement.ex`

```
@type mode :: :off | :shadow
@type precondition :: :bindings_without_row | :org_inconsistent | :tokens_exceed_owner
@type precondition_report :: %{
        bindings_without_row: non_neg_integer(),
        org_consistency: :ok | :inconsistent | :unavailable,
        tokens_exceeding_owner: non_neg_integer()
      }
@type flip_error ::
        :invalid_mode | :reason_required | :invalid_reason | :tenant_not_found
        | :tenant_prefix_mismatch
        | {:precondition_failed, [precondition()], precondition_report()}
        | {:audit_failed, term()} | {:transaction_failed, Exception.t()}
```

| Function | Spec | Contract |
|---|---|---|
| `modes/0` | `@spec modes() :: [mode()]` | `[:off, :shadow]`. |
| `parse_mode/1` | `@spec parse_mode(term()) :: {:ok, mode()} \| {:error, :invalid_mode}` | Exactly the strings `"off"`, `"shadow"`. Every other value, `"on"`, `"ON"`, `nil`, non-strings included, is `:invalid_mode`. No atom is minted from input. |
| `get_mode/1` | `@spec get_mode(tenant_id :: Ecto.UUID.t()) :: {:ok, mode()} \| {:error, :tenant_not_found}` | One read of the tenant row. |
| `preconditions/1` | `@spec preconditions(prefix :: String.t()) :: precondition_report()` | Read-only, the three Rollout-4 facts: `RoleScopeGrants.bindings_without_row_count/1` (T9); `ScopeNodePaths.Consistency.check/1` status (`{:error, _}` -> `:unavailable`, which fails the precondition); `TokenPreconditions.exceeding_owner_count/1` (section 7). Writes nothing, no audit. Inside the flip it sees the flip transaction's locks. |
| `flip/4` | `@spec flip(tenant_id :: Ecto.UUID.t(), prefix :: String.t(), target :: mode(), attrs :: %{actor_id: Ecto.UUID.t() \| nil, reason: term(), trace_id: String.t() \| nil}) :: {:ok, %{mode: mode(), previous: mode(), changed: boolean()}} \| {:error, flip_error()}` | Section 3.3. |

### 3.3 `flip/4` transaction (server-side preconditions, D12, Rollout 4)

Before the transaction (no DB): `prefix` must equal `TenantProvisioning.schema_name_for_tenant(tenant_id)`
(else `:tenant_prefix_mismatch`); for `target == :off`, `reason` validated by the shared rule of
section 3.5 (`nil`/missing -> `:reason_required`; failing the rule -> `:invalid_reason`); for
`target == :shadow` a reason is optional, validated the same way when present.

One `Repo.transaction` (wrapped in `try/rescue` -> `{:transaction_failed, e}`), in this order:

1. `Identity.lock_tenant_admins!(prefix)` (lock A). Every binding writer, every membership
   writer, token mint/revoke and the backfill take A first, so T9 and the token/owner role facts are
   stable until commit.
2. The `tenants` row by id `FOR UPDATE` (public; new rank T). `nil` -> rollback
   `:tenant_not_found`.
3. Current mode == target -> return `{:ok, %{mode: m, previous: m, changed: false}}`: no write, no
   audit, no precondition check (idempotent PUT).
4. `target == :shadow` (off -> shadow): `ScopeNodePaths.lock!(prefix)` (rank S, SHARE ROW
   EXCLUSIVE: no tree write can commit between the check and the flip), then `preconditions/1`.
   Any failing fact (`bindings_without_row > 0`; `org_consistency != :ok`;
   `tokens_exceeding_owner > 0`) -> rollback `{:precondition_failed, failed_list, report}`. ALL
   three are evaluated so the response names every failure. Non-expiring PLATFORM_ADMIN tokens and
   NULL-issuer tokens are NOT a precondition (B5).
5. `target == :off` (shadow -> off): no precondition (turning a non-enforcing mode off is never
   blocked); the reason is mandatory (step 0).
6. `Repo.update(Tenant.scope_enforcement_changeset(tenant, %{scope_enforcement: target}))`.
7. `Audit.insert_entry(Repo, attrs, prefix)` in the SAME transaction (rank C; an `{:error, r}`
   rolls back with `{:audit_failed, r}`):
   - off -> shadow: `action: "scope.enforcement_enabled"`;
   - shadow -> off: `action: "scope.enforcement_disabled"`;
   - both: `actor_id`, `trace_id` from attrs; `resource_type: "tenant"`, `resource_id: tenant_id`;
     `before_state: %{"mode" => previous}`; `after_state: %{"mode" => target, "reason" => reason
     or nil, "preconditions" => %{"bindings_without_row" => n, "org_consistency" => "ok",
     "tokens_exceeding_owner" => n}}` (the `preconditions` key only on enable). D8 names reused
     with mode metadata; no new event names (REQ-497 open question 1, decided).

A refused flip writes NO audit entry (D12 audits flips; a refusal is a read result, it changes
nothing) and no `token.listed` (no token is disclosed; section 7.3).

### 3.4 Routes - new router `Letflow.Routers.TenantScopeEnforcement`

File `lib/letflow/routers/tenant_scope_enforcement.ex`, `use Letflow.Api.AuthorizedRouter`,
mounted in `lib/letflow/plugs/api_pipeline.ex` next to `:155` with
`forward("/tenant/scope-enforcement", to: Letflow.Routers.TenantScopeEnforcement)`. Tenant from
`conn.assigns.auth_context.tenant_id` and `scoped_opts[:prefix]` ONLY (INV-1); no tenant in path,
query or body. `authz_unmatched(:ordinary)`.

| Route (full path under `/api/v1`) | Policy key | `required_permission/1` | Handler gate after the plug |
|---|---|---|---|
| `GET /tenant/scope-enforcement` | `:ScopeEnforcementRead` | `:UsersGroupsRolesManage` | `require_tenant_wide/2` |
| `PUT /tenant/scope-enforcement` | `:ScopeEnforcementManage` | `:UsersGroupsRolesManage` | `require_tenant_wide/2` |
| `GET /tenant/scope-enforcement/integrity` | `:ScopeGrantsIntegrityRead` | `:UsersGroupsRolesManage` | `require_tenant_wide/2` (section 8) |
| `GET /tenant/scope-enforcement/token-preconditions` | `:ScopeEnforcementTokensRead` | `:UsersGroupsRolesManage` | `require_tenant_wide/2` (section 7) |

`lib/letflow/api/authorization.ex`: the four keys join the `endpoint_policy_key()` type, four
`endpoint_policy_key/2` clauses next to `:1130` (same shape as `:ScopeNodePathsConsistencyRead`),
four `required_permission/1` clauses next to `:1356`. All tenant scope: holders are TENANT_ADMIN
and, in the platform tenant only, PLATFORM_ADMIN (ISS-0993). "Platform scope" in D12 is therefore
a platform-tenant PLATFORM_ADMIN acting on the platform tenant's own flag (step 4 of 1.4 allows it
without reading rows); a cross-tenant platform route is OQ-1 (ruled: #2535, optional).

Who is refused (AC7): a caller without `:UsersGroupsRolesManage` gets the plug's 403; a
TENANT_ADMIN whose TA scope is not tenant-wide (only scoped rows, inserted directly in tests) gets
403 `insufficient permissions` from `require_tenant_wide/2` (`{:deny, :not_tenant_wide}`).

PUT body: `{"mode": string, "reason": string?}` (validated with `Letflow.Api.Validation`; unknown
keys ignored except none are read). Responses (stable codes, `Response.unprocessable/2` /
`Response.conflict/2` style):

| Outcome | Status | Body / code |
|---|---|---|
| ok | 200 | `{"mode": "off"\|"shadow", "previous": ..., "changed": bool}` |
| `:invalid_mode` (incl. `"on"`) | 422 | `invalid_enforcement_mode` |
| `:reason_required` | 422 | `reason_required` |
| `:invalid_reason` | 422 | `invalid_reason` (same code as rebind) |
| `{:precondition_failed, failed, report}` | 409 | code `enforcement_precondition_failed`, plus `"failed": [..]` (atom names as strings) and `"report"` (the three counts/status only; no ids, no names, INV-2) |
| `:tenant_not_found`, `:tenant_prefix_mismatch`, `{:audit_failed, _}`, `{:transaction_failed, _}` | 500 | `Response.internal_error/1` |

GET body: `{"mode": "off"|"shadow", "available_modes": ["off", "shadow"]}`.

### 3.5 Shared reason rule

The rebind reason rule (`RoleRegistry.validate_reason/1`, private, `role_registry.ex:754-764`:
string, trimmed, 1..500 codepoints, no Cc/Cf/Zl/Zp) is extracted to a public
`@spec Letflow.Audit.Reason.validate(term()) :: {:ok, String.t()} | :error` in new file
`lib/letflow/audit/reason.ex`; `rebind_role/4` and `flip/4` both call it. Behaviour of rebind is
unchanged (its existing tests pin it).

---

## 4. Shadow evaluation and counters (AC8, Rollout 3)

### 4.1 Hook: `Letflow.Plugs.Authorize.call/2` (`lib/letflow/plugs/authorize.ex:138-144`)

In the allow branch (`:Allow` / `:AllowWithRowFilter`), AFTER the two `assign/3` calls (r1, SEC A6:
so `conn.assigns.scoped_opts[:prefix]`, taken from the plug's own `{:ok, prefix: schema}` result,
is the prefix the observer uses; it never derives a prefix itself), add one call:
`Letflow.Api.Scope.Shadow.observe(conn, ctx, policy_key)` when
`Map.get(conn.assigns.auth_context, :scope_enforcement) == :shadow`. The deny branch and every
response are unchanged. The return value of `observe/3` is ignored except for the conn (it may carry
the grants memo); it NEVER halts, never changes status, body or assigns other than the memo.

Why there: it is the single point after `evaluate_access/2` on every authorized route (D4: called
after the coarse check), it already has the recomputed `platform_tenant?`, and routes declare no
resource scope in stage 1 (D5 is #2535), so the resource scope evaluated is `:tenant_wide` for
every route (a principal holding its role with no row, or with only scoped rows, is a would-deny).
The marker keys `:Unknown`, `:UnmatchedRoute`, `:UnmatchedPlatformPath`, `:MetricsRead` are skipped.

### 4.2 `Letflow.Api.Scope.Shadow` - new file `lib/letflow/api/scope/shadow.ex`

| Function | Spec | Contract |
|---|---|---|
| `observe/3` | `@spec observe(Plug.Conn.t(), Authorization.AccessContext.t(), policy_key :: atom()) :: Plug.Conn.t()` | `principal_from_conn/1` (uses the pipeline memo: 0 queries for OIDC, which always carries it after r1, and 0 for tokens); `allowed?(p, Authorization.required_permission(policy_key), :tenant_wide)`. `{:allow, _}` -> nothing. `{:deny, reason}` -> one telemetry event and one sampled log line (4.3). `{:error, :no_principal}` -> counted as reason `:grants_unavailable`. Any exception, exit or throw is caught: one constant log line `scope_shadow_failed class=... exception=<module>` (once per boot per class/module, the same mechanics as `AuthzDenyLog`'s private `note_failure/2`), the original conn returned. Never raises. |

### 4.3 Counter and log (INV-4, INV-2)

- Telemetry: `:telemetry.execute([:letflow, :scope, :shadow, :would_deny], %{count: 1},
  %{reason: deny_reason(), policy: policy_key})`.
- Metrics: `lib/letflow/metrics/registry.ex` gains family `letflow_scope_shadow_would_deny_total`,
  counter, ONE label `reason` (the closed six-value `deny_reason()` set; an unknown value is dropped,
  as the existing label allow-lists do), attached in `dispatch/4` for that event. No tenant or user
  label (the metrics endpoint is global).
- Log: new `Letflow.Api.Scope.ShadowLog` (`lib/letflow/api/scope/shadow_log.ex`), shape
  `scope_shadow_would_deny method=GET route=/api/v1/... policy=UsersManage permission=UsersGroupsRolesManage reason=no_grant_rows credential=oidc caller=<16hex> tenant=<16hex>`
  plus `suppressed=<n>`. Built ONLY from `AuthzDenyLog.method_token/1`, `route_pattern/1`,
  `policy_token/1`, `hash_id/3` and `subkey/0` (all public, `authz_deny_log.ex:179-251`), a
  permission atom name, the reason atom, the credential atom. Its own sampler, same mechanics as
  `AuthzDenyLog` (persistent_term key `{Letflow.Api.Scope.ShadowLog, :sampler}`, window config
  `:scope_shadow_log_window_s`, default 60, slot `{policy, caller hash, tenant hash}`). Never: raw
  path, params, body, headers, token, email, raw ids, role names, node ids, record contents.

### 4.4 Writers under shadow

No binding or membership writer reads the flag in stage 1 (B4: the enforced-tenant branch is
#2535). AC8's "writers behave identically" is therefore structural, and is tested (T-S5).

---

## 5. `exclude_scoped_holders/2` and its twin (AC13)

### 5.1 `exclude_scoped_holders/2` (`lib/letflow/identity.ex:1066-1071`, private)

Restructured so tokens are never excluded (D1: a token principal is tenant-wide by rule):
`tenant_wide_admins_query/2` (:1037-1064) applies `exclude_scoped_holders/2` to the
`member_of_admin_group` subquery (not to the users query); the outer `where` stays
`exists(member_of_admin_group) or exists(owns_live_admin_token)`. Spec unchanged:
`@spec exclude_scoped_holders(query :: Ecto.Query.t(), prefix :: String.t()) :: Ecto.Query.t()`;
its comment block is rewritten to say this.

Predicate added (bound parameters; `parent_as(:user)` and the subquery's `tr` binding): the member
is kept unless they are a **scoped-only holder**, i.e. at least one `role_scope_grants` row with
`role = "TENANT_ADMIN"`, `tenant_wide = false` exists for (`user`, the user id) or (`group`,
`tr.group_id`), AND no row with `tenant_wide = true` exists for either.

Consequences, stated for SECURITY-REVIEWER:
- With only tenant-wide rows (every real tenant in stage 1) nothing is excluded: counts equal
  today's (AC13 second half; the T-35 oracle keeps passing unchanged).
- A binding with ZERO rows (a T9 gap) is still counted: stage 1 is pre-enforcement and a gap must
  not silently drop the last admin from N1 (the gap itself blocks the flip). Stage 2 (#2535)
  revisits "zero rows means not tenant-wide" for the enforced branch (section 15).
- A TA token owner is counted whatever their rows (Option A ruling for `revoke_token` relies on it).

### 5.2 `exclude_scoped_role_names/3` (#2552, private in `identity.ex`)

Filled with the same rule per role: from `names`, drop a role R when (`user`, U, R) or (`group`, the
group bound to R, R) has at least one scoped row and neither has a tenant-wide row. One query for
the whole set. Identity in stage 1 for every real tenant. Spec unchanged.

### 5.3 T-34 tripwire

`test/letflow/identity/tenant_wide_admins_test.exs:492-532` (retargeted in 1a) is REPLACED by
T-X1..T-X4 (section 12.5) in the same file; its failure-message text goes with it.

---

## 6. N1 last-admin guard (AC9, AC10, AC11, AC12)

### 6.1 `Letflow.Identity.TenantAdminGuard` - new file `lib/letflow/identity/tenant_admin_guard.ex`

**Shared contract (r1, SEC A1, pinned with letflow-3 for #2564; binding):**

| Item | Value |
|---|---|
| HTTP status and code of every N1 count refusal | **409 `last_tenant_wide_admin`** (`Response.conflict(conn, "last_tenant_wide_admin")`) |
| Function error atom | `{:error, :last_tenant_wide_admin}` |
| Event | `tenant_admin.guard_refused` |
| `after_state` keys | EXACTLY `"action"`, `"actor"`, `"target_id"`, `"reason_code"`, `"counted_admins"`, `"trace_id"` |
| `reason_code` | `"last_tenant_wide_admin"` (the only value) |
| `action` values (1b) | `"unbind_tenant_admin"` (POST /roles kind change), `"remove_tenant_admin_member"`, `"rebind_tenant_admin"`, `"revoke_pending_grant"`, `"revoke_token"` |
| `action` value (#2564) | `"deactivate_user"` |

```
@type action :: :unbind_tenant_admin | :remove_tenant_admin_member | :rebind_tenant_admin
              | :revoke_pending_grant | :revoke_token | :deactivate_user
@type refusal :: %{action: action(), target_id: String.t(), counted_admins: non_neg_integer()}
@type refuse_opt :: {:platform_companion, platform_prefix :: String.t()}
```

| Function | Spec | Contract |
|---|---|---|
| `lock_admin_binding!/1` | `@spec lock_admin_binding!(prefix :: String.t()) :: TenantRole.t() \| nil` | #2547 6.4 step 2: the `tenant_role` row `name = "TENANT_ADMIN"` (no `kind` filter) `FOR UPDATE`. Raises outside a transaction. Caller holds A. |
| `admin_group_id/1` | `@spec admin_group_id(TenantRole.t() \| nil) :: Ecto.UUID.t() \| nil` | Group id when the row is `:platform_role`, else `nil`. Pure. |
| `ensure_admins_remain!/3` | `@spec ensure_admins_remain!(prefix :: String.t(), action(), target_id :: String.t()) :: :ok` | After the write, in the same transaction: `Identity.count_tenant_wide_admins(prefix)`; `> 0` -> `:ok`; `0` -> `Repo.rollback({:tenant_admin_guard, %{action:, target_id:, counted_admins: 0}})`. Raises `ArgumentError` outside a transaction. |
| `refuse/4` | `@spec refuse(prefix :: String.t(), refusal(), AuditContext.t(), [refuse_opt()]) :: {:error, :last_tenant_wide_admin}` (`refuse/3` = `refuse(prefix, refusal, ctx, [])`) | Called by the public function AFTER its transaction returned the rollback value, i.e. outside any transaction (precondition; when `Repo.in_transaction?()` is true it writes nothing and logs a constant line, because an inner write would roll back with the caller). ONE `Repo.transaction` of its own (post-rollback), via `Audit.insert_entry/3`: **(1) tenant chain** (`prefix`): `action: "tenant_admin.guard_refused"`; `resource_type` per action (`"tenant_role"`, `"group_member"`, `"api_token"`, `"pending_admin_grant"`, `"user"`); `resource_id: target_id`; `before_state: nil`; `after_state` the six contract keys. Without opts, `actor_id`/`"actor"` and `trace_id`/`"trace_id"` come from `ctx`. **With `platform_companion: platform_prefix` (r1, SEC B1):** the tenant-chain entry has `actor_id: nil`, `"actor" => nil`, `trace_id: nil`, `"trace_id" => nil` (no platform user id ever enters a tenant chain), and **(2)** a companion `tenant_admin.guard_refused` entry is written LAST on the PLATFORM chain (`platform_prefix`) with the operator as `actor_id`/`"actor"`, the request trace, the same `action`, `target_id`, `reason_code`, `counted_admins` keys, `resource_type: "pending_admin_grant"`. Both entries commit or neither. An audit failure is logged as a constant line (no ids) and the refusal is still returned (the guarded change stays rolled back; INV-8). Always returns `{:error, :last_tenant_wide_admin}`. |

#2564 (deactivation) reuses `ensure_admins_remain!/3` and `refuse/3` with action
`:deactivate_user`; one event, one helper (0051 D8 "no path invents its own name").

### 6.2 Per-path guard (file:line on c55baa4f5)

Every guarded transaction keeps `lock_tenant_admins!/1` as its first locking statement. "Count"
always means `count_tenant_wide_admins/1` AFTER the write. Every count refusal returns
`{:error, :last_tenant_wide_admin}` and HTTP **409 `last_tenant_wide_admin`** (6.1 contract).

Already-zero rule (r1, CDV adv 4; AC9 "roll back on 0", #2547 6.4 "write, then count, then roll
back on 0"): for (a) kind change, (b) remove member and (c) rebind, once the trigger matches, the
guard refuses whenever the count after the write is 0, INCLUDING when it was already 0 before
(e.g. removing an inactive member from the TA group of a tenant with no counted admin). The guard
measures state, it does not compare before/after. (f) differs by the ruling in its row.

| N1 path | Function and insertion point | Trigger (only then is the count run) | Error returned / route mapping |
|---|---|---|---|
| (a) POST /roles kind change | `RoleRegistry.converge_existing_role/5` (`role_registry.ex:550-572`), `true` branch, after `audit_binding_write` (:565) | `role.name == "TENANT_ADMIN"`, `role.kind == :platform_role`, new `kind != :platform_role` -> `ensure_admins_remain!(prefix, :unbind_tenant_admin, role.id)`. The role row is already locked by name (:473, :501). | `do_upsert_role/4` maps `{:error, {:tenant_admin_guard, r}}` after the transaction to `TenantAdminGuard.refuse/3`; `upsert_role/4` returns `{:error, :last_tenant_wide_admin}` (add to `upsert_error`). Router `upsert_role/5` (`routers/identity.ex:947-982`) adds the 409 clause. Nested callers (seeding W4, TenantAdminMigration W5) never convert a TA binding away from platform, so they cannot reach it. |
| (b) remove member | `Identity.do_remove_group_member/4` (`identity.ex:915-936`) | Insert `TenantAdminGuard.lock_admin_binding!(prefix)` right after `lock_tenant_admins!` (:916), before the group KEY SHARE (:920). After the delete (:924-926), when `count == 1` AND `group_id == admin_group_id(binding)`: `ensure_admins_remain!(prefix, :remove_tenant_admin_member, user_id)`, BEFORE the membership audit (:929). | `remove_group_member/3` maps the rollback value to `refuse/3`; adds `{:error, :last_tenant_wide_admin}` to its spec. Router (`routers/identity.ex:758-763`) adds the 409 clause. A non-last admin's removal and every non-TA group are unaffected. |
| (b') delete_group | `Identity.delete_group/2` (`identity.ex:752-799`) | NONE. The TA group is bound, so the FK refusal (`:bound_to_role`) or the members refusal (`:not_found_or_has_members`) fires as today, under the lock (:767). No count, no event. | Unchanged. |
| (c) rebind | `RoleRegistry.move_role/6` (`role_registry.ex:711-739`), after `reconcile_binding!` (:723), before the `role.rebound` audit (:725) | `role.name == "TENANT_ADMIN"` and `role.kind == :platform_role` -> `ensure_admins_remain!(prefix, :rebind_tenant_admin, role.id)`. | `rebind_role/4` (:677-709) maps it to `refuse/3`, returns `{:error, :last_tenant_wide_admin}`. **Closes GH #2575** (supervisor ruling on OQ-2; the PR body carries "Closes #2575"). **Rescue added (1a section 10 item 1b-3, GH #2575):** `rebind_role/4` wraps its `Repo.transaction` in `try/rescue exception -> {:error, {:transaction_failed, exception}}`; `rebind_error` gains both. Router `handle_rebind_role/3` (`routers/identity.ex:1003-1014`) adds `{:error, :last_tenant_wide_admin}` -> 409 and `{:error, {:transaction_failed, _}}` -> `Response.internal_error/1`. 1a's T-W8 R2 changes from `assert_raise Postgrex.Error` to asserting `{:error, {:transaction_failed, %Postgrex.Error{}}}` with nothing written. |
| (d) pending-grant revoke | `PendingAdminGrants.revoke/3` (`pending_admin_grants.ex:275-332`) | New FIRST Multi step `:tenant_admin_lock` -> `Identity.lock_tenant_admins!(prefix)` (AC12), then `:grant` (:282). New step `:tenant_admin_guard` after `:revoke` (:283-294), before `:tenant_audit`: if no OTHER open grant remains (count of grants with `consumed_at` and `revoked_at` nil, after the revoke, is 0) AND `count_tenant_wide_admins(prefix) == 0` -> `{:error, %{action: :revoke_pending_grant, target_id: grant_id, counted_admins: 0}}`. | The `case` (:320-329) gains `{:error, :tenant_admin_guard, refusal, _}` -> `refuse(prefix, refusal, ctx, platform_companion: platform_prefix)` (ctx: actor = the operator `user_id`, trace from `opts[:trace_id]`; r1 SEC B1: the tenant-chain entry carries nil actor and nil trace, the operator and trace go only into the companion PLATFORM-chain entry, written last in the same post-rollback transaction) -> `{:error, :last_tenant_wide_admin}`; spec updated. Router `handle_revoke_pending_admin/3` (`routers/onboarding.ex:985-990`) adds the 409 clause. |
| (e) reactivation lock | `Identity.update_locked_user/5` (`identity.ex:418-462`) | New FIRST Multi step `:tenant_admin_lock` -> `lock_tenant_admins!(prefix)`, before `:locked_user` (:423). Applies to `update_user_status/3` (AC12) and, because the helper is shared, to `update_user_profile/3` (`identity.ex:378`); no count here (reactivation only adds admins; the deactivation count is #2564's, which builds on this lock). | No new error. |
| (f) revoke_token | `Identity.revoke_locked_token/3` (`identity.ex:2085-2121`; #2594 keeps it, `token_audit_state/1` for states) | r1 (CDV B3, SEC A3): `lock_admin_binding!/1` UNCONDITIONALLY, right after `lock_tenant_admins!` (:2086) and BEFORE the token row `FOR UPDATE` (:2088), matching #2547 6.4 order A -> R -> B. r1 (CDV B2): the guard runs ONLY when the locked token was COUNTED at lock time, i.e. on the row read `FOR UPDATE`: `revoked_at` nil, `expires_at` nil or after now (the `count_tenant_wide_admins/1` second-truncated `now`), owner active (`Identity.active_user?/1` on the owner row, read in the same transaction), and `roles` contain `"TENANT_ADMIN"`. Then, after the `Repo.update` (:2100-2104) and BEFORE the `token.revoke` audit: `ensure_admins_remain!(prefix, :revoke_token, token.id)`. An uncounted token (expired, inactive owner, no TA role) revokes without a count, even in a 0-admin tenant. A TA-group member who also owns the token keeps the count > 0 (Option A). | `revoke_token/2` (:2057) maps the rollback value to `refuse/3`, returns `{:error, :last_tenant_wide_admin}` (spec updated). Router `handle_revoke_token/3` (`routers/identity.ex:849-860`) adds the 409 clause. |

Rollback mechanics: every path uses `Repo.rollback/1` (or a Multi `{:error, _}`) so the write and
any audit of the write are undone; the guard event is written only afterwards by `refuse/3`.

---

## 7. Flip-precondition token listing (AC14, M2 (d), N2)

### 7.1 `Letflow.Identity.TokenPreconditions` - new file `lib/letflow/identity/token_preconditions.ex`

```
@type item :: %{token: ApiToken.t(), status: :active | :owner_inactive}
@type findings :: %{roles_exceed_owner: [item()], non_expiring_platform_admin: [item()],
                    null_issuer: [item()]}
```

| Function | Spec | Contract |
|---|---|---|
| `findings/1` | `@spec findings(prefix :: String.t()) :: findings()` | Read-only. `{:ok, items} = Identity.list_tokens(prefix: prefix)` (#2552 shape: `{:ok, [%{token: ApiToken.t(), owner_active: boolean()}]}`) once; status of each by `Identity.token_effective_status(token, owner_active, now)` (`now` taken once). Only tokens with status `:active` or `:owner_inactive` are considered (revoked and expired tokens can never authenticate again; an inactive owner's token comes back on reactivation, so it counts). Category (i): `MapSet.new(token.roles)` NOT a subset (`MapSet.subset?/2`) of `Identity.tenant_wide_role_names(token.user_id, prefix: prefix)`, which returns a `MapSet.t(String.t())`; that function is called once per DISTINCT owner. (ii): `"PLATFORM_ADMIN"` in roles and `expires_at` nil. (iii): `issuer_user_id` nil. A token may appear in several categories. Each list keeps `list_tokens/1`'s order. |
| `exceeding_owner_count/1` | `@spec exceeding_owner_count(prefix :: String.t()) :: non_neg_integer()` | `length(findings(prefix).roles_exceed_owner)`; the flip's precondition. No audit (it discloses nothing). |

### 7.2 Route `GET /tenant/scope-enforcement/token-preconditions`

Gate: section 3.4 (`:ScopeEnforcementTokensRead`, then `require_tenant_wide/2`); a caller without
the permission gets 403 (AC14). Handler: `findings/1`, then the audit (7.3), then the body. If the
audit write fails the handler answers 500 and returns NO token data (fail closed: no unaudited
listing).

Body:
```
{"flip_blocked": bool,
 "blocking": {"roles_exceed_owner": [token_map, ...]},
 "information": {"non_expiring_platform_admin": [token_map, ...], "null_issuer": [token_map, ...]},
 "count": n}
```
`token_map` is #2552's map with keys EXACTLY {id, name, user_id, issuer_user_id, roles, status,
created_at, expires_at, revoked_at, last_used_at}, status the lowercase string of
`token_effective_status/3`. To reuse it rather than copy it, #2594's private
`Letflow.Routers.Identity.token_map/2` (`routers/identity.ex` in the #2594 diff) is moved verbatim to
a public `@spec Letflow.Api.TokenView.token_map(ApiToken.t(), :revoked | :expired | :owner_inactive
| :active) :: map()` in new file `lib/letflow/api/token_view.ex`; both routers call it. It
structurally has no hash or plaintext input (INV-4). `count` = number of DISTINCT tokens in the
three lists.

### 7.3 `token.listed` (N2)

One `Audit.insert_entry/3` per call, its own transaction, tenant chain: `action: "token.listed"`,
`actor_id` = caller, `trace_id` = request trace, `resource_type: "api_token_listing"`,
`resource_id` = tenant id string, `before_state: nil`, `after_state` EXACTLY `%{"actor" =>
actor_id, "count" => n, "token_ids" => sorted distinct ids}`. Never a value, hash, prefix, name or
role. The flip's internal precondition read writes no `token.listed`.

---

## 8. Integrity-check endpoint (AC16; REQ-497 open question 3)

`GET /api/v1/tenant/scope-enforcement/integrity` (section 3.4; `:ScopeGrantsIntegrityRead` ->
`:UsersGroupsRolesManage`, then `require_tenant_wide/2`). Read-only, no audit (it shows binding
metadata already visible on `GET /roles`). Tenant from auth only. Body built field by field:
```
{"bindings_without_row": n,
 "items": [{"role_id": ..., "name": ..., "group_id": ...}, ...],   # RoleScopeGrants.bindings_without_row/1, capped at 1000
 "orphan_group_rows": m,                                            # length of RoleScopeGrants.orphan_group_rows/1
 "truncated": bool}
```
It sits beside, not inside, the #2530 consistency endpoint (`routers/tenant_scope_node_paths.ex`),
because that router is the 0050 tree's and this is the grant table's.

---

## 9. Route walk (AC15, N4)

New test file `test/letflow/api/scope_grants_route_walk_test.exs` (async false, dedicated tenants):

- **T-RW1 static writer pin (AST over `lib/**/*.ex`, as `managed_types_callers_test.exs` does):**
  the `RoleScopeGrant` schema and the literal `"role_scope_grants"` are referenced for writing
  (`Repo.insert*`, `update_all`, `delete_all`, raw SQL) only in
  `lib/letflow/identity/role_scope_grants.ex` and the 1a migration; no public function of
  `RoleScopeGrants` accepts a `scope_node_id` or writes `tenant_wide: false` (its writer set is
  exactly the six 1a writers). This is the proof for routes the dynamic walk cannot reach with a
  valid body. (Also closes 1a OQ-4.)
- **T-RW2 dynamic walk:** in a dedicated tenant, a test-installed trigger on `role_scope_grants`
  raises on any INSERT/UPDATE/DELETE where `NEW.tenant_wide = false` or `OLD.tenant_wide = false`.
  For EVERY `{method, path, key}` of every router's `__authz_routes__/0` (the set
  `authorization_enforcement_test.exs:189-196` walks), the route is called once as a TENANT_ADMIN
  of the tenant (and, for platform keys, as a platform-tenant PLATFORM_ADMIN) with an empty body,
  and the identity/onboarding binding and membership routes (POST /roles both kinds, rebind, POST
  and DELETE /groups/:id/members, DELETE /groups/:id, POST/DELETE /tokens, POST /users/:id/status,
  the onboarding pending-admin routes, PUT /tenant/scope-enforcement both ways) additionally with a
  valid fixture body. r1 (CDV adv 3): Assert the FULL `role_scope_grants` row set (every column)
  is identical before and after each route call, except for tenant-wide group-row changes that
  the 1a writer cascades explain (`reconcile_binding!/3` on a kind change or rebind,
  `delete_group_principal_rows!/2` on a group delete), which the test computes from the call and
  checks exactly; and `user_row_count` stays 0. The UPDATE/DELETE half of "no scoped row is
  changed" is EMPTY BY CONSTRUCTION: no scoped row exists in the tenant (stage 1 creates none, the
  test inserts none), so the trigger's OLD-side condition can only fire if a route created one
  first, which the INSERT side already catches. The trigger stays as a tripwire.
- **T-RW3 N4 routes:** the routes calling `Entities.Definitions.create_definition` /
  `activate_definition` (`routers/entities.ex:463` create, `:774` activate) and the module/solution
  install routes reaching `SolutionPack.install` (`solution_pack.ex:1654`) and
  `Modules.EntityActivation` (`entity_activation.ex:105`) are each driven with a valid body; assert
  no `role_scope_grants` row changes (full row set equal before/after) and that a create with a
  managed name returns the #2530 refusal unchanged (0050 D7).
- **T-RW4 provisioning under the managed-name rule:** AST pin that `lib/letflow/tenant_provisioning.ex`
  and `lib/letflow/tenant_onboarding.ex` call neither `create_definition` (any arity) nor
  `activate_definition`, nor `SolutionPack.install`, nor write `EntityDefinition` /
  `"entity_definitions"`; and a behavioural check: provisioning a new tenant plus
  `TenantProvisioning.ensure_column_promotions/2` over an installed managed type leaves that
  type's `managed_by` and name unchanged (the 0050 D7 trigger stays the backstop).

---

## 10. Lock order and overlap with open work

Ranks (extending #2547 design 6.6 / 1a section 3): **A** tenant admin advisory lock < **R** the
TENANT_ADMIN `tenant_role` row (by name or id) < **G** group row < **B** business rows
(`group_members`, `api_tokens`, `users`, pending grant, `role_scope_grants`) < **T** public
`tenants` row (flip only) < **S** `scope_node_paths` table lock (flip only) < **C** audit chain.
Every 1b path takes A first. The guard event (`refuse/4`) takes only C (tenant chain, then platform chain for the pending-grant companion), in a transaction opened
after the guarded one ended. r1 (SEC A4) corrected: T (the `tenants` row) is also row-locked by
existing paths (realm bind, the tenant status updates and the settings/admin-patch updates in
`identity.ex`), but none of them takes A afterwards, so the flip's A -> T order cannot form a
cycle with them. S is taken by tree writers (`ScopeNodePaths.write/2`) and module installs without
A; no path takes S and then A. **S is never taken before A** by any path that takes both: 1b adds
that sentence to the `Letflow.ScopeNodePaths` moduledoc (`lib/letflow/scope_node_paths.ex`, doc
only, no code change).

| In flight | Touches | Interaction | Order rule |
|---|---|---|---|
| #2594 (GH #2552, letflow-3) | `identity.ex` token functions, `routers/identity.ex` token routes, `api_tokens` migration | 1b builds on it (B6) and edits `revoke_locked_token/3`, `handle_revoke_token/3`, moves `token_map/2`, fills `exclude_scoped_role_names/3`. 1b starts after it merges. | mint/revoke: A first (unchanged). |
| #2564 (deactivation, `state:ready`) | `update_locked_user/5`, PATCH /users/:id | 1b adds the A lock as that Multi's first step; #2564 adds its count after the write with `TenantAdminGuard` (`:deactivate_user`, 409 `last_tenant_wide_admin`, pinned with letflow-3). Whoever merges second rebases; the lock stays the first step. | A first. |
| #2593 / 7b-2b (letflow-4) | script publish SoD reads `tenant_wide_admin_user_ids/1` under A | 5.1 changes the shared query; identity for every stage-1 tenant (T-35 oracle unchanged). | A first. |
| GH #2575 (open, rebind rescue) | `rebind_role/4`, rebind router clauses | 1b delivers its three ACs and CLOSES it ("Closes #2575" in the PR body; supervisor ruling), tests T-G3, T-G9. | A first. |

---

## 11. Test-support change (ORCH input on `token_mint_fixture.ex`)

Decided: **change the fixture**, not the tests. The PRIVATE `binding_group_id!/2` of
`Letflow.Support.TokenMintFixture` (`test/support/token_mint_fixture.ex`, added by #2594; reached
through the public `grant_roles!/3` and `role_holder!/3`), new-binding branch: insert the group, the
`:platform_role` binding and its tenant-wide group row inside one `Repo.transaction`, the row via
`Letflow.Identity.RoleScopeGrants.ensure_tenant_wide_group_row!/3`. Reason: the fixture's contract
is "raw rows, no audit entry"; routing it through `RoleRegistry.upsert_role/4` would add
`role_binding.created` audit rows that #2552's tests do not expect, and every 1b test that asserts
T9 == 0 (flip precondition, shadow, integrity) and uses `role_holder!/3` then stays gap-free. The
existing-binding branch is unchanged. The other raw binding inserters
(`test/support/role_scope_grants_fixture.ex` `raw_binding!/4`, `sod_support.ex`,
`tenant_admin_migration_fixture.ex`) are left as they are (1a OQ-2): they are used where a gap is
the point or T9 is not asserted; any 1b test that needs T9 == 0 creates bindings through the
writers or through `TokenMintFixture`.

---

## 12. Tests (TEST-DESIGNER writes them; ids are the contract)

New files: `test/letflow/api/scope_test.exs`, `test/letflow/plugs/auth_pipeline_scope_test.exs`,
`test/letflow/scope_enforcement_test.exs` (+ router tests in
`test/letflow/routers/tenant_scope_enforcement_test.exs`), `test/letflow/api/scope_shadow_test.exs`,
`test/letflow/identity/tenant_admin_guard_test.exs`, `test/letflow/identity/token_preconditions_test.exs`,
`test/letflow/api/scope_grants_route_walk_test.exs`. All under AC17's scoped paths except
`scope_enforcement_test.exs`, which ELIXIR-DEV adds to the AC17 run list. Scoped and user rows are
inserted directly by fixtures (`RoleScopeGrantsFixture`), never by a route.

### 12.1 AC5 `allowed?/3` (`scope_test.exs`, table-driven)

| Id | Case | Expected |
|---|---|---|
| T-A1 | own group: user in group G bound to TASK_WORKER, G has its tenant-wide row, permission `:TasksRead`, resource `:tenant_wide` | `{:allow, :tenant_wide}` |
| T-A2 | G has a tenant-wide row AND a scoped row (tenant-wide within a principal wins), resource `{:node, other}` | `{:allow, :tenant_wide}` |
| T-A3 | union across principals: user row on node N1, group row on N2; resources N1, child of N2, N3 | allow `:subtree`, allow `:subtree`, `{:deny, :out_of_scope}` |
| T-A4 | a tenant-wide USER row for PROCESS_DESIGNER while the user holds PROCESS_DESIGNER through no group; permission `:EntitiesDefinitionsWrite` (held by PROCESS_DESIGNER, 0051 D6) | `{:deny, :role_not_held}` (the user row has no effect) |
| T-A5 | binding with zero rows | `{:deny, :no_grant_rows}`; never tenant-wide |
| T-A6 | resource `:unresolvable`, for user, token and tenant-wide principals | `{:deny, :unresolvable}` |
| T-A7 | `{:node, id}` missing, malformed (`"a/b"`), and existing; plus a subtree MOVE via `ScopeNodePaths.write/2` | missing/malformed -> `{:deny, :unresolvable}`, no raise; decision follows the CURRENT tree after the move |
| T-A8 | static: `scope.ex` calls `ScopeNodePaths.ancestors/2` and references no `ScopeNodePaths.Node` schema, no `"scope_node_paths"` literal, no `Repo` call outside `load_grants/2` | AST pin |
| T-A9 | platform-scope permission (`:TenantsManage`) by a platform-tenant PLATFORM_ADMIN with its group row present, absent, and replaced by a scoped row; and by a non-platform PLATFORM_ADMIN | identical `{:allow, :platform}` x3; `{:deny, :role_not_held}` (1a 1b-1, INV-10) |
| T-A10 | token principal with scoped rows inserted for its owner's groups | `{:allow, :token}` |
| T-A11 | grants `:not_loaded` | `{:deny, :grants_unavailable}` |
| T-A13 | r1 (SEC A7): permission `:NotARealPermission` for a platform-tenant PLATFORM_ADMIN, a TENANT_ADMIN and a token principal | `{:deny, :role_not_held}` for all three |
| T-A12 | `effective_scope/2` returns `:tenant_wide`, `{:nodes, sorted}`, `:deny` for the T-A1/T-A3/T-A5 fixtures | as stated |

### 12.2 AC6 AuthPipeline (`auth_pipeline_scope_test.exs`, query counts via `[:letflow, :repo, :query]` telemetry)

| Id | Test |
|---|---|
| T-P1 | OIDC, tenant in `off` AND in `shadow`: `auth_context.scope_grants` is a `Grants` struct equal to `load_grants/2`, loaded in the `verify_local_account_state` step; then `principal_from_conn/1` twice on the returned conn issues 0 queries. |
| T-P2 | API token: query count identical with the tenant in `off` and `shadow`, equal to the pinned literal; `scope_grants == :token`. |
| T-P3 | OIDC query count: identical with the tenant in `off` and in `shadow`, and equal to the pinned pre-1b literal + 1 (the grants query); a hand-assigned context without `scope_grants` makes `principal_from_conn/1` load once and a second call issue 0 queries. |
| T-P4 | per-request flag: flip `off -> shadow` through `ScopeEnforcement.flip/4`; the very next request carries `scope_enforcement: :shadow` (no restart, no cache). |

### 12.3 AC7 flag (`scope_enforcement_test.exs`, router tests)

| Id | Test |
|---|---|
| T-F1 | PUT `"on"`, `"ON"`, `"enforce"`, `1`, missing mode -> 422 `invalid_enforcement_mode`, mode unchanged; direct SQL update to `'on'` violates `tenants_scope_enforcement_check`. |
| T-F2 | Not settable elsewhere: `PATCH /tenant/settings`, the tenant_config routes and `PATCH /tenants/:slug` with `scope_enforcement` in the body leave it unchanged; T-F7 changeset pin. |
| T-F3 | caller without `:UsersGroupsRolesManage` (PROCESS_DESIGNER) -> 403; TENANT_ADMIN whose TA group holds only a scoped row (tenant-wide row deleted, scoped row inserted directly) -> 403; tenant-wide TENANT_ADMIN -> 200; platform-tenant PLATFORM_ADMIN on the platform tenant -> 200. |
| T-F4 | precondition T9: a binding without a row (raw insert) -> 409 `enforcement_precondition_failed`, `failed == ["bindings_without_row"]`, mode `off`, no audit entry. |
| T-F5 | precondition org: an inconsistent `scope_node_paths` (raw orphan row) -> 409, `failed == ["org_inconsistent"]`. |
| T-F6 | precondition tokens: a token whose roles exceed its owner's tenant-wide roles (owner removed from the role's group after the mint) -> 409, `failed == ["tokens_exceed_owner"]`. |
| T-F6b | a seeded non-expiring PLATFORM_ADMIN token alone (platform tenant) -> flip succeeds. |
| T-F6c | a seeded NULL-issuer token alone (`create_token/3`) -> flip succeeds. |
| T-F8 | shadow -> off without reason -> 422 `reason_required`; with an invalid reason -> 422 `invalid_reason`; with a reason -> 200. |
| T-F9 | both flips: exactly one `scope.enforcement_enabled` / `scope.enforcement_disabled` entry with the 3.3 states; forced audit failure (trigger on `audit_entries`, dedicated tenant) -> 500 and mode unchanged (same transaction). |
| T-F10 | same-mode PUT -> 200 `changed: false`, no audit, no precondition evaluated (a T9 gap does not refuse it). |
| T-F7 | every non-flag `Tenant` changeset drops `scope_enforcement`. |

### 12.4 AC8 shadow (`scope_shadow_test.exs`, `capture_log`)

| Id | Test |
|---|---|
| T-S1 | a fixed request matrix (one route per router, both credentials) gives identical status and body under `off` and `shadow`. |
| T-S2 | a principal holding a role whose binding has no row: under `shadow` one `[:letflow, :scope, :shadow, :would_deny]` event with `reason: :no_grant_rows` and `letflow_scope_shadow_would_deny_total{reason="no_grant_rows"}` +1; under `off` none. |
| T-S3 | captured log line contains none of: the bearer token, `lf_tok_` prefix, user id, tenant id, email, role name, group id, node id, request body field values; it matches the 4.3 shape. |
| T-S4 | `observe/3` with a raising dependency (grants struct corrupted) returns the conn and the request still succeeds; one `scope_shadow_failed` line. |
| T-S5 | the AC2 writer assertions (1a T-W1..T-W13 subset: upsert new/kind change, rebind, seeding, member add/remove, sync, bind_on_login) re-run with the tenant in `shadow` give the same row sets and T9 0. |

### 12.5 AC13 (`tenant_wide_admins_test.exs`, replaces T-34)

| Id | Test |
|---|---|
| T-X1 | a user whose only TA source is the TA group, with the group's tenant-wide row replaced by a scoped row: not in `count_tenant_wide_admins/1` nor `tenant_wide_admin_user_ids/1`. |
| T-X2 | same user also owning a live TA token: counted. |
| T-X3 | a user row tenant-wide for TA plus the scoped group row: counted. |
| T-X4 | only tenant-wide rows: counts equal T-35's oracle; a TA binding with zero rows still counted (stage-1 rule, 5.1). |
| T-X5 | `tenant_wide_role_names/2` drops a role held only through a scoped row and keeps it with a tenant-wide row. |

### 12.6 AC9-AC12 N1 (`tenant_admin_guard_test.exs` + router tests)

Each refusal test asserts: the change did not happen (admin set, binding, membership, token,
grant unchanged), the response/return code, and exactly one `tenant_admin.guard_refused` row whose
`after_state` keys are exactly the six of 6.1 with `counted_admins: 0`, which survives (written
after the rollback).

| Id | Test |
|---|---|
| T-G1 | POST /roles TENANT_ADMIN kind -> `process_routing_role` with the last admin in the group -> 409 `last_tenant_wide_admin`, event `action` `"unbind_tenant_admin"`; with a second admin (member or TA token owner) -> 200. Already-zero: the same conversion in a tenant whose only TA member is inactive -> 409. |
| T-G2 | DELETE /groups/:ta/members/:last -> 409; removing a non-last admin -> 204; removing from a non-TA group in a tenant with 0 admins -> 204 (no count). |
| T-G3 | POST /roles/:ta/rebind to an empty group -> 409; to a group with an active member -> 200. Rescue: forced raise (update trigger) -> 500 body, `{:error, {:transaction_failed, _}}` at the function, nothing written (GH #2575 ACs; replaces 1a T-W8 R2's `assert_raise`). |
| T-G4 | DELETE /groups/:ta (memberless bound -> 409 `bound_to_role`; with members -> 404/409 as today), zero `guard_refused` entries. |
| T-G5 | pending-grant revoke: last OPEN grant while count 0 -> 409 `last_tenant_wide_admin`, grant still open; r1 (SEC B1): exactly one tenant-chain `guard_refused` entry with `actor_id` nil, `"actor"` nil, `trace_id` nil, `"trace_id"` nil, and NO platform user id anywhere in the tenant chain's new entries; exactly one companion PLATFORM-chain `guard_refused` entry with the operator as actor and the request trace, `action` `"revoke_pending_grant"`; with another open grant -> 204; with a counted admin present -> 204. |
| T-G6 | revoke_token (AC10): owner admin only through the token -> 409, token live (`revoked_at` nil, still authenticates), event `action` `"revoke_token"`; owner also in the TA group -> 200 revoked; a non-TA token in a 0-admin tenant -> 200. r1 (CDV B2), in a 0-admin tenant: an EXPIRED TA token -> 200 revoked, no event; a TA token whose owner is INACTIVE -> 200 revoked, no event. r1 (SEC A3): a test transaction holding ONLY the TA `tenant_role` row `FOR UPDATE` (no advisory lock) blocks `revoke_token/2` of a NON-TA token until it commits (bounded `assert_receive`, <= 2 s): R is taken unconditionally. |
| T-G7 | AC12 lock: a test process holds `lock_tenant_admins!/1` in an open transaction; `update_user_status/3` (reactivation) and `PendingAdminGrants.revoke/3` started in another process do not complete until it is released (bounded wait, `assert_receive` timeouts <= 2 s, no busy loop). |
| T-G9 | r1 (GH #2575, one test per path): `rebind_role/4` with a forced raise inside its transaction returns `{:error, {:transaction_failed, _}}` with binding, rows and audit unchanged; `POST /roles/:id/rebind` under the same fault answers the `Response.internal_error/1` body with no crash report (`capture_log` has no `Plug.ErrorHandler` report). |
| T-G10 | every refusal's `after_state` keys are exactly the six of 6.1 and `"reason_code" == "last_tenant_wide_admin"`; the `action` string per path is the 6.1 value. |
| T-G8 | `refuse/3` inside an open transaction writes nothing; `ensure_admins_remain!/3` outside a transaction raises `ArgumentError`. |

### 12.7 AC14 listing, AC16 integrity, AC15 walk

| Id | Test |
|---|---|
| T-L1 | seeded (i) exceeding, (ii) non-expiring PA (platform tenant), (iii) NULL issuer, and a compliant token: each found in its list, the compliant one absent; revoked/expired variants absent; `flip_blocked` true only with (i). |
| T-L2 | item keys exactly the 10 #2552 keys; status from `token_effective_status/3` (an inactive owner's token shows `owner_inactive`); r1 (SEC A2): the response contains no plaintext, no full `token_hash` and no `lf_tok_` substring (`name` is part of the #2552 map and may appear). |
| T-L3 | one `token.listed` per call, `after_state` keys exactly `actor`, `count`, `token_ids`; no value, hash or prefix; audit failure -> 500 with no token data. |
| T-L4 | 403 without the permission; 403 for a scoped TA. |
| T-I1 | integrity: 0 on a clean (writer-built) tenant; the seeded gap listed with its role id, name and group id; tenant from auth only (a body/query `tenant_id` is ignored); 403 without the permission. |
| T-RW1..T-RW4 | section 9. |

### 12.8 AC17 (1b)

ELIXIR-DEV and TEST-RUNNER quote real output of `mix compile --warnings-as-errors`,
`mix format --check-formatted`, the scoped `mix test` (`test/letflow/identity*`,
`test/letflow/routers/identity*`, `test/letflow/routers/onboarding*`, `test/letflow/plugs`,
`test/letflow/api`, the new files of 12, `test/letflow/scope_enforcement_test.exs`,
`test/letflow/routers/tenant_scope_enforcement_test.exs`, and the 1a role_scope_grants tests), and
`mix letflow.check_boundaries`. Existing tests whose expectations change because N1 now refuses a
last-admin change (1b blast radius) are edited in the same PR and listed in the PR body.

---

## 13. AC to design map

| AC | Design | Tests |
|---|---|---|
| AC5 | 1.1-1.4 | T-A1..T-A12 |
| AC6 | 2 | T-P1..T-P4 |
| AC7 | 3.1-3.5 | T-F1..T-F10, T-F6b, T-F6c |
| AC8 | 4 | T-S1..T-S5 |
| AC9 | 6.1, 6.2 (a)(b)(b')(c)(d) | T-G1..T-G5, T-G9 |
| AC10 | 6.2 (f) | T-G6 |
| AC11 | 6.1 `refuse/4` | assertion in every T-G refusal, T-G10 |
| AC12 | 6.2 (d)(e) | T-G7 |
| AC13 | 5 | T-X1..T-X5 |
| AC14 | 7 | T-L1..T-L4 |
| AC15 | 9 | T-RW1..T-RW4 |
| AC16 | 8 | T-I1 |
| AC17 (1b) | 12.8 | gate output |

---

## 14. Security (INV per REQ-497 GATES)

- INV-1: every new query takes an explicit `prefix`; the flag is a column of the caller's own
  `tenants` row, read and written by `auth_context.tenant_id` only; new routes take no tenant from
  path, query or body.
- INV-2: `allowed?/3` sits after `evaluate_access/2`, which is untouched; new bodies are built field
  by field (counts, ids of identity metadata for admins only); the flip refusal names checks, not
  records.
- INV-4: shadow log uses keyed pseudonyms only; `token.listed` carries ids and a count; no token
  value, hash, prefix or name anywhere; guard events carry the six keys only.
- INV-5: no by-id lookup changes its existence behaviour.
- INV-6: one new read path (`applicable_rows_for_user/2`) inside the single grants module.
- INV-7: all values bound; the only interpolation remains the 1a constant conflict target and
  `ScopeNodePaths.lock!/1`'s validated prefix.
- INV-8: guard refusals are typed (409), rebind gains its rescue, shadow never raises, an audit
  failure of a listing fails closed (500, no data), a flip audit failure rolls the flip back.
- INV-10: platform-scope permissions never consult grants (T-A9); `platform_tenant?` recomputed.

---

## 15. Carried to #2535 (referenced, not designed here)

- 1a section 10 item 1b-2 (i)-(iii): routing -> platform re-creation, `nil -> P` in an enforced
  tenant, IdP sync into a tenant-wide group (`grant.sync_suppressed`); `binding.pending_scope`; the
  last-scoped-row refusal; the flag value `on` (CHECK widening) and per-route resource scopes (D5,
  D11 walk); "zero rows means not tenant-wide" for `exclude_scoped_holders/2` in enforced tenants;
  retired-node handling with the FK (1a S2-1); the T13 tension in OQ-3; the optional cross-tenant
  platform flip route (OQ-1, added to #2535 by letflow-2).
- r1 (SEC A5): once `on` exists, refuse the OFF flip (a total bypass, D12) when it comes from a
  TOKEN principal whose roles exceed its owner's current tenant-wide roles. In stage 1 the flip
  only toggles a non-enforcing mode, so 1b does not add this check.

## 16. If #2594's merged shape differs

| #2594 item | Used in | If different |
|---|---|---|
| `Identity.token_effective_status/3` | 7.1, 7.2 | Renamed/re-aritied: call the merged name; if absent, 1b stops (B6 is binding, ORCH re-routes). |
| `Identity.list_tokens/1` -> `{:ok, [%{token, owner_active}]}` | 7.1 | If it still returns `{:ok, [ApiToken.t()]}`: `findings/1` adds one query joining owners with `Identity.active_user_condition/1` (no other change). |
| `Identity.tenant_wide_role_names/2` | 7.1 | If absent: `TokenPreconditions` computes `Authorization.effective_roles(list_effective_role_names(...), platform?)` and applies 5.2's predicate itself; 5.2 then moves into `TokenPreconditions` as a private step. |
| private `exclude_scoped_role_names/3` | 5.2 | If absent: 5.2 is dropped from `identity.ex` (see previous row). |
| private `token_map/2` in `routers/identity.ex` | 7.2 | Moved to `Letflow.Api.TokenView` whatever its merged arity; the key set stays the AC14 list (T-L2 pins it). |
| `revoke_locked_token/3` with `token_audit_state/1` | 6.2 (f) | Insertion points are relative ("after the update, before the `token.revoke` audit"); unchanged. |
| `test/support/token_mint_fixture.ex` | 11 | If removed or renamed: apply section 11 to its successor, or drop the item. |

## 17. Open questions

- **OQ-1 (ORCH/supervisor):** a cross-tenant platform route to flip ANOTHER tenant's flag
  (`/tenants/:slug/scope-enforcement`, `:TenantsManage`). Not in 1b: D12's "platform scope" is
  served on the platform tenant itself (3.4). **RULED (r1):** goes to #2535 as optional; letflow-2
  added it there. Not in 1b.
- **OQ-2:** GH #2575 (rebind rescue). **RULED (r1, supervisor):** 1b closes #2575; the PR body
  carries "Closes #2575"; tests per path T-G3 and T-G9 (the `rebind_role/4` rescue and the router
  `transaction_failed` clause).
- **OQ-3:** 0051 T13 says an `:unresolvable` instance is visible to tenant-wide holders, while
  D4/AC5 deny `:unresolvable` for everyone. **RULED (r1):** recorded for #2535; 1b follows D4/AC5.
- **OQ-4:** `exclude_scoped_holders/2` keeps counting a TA binding with zero rows in stage 1 (5.1).
  **RULED (r1):** SECURITY-REVIEWER accepts it.

No open question remains for 1b.

## 18. Implementation notes (ELIXIR-DEV, 2026-10-14T22:02Z UTC, base `main` 9d95d4335)

**Section 16 check against merged #2594 (PR #2594 = 9d95d4335): no delta.**
`Identity.token_effective_status/3`, `Identity.list_tokens/1` returning
`{:ok, [%{token, owner_active}]}`, `Identity.tenant_wide_role_names/2` (`MapSet`), private
`exclude_scoped_role_names/3`, private `Routers.Identity.token_map/2` (arity 2, the ten keys),
`revoke_locked_token/3` with `token_audit_state/1`, and `test/support/token_mint_fixture.ex`
(`binding_group_id!/2`) all exist with the shapes section 0 B6 assumed. `token_map/2` moved
verbatim to `Letflow.Api.TokenView.token_map/2`; the router's `revoked_token_map/1` calls it.
Migration version `20261015025332` checked: unused in `lib test priv config`, not on
`origin/main`, not in any open PR (#2593 adds `20261014000003`).

**Supervisor ruling 2026-10-15 (ORCH relay), binding, supersedes 6.2's "already-zero rule"
for (a), (b), (c):**
1. Transition rule for `unbind_tenant_admin`, `remove_tenant_admin_member`,
   `rebind_tenant_admin`: refuse ONLY when the count was > 0 BEFORE the write AND is 0 after.
   The before-count is `TenantAdminGuard.count_before!/1`, taken under lock A after the
   path's row locks and before the write ((a) after the role row lock, before the kind update;
   (b) after the group KEY SHARE, before the delete, only for the TA binding's group; (c)
   after the role and target-group locks, before the update). The rule lives in ONE place:
   `TenantAdminGuard.ensure_admins_remain!/4` (`before_count` integer -> transition rule;
   `:not_measured` -> state rule). `revoke_token` keeps the state rule via
   `ensure_admins_remain!/3` (only a token counted at lock time is guarded). `revoke_pending_grant`
   unchanged (last OPEN grant while count == 0). T-G1's "already-zero ... -> 409" case is
   therefore obsolete: an already-zero tenant is NOT refused on (a)/(b)/(c).
2. Integrity finding `zero_tenant_wide_admins` (INFORMATIONAL, does not block off -> shadow;
   becomes a precondition of the stage-2 `on` flip, #2535; stated in the
   `Letflow.ScopeEnforcement` moduledoc). Body of `GET /tenant/scope-enforcement/integrity`
   gains `"findings": [code, ...]` (`[]` or `["zero_tenant_wide_admins"]`); the report is
   built by new `ScopeEnforcement.integrity/1`.
3. The event write stays behind `TenantAdminGuard.refuse/3,4` (single writer), so it can
   delegate to #2564's `Identity.record_guard_refused/2` on rebase.

**SECURITY-REVIEWER r2 availability advisory, adopted.** In `AuthPipeline`, the OIDC grants
load (`load_scope_grants/2`) rescues `Postgrex.Error` only: the memo becomes `:not_loaded`
and one constant line `scope_grants_load_failed credential=oidc` is logged (no id, no SQL).
Still fail closed: `principal_from_conn/1` does NOT retry a memo that is present as
`:not_loaded` (it lazily loads only when the key is ABSENT, i.e. a context not built by the
pipeline), so `allowed?/3` denies with `:grants_unavailable` and the shadow observer counts it.

**Other choices within the design.**
- `principal_from_conn/1` uses `scoped_opts[:prefix]` and additionally requires it to equal
  `schema_name_for_tenant(auth_context.tenant_id)` (mismatch -> `:no_principal`).
- PUT body is read directly, not via `Letflow.Api.Validation`, so a missing, non-string or
  `"on"` mode all answer the one code `invalid_enforcement_mode` (T-F1); `reason` is passed
  raw to `flip/4`.
- `flip/4` returns `{:error, :invalid_mode}` for a non-mode target; a changeset failure on the
  flag update raises inside the transaction and returns `{:transaction_failed, e}`.
- `attach_auth_context` now takes the `%Tenant{}` and the grants memo (arity 6) and reads
  `scope_enforcement` from it.
- `refuse/4` rescues and logs a constant line (`tenant_admin_guard_refusal_not_recorded ...`)
  so a refusal is always returned.
- `exclude_scoped_holders/2` names the membership subquery bindings `:admin_member` /
  `:admin_binding` (one-level `parent_as`).
- Not verified here: `mix test` (free memory 1.5 GB, below the 4 GB floor). TEST-RUNNER runs it.
- Post-review advisories (2026-10-14T22:06Z, after SEC/REVIEWER PASS): SEC adv 1,
  `load_scope_grants/2` also rescues `DBConnection.ConnectionError` (same `:not_loaded`, same
  line); REVIEWER adv 1, `GET /token-preconditions` turns a raise from `findings/1` or the
  `token.listed` insert into the detail-free 500 with one constant line and no token data;
  REVIEWER adv 5, the metrics registry/exposition comments say seven families.
