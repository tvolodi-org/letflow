defmodule Letflow.Routers.TenantConfig do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Public login-bootstrap sub-router (REQ-078, design
  `lib/letflow/design/req078-supporting-routes.md` §12). Ports
  `src/api/routes/tenant_config.zig`'s `handleTenantConfig` (L52).

  | Handler | Method/path            | Delegate                                | Auth     | Response |
  |---------|------------------------|-----------------------------------------|----------|----------|
  | config  | `GET /api/tenant-config` | `Letflow.Identity.get_tenant_by_slug/1` | **none** | always 200, `{oidc_authority, client_id, branding, tenant_type}` |
  | logo    | `GET /api/tenant-config/logo?slug=` | `Letflow.Identity.TenantLogo.fetch/1` | **none** | 200 with the stored image bytes, or one uniform 404 (flag off, no/unknown slug, lookup failure, nil/empty realm, inactive tenant, no upload) |

  ## Why this is mounted on `Letflow.Router`, NOT in `Letflow.Plugs.ApiPipeline`

  PROVENANCE (historical, not current decision authority):
  R-Co's endpoint is **explicitly public** — `tenant_config.zig:3` says
  "Public endpoint (no auth required)" and `main.zig:462` carries the same
  comment. Its purpose is login-page bootstrap: the SPA calls it to learn
  which OIDC authority to redirect to, **before** it has any token.
  `web/src/auth/tenantConfig.ts:46` calls exactly `/api/tenant-config`.

  REQ-070 reserved this module at `/tenant-config` **inside**
  `Letflow.Plugs.ApiPipeline`, i.e. behind `Letflow.Plugs.AuthPipeline`. Read
  in full, that plug has **no public-path allowlist, no bypass and no `skip`
  option** — every request reaching it without a valid bearer token gets 401.
  A login-bootstrap endpoint behind auth is unreachable by the only caller
  that needs it. That is not a preference; it is a functional defect in the
  reserved mount point.

  So this module is forwarded from **`Letflow.Router`** —
  `forward("/api/tenant-config", to: Letflow.Routers.TenantConfig)`, declared
  before the `/api/v1` forward, exactly as `GET /health` is. The module file
  did not move; only its mount did. The `/tenant-config` forward inside
  `ApiPipeline` was removed.

  ## The never-error rule is LOAD-BEARING, not an R-Co quirk

  PROVENANCE (historical, not current decision authority):
  `tenant_config.zig:50-51` states it outright: *"Never returns an error to
  the caller — DB failures fall through to the default tenant config so the
  frontend login page always renders."* Ported **exactly**, for two
  independent reasons:

    1. **Availability.** The login page cannot render without a config. A 500
       here locks every tenant out.
    2. **INV-5 / anti-oracle.** A miss, an unprovisioned host, a malformed
       slug and a database outage all produce **the same 200 with the same
       default body**. There is no status code, no error body and no absent
       field from which a prober could learn whether a given hostname or slug
       corresponds to a real tenant. Returning 404 for an unknown host — the
       "tidier" REST answer — would turn this endpoint into a tenant-existence
       oracle for anyone with a wordlist.

  A caller **can** still infer that a slug is bound to *some* realm when it
  gets back a non-default realm id. That is unavoidable: telling the browser
  which realm to use is the endpoint's entire purpose, and it is the same
  information any user of that tenant sees on their own login page.

  ## What this endpoint discloses, and what it must never disclose

  The body has four top-level keys: `oidc_authority`, `client_id`, `branding`
  and `tenant_type` (REQ-472), plus the optional instance-global `env_label` (T-1494:
  the `LETFLOW_ENV_LABEL` operator setting for the test-environment banner; absent when
  the variable is unset, a platform setting and not a tenant attribute, so INV-2 and
  INV-5 are unaffected). `tenant_type` is `"test"`, `"production"` or
  `null`; it is non-null only when a real tenant is resolved through `?realm=<slug>` or a bound
  `?host=<hostname>`, and `null` on every default branch (unknown slug or host, inactive or migrating
  tenant, nil or empty realm, lookup failure, no parameter), so those bodies stay byte-identical
  (INV-5). It is the same bounded inference as a non-default realm id, and it is never a name, slug,
  display name or id (INV-2).

  It returns exactly three values: an OIDC authority URL (which embeds a realm
  id), a public client id, and a `branding` block. Both of the first two are
  values the browser must learn *before* authenticating; the third is display
  information the login page renders before authentication as well. All three
  are visible to any user of that tenant. The `branding` block is itself a
  closed, explicit allowlist of exactly three sub-keys — `app_name`,
  `logo_url`, `brand_colors` — sourced from the tenant's own stored settings
  (`Letflow.Identity.Tenant`'s `:settings` column, REQ-280) where set, and from
  a platform-default value per sub-key where not. It must **never** return a
  tenant id, slug, display name, status, user count, locale/language
  configuration, or any other tenant attribute — the response map is
  hand-built with exactly these three values plus `tenant_type`, and the `branding` block
  is hand-built with exactly its three sub-keys (`brand_colors` itself holds
  the closed sub-keys `primary` and, when stored, `secondary` (REQ-585), each
  read by name and never copied wholesale), both **never** derived from
  `%Letflow.Identity.Tenant{}` (INV-2) or from that struct's `:settings` field
  by anything other than an explicit, named-key read. A non-default `branding`
  block is itself a signal that a slug is real — the same bounded inference
  this endpoint already makes via a non-default realm id in `oidc_authority`;
  it is exactly what any user of that tenant already sees on their own login
  page. **Adding a fourth top-level key to this response, or a fourth sub-key
  to `branding`, is a security change, not a feature.**

  ## Logo (REQ-591, GH #3337)

  `branding.logo_url` may now be a path, `/api/tenant-config/logo?slug=<slug>`, in place of the
  stored string. That happens only when `:tenant_logo_upload_enabled` is on and the resolved tenant
  passes the logo route's guard (non-empty `idp_realm_id`, status other than `:inactive`) and has an
  upload. Which slug can appear: on a `?realm=` hit, the resolved tenant's canonical slug; on a bound
  `?host=` hit, that same resolved tenant's slug (never the caller-supplied hostname); on every default
  branch, the constant `bpm-default`, which `oidc_authority` already discloses. Nothing new is
  learnable. The image bytes, hash, size and `updated_by` never appear in the body (INV-2): only whether
  a logo exists is read. With the flag off, or with no upload, the stored string (or the platform
  default) is returned exactly as before; `branding_from_settings/1` is unchanged. The row
  `GET /api/tenant-config` above stays "always 200".

  `GET /api/tenant-config/logo` resolves ONLY by `?slug=` (no `?realm=`, `?host=` or default
  fallback). Seven cases return one identical 404 (same status, body and header names, INV-5): no
  slug, unknown slug, lookup failure, nil or empty `idp_realm_id`, inactive tenant, no upload, and the
  flag off. A 200 carries the stored content type, `X-Content-Type-Options: nosniff`,
  `Content-Security-Policy: default-src 'none'; sandbox` and `Content-Disposition: inline`. The
  `:prefix` is derived from the tenant found by slug (INV-1).

  ## Precedence

    1. `?realm=<slug>` present — resolve the tenant by slug; if it resolves, is active and has a
       non-empty `idp_realm_id`, that wins and the host branch is skipped.
    2. Otherwise `?host=<hostname>` — resolve the already stored `onboarding_registry.hostname` to its
       tenant. Comparison trims and lower-cases both request and stored values; an active tenant with a
       non-empty realm supplies the response, its `tenant_type`, and its canonical slug for an uploaded
       logo. Unknown, malformed, ambiguous, inactive, migrating, realm-less and failed lookups fall
       through without selecting an arbitrary company.
    3. Otherwise, or on any miss or error — the default tenant: the tenant whose slug is in
       `LETFLOW_DEFAULT_TENANT_SLUG` when it resolves to an active tenant with a realm (T-1481; set to
       `showroom` on the demo), else the constant realm `bpm-default` (branding of that realm's tenant
       when it can be read, else the platform default). The web's order is `?realm=`, remembered slug,
       then host.

  ## `?host=` resolves the company's existing onboarding binding

  T-1359/F1b: the public bootstrap route reads the global `onboarding_registry` and `tenants` tables;
  no second hostname store is needed. For example, `sss.ai-letflow.com` resolves only the tenant whose
  onboarding row stores that hostname. This lookup selects public sign-in configuration only. It never
  authorizes a request or selects a tenant-data prefix: after authentication, the verified token issuer
  remains authoritative.

  GH #2936: "the default" means the default realm **and the branding saved by the tenant that owns it**
  (`bpm-default`), not the platform default. An unknown or otherwise unusable host therefore returns
  exactly the no-parameter default answer. A bound host instead returns that company's public realm and
  allowlisted branding, the same bounded disclosure as its `?realm=<slug>` answer.

  The SPA passes `{host: window.location.hostname}` when no explicit or remembered realm slug exists
  (`web/src/auth/tenantConfig.ts`). No cookie, tenant picker, new route or frontend storage is involved.

  ## No trace id on this endpoint

  Because this module is mounted outside `Letflow.Plugs.ApiPipeline`, it does
  not get `Plug.Parsers`, `Letflow.Plugs.AuthPipeline`,
  `Letflow.Plugs.TenantStatus`, or
  `Letflow.Api.Context.assign_trace_id/1` — so `conn.assigns[:trace_id]` is
  absent and no `x-trace-id` response header is set. Harmless today (this
  endpoint emits no problem document, ever), but it is an inconsistency with
  every other Letflow endpoint. It is **not** fixed by mounting
  `assign_trace_id/1` on `Letflow.Router`, because that would change
  `GET /health`'s response headers, which `deploy/redeploy-test.sh` pins (see
  `Letflow.Router`'s moduledoc). It is a `GET` with no body, so `Plug.Parsers`
  is not needed; this module calls `Plug.Conn.fetch_query_params/1` itself.

  ## No tenant scoping call, deliberately

  This is the one REQ-078 route that does **not** call
  `Letflow.Api.Context.scoped_repo_opts/1`. It is unauthenticated by design
  and reads only the **global** `tenants` and `onboarding_registry` tables, which live outside every
  per-tenant schema — there is no prefix to derive and no per-tenant row to reach.
  """

  use Plug.Router

  alias Letflow.Api.Response
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantLogo

  # PROVENANCE (historical, not current decision authority):
  # Ported from tenant_config.zig:59/:60/:62, then corrected under REQ-133:
  # the literal ported defaults named R-Co's nginx gateway port (8081) and
  # client id (bpm-platform-api) verbatim, both stale against Letflow's own
  # Keycloak -- REQ-128's docker-compose.yml/config/keycloak_port.exs default
  # to port 8082, and REQ-128's config/dev.exs :oidc client_id is
  # "letflow-web" (priv/keycloak/realms/bpm-default.json's only client).
  # This endpoint is what the SPA actually calls at runtime (its own
  # web/src/auth/{OidcManager,tenantConfig}.ts defaults are a same-value
  # fallback for when this call fails, not the effective source of truth),
  # so a stale default here silently overrides a correct SPA-side default.
  @default_idp_base_url "http://localhost:8082"
  @default_client_id "letflow-web"
  @default_realm "bpm-default"

  # ISS-0720 (design lib/letflow/design/iss0720-tenant-config-stale-issuer-key.md
  # §2.2): mirrors Letflow.Repository.Activation's
  # @activation_test_hooks_enabled? shape exactly -- resolved once at compile
  # time via Application.compile_env/3, defaulting false, never a runtime
  # Mix.env() check (unavailable in a compiled release). Only
  # config/dev.exs and config/test.exs set this true; config/prod.exs and
  # config/runtime.exs add nothing, so the false default holds everywhere
  # else and idp_base_url/0's final fallback clause raises instead of
  # silently serving @default_idp_base_url.
  @allow_localhost_idp_fallback? Application.compile_env(
                                   :letflow,
                                   :allow_localhost_idp_fallback,
                                   false
                                 )

  # ── Branding platform defaults (REQ-281) ──────────────────────────────────
  #
  # Endpoint-local, independent from Letflow.Routers.MobileTenantConfig's own
  # @default_branding -- deliberately NOT shared/reused (design §5). Mobile's
  # #0B5FFF brand color is already flagged as stale (REQ-280 design §6); this
  # endpoint reaches its own default for the first time and uses REQ-280's
  # re-verified canonical value (web/src/styles/tokens.css:18, --color-brand-600)
  # from day one, with no stale value to preserve.
  @default_app_name "Letflow"
  @default_logo_url nil
  @default_brand_colors %{"primary" => "#228be6"}

  # GH T-1558: public, credential-free lookup -> per-address 429 with retry-after (slug enumeration).
  plug(Letflow.Plugs.AuthAttemptLimit, mode: :requests)
  plug(:match)
  plug(:dispatch)

  get "/" do
    handle_tenant_config(conn)
  end

  get "/logo" do
    serve_logo(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── GET /api/tenant-config/logo (REQ-591) ─────────────────────────────────
  #
  # Resolves ONLY by ?slug= (no ?realm=, no ?host=, no default fallback). Every miss
  # (no slug, unknown, lookup failure, nil/empty realm, inactive, no logo, flag off)
  # is the one Response.not_found/1 call (INV-5). The prefix comes from the tenant
  # found by slug inside TenantLogo.fetch/1 (INV-1). The slug is read through the
  # local `query` map, like the other parameters of this router.
  defp serve_logo(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with true <- TenantLogo.enabled?(),
         slug when is_binary(slug) <- non_empty(query["slug"]),
         {:ok, %Tenant{} = tenant} <- Identity.safe_get_tenant_by_slug(slug, "tenant-config-logo"),
         true <- TenantLogo.servable?(tenant),
         {:ok, logo} <- TenantLogo.fetch(tenant) do
      conn
      |> put_resp_header("content-type", logo.content_type)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("content-disposition", "inline")
      |> send_resp(200, logo.data)
    else
      _miss -> Response.not_found(conn)
    end
  end

  # ── GET /api/tenant-config (design §12) ───────────────────────────────────
  #
  # There is no error map by design: EVERY path returns 200 with either the
  # resolved config or the default config. See the moduledoc.

  defp handle_tenant_config(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    {realm_id, tenant, tenant_type, logo_slug} =
      resolve_realm(non_empty(Map.get(query, "realm")), non_empty(Map.get(query, "host")))

    body =
      realm_id
      |> config_map(tenant)
      |> Map.put("tenant_type", tenant_type)
      |> put_env_label()
      |> update_in(["branding"], &put_logo(&1, tenant, logo_slug))

    Response.ok(conn, body)
  end

  # T-1494: instance-global display label for the test-environment banner. Unset env var
  # -> no key (legacy banner); set -> trimmed, capped at 40 chars ("" turns the banner off).
  # Not a tenant attribute and not secret, so every branch returns the same value (INV-5).
  defp put_env_label(body) do
    case System.get_env("LETFLOW_ENV_LABEL") do
      nil -> body
      value -> Map.put(body, "env_label", value |> String.trim() |> String.slice(0, 40))
    end
  end

  # REQ-591: the uploaded logo replaces branding.logo_url only when the flag is on and
  # the tenant is servable with an upload; otherwise the branding is untouched. Reads
  # existence only, never the row's fields (INV-2).
  defp put_logo(branding, %Tenant{} = tenant, logo_slug) do
    case TenantLogo.public_path(tenant, logo_slug) do
      nil -> branding
      path -> Map.put(branding, "logo_url", path)
    end
  end

  defp put_logo(branding, nil, _logo_slug), do: branding

  # Step 1: ?realm=<slug>. A hit with a non-nil idp_realm_id wins outright and
  # the host branch is skipped. Returns {realm_id, tenant_or_nil, tenant_type, logo_slug} -- OQ-1
  # (design §4; logo_slug is the resolved tenant's slug on a slug or host hit, or bpm-default on
  # the default branches, REQ-591): the matched %Tenant{} (and therefore its already-loaded
  # :settings field) is threaded straight through to config_map/2 so the
  # branding helper never performs a second, independent DB lookup for the
  # same slug in the same request.
  defp resolve_realm(slug, host) when is_binary(slug) do
    case servable_tenant_by_slug(slug) do
      {:ok, tenant} ->
        {tenant.idp_realm_id, tenant, tenant_type_value(tenant), tenant.slug}

      :error ->
        resolve_realm(nil, host)
    end
  end

  # Steps 2 and 3: ?host=<hostname>, or neither parameter. A host hit resolves through the global
  # onboarding registry and uses the resolved tenant's realm, branding, type and logo slug. Every
  # miss or failure converges on the default tenant: the one named by LETFLOW_DEFAULT_TENANT_SLUG
  # when servable, else the constant default realm (GH #2936).
  #
  # tenant_type is nil on the default branches even though the default tenant is non-nil: only a
  # slug- or host-resolved branch may disclose a type (REQ-472, INV-5).
  defp resolve_realm(nil, host) when is_binary(host) do
    case servable_tenant_by_hostname(host) do
      {:ok, tenant} ->
        {tenant.idp_realm_id, tenant, tenant_type_value(tenant), tenant.slug}

      :error ->
        resolve_default_realm()
    end
  end

  defp resolve_realm(nil, _host_or_absent), do: resolve_default_realm()

  defp resolve_default_realm do
    with slug when is_binary(slug) <- non_empty(System.get_env("LETFLOW_DEFAULT_TENANT_SLUG")),
         {:ok, tenant} <- servable_tenant_by_slug(slug) do
      {tenant.idp_realm_id, tenant, nil, tenant.slug}
    else
      _unset_or_unservable -> {@default_realm, default_realm_tenant(), nil, @default_realm}
    end
  end

  # A tenant that may name its realm: active and with a non-empty idp_realm_id. The same guard
  # applies whether the public bootstrap request names a slug or a hostname. Never raises.
  defp servable_tenant_by_slug(slug) do
    slug
    |> Identity.safe_get_tenant_by_slug("tenant-config")
    |> servable_tenant()
  end

  defp servable_tenant_by_hostname(hostname) do
    hostname
    |> Identity.safe_get_tenant_by_hostname("tenant-config")
    |> servable_tenant()
  end

  defp servable_tenant({:ok, %Tenant{idp_realm_id: realm_id, status: :active} = tenant})
       when is_binary(realm_id) and realm_id != "",
       do: {:ok, tenant}

  defp servable_tenant(_miss_or_unservable), do: :error

  # Explicit named-key read, closed to the two known values (INV-2).
  defp tenant_type_value(%Tenant{tenant_type: type}) when type in ["test", "production"],
    do: type

  defp tenant_type_value(_other), do: nil

  # The tenant whose idp_realm_id is the default realm, or nil on a miss, a nil
  # realm or a lookup failure (then the branding is the platform default).
  defp default_realm_tenant do
    case Identity.safe_get_tenant_by_slug(@default_realm, "tenant-config") do
      {:ok, %Tenant{idp_realm_id: @default_realm} = tenant} -> tenant
      _miss_or_other_realm_or_error -> nil
    end
  end

  # The never-raise, INV-4-compliant lookup wrapper itself is shared with
  # Letflow.Routers.MobileTenantConfig via Letflow.Identity.safe_get_tenant_by_slug/2
  # (hoisted there per REVIEWER's REQ-124 rework -- see that function's @doc).

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value
  defp non_empty(_other), do: nil

  # ── Response allowlist (INV-2) ────────────────────────────────────────────

  # EXACTLY three keys here (tenant_type is added by the caller), hand-built,
  # never derived from %Tenant{} as a whole.
  # `tenant` is passed through only to read its :settings field via the
  # explicit-key branding helper below -- it is never `Map.from_struct/1`'d or
  # otherwise merged wholesale into the response. Adding a fourth top-level
  # key here (or a fourth branding sub-key) is a security change -- see the
  # moduledoc.
  defp config_map(realm_id, tenant) do
    %{
      "oidc_authority" => idp_base_url() <> "/realms/" <> realm_id,
      "client_id" => client_id(),
      "branding" => branding_map(tenant)
    }
  end

  # ── branding (REQ-281, design §4/§6) ──────────────────────────────────────
  #
  # `tenant` is either the %Tenant{} matched by resolve_realm/2's slug lookup,
  # or nil (unknown slug, malformed/absent slug, or a lookup failure -- all of
  # resolve_realm/2's "no tenant" branches converge on the same nil input
  # here, design §4 cases 3/4). Reads exactly the three named sub-keys off
  # tenant.settings by explicit Map.get/3 -- never iterates or merges
  # tenant.settings wholesale, so an out-of-allowlist key could not surface
  # here even if TenantSettings' write-time enforcement were somehow bypassed
  # (design §6, AC4).
  defp branding_map(%Tenant{settings: settings}), do: branding_from_settings(settings)
  defp branding_map(nil), do: branding_from_settings(nil)

  @doc """
  REQ-355 -- made `def` (was `defp`) so `Letflow.Modules.Exam.Certificate` can read
  the exact same three-key branding map this router's own `config/2` route
  exposes, rather than re-deriving branding from `Tenant.settings` a second
  way. Still the same allowlist-by-construction read this module's own
  moduledoc documents: exactly three named `Map.get/3` reads over
  `settings`, never a merge or `Map.from_struct/1`, so an out-of-allowlist
  key cannot surface here even if `TenantSettings`' write-time enforcement
  were bypassed. `settings` is a tenant's raw `Tenant.settings` map (or
  `nil`) -- callers outside this module still resolve their own `%Tenant{}`
  first (this function does no `Repo` call itself, matching the rest of
  this module's read-only, DB-call-free shape apart from `config/2`'s own
  lookup).
  """
  @spec branding_from_settings(settings :: map() | nil) :: %{
          String.t() => String.t() | nil | map()
        }
  def branding_from_settings(settings) when is_map(settings) do
    %{
      "app_name" => Map.get(settings, "app_name", @default_app_name),
      "logo_url" => Map.get(settings, "logo_url", @default_logo_url),
      "brand_colors" => brand_colors_from_settings(settings)
    }
  end

  def branding_from_settings(_nil_or_other) do
    %{
      "app_name" => @default_app_name,
      "logo_url" => @default_logo_url,
      "brand_colors" => @default_brand_colors
    }
  end

  # REQ-585: `brand_colors` is rebuilt from two named reads (`primary`,
  # `secondary`), never copied wholesale (INV-2). Nothing usable stored
  # (absent, non-map, empty, no binary value) -> the platform default.
  defp brand_colors_from_settings(settings) do
    case Map.get(settings, "brand_colors") do
      %{} = stored ->
        built =
          for key <- ["primary", "secondary"],
              value = Map.get(stored, key),
              is_binary(value),
              into: %{},
              do: {key, value}

        if built == %{}, do: @default_brand_colors, else: built

      _absent_or_malformed ->
        @default_brand_colors
    end
  end

  # Read at the point of use via System.get_env/1, never threaded through a
  # struct field and never logged (INV-4). None of these is secret material --
  # an OIDC authority URL and a public client id are values the browser must
  # learn in order to log in at all -- but the resolution style follows INV-4
  # regardless.
  defp idp_base_url do
    System.get_env("BPM_IDP_BASE_URL") || System.get_env("KEYCLOAK_BASE_URL") ||
      oidc_issuer_base() ||
      default_idp_base_url!()
  end

  # ISS-0720 §2.2/§2.3: the compiled-in localhost default is only ever
  # returned in dev/test (@allow_localhost_idp_fallback? true there). Every
  # other environment raises at call time rather than silently serving
  # localhost:8082 as a plausible-looking 200 -- see the design doc's
  # reckoning with this module's moduledoc "never error to the caller" rule,
  # which is scoped to the realm/tenant-resolution branch, not this one.
  defp default_idp_base_url! do
    if @allow_localhost_idp_fallback? do
      @default_idp_base_url
    else
      raise "Letflow.Routers.TenantConfig: no IDP base URL resolved -- " <>
              "BPM_IDP_BASE_URL and KEYCLOAK_BASE_URL are both unset and " <>
              ":letflow, :oidc, :keycloak_base_url is not configured. Refusing " <>
              "to fall back to the dev-only default (#{@default_idp_base_url}); " <>
              "set one of the above."
    end
  end

  # Derive the IDP base URL from the compiled :oidc config's
  # :keycloak_base_url, which is already a bare base URL (no /realms/...
  # suffix -- REQ-370 retired the old :issuer key, which was a full issuer
  # URL and needed the now-removed String.split/List.first stripping to
  # recover the bare host). See design lib/letflow/design/
  # iss0720-tenant-config-stale-issuer-key.md §1.
  defp oidc_issuer_base do
    Application.get_env(:letflow, :oidc, [])[:keycloak_base_url]
  end

  defp client_id, do: System.get_env("OIDC_CLIENT_ID") || @default_client_id
end
