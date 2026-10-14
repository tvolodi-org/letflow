# GH #2552: API token issuer, role subset, audit metadata, effective status (0051 M2)

Builds on #2547 (2a29b162) and #2557 (3e9b6faf); 0051 M2 (`0051-...md:52-57`), D1 (`:199-217`), D8
(`:324-337`), D11 (`:409-425`), no new record. Refs at 2a29b162; `identity.ex` = `lib/letflow/identity.ex`, router = `routers/identity.ex`.

## 1. Verified starting point

- `api_tokens` has no issuer (`identity/api_token.ex:26-36`; migration `20260823000001_...:27-41`, `user_id` NOT
  NULL FK `:29`). `POST /tokens` takes `user_id`/`roles` from the body (router `:772-776`, `:795-807`), gated only
  by `:TokensManage` (router `:226-228`; `authorization.ex:772-774`, `:1250`): tenant scope (`:466-474`), held by
  `TENANT_ADMIN` (`:1424-1425`) and by `PLATFORM_ADMIN` only in the platform tenant (`:1417`, drop `:1179-1182`).
- `create_token/3` (`identity.ex:1856-1877`): pure checks, then `insert_token/4` (`:1907-1959`): lock first
  (`:1930-1932`), insert, `token.create` with `struct_state(token, [:token_hash])`, actor/trace from
  `opts[:audit_context]` (`:1934-1949`). `revoke_token/2` (`:2043-2066`) -> `revoke_locked_token/3`
  (`:2075-2111`): lock first (`:2076`), re-read `FOR UPDATE` (`:2078`), `token.revoke` minus `token_hash`.
- Audit has no metadata column; payload is `before_state`/`after_state` (`audit/entry.ex:28-38`). `token.name` is
  `"token-" <> first 8 hex of token_hash` (`identity.ex:1911`), a hash prefix, today in audit states.
- `list_effective_role_names/2` (`identity.ex:960-974`): the user's group-bound role names, `kind == :platform_role`
  (`:968`); never token roles. `verify_api_token/2` authenticates as the token OWNER (`user_id: token.user_id`, `:2237`).
- Every membership/binding writer takes `lock_tenant_admins!/1` first: `identity.ex:685`, `:906`, `:766`,
  `role_registry.ex:296,469,675`, `pending_admin_grants.ex:539`, `tenant_admin_migration.ex:311`, IdP sync
  (`identity.ex:1133-1139`). `update_locked_user/5` (`identity.ex:417-457`, every user profile/status edit) does
  NOT: it locks only the user row `FOR UPDATE` (`:423`), audits with `actor_id: nil, trace_id: nil` (`:439`, `:445`).
- `Validation.validate/2` keeps only declared fields (`api/validation.ex:235`). Tenant migrations: `if prefix()`
  guard plus manifest (`tenant_provisioning.ex:491-652`); existing tenants via `migration_replay_boot.ex`.

## 2. Schema and migration

`priv/repo/migrations/2026101500000N_add_issuer_user_id_to_api_tokens.exs`, `Letflow.Repo.Migrations.AddIssuerUserIdToApiTokens`,
`change/0` inside `if prefix() do`: `alter table(:api_tokens, prefix: prefix())` `add :issuer_user_id,
references(:users, type: :binary_id)`, nullable, NO default, default `on_delete` (as `user_id`); no UPDATE, so
existing rows stay NULL = legacy ("issuer not recorded"; no flag column, it would duplicate NULL);
`create index(:api_tokens, [:issuer_user_id], prefix: prefix())`. Manifest entry after `CreateScriptRules`
(`tenant_provisioning.ex:650-651`); version chosen free on `origin/main` and open PRs at implementation time.

`ApiToken`: `field(:issuer_user_id, :binary_id)`; `insert_changeset/2` (`:46-52`) casts it (not required) plus
`foreign_key_constraint(:issuer_user_id)`. Its value comes only from the server-built attrs in `insert_token`
(`identity.ex:1914-1920`). The other changesets do not cast it. Moduledoc: NULL = legacy; issuer is
attribution only, the OWNER (`user_id`) is the acting identity (section 3, SoD).

