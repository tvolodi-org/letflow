# GH-2557: an inactive user's API token must not authenticate

Issue #2557. Gates: SECURITY-REVIEWER (INV-5, INV-6), REVIEWER. Cross-references #2547
(letflow-9c, `Identity.count_tenant_wide_admins/1`, not on main at fde30dca) and decision
0051 N1 (`docs/migration/decisions/0051-org-scoped-role-grants-and-enforcement.md:555`).

## 0. Verified facts (main fde30dca)

| # | Fact | Source |
|---|---|---|
| F1 | The token branch attaches `verified.user_id`/`verified.roles` from the token row, with no owner check. | `lib/letflow/plugs/auth_pipeline.ex:148-157` |
| F2 | `verify_api_token/2` does `Repo.get_by(ApiToken, token_hash: ...)` and rejects only `revoked_at`/`expires_at`. On success it calls `touch_last_used_and_verify/2`, which writes `last_used_at` (best effort). | `lib/letflow/identity.ex:1699-1738` |
| F3 | The issue's OIDC citation (`identity.ex:832-846`) is wrong: that is `list_effective_role_names/2`, with no status check. The real OIDC inactive check is `verify_local_account_state/2`: `provisioned.user.status == :inactive` gives `{:error, {:account, :inactive}}`, rendered as 403 "account is inactive". | `lib/letflow/plugs/auth_pipeline.ex:386-401`, `:192-193` |
| F4 | The only "active" notion for a user is `users.status`, `Ecto.Enum [:active, :inactive]`. There is no `deactivated_at`, no locked flag and no membership-level status. | `lib/letflow/identity/user.ex:41` |
| F5 | `users` and `api_tokens` are both tenant-scoped, in the same tenant schema (Decision 0006). `api_tokens.user_id` is `references(:users)`, `null: false`, with an index. | `lib/letflow/identity/api_token.ex:3-6`, `priv/repo/migrations/20260823000001_create_api_tokens_tenant_scoped.exs:11,29,41` |
| F6 | There are **two** deactivation paths. Both go through `update_locked_user/5` (`users` row `FOR UPDATE`), and neither touches `api_tokens`. (a) `POST /users/:id/status` calls `Identity.update_user_status/3` and audits `"user.update_status"`. (b) `PATCH /users/:id` calls `Identity.update_user_profile/3` and audits `"user.update_profile"`; `User.profile_changeset/2` casts `:status`. | (a) `routers/identity.ex:190`, `identity.ex:384-390`. (b) `routers/identity.ex:186`, `:437`, `identity.ex:356-361`, `identity/user.ex:124-128`. Shared: `identity.ex:398-404` |
| F7 | Every `{:error, {:api_token, _}}` renders the same 401 `"unauthorized"` / `"invalid or expired bearer token"`. | `lib/letflow/plugs/auth_pipeline.ex:189-190`, `:234-241` |
| F8 | `verify_api_token/2` has one production caller. | `auth_pipeline.ex:235` (grep `verify_api_token(` over `lib/`) |
| F9 | Nothing on main counts active tenant admins. The only admin count is the migration report `tenant_admin_member_count_after`. | `lib/letflow/identity/tenant_admin_migration.ex:93,294,331` |

## 1. The "active" notion (settles the first question)

A user is **active** if and only if `users.status == :active` in the tenant schema that
also holds the token. This is the same field, value and schema as the OIDC check (F3, F4).
Activity is **per tenant**: each tenant schema has its own `users` row (F5). Deactivating
in tenant A has no effect on tenant B. The same is true for OIDC.

Intentional asymmetry: OIDC answers 403 "account is inactive" (F3). The token path answers
the revoked-token 401, as AC1 requires. This change does not alter the OIDC response.

## 2. Public contract (AC5: the reusable check that letflow-9c codes against)

Both functions are added to `Letflow.Identity`, with `@doc`. They are the **single
definition** of "active user". `verify_api_token/2` uses `active_user_condition/1`, so the
token path and the #2547 count cannot drift apart.

```
@spec active_user?(Letflow.Identity.User.t()) :: boolean()
@spec active_user_condition(binding :: atom()) :: Ecto.Query.dynamic_expr()
```

* `active_user?/1` is pure and does no I/O. It returns `true` if and only if
  `user.status == :active`. Any other value, including `:inactive`, returns `false`.
  Clause: `%User{}` only. Any other argument raises `FunctionClauseError`.
* `active_user_condition/1` returns an `Ecto.Query.dynamic` expression that is true if and
  only if the row bound by the **named binding** `binding` is active (`status == :active`).
  The caller must bind `Letflow.Identity.User` with `as: binding` in the query that
  receives the expression. Otherwise Ecto raises at query build. The function does not
  set or read a prefix: the caller's `Repo` call passes `prefix:`, as every tenant query
  does. It does no I/O, uses only parameterised Ecto (INV-7) and contains no `fragment`.
