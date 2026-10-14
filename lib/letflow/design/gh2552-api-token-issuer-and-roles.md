# GH #2552: API token issuer, role subset, audit metadata, effective status (0051 M2)

Builds on #2547 (2a29b162) and #2557 (3e9b6faf); 0051 M2 (`0051-...md:52-57`), D1 (`:199-217`), D8
(`:324-337`), D11 (`:409-425`), no new record. Refs at 2a29b162; `identity.ex` = `lib/letflow/identity.ex`, router = `routers/identity.ex`.

## 1. Verified starting point

- `api_tokens` has no issuer (`identity/api_token.ex:26-36`; migration `20260823000001_...:27-41`,
  `user_id` NOT NULL FK at `:29`). `POST /tokens` takes `user_id` and `roles` from the body
  (router `:772-776`, `:795-807`) and is gated only by `:TokensManage` (router `:226-228`;
  `authorization.ex:772-774`, `:1250`).
- `:TokensManage` is tenant scope (`authorization.ex:466-474`), so it is held by `TENANT_ADMIN`
  (`:1424-1425`) and by `PLATFORM_ADMIN` only inside the platform tenant (`:1417`, drop at `:1179-1182`).
- `create_token/3` (`identity.ex:1856-1877`): pure checks, then `insert_token/4` (`:1907-1959`) whose Multi
  takes `lock_tenant_admins!/1` first (`:1930-1932`), inserts, appends `token.create` with
  `after_state: Audit.struct_state(token, [:token_hash])` and actor/trace from `opts[:audit_context]`
  (`:1934-1949`). `revoke_token/2` (`:2043-2066`) -> `revoke_locked_token/3` (`:2075-2111`): lock first
  (`:2076`), re-read `FOR UPDATE` (`:2078`), `token.revoke` with before/after minus `token_hash`.
- Audit entries have no metadata column; the payload is `before_state`/`after_state`
  (`audit/entry.ex:28-38`). `token.name` is `"token-" <> first 8 hex of token_hash` (`identity.ex:1911`),
  i.e. a hash prefix, and is in today's audit states.
- Role resolution: `list_effective_role_names/2` (`identity.ex:960-974`) = distinct `tenant_role.name` of
  the user's groups, `kind == :platform_role` only (`:968`); group bindings only, never token roles.
- Every path that changes group membership or bindings takes `lock_tenant_admins!/1` first:
  `identity.ex:685` (add), `:906` (remove), `:766` (delete group), `role_registry.ex:296,469,675`,
  `pending_admin_grants.ex:539`, `tenant_admin_migration.ex:311`, IdP sync (`identity.ex:1133-1139`).
  User status writes do NOT: `update_locked_user/5` (`identity.ex:417-457`) locks only the user row
  `FOR UPDATE` (`:423`) and audits with `actor_id: nil, trace_id: nil` (`:439`, `:445`).
- `Validation.validate/2` keeps only declared fields (`api/validation.ex:235`); unknown body keys are dropped.
- Tenant migrations: `if prefix()` guard plus manifest entry (`tenant_provisioning.ex:491-652`); existing
  tenants get them by the boot replay (`tenant_provisioning/migration_replay_boot.ex`).

## 2. Schema and migration

Migration `priv/repo/migrations/2026101500000N_add_issuer_user_id_to_api_tokens.exs`, module
`Letflow.Repo.Migrations.AddIssuerUserIdToApiTokens`, `change/0`, all inside `if prefix() do`:
- `alter table(:api_tokens, prefix: prefix())`: `add :issuer_user_id, references(:users, type: :binary_id)`,
  nullable, default `on_delete` (no action, same as `user_id`). No default, no UPDATE: existing rows stay
  NULL. NULL is the legacy marker ("issuer not recorded"); no extra flag column (it would duplicate NULL).
