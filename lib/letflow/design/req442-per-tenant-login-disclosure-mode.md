# REQ-442 design: per-tenant login disclosure mode

Stage S4 (public tenant-login discovery series). Source: `docs/requirements.yaml` REQ-442 (as extracted
into the handoff), decision `docs/migration/decisions/0043-email-first-login-ba-decisions.md` D-A,
decision 0042, design `lib/letflow/design/req434-email-first-login-directory.md` (sections 5.4 and 7).
Design only: signatures, shapes, constraints. No implementation bodies.

## 0. Verified premises (each read in the repository, not assumed)

| # | Fact | Where |
|---|---|---|
| P1 | `tenants` is a public-schema table. Migrations are in `priv/repo/migrations/`; the latest is `20261004000001_create_tenant_login_directory.exs`. Tenant-scoped migrations are a separate manifest (`TenantProvisioning.tenant_scoped_migrations/0`); a public column migration must NOT be added to it. | `priv/repo/migrations/`, `lib/letflow/tenant_provisioning.ex` |
| P2 | `Tenant` schema: fields `slug, display_name, status, idp_realm_id, settings (TenantSettings), storage_allowance_bytes`. Changesets: `create_changeset/3`, `update_changeset/2`, `admin_patch_changeset/2` (casts only `:display_name`), `status_changeset/2`, `settings_changeset/2`. No changeset casts a mode. | `lib/letflow/identity/tenant.ex` |
| P3 | The ONLY caller of `Tenant.admin_patch_changeset/2` is `Letflow.Identity.patch_tenant/2` (`identity.ex` ~line 1103). The ONLY caller of `Identity.patch_tenant/2` is `Letflow.Routers.Tenants.handle_patch/2`, route `PATCH /api/v1/tenants/:slug`, gated by the `:TenantsManage` permission (PLATFORM_ADMIN only, no own-tenant carve-out, `tenants.ex` moduledoc AC3). So the route exists; no new route is needed and REQ-VALIDATOR need not be stopped. | `lib/letflow/routers/tenants.ex`, `lib/letflow/identity.ex` |
| P4 | `handle_patch/2` validates the body with `Letflow.Api.Validation.validate/2` against a closed `@patch_schema` (today only `display_name`); `validate/2` returns `Map.take(body, declared_fields)`, so an undeclared key is silently dropped, not rejected. | `tenants.ex`, `lib/letflow/api/validation.ex` |
| P5 | `tenant_map/1` in `Routers.Tenants` is the platform-admin tenant response: exactly 6 hand-built keys (`id, slug, display_name, status, inserted_at, updated_at`). It is shared by create, list, get, patch, deactivate, reactivate. | `tenants.ex` |
| P6 | **DISCREPANCY with the requirement text.** The requirement says the change is "audited as other platform-admin tenant updates are". Verified: `patch_tenant/2` and the `tenants.ex` router write NO audit entry today. Audit entries are written by `Letflow.Audit.append_multi/4` / `insert_entry/3` into a per-tenant chain addressed by a tenant schema `prefix` (`audit_chain_locks`, per-tenant). There is no platform-level (non-tenant) audit sink. | `identity.ex` (audit only in user/group paths), `lib/letflow/audit.ex` |
| P7 | Tenant-admin settings route `Routers.TenantSettings` (REQ-382) uses `Tenant.settings_changeset/2` and the closed `TenantSettings` key vocabulary (`app_name, logo_url, brand_colors, locales, default_locale`); an unrecognised top-level key is rejected and audited (`tenant_settings.reject_unrecognized_keys`). Its response is `%{"tenant_id", "settings"}`. | `lib/letflow/routers/tenant_settings.ex`, `lib/letflow/identity/tenant_settings.ex` |
| P8 | Tenant JSON shapers found by grep (`%Tenant{`, `Map.from_struct`, `Jason.encode`): `Routers.TenantConfig.config_map/2` (3 keys: `oidc_authority, client_id, branding`), `Routers.MobileTenantConfig` (reads `idp_realm_id` + `settings` only, explicit keys), `Routers.Me.home_tenant_json/1` and `membership_json/1` (4 hand-built keys), `Routers.TenantSettings.settings_response_map/2`, `Routers.Tenants.tenant_map/1` (P5), `Modules.Exam.Certificate` (branding via `TenantConfig.branding_from_settings/1`), `Plugs.TenantStatus` (fixed Jason body), `Repository.Attachments`, `ServiceCatalog`, `TenantOnboarding` (read the struct, do not serialise it). None derives JSON from the whole struct; every one is an explicit-key allowlist. No `Jason.Encoder` is derived on `Tenant`. | grep over `lib/` |
| P9 | `Letflow.LoginDirectory.lookup_by_keys/1` (REQ-435, merged in #2201) is the single query: `Tenant` rows with `EXISTS` semijoin to `TenantLoginDirectoryEntry` on `email_key in ^keys`, `status == :active`, `idp_realm_id` non-null and non-empty, ordered `display_name, slug`, `limit 50`, `select %{slug, display_name}`, `Repo.all(query, log: false)`, wrapped in `rescue -> {:error, :lookup_failed}`; no `:prefix`. `lookup_by_email/1` composes `email_keys/1` / `sentinel_keys/1` with it. | `lib/letflow/login_directory.ex` |
| P10 | Callers of `lookup_by_keys/1` / `lookup_by_email/1` in `lib/`: only `LoginDirectory` itself (`Backfill` references `LoginDirectory` for keys, not lookup). Callers in `test/`: `test/letflow/login_directory_test.exs`, `test/letflow/login_directory/backfill_test.exs`, `test/support/login_directory_fixture.ex`. `Letflow.LoginDiscovery` and `Letflow.Routers.LoginDiscovery` (REQ-436/437) do NOT exist in the tree yet, so REQ-442 has no production consumer to update; REQ-437 will consume `disclose`. | grep |
| P11 | Deployment-wide mode config (design 434 section 7): `config :letflow, Letflow.Routers.LoginDiscovery, mode:` with values `:uniform_plus_email | :redirect_single`, default `:redirect_single` in `config/config.exs`, env override `LETFLOW_LOGIN_DISCOVERY_MODE` in `config/runtime.exs`. These do not exist yet (REQ-437 / REQ-436 own them). REQ-442 adds no config and no env var. | design 434 s7; `config/` grep found nothing |
| P12 | Decision 0044 (hybrid identity model) concerns identity-source/realm topology; it does not touch `tenants.login_disclosure_mode`, the directory lookup or the disclosure modes. No conflict found. | `docs/migration/decisions/0044-hybrid-identity-model.md` |

## 1. Migration (acceptance criterion 1)

- File: `priv/repo/migrations/20261005000001_add_login_disclosure_mode_to_tenants.exs` (timestamp rule: strictly greater
  than the newest existing file, `20261004000001`, in the repo's `YYYYMMDDNNNNNN` form).
- Module: `Letflow.Repo.Migrations.AddLoginDisclosureModeToTenants`.
- Public schema only (default `tenants` table, no `prefix`). Not added to `tenant_scoped_migrations/0`.
- **up**: add column `login_disclosure_mode`, type `varchar(255)` (Ecto `:string`), `NULL` allowed, NO default
  (existing rows read NULL = "use the deployment mode"). Create a named CHECK constraint
  `tenants_login_disclosure_mode_check`: `login_disclosure_mode IN ('uniform_plus_email', 'redirect_single')`
  (a NULL satisfies a CHECK, so nullability is preserved).
- **down**: drop constraint `tenants_login_disclosure_mode_check`, then remove the column. Implemented with explicit
  `up/0` and `down/0` (not `change/0`) so rollback order is unambiguous.
- No index: the column is only read in the select list of an already-selective, `limit 50` query, never filtered on.
- No data change; no tenant-specific value (decision 0022 bucket rule).
- Verification to run by ELIXIR-DEV and quote: `mix ecto.migrate`, `mix ecto.rollback`, `mix ecto.migrate`;
  `information_schema.columns` shows `is_nullable = YES` for `public.tenants.login_disclosure_mode` and no such column
  in any `tenant_*` schema; an `INSERT` with `'picker_unauth'` fails with a check_violation naming the constraint.

## 2. Tenant schema and changeset (acceptance criteria 2, 5)

`Letflow.Identity.Tenant`:

- New field: `field :login_disclosure_mode, :string` (plain string, nullable, no default, NOT `read_after_writes`).
  Rationale for `:string` over `Ecto.Enum`: an unrecognised stored value cannot occur (CHECK), and requirement item 4 says
  an unrecognised value read in code is treated as uniform; `Ecto.Enum` would raise on load instead.
- New public constant/function: `@spec login_disclosure_modes() :: [String.t()]` returning exactly
  `["uniform_plus_email", "redirect_single"]` (single source for the changeset validation and tests).
- Changeset change (only change to casting in the module): `admin_patch_changeset/2` casts `[:display_name,
  :login_disclosure_mode]` and then `validate_inclusion(:login_disclosure_mode, login_disclosure_modes())` (a `nil`
  value is permitted: it is the reset-to-fallback value). Its `@spec` is unchanged; its `@doc` and the moduledoc
  (which says it casts only `:display_name`) are updated.
- Untouched, and still must NOT cast the new field: `create_changeset/3`, `update_changeset/2`, `status_changeset/2`,
  `settings_changeset/2`. A test asserts each of these produces no change for `%{"login_disclosure_mode" => ...}`.
- No `@type t` change: verified by grep that `lib/letflow/identity/tenant.ex` declares NO `@type t` (callers' `Tenant.t()`
  specs resolve through the struct's auto-generated type). ELIXIR-DEV adds the field to the schema block only and
  does NOT introduce a `@type t`.
- Semantics on PATCH: key absent = no change; `null` = reset to NULL (deployment fallback); a value outside the two
  modes = changeset error -> existing `Response.unprocessable(conn, "validation failed")`.

Why a tenant admin cannot set it: the only changeset that casts it is `admin_patch_changeset/2`, reached only via
`PATCH /api/v1/tenants/:slug` (PLATFORM_ADMIN by `:TenantsManage`, P3). The tenant-admin route uses
`settings_changeset/2`, which casts only `:settings`; a top-level `login_disclosure_mode` in that request body is not a
`settings` key, and a `login_disclosure_mode` key INSIDE `settings` is rejected by the closed `TenantSettings`
vocabulary (P7). The vocabulary is NOT extended.

## 3. Write path and audit (acceptance criterion 2)

Route (existing, extended; no new route): `PATCH /api/v1/tenants/:slug` -> `Routers.Tenants.handle_patch/2` ->
`Identity.patch_tenant/2` -> `Tenant.admin_patch_changeset/2`.

`Routers.Tenants`:
- `@patch_schema` gains a second `FieldConstraint`: name `"login_disclosure_mode"`, `required: false`,
  `type: :string`, `allowed_values: ["uniform_plus_email", "redirect_single"]` (the field already exists on
  `FieldConstraint`, see `validation.ex` line ~172). `nil`/absent are skipped by `validate_field/2` (it treats nil
  as not present); because `validate/2` returns `Map.take(body, fields)`, an explicit JSON `null` is carried in `attrs`
  as `nil` and reaches the changeset as reset-to-NULL. An unknown extra body key remains silently dropped (existing
  behaviour; not changed).
- `tenant_map/1` gains a seventh key `"login_disclosure_mode" => tenant.login_disclosure_mode` (string or `null`).
  Allowed by the requirement ("the platform-admin tenant response may contain it"); it is the only way an operator
  can read back the setting. Consequence: `tenant_map/1` is shared by create/list/get/patch/deactivate/reactivate, all
  PLATFORM_ADMIN-only (P3), so every one now carries the key; tests that assert "exactly 6 keys" in
  `test/letflow/routers/tenants_test.exs` must change to 7 (flag for TEST-DESIGNER). Update the "Exactly 6 keys"
  comment.

`Identity.patch_tenant/3` (replaces `patch_tenant/2`; P3 shows no other caller, so no arity-2 delegate is kept):

```
@type patch_opts :: [actor_id: Ecto.UUID.t() | nil, platform_prefix: String.t() | nil, trace_id: String.t() | nil]
@spec patch_tenant(slug :: String.t(), attrs :: map(), patch_opts()) ::
        {:ok, Tenant.t()}
        | {:error, :not_found}
        | {:error, Ecto.Changeset.t()}
        | {:error, :audit_failed}
```

Router clause per tag in `handle_patch/2` (the existing `get_tenant_by_slug` pre-check stays):
`{:ok, tenant}` -> `Response.ok(conn, tenant_map(tenant))`; `{:error, %Ecto.Changeset{}}` ->
`Response.unprocessable(conn, "validation failed")` (unchanged); `{:error, :not_found}` -> `Response.not_found(conn)`
(unchanged); `{:error, :audit_failed}` -> `Response.internal_error(conn)`, i.e. HTTP 500 with the platform's existing
RFC 9457 problem envelope, `type` ending `internal-error`, `title` "Internal Server Error", and the fixed
`@internal_error_detail` (the helper takes no detail, so the body cannot vary with the cause; INV-4). The PATCH is
rolled back: the tenant row is unchanged.

Actor id and trace id source: `conn.assigns.auth_context.user_id` and `conn.assigns[:trace_id]`, exactly as
`Routers.TenantSettings` reads them (`tenant_settings.ex`, the audit attrs block). The router passes
`[actor_id: ..., trace_id: ...]`. Nil-actor policy: `Audit.entry_attrs` permits a nil `actor_id`, but this path does NOT.
When the mode is changing and `actor_id` is not a binary, `patch_tenant/3` returns `{:error, :audit_failed}` before any
write (a security-attribute change with no attributable actor is refused, fail closed). A display_name-only patch does
not need or check the actor.

> **AMENDED 2026-10-13 (ISS-1032 / GH #2351, PR #2482, queue row 1032; GH #2484 records this doc fix).** The audit
> actor description below this note, and the "FINAL audit decision" bullet's single-entry shape, are SUPERSEDED. A
> mode change now writes TWO value-free entries in ONE transaction (lock order tenant row, tenant chain, platform
> chain, as `bind_tenant_realm/3`):
> - TARGET-tenant chain: `tenant.platform_setting.updated`, `actor_id` NIL, `trace_id` NIL,
>   `after_state` `%{"changed" => true, "actor_class" => "platform_operator"}`. Tenant administrators read this chain
>   (`:AuditRead`) and must not learn which platform operator acted (INV-2).
> - PLATFORM chain: `platform.tenant_platform_setting.updated`, `actor_id` = the operator's user id, the passed
>   `trace_id`, `after_state` `%{"tenant_id" => tenant.id, "changed" => true}`.
> `patch_opts` gains `platform_prefix`, supplied by the router only when the platform tenant's schema equals the
> caller's database-resolved tenant schema (`verified_platform_prefix/1` in `Routers.Tenants`); otherwise a mode
> change fails closed with the fixed 500 and writes nothing. The nil-actor policy in the next paragraph now applies
> to the OPERATOR actor of the platform entry only: the tenant entry's nil actor is by design. A `display_name`-only
> patch is unchanged (unaudited). Tenant-chain entries written before PR #2482 still carry the operator id; that is
> a separate decision item (GH #2485).
> **DECIDED 2026-10-14 (GH #2485, option b: leave and document).** Tenant-chain entries with action
> `tenant.platform_setting.updated` written before PR #2482 keep the platform operator's user id in `actor_id`.
> They are not redacted and not re-chained: the chain is hash-linked, and a rewrite would break verification of every later
> entry. A reader of a tenant's audit chain must treat a non-nil `actor_id` on that action as a platform operator id
> (an INV-2 class leak of the operator identity into the tenant's own chain), not as a tenant user.
- Behaviour: load by slug; build `admin_patch_changeset/2`; if the changeset is invalid return `{:error, changeset}`;
  if `login_disclosure_mode` is among the changes (value actually differs), run the tenant update and the audit insert
  in ONE `Repo.transaction` (`Ecto.Multi`: `:tenant` update, then `Audit.append_multi/4`), so the audit row and the
  mutation commit or roll back together (the established pattern of `create_user/2` etc.). If it is not among the
  changes (e.g. a display_name-only patch), behaviour is exactly as today: plain `Repo.update/1`, no audit (matches
  the status quo that this route is unaudited, P6; this requirement does not retrofit audit onto display_name).
- **FINAL audit decision (resolves the former open question Q1; no further decision is pending).**
  Premise correction recorded for ORCH/DOC-UPDATER: the requirement's phrase "audited as other platform-admin tenant
  updates are" is wrong, because no platform-admin tenant update (including `PATCH /tenants/:slug`) is audited today
  (P6, re-verified by the CODE-DESIGN-VALIDATOR) and no platform-level audit sink exists. AC2's "the change is audited"
  is satisfied by auditing a mode change in the TARGET tenant's chain, in the same transaction as the update. Audit rows
  are not retro-fitted to display_name patches.
- Audit entry attrs (type `Letflow.Audit.entry_attrs()`): `actor_id` = the validated actor (above);
  `action` = `"tenant.platform_setting.updated"` (neutral: it does not name the attribute, so a tenant-side audit
  reader learns only that some platform-managed tenant setting changed); `resource_type` = `"tenant"`;
  `resource_id` = the target tenant id; `trace_id` = the passed trace id; `before_state` = `nil`;
  `after_state` = `%{"changed" => true}` (INV-2: no mode value, no attribute name, because `GET /audit` returns
  `before_state`/`after_state` verbatim and `:AuditRead` is held by PROCESS_OPERATOR and wider). The mode value is
  visible only to PLATFORM_ADMIN through `tenant_map/1`.
- Audit prefix: the TARGET tenant's schema name taken from its registration row, NOT from the caller's `scoped_opts`
  and NOT from the pure `TenantProvisioning.schema_name_for_tenant/1` (which only derives a name and never checks
  provisioning).
- **Audit failure mechanism (verified: `schema_name_for_tenant/1` and `tenant_id_for_schema_name/1` are pure and do not
  detect an unprovisioned tenant, and `Audit.insert_entry/3` would raise `undefined_table` rather than return an
  error).** Two layers, both mapped to the one tag `{:error, :audit_failed}`:
  1. Pre-check, before any write, only when the mode is changing: `Repo.get_by(TenantProvisioning.Registration,
     tenant_id: tenant.id)`; `nil` -> `{:error, :audit_failed}` (tenant row without a provisioned schema; nothing
     written). Otherwise the audit prefix is `registration.schema_name`.
  2. The `Repo.transaction` (`:tenant` update + `Audit.append_multi/4`) is wrapped in a `rescue` clause that catches any
     exception and returns `{:error, :audit_failed}`; it logs one fixed message naming only the tenant id (INV-4: never
     the exception, query text or connection detail). An `{:error, :audit, _reason, _changes}` Multi result maps to
     the same tag. In every failing case the transaction has rolled back, so the mode is unchanged.
  The router maps the tag to HTTP 500 with the existing problem envelope (above).

Authorisation matrix (all through the existing `Authorization.evaluate_access/2` `:TenantsManage` gate; nothing is
loosened): PLATFORM_ADMIN -> 200 and value set; TENANT_ADMIN -> existing platform refusal (403 per
`tenants_test.exs` AC1/AC2), row unchanged; ordinary user -> same refusal, row unchanged.

## 4. Response exposure (acceptance criterion 3, INV-2)

Rule: `login_disclosure_mode` appears in exactly one shaper, `Routers.Tenants.tenant_map/1` (platform admin).
For every other shaper in P8 the design adds nothing: each is a hand-built explicit-key allowlist that cannot surface a
new `%Tenant{}` field, so the absence is by construction. The test plan asserts it at byte level anyway.

| Shaper | Audience | Change | Assertion |
|---|---|---|---|
| `Routers.TenantConfig.config_map/2` (`GET /api/tenant-config?realm=<slug>`) | pre-auth | none | raw response body (binary), for tenants with mode set and unset: `refute body =~ "login_disclosure_mode"` and keys still exactly `oidc_authority, client_id, branding` |
| `Routers.MobileTenantConfig` (`GET /api/mobile/tenant-config`) | pre-auth | none | same byte-level refute, set and unset |
| `Routers.TenantSettings` GET/PATCH response (`settings_response_map/2`) | tenant admin | none | byte-level refute on GET and PATCH; plus a PATCH whose body carries `login_disclosure_mode` (top level and inside `settings`) is rejected/ignored and the column is unchanged |
| `Routers.Me` (`home_tenant_json/1`, `membership_json/1`) | any authenticated user | none | byte-level refute, set and unset |
| Tenant-admin-readable audit entries (`GET /audit`) | tenant admin | none (neutral action name, value-free payload) | the entry written by section 3 contains no mode value (byte-level) |
| `Routers.Tenants.tenant_map/1` | PLATFORM_ADMIN | add key | key present on GET/PATCH responses with the value (or `null`) |

A grep gate (a test using `File.read!` over `lib/letflow/routers/**/*.ex` and `lib/letflow/modules/**/*.ex`) asserts
the string `login_disclosure_mode` occurs only in: `identity/tenant.ex`, `identity.ex`, `login_directory.ex`,
`routers/tenants.ex` (and design/test/migration files). This also covers criterion 5's grep.

## 5. LoginDirectory extension (acceptance criteria 4, 5, 6)

Types (replace the old `tenant_ref` use on the lookup's return; keep `tenant_ref` for the delivery list and
response shapes that REQ-437 builds):

```
@type disclosure_mode :: :uniform_plus_email | :redirect_single
@type tenant_ref   :: %{slug: String.t(), display_name: String.t()}                      # unchanged
@type tenant_match :: %{slug: String.t(), display_name: String.t(), disclose: boolean()} # new internal match type
```

Signatures:

```
@spec lookup_by_keys(candidate_keys()) :: {:ok, [tenant_match()]} | {:error, :lookup_failed}
@spec lookup_by_keys(candidate_keys(), disclosure_mode() | term()) :: {:ok, [tenant_match()]} | {:error, :lookup_failed}
@spec lookup_by_email(term()) :: {:ok, [tenant_match()]} | {:error, :lookup_failed}
```

- `lookup_by_keys/2` is new and holds the logic; the second argument is the DEPLOYMENT mode (so the SQL-bound parameter
  is explicit and testable without mutating application env). `lookup_by_keys/1` delegates with the deployment mode read
  by a private `deployment_mode/0`; `lookup_by_email/1` is unchanged in shape and returns the new match type.
- `deployment_mode/0` (private) reads `Application.get_env(:letflow, Letflow.Routers.LoginDiscovery, [])[:mode]`
  directly (the key of P11), NOT through `Letflow.LoginDiscovery.mode/0`, which does not exist yet and would make
  `LoginDirectory` depend upward on a later module. Missing key = `:redirect_single` (ratified default). Any other
  unrecognised term = `:uniform_plus_email` (design 434 s7 conservative rule; no log from this module, no new env var,
  no `runtime.exs` change). Open question Q3 asks REQ-437 to keep this single reader or re-point it.
- `lookup_by_keys/2` treats its second argument the same way: exactly `:redirect_single` yields deployment-allows-
  disclosure `true`; anything else (including `:uniform_plus_email`, nil, a junk term) yields `false`. Only this boolean is
  sent to the database.

The single query (unchanged: `Tenant` from-clause, `EXISTS` semijoin on `email_key in ^keys`, `status == :active`,
non-null non-empty `idp_realm_id`, `order_by display_name, slug`, `limit 50`, `Repo.all(query, log: false)`, same
`rescue` to `{:error, :lookup_failed}`, no `:prefix`, no second query) changes only its select list to add:

```
disclose = ($deployment_allows::boolean)
           AND COALESCE(tenants.login_disclosure_mode, 'redirect_single') = 'redirect_single'
```

where `$deployment_allows` is the bound boolean parameter (never string-built SQL; INV-7).

Ecto expression form (pinned): the `select` map's `disclose:` value is a single `fragment/1` with the SQL text a literal
and ONE `?` placeholder for each of two arguments: the pinned bound parameter `type(^deployment_allows?, :boolean)`
(a `^` pin, so it travels as a Postgrex bound parameter, never interpolated) and the column reference
`t.login_disclosure_mode`. The literal comparison `COALESCE(?, 'redirect_single') = 'redirect_single'` and the `AND`
live inside that fragment. No `Ecto.Query.dynamic/2`, no string concatenation, no `Code.eval`. `deployment_allows?` is
a local boolean computed in Elixir from the second argument of `lookup_by_keys/2` (exactly `:redirect_single` -> `true`,
anything else -> `false`).

Equivalence with the requirement text ("the deployment mode is bound as a parameter"): the mode is a two-valued
atom, and the SQL rule only ever asks "is the deployment mode `redirect_single`". Binding the derived boolean
`deployment_mode == :redirect_single` carries exactly that one bit, so the truth table of
`(deployment is redirect_single) AND COALESCE(...) = 'redirect_single'` is identical to binding the mode string and
comparing in SQL; it additionally makes any unrecognised deployment term collapse to `false` (uniform) in Elixir before
it reaches the database, which satisfies requirement item 4. `select` still builds the map
directly: `%{slug, display_name, disclose}`. `Tenant` is still never loaded, so `id`, `idp_realm_id`, `settings` and
`login_disclosure_mode` are unrepresentable past the query. Consequences, all intended:
- tenant NULL falls back to the deployment mode (both rows of the matrix);
- deployment `:uniform_plus_email` makes `disclose` false for every tenant (ceiling; 0042 kill switch preserved);
- an unrecognised stored value (impossible under the CHECK) evaluates to `false` = uniform, satisfying item 4 at the
  data layer; the code-side treatment is the same for the deployment value;
- an inactive or unbound-realm tenant is excluded by the unchanged WHERE clause, so it yields no row regardless of its mode.

Result-ordering, de-duplication across the two rotation keys, `limit`, and the `{:error, :lookup_failed}` branches for
non-list / bad-size key arguments are all unchanged.

`log: false` is preserved on every directory `Repo` call (the lookup, `upsert_entry/2`, `remove_entry_if_unreferenced/3`,
`acquire_key_lock/2`, the backfill); this requirement touches only `lookup_by_keys`. The query adds no email-derived
value to any log line.

Amendments to existing text (to be made in the same change, as decision 0043 conflict items 4-6 require REVIEWER and
SECURITY-REVIEWER sign-off): `LoginDirectory` moduledoc and `lookup_by_keys` `@doc` ("plain maps holding only slug and
display_name"); design 434 s5.4 (`tenant_ref`/return type) and s7 (`mode()` is now `decide/2` over the per-match flag).
REQ-442 does not write REQ-437's `decide/2`; it only supplies `disclose`.

## 6. Cross-module dependencies

- Depends on REQ-435 (`LoginDirectory`, merged). Consumed by REQ-437 (`LoginDiscovery.decide/2`, `delivery/2`).
- Touches `Identity` (`patch_tenant`), `Audit` (append), `TenantProvisioning` (schema name lookup), `Routers.Tenants`.
- Must not touch: `config/config.exs`, `config/runtime.exs`, `TenantSettings`, `TenantConfig`, `MobileTenantConfig`,
  `Routers.Me`, `Routers.TenantSettings`. Module boundaries: `mix letflow.check_boundaries` unaffected (no new
  cross-module-context dependency: `LoginDirectory` gains none).

## 7. Invariants

1. `tenants.login_disclosure_mode` is NULL or one of the two modes (DB CHECK).
2. Only `admin_patch_changeset/2` casts it; only `PATCH /api/v1/tenants/:slug` (PLATFORM_ADMIN) calls that.
3. It is never present in any pre-auth, tenant-admin-readable, or ordinary-user response, nor in any log, audit payload
   readable by a tenant admin, or error body (INV-2, INV-4).
4. `disclose` leaves `LoginDirectory` only inside the internal match; REQ-437 strips it before a response is built.
5. `disclose` is true only when the deployment mode is exactly `:redirect_single` AND the tenant value is NULL or
   `redirect_single`.
6. The lookup remains exactly one query, public tables only, no `:prefix`, `log: false`.

## 8. Files to touch (small diff)

| File | Change |
|---|---|
| `priv/repo/migrations/20261005000001_add_login_disclosure_mode_to_tenants.exs` | new |
| `lib/letflow/identity/tenant.ex` | field, `login_disclosure_modes/0`, `admin_patch_changeset/2` cast + inclusion, docs |
| `lib/letflow/identity.ex` | `patch_tenant/3` (Multi + audit when mode changes), doc/spec |
| `lib/letflow/routers/tenants.ex` | `@patch_schema` entry, pass actor/trace to `patch_tenant`, `:audit_failed` clause, `tenant_map/1` 7th key |
| `lib/letflow/login_directory.ex` | types, `lookup_by_keys/2`, select-list `disclose`, private `deployment_mode/0`, docs |
| `lib/letflow/design/req434-email-first-login-directory.md` | amend s5.4 / s7 pointers to this design (doc only; DOC-UPDATER or ELIXIR-DEV) |
| tests (TEST-DESIGNER): `test/letflow/login_directory_test.exs`, `test/letflow/routers/tenants_test.exs`, new `test/letflow/req442_*` files, migration test | see section 9 |

Overlap flags for the sibling checkout `../letflow-4` (concurrent-session rule): `lib/letflow/login_directory*`,
`lib/letflow/identity.ex`, `lib/letflow/identity/tenant.ex`, `lib/letflow/routers/tenants.ex`. ORCH should fetch and
check letflow-4's branches before merging. `Letflow.Routers.Identity` (`routers/identity.ex`) is NOT touched.
Call sites of the lookup return: none in `lib/` beyond `LoginDirectory` itself (P10); tests listed above assert the old
two-key map shape and must be updated to include `disclose` (the only new key).

## 9. Test plan mapped to acceptance criteria

AC1 migration (`test/.../req442_migration_test.exs`, or a documented shell verification quoted by ELIXIR-DEV): migrate,
rollback, migrate succeed; column present, nullable, public only (query `information_schema.columns` over `tenant_*`
schemas returns nothing); insert `'picker_unauth'` fails with check_violation; both valid values insert; an existing tenant
row reads NULL.

AC2 authorisation (`tenants_test.exs`, extending its AC1/AC2 matrix style):
PLATFORM_ADMIN `PATCH` with each valid value -> 200, DB value set, response key present; with `null` -> NULL; with
`"picker_unauth"` -> 422, row unchanged; audit row exists with action `tenant.platform_setting.updated`, actor, target
tenant id, in the target tenant's chain, and contains no mode value; TENANT_ADMIN and ordinary user -> platform
refusal, row unchanged, no audit row; tenant settings route with body key `login_disclosure_mode` (top level and inside
`settings`) -> rejected/ignored, column unchanged; display_name-only patch writes no audit row; nil actor on a mode change -> 500 problem envelope, row unchanged; mode change on a tenant row with no `tenant_schemas` registration -> 500 problem envelope with the fixed internal-error body, row unchanged, no raise; failed audit (unprovisioned
schema) rolls back the update.

AC3 exposure: byte-level `refute body =~ "login_disclosure_mode"` on each row of the section-4 table, for a tenant with the
value set to each mode and one with it unset; platform-admin GET/PATCH include it; the grep-gate test of section 4.

AC4 lookup matrix (`login_directory_test.exs`), one test per cell, each asserting `disclose` and exactly one query by
`:telemetry` handler on `[:letflow, :repo, :query]` (count 1): deployment `:redirect_single` with tenant NULL -> true;
with `redirect_single` -> true; with `uniform_plus_email` -> false; deployment `:uniform_plus_email` with each of NULL /
`redirect_single` / `uniform_plus_email` -> false; an `:inactive` tenant and a tenant with NULL/empty `idp_realm_id`
(each with each mode value) -> no row. Plus: a junk deployment term -> false for all; a `lookup_by_keys/1` test that sets
and restores the application env.

AC5 match type: the returned maps have exactly the keys `[:disclose, :display_name, :slug]` (sorted keys equality), no
`id`, `idp_realm_id`, `login_disclosure_mode`; grep gate (section 4); REQ-437's response allowlist test is not part of
this requirement and is unchanged (it does not yet exist).

AC6 no prefix / log:false: capture the telemetry query metadata for the lookup (no `prefix` option set, query source is
`tenants` unprefixed); a source-level test asserting every `Repo.` call in `login_directory.ex` carries `log: false`
(the existing assertion style, extended if absent); no log output captured during the lookup.

AC7 gates: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test` on the touched files, and
`mix letflow.check_boundaries`, real output quoted by ELIXIR-DEV/TEST-RUNNER; SECURITY-REVIEWER verdict recorded against
INV-1, INV-2, INV-5, INV-6 (and INV-4/INV-7 for the log and bound-parameter points).

## 10. Open questions (none silently resolved)

- **Q1 (audit): RESOLVED, no longer open.** See section 3 "FINAL audit decision" (ORCH ruling and CODE-DESIGN-VALIDATOR
  ruling agree). Kept as a numbered line only so cross-references stay stable.
- **Q2 (ceiling vs override)**: carried from the requirement/0043 conflict 6. The ceiling reading is the BUILD decision;
  it is flagged for REVIEWER. If the BA meant a tenant may enable disclosure under a uniform deployment default, the SQL
  rule and the kill switch change.
- **Q3 (deployment-mode reader)**: `deployment_mode/0` reads the config key of design 434 s7 directly because
  `Letflow.LoginDiscovery.mode/0` does not exist. REQ-437 should either keep this reader as the single source or replace
  its body, and must not introduce a second reader that can disagree. The config key itself is created by REQ-437/436, so
  until then the default `:redirect_single` applies.
- **Q4 (tenant_map seventh key)**: adding the key to the shared `tenant_map/1` changes every platform-admin tenant response and
  the "exactly 6 keys" tests. Alternative (smaller blast radius): include it only in GET/PATCH by a separate map merge.
  Default chosen: shared key, because a single allowlist is easier to review.
- **Q5 (documented wording conflicts)**: 0042 Standing prohibitions 4 and 11 and design 434 s5.4/s7 wording amendments
  (decision 0043 conflict items 4-6) need REVIEWER/SECURITY-REVIEWER sign-off; this design implements the proposed reading.
- **Q6 (Bilimbaga value)**: setting a tenant to `uniform_plus_email` is an operator action after deploy; no data migration
  ships (requirement open question 2). Keycloak Organizations remain deferred (D-G).