* Usage contract for #2547 (letflow-9c):
  - **Admin count:** the member-to-user join is
    `GroupMember join User as: :member on user_id`, and its where clause is
    `^Identity.active_user_condition(:member)`.
  - **Tokens in the count:** if the count also counts token-held TENANT_ADMIN, it must
    join `ApiToken` to `User` with `as: :owner` and apply `active_user_condition(:owner)`,
    plus `is_nil(revoked_at)` and an `expires_at` that is nil or in the future (OQ-1).
  - **PR body:** the PR states "uses GH-2557's `Identity.active_user_condition/1`".
    Whichever PR merges second rebases onto the other's function. If #2547 merges first
    with its own inline `status == :active`, #2557's PR switches that call to this function.

## 3. `verify_api_token/2` change

The `@spec` and the return set are **unchanged** (`identity.ex:1694-1698`). An inactive
owner returns `{:error, :revoked}`, the exact term a revoked token returns. So
`verify_token_credential/2` (`auth_pipeline.ex:234-241`) and `handle_auth_error/2` are
untouched (F7), and status, body and headers are byte-identical by construction (AC1).
No new atom reaches the plug or the logs.

**Query shape** (replaces `Repo.get_by/3` at `identity.ex:1703`): one `Repo.one/2`,
`prefix: prefix`, with:
* `from ApiToken as :token`;
* `inner join User as :owner on owner.id == token.user_id`;
* `where token.token_hash == ^token_hash`;
* the select is applied with `select/3` as a **top-level interpolated map of dynamics**:
  `select(base, [token: t], ^%{token: dynamic([token: t], t), owner_active: active_user_condition(:owner)})`.

The result is `%{token: %ApiToken{}, owner_active: boolean()}`, or `nil` when no row
matches. CODE-DESIGN-VALIDATOR planned this exact shape on Ecto 3.14.1 to one query:
`%{token: a0, owner_active: u1.status == "active"}`.