- `create index(:api_tokens, [:issuer_user_id], prefix: prefix())` (FK check on user delete, issuer queries).
- Manifest: append `{version, Letflow.Repo.Migrations.AddIssuerUserIdToApiTokens, "<file>"}` after
  `CreateScriptRules` (`tenant_provisioning.ex:650-651`). Version: pick one free on `origin/main` and open
  PRs at implementation time (anti-pattern "Two independently-merged Ecto migrations picking the same
  version-number prefix").

`ApiToken` (`api_token.ex`): add `field(:issuer_user_id, :binary_id)`. `insert_changeset/2`
(`:46-52`) adds `:issuer_user_id` to the cast list (not required) and `foreign_key_constraint(:issuer_user_id)`.
Its value only ever comes from the server-built attrs map in `insert_token` (`identity.ex:1914-1920`),
never from a request body. `revoke_changeset/2`, `roles_rewrite_changeset/2` and
`touch_last_used_changeset/2` do not cast it. Moduledoc states the NULL = legacy meaning.

## 3. Domain API (`Letflow.Identity`)

```
@type mint_error ::
        :issuer_not_authorized | :user_not_found | :user_inactive | :invalid_role_set
        | :roles_not_held | :expires_at_in_past | Ecto.Changeset.t() | {:transaction_failed, Exception.t()}
@spec mint_token(issuer_user_id :: Ecto.UUID.t(), user_id :: Ecto.UUID.t(),
                 attrs :: create_token_attrs(), opts :: opts()) ::
        {:ok, %{token: ApiToken.t(), plaintext: String.t()}} | {:error, mint_error()}
@spec tenant_wide_role_names(user_id :: Ecto.UUID.t(), opts :: opts()) :: MapSet.t(String.t())
@spec token_effective_status(token :: ApiToken.t(), owner_active :: boolean(), now :: DateTime.t()) ::
        :revoked | :expired | :owner_inactive | :active
@spec list_tokens(opts :: opts()) :: {:ok, [%{token: ApiToken.t(), owner_active: boolean()}]}
```

**`mint_token/4`** is the HTTP mint path (0051 M2). Step order:
1. Outside the transaction, unchanged pure checks: `validate_issuable_roles/1` (empty or unknown ->
   `:invalid_role_set`, `identity.ex:1879-1887`), `reject_platform_admin_outside_platform_tenant/2`
   (`:1891-1895`), `validate_expires_at/1` (`:1897-1905`). An empty list is thus refused before the subset
   rule (the subset rule alone would accept `[]`).
2. One Multi, via the shared insert (see below):
   a. `:tenant_admin_lock`: `lock_tenant_admins!(prefix)`, the FIRST locking step (unchanged).
   b. `:mint_checks` (`Multi.run`): read the users `id IN [issuer, target]` `ORDER BY id FOR SHARE`.
      - issuer row missing, `active_user?/1` false (`identity.ex:2198`), or not holding a mint role ->
        `:issuer_not_authorized`. Mint role: `"TENANT_ADMIN" in tenant_wide_role_names(issuer)`, or the
        prefix is the platform tenant (`PlatformTenant.platform_prefix?/1`) and `"PLATFORM_ADMIN"` is held.
      - target row missing -> `:user_not_found`; target not `active_user?/1` -> `:user_inactive`.
      - `MapSet.subset?(roles, MapSet.intersection(held(issuer), held(target)))` false -> `:roles_not_held`.
   c. insert with `issuer_user_id: issuer_user_id`; d. `token.create` audit (section 5).
   Issuer is checked before the target, so an unauthorized caller learns nothing about the target.

**Shared insert.** `insert_token/4` becomes `insert_token(user_id, attrs, prefix, ctx, issuer_user_id)`
(`issuer_user_id :: Ecto.UUID.t() | nil`). When non-nil, step 2b runs between the lock and the insert;
the result `case` (`identity.ex:1951-1955`) maps `{:error, :mint_checks, reason, _}` to `{:error, reason}`.
The `rescue` (`:1956-1957`) is kept.

**`create_token/3` stays** (signature, checks and lock as merged) as the trusted non-HTTP path: it passes
`nil`, so the row has NULL issuer and no M2 checks run. Its @doc says so and names its callers (section 8).
The router no longer calls it.

**`tenant_wide_role_names/2`**: `list_effective_role_names(user_id, opts)` as a `MapSet`, minus
`"PLATFORM_ADMIN"` unless `platform_prefix?(prefix)` (same rule as `Authorization.effective_roles/2`,
`authorization.ex:612-619`), then a private no-op hook `exclude_scoped_role_names/3` that #2533 fills (the
twin of `exclude_scoped_holders/2`, `identity.ex:1060-1061`). Token roles never count as held: otherwise a
token could justify the next token, and the 0051 flip precondition ("no token beyond its owner's roles",
`0051:213-215`) would be vacuous. Consequence: a token-only admin (counted by
`tenant_wide_admins_query/2`, `identity.ex:1040-1051`) cannot mint. A credential is never a source of minting
authority. That set stays the zero-admin count source; it is not the mint predicate.