## 3. Domain API (`Letflow.Identity`)

```
@type mint_error ::
        :issuer_not_authorized | :user_not_found | :user_inactive | :invalid_role_set | :expires_at_in_past
        | :platform_admin_token_not_self | :platform_admin_token_expiry | :roles_not_held
        | Ecto.Changeset.t() | {:transaction_failed, Exception.t()}
@spec mint_token(issuer_user_id :: Ecto.UUID.t(), user_id :: Ecto.UUID.t(),
                 attrs :: create_token_attrs(), opts :: opts()) ::
        {:ok, %{token: ApiToken.t(), plaintext: String.t()}} | {:error, mint_error()}
@spec tenant_wide_role_names(user_id :: Ecto.UUID.t(), opts :: opts()) :: MapSet.t(String.t())
@spec validate_platform_admin_expiry(roles :: [String.t()], expires_at :: DateTime.t() | nil,
                                     now :: DateTime.t(), max_ttl_days :: pos_integer()) ::
        :ok | {:error, :platform_admin_token_expiry}
@spec token_effective_status(token :: ApiToken.t(), owner_active :: boolean(), now :: DateTime.t()) ::
        :revoked | :expired | :owner_inactive | :active
@spec list_tokens(opts :: opts()) :: {:ok, [%{token: ApiToken.t(), owner_active: boolean()}]}
```

**`mint_token/4`**, the HTTP mint path (0051 M2). One Multi via the shared insert; every check below is in
`:mint_checks` (`Multi.run`), in this order, so authorization comes first (403 before any 422):
1. `:tenant_admin_lock`: `lock_tenant_admins!(prefix)`, the FIRST locking step (unchanged).
2. Users `id IN [issuer, target]` `ORDER BY id FOR SHARE` (the only row locks; role/group reads below are
   plain reads, made stable by the advisory lock, section 1).
3. Issuer: row missing, not `active_user?/1` (`identity.ex:2198`), or `mint_authority?(held(issuer), prefix)`
   false -> `:issuer_not_authorized`.
4. Input checks, unchanged code: `validate_issuable_roles/1` (`[]` or unknown -> `:invalid_role_set`,
   `identity.ex:1879-1887`; so `[]` never reaches the subset rule), `reject_platform_admin_outside_platform_tenant/2`
   (`:1891-1895`), `validate_expires_at/1` (`:1897-1905`).
5. Target: missing -> `:user_not_found`; not active -> `:user_inactive`.
6. PLATFORM_ADMIN token rules (any token whose roles contain `"PLATFORM_ADMIN"`; such a token can exist only in the
   platform tenant, step 4): target != issuer -> `:platform_admin_token_not_self`;
   `validate_platform_admin_expiry(roles, expires_at, now, max_ttl_days)` -> `:platform_admin_token_expiry` when
   `expires_at` is nil or `> now + max_ttl_days` (whole seconds; equal to the cap is allowed). `max_ttl_days` =
   `Application.get_env(:letflow, :platform_admin_token_max_ttl_days, 90)`, read at call time; `config/config.exs`
   sets `90` explicitly.
7. `MapSet.subset?(roles, MapSet.intersection(held(issuer), held(target)))` false -> `:roles_not_held`.
Then the insert with `issuer_user_id`, then `token.create` (section 5).

Ordering and leaks: steps 3-7 run after authorization, so a caller without mint authority always gets 403 and
learns nothing about input validity or the target. The only earlier refusals are router-level ones that depend on
the request alone or the caller's own scope (section 4, 1-2); they reveal no tenant data.

