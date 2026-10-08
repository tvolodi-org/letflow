# ISS-1030 / Q-1012 / GH #2312 -- onboarding wizard: the named administrator is collected but neither created nor granted anything; no idp_realm_id is bound

Status: DESIGN (CODE-DESIGNER). Written against `origin/main` ff944312 (worktree `wt1012`, branch `feat/ISS-1030-onboarding-admin`). Design only: signatures, type shapes, tables, algorithms in prose. No implementation code, no tests, no lib edits, no commit.

Authority and inputs (all read, none re-decided): GH #2312 body (BA default decision, items 1-4, ACs 1-5) and its two comments (letflow-9a fix direction; BA amendment of 2026-10-07 adding ACs 6-8, comment id 6031770847); letflow-9a's BINDING ANSWERS Q1-Q6 (restated in section 0); decision 0044 (Phase 1 realm-per-tenant, brokered IdP and shared tier deferred), 0046 D4/D5/D8 (D4: `PLATFORM_ADMIN` exists only in the platform tenant and has no power inside a customer tenant; D5: `TENANT_ADMIN` is the tenant's owner role; D8: migration of existing admins); `lib/letflow/design/req447-tenant-admin-role.md` (section 3.7, section 7 = the investigation that filed this issue) and `lib/letflow/design/req447-infra-realm-mapping.md` (section 3b); `docs/agents/instructions/security-invariants.md` INV-1..INV-10.

---

## 0. Summary of what is proposed

1. TWO pull requests (Q6 A), in this order.
   * **PR 1 (no schema, no migration).** BA items 1-3 plus the runbook. Stops the silent drop; optional validated `idp_realm_id` on `POST /onboarding`; a bind-once route for the operator to bind the realm later; a "not yet loginable" marking in the onboarding record; the manual runbook `docs/runbooks/onboarding-new-tenant-realm.md`; the SPA wizard stops requiring the admin fields; creates `docs/issues/ISS-1030.yaml` (section 11).
   * **PR 2 (one tenant-scoped migration).** Pending administrator grants (a NEW tenant-schema table), first-login binding in the OIDC auth path, the per-realm unverified-e-mail setting (default OFF), audit events, the operator list (with AGE) and revoke routes, and the tenant-admin READ route (Q5, decision in section 5.3).
2. The grant is TENANT_ADMIN only, structurally (a CHECK constraint, not just code). It is created only by the onboarding call (v1). It binds only on a VERIFIED e-mail claim equal to the stored key, through the tenant's own realm, exactly once, inside one transaction together with its audit entry. `preferred_username` is never consulted.
3. Wizard-driven Keycloak realm/user creation (BA item 4) stays OUT. The operator or infra still creates the realm and the first user (runbook).
4. Findings beyond the issue text that need acknowledgement (all in section 12): the SPA wizard is written against a saga-shaped contract the backend does not speak (OQ-10); `POST /onboarding` also silently drops `client_config`, `realm_config` and `redirect_uris` (treated the same way as `admin_*`); bind-once `idp_realm_id` is a narrow, atomic exception to the "immutable" rule of decision 0006 (OQ-1); the reserved realm `master` must be refused (OQ-9).

---

## 1. Current behaviour (file:line, `origin/main` ff944312)

| # | Fact | Evidence |
|---|---|---|
| C1 | `POST /onboarding` validates only `slug`, `display_name`, `hostname`. | `lib/letflow/routers/onboarding.ex:147-172` (`@create_schema`) |
| C2 | `Validation.validate/2` returns `Map.take(body, declared_fields)`, so every other body key (`admin_email`, `admin_username`, `admin_display_name`, `client_config`, `realm_config`, `redirect_uris`) is dropped before the handler runs. No error, no echo. | `lib/letflow/api/validation.ex:234-235` |
| C3 | `handle_create/1` keeps `slug` and `display_name`, adds `"status" => "migrating"`, calls `Identity.create_tenant/1`. No `idp_realm_id` is set. | `onboarding.ex:174-183` |
| C4 | `Identity.create_tenant/1` always uses `Tenant.create_changeset(..., :disabled)`: `idp_realm_id` is cast but not required. | `lib/letflow/identity.ex:1001-1004`, `lib/letflow/identity/tenant.ex:118-125, 402` |
| C5 | The tenant's `idp_realm_id` is immutable after creation: no changeset on an existing row casts it (`admin_patch_changeset/2` casts `display_name`, `login_disclosure_mode` only). | `tenant.ex:44-57, 129-148`; decision 0006 R5 |
| C6 | `provision_and_bind/4` runs `TenantOnboarding.provision_and_migrate/1` (schema, migrations, role seeding including the `TENANT_ADMIN` group and binding, then `:active`) and `Identity.create_onboarding/1`. It never creates a user, a membership or a token. The moduledoc says so. | `onboarding.ex:209-221, 104-108`; `lib/letflow/tenant_onboarding.ex:168-175` |
| C7 | `onboarding_map/1` returns exactly five keys: `id`, `tenant_id`, `slug`, `hostname`, `created_at`. | `onboarding.ex:259-267` |
| C8 | A first login resolves the tenant ONLY through the token's realm: `extract_realm` -> `Identity.resolve_tenant_by_realm/1` (`Repo.get_by(Tenant, idp_realm_id: ...)`) -> `verify_realm_ownership/2`. A tenant with `idp_realm_id` NULL can never be reached by any OIDC token. | `lib/letflow/plugs/auth_pipeline.ex:125-133`; `identity.ex:152-157` |
| C9 | The OIDC chain is: verify token, realm, tenant, ownership, `map_claims`, `provision_user` (`Identity.provision_oidc_user/4`), `verify_local_account_state` (reads effective roles from `group_members`/`tenant_role` per request), `attach_auth_context`. | `auth_pipeline.ex:125-133, 302-361` |
| C10 | `provision_oidc_user/4` upserts the user keyed by `(external_realm, external_id)`; it returns `%{user, created}`; `sync_role_claims_from_token/3` copies claimed role names into `group_members` once, gated on `users.role_claims_synced_at` being NIL (stamped only when at least one grant was written, ISS-0773, so a user whose claims resolve to nothing is retried every login). | `identity.ex:129-141, 851-926, 1958-2010` |
| C11 | `IdentityContext` carries `email` (claim `email`, default `""`) and `preferred_username` but NO `email_verified`. | `lib/letflow/oidc/identity_context.ex:29-51`; `lib/letflow/oidc/claim_mapping.ex:92-101` |
| C12 | Per-realm JIT config: `Letflow.Oidc.JitProvisioningConfig.for_realm/1` reads `config :letflow, :oidc_jit_provisioning` (a map keyed by realm; only `bpm-default` is listed, every other realm gets `default/1`). | `lib/letflow/oidc/jit_provisioning_config.ex:44-82`; `config/prod.exs:32-38` |
| C13 | The tenant-scoped migration mechanism: a migration file guarded by `if prefix()` AND an entry in `@tenant_scoped_migration_manifest`. New tenants get it through `replay_migrations/2` inside `provision_and_migrate/1`; existing tenants get it at every app start through the boot-time `replay_all_pending/0` (ISS-0771). | `lib/letflow/tenant_provisioning.ex:489, 733-737, 372, 435`; `lib/letflow/tenant_provisioning/migration_replay_boot.ex`; example `priv/repo/migrations/20260923010002_create_user_entity_type_grants.exs` |
| C14 | Audit entries are written in the tenant's own chain via `Audit.append_multi/4` or `Audit.insert_entry/3`, in the same transaction as the mutation. `actor_id` is a bare uuid (the existing `patch_tenant_with_audit` writes an operator's id into a customer tenant's chain). | `lib/letflow/audit.ex:182-260`; `identity.ex:1130-1170` |
| C15 | The SPA wizard REQUIRES `admin_email`, `admin_username`, `admin_display_name` (client-side validation), sends them plus `client_config`, `realm_config` and `redirect_uris`, and expects a saga-shaped answer (`onboarding_id`, `state`, `idp_realm_id`, `admin_user_id`). The backend answers `201` with `id` and no `state`. | `web/src/pages/admin/onboarding/RegisterTenantPage.tsx:85-97, 289-300`; `web/src/api/onboarding.ts:26-70, 85-120`; `web/src/pages/admin/onboarding/OnboardingProgressPage.tsx:68` |
| C16 | Runbook house style: `docs/runbooks/*.md`, owner/evidence/date checklist tables, release `rpc` form, names only, no secrets. | `docs/runbooks/login-directory-enablement.md`, `login-directory-pepper-rotation.md`, `req447-infra-realm-mapping.md` |
| C17 | Role claims in tokens: infra mapping requires every new realm to issue `TENANT_ADMIN`, never in `default-roles-<realm>`, default groups or client scopes. | `lib/letflow/design/req447-infra-realm-mapping.md` sections 1, 3b |

---

## 2. Binding answers (letflow-9a) as design constraints