**Race (check vs insert).** All membership and binding writers serialize on the advisory lock (section 1),
so the held-role sets read in 2b cannot change before commit. Status writes do not take it, hence the
`FOR SHARE` user rows: a concurrent `update_locked_user` `FOR UPDATE` (`:423`) either committed first (2b
sees inactive and refuses) or waits until the mint commits. Lock order: advisory, users (by id), token
insert, audit chain. This matches #2564's order (section 9).

**`list_tokens/1`**: one query, `ApiToken as :token` inner-joined to `User as :owner` on `user_id` (NOT
NULL FK, so no row is lost), selecting `%{token: t, owner_active: active_user_condition(:owner)}` in the
`select(^map)` form of `verify_api_token/2` (`identity.ex:2160-2165`), `order_by desc inserted_at`,
`prefix:`. Return shape changes. Callers to update: router `:842`, `identity_test.exs:926,1007,1032`,
`platform_admin_outside_platform_test.exs:126`.

**`token_effective_status/3`** (pure; moved from the router's `token_status/1`, `:1105-1114`). Precedence:
`revoked` > `expired` (`expires_at` not after `now`) > `owner_inactive` > `active`. Permanent states come
first, because neither can be undone. `owner_inactive` is the one reversible state, so it is shown only when
the token would otherwise work. This answers "why does this live token not authenticate?" (#2557 refuses
it, `identity.ex:2174-2175`).

## 4. HTTP (`Letflow.Routers.Identity`)

`POST /tokens` (route and `:TokensManage` gate unchanged):
1. If `conn.body_params` has the key `"issuer_user_id"` (any value, even the caller's id) -> 422
   `issuer_user_id_not_allowed`, before schema validation and any DB access. **Reject rather than ignore**:
   `Validation` would drop it silently (`validation.ex:235`). A client that thinks it set attribution
   ("mint on behalf of") must learn that it did not. The web client never sends it
   (`web/src/api/identity.ts:96`), so no current caller breaks.
2. Schema validation and the PLATFORM_ADMIN platform-scope 403 are unchanged (`:779-791`).
3. `Identity.mint_token(conn.assigns.auth_context.user_id, user_id, attrs, audit_opts(conn, opts))`. The
   issuer is the authenticated caller, the same value as the audit actor (`audit_opts/2`, `:1024-1030`).
4. Mapping: `:issuer_not_authorized` -> `forbid_insufficient/1` (403, fixed body, `:591`); `:user_not_found`
   -> 404; `:user_inactive` -> 422 `user_inactive`; `:roles_not_held` and `:invalid_role_set` -> 422
   `roles_invalid`; the other errors are unchanged (`:811-824`).
- **The 422 code is `roles_invalid`, not a new one**: 0051 M2 fixes "same code as `roles_invalid`"
  (`0051:53`, `:209`), and a new name would re-decide it. It is stable, and the body is the fixed `detail`
  only. It does not say which roles failed, or whether the minter or the target lacks them (INV-2: no
  membership oracle in the response; the domain atom tells tests apart).
- `token_created_map/2` adds `"issuer_user_id"`.

`GET /tokens`: same endpoint and permission (`:TokensManage`). Today only a tenant-wide holder can have it,
since scoped grants do not exist yet (`identity.ex:1061`); #2533's D11 route walk adds `:tenant_wide`
resolution for every `:TokensManage` route (`0051:416`). `token_map/2(token, status)` adds
`"issuer_user_id"` (always present, `null` for legacy), and `"status"` is the string from
`token_effective_status/3`. No `token_hash`, no plaintext (unchanged). `DELETE /tokens/:id` renders with
status from `owner_active: true`: the returned token always has `revoked_at` set (`identity.ex:2054-2055`,
`:2084-2085`, `:2090-2094`), so `revoked` wins.

## 5. Audit (names unchanged: `token.create`, `token.revoke`, 0051 D8 `:330-334`)

- Both actions exclude `[:token_hash, :name]` from `struct_state` (`name` is a hash prefix, `identity.ex:1911`).
- `token.create` `after_state` = token fields `id, user_id` (target), `issuer_user_id`, `roles`,
  `expires_at`, `revoked_at`, `last_used_at`, `inserted_at`, plus `scope: "tenant_wide"` (0051 D1(c)
  "tenant-wide statement", `:211`). Actor and `trace_id` are the entry columns from `opts[:audit_context]`,
  unchanged. `create_token/3` rows show `issuer_user_id: nil`.
- `token.revoke` before/after carry `issuer_user_id`, `user_id`, `roles`, `expires_at` automatically.
  The actor is the revoker.
- #2547 test T-30 (key sets equal pre-change) is updated to the new key sets in the same PR.
- `token.listed` (0051 M2, N2 `:566`) is NOT added: the issue's ACs do not ask for it; it belongs to the
  flip-precondition listing (#2533).

## 6. Decisions on the open choices

| Question | Decision |
|---|---|
| Body `issuer_user_id` | 422 `issuer_user_id_not_allowed` (section 4.1) |
| Who mints | active user holding TENANT_ADMIN via group binding (tenant-wide); PLATFORM_ADMIN only in the platform tenant; never by token roles alone |
| Subset failure | 422 `roles_invalid` (0051 M2), fixed body |
| Empty roles | 422 `roles_invalid` via `validate_issuable_roles/1`, before the subset check |
| Inactive target | refused, 422 `user_inactive`: the token would be dead now (#2557) and would wake on reactivation, which #2564 is removing |
| Inactive minter / self-mint | 403 (in-flight race only) / allowed, bounded to own roles by the subset rule |
| List | existing `GET /tokens`, `:TokensManage`; `owner_inactive` REQUIRED |

## 7. Existing tokens keep working

No change to `verify_api_token/2`, no UPDATE of existing rows; legacy rows list `"issuer_user_id": null`;
tokens beyond their owner's roles are untouched (the 0051 flip precondition handles them).

## 8. Callers of `create_token/3` (all keep NULL issuer, no code change)

`lib/mix/tasks/letflow.seed.exam_fixtures.ex:181` (dev CANDIDATE seed); `test/support/platform_tenant_fixture.ex:169`;
direct test calls (28 files under `test/letflow/`, e.g. `identity_test.exs`, simulation, entities, modules). `TenantAdminMigration`
does not mint (it rewrites roles via `roles_rewrite_changeset/2`, `tenant_admin_migration.ex:311`), so issuer is untouched.
HTTP tests that `POST /tokens` must now give the caller and target the roles via group membership:
`test/letflow/api/{authorization,identity_id_hardening,platform_admin_outside_platform,platform_escalation_guard}_test.exs`,
`test/letflow/routers/{identity,identity_gh2547_audit,tenant_admin_routes,tenant_auditor_routes,onboarding_scope_extension}_test.exs`,
`test/letflow/api_token_auth_pipeline_test.exs`, `test/letflow/plugs/iss0736_oidc_live_revocation_test.exs`.

## 9. Follow-on: #2564 (PLAN FOR THE NEXT PR, not part of #2552's implementation)

Option 3 (supervisor plan): deactivation revokes all of the user's tokens in the same transaction, and
reactivation restores none.
- **Where:** `update_locked_user/5` (`identity.ex:417-457`), which serves both deactivation paths:
  `update_user_status/3` (`:403-409`) and `update_user_profile/3` with `status` (`:375-381`). Trigger: locked
  `status == :active` and updated `status != :active`.
- **Order:** `lock_tenant_admins!(prefix)` as the new first step (before the user `FOR UPDATE`, `:423`),
  then the user row, then the user's tokens with `revoked_at IS NULL` `ORDER BY id FOR UPDATE`. Each is
  revoked by a changeset update (not `update_all`) through a private `revoke_token_row/4`, extracted from
  `revoke_locked_token/3` (`:2087-2109`) and shared with it. Same order as `revoke_token/2` and `mint_token/4`.
- **Audit:** one `token.revoke` per token: before/after minus `[:token_hash, :name]`, after_state adds
  `cause: "owner_deactivated"`. The `user.update_status`/`user.update_profile` after_state adds
  `revoked_token_count`. Actor and trace come from `opts[:audit_context]`, which these two functions start
  accepting (today `nil`, `:439`, `:445`).
- **Zero-admin guard (0051 N1, `:558-565`):** count after the writes, roll back on 0. #2547 assigns it to
  #2533 (`gh2547-...md:53`); #2564 already holds the lock, so including the count there is one call
  (open question 2). The count already excludes inactive users (`identity.ex:982-986`), so revoking that
  user's TENANT_ADMIN tokens does not change the guard's result.
- **Consistency with #2552:** after #2564, an inactive owner's tokens are normally `revoked` (which wins
  the precedence). `owner_inactive` then remains for rows from before #2564 deploys, for legacy data, and
  for in-flight cases. Reactivation leaves them `revoked`; new tokens are minted under section 3.

## 10. AC -> design -> named tests

| AC | Design | Tests (new unless stated) |
|---|---|---|
| issuer column, server-set, legacy NULL | §2, §4.1, §4.3 | `gh2552_token_issuer_test.exs`: "mint records caller as issuer"; "body issuer_user_id -> 422 issuer_user_id_not_allowed, no row, no audit"; "pre-existing row has NULL issuer after migration and still verifies" |
| roles subset of minter AND target, 422 | §3 2b, §4 | "role not held by target -> 422 roles_invalid"; "role not held by minter -> 422 roles_invalid"; "role held only via target's token -> 422"; "empty roles -> 422 roles_invalid"; "PLATFORM_ADMIN held in platform tenant -> 201"; "concurrent remove_group_member vs mint: either 422 or token minted before removal" |
| audit token.create/revoke metadata | §5 | "token.create after_state has issuer_user_id,user_id,roles,expires_at,scope; trace/actor columns set; no token_hash, name or lf_tok_ substring"; same for token.revoke; T-30 updated |
| effective status incl. owner_inactive | §3, §4 | "list: deactivated owner -> owner_inactive"; "revoked -> revoked"; "expired -> expired"; "revoked+inactive -> revoked"; "expired+inactive -> expired"; unit test of `token_effective_status/3` precedence table |
| list exposes issuer, never value | §4 GET | "list item has issuer_user_id (null for legacy), no token/token_hash keys"; "non-TokensManage caller -> 403" (existing) |
| only tenant-wide TENANT_ADMIN mints | §3 2b, §4.4 | "TokensManage via TENANT_ADMIN token, user not in TA group -> 403"; "inactive minter (race) -> 403"; "PLATFORM_ADMIN outside platform tenant -> 403" (existing) |
| existing tokens keep working | §7 | "legacy NULL-issuer token authenticates and lists with issuer null" |
| inactive target | §3 2b | "inactive target -> 422 user_inactive, no row" |

## 11. Security, blast radius, anti-patterns

- **INV-4:** the plaintext stays in the return tuple only. `token_hash` and `name` are excluded from audit.
  Error bodies are fixed strings. `issuer_user_id` is not secret. **INV-6:** new paths are the mint
  user/role reads and the list join. All use `prefix:` from `scoped_opts`, with joins in the same tenant
  schema. The migration is tenant-scoped (guard plus manifest). **INV-2:** the 422 does not say which
  principal lacks a role.
- **Blast radius:** `identity.ex` (mint, list, audit excludes), `api_token.ex`, router token handlers, one
  tenant migration and manifest, 11 HTTP test files (section 8), and 3 `list_tokens` call sites. The
  web `ApiToken.status` type (`web/src/types/api.ts:578`, uppercase) is already stale; display-only, so no
  FRONTEND-DEV change is needed.
- **Anti-patterns (`docs/anti-patterns.md`):** "Two independently-merged Ecto migrations picking the same
  version-number prefix"; "A migration version can collide with a test fixture's hardcoded version
  constant..."; "Stale `tenant_template` schema surviving a migration-adding commit" and
  "`test/support/tenant_template.ex`'s template-existence check has no staleness detection..." (drop the
  local template before testing); "A bulk `update_all` used for a state transition silently skips both the
  audit call..." (#2564: per-row revoke); "Audit-shaped requirements: closed-set and outcome-independence
  must be checked at draft time" (audit on success only, same transaction).

## 12. Open questions

1. A token-only tenant admin can no longer mint (§3). Is that accepted, or must #2547's admin set be the
   mint predicate? (The design says no: a credential must not mint credentials.)
2. #2564: does the zero-admin guard on deactivation go in #2564 (lock already held) or wait for #2533?
3. 0051 M2's "admin-flagged service principal" exception does not exist yet; this design has no bypass.
   Confirm it is out of scope.
4. `token.listed` (N2) is deferred to #2533. Confirm.