**`mint_authority?/2`** (private) = `tenant_admin_mint_authority?(held)` `or`
`platform_admin_mint_exception?(held, prefix)`:
- `tenant_admin_mint_authority?/1`: `"TENANT_ADMIN" in held`. This is the 0051 M2/D1(a) rule.
- `platform_admin_mint_exception?/2`: **DEVIATION from 0051 M2/D1(a), confirmed by advisor 2026-10-15 with
  conditions (1)-(3).** True iff `PlatformTenant.platform_prefix?(prefix)` and `"PLATFORM_ADMIN" in held`. One
  function and one `or` term; removing both removes the exception, with no other change (supervisor: if the
  ruling is ever withdrawn, the clause is dropped with no redesign). Rationale: REQ-447 issues PLATFORM_ADMIN tokens
  only from the platform tenant (`identity.ex:1889-1895`); PLATFORM_ADMIN holds every permission
  (`authorization.ex:1417`); without the clause only a user in both the PA and TA groups could mint there.
  Bounds: platform tenant only, never a customer tenant (checked here, and `held` drops PA outside it); the subset
  rule (7) still applies; issuer and audit are recorded as for every mint; no cross-tenant mint (the prefix is the
  caller's own `scoped_opts`, and the target must exist in it). Advisor conditions: (1) the subset of minter AND
  target applies, and a PA-carrying token requires target == minter (step 6); (2) a PA-carrying token must expire
  within `:platform_admin_token_max_ttl_days` (step 6), so there are no non-expiring operator bearer tokens via
  HTTP; (3) SoD identity (below).

**SoD identity (advisor condition 3).** A token acts as its OWNER, `api_tokens.user_id` (`identity.ex:2237`).
Script contributor/publisher separation of duties (0053 D6, letflow-4's 7b) MUST compare owners, never
`issuer_user_id`. The issuer is recorded separately (column and audit) for attribution only.

**Shared insert.** `insert_token(user_id, attrs, prefix, ctx, issuer_user_id :: Ecto.UUID.t() | nil)`; when
non-nil, `:mint_checks` runs between the lock and the insert; the result `case` (`identity.ex:1951-1955`) maps
`{:error, :mint_checks, reason, _}` to `{:error, reason}`; the `rescue` (`:1956-1957`) stays. **`create_token/3`
stays as merged** (pure checks outside, lock first) as the trusted non-HTTP path: passes `nil`, so NULL issuer and
no M2/PA-expiry checks. The router no longer calls it.

**`tenant_wide_role_names/2`**: `Authorization.effective_roles(list_effective_role_names(user_id, opts),
PlatformTenant.platform_prefix?(prefix))` (`authorization.ex:612-619`, the one shared PA-drop rule), mapped
back with `Atom.to_string/1` into a `MapSet`, then private no-op `exclude_scoped_role_names/3`. Its comment and
`exclude_scoped_holders/2`'s (`identity.ex:1056-1061`) cross-reference each other: #2533 fills BOTH. Token
roles never count as held (supervisor OQ1 ruling): a token must not justify the next token, and the 0051 flip
precondition (`0051:213-215`) would be vacuous. So a token-only admin (counted by `tenant_wide_admins_query/2`,
`identity.ex:1040-1051`, which stays the zero-admin count source) cannot mint. The PR body and the runbook state this.

**Race (check vs insert).** Held roles cannot change before commit: every membership/binding writer takes the
advisory lock. Status writes do not, hence the `FOR SHARE` user rows. A concurrent `update_locked_user` `FOR
UPDATE` (`:423`) either committed first (refused at 3/5) or waits for the mint's commit. Lock order: advisory,
users by id, token insert, audit chain. This is the same order as #2564 (section 9).

**`list_tokens/1`**: `ApiToken as :token` inner-joined to `User as :owner` on `user_id` (NOT NULL FK, so no row is
lost), `select(^%{token: t, owner_active: active_user_condition(:owner)})` as in `verify_api_token/2`
(`identity.ex:2160-2165`), `desc inserted_at`, `prefix:`. Callers to update: router `:842`,
`identity_test.exs:926,1007,1032`, `platform_admin_outside_platform_test.exs:126`.

**`token_effective_status/3`** (pure; replaces router `token_status/1`, `:1105-1114`): `revoked` > `expired`
(`expires_at` not after `now`) > `owner_inactive` > `active`. Permanent states win. `owner_inactive` is the only
reversible state, so it shows only when the token would otherwise work. That is the case #2557 refuses
(`identity.ex:2174-2175`).

## 4. HTTP (`Letflow.Routers.Identity`)

`POST /tokens` (route and `:TokensManage` gate unchanged):
1. Body has key `"issuer_user_id"` (any value) -> 422 `issuer_user_id_not_allowed`, before schema validation and any
   DB access. Reject, not ignore: `Validation` would drop it silently (`validation.ex:235`), and a client that
   believes it set attribution must learn it did not. The web client never sends it (`web/src/api/identity.ts:96`).
2. Schema validation, `expires_at` parsing and the PA platform-scope 403 are unchanged (`:779-799`).
3. `Identity.mint_token(conn.assigns.auth_context.user_id, user_id, attrs, audit_opts(conn, opts))`. The issuer
   is the authenticated caller, the same value as the audit actor (`:1024-1030`).
4. `:issuer_not_authorized` -> `forbid_insufficient/1` (403, fixed body, `:591`); `:user_not_found` -> 404;
   `:user_inactive` -> 422 `user_inactive`; `:roles_not_held`, `:platform_admin_token_not_self` and
   `:invalid_role_set` -> 422 `roles_invalid`; `:platform_admin_token_expiry` -> 422
   `platform_admin_token_expiry_invalid`; the rest unchanged (`:811-824`). `roles_invalid` is 0051 M2's
   code (`0051:53`, `:209`), not re-decided. It has a fixed body that names no role and no principal (INV-2);
   the domain atoms let tests tell the cases apart.
5. `token_created_map/2` adds `"issuer_user_id"`.

`GET /tokens`: existing endpoint, `:TokensManage` (today only tenant-wide holders exist, `identity.ex:1061`;
#2533's D11 walk adds `:tenant_wide` resolution, `0051:416`). `token_map/2(token, status)` adds `"issuer_user_id"`
(always present, `null` for legacy); `"status"` comes from `token_effective_status/3`. `DELETE /tokens/:id` passes
`owner_active: true`; the returned token always has `revoked_at` (`identity.ex:2054-2055`, `:2084-2094`), so
`revoked` wins.

**`"name"` stays in responses.** It is the REQ-076 handle that lets a token holder match a row. Only the
plaintext produces it (SHA-256 is one-way; 32 bits of digest reveal nothing about a 256-bit random value).
Responses are `:TokensManage`-only. The web does not read it (`TokensPage.tsx:35-40,112` labels rows by user),
but removing it is an API break with no security gain. Audit excludes it (section 5) because the AC forbids
prefixes there, and audit is read more widely (`:AuditRead`, TENANT_AUDITOR) and is immutable.

Response pins to update: `test/letflow/routers/identity_test.exs:1181-1189` (created key set) and `:1223-1233`
(list key set) gain `"issuer_user_id"`, and the router's `token_map` comment (`:1087-1089`). The router's
"Exactly 8 keys" comment (`:1035`) belongs to `user_map/1`, so it is unaffected.

## 5. Audit (names unchanged: `token.create`, `token.revoke`, 0051 D8 `:330-334`)

- Both exclude `[:token_hash, :name]` from `struct_state`. `token.create` `after_state`: `id`, `user_id`
  (target/owner), `issuer_user_id`, `roles`, `expires_at`, `revoked_at`, `last_used_at`, `inserted_at`, plus
  `scope: "tenant_wide"` (0051 D1(c), `:211`). Actor and `trace_id` are the entry columns, unchanged.
  `create_token/3` rows show `issuer_user_id: nil`. `token.revoke` before/after carry the same fields; the actor
  is the revoker. #2547 T-30 (key sets) is updated in this PR.
- `token.listed` (0051 N2 `:566`) is deferred to #2533 (supervisor ruling on OQ4).

## 6. Decisions

| Question | Decision |
|---|---|
| Body `issuer_user_id` | 422 `issuer_user_id_not_allowed` |
| Who mints | active user with TENANT_ADMIN group-held; PA in the platform tenant only (DEVIATION clause, confirmed); never by token roles |
| Subset / PA-not-self / empty roles | 422 `roles_invalid` (0051 M2), fixed body |
| PA token expiry | required, `<= now + :platform_admin_token_max_ttl_days` (90); else 422 `platform_admin_token_expiry_invalid` |
| Inactive target / minter | 422 `user_inactive` (it would be dead now and wake on reactivation) / 403 |
| Error order | authorization (403) before any input or target 422 |
| List | existing `GET /tokens`; `owner_inactive` REQUIRED; `name` kept |
| Out of scope | service-principal exception (OQ3, deferred); `token.listed` (#2533) |

Existing tokens keep working: `verify_api_token/2` unchanged, no UPDATE; legacy rows list `"issuer_user_id": null`;
existing non-expiring PA tokens are untouched (OQ A).

## 7. Callers of `create_token/3` (NULL issuer, no code change)

`lib/mix/tasks/letflow.seed.exam_fixtures.ex:181`; `test/support/platform_tenant_fixture.ex:169`; 28 test files
under `test/letflow/`. `TenantAdminMigration` does not mint (`tenant_admin_migration.ex:311`). HTTP tests that
`POST /tokens` must give caller and target the roles by group membership (PA tokens: self and expiring):
`test/letflow/api/{authorization,identity_id_hardening,platform_admin_outside_platform,platform_escalation_guard}_test.exs`,
`test/letflow/routers/{identity,identity_gh2547_audit,tenant_admin_routes,tenant_auditor_routes,onboarding_scope_extension}_test.exs`,
`test/letflow/api_token_auth_pipeline_test.exs`, `test/letflow/plugs/iss0736_oidc_live_revocation_test.exs`.

## 8. Frontend follow-up (not in this PR)

`web/src/pages/admin/TokensPage.tsx:137-140` colours by `revoked_at` only, so `owner_inactive` (and `expired`) show
green; `web/src/types/api.ts:578` types status as uppercase. File a FRONTEND-DEV issue.

## 9. Follow-on: #2564 (PLAN FOR THE NEXT PR, not part of #2552's implementation)

Option 3: deactivation revokes all the user's tokens in the same transaction; reactivation restores none.
- **Where:** `update_locked_user/5` (`identity.ex:417-457`), shared by `update_user_status/3` (`:403-409`) and
  `update_user_profile/3` (`:375-381`). Trigger: locked `:active` -> updated not `:active`.
- **Order:** `lock_tenant_admins!(prefix)` becomes the first step of EVERY `update_locked_user/5` call (every
  profile edit, not only deactivations: lock-first precedes reading the row; per-tenant serialisation of user
  edits is accepted). Then the user `FOR UPDATE` (`:423`), then the user's `revoked_at IS NULL` tokens
  `ORDER BY id FOR UPDATE`, each revoked through a private `revoke_token_row/4` extracted from
  `revoke_locked_token/3` (`:2087-2109`) and shared with it (changeset per row, not `update_all`). Role and group
  rows are deliberately not row-locked: every binding writer holds the advisory lock. Same order as
  `revoke_token/2` and `mint_token/4`.
- **Audit:** one `token.revoke` per token (minus `[:token_hash, :name]`, after_state adds `cause:
  "owner_deactivated"`); the user entry's after_state adds `revoked_token_count`; actor and trace from
  `opts[:audit_context]`, which both functions start accepting (today `nil`, `:439`, `:445`).
- **Zero-admin guard (0051 N1 `:558-565`; supervisor ruling on OQ2: in #2564):** after the writes, under the
  same lock, `count_tenant_wide_admins(prefix) == 0` -> rollback, `{:error, :last_tenant_wide_admin}` -> HTTP
  409 `last_tenant_wide_admin` (fixed body). Then a `tenant_admin.guard_refused` audit entry (supervisor ruling)
  goes in its own transaction after the rollback, as for 0051's `grant.self_grant_refused`, with metadata
  `{action, actor, target_user_id, reason: "last_tenant_wide_admin", counted_admins, trace_id}`. The count
  already excludes inactive users (`identity.ex:982-986`), so token revocation does not change its result.
- **Consistency with #2552:** after #2564, an inactive owner's tokens are normally `revoked` (which wins);
  `owner_inactive` remains for rows from before #2564, for legacy data and for in-flight cases.

## 10. AC -> design -> named tests (`test/letflow/routers/gh2552_token_issuer_test.exs` unless stated)

| AC | Design | Tests |
|---|---|---|
| issuer column, server-set, legacy NULL | §2, §4 | "mint records caller as issuer_user_id"; "body issuer_user_id -> 422 issuer_user_id_not_allowed, no row, no audit"; "create_token/3 row has NULL issuer, authenticates via verify_api_token/2, lists with issuer_user_id null"; "information_schema: api_tokens.issuer_user_id is_nullable YES, column_default NULL" |
| roles subset of minter AND target, 422 | §3 4,7 | "role not held by target -> 422 roles_invalid"; "role not held by minter -> 422 roles_invalid"; "role held only via target's token -> 422"; "empty roles -> 422 roles_invalid"; "non-admin caller with bad roles -> 403, not 422" |
| audit metadata | §5 | "token.create after_state has issuer_user_id,user_id,roles,expires_at,scope; actor/trace columns set; no token_hash, name or lf_tok_"; same for token.revoke; T-30 updated |
| effective status incl. owner_inactive | §3, §4 | "deactivated owner -> owner_inactive"; "revoked -> revoked"; "expired -> expired"; "revoked+inactive -> revoked"; "expired+inactive -> expired"; unit table for `token_effective_status/3` |
| list exposes issuer, never value | §4 | "item has issuer_user_id (null for legacy), no token/token_hash"; key-set pins updated (§4) |
| only tenant-wide TENANT_ADMIN mints | §3 3 | "TA token but not in TA group -> 403"; "inactive minter -> 403"; "TA mints in customer and platform tenant, no PA binding anywhere (passes unchanged with the PA clause deleted)"; "PA in a customer tenant cannot mint -> 403"; "PA in platform tenant mints own expiring PA token -> 201" |
| PA conditions (advisor) | §3 6 | "PA mints a PA token for another user -> 422 roles_invalid"; "PA token without expires_at -> 422 platform_admin_token_expiry_invalid"; "PA token past the cap -> 422"; "PA token at the cap -> 201" (now + 90 d - 5 s); unit: `validate_platform_admin_expiry/4` at exactly the cap :ok, cap + 1 s error |
| race | §3 | "concurrent remove_group_member vs mint: either 422 or the token commits before the removal" |
| inactive target | §3 5 | "inactive target -> 422 user_inactive, no row" |

Clause-removal check (REVIEWER): delete `platform_admin_mint_exception?/2` and its `or` term. The build and every
non-PA test above must stay green.

## 11. Security, blast radius, anti-patterns

- **INV-4:** the plaintext is only in the return tuple; audit excludes `token_hash` and `name`; error bodies are
  fixed. **INV-6:** the new reads (mint users/roles, list join) use `prefix:` from `scoped_opts`, with joins in
  one tenant schema; the migration is tenant-scoped (guard plus manifest). **INV-2:** the 422 does not say which
  principal or role failed.
- **Blast radius:** `identity.ex`, `api_token.ex`, the router token handlers, `config/config.exs` (one key), one
  tenant migration and its manifest entry, 11 HTTP test files (§7), 3 `list_tokens` call sites, 2 key-set pins.
- **Anti-patterns:** "Two independently-merged Ecto migrations picking the same version-number prefix"; "A
  migration version can collide with a test fixture's hardcoded version constant..."; "Stale `tenant_template`
  schema surviving a migration-adding commit" and "`test/support/tenant_template.ex`'s template-existence check has
  no staleness detection..."; "A bulk `update_all` used for a state transition silently skips both the audit
  call..." (#2564); "Audit-shaped requirements: closed-set and outcome-independence must be checked at draft time".

## 12. Rulings and open questions

Ruled: OQ1 group-held roles only (PR body plus runbook); OQ2 the guard goes in #2564 (§9); OQ3 the
service-principal exception is deferred; OQ4 `token.listed` goes to #2533; OQ5 the PA clause is confirmed with
conditions (§3).
Open: (A) existing non-expiring PA tokens and `create_token/3` (non-HTTP: seeds, fixtures) are not under the PA
expiry cap; applying it there touches about 15 test files that mint PA tokens with `expires_at: nil`. Is a
follow-up wanted?