Do not use the other forms. A tuple or literal map that contains a nested `^dynamic`
compiles but fails at plan time ("dynamic expressions can only be interpolated at the
top level of ... select").

`active_user_condition/1` stays the only definition of "active".

The single prefix applies to both sources, so both tables are read from the same tenant
schema (INV-1, INV-6). `token_hash` keeps its unique index, and `users.id` is the primary
key, so this stays one indexed round trip.

**Decision order** (deterministic):
1. no row gives `:invalid`;
2. `revoked_at` not nil gives `:revoked`;
3. owner not active gives `:revoked`, with **no `last_used_at` write**;
4. `expires_at` reached gives `:expired`;
5. otherwise `touch_last_used_and_verify/2`, unchanged.

An inner-join miss with an existing token row cannot happen: the FK is NOT NULL and no
user-delete function exists (grep `def delete_user`: none). If it ever did happen, the
result is `:invalid`, still the same 401.

Doc updates, prose only:
* the `verify_api_token/2` `@doc`: inactive owner gives `:revoked`, with no touch;
* the moduledoc list of byte-identical 401s at `auth_pipeline.ex:67-72`: add "a token
  whose owner is inactive".

**Timing (AC2 / INV-5):** revoked and inactive-owner both run one identical SELECT and
no write. Only active+valid adds the pre-existing `last_used_at` UPDATE.

## 4. Deactivate and reactivate: no token-state change (AC3 / AC4)

Decision: **do not revoke** token rows when a user is deactivated, on either path (F6).
`update_user_status/3` and `update_user_profile/3` are both unchanged, and neither
touches `api_tokens`. They emit only `user.update_status` and `user.update_profile`,
never `token.revoked`, so audit events are unchanged (AC4).

Both paths write the same `users.status` column, which the live join in §3 reads on
every request. Reactivating the user makes the token work again on the next request,
unless it is revoked or expired. Its stored `roles` snapshot still applies
(`api_token.ex:16-19`). Revoking on deactivate would be irreversible, would add audit
events and would race with concurrent verifies; the live join avoids all three.

## 5. Other consumers of `api_tokens` / `verify_api_token`

| Consumer | Needs the owner check? |
|---|---|
| `auth_pipeline.ex:235` (the only verifier caller) | Covered by section 3. No code change. |
| `Identity.list_tokens/1` `:1563`, `GET /tokens` `routers/identity.ex:227`, `token_status/1` `:1028-1037` | **No.** This is an admin listing. A token of an inactive user is still displayed as "active" because its row state did not change. OQ-2 asks whether to add a derived status. Not in scope. |
| `create_token/3` `:1454`, `revoke_token/2` `:1626`, `token_carries_platform_admin?/2` `:1603` | No. These are not authentication paths. Creating a token for an inactive user is OQ-3. |
| `TenantAdminMigration` `:261,:377,:546` | No. It is a one-time role rewrite. |
| `tenant_onboarding.ex:45`, `audit/entry.ex:5`, `public_read/handle.ex:9`, `webhooks/subscription.ex:5,41`, `tasks.ex:119` | No. These are prose references only. |
| Scripting / 7b (`lib/letflow/scripting`) | No. Grep finds no reference to `api_token` or `verify_api_token`. |
| Signed attachment links (REQ-386, `lib/letflow/repository/attachment_links.ex`) and public-read handles (`lib/letflow/public_read/handle.ex`) | **Out of scope.** These are time-limited capabilities, not user credentials, and they are not authenticated through `verify_api_token/2`. |

## 6. AC to design to test

New `describe "GH-2557 ..."` blocks go in `test/letflow/api_token_auth_pipeline_test.exs`
(HTTP level, existing `api_token_request/4`) and in `test/letflow/identity_test.exs`
(the `verify_api_token/2` describe at `:1064`). Routes:
* **admin route:** `GET /api/v1/identity/tokens` (`:TokensManage`, `routers/identity.ex:227`);
* **plain route:** `GET /api/v1/me/memberships` (`:MembershipsRead`, `routers/me.ex:74`).

| AC | Design element | Test (name) |
|---|---|---|
| AC1 | §3, inactive gives `:revoked` | "deactivated owner's TENANT_ADMIN token is refused 401 on GET /identity/tokens and GET /me/memberships" (positive control first: 200 on both while active) |
| AC1 | §3, F7 | "inactive-owner rejection is byte-identical to a revoked token": status, `resp_body` and `resp_headers` are equal to a revoked token's response on the same route |
| AC2 | §3 query shape | "verify_api_token: inactive owner and revoked token each issue exactly 1 query and no UPDATE on api_tokens". The `[:letflow, :repo, :query]` telemetry handler keeps only events from the test's own process (`self()` captured at attach). It asserts a count of exactly 1 per call for both cases, and that no captured query is an UPDATE of `api_tokens`. |
| AC2 | §3 step 3 | "verify_api_token: inactive owner returns {:error, :revoked} and leaves last_used_at unchanged" |
| AC2 | §3 order | "verify_api_token: inactive owner with an expired token returns {:error, :revoked}" (step 3 comes before step 4) |
| AC1/AC2 | §3 select shape | The §3 select shape is proven at runtime by the request-path tests in this table, which execute the real query. No separate compile probe. |
| AC3 | §4 | "reactivating the owner makes the same token authenticate again (200)" |
| AC3 | §3 order | "reactivated owner with a revoked token stays 401 / with an expired token stays 401" |
| AC3 | unchanged | existing REQ-076 revoked/expired tests in both files stay green, unmodified |
| AC4 | §4, F6(a) | "deactivate via POST /users/:id/status: only user.update_status audit; token revoked_at stays nil; no token.revoked; token gets the revoked-token 401" |
| AC4 | §4, F6(b) | "deactivate via PATCH /users/:id status=inactive: token gets the same 401 as a revoked token; the only audit row is user.update_profile; no token.revoked; revoked_at stays nil" |
| AC5 | §2 | This PR tests the **contract only**: "active_user?/1 truth table" and "active_user_condition/1 filters an inactive member out of a GroupMember-User join". The test that the admin count excludes inactive users lives in #2547's PR (letflow-9c), which owns `count_tenant_wide_admins/1`. |

## 7. Security invariants

* **INV-5:** the response and the query count are identical for a revoked token and an
  inactive owner (§3). The response never reveals that the user exists or is inactive.
* **INV-6:** this is a changed authentication data path. Scoping: one Ecto query, with a
  prefix taken from the server-resolved `tenant.id` (`auth_pipeline.ex:150-152`), never
  from the token. The join is same-schema only.
* **INV-1:** a cross-tenant token still misses its row (unchanged).
* **INV-7:** no raw SQL.

## 8. Blast radius

Changed: `lib/letflow/identity.ex` (`verify_api_token/2`, plus two new public functions)
and doc prose in `auth_pipeline.ex`. No migration, no schema change, no route change and
no OIDC change.

Behaviour change: a token owned by an inactive user now gets 401. This is intended and
can break any test fixture that issues tokens for `status: :inactive` users (TEST-RUNNER:
grep `status: :inactive` near `create_token`).

## 9. Anti-patterns checked (`docs/anti-patterns.md`)

* "Inheriting a claim from a record instead of re-deriving it from the source": the
  issue's `identity.ex:832-846` was re-derived to the real check at
  `auth_pipeline.ex:386-401` (F3).
* "A gate-approved design fixing a shared write function missed a sibling write path
  constructing the same state independently":
  - the verifier has exactly one caller (F8), and the other consumers are listed in §5;
  - both writers of `users.status` (F6 a and b) are covered by the live join;
  - each writer has its own test in §6.
* "Duplicating an `Ecto.Query.fragment/1` SQL literal instead of sharing it": not
  applicable. No fragment is used, and the active condition is defined once (§2).

## 10. Open questions

* **OQ-1 (letflow-9c):** does #2547's count include token-held TENANT_ADMIN, or only
  group members? §2 gives the conditions for either case.
* **OQ-2:** should `GET /tokens` show the effective status ("owner_inactive")?
  Default: no, out of scope. File it separately if wanted.
* **OQ-3:** should `create_token/3` refuse an inactive owner? Default: no change. The
  token would not authenticate anyway.
