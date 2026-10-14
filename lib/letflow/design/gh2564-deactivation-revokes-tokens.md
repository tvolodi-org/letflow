# GH #2564: deactivation revokes all the user's API tokens; 0051 N1 guard on deactivation

Ruling: issue comment 6174049298 (option 3). Plan: `gh2552-api-token-issuer-and-roles.md` §9 (corrected in this PR).
0051 M1 (`0051-...md:49-51`), D8 (`:324-339`), N1 (`:560-567`). Base `origin/main` 9d95d433 (#2552), which contains
#2547 (2a29b162) and #2557 (3e9b6faf). `identity.ex` = `lib/letflow/identity.ex`; router = `lib/letflow/routers/identity.ex`.

## 1. Verified starting point

- `update_user_profile/3` (`identity.ex:376-382`) and `update_user_status/3` (`:404-410`) both call
  `update_locked_user/5` (`:418-462`): Multi `:locked_user` `FOR UPDATE` (`:423-428`), `:user` update (`:429-431`),
  `directory_step` (`:432-434`), `:audit` with `actor_id: nil`, `trace_id: nil` (`:435-450`), result `case` (`:452-458`),
  `rescue` -> `{:transaction_failed, e}` (`:459-461`). No advisory lock, no token write today.
- `count_tenant_wide_admins/1` (`:1010-1016`) counts ACTIVE users (`:1060`) in the TA group or owning a live TA token
  (`:1050-1056`); sees the caller's uncommitted writes (`:1000-1001`). `lock_tenant_admins!/1` (`:1105-1115`): xact
  advisory lock, raises outside a transaction.
- `revoke_locked_token/3` (`:2383-2419`): lock, row `FOR UPDATE`, `revoke_changeset`, `token.revoke` via
  `Audit.insert_entry/3` with `token_audit_state/1` (`:2243-2247`: no `token_hash`, no `name`, adds `scope`).
- `token_effective_status/3` (`:2129-2141`): `revoked` wins over `owner_inactive`. `list_tokens/1` (`:2270-2290`).
- Router: `PATCH /users/:id` and `POST /users/:id/status` (`:195-201`) pass `user_write_opts/1` (`:303-305`), which has
  no `:audit_context`; `do_patch/3` (`:444-461`) and `do_status_update/3` (`:488-507`) map errors; `audit_opts/2`
  (`:1060-1067`); fixed-code 409 precedent `Response.conflict(conn, "role_already_bound")` (`:1003`).
- `User.status` is `Ecto.Enum [:active, :inactive]` (`identity/user.ex:41`); `profile_changeset/2` casts `:status`
  (`:124-129`). `Audit.insert_entry/3` opens its own transaction (`audit.ex:233-240`).
- Lock protocol of #2547 §6.4 (`gh2547-...md:719-735`): advisory lock first, write, count, roll back on 0. Its step 2
  (TA role row by name `FOR UPDATE`) is NOT taken here: deactivation writes no role/group row, and every binding writer
  holds the advisory lock (decided constraint 2, agreed with letflow-9c).

## 2. Domain API (`Letflow.Identity`)

```
@type status_write_error :: :last_tenant_wide_admin
@spec update_user_profile(Ecto.UUID.t(), map(), user_write_opts()) ::
        {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t() | directory_guard_error() | status_write_error()}
        | {:error, {:login_directory, term()}} | {:error, {:transaction_failed, Exception.t()}}
@spec update_user_status(Ecto.UUID.t(), :active | :inactive, user_write_opts()) :: (same as above)
# private
@spec status_write?(attrs :: map()) :: boolean()      # Map.has_key?(attrs, "status") or Map.has_key?(attrs, :status)
@spec update_locked_user(Ecto.UUID.t(), user_write_opts(), term(), String.t(), (User.t() -> Ecto.Changeset.t()),
        status_write :: boolean()) :: same result union
@spec revoke_owner_tokens(user_id :: Ecto.UUID.t(), prefix :: String.t(), ctx :: AuditContext.t()) ::
        {:ok, [ApiToken.t()]} | {:error, Ecto.Changeset.t() | term()}
@spec revoke_token_row(ApiToken.t(), prefix :: String.t(), ctx :: AuditContext.t(), cause :: String.t() | nil) ::
        {:ok, ApiToken.t()} | {:error, Ecto.Changeset.t() | term()}
@spec record_guard_refused(prefix :: String.t(), refusal :: %{action: String.t(), actor: Ecto.UUID.t() | nil,
        target_id: Ecto.UUID.t(), reason_code: String.t(), counted_admins: non_neg_integer(),
        trace_id: String.t() | nil}) :: :ok
```

`user_write_opts` gains optional `audit_context` (as `AuditContext.from_opts/1`, `audit_context.ex:34-47`).
`update_user_status/3` passes `status_write: true`; `update_user_profile/3` passes `status_write?(attrs)`.

**`revoke_token_row/4`** is extracted from `revoke_locked_token/3` (`:2395-2417`) and shared by it (cause `nil`,
so `DELETE /tokens/:id` audit is byte-for-byte unchanged): changeset update (never `update_all`), then `token.revoke`
with `before_state: token_audit_state(token)`, `after_state: token_audit_state(updated)` plus `cause` when non-nil,
actor/trace from `ctx`. Returns tagged tuples; `revoke_locked_token/3` maps `{:error, r}` to `Repo.rollback(r)` as today.

**`revoke_owner_tokens/3`**: `from t in ApiToken, where t.user_id == ^id and is_nil(t.revoked_at), order_by t.id,
lock "FOR UPDATE"`, then `revoke_token_row(t, prefix, ctx, "owner_deactivated")` per row in id order, one `now`
(second-truncated) for all; first error stops and is returned. Expired-but-unrevoked tokens are revoked too ("every
non-revoked token", ruling AC1).

**`record_guard_refused/2`** (`@doc false` public, so #2533 1b can reuse it, OQ-2): `Audit.insert_entry(Repo, attrs,
prefix)` OUTSIDE any transaction, `action: "tenant_admin.guard_refused"`, `resource_type: "user"`, `resource_id:
target_id`, `actor_id`/`trace_id` columns = refusal actor/trace, `before_state: nil`, `after_state:` the refusal map,
EXACTLY `{action, actor, target_id, reason_code, counted_admins, trace_id}` (0051 D8 `:339`). Never raises: an
`{:error, _}` or a rescued exception -> `Logger.error("tenant_admin.guard_refused audit write failed")` with metadata
`action`, `target_id`, `trace_id` and `error_kind` (the exception module or the error atom, never a message or a
value), then `:ok`. **Decision: the response stays 409.** The refused change is already rolled back, so the state
the 409 reports is true; a 500 would invite a retry that refuses again. D8's same-transaction rule covers successful
changes only (`0051:339`); the log line is the fallback record.

## 3. `update_locked_user/6`: step order (one Multi, one transaction)

`ctx = AuditContext.from_opts(opts)`. Steps marked [S] run only when `status_write` is true.

1. [S] `:tenant_admin_lock`: `lock_tenant_admins!(prefix)`, the FIRST locking statement, before any row lock.
2. `:locked_user`: unchanged `FOR UPDATE` (`:423-428`).
3. [S] `:admins_before`: `count_tenant_wide_admins(prefix)`.
4. `:user`: unchanged update (`:429-431`). 5. `directory_step`: unchanged (`:432-434`).
6. [S] `:revoked_tokens`: when `locked.status == :inactive or updated.status == :inactive`, `revoke_owner_tokens/3`
   (tokens `FOR UPDATE` by id, per-row update, one `token.revoke` each); else `{:ok, []}`.
7. `:audit` (user entry, `:435-450`): `actor_id: ctx.actor_id`, `trace_id: ctx.trace_id` (was `nil`, `:440`, `:446`);
   [S] `after_state` adds `revoked_token_count: length(revoked_tokens)` (0 included).
8. [S] `:admin_guard`, when `updated.status == :inactive`: `after = count_tenant_wide_admins(prefix)`;
   `admins_before > 0 and after == 0` -> `{:error, {:last_tenant_wide_admin, after}}`, else `{:ok, after}`.
9. Result `case` adds: `{:error, :admin_guard, {:last_tenant_wide_admin, n}, _}` -> (transaction already rolled back)
   `record_guard_refused(prefix, %{action: "deactivate_user", actor: ctx.actor_id, target_id: id, reason_code:
   "last_tenant_wide_admin", counted_admins: n, trace_id: ctx.trace_id})`, then `{:error, :last_tenant_wide_admin}`;
   `{:error, :revoked_tokens, reason, _}` -> `{:error, reason}`. The `rescue` stays and does NOT write the refusal.

Lock order (agreed with letflow-9c #2547 and letflow-4 7b-2b): advisory -> user row -> token rows by id -> audit
chain (`insert_entry`) -> count. Same prefix as `revoke_token/2` (advisory -> token) and `mint_token/4` (advisory ->
users by id `FOR SHARE` -> insert), so no cycle: every path that row-locks a user or token takes the advisory lock first.

**Decisions inside the constraints.**
- **PATCH without `status` takes no lock** and runs none of [S]: it changes no admin-relevant fact. A PATCH or POST
  carrying any `status` (`active` too) takes it: the lock must precede the row read, so it is chosen from the request,
  not the row; and reactivation adds an admin, which #2533 1b AC 12 (`requirements.yaml:36252`, N1 (e) `:36185`)
  requires to hold the lock. This PR delivers the `update_user_status` half of that AC; letflow-9c only tests it.
- **Guard = transition to zero** (`admins_before > 0`): measured, not predicted (#2547 §6.4 step 5). A bare `== 0`
  would refuse deactivating ANY user in a tenant that has no counted admin (fresh tenants, most fixtures, 14 calls in
  `identity_login_directory_test.exs`). Deactivating a non-admin cannot lower the count. OQ-1 aligns letflow-9c.
- **Reactivation restores none, legacy included:** step 6 also runs when the locked row is inactive, so tokens left
  live by a pre-#2564 deactivation (or by `create_token/3` for an inactive user) are revoked before the user becomes
  active, with `cause: "owner_deactivated"`. A reactivation of a user deactivated after #2564 finds none (count 0).
- **Re-deactivating** an inactive user (POST `inactive` again) revokes any leftover tokens: the cleanup path for
  legacy rows. Guard: `admins_before` already excludes the user, so no refusal.

## 4. HTTP (router)

`do_patch/3` and `do_status_update/3` call Identity with `audit_opts(conn, opts)` (`:1060-1067`); the
`with_platform_admin_member_guard` helpers keep the unchanged opts (`:1059`). Both add
`{:error, :last_tenant_wide_admin} -> Response.conflict(conn, "last_tenant_wide_admin")`: 409, fixed body naming no
admin and no count (INV-2). No route, schema or response map changes.

## 5. Audit summary

| Event | When | Payload |
|---|---|---|
| `token.revoke` (existing name, 0051 D8 `:331-333`) | one per revoked token, same tx | before/after = `token_audit_state/1` (id, user_id, issuer_user_id, roles, expires_at, revoked_at, last_used_at, inserted_at, scope); after adds `cause: "owner_deactivated"`; actor/trace columns; never hash, name or value |
| `user.update_status` / `user.update_profile` | same tx | as today + `revoked_token_count` on status writes; actor/trace now set |
| `tenant_admin.guard_refused` | after rollback, own tx | exactly `{action: "deactivate_user", actor, target_id, reason_code: "last_tenant_wide_admin", counted_admins, trace_id}` |

## 6. Callers and effects

| Caller | Effect |
|---|---|
| router `:450` (PATCH), `:496` (POST status) | actor/trace in audit; tokens revoked; 409 on last admin |
| `web/src/api/identity.ts:30` (PATCH) | a 409 shows as a generic error; FRONTEND-DEV follow-up issue for a message |
| IdP / OIDC sync, seeds, mix tasks, `deploy/`, `scripts/`, `apps/` | none call either function (repo grep); `TenantAdminMigration` neither |
| `test/letflow/api_token_auth_pipeline_test.exs:250-409` (GH-2557) | single token-admin tenant -> now 409: add a second admin; `:282` (reactivation 200), `:332`, `:371` ("revoked_at nil", "no token.revoke") are superseded by this ruling and rewritten to the new behaviour |
| `test/letflow/plugs/iss0736_oidc_live_revocation_test.exs:209-213` | sole group admin -> 409: add a second admin |
| `audit_dispositions_test.exs:432-469`, `:603-629`; `identity_login_directory*_test.exs` | unchanged (no admin; nil actor without context; forced failure still rolls back) |
| `gh2552_token_issuer_test.exs:62` | deactivates by `Repo.update!`, bypassing Identity: `owner_inactive` row stays valid |

**Existing integrations (ruling AC 6).** Repo-wide grep for token minting outside tests: only
`lib/mix/tasks/letflow.seed.exam_fixtures.ex:181` (CANDIDATE token for a seeded candidate, never deactivated: no
migration) and `test/support/platform_tenant_fixture.ex:169` (test-only). No `lf_tok_`/`/identity/tokens` caller in
`deploy/`, `scripts/`, `config/`, `priv/`, `apps/`. Operational migration: an integration whose owner is deactivated
must be re-minted after reactivation by a tenant-wide TENANT_ADMIN under #2552's rules. The PR body lists this.

## 7. AC -> design -> tests (new file `test/letflow/routers/gh2564_deactivation_revokes_tokens_test.exs`)

| AC | Design | Tests |
|---|---|---|
| revoke all in same tx; forced failure rolls back both | §3 6 | "POST status inactive revokes all N unrevoked tokens (TA, plain, expired), leaves already-revoked revoked_at unchanged"; same via PATCH; "audit table dropped -> 500, user active, every token revoked_at nil" (both paths) |
| one `token.revoke` per token, metadata | §2, §5 | "N tokens -> N token.revoke with cause owner_deactivated, actor = caller, user_id, id, roles, trace_id = x-trace-id; no token_hash, name, lf_tok_ in any state"; "user entry revoked_token_count == N, actor set" |
| reactivation resurrects none | §3 | "deactivate TA-token holder, reactivate (both paths, 4 combinations): token revoked, old plaintext 401"; "legacy: Repo.update! inactive, live token, POST active -> token revoked, 401" |
| list shows `revoked` | §1 | "GET /tokens after deactivation: status revoked, not owner_inactive; after reactivation still revoked" |
| N1 counts across deactivation/reactivation | §3 8 | "last tenant-wide admin (group) deactivated -> 409 last_tenant_wide_admin, user active, tokens unrevoked, no token.revoke/user entry, exactly one guard_refused with the 6 keys, counted_admins 0" (POST and PATCH); same for a token-only admin; "two admins: first deactivation 200, second 409; reactivate first -> second 200"; "tenant with no admin: deactivating a plain user 200"; "guard_refused write forced to fail -> still 409, log captured, no value logged" |
| lock order | §3 | "test holds lock_tenant_admins! in another tx: POST status and PATCH status block until release"; "PATCH display_name only does not block"; "concurrent deactivation of U and DELETE /tokens of U's token: both complete, one token.revoke for that token" |
| integrations listed | §6 | PR body (no test) |

## 8. Security, blast radius, anti-patterns

- **INV-4:** audit states come only from `token_audit_state/1`; the refusal log carries no message or value; error
  bodies are fixed. **INV-6:** every new query uses `prefix:` from `user_write_opts` (tenant from `auth_context`,
  router `:303-305`); tokens and users are joined by id in one schema; no new route. **INV-2:** 409 names nothing.
- **Blast radius:** `identity.ex` (two functions, one private extracted, three helpers), router (two handlers), 2 test
  files rewritten (§6), 1 new test file. Behaviour change: deactivation now ends integrations; the last tenant-wide
  admin cannot be deactivated.
- **Anti-patterns:** "A bulk `update_all` used for a state transition silently skips both the audit call..."
  (per-row changeset); "Audit-shaped requirements: closed-set and outcome-independence must be checked at draft time"
  (exact key set; refusal written whatever the outcome); "A validator that began refusing at activate broke two
  already-merged test files its own run never touched" (TEST-RUNNER runs `test/letflow/identity*`,
  `test/letflow/routers/identity*`, `test/letflow/api*`, `test/letflow/plugs`, `test/letflow/audit_dispositions_test.exs`).

## 9. Open questions

- OQ-1 (letflow-9c): guard rule "refuse iff count before > 0 and after == 0". #2533 1b's `revoke_token` guard
  needs the same rule, or revoking a TA token in an admin-less tenant is refused.
- OQ-2 (letflow-9c): `record_guard_refused/2` is shared; whichever PR merges second reuses it, not a copy.
- OQ-3: `cause` for legacy tokens revoked at reactivation is `"owner_deactivated"` (no new value). Confirm.