| Q | Answer | Where applied |
|---|---|---|
| Q1 A | Separate tenant-schema table; pending grants; e-mail key normalised by trim + lower-case ONLY; unique per tenant. | 4.1 |
| Q2 A | Bind only with a VERIFIED e-mail (`email_verified` JSON `true`) equal to the pending key, through the tenant's own realm; NEVER `preferred_username`. Per-realm, operator-set, DEFAULT-OFF, server-side-only setting accepts the e-mail without the verified flag. Exactly once (transaction); confers TENANT_ADMIN and nothing else; login response identical with or without a pending grant; bind audited naming the grant's creator; unverified/different e-mail never binds. | 6, 7 |
| Q3 A | `admin_email` OPTIONAL; absent -> the response says plainly the tenant has no administrator and names the next step; present -> valid e-mail, stored pending, response lists next steps; never collect-and-discard; other `admin_*` echoed as "not provisioned"; grant consumable only once the tenant has an `idp_realm_id`. | 3, 5.1 |
| Q4 A | No TTL; operator list shows each grant's AGE; a grant is CREATED only by the onboarding call (v1); an audited revocation route for the operator. | 5.2 |
| Q5 | B preferred (tenant TENANT_ADMIN can READ, not create, its own tenant's pending grants under the existing user-management permission); A acceptable for v1. DECISION: B, in PR 2. Reason in 5.3. | 5.3 |
| Q6 A | Two PRs. | 0, 8 |

---

## 3. PR 1 -- scope and design

### 3.1 Behaviour of `POST /onboarding` after PR 1

Request: unchanged required fields (`slug`, `display_name`, `hostname`) plus OPTIONAL `idp_realm_id` (string). Every other top-level key is read from the raw body (`conn.body_params`) ONLY to build the response; nothing is stored or acted on.

Validation of `idp_realm_id` (all before any row is written, so a refusal leaves no tenant behind):
1. Absent or JSON null: allowed (the tenant is created "not yet loginable").
2. Trim first, and STORE the trimmed value. Present but blank after trim: 422 field error `idp_realm_id` ("must not be blank"); the error text never echoes the value.
3. Format, applied to the trimmed value: the regular expression `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$` (1..64 characters, ASCII letters, digits, `_`, `-`; NO dot, so `.` and `..` can never form a path segment; must start with a letter or digit); otherwise 422. (This is narrower than the alphabet `extract_realm` can parse out of an `iss`; a realm whose name falls outside it cannot be bound, which is an accepted limit.)
4. Reserved: `master` compared CASE-INSENSITIVELY (`master`, `Master`, `MASTER`; Keycloak's own administration realm) is refused with 422 (OQ-9).
5. Existence: `Letflow.Oidc.RealmProbe.verify(realm :: String.t()) :: :ok | {:error, :not_found} | {:error, :unreachable}` (new module, behaviour with a configurable adapter, `config :letflow, :oidc_realm_probe`). The default adapter does NOT use the `oidcc` discovery loader: `deps/` is not present in the design worktree, so the loader's redirect and body-size behaviour could not be confirmed, and the two properties below must be enforced by code this repository controls. It issues one GET with `:httpc` (the call style already used at `lib/letflow/engine/service_task_dispatcher.ex:355`) to `"<keycloak_base_url>/realms/<realm>/.well-known/openid-configuration"`, where `keycloak_base_url` is the already configured `config :letflow, :oidc, :keycloak_base_url` (never a caller-supplied host, INV-9) and `<realm>` is the validated realm after percent-encoding of the path segment (URI path-segment encoding; for the allowed alphabet this is the identity, the step exists so a future widening of the alphabet cannot create a path injection). Enforcement: (a) REDIRECTS ARE NOT FOLLOWED: the request is made with `autoredirect: false`; any 3xx, and any status other than 200 or 404, maps to `{:error, :unreachable}` (a redirecting Keycloak base URL is a misconfiguration, not proof that the realm exists); (b) the SIZE CAP covers the STREAMED 200 BODY ONLY, and the design states exactly what OTP does: the request is made asynchronously (`sync: false`, `stream: :self`; the call returns a request id), because OTP streams only 200/206 bodies and only in async mode. On the `stream_start` message the adapter first checks the `content-length` header and, if it exceeds 64 KiB, cancels at once; otherwise it counts chunk bytes and cancels as soon as 64 KiB is exceeded. Cancellation is `:httpc.cancel_request(request_id)` on the default profile (the adapter uses the default profile; a non-default profile would need `cancel_request(request_id, profile)`). A 206 is treated like any non-200. Any non-200 answer (a 3xx, a 404, a 5xx) arrives from OTP as ONE already-buffered message that no option can cap; the adapter decides from the STATUS LINE alone and discards that body unread and undecoded. That residual (OTP buffers an oversized non-200 body in memory before the adapter sees it) is ACCEPTED, because the base URL is operator configuration pointing at the operator's own Keycloak, never a tenant- or caller-supplied host; the cap is a defence against a misbehaving realm document, not against a hostile server; (c) ISOLATION AND DEADLINE (N1): the whole exchange runs inside a short-lived `Task` (its own mailbox), because an async `:httpc` request with `stream: :self` delivers `{:http, ...}` messages to the calling process; the task matches ONLY messages carrying its own request id, enforces the 3 s deadline itself with a `receive ... after` computed once from a start time (remaining time on each receive), sets `connect_timeout` 2 s as well, and always cancels the request on cap, timeout or any decision before it ends, so a late message can only reach a process that is already gone and the caller's mailbox is never touched (a timeout of the task itself is `{:error, :unreachable}`); (d) TLS (N3): for an `https` base URL the ssl options are `verify: :verify_peer`, `cacerts: :public_key.cacerts_get()` and `customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]` (`:httpc` does NOT check the server name by default, so without the match function a certificate for any host would be accepted); the request carries only `accept: application/json` and NO `Accept-Encoding` header, so the capped body is never decompressed; a trailing slash of the configured base URL is stripped ONCE and the stripped value is used both in the request URL and in the expected issuer string of (e); (e) the body must decode as a JSON object whose `issuer` equals the expected issuer string `"<keycloak_base_url>/realms/<realm>"` exactly, else `{:error, :not_found}`. 404 -> `{:error, :not_found}`. `:not_found` -> 422 field error `idp_realm_id` ("realm not found"); `:unreachable` -> 503 through `Response.service_unavailable(conn, detail)` (`lib/letflow/api/response.ex:199`, two arguments, it sets no header itself; the error constructor documents that the caller sets `Retry-After` separately), so the handler puts the `retry-after` response header (`5`) on the conn first, the same pattern the 429 helper documents (OQ-2). The test config installs a deterministic double; the default adapter is tested against a local test HTTP server (`test/support/` has precedents).
6. Uniqueness: the existing partial unique index `tenants_idp_realm_id_partial_index`. A violation (checked by the changeset's `unique_constraint`, mapped in the handler) -> 409 with the fixed message "realm already bound" that names no tenant (F9) (new mapping; today every changeset error is a generic 422, `onboarding.ex:190-191`).

If valid, `idp_realm_id` is added to the attributes of `Identity.create_tenant/1` (already cast, C4). No other changeset changes for create.

### 3.2 Bind-once route (the realm is usually created AFTER the onboarding call)

Because `idp_realm_id` is immutable (C5) a tenant onboarded without a realm would otherwise be unloginable forever. Decision (OQ-1): a new operator route on the onboarding router, `POST /onboarding/:id/bind-realm`, body `{"idp_realm_id": string}`, permission `:TenantsManage` (PLATFORM scope, same gate as the three existing routes, `authz_unmatched(:platform_prefix)` unchanged), registered in `Authorization.endpoint_policy_key/2` next to line 805.
* Same validation as 3.1 items 2-5.
* `Letflow.Identity.bind_tenant_realm(tenant_id :: Ecto.UUID.t(), realm :: String.t(), opts :: [actor_id: Ecto.UUID.t(), platform_prefix: String.t(), trace_id: String.t() | nil]) :: {:ok, Tenant.t()} | {:error, :not_found} | {:error, :realm_already_bound} | {:error, :tenant_not_active} | {:error, :duplicate_realm} | {:error, Ecto.Changeset.t()} | {:error, :audit_failed}`. (Implementation note: the write is made under a row lock, `SELECT ... FOR UPDATE` on the tenant row, then `Repo.update` of the changeset, so the unique index maps to a changeset error; concurrent binders serialise on the lock. Effect is the same as the conditional update below, with the status check `:active` inside the same lock; a non-active tenant without a realm returns `{:error, :tenant_not_active}`.) Intended semantics: ONE atomic conditional update: set `idp_realm_id` WHERE the tenant's `idp_realm_id` IS NULL; zero rows updated -> re-read: the same realm already stored -> `{:ok, tenant}` (idempotent, no second audit entry); a different realm stored -> `{:error, :realm_already_bound}` (409). A changeset `Tenant.realm_bind_changeset/2` (new; casts ONLY `:idp_realm_id`, validates the format of 3.1 item 3, `unique_constraint(:idp_realm_id, name: :tenants_idp_realm_id_partial_index)`) is the ONLY code that casts `idp_realm_id` on an existing row; the moduledoc passage "no code path anywhere" is rewritten to state the bind-once exception. A realm that is already set can never be changed or cleared. Platform prefix (aligned across `create/3`, `revoke/3` and `bind_tenant_realm/3`): none of the three returns a prefix-related error; the HANDLER computes `platform_prefix` and checks it against the caller's tenant prefix BEFORE calling (7a, "One source for the platform prefix"), answering the fixed 500 `internal_error` itself on a mismatch or `:error`, so the context functions only ever receive a verified `platform_prefix` option.
* Audit (two entries, one transaction; section 7a has the shapes and the reasoning): a TENANT-chain entry `tenant.idp_realm.bound` with `actor_id` NIL and `after_state` `{"idp_realm_id": <realm id>, "actor_class": "platform_operator"}`, and a PLATFORM-chain entry `platform.tenant_idp_realm.bound` carrying the operator's user id. The tenant chain is readable by every `:AuditRead` holder of the tenant, so the operator's id is deliberately NOT written there. (The existing `patch_tenant_with_audit`, `identity.ex:1130-1170`, does write the operator's id into a tenant chain for `tenant.platform_setting.updated`; that exposure is pre-existing, is NOT copied here, and is reported as a follow-up in section 12, R7.)
* Tenant status: `bind-realm` is allowed only while the tenant's status is `:active`; a `:migrating` or `:inactive` (deactivated) tenant answers 409 with the fixed message "tenant is not active" (identical bytes for both states, no state named) and nothing is written. Rationale: a realm bound to a deactivated tenant would make that realm's tokens resolvable for a tenant the operator has switched off, and a half-provisioned tenant has no role bindings yet.
* The 409 for a realm that belongs to ANOTHER tenant (unique index) is the fixed message "realm already bound"; it never names or identifies the other tenant, and the answer is byte-identical whether the realm is bound elsewhere or (on `bind-realm`) to this very tenant under a different value (F9).
* Answers: 200 with the onboarding map; 404 for an unknown onboarding id (plain 404, same as `GET /onboarding/:id`).
* The `ProviderRegistry` trust gate re-reads `tenants` on every call (`lib/letflow/oidc/provider_registry.ex` moduledoc), so a bind takes effect for the next token with no cache to invalidate.

### 3.3 "Not yet loginable" marking

`onboarding_map/1` gains ONE key, `login`, built by hand (INV-2 allowlist kept; the "exactly five keys" moduledoc text becomes "six keys"):
* `login.loginable` boolean = the tenant's `idp_realm_id` is non-NULL.
* `login.status` = `"realm_bound"` | `"not_yet_loginable"`.
* `login.idp_realm_id` = string | null.
* `login.next_steps` = list of fixed English strings, empty when loginable; when not: "Create the realm and its first administrator (docs/runbooks/onboarding-new-tenant-realm.md), then bind it with POST /api/v1/onboarding/{id}/bind-realm."

The value comes from a new read `Letflow.Identity.get_onboarding_login_state(tenant_id :: Ecto.UUID.t()) :: {:ok, %{idp_realm_id: String.t() | nil}} | {:error, :not_found}` (one primary-key read of `tenants`; used by the three GET/POST handlers that already build `onboarding_map/1`). The hostname lookup keeps its 403/404 behaviour (C-INV-5 in its moduledoc) because the `login` key is added only to bodies that are already returned to a `:TenantsManage` caller.

### 3.4 No silent drop of administrator (and other) fields

New key in the 201 body (and ONLY the 201 body, not the GET maps): `administrator`, hand-built:
* "Sent" rule (ONE rule, both PRs, all three fields `admin_email`, `admin_username`, `admin_display_name`): a key whose value is JSON null or a string that is empty after trim counts as NOT SENT: it is not validated, not echoed, not listed in `ignored_fields` and does not influence `state`. Any other value (a non-blank string, or a non-string value) counts as sent. A non-string `admin_email` is a 422 field error `admin_email`; a non-string `admin_username` or `admin_display_name` is echoed without `value`. The SPA adapter (3.5) OMITS blank values from the request, so the wizard never sends a blank key; direct API clients may, and get the same result.
* `state` (precisely; PR 1 and PR 2 differ ONLY in the last two rows):

| Sent fields | PR 1 `administrator.state` | PR 2 `administrator.state` |
|---|---|---|
| none of the three | `none` | `none` |
| only `admin_username` and/or `admin_display_name` (no `admin_email`) | `none` | `none` |
| `admin_email` only | `not_provisioned` | `pending` (grant stored), or `not_stored` if the insert failed (OQ-3) |
| `admin_email` plus other admin fields | `not_provisioned` | `pending` / `not_stored` |

  The rule: NO sent `admin_email` means state `none`, because only the e-mail can ever be turned into a grant; any sent `admin_username`/`admin_display_name` are still echoed in `not_provisioned` (never dropped silently) next to the `none` message.
* `message`: fixed string. `none`: "This tenant has no administrator. Nobody can administer it until one is set up: follow docs/runbooks/onboarding-new-tenant-realm.md (create the realm and its first administrator with the TENANT_ADMIN role, then bind the realm)." (When other admin fields were sent the message adds: "The other administrator details you entered were NOT used.") `not_provisioned` (PR 1 only): "The administrator details you entered were NOT used. The platform does not create realm users from the wizard yet; follow docs/runbooks/onboarding-new-tenant-realm.md."
* `not_provisioned`: list of `{"field": <name>, "value": <string>}` for each SENT admin field except an `admin_email` that PR 2 stored as a grant (value echoed only when it is a string of at most 255 characters, otherwise the key `value` is omitted). The response goes to the same PLATFORM operator who sent it, built by hand; it is never logged.
* `next_steps`: list of fixed strings (runbook; bind the realm; the first administrator must carry the realm role `TENANT_ADMIN`).
Plus top-level `ignored_fields`: names (never values) of every other body key, capped and sanitised: at most 20 names (a 21st is dropped and the list carries a final marker string `"..."`), each truncated to 64 characters with control characters (U+0000-U+001F, U+007F) stripped, de-duplicated after stripping, of every other body key that is not one of `slug`, `display_name`, `hostname`, `idp_realm_id` and not `admin_*` (today this lists `client_config`, `realm_config`, `redirect_uris` as the wizard sends them). The same "never collect-and-discard" principle, applied to the other silently dropped fields (an addition to the BA text, flagged in section 0 item 4).
Echoed `administrator.not_provisioned` values are the operator's own input returned to that same operator; they are untrusted text. The SPA renders every response string as TEXT (React text nodes, never `dangerouslySetInnerHTML`); a web test asserts it (section 10.1).
Response `201` also carries the `login` object of 3.3 so the operator sees "not yet loginable" immediately. Existing clients that send only the three required fields get the same status and the previous five keys plus the additive `login`, `administrator` (state `none`) and `ignored_fields` (empty list); no existing key changes.

### 3.5 PR 1 files

| File | Change |
|---|---|
| `lib/letflow/routers/onboarding.ex` | `@create_schema` gains optional `idp_realm_id` (string, max 64); raw-body inspection for the echo; realm validation before `create_tenant`; 409 mapping; new `POST /:id/bind-realm`; `onboarding_map/1` gains `login`; moduledoc (the "NOT ported" section lines 100-110, the "exactly 5 keys" text) rewritten |
| `lib/letflow/platform_tenant.ex` | new accessor `platform_prefix/0` (7a, N6); its tests are the new file `test/letflow/platform_tenant_prefix_test.exs` (10.1) |
| `lib/letflow/identity.ex` | `bind_tenant_realm/3`, `get_onboarding_login_state/1` |
| `lib/letflow/identity/tenant.ex` | `realm_bind_changeset/2`; moduledoc immutability paragraph amended |
| `lib/letflow/oidc/realm_probe.ex` (new) | behaviour + default adapter |
| `lib/letflow/api/authorization.ex` | `endpoint_policy_key("POST", "/onboarding/:id/bind-realm")` -> `:TenantsManage` |
| `config/test.exs` | `:oidc_realm_probe` double |
| `docs/runbooks/onboarding-new-tenant-realm.md` (new) | section 9 |
| `docs/issues/ISS-1030.yaml` (new) | section 11 |
| `web/src/api/onboarding.ts`, `web/src/pages/admin/onboarding/RegisterTenantPage.tsx`, `OnboardingResultPage.tsx` | admin fields optional (validated only when filled; visible note "not provisioned by the platform yet"), optional realm field, display of `administrator`, `login`, `ignored_fields`; thin adapter for the response shape (OQ-10); the request builder OMITS `admin_email`, `admin_username`, `admin_display_name` and `idp_realm_id` when blank after trim (never sends an empty string or null) |
| `test/...` | section 10.1 |

No migration, no new table, no change to authentication or authorization in PR 1.

---

## 4. PR 2 -- tables and migration

### 4.1 Table `pending_tenant_admin_grants` (tenant schema, one per tenant)

| Column | Type | Null | Notes |
|---|---|---|---|
| `id` | binary_id (uuid), PK | no | client generated like the sibling tables |
| `email_key` | text | yes | `TenantMembership.normalize_subject_key/1` output (trim, then lower-case; the ONE shared normaliser the read side also calls, so write and read cannot diverge), ASCII only (F4). Not null ONLY while the grant is `open`; SET TO NULL when the grant is bound (the bound user's `users.email` already holds the address) and when it is revoked (data minimisation, F8) |
| `role_name` | text | no | default `'TENANT_ADMIN'`; CHECK `role_name = 'TENANT_ADMIN'` (Q2: confers nothing else, enforced by the database, not only by code) |
| `created_via` | text | no | default `'onboarding'`; CHECK `created_via = 'onboarding'` (v1: only the onboarding call creates grants; a later source widens the CHECK in its own migration) |
| `inserted_at` | utc_datetime_usec | no | the grant's AGE is computed from it |
| `consumed_at` | utc_datetime_usec | yes | set once, by the binding |
| `consumed_by_user_id` | binary_id | yes | FK to this schema's `users(id)`, `on_delete: :nilify_all` (F8: a hard delete of the bound user, an operational erasure, nulls this column instead of being blocked; no `DELETE /users/:id` route exists today, so this is the data-level erasure path; the audit chain keeps only the user's uuid, which is not personal data once the user row is gone) |
| `revoked_at` | utc_datetime_usec | yes | set by the operator's revoke |

Constraints and indexes (names are the contract; INV-7: the migration interpolates nothing but `prefix()`):
* Unique index `pending_tenant_admin_grants_email_key_idx` on `(email_key)` (unique per tenant; NULLs from revoked rows do not collide).
* CHECK `pending_tenant_admin_grants_state_chk`: not both `consumed_at` and `revoked_at` set; `(consumed_at IS NULL AND revoked_at IS NULL) = (email_key IS NOT NULL)` (only an open row holds the e-mail); `consumed_by_user_id IS NULL` whenever `consumed_at IS NULL` (it may become NULL later through the FK's `nilify_all`); `char_length(email_key) BETWEEN 3 AND 254` when not NULL (the SAME 254-character total that `PendingAdminGrants.normalize_email/1` enforces in 4.3; a value that passes the validator can never fail the CHECK); `email_key = btrim(email_key)` and `email_key !~ '[^\x01-\x7F]'` (ASCII only) when not NULL.
* Partial index `pending_tenant_admin_grants_open_idx` on `(email_key)` WHERE `consumed_at IS NULL AND revoked_at IS NULL` (the login-path lookup; tiny table, still keeps the lookup an index probe).
Row lifecycle: `open` (consumed_at and revoked_at NULL, e-mail present) -> `bound` (consumed, e-mail scrubbed) or `revoked` (e-mail scrubbed); never back. The creator's identity is NOT stored in this table (F1): the table carries only the constant `created_via`; the operator's user id lives in the PLATFORM audit chain, reachable through the grant id (section 7a). Because the unique key is freed by the scrub, a second grant for the same address could be inserted after a bound or revoked one; that is harmless because the only creator of grants is the onboarding handler, which creates a fresh tenant (and one grant) per call (OQ-6).

### 4.2 Migration and rollout to existing tenants

* File `priv/repo/migrations/20261008000001_create_pending_tenant_admin_grants.exs` (the implementer re-checks that no other open PR took that version, OQ-12), module `Letflow.Repo.Migrations.CreatePendingTenantAdminGrants`, body under the mandatory `if prefix()` guard, header comment in the house style (TENANT-SCOPED MIGRATION, both halves mandatory).
* Second half: one new entry in `@tenant_scoped_migration_manifest` (`lib/letflow/tenant_provisioning.ex:489`) with version, module, filename, and the moduledoc counts/lists updated.
* New tenants: `provision_and_migrate/1` -> `replay_migrations/2` creates the table before the onboarding handler inserts the grant.
* Existing tenants: the boot-time `Letflow.TenantProvisioning.MigrationReplayBoot` runs `replay_all_pending/0` at every app start, so the table appears in every registered tenant schema at the next deploy; no manual step, no data backfill (the table starts empty; no existing tenant has a pending administrator). A tenant whose replay fails is reported by the existing boot path; until it succeeds the login-path bind finds no table and, by section 7 step 11 (any failure, including the missing table at the step 5 lookup, is a silent `:noop`), does nothing (fail closed, request unaffected).
* Test infrastructure: `test/support/tenant_template.ex` builds the per-test template from the manifest; the new entry makes the template stale and it rebuilds (ISS-0427/0515 staleness handling). Any test asserting the manifest length or filename set (`test/letflow/migration_filenames_test.exs`) is updated.

### 4.3 Ecto schema and contexts (types only)

* `Letflow.Identity.PendingAdminGrant` (schema for the table above). Fields as in 4.1. `@type state :: :open | :bound | :revoked` derived by a pure function `PendingAdminGrant.state(t()) :: state()`. Changesets: `create_changeset/2` (casts only `email_key` after normalisation; `role_name` and `created_via` are never cast, the column defaults apply) and no update changeset (transitions are conditional updates inside the context, section 7).
* `Letflow.Identity.PendingAdminGrants` (new context module, no OIDC knowledge beyond its inputs):
  * `normalize_email(raw :: term()) :: {:ok, String.t()} | :error` -- binary, trim and lower-case via the shared normaliser, then a shape check: the normalised value is at most 254 characters IN TOTAL (the same bound as the CHECK of 4.1, so the pre-tenant validation of 5.1 step 2 and the table can never disagree; 255 or more -> `:error` -> 422 before any row), exactly one `@`, local part 1..64, domain 3..189 (so the total stays within 254) with a `.` that is neither first nor last, no whitespace or control characters, and ASCII ONLY (F4): any byte above 0x7F -> `:error` -> 422 at creation (an internationalised address must be given in its punycode `xn--` form). The matching rule itself stays trim + lower-case. Never echoes the value.
  * `create(email_key :: String.t(), creator :: %{user_id: Ecto.UUID.t()}, opts :: [prefix: String.t(), platform_prefix: String.t(), trace_id: String.t() | nil]) :: {:ok, PendingAdminGrant.t()} | {:error, :duplicate} | {:error, Ecto.Changeset.t()} | {:error, :audit_failed}` -- inserts the grant, the TENANT-chain entry `tenant.admin_grant.created` and the PLATFORM-chain entry `platform.tenant_admin_grant.created` (the only place the operator's user id is recorded) in one transaction. `create/3` has exactly ONE caller, the onboarding handler (structural test, section 10.2).
  * `list(opts :: [prefix: String.t(), now: DateTime.t()]) :: [%{grant: PendingAdminGrant.t(), state: state(), age_seconds: non_neg_integer() | nil}]` -- `age_seconds` only for open grants, computed from `inserted_at`; ordered oldest first.
  * `revoke(grant_id :: Ecto.UUID.t(), actor :: %{user_id: Ecto.UUID.t()}, opts :: [prefix: String.t(), platform_prefix: String.t(), trace_id: String.t() | nil]) :: :ok | {:error, :not_found} | {:error, :not_open} | {:error, :audit_failed}`.
  * `bind_on_login(tenant :: Tenant.t(), provisioned :: %{user: User.t(), created: boolean()}, identity_context :: IdentityContext.t(), jit_config :: JitProvisioningConfig.t(), opts :: [prefix: String.t()]) :: :bound | :noop` -- the binding (section 7). NEVER raises, NEVER returns an error: every failure is `:noop`.
* `Letflow.Identity.add_group_member/3` (identity.ex:617) is reused for the membership insert; `RoleRegistry.list_roles/1` (role_registry.ex:52) resolves the `TENANT_ADMIN` binding's `group_id` by role name and kind.

### 4.4 Other PR 2 type changes

* `Letflow.Oidc.IdentityContext` gains `email_verified :: boolean()`; NOT in `@enforce_keys`, struct default `false` (so every existing constructor, test double and fixture still compiles and defaults to "not verified").
* `Letflow.Oidc.ClaimMapping.map_verified_claims/3` sets it to true ONLY when the claim `email_verified` resolves to the JSON boolean `true` (strict equality; the string `"true"`, `1`, a missing claim, any other value -> `false`). The claim name is fixed, not configurable (no new knob).
* `Letflow.Oidc.JitProvisioningConfig` gains `accept_unverified_email_for_admin_bind :: boolean()`, default `false` in `default/1` and in every config entry that does not mention it (so the shipped `bpm-default` entries in `config/*.exs` need no edit). Source of truth: a new application key `:oidc_admin_bind_unverified_realms` (a list of realm names), set ONLY by `config/runtime.exs` from the environment variable `LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS` (comma-separated realm names; unset or empty = none; a name outside the realm alphabet of 3.1 item 3 makes boot refuse, naming the variable and never echoing a value). It is read by `for_realm/1`. There is no database column, no API, no tenant setting, no claim and no request field that can set it (structural: nothing in `Tenant.settings_changeset/2`, `admin_patch_changeset/2` or any router touches it; a test asserts it).

---

## 5. PR 2 -- routes, creation, visibility

### 5.1 Creation: ONLY by `POST /onboarding` (Q3)

After `provision_and_migrate/1` and `create_onboarding/1` succeed:
1. No `admin_email` SENT (absent, null or blank after trim, rule of 3.4): no grant. `administrator.state = "none"` with the fixed message of 3.4, and any sent `admin_username`/`admin_display_name` echoed in `not_provisioned`. This is the same state PR 1 reports (3.4 table).
2. `admin_email` sent: `PendingAdminGrants.normalize_email/1` runs BEFORE the tenant is created, together with the other validations (invalid -> 422 field error `admin_email`, no tenant row, message never echoes the value). After provisioning, `PendingAdminGrants.create/3` runs with `prefix` = the new tenant's schema the creator = `%{user_id: auth_context.user_id}` (the operator's user id only; no tenant id is passed) and `platform_prefix` obtained as described in section 7a ("One source for the platform prefix").
3. Outcome in the 201 body: `administrator.state = "pending"`, `administrator.grant_id`, a message ("The named administrator is stored as a pending TENANT_ADMIN. It becomes active when that person first signs in through this tenant's realm with this e-mail address VERIFIED. The tenant must have a bound realm first."), and `next_steps` (create the realm and the first user with that e-mail marked verified, optionally with the TENANT_ADMIN realm role; bind `idp_realm_id` via `POST /onboarding/{id}/bind-realm` when not yet bound; ask the person to sign in). `admin_username` and `admin_display_name` stay in `not_provisioned`. If the grant insert fails after the tenant was provisioned, the response is still 201 with `administrator.state = "not_stored"` and the `none`-style next steps (OQ-3); the failure is logged with a fixed message and the tenant id only.
4. The grant is consumable only when the tenant has an `idp_realm_id` (structural: the login path reaches the tenant only through its realm, C8, and step 3 of section 7 re-asserts it).

### 5.2 Operator list and revoke (Q4)

Both on the onboarding router, `:TenantsManage` (platform scope, INV-10), tenant resolved from the onboarding record (never from a path/query/body tenant identifier), schema from that tenant's `Registration`.
* `GET /onboarding/:id/pending-admins` -> 200 `{"pending_admins": [ {id, email, state, age_seconds, created_at, created_by_user_id, bound_at, bound_user_id, revoked_at} ]}`. `email` is the stored key for OPEN rows and null for bound and revoked ones (scrubbed, F8). `created_by_user_id` is read from the PLATFORM-chain entry `platform.tenant_admin_grant.created` whose `resource_id` is the grant id (ELIXIR-DEV verifies the existing `Audit.list_entries/1` `:resource_id` filter suffices, otherwise a direct query on `Audit.Entry` with the platform prefix). Unknown onboarding id -> plain 404 (same convention as `GET /onboarding/:id`).
* `DELETE /onboarding/:id/pending-admins/:grant_id` -> 204. Unknown grant id or malformed uuid -> 404 (same bytes as an unknown onboarding id); grant not open (bound or already revoked) -> 409 fixed message "grant is not open". Audited with two entries (section 7a): TENANT chain `tenant.admin_grant.revoked` (actor NIL, no operator id), PLATFORM chain `platform.tenant_admin_grant.revoked` (actor = the operator). E-mail scrubbed to NULL in the same transaction. Revoking a BOUND grant is refused; removing the administrator is the existing `DELETE /groups/:id/members/:user_id` (tenant scope).
* Policy keys in `Authorization.endpoint_policy_key/2` for both routes (-> `:TenantsManage`).
* There is NO create/update route for grants anywhere (0046 D4 gives `PLATFORM_ADMIN` no power inside a customer tenant; why a bootstrap grant is consistent with it is argued in section 12, OQ-13). A platform-wide sweep across all tenants is not built (OQ-8).

### 5.3 Tenant-admin visibility: DECISION B (Q5) -- the TENANT_ADMIN reads its own tenant's grants; no write

Decision: B ships in PR 2, together with the table. Reasons:
1. It is the only control that lets the tenant's owner detect a grant it did not expect (a typo'd or hostile e-mail waiting with no TTL). Revocation stays with the operator, so the tenant cannot be locked out by its own admin and the operator's audit trail stays authoritative, but visibility is what makes "no TTL" acceptable.
2. It is cheaper than the operator list, not dearer: the table lives in the tenant schema and `conn.assigns.scoped_opts` already carries the caller's own prefix, so there is no cross-tenant resolution and no tenant identifier in the request (INV-1, INV-6, INV-10 trivially hold).
3. No new permission: `GET /identity/pending-admin-grants` is gated by the existing `:UsersManage` (-> `:UsersGroupsRolesManage`, tenant scope) that `TENANT_ADMIN` already holds (decision 0046 D5); `endpoint_policy_key("GET", "/pending-admin-grants")` is added next to line 731.
4. The deferred alternative (A, operator only) leaves the tenant blind to a pending owner-level grant in its own schema, which is the property a reviewer would flag.
Response (hand-built allowlist, INV-2): `{"pending_admins": [ {id, email, state, age_seconds, created_at, bound_at} ]}`. It deliberately OMITS every creator, revoker and operator id (none is stored in the tenant schema any more, F1) and `bound_user_id`; the creator is shown as the constant `"created_via": "platform_operator_onboarding"`. The `email` is null once a grant is bound or revoked. For an open grant the e-mail is shown in full (the same sensitivity class as `GET /users`, which the same role already reads); it is never logged. Route is GET only; `POST`/`PUT`/`PATCH`/`DELETE` on the path fall to the router's existing unmatched handling.

---

## 6. Where the binding happens

In `Letflow.Plugs.AuthPipeline.authenticate_oidc/2` (auth_pipeline.ex:125-133): one NEW step between `provision_user/3` and `verify_local_account_state/2`, so the bind commits BEFORE the per-request effective-role read and the very request that performs the bind already sees `TENANT_ADMIN`. The step's input is the resolved `tenant` (the DB-sourced struct, never the token), the `provisioned` map, the `identity_context` and `JitProvisioningConfig.for_realm(realm)`; its output is always the unchanged `{:ok, provisioned}` (a bind outcome never changes the HTTP outcome, section 7 step 11). The prefix comes from `TenantProvisioning.schema_name_for_tenant/1` exactly as the neighbouring steps derive it.

The OIDC-only scope is deliberate: API-token requests (`lf_tok_`) never bind anything.

---

## 7. First-login binding algorithm (`PendingAdminGrants.bind_on_login/5`), step by step

Cheap pre-checks, no database access (any failure -> `:noop`, nothing else happens):
1. Trigger gate: `provisioned.created == true` OR `provisioned.user.role_claims_synced_at` is NIL (the user has no synced role claims: a brand-new user, or one whose claims resolved to no grant and is retried every login, C10). A user whose claims already granted something never binds (documented limitation, OQ-5). For ordinary users with roles the step costs zero queries.
2. `provisioned.user.status == :active`.
3. Realm: `identity_context.realm == provisioned.user.external_realm == tenant.idp_realm_id`, with `tenant.idp_realm_id` non-NIL. (The pipeline already guarantees it through `guard_realm_ownership/2`; re-asserted here because this function must be safe on its own.)
3b. Platform chain reachable (letflow-9a condition 1): the platform tenant's schema name must be resolvable from `Letflow.PlatformTenant.configured_id/0` (`lib/letflow/platform_tenant.ex:89`) through `TenantProvisioning.schema_name_for_tenant/1` (pure, no I/O, the same derivation the neighbouring pipeline steps use). When no platform tenant is configured, or the derivation fails, the bind is a silent `:noop` for the caller, logged as a REAL FAULT at `:warning` (throttled, step 11), never at `:debug` (fail closed: the bind never runs without its platform entry). The login path is tenant-resolved, so the platform prefix does NOT come from the caller; it comes from server configuration, never from the token or the request.
4. E-mail basis: `identity_context.email` is a non-blank binary that is ASCII ONLY after trim (F4: a claim containing any non-ASCII character never binds, because Unicode case folding could otherwise map a look-alike character such as U+212A onto an ASCII letter of the key; an internationalised address must arrive as punycode) AND (`identity_context.email_verified == true` OR `jit_config.accept_unverified_email_for_admin_bind == true`). The key is `normalize_subject_key(identity_context.email)`. `preferred_username` and `display_name` are never read.
4b. Stored-address consistency (F3, code defence): the e-mail stored on the user row at JIT time (`users.email`, written from the claim at `identity.ex` `insert_or_fetch_in_tx`, about line 2025, and NOT refreshed afterwards) must, after the same normalisation, EQUAL the key. A user that already exists with a stored `users.email` that differs from the claim e-mail (the address was changed in the realm after first login) never binds (silent `:noop`). For a user created in this very request the two are equal by construction.

Transaction (one `Repo.transaction` over an `Ecto.Multi`, prefix = the tenant schema):
5. Lock-select: the open grant `WHERE email_key = <key> AND consumed_at IS NULL AND revoked_at IS NULL` with `SELECT ... FOR UPDATE`. None -> the transaction ends, `:noop`. Concurrency: two simultaneous logins that both reach this step serialise on the row lock; under READ COMMITTED the second one re-evaluates its WHERE after the first commits, finds the row no longer open and gets `:noop`. Exactly one winner, with no advisory lock and no retry loop. Two DIFFERENT users presenting the same verified e-mail (possible only if the realm allows duplicate e-mails, see 8) resolve the same way: first commit wins.
5b. Duplicate check, fail closed (F5, N4): inside the same transaction the candidate set is every OTHER user of this tenant schema (`users.id` different from this user, whatever its `external_id`) whose stored `users.email` is EITHER equal to the key after SQL `lower(btrim(...))` OR contains any non-ASCII character. Postgres `lower()` depends on the database collation and may not fold characters such as U+212A the way `String.downcase/1` does, so the non-ASCII candidates (a handful at most) are fetched and compared IN ELIXIR: each one's stored address is normalised with `normalize_subject_key/1` and, if it equals the key, counts as a duplicate. Any duplicate abandons the bind: `:noop`, the grant stays open, nothing is written. A tenant in which two accounts share an address therefore never auto-grants an owner role to either. Residual, accepted (fail closed): a pre-registered holder of the address (self-registration in a realm without duplicate-e-mail protection) permanently blocks the legitimate bind; the signal is the grant staying open with a growing AGE (5.2), the remedy is the runbook role path (the realm role `TENANT_ADMIN` on the intended user).
6. Resolve the `TENANT_ADMIN` group: the `group_id` of the binding named `TENANT_ADMIN` of kind `:platform_role` (`RoleRegistry.list_roles/1`). Missing -> rollback, `:noop`, fixed log line (tenant id only).
7. Membership: `Identity.add_group_member(group_id, user.id, prefix: prefix)` (idempotent insert-or-fetch). This is the ONLY membership written: no other group, no other role (the grant row cannot name anything else, 4.1 CHECK).
8. Mark consumed, asserted: `UPDATE pending_tenant_admin_grants SET consumed_at = now, consumed_by_user_id = <user id>, email_key = NULL WHERE id = <grant id> AND consumed_at IS NULL AND revoked_at IS NULL` and the step REQUIRES exactly one updated row, otherwise the whole transaction rolls back (`:noop`) (F6); the e-mail is scrubbed because the bound user's row already holds it (F8). Then, when still NIL, stamp `users.role_claims_synced_at = now` on the user (so the per-request retry of step 1 ends and REQ-378's "roles are database-managed after the first sync" semantics hold; a later admin revocation by group-member removal is permanent, nothing re-applies it; OQ-11). Fixed lock order everywhere a grant is touched: (1) the grant row, (2) the membership insert, (3) the user row, (4) the tenant audit chain lock, (5) the platform audit chain lock, always last (taken by the login-path bind in step 9(b) and by every operator operation, section 7a). `sync_role_claims_from_token/3` runs earlier, in its own transaction, and locks only the user row, so no cycle can form.
9. Audit, last steps, SAME transaction as steps 5-8 (letflow-9a condition 1): TWO entries, written with `Audit.append_multi/4` as the last Multi steps, in this fixed order: (a) the TENANT-chain entry (prefix = the tenant schema), then (b) the PLATFORM-chain entry (prefix = the platform tenant's schema from step 3b). Writer: the same `Audit.append_multi/4` / `Audit.insert_entry/3` (`lib/letflow/audit.ex:182-260`), which takes the prefix as a parameter, resolves the chain's tenant from it and locks that chain's `audit_chain_locks` row inside the caller's transaction; nothing in it depends on who the caller is, so a login-path write into the platform chain is possible. Lock order: grant row, membership, user row, tenant chain, platform chain (the platform chain is last everywhere, so concurrent binds of different tenants and operator actions cannot form a cycle). BOUNDED WAIT (N2): the platform chain lock is the one contended point (every login-path bind and every operator write targets the same `audit_chain_locks` row), so the bind transaction starts with `SET LOCAL lock_timeout = '2s'`; a lock timeout (Postgres error `lock_not_available`) at any step aborts the transaction and is a silent `:noop`: the grant stays open and the next login retries, and a login never queues behind operator writes. The lock_timeout applies to the bind transaction only. The R7 fix (`patch_tenant_with_audit`, Q-1032) and every future operator action that touches a tenant MUST keep the order tenant chain, then platform chain.
   (a) Tenant entry: `action` `tenant.admin_grant.bound`; `resource_type` `pending_admin_grant`; `resource_id` the grant id; `actor_id` the bound user's id (a user of this tenant); `before_state` nil; `after_state` exactly `{"grant_id", "role": "TENANT_ADMIN", "bound_user_id", "created_via": "platform_operator_onboarding", "email_basis": "verified_claim" | "unverified_realm_setting"}`.
   (b) Platform entry: `action` `platform.tenant_admin_grant.bound`; `resource_type` `pending_admin_grant`; `resource_id` the SAME grant id; `actor_id` the bound user's id; `before_state` nil; `after_state` exactly `{"grant_id", "tenant_id", "bound_user_id"}`.
   Neither entry contains an e-mail, a username, a token, a claim, or (tenant entry) any operator id or tenant id of the platform side. Atomicity: a failure of EITHER audit write (changeset error, database error, a missing platform chain, a lock failure) aborts the whole transaction, so the grant stays open, no membership and no marker stamp exist, no entry exists in either chain, and the request continues as a silent `:noop` (step 11). Neither entry can exist without the other, and the state change cannot exist without both.
10. Commit -> `:bound`. The pipeline's next step (`verify_local_account_state`) now reads `TENANT_ADMIN` from the database for this same request.

Failure semantics:
11. ANY failure (no table yet, a changeset error, a database error, a lock timeout, a platform-chain failure, a raise: the whole function body is inside `try/rescue`, INV-8) returns `:noop`; the request continues exactly as if no grant existed: same status, same body, no hint. Logging (N5): the line is always FIXED text plus the tenant id only (never the exception struct, never params, never the e-mail or any claim; INV-4). EXPECTED no-ops (no open grant, a failed pre-check of steps 1-4b, the duplicate check of 5b) log at `:debug`. REAL FAULTS (the step 3b failure, i.e. no platform tenant configured or the platform prefix not derivable, which is a server misconfiguration that disables every bind; a missing `TENANT_ADMIN` binding, a database error, a lock timeout, a platform-chain failure, a missing table) log at `:warning`, rate-limited to once per tenant per hour by a small in-memory throttle keyed by tenant id (a named ETS table created at application start in the infrastructure supervisor; no existing per-tenant throttle was found, the login-discovery limiter is per client address; placement is OQ-16), so a fault is visible to an operator without a per-request flood. The operator's second signal that a bind did not happen is the grant staying `open` with a growing AGE in the list of 5.2. Because the marker stays NIL after a failed bind, the next login retries (self-healing, same as the claim sync).
12. Idempotency: a second login of the bound user (and any later login) finds no open grant -> `:noop`; with the marker stamped in step 8 the step 1 gate is false and costs nothing. A grant is never re-applied after the membership is removed.
13. "Login response identical": nothing in the pipeline's HTTP outputs depends on whether a grant was found. The only observable difference is the GRANTED roles of the person who legitimately binds (their roles are the purpose of the feature). Status codes, bodies and headers for every other caller are byte-identical with and without a pending grant; timing: the lookup in step 5 runs for every caller who passes steps 1-4b whether or not a grant exists, so the only extra latency is on the binding path itself (OQ-4 records this interpretation).

---

## 7a. Audit trail: what is written, where, and who can read it (F1)

The tenant audit chain is readable by every `:AuditRead` holder of the tenant (`lib/letflow/routers/audit.ex:320-333` serialises `actor_id`, `resource_type`, `resource_id`, `before_state`, `after_state`), and the freshly bound `TENANT_ADMIN` holds `:AuditRead`. Nothing written to a TENANT chain may therefore contain a platform operator's identity (the same concern that makes the tenant read of 5.3 hide it). The creator's identity is kept in the PLATFORM tenant's own chain (the schema of the caller's own database-resolved tenant, which `:TenantsManage` platform scope guarantees is the platform tenant), readable only by platform-tenant `:AuditRead` holders, and linked to the tenant side by the grant id (or the tenant id for the realm bind). Entries are written in the same transaction; the lock order is tenant chain, then platform chain.

| Event | TENANT chain entry (action; `actor_id`; `after_state`) | PLATFORM chain entry (action; `actor_id`; `after_state`) |
|---|---|---|
| grant created (onboarding call, PR 2) | `tenant.admin_grant.created`; NIL; `{"grant_id", "role": "TENANT_ADMIN", "created_via": "platform_operator_onboarding"}` | `platform.tenant_admin_grant.created`; the operator's user id; `{"grant_id", "tenant_id", "onboarding_id"}` |
| grant bound (login path, PR 2) | `tenant.admin_grant.bound`; the bound user's id; exactly the shape of 7 step 9(a) | `platform.tenant_admin_grant.bound`; the bound user's id; `{"grant_id", "tenant_id", "bound_user_id"}` (7 step 9(b)); written by the login path from the configured platform prefix, in the SAME transaction |
| grant revoked (operator, PR 2) | `tenant.admin_grant.revoked`; NIL; `{"grant_id", "role": "TENANT_ADMIN", "created_via": "platform_operator_onboarding"}` | `platform.tenant_admin_grant.revoked`; the operator's user id; `{"grant_id", "tenant_id"}` |
| realm bound (PR 1) | `tenant.idp_realm.bound`; NIL; `{"idp_realm_id", "actor_class": "platform_operator"}` | `platform.tenant_idp_realm.bound`; the operator's user id; `{"tenant_id", "idp_realm_id", "onboarding_id"}` |

* No entry, in either chain, ever contains an e-mail address (`before_state` is nil everywhere).
* A tenant `:AuditRead` holder can read: that a grant was created, bound (and by which tenant user) or revoked, and when; never which operator acted.
* The precedent `patch_tenant_with_audit` (`identity.ex:1130-1170`) writes the operator's user id as `actor_id` of `tenant.platform_setting.updated` in the TENANT chain. That is a pre-existing exposure of the same kind. This design does not extend it, does not rely on it as a precedent, and reports it as a follow-up issue (R7). Writing the operator id into a tenant chain is judged NOT acceptable for the new entries.
* Reconciliation with letflow-9a's Q2 requirement ("the bind writes an audit event naming the grant's creator"): the tenant-chain bind entry names the creator as the constant class `platform_operator_onboarding`; the creator's IDENTITY is named in the platform chain and reachable from the bind entry's `grant_id`. This is a deliberate narrowing of the literal wording and is raised as a question to letflow-9a (OQ-15).
* Conditions accepted by letflow-9a (OQ-15 closed): (1) for EVERY event of the table the tenant-chain entry, the platform-chain entry and the state change are ONE database transaction: created (grant insert), bound (membership, consumed mark, marker stamp), revoked (revoke update and scrub), realm bound (the NULL-only update). A failure of the platform write rolls back the state change and the tenant entry; a failure of the tenant write rolls back the state change and the platform entry. For created/revoked/realm-bound the operator-side code already builds one Multi, so the platform entry is one more step after the tenant entry; for the bind the platform entry is step 9(b). (2) Both entries of an event carry the SAME reference: the same `grant_id` as `resource_id` and in `after_state` for the three grant events, and the same `tenant_id` (plus `onboarding_id` on the platform side) for the realm bind, so the operator can answer "who onboarded us" from the platform chain by the grant id found in the tenant chain.
* One source for the platform prefix (N6): every platform-chain write, operator-side or login-side, derives `platform_prefix` from ONE new accessor `Letflow.PlatformTenant.platform_prefix() :: {:ok, String.t()} | :error` (built on `configured_id/0` and `TenantProvisioning.schema_name_for_tenant/1`; `:error` when no platform tenant is configured). The login-path bind uses it directly (7 step 3b). Every OPERATOR-side function (`PendingAdminGrants.create/3`, `PendingAdminGrants.revoke/3`, `Identity.bind_tenant_realm/3`) is called by a handler that first computes `platform_prefix` this way AND asserts that it equals the schema of the caller's database-resolved tenant (`auth_context.tenant_id` through `schema_name_for_tenant/1`); a mismatch or `:error` answers the fixed 500 `internal_error` response, writes nothing, and is logged as a real fault (fixed text, no ids of the caller). Under `:TenantsManage` platform scope the two are equal by construction; the assertion makes a misconfiguration fail closed instead of writing operator ids into another tenant's chain.
* Readability of the platform-chain entries (N7): they carry a customer `tenant_id` and `bound_user_id` (uuids only, never an e-mail) and are readable by every `:AuditRead` holder of the PLATFORM tenant (`PLATFORM_ADMIN` and platform-tenant `TENANT_ADMIN`, who are the operator organisation). ACCEPTED: uuids only, platform-tenant principals only. They are never readable by any other tenant: `GET /audit` reads the caller's own schema only, so an admin of a customer tenant cannot reach them (test in 10.2).
* One pattern for every operator action that touches a tenant: when the existing `patch_tenant_with_audit` exposure (R7; filed by letflow-2, owner letflow-4) is fixed, it uses this SAME split: the tenant chain gets an entry with a NIL actor and an actor class, the platform chain gets the entry carrying the operator's user id, both in the one transaction, with the same resource reference.

---


## 8. Security analysis

Invariants (SECURITY-REVIEWER scope; each assessed):

| INV | Assessment |
|---|---|
| INV-1 tenant isolation | The grant table is in the tenant schema; the bind and the caller-facing read use a prefix derived from the DB-resolved tenant / `scoped_opts`, never from request input. The operator routes derive the prefix from the onboarding record's tenant. Negative test: a user of tenant B with the pending e-mail of tenant A does not bind (their realm resolves tenant B). |
| INV-2 response allowlists | Every new body is hand-built (3.4, 5.2, 5.3). The tenant view carries no operator id and no creator id; the tenant audit chain, which tenant `:AuditRead` holders can read, carries none either (section 7a). `ignored_fields` is capped and sanitised (3.4). |
| INV-3 | Not applicable (no sandbox). |
| INV-4 secrets / PII in logs | No secret exists. The e-mail is never logged: not in a Logger call, not in an error message, not in any audit entry of either chain, not in a validation message. Bind no-ops and faults log fixed text and the tenant id only: `:debug` for expected no-ops, `:warning` (throttled) for real faults (7 step 11). A `capture_log` test covers create, bind success, bind failure, revoke. |
| INV-5 indistinguishability | Unknown grant id and unknown onboarding id answer the same 404 bytes; a non-operator gets the router's uniform 403 for matched and unmatched paths (unchanged `authz_unmatched(:platform_prefix)`); a failed bind is invisible to the caller (7.11). |
| INV-6 new data-access paths | Section 5.2/5.3/6 each state the prefix source; the one query that runs on the hot auth path is a single indexed probe on a tiny table, gated so ordinary users pay nothing. |
| INV-7 SQL | Ecto queries only; the migration interpolates nothing except `prefix()`. |
| INV-8 crashes | `bind_on_login/5` cannot raise; a missing table is `:noop`; the realm probe maps timeouts and transport errors to `:unreachable`. |
| INV-9 outbound URL | The realm probe URL is the configured Keycloak base URL plus a realm string validated against `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$` and percent-encoded as a path segment; no host comes from a request or a tenant setting; redirects are not followed and the streamed 200 body is capped at 64 KiB and every other body is discarded unread (3.1 item 5). |
| INV-10 platform authority | Grant creation, listing and revocation and the realm bind are platform-scope (`:TenantsManage`, recomputed platform scope, unchanged gate). The tenant read is tenant scope with no tenant identifier in the request. No role other than the onboarding call creates a grant. The grant confers only `TENANT_ADMIN`, never `PLATFORM_ADMIN` (CHECK constraint plus the existing REQ-447 escalation guards unchanged). |

Account takeover by e-mail spoofing:
* Threat: someone obtains a token in the tenant's realm carrying the pending e-mail and becomes tenant owner. Preconditions the design enforces: the token must be signed by the tenant's own realm (C8), carry `email_verified == true` (strict JSON boolean) and the e-mail must equal the stored key after trim + lower-case. An unverified claim, a different address, `preferred_username` equal to the address, `+tag` or dotted variants, never bind (tests, section 10.2).
* Residual risks, all configuration of the realm, each in the runbook checklist (section 9): (a) realm self-registration without e-mail verification: harmless with the default OFF setting (the claim is unverified); (b) the per-realm setting ON for a realm with self-registration lets anyone who registers with that address take the grant, so it is allowed only for a realm whose users are created by an administrator (documented as an operator decision, default OFF, no API); (c) "Duplicate emails" ON in the realm lets a second user present the same verified address (first commit wins, 7.5): the runbook requires it OFF; (d) a brokered identity provider in the realm with "Trust Email" ON would mark foreign e-mails verified: decision 0044 defers brokering, the runbook forbids it for tenant realms; (e) a realm administrator can mark any e-mail verified: realm administrators are infra and already trusted to issue `TENANT_ADMIN` itself; (f) a typo that names a stranger who holds an account in that realm: bounded by closed registration, by the operator list with AGE and by the tenant's own read route (5.3), with revoke available. No TTL (Q4) is therefore compensated by visibility, not by expiry.
Additional code defences (security review F3-F5): (a) the claim e-mail must be ASCII, so Unicode case folding cannot map a look-alike character onto the key (7 step 4); (b) a user whose stored `users.email` (written once at JIT) differs from the claim e-mail never binds, so changing the address in the realm after the first login cannot redirect a grant (7 step 4b); (c) a tenant where any other account holds the same stored address never binds (7 step 5b); (d) the grant row is consumed by a conditional update that must change exactly one row (7 step 8).
E-mail enumeration: there is no public or login-path endpoint that reveals whether an address is pending (7.13). The only reads are operator-scoped (5.2) and tenant-admin-scoped (5.3). Creation reveals nothing to a non-operator.
PII at rest: the e-mail key is stored in the tenant schema while the grant is open or bound (the bound user's row holds the same address) and is scrubbed to NULL on revoke. Access: platform operator (their own input), the tenant's own `TENANT_ADMIN`. Never exported to the audit chain or to logs.
Cross-tenant ids: no operator id is written into a customer tenant's schema by this feature (grant row: none; audit chain: none; section 7a). The operator's id lives only in the platform tenant's own chain.

---

## 9. The runbook and the infra line

`docs/runbooks/onboarding-new-tenant-realm.md` (PR 1; PR 2 amends it for the pending path). Contents, in the house style of C16 (owner / evidence / date checklist tables, names only, no secrets, no value ever pasted):
1. When to use it: a tenant created through the wizard or `POST /api/v1/onboarding` is "not yet loginable" until a realm is bound.
2. References: infra T-0150 (the realm and persona-account recipe) and T-0158; decisions 0044 (realm-per-tenant, Phase 1) and 0046 D4/D5; `lib/letflow/design/req447-infra-realm-mapping.md` sections 1 and 3b.
3. Ordered steps: (R1) create the realm by CLONING the `bpm-default` realm definition (`priv/keycloak/realms/bpm-default.json` shape: the `letflow-web` client with its audience mapper and the `realm-roles` mapper), INCLUDING the realm role `TENANT_ADMIN`; (R2) create the first administrator user: e-mail set, e-mail MARKED VERIFIED, and, until PR 2 is deployed, the realm role `TENANT_ADMIN` mapped to that user (after PR 2 and a pending grant for that exact e-mail the role mapping is optional); (R3) bind the realm: `POST /api/v1/onboarding/{id}/bind-realm` or give `idp_realm_id` at onboarding time (the realm must exist; it cannot be changed afterwards); (R4) the administrator signs in once; verify `GET /api/v1/me` shows `TENANT_ADMIN` (roles by name only); (R5) PR 2: operator checks `GET /api/v1/onboarding/{id}/pending-admins` shows the grant as bound.
4. Realm checklist (a table with the columns Item / Owner / Evidence / Date, one row per item; evidence is a reference, never a value): `TENANT_ADMIN` exists as a plain realm role and is NOT in `default-roles-<realm>`, any default group, any client-scope role mapping or any composite; "Duplicate emails" OFF; self-registration OFF (or the unverified-binding setting stays OFF); no brokered identity provider with "Trust Email"; the first user's e-mail verified; "Verify email" ON in the realm; users CANNOT edit their own e-mail, or `email_verified` is reset whenever the e-mail changes (the realm's profile and "Update email" settings reviewed); the `email` and `email_verified` mappers are present in the `letflow-web` client scope (without `email_verified` in the token no grant can ever bind); the realm never issues `PLATFORM_ADMIN`; and the row "realm ownership confirmed by" (the named person at the operator who confirmed that this realm belongs to this customer's tenant before it was bound, with the date). Binding a realm to a tenant whose status is not active is refused (409). Known residual to record in the runbook: a user who registered with the intended administrator's address BEFORE the intended person (self-registration without duplicate-e-mail protection) permanently blocks the automatic bind (fail closed, 7 step 5b); the signal is the pending grant staying open with a growing AGE, the remedy is to map the realm role `TENANT_ADMIN` to the intended user.
5. The ONE infra line for `ai-dala-infra` (to be copied into its onboarding checklist by ORCH as a task; this repository does not edit the infra repo): "Every new tenant realm: clone from bpm-default including the TENANT_ADMIN realm role; create the first user with a VERIFIED e-mail and the TENANT_ADMIN role; never map TENANT_ADMIN to default roles or groups; Duplicate emails OFF."
6. PR 2 addition: the optional operator setting `LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS` (what it does, why default OFF, that it must stay empty for realms with self-registration).
7. UAT note (not a build item): QA's binding test needs the seeded QA users' e-mails marked `email_verified=true` in the QA realms (an infra task, approved later, when the binding is deployed).

---

## 10. Tests (exact names; real Postgres for router, migration, binding and pipeline tests)

Naming limit: ExUnit turns `test "..."` into an atom named `test <describe> <name>`, and an atom is limited to 255 characters; the longest planned name here is 211 characters, so test files use FLAT tests (no `describe` block) or a `describe` title of at most 38 characters; an implementer who needs a longer title shortens the NAME, not the mapping (the mapping in section 11 is by name and is then updated in the same PR).

### 10.1 PR 1

`test/letflow/routers/onboarding_administrator_fields_test.exs`
* "POST /onboarding with no admin fields returns 201 and administrator.state none with the next-step message"
* "POST /onboarding with admin_email, admin_username and admin_display_name returns 201, echoes each as not_provisioned and stores nothing"
* "POST /onboarding treats a blank-string admin field as not sent: state none and no echo"
* "POST /onboarding treats a null admin field as not sent: state none and no echo"
* "POST /onboarding treats a whitespace-only admin field as not sent: state none and no echo"
* "POST /onboarding with only admin_username and admin_display_name returns state none, the no-administrator message and both fields echoed as not_provisioned"
* "POST /onboarding with a non-string admin_email answers 422 and creates no tenant row"
* "POST /onboarding does not echo a non-string admin value and omits oversize values"
* "POST /onboarding lists client_config, realm_config and redirect_uris in ignored_fields by name only"
* "ignored_fields is capped at 20 names, truncates each to 64 characters and strips control characters"
* "POST /onboarding without any extra field is unchanged: status 201 and the five original keys are present"
* "POST /onboarding with a valid idp_realm_id binds it and the record says loginable true"
* "POST /onboarding with an unknown idp_realm_id answers 422 and creates no tenant row"
* "POST /onboarding with a blank, malformed or master idp_realm_id answers 422 and creates no tenant row"
* "idp_realm_id validation refuses '.', '..', 'Master' (any case of master), an over-long value (65 characters) and a leading dash or underscore, and stores ' x ' as 'x' after trimming"
* "a realm name is percent-encoded as a path segment in the probe URL"
* "POST /onboarding with an idp_realm_id already bound to another tenant answers 409 and creates no tenant row"
* "POST /onboarding answers 503 with a retry-after header of 5 and creates no tenant row when the realm probe is unreachable"
* "GET /onboarding/:id and GET /onboarding?hostname= mark a tenant without a realm as not_yet_loginable with next steps"
* "POST /onboarding/:id/bind-realm binds the realm once, answers 200 and writes a tenant.idp_realm.bound audit entry"
* "POST /onboarding/:id/bind-realm with the same realm again answers 200 and writes no second audit entry"
* "POST /onboarding/:id/bind-realm with a different realm after binding answers 409 and leaves the tenant unchanged"
* "POST /onboarding/:id/bind-realm with an unknown realm answers 422 and leaves the tenant unchanged"
* "POST /onboarding/:id/bind-realm for a nonexistent onboarding id answers 404"
* "POST /onboarding/:id/bind-realm on a deactivated or migrating tenant answers 409 tenant is not active with identical bytes and writes nothing"
* "POST /onboarding/:id/bind-realm 409 for a realm bound to another tenant names no tenant"
* "bind-realm writes a tenant-chain entry with a NIL actor and a platform-chain entry with the operator id"
* "POST /onboarding/:id/bind-realm answers the fixed 500 and writes nothing when the platform prefix differs from the caller's tenant prefix"
* "POST /onboarding/:id/bind-realm answers the fixed 500 and writes nothing when no platform tenant is configured"
* "POST /onboarding/:id/bind-realm by an admin of another tenant answers the uniform 403, byte-identical for a matched and an unmatched path"
* "after bind-realm a token from that realm resolves the tenant and a tenant without a realm cannot be resolved"
* The existing `test/letflow/routers/onboarding_test.exs` and `onboarding_scope_extension_test.exs` run UNCHANGED (AC "no change for existing onboarding tests").

`test/letflow/platform_tenant_prefix_test.exs` (new, PR 1)
* "platform_prefix returns the schema name of the configured platform tenant"
* "platform_prefix returns error when no platform tenant is configured"
* "platform_prefix returns error when the configured value is not a valid tenant id" (the derivation is pure and never reads the registration table)

`test/letflow/identity/tenant_realm_bind_test.exs`
* "bind_tenant_realm sets idp_realm_id only while it is NULL"
* "two concurrent bind_tenant_realm calls with different realms: exactly one wins and the loser gets realm_already_bound"
* "realm_bind_changeset casts nothing but idp_realm_id and rejects a malformed value"
* "no other changeset casts idp_realm_id on an existing tenant" (structural)
* "realm bound: a forced failure of the platform write leaves idp_realm_id NULL and no tenant entry" (PR 1; in this file, not in the PR 2 binding test file)

`test/letflow/oidc/realm_probe_test.exs`
* "accepts a realm whose discovery issuer equals the expected issuer"
* "does not follow a redirect: a 3xx answer is unreachable and the Location target is never requested"
* "refuses a 200 response whose content-length exceeds 64 KiB, cancelling before reading the body"
* "no stray http message remains in the caller mailbox after a cancel or a timeout"
* "rejects a server certificate whose host name does not match the base URL host"
* "sends no Accept-Encoding header"
* "strips a trailing slash of the base URL in both the request URL and the expected issuer"
* "refuses a chunked 200 response that grows past 64 KiB, cancelling the request without decoding"
* "maps a 404, a 500 and a 206 to not_found, unreachable and unreachable and never decodes their bodies"
* "refuses a 200 response that is not a JSON object"
* "rejects a discovery document whose issuer differs"
* "maps a 404 to not_found and a timeout or transport error to unreachable"
* "refuses a realm name outside the allowed alphabet before any request is made"
* "builds the URL only from the configured Keycloak base URL and the validated realm"

Web (`web/src/pages/admin/onboarding/__tests__/RegisterTenantPage.iss1030.test.tsx`)
* "admin fields are optional and the form submits without them"
* "a filled admin_email must be a valid address"
* "the optional realm field is sent when filled"
* "blank admin and realm fields are omitted from the request body"
* "administrator values and ignored field names are rendered as text, never as HTML"
* "the result view lists not-provisioned fields, ignored fields and the not yet loginable next steps"

### 10.2 PR 2

`test/letflow/migrations/create_pending_tenant_admin_grants_test.exs`
* "the migration is in the tenant-scoped manifest and is guarded by prefix()"
* "replay_migrations creates the table in an existing tenant schema and a second replay is a no-op"
* "role_name other than TENANT_ADMIN is rejected by the CHECK constraint"
* "email_key is unique per tenant schema and the same address is allowed in two tenants"
* "email_key CHECK: an open row has a non-null email_key, a bound row and a revoked row have NULL, and a row with both consumed_at and revoked_at set is rejected"

`test/letflow/identity/pending_admin_grants_test.exs`
* "normalize_email trims and lower-cases only: plus tags and dots are preserved"
* "normalize_email refuses non-ASCII addresses at creation (an internationalised address must be punycode)"
* "normalize_email rejects blank, no @, two @, whitespace and over-long values without echoing them"
* "normalize_email boundary: a 254-character address is accepted and a 255-character address is refused"
* "create stores the grant, writes the tenant.admin_grant.created entry without any operator id and the platform.tenant_admin_grant.created entry with the operator id, in one transaction"
* "create has exactly one caller: the onboarding handler" (structural: a source scan of lib/ finds PendingAdminGrants.create only in Letflow.Routers.Onboarding)
* "an operator-side platform write refuses with 500 and writes nothing when the configured platform prefix differs from the caller's tenant prefix or no platform tenant is configured"
* "no audit row in the tenant chain or the platform chain contains the e-mail, after create, bind, failed bind and revoke"
* "no tenant-chain row contains the operator's user id or the platform tenant id, for created, bound, revoked and realm-bound entries"
* "the platform chain entry for a grant names the creating operator and is found by the grant id"
* "create returns duplicate for the same normalised address"
* "list reports age_seconds for open grants and none for bound and revoked ones, oldest first"
* "revoke audits, scrubs the e-mail and refuses a bound or already revoked grant"

`test/letflow/identity/pending_admin_binding_test.exs`
* "binds when a verified e-mail equals the pending key through the tenant's own realm"
* "the bound user holds TENANT_ADMIN and no other group membership"
* "an unverified e-mail does not bind"
* "an email_verified claim of the string true does not bind"
* "a missing email_verified claim does not bind"
* "a different e-mail does not bind"
* "preferred_username equal to the pending e-mail does not bind"
* "preferred_username equal to the pending e-mail does not bind even when the e-mail claim is empty"
* "matching ignores case and surrounding whitespace of the claim but not plus tags or dots"
* "a second login does not re-bind"
* "removing the TENANT_ADMIN membership after binding is permanent: a later login does not re-apply the grant"
* "two concurrent first logins of the same user bind exactly once: one membership, one consumed row, one audit entry"
* "two users presenting the same verified e-mail: exactly one binds"
* "a token from another tenant's realm with the pending e-mail does not bind"
* "a tenant without idp_realm_id cannot bind"
* "an inactive user does not bind"
* "a revoked grant does not bind"
* "a bind with a missing TENANT_ADMIN binding does nothing and leaves the grant open"
* "a failure injected at the tenant audit step rolls back the membership, the consumed mark, the marker stamp and writes no platform entry"
* "bind: tenant-chain and platform-chain entries exist in the same transaction (forced failure of the platform write leaves no membership, no consumed grant, no tenant entry)"
* "tenant-chain and platform-chain entries carry the same grant_id" (for created, bound and revoked; for realm-bound the same tenant_id)
* "a bind with no configured platform tenant is a silent no-op and the grant stays open"
* "a bind with no configured platform tenant logs the fixed warning for that tenant at most once per hour"
* "created: a forced failure of the platform write leaves no grant row and no tenant entry"
* "revoked: a forced failure of the platform write leaves the grant open, the e-mail present and no tenant entry"
* "the platform bind entry contains only grant_id, tenant_id and bound_user_id and no e-mail"
* "a missing grants table is a silent no-op"
* "the bind audit entry carries the created_via class and the bound user and no operator id"
* "a claim e-mail containing a non-ASCII character that case-folds onto the key (U+212A) does not bind"
* "a user whose stored users.email differs from the claim e-mail does not bind"
* "a user created in this request whose stored e-mail equals the claim e-mail binds"
* "a tenant where another user holds the same stored e-mail does not bind and the grant stays open"
* "the consumed update must change exactly one row: a grant revoked between select and update rolls the bind back"
* "binding scrubs email_key to NULL and a revoke scrubs it too"
* "hard-deleting the bound user nulls consumed_by_user_id and does not fail"
* "an expected no-op bind logs only fixed text and the tenant id at debug level"
* "a real fault in the bind (missing TENANT_ADMIN binding, database error, platform chain failure, missing table) logs fixed text and the tenant id at warning, at most once per tenant per hour, and never the e-mail"
* "a bind waiting on the platform chain lock past the lock timeout is a silent no-op and the grant stays open"
* "a tenant where another user holds a non-ASCII stored e-mail that case-folds onto the key does not bind"
* "a user who already has synced role claims is not offered the bind"

`test/letflow/oidc/jit_provisioning_config_admin_bind_test.exs`
* "accept_unverified_email_for_admin_bind defaults to false"
* "a configured realm entry without the key keeps it false"
* "the setting is true only for realms named in the operator environment list"
* "with the setting on, an unverified e-mail equal to the key binds and the audit entry says unverified_realm_setting"
* "with the setting on, preferred_username still never binds"
* "no tenant setting, claim or request field can set the flag" (structural)
* "boot refuses a malformed realm name in the environment list without echoing it"

`test/letflow/oidc/claim_mapping_email_verified_test.exs`
* "email_verified is true only for the JSON boolean true"
* "an IdentityContext built without the field defaults email_verified to false"

`test/letflow/plugs/pending_admin_login_response_test.exs`
* "a non-matching user's response is byte-identical in a tenant with a pending grant and in a tenant without one"
* "an unverified user whose e-mail equals the pending key gets a response byte-identical to the no-grant case"
* "no log line contains the pending e-mail or the claim e-mail on a successful bind, a failed bind or a revoke"
* "the binding request itself already sees TENANT_ADMIN in the auth context"

`test/letflow/routers/onboarding_pending_admin_test.exs`
* "POST /onboarding without admin_email (absent, null or blank) answers 201 with administrator.state none and the plain no-administrator message"
* "POST /onboarding with admin_email stores a normalised pending grant and answers state pending with next steps"
* "POST /onboarding with an invalid admin_email answers 422 and creates no tenant row"
* "POST /onboarding with a 254-character admin_email stores the grant and with a 255-character admin_email answers 422 before any tenant row exists"
* "POST /onboarding with only admin_username and admin_display_name still answers state none and stores no grant"
* "POST /onboarding with admin_email plus admin_username returns state pending and echoes only admin_username as not_provisioned"
* "POST /onboarding still echoes admin_username and admin_display_name as not_provisioned"
* "POST /onboarding existing clients that send no admin fields behave as in PR 1"
* "POST /onboarding answers 201 with state not_stored when the grant insert fails"
* "GET /onboarding/:id/pending-admins shows each grant's age_seconds and the creator read from the platform chain"
* "DELETE /onboarding/:id/pending-admins/:grant_id revokes with an audit entry and a matching login then does not bind"
* "DELETE of an unknown grant id answers the same 404 bytes as an unknown onboarding id"
* "DELETE of a bound grant answers 409"
* "an admin of another tenant gets the uniform 403 on both new routes, byte-identical for a matched and an unmatched path"

`test/letflow/routers/audit_platform_entries_isolation_test.exs` (N7, new, PR 2)
* "GET /audit as an admin of a non-platform tenant never returns platform-chain entries of any tenant"

`test/letflow/routers/identity_pending_admin_grants_test.exs` (Q5 B)
* "a TENANT_ADMIN reads its own tenant's pending grants"
* "a caller without :UsersManage gets 403"
* "the tenant view omits creator, revoker and bound-user ids"
* "the route accepts no write verb"
* "a TENANT_ADMIN never sees another tenant's grants"

Existing tests updated: any test asserting the manifest length or the tenant-schema table list; the routing-policy completeness test picks up the `endpoint_policy_key` entries: PR 1 adds one (`POST /onboarding/:id/bind-realm`), PR 2 adds three (operator list, operator revoke, tenant read), four across both PRs.

---

## 11. Acceptance criteria mapping and the issue file

`docs/issues/ISS-1030.yaml` (created in PR 1, completed in PR 2). Fields in the house format (see `docs/issues/ISS-1026.yaml`): `id: ISS-1030`; `title` (the GH #2312 title); `discovered_by` letflow-4 CODE-DESIGNER (REQ-447 design, BUILDS item 8); `severity: MAJOR`; `failure_class: defect`; `owner: ELIXIR-DEV` (backend) with FRONTEND-DEV for the web part; `description` (the GH body, then the BA amendment); `acceptance_criteria`: ACs 1-5 of the issue body AND ACs 6-8 copied VERBATIM from the BA amendment comment (https://github.com/tvolodi/letflow/issues/2312#issuecomment-6031770847; the BA does not edit local issue files); `affected_files` (sections 3.5 and 11.1); `queue_ref: Q-1012`; `github_ref: GH-2312`; `status: open` in PR 1, `resolved` in PR 2 with `resolved_in_run`, `resolution`, `regression_test`; a header comment on the numbering clash in the same wording style as ISS-1026's: "The queue's own issue_ref for Q-1012 came back ISS-1012, which clashes with the local numbering (docs/issues/ISS-1012.yaml is a different, resolved issue: Q-994). ISS-1030 is the local id; it is the id REQ-447's design already cites." `follow_ups`: the wizard-driven realm and user creation (BA item 4, awaiting the owner's decision, NOT built), tenant-admin revoke, re-creation of a grant, the platform-wide pending sweep.

| AC | Delivered by | Design element | Test |
|---|---|---|---|
| 1 no silent drop | PR 1 | 3.4 `administrator`, `ignored_fields` | 10.1 first block |
| 2 realm bind with validation; "not yet loginable" | PR 1 | 3.1, 3.2, 3.3 | 10.1 realm tests |
| 3 runbook referencing T-0150/T-0158 | PR 1 | 9 | reviewed by DOC-UPDATER / CODE-DESIGN-VALIDATOR; the file's existence and links are checked by the repository's doc-link check if present |
| 4 tests for admin fields, valid/unknown realm, unchanged existing tests | PR 1 | 10.1 | listed |
| 5 follow-up requirement for item 4 NOT built here | both | 11 `follow_ups`; no Keycloak admin client anywhere | none (absence) |
| 6 pending grant: new tenant table, TENANT_ADMIN only, e-mail trim+lower-case, creation only by the onboarding call, `admin_email` optional with the plain "no administrator" message | PR 2 | 4.1, 4.3, 5.1 | 10.2 migration, grants, onboarding_pending_admin tests |
| 7 binding: verified claim only, never `preferred_username`, own realm, once, audited with the creator; unverified setting operator-only default OFF; response identical; no TTL; operator list with AGE | PR 2 | 4.4, 6, 7, 5.2 | 10.2 binding, config, login_response, onboarding_pending_admin tests |
| 8 visibility (decision B recorded in 5.3), two PRs, the mandatory test list | PR 2 / this design | 5.3, 0 | the AC8 list maps, by EXACT test name, as: unverified e-mail does not bind -> "an unverified e-mail does not bind"; `preferred_username` equal to the e-mail does not bind -> "preferred_username equal to the pending e-mail does not bind" and "preferred_username equal to the pending e-mail does not bind even when the e-mail claim is empty"; second login does not re-bind -> "a second login does not re-bind"; response byte-identical with and without a grant -> "a non-matching user's response is byte-identical in a tenant with a pending grant and in a tenant without one" and "an unverified user whose e-mail equals the pending key gets a response byte-identical to the no-grant case"; per-realm setting default OFF -> "accept_unverified_email_for_admin_bind defaults to false"; `admin_email` absent message -> "POST /onboarding without admin_email (absent, null or blank) answers 201 with administrator.state none and the plain no-administrator message"; audit row carries the creator -> "the bind audit entry carries the created_via class and the bound user and no operator id" (tenant chain: the creator CLASS) and "the platform chain entry for a grant names the creating operator and is found by the grant id" (platform chain: the creator identity) and "GET /onboarding/:id/pending-admins shows each grant's age_seconds and the creator read from the platform chain"; visibility decision B -> the five tests of `identity_pending_admin_grants_test.exs` |

Security-review additions and their tests (each test is named once here and mapped exactly; all under AC 6/7, PR 2 unless marked PR 1). F1 audit reconciliation -> "no tenant-chain row contains the operator's user id or the platform tenant id, for created, bound, revoked and realm-bound entries", "no audit row in the tenant chain or the platform chain contains the e-mail, after create, bind, failed bind and revoke", "create stores the grant, writes the tenant.admin_grant.created entry without any operator id and the platform.tenant_admin_grant.created entry with the operator id, in one transaction", "bind-realm writes a tenant-chain entry with a NIL actor and a platform-chain entry with the operator id" (PR 1). F2 realm validation and probe hardening (PR 1) -> "idp_realm_id validation refuses '.', '..', 'Master' (any case of master), an over-long value (65 characters) and a leading dash or underscore, and stores ' x ' as 'x' after trimming", "a realm name is percent-encoded as a path segment in the probe URL", "does not follow a redirect: a 3xx answer is unreachable and the Location target is never requested", "refuses a 200 response whose content-length exceeds 64 KiB, cancelling before reading the body", "refuses a chunked 200 response that grows past 64 KiB, cancelling the request without decoding", "maps a 404, a 500 and a 206 to not_found, unreachable and unreachable and never decodes their bodies". F3 -> "a user whose stored users.email differs from the claim e-mail does not bind", "a user created in this request whose stored e-mail equals the claim e-mail binds". F4 -> "normalize_email refuses non-ASCII addresses at creation (an internationalised address must be punycode)", "a claim e-mail containing a non-ASCII character that case-folds onto the key (U+212A) does not bind". F5 -> "a tenant where another user holds the same stored e-mail does not bind and the grant stays open". F6 -> "the consumed update must change exactly one row: a grant revoked between select and update rolls the bind back". F7 and N5 -> "an expected no-op bind logs only fixed text and the tenant id at debug level", "a real fault in the bind (missing TENANT_ADMIN binding, database error, platform chain failure, missing table) logs fixed text and the tenant id at warning, at most once per tenant per hour, and never the e-mail". N1/N3 (PR 1) -> "no stray http message remains in the caller mailbox after a cancel or a timeout", "rejects a server certificate whose host name does not match the base URL host", "sends no Accept-Encoding header", "strips a trailing slash of the base URL in both the request URL and the expected issuer". N2 -> "a bind waiting on the platform chain lock past the lock timeout is a silent no-op and the grant stays open". N4 -> "a tenant where another user holds a non-ASCII stored e-mail that case-folds onto the key does not bind". N6 (PR 2, create and revoke) -> "an operator-side platform write refuses with 500 and writes nothing when the configured platform prefix differs from the caller's tenant prefix or no platform tenant is configured". N6 (PR 1, bind-realm and the accessor) -> "POST /onboarding/:id/bind-realm answers the fixed 500 and writes nothing when the platform prefix differs from the caller's tenant prefix", "POST /onboarding/:id/bind-realm answers the fixed 500 and writes nothing when no platform tenant is configured", "platform_prefix returns the schema name of the configured platform tenant", "platform_prefix returns error when no platform tenant is configured", "platform_prefix returns error when the configured value is not a valid tenant id". Step 3b logging -> "a bind with no configured platform tenant logs the fixed warning for that tenant at most once per hour". N7 -> "GET /audit as an admin of a non-platform tenant never returns platform-chain entries of any tenant". F8 -> "binding scrubs email_key to NULL and a revoke scrubs it too", "hard-deleting the bound user nulls consumed_by_user_id and does not fail", "email_key CHECK: an open row has a non-null email_key, a bound row and a revoked row have NULL, and a row with both consumed_at and revoked_at set is rejected". F9 (PR 1) -> "ignored_fields is capped at 20 names, truncates each to 64 characters and strips control characters", "POST /onboarding/:id/bind-realm 409 for a realm bound to another tenant names no tenant", "administrator values and ignored field names are rendered as text, never as HTML". F10 (PR 1) -> "POST /onboarding/:id/bind-realm on a deactivated or migrating tenant answers 409 tenant is not active with identical bytes and writes nothing". G(g) -> "create has exactly one caller: the onboarding handler". letflow-9a conditions: (1) same transaction -> "bind: tenant-chain and platform-chain entries exist in the same transaction (forced failure of the platform write leaves no membership, no consumed grant, no tenant entry)", "a failure injected at the tenant audit step rolls back the membership, the consumed mark, the marker stamp and writes no platform entry", "created: a forced failure of the platform write leaves no grant row and no tenant entry", "revoked: a forced failure of the platform write leaves the grant open, the e-mail present and no tenant entry", "realm bound: a forced failure of the platform write leaves idp_realm_id NULL and no tenant entry" (PR 1), "a bind with no configured platform tenant is a silent no-op and the grant stays open"; (2) same reference -> "tenant-chain and platform-chain entries carry the same grant_id", "the platform bind entry contains only grant_id, tenant_id and bound_user_id and no e-mail".

### 11.1 PR 2 files

`priv/repo/migrations/20261008000001_create_pending_tenant_admin_grants.exs` (new); `lib/letflow/tenant_provisioning.ex` (manifest + docs); `lib/letflow/identity/pending_admin_grant.ex` (new); `lib/letflow/identity/pending_admin_grants.ex` (new); `lib/letflow/oidc/identity_context.ex`, `claim_mapping.ex`, `jit_provisioning_config.ex`; `config/runtime.exs` (env list, boot validation); `lib/letflow/plugs/auth_pipeline.ex` (the new step, moduledoc chain list); `lib/letflow/routers/onboarding.ex` (grant creation, list, revoke, response keys); `lib/letflow/routers/identity.ex` (read route); `lib/letflow/api/authorization.ex` (three policy keys); `docs/runbooks/onboarding-new-tenant-realm.md`; a short decision record `docs/migration/decisions/00NN-pending-tenant-admin-grant.md` recording the binding rules (OQ-13); `docs/roles.md` (who holds TENANT_ADMIN: the pending-grant path); `lib/letflow/design/req447-infra-realm-mapping.md` section 3b sentence updated; `docs/issues/ISS-1030.yaml`; web result view (drop the `admin_username` and `admin_display_name` inputs, keep `admin_email` optional, show `administrator.state`); tests of 10.2.

---

## 12. Risks and open questions

### Risks
* R1. The SPA wizard speaks a saga contract the backend does not implement (C15). If PR 1 is merged without the adapter the new messages are not visible in the wizard even though the API is correct. Mitigation: the thin adapter in PR 1 (OQ-10).
* R2. The first-login step adds one indexed query on the hot auth path for users who have no synced role claims. Gated so users with roles pay nothing; stamped marker ends it after a bind.
* R3. Stamping `role_claims_synced_at` at bind changes nothing for revocation semantics (REQ-378) but means a later realm role added for that user is not synced (it already holds the owner role).
* R4. Boot-time replay is the only rollout path for existing tenants (C13); a failing replay leaves that tenant without the table (bind is a silent no-op there, onboarding of NEW tenants is unaffected).
* R5. No TTL (Q4) leaves an unused grant valid indefinitely; compensated by visibility (5.3), the operator list AGE and revoke.
* R6. Realm hygiene (section 8 residual risks) is enforced only by the runbook, not by code.
* R7. The existing `patch_tenant_with_audit` writes the platform operator's user id into a customer tenant's audit chain (`tenant.platform_setting.updated`), readable by that tenant's `:AuditRead` holders. Reported as a follow-up issue for ORCH to file (it is outside ISS-1030); this design does not copy it. letflow-2 files it, owner letflow-4; the fix must use the split pattern of section 7a (one pattern for every operator action that touches a tenant). Filed as Q-1032 / GH #2351 (LOW/MEDIUM, INV-2): `patch_tenant_with_audit` (`identity.ex` about lines 1144-1177) writes the operator's user id into the tenant audit chain; the fix follows the same split pattern as section 7a; owner letflow-4; a separate small PR, not part of ISS-1030.

### Open questions (genuinely open; each with the default this design uses)
* OQ-1. Bind-once `idp_realm_id` after creation is a narrow exception to decision 0006 R5 ("immutable after creation", no code path). The BA text allows "PATCH /tenants/:slug before activation"; this design uses a dedicated onboarding route instead (the onboarding record is the operator's work item, and a PATCH on tenants would widen an already audited route). DEFAULT: `POST /onboarding/:id/bind-realm`, atomic NULL-only update; REVIEWER confirms against 0006.
* OQ-2. A realm probe that is unreachable: refuse (503, nothing created) or accept unchecked? DEFAULT: refuse, because accepting an unverified realm binds a trust anchor to a tenant.
* OQ-3. Grant insert failing after the tenant is provisioned: 500 or 201 with `not_stored`? DEFAULT: 201 with an explicit state and the runbook next step (the router has no rollback precedent, `onboarding.ex:200-208`).
* OQ-4. "Login response identical": there is no Letflow login endpoint (Keycloak signs the user in; Letflow sees bearer requests). DEFAULT interpretation: for every caller who does not legitimately bind, status, body and headers of the authenticated request are byte-identical with and without a pending grant; the binding person's granted roles are the intended difference. BA to confirm.
* OQ-5. Bind trigger: only for a newly created user or one with no synced role claims. A person who already holds claim-synced roles never binds. DEFAULT as designed (limits the hot-path cost); alternative is "every request until consumed".
* OQ-6. Correcting a wrong `admin_email`: v1 has no re-create path (creation only by the onboarding call; see OQ-13 for the 0046 D4 argument). DEFAULT: revoke, then use the runbook path (realm user with the `TENANT_ADMIN` realm role). A "replace pending admin" route is a follow-up decision for the BA.
* OQ-7. Maximum e-mail length: RFC 5321 allows 320 characters in total; this design caps at 254 (the usual practical bound and the CHECK). DEFAULT: 254; an administrator with a longer address uses the runbook path.
* OQ-8. Platform-wide list of pending grants across all tenants. DEFAULT: not built (per-onboarding list only).
* OQ-9. Reserved realm names. DEFAULT: `master` only, as a constant; the list can become configuration if the operator needs more.
* OQ-10. Whether the wizard is actually used with the synchronous backend (it cannot navigate today: `onboarding_id` vs `id`, `state`). DEFAULT: a thin adapter in `web/src/api/onboarding.ts` mapping the synchronous record to the saga-shaped types, limited to what is needed to display the new response; FRONTEND-DEV verifies the contract and reports if a larger rework is needed (that would be a separate issue, not folded into this PR).
* OQ-11. Stamp `role_claims_synced_at` in the bind transaction. DEFAULT: yes (7.8).
* OQ-12. Migration version collision. DEFAULT `20261008000001`; ELIXIR-DEV re-checks `origin/main` and open PRs.
* OQ-13. A decision record for the first-login e-mail binding rules. DEFAULT: write a short one in PR 2, `docs/migration/decisions/00NN-pending-tenant-admin-grant.md`, with REVIEWER sign-off, containing (i) the binding rules of section 7; (ii) the NARROW EXCEPTION to decision 0006 R5 ("`idp_realm_id` immutable after creation"): it may be set once from NULL through the bind-once route of 3.2, never changed and never cleared, by the platform operator only; (iii) the argument that a bootstrap grant is consistent with 0046: D4 gives `PLATFORM_ADMIN` no power inside a customer tenant, and D5 makes `TENANT_ADMIN` the tenant's own owner role. The bootstrap grant is not "the operator adding admins inside a customer tenant" because the operator holds and exercises no tenant power (it writes one pending record for a person it names at the moment the tenant is created, confers nothing to itself, and has no route to add, change or replace an administrator afterwards, which is why the revoke route exists only to withdraw); the grant takes effect only through that person's own verified login in the tenant's own realm, where the tenant's `TENANT_ADMIN` role is conferred by the tenant's own data. The record must not contradict 0043, 0044 or 0046; REVIEWER confirms.
* OQ-14. The operator `LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS` list is read at boot (restart to change). DEFAULT yes; no hot reload, which also keeps it out of any request path.
* OQ-16. Placement of the once-per-tenant-per-hour log throttle of 7 step 11 (a named ETS table created in the infrastructure supervisor at application start). DEFAULT: that; ELIXIR-DEV substitutes an existing throttle helper if review finds one. Not security relevant, only placement.
* OQ-15 (CLOSED): letflow-9a accepted the narrowed audit design (it follows INV-10) with two conditions, recorded in section 7a and in 7 step 9: both entries in the same transaction as the state change, and both carrying the same grant (or tenant) reference.

---

## 13. Size estimate

| | PR 1 | PR 2 |
|---|---|---|
| lib files | 6 touched (`onboarding.ex`, `identity.ex`, `tenant.ex`, `authorization.ex`, plus config) and 1 new (`realm_probe.ex`) | about 10 touched, 3 new (`pending_admin_grant.ex`, `pending_admin_grants.ex`, migration) |
| docs | runbook, ISS-1030.yaml | runbook amendment, decision record, roles.md, infra-mapping sentence |
| web | 3 files + 1 test | 2 files + test updates |
| tests | about 59 | about 91 |
| estimate | S3 to S4 (one agent turn each for lib, web and tests; the web adapter is the swing factor) | M (about 700 lines of lib, about 1500 lines of tests), two to three agent turns; the migration, the pipeline step and the audit transaction are the parts to review hardest |
| gate | SECURITY-REVIEWER (new platform-scope route, outbound probe) then REVIEWER | SECURITY-REVIEWER (auth path, tenant-data path, PII) then REVIEWER |

Release gate for PR 2: PR 1 merged and deployed; a QA realm with a verified-e-mail user available for the UAT binding test (infra task, section 9 item 7).
