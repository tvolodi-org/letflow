defmodule Letflow.Plugs.AuthPipeline do
  @moduledoc """
  Letflow's first real auth plug — supersedes the never-built REQ-103
  dev-bearer-token plug (cancelled along with the rest of the MVP-1
  milestone; REQ-103 is not prior art this module extends, it never landed).

  PROVENANCE (historical, not current decision authority):
  Ports the orchestration order from R-Co's `src/api/middleware/auth.zig`
  (`authenticate/3` → `tryTenantRealmAuth` → `postAuthJitProvision`):

    1. Bearer-token extraction + verification (`Letflow.Oidc.TokenVerifier`,
       backed by REQ-016's supervised `Oidcc.ProviderConfiguration.Worker`).
    2. Tenant resolution from the token's `iss` claim's realm
       (`Letflow.Identity.resolve_tenant_by_realm/1`).
    3. Realm-ownership guard, **before** JIT provisioning
       (`Letflow.Identity.verify_realm_ownership/2`).
    4. JIT provisioning/lookup (`Letflow.Identity.provision_oidc_user/4`).
    4c. Pending-administrator binding (ISS-1030,
       `Letflow.Identity.PendingAdminGrants.bind_on_login/5`): between JIT
       provisioning and the per-request effective-role read, so the request that
       binds already sees `TENANT_ADMIN`. OIDC branch only; a bind outcome
       never changes the HTTP outcome (every failure is a silent no-op).
    5. Attach an auth context (`user_id`, `tenant_id`, `roles`) to
       `conn.assigns[:auth_context]` for downstream plugs.

  A request with a missing/malformed bearer token is rejected with 401
  before any DB or claim-mapping work runs (step 1's short-circuit).

  ## API-token branch (REQ-076, 1b/2b alongside the 5-step OIDC list above)

  Immediately after `extract_bearer_token/1` succeeds, `raw_token` is
  inspected for the literal `"lf_tok_"` prefix `Letflow.Identity.create_token/3`
  generates (never present in a JWT, which is three `.`-joined base64url
  segments with no fixed literal prefix) — cheap, unambiguous dispatch, no
  format ambiguity with a JWT. A match routes to this branch instead of the
  five OIDC steps above, which run completely unchanged on every other
  request.

  This branch solves only ONE tenant-identification mechanism for an opaque
  API-token bearer credential — a caller authenticating with an API token
  must additionally send `X-Tenant-Slug: <tenant slug>`, since the bearer
  value itself (unlike a JWT's `iss` claim) carries no tenant hint. It does
  **not** attempt the general problem of embedding tenant identity inside an
  opaque bearer token; a future credential type needing a different
  resolution mechanism (e.g. a tenant segment embedded in a path) is a new
  branch, not a generalization of this one.

  Five steps, mirroring the OIDC branch's own "tag the step" discipline:

    1. `extract_tenant_slug_header/1` — reads the `x-tenant-slug` request
       header. Exactly one non-empty value required. Read only on this
       branch — harmless/ignored on every OIDC-authenticated request.
    2. `resolve_tenant_by_slug/1` — `Letflow.Identity.get_tenant_by_slug/1`
       (already shipped, used identically by `Letflow.Routers.TenantConfig`).
    3. `resolve_schema_name/1` — `Letflow.TenantProvisioning.schema_name_for_tenant/1`,
       the exact same call `provision_user/3`'s OIDC-branch step 4b already
       makes (pure derivation from `tenant_id`, no I/O).
    4. `verify_token_credential/2` — `Letflow.Identity.verify_api_token/2`
       (unchanged) — the live, uncached, per-call database read that makes
       revocation take effect on the very next request (AC4).
    5. `attach_auth_context/4` (existing function, unchanged) — `tenant.id`
       (step 2's schema-authoritative source, never a token-claimed value),
       `verified.user_id`, `verified.roles`. No JIT provisioning step exists
       on this branch: `create_token/3` already requires `user_id` to
       reference an existing row, so there is nothing to provision.

  A missing header, an unresolvable slug, a garbage token, a revoked token,
  an expired token, and a token whose owner is inactive (GH-2557) are all
  byte-identical 401s (`"invalid or expired bearer token"`) — the same anti-oracle discipline the OIDC branch already
  applies to its own five failure tags, extended here rather than inventing a
  differently-worded message that would let a caller distinguish "your slug
  is wrong" from "your token is revoked" by response text. No
  realm-ownership check, no claim mapping, no JIT provisioning on this
  branch — all three are OIDC-specific concepts that do not apply to a
  pre-existing internal user authenticating with a token issued directly by
  an already-authenticated PLATFORM_ADMIN.

  **Mounted since REQ-071.** `Letflow.Plugs.ApiPipeline` (the shared middleware chain for
  every `/api/v1/*` sub-router, forwarded to from `Letflow.Router`) declares
  `plug Letflow.Plugs.AuthPipeline` immediately after `Plug.Parsers` and immediately
  before `Letflow.Plugs.TenantStatus`, ahead of its own `:match`/`:dispatch` — so every
  request under `/api/v1` runs through this plug first, before reaching any of
  REQ-070's sub-routers. `GET /health` is declared directly on `Letflow.Router`, before
  the `/api/v1` forward, and never enters this chain.

  See `lib/letflow/design/req021-auth-plug-pipeline.md` for the full design.
  """

  @behaviour Plug

  require Logger

  import Plug.Conn

  alias Letflow.Api.Scope
  alias Letflow.Identity
  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Identity.Tenant
  alias Letflow.Oidc.ClaimMapping
  alias Letflow.Oidc.ClaimMappingConfig
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.TenantProvisioning

  @impl Plug
  def init(opts), do: opts

  # Every branch's failure reason is tagged with which pipeline step
  # produced it (rather than matched by the raw, callee-specific reason atom
  # in the `else` clause below) — the verifier adapter, `resolve_tenant_by_realm/1`,
  # and `provision_oidc_user/4` all use `:not_found`/similarly-generic atoms
  # for unrelated failures, so dispatching on the bare reason alone would
  # conflate them. Tagging the step is what keeps each failure mapped to the
  # correct status code (§5) regardless of which callee produced it.
  @impl Plug
  def call(conn, _opts) do
    case extract_bearer_token(conn) do
      {:ok, raw_token} ->
        if api_token?(raw_token) do
          authenticate_api_token(conn, raw_token)
        else
          authenticate_oidc(conn, raw_token)
        end

      {:error, reason} ->
        handle_auth_error(conn, {:error, reason})
    end
  end

  # Unchanged five-step OIDC chain (steps 1b-5), extracted from the former
  # single call/2 with clause so it can share handle_auth_error/2 with the new
  # API-token branch below (REQ-076 §3.5) -- same functions, same order, same
  # error tags as before this change.
  defp authenticate_oidc(conn, raw_token) do
    with {:ok, claims} <- verify_token(raw_token),
         {:ok, realm} <- extract_realm(claims),
         {:ok, tenant} <- resolve_tenant(realm),
         :ok <- guard_realm_ownership(tenant.id, realm),
         {:ok, identity_context} <- map_claims(realm, claims),
         {:ok, provisioned} <-
           provision_user(identity_context, tenant.id, realm, conn.assigns[:trace_id]),
         :ok <-
           bind_pending_admin(
             tenant,
             provisioned,
             identity_context,
             realm,
             conn.assigns[:trace_id]
           ),
         {:ok, {live_roles, scope_grants}} <- verify_local_account_state(provisioned, tenant) do
      attach_auth_context(conn, tenant, provisioned.user.id, live_roles, :oidc, scope_grants)
    else
      error -> handle_auth_error(conn, error)
    end
  end

  # REQ-076 §3.5's five-step API-token branch -- see moduledoc "API-token
  # branch" section for the full description of each step.
  defp authenticate_api_token(conn, raw_token) do
    with {:ok, slug} <- extract_tenant_slug_header(conn),
         {:ok, tenant} <- resolve_tenant_by_slug(slug),
         {:ok, schema_name} <- resolve_schema_name(tenant.id),
         {:ok, verified} <- verify_token_credential(raw_token, schema_name) do
      # REQ-497 PR 1b (design section 2): a token principal has no grant rows (0051 D1), so
      # no grants query is added; the flag rides on the tenant row already read.
      attach_auth_context(conn, tenant, verified.user_id, verified.roles, :api_token, :token)
    else
      error -> handle_auth_error(conn, error)
    end
  end

  defp handle_auth_error(conn, error) do
    case error do
      {:error, {:header, _reason}} ->
        reject(conn, 401, "unauthorized", "missing or malformed Authorization header")

      {:error, {:verify, _reason}} ->
        reject(conn, 401, "unauthorized", "invalid or expired bearer token")

      {:error, {:realm, _reason}} ->
        reject(conn, 401, "unauthorized", "invalid or expired bearer token")

      {:error, {:tenant, _reason}} ->
        reject(conn, 401, "unauthorized", "invalid or expired bearer token")

      {:error, {:ownership, :realm_tenant_mismatch}} ->
        reject(conn, 401, "unauthorized", "token realm does not match tenant")

      {:error, {:ownership, :not_found}} ->
        reject(conn, 401, "unauthorized", "invalid or expired bearer token")

      {:error, {:claims, _reason}} ->
        reject(conn, 401, "unauthorized", "invalid or expired bearer token")

      {:error, {:provision, :jit_disabled}} ->
        reject(conn, 403, "forbidden", "JIT provisioning disabled for this realm")

      {:error, {:provision, reason}} ->
        Logger.error("JIT user provisioning failed reason=#{inspect(reason)}")
        reject(conn, 500, "internal_error", "user provisioning failed")

      {:error, {:api_token, _reason}} ->
        reject(conn, 401, "unauthorized", "invalid or expired bearer token")

      {:error, {:account, :inactive}} ->
        reject(conn, 403, "forbidden", "account is inactive")

      {:error, {:account, :invalid_tenant_id}} ->
        Logger.error("verify_local_account_state/2: invalid tenant_id post-provisioning")
        reject(conn, 500, "internal_error", "account state verification failed")
    end
  end

  # Step 1b dispatch (REQ-076 §3.5) -- the literal "lf_tok_" prefix
  # Letflow.Identity's create_token/3 generates, never present in a JWT.
  defp api_token?(raw_token), do: String.starts_with?(raw_token, "lf_tok_")

  # API-token step 1 -- the x-tenant-slug request header, read only on this
  # branch (harmless/ignored on every OIDC-authenticated request).
  defp extract_tenant_slug_header(conn) do
    case get_req_header(conn, "x-tenant-slug") do
      [slug] when byte_size(slug) > 0 -> {:ok, slug}
      _other -> {:error, {:api_token, :header_missing}}
    end
  end

  # API-token step 2 -- Letflow.Identity.get_tenant_by_slug/1 (already
  # shipped, used identically by Letflow.Routers.TenantConfig).
  defp resolve_tenant_by_slug(slug) do
    case Identity.get_tenant_by_slug(slug) do
      {:ok, tenant} -> {:ok, tenant}
      {:error, _reason} -> {:error, {:api_token, :tenant_not_found}}
    end
  end

  # API-token step 3 -- same pure, no-I/O derivation provision_user/3's
  # OIDC-branch step 4b already calls.
  defp resolve_schema_name(tenant_id) do
    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema_name} -> {:ok, schema_name}
      {:error, :invalid_tenant_id} -> {:error, {:api_token, :tenant_not_found}}
    end
  end

  # API-token step 4 -- Letflow.Identity.verify_api_token/2 (unchanged), the
  # live, uncached, per-call database read AC4 depends on.
  defp verify_token_credential(raw_token, schema_name) do
    case Identity.verify_api_token(raw_token, prefix: schema_name) do
      {:ok, verified} -> {:ok, verified}
      {:error, :invalid} -> {:error, {:api_token, :invalid}}
      {:error, :revoked} -> {:error, {:api_token, :revoked}}
      {:error, :expired} -> {:error, {:api_token, :expired}}
    end
  end

  # PROVENANCE (historical, not current decision authority):
  # Step 1a — RFC 6750 §2.1 case-sensitive "Bearer " prefix, matching
  # auth.zig's own check. Missing header, wrong prefix, or an empty token
  # after stripping the prefix all short-circuit here, before step 1b's
  # verifier call — no DB or claim-mapping work has run yet.
  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> {:ok, token}
      _other -> {:error, {:header, :missing_or_malformed}}
    end
  end

  # Step 1b — verify via the configured Letflow.Oidc.TokenVerifier
  # implementation (real oidcc adapter or the test double, per config).
  # Every {:error, _reason} the verifier returns collapses to a single 401 —
  # this design does not distinguish malformed/expired/bad-signature at the
  # HTTP-response level (§3.1's OQ-4).
  #
  # REQ-370: verify_bearer_token/1 (arity 1, no provider_name) — the verifier
  # itself resolves which provider to trust from the token's own claimed
  # issuer against the tenants table
  # (lib/letflow/design/req370-multi-issuer-oidc-verification.md §3).
  defp verify_token(raw_token) do
    oidc_config = Application.fetch_env!(:letflow, :oidc)
    verifier = Keyword.fetch!(oidc_config, :token_verifier)

    case verifier.verify_bearer_token(raw_token) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, {:verify, reason}}
    end
  end

  # PROVENANCE (historical, not current decision authority):
  # Step 2a — realm slug parsed from the `iss` claim's "/realms/" suffix
  # (matching auth.zig's own realmSlugFromIssuer/1), not a `tenant_id` claim.
  defp extract_realm(claims) do
    case Map.get(claims, "iss") do
      iss when is_binary(iss) ->
        case String.split(iss, "/realms/", parts: 2) do
          [_prefix, realm] when byte_size(realm) > 0 -> {:ok, realm}
          _other -> {:error, {:realm, :unresolvable}}
        end

      _other ->
        {:error, {:realm, :unresolvable}}
    end
  end

  # Step 2b — Letflow.Identity.resolve_tenant_by_realm/1.
  defp resolve_tenant(realm) do
    case Identity.resolve_tenant_by_realm(realm) do
      {:ok, tenant} -> {:ok, tenant}
      {:error, reason} -> {:error, {:tenant, reason}}
    end
  end

  # Step 3 — Letflow.Identity.verify_realm_ownership/2, called before any
  # JIT provisioning runs (AC4's explicit ordering guarantee).
  defp guard_realm_ownership(tenant_id, realm) do
    case Identity.verify_realm_ownership(tenant_id, realm) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ownership, reason}}
    end
  end

  # Step 4a — pure claim mapping (Letflow.Oidc.ClaimMapping.map_verified_claims/3).
  defp map_claims(realm, claims) do
    config = ClaimMappingConfig.for_realm(realm)
    subject = Map.get(claims, "sub")

    case ClaimMapping.map_verified_claims(config, subject, claims) do
      {:ok, identity_context} -> {:ok, identity_context}
      {:error, reason} -> {:error, {:claims, reason}}
    end
  end

  # Step 4b — Letflow.Identity.provision_oidc_user/4. tenant_id passed here
  # is the step-2-resolved, DB-sourced value — never
  # identity_context.tenant_id (the token-claimed hint field). REQ-063 moved
  # `users` behind schema-per-tenant, so this step must first derive the
  # tenant's physical schema name (pure, no extra DB round trip --
  # TenantProvisioning.schema_name_for_tenant/1 is confirmed no-I/O) and pass
  # it through as provision_oidc_user/4's new `prefix:` opt.
  #
  # GH 2547 (design section 2.4): the request's trace id reaches the role-claim sync's
  # `group_member.added` audit entries through `:audit_context`; the sync itself sets
  # the actor to the user.
  defp provision_user(identity_context, tenant_id, realm, trace_id) do
    jit_config = JitProvisioningConfig.for_realm(realm)

    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema_name} ->
        case Identity.provision_oidc_user(identity_context, tenant_id, jit_config,
               prefix: schema_name,
               audit_context: %{actor_id: nil, trace_id: trace_id, source: "idp_sync"}
             ) do
          {:ok, provisioned} -> {:ok, provisioned}
          {:error, reason} -> {:error, {:provision, reason}}
        end

      {:error, :invalid_tenant_id} ->
        {:error, {:provision, :invalid_tenant_id}}
    end
  end

  # Step 4c (ISS-1030, design section 6) — the first-login binding of a pending
  # tenant-administrator grant. Runs between provision_user/3 and
  # verify_local_account_state/2 so the bind commits BEFORE the per-request
  # effective-role read. The tenant is the DB-resolved struct (never the token),
  # the prefix is derived exactly as the neighbouring steps derive it. The result
  # is ignored on purpose: bind_on_login/5 never raises and never fails the
  # request, and the pipeline's outcome is identical with or without a grant.
  # GH 2547: the request's trace id reaches both bound audit entries.
  defp bind_pending_admin(tenant, provisioned, identity_context, realm, trace_id) do
    case TenantProvisioning.schema_name_for_tenant(tenant.id) do
      {:ok, schema_name} ->
        _ =
          PendingAdminGrants.bind_on_login(
            tenant,
            provisioned,
            identity_context,
            JitProvisioningConfig.for_realm(realm),
            prefix: schema_name,
            trace_id: trace_id
          )

        :ok

      {:error, :invalid_tenant_id} ->
        :ok
    end
  end

  # Step new (REQ-378 §1.1) — inserted between provision_user/3 and
  # attach_auth_context/4. Two jobs, in order:
  #
  #   1. `users.status` (already present on `provisioned.user` — the row
  #      provision_user/3 just fetched/inserted this same request, so this is
  #      a struct-field read, not a new query) — `:inactive` short-circuits
  #      the whole request with a 403 before any role query runs.
  #   2. `Identity.list_effective_role_names/2` — one new, uncached `Repo`
  #      round trip per authenticated OIDC request, mirroring
  #      `verify_api_token/2`'s own single-uncached-query shape (AC1: a role
  #      revocation — a `group_members` row delete — takes effect on this
  #      user's very next request, no cache/ETS/memoization anywhere in this
  #      path).
  #
  # `schema_name_for_tenant/1` is re-derived here (not threaded through as a
  # new provision_user/3 arg) to avoid changing that function's signature —
  # same no-extra-I/O derivation provision_user/3 itself already calls.
  # REQ-497 PR 1b (design section 2, 0051 D3; r1 CDV B1): in the SAME step, right after the
  # role read and whatever the tenant's flag, the user's applicable scope grants are loaded
  # with exactly one more query and returned as the request memo. An inactive user still
  # short-circuits before both reads.
  defp verify_local_account_state(provisioned, %Tenant{id: tenant_id}) do
    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema_name} ->
        # GH-2557: the same "active" definition the API-token path uses, so
        # the two cannot drift if `User.status` gains a value.
        if Identity.active_user?(provisioned.user) do
          roles = Identity.list_effective_role_names(provisioned.user.id, prefix: schema_name)
          {:ok, {roles, load_scope_grants(provisioned.user.id, schema_name)}}
        else
          {:error, {:account, :inactive}}
        end

      {:error, :invalid_tenant_id} ->
        {:error, {:account, :invalid_tenant_id}}
    end
  end

  # REQ-497 PR 1b (SECURITY-REVIEWER r2 availability advisory): if `role_scope_grants`
  # cannot be read, the request is not failed. The memo becomes `:not_loaded`, which still
  # fails closed: `Letflow.Api.Scope.allowed?/3` denies with `:grants_unavailable` (and the
  # shadow observer counts it); `principal_from_conn/1` does not retry a `:not_loaded` memo.
  # One constant log line, no id and no SQL.
  defp load_scope_grants(user_id, schema_name) do
    Scope.load_grants(user_id, schema_name)
  rescue
    _db_error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("scope_grants_load_failed credential=oidc")
      :not_loaded
  end

  # GH 2534 7b-1: `credential` records which branch authenticated the caller (:oidc or
  # :api_token). Set here by each branch, never from the request. The script registry refuses
  # every write from :api_token (a tenant admin can mint a token for any user, so a token write
  # could launder authorship past the separation-of-duties check).
  #
  # REQ-497 PR 1b (design section 2): adds `scope_enforcement` (`:off | :shadow | :on`, from the
  # tenant row the branch already loaded: zero extra queries, read per request) and
  # `scope_grants` (`Grants.t() | :token | :not_loaded`, the request memo). A context built
  # elsewhere without these keys reads as `:off` / not loaded (fail closed).
  defp attach_auth_context(
         conn,
         %Tenant{id: tenant_id} = tenant,
         user_id,
         roles,
         credential,
         scope_grants
       )
       when credential in [:oidc, :api_token] do
    # ISS-0993 (design section 4): the two scope facts are stored as a
    # CACHE/assertion only. No authorization decision reads them; consumers
    # recompute via Letflow.PlatformTenant from tenant_id and roles.
    #
    # REQ-447 PR 2 (design 3.5): `PLATFORM_ADMIN` is dropped here for every
    # non-platform tenant, so `auth_context.roles` (and everything reading it)
    # never carries it; both the OIDC and the API-token branch converge here.
    roles = Letflow.PlatformTenant.effective_role_strings(tenant_id, roles)
    facts = Letflow.PlatformTenant.scope_facts(tenant_id, roles)

    assign(conn, :auth_context, %{
      user_id: user_id,
      tenant_id: tenant_id,
      roles: roles,
      platform_tenant?: facts.platform_tenant?,
      platform_scope?: facts.platform_scope?,
      credential: credential,
      scope_enforcement: scope_enforcement(tenant),
      scope_grants: scope_grants
    })
  end

  # MUTANT N7: the :on mapping is deleted (maps to :off on both credentials)
  defp scope_enforcement(%Tenant{scope_enforcement: :shadow}), do: :shadow
  defp scope_enforcement(%Tenant{}), do: :off

  defp reject(conn, status, error, detail) do
    body = Jason.encode!(%{error: error, detail: detail})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
