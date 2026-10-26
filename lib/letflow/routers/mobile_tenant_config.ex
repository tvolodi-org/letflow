defmodule Letflow.Routers.MobileTenantConfig do
  @moduledoc """
  Public mobile-bootstrap sub-router (REQ-124, design
  `lib/letflow/design/req124-mobile-tenant-config.md`), gate for MOB-2
  (`docs/mobile/requirements.md`) — the single blocking dependency for the
  entire mobile tier per `docs/mobile/build-order.md` phase M-0.

  | Handler | Method/path                    | Delegate                                | Auth     | Response |
  |---------|---------------------------------|------------------------------------------|----------|----------|
  | config  | `GET /api/mobile/tenant-config` | `Letflow.Identity.get_tenant_by_slug/1`  | **none** | always 200, `{realm_url, locales, default_locale, branding, environment_kind, client_id}` |

  This is a **second, independent** module from `Letflow.Routers.TenantConfig`
  (REQ-078), not a discriminator on its route — see design §1 for why: the
  existing module's 2-key allowlist and this module's 6-key allowlist are each
  easier to audit in isolation than one handler branching between two response
  contracts. `Letflow.Routers.TenantConfig`'s existing route, behavior and
  response shape are **untouched** by this module.

  ## Why this is mounted on `Letflow.Router`, NOT in `Letflow.Plugs.ApiPipeline`

  This route's caller is the mobile app **before it holds any token** —
  resolving tenant identity and fetching config is a precondition for
  starting the OIDC Authorization-Code+PKCE flow, so a token cannot exist
  yet. `Letflow.Plugs.AuthPipeline`, read in full, has **no public-path
  allowlist and no bypass/skip option** — its `call/2` `with` chain always
  requires `extract_bearer_token/1` to succeed. Mounting this route inside
  `Letflow.Plugs.ApiPipeline` (and therefore behind `AuthPipeline`) would make
  it unreachable by the only caller that needs it — exactly the defect
  `Letflow.Routers.TenantConfig`'s moduledoc already documents for the web
  SPA case. This module restates that reasoning locally rather than only
  cross-referencing REQ-078's, since a reader of this module alone must not
  have to chase a second file to find load-bearing reasoning.

  So this module is forwarded from **`Letflow.Router`** —
  `forward("/api/mobile/tenant-config", to: Letflow.Routers.MobileTenantConfig)`,
  declared immediately after the existing `/api/tenant-config` forward and
  still before the `/api/v1` forward, exactly mirroring
  `Letflow.Routers.TenantConfig`'s mount. `Letflow.Plugs.Cors` is mounted on
  `Letflow.Router` itself, ahead of `plug(:match)`, and is origin- not
  path-based, so it covers this route automatically with no change needed.

  ## The never-error rule is LOAD-BEARING here too

  Every path — resolvable slug, unknown slug, missing `?slug=` param, DB
  error/exception — returns **200** with the full 6-field body. There is no
  `404`, no partial body, no absent field:

    1. **Availability.** The mobile app cannot get past its bootstrap screen
       without a config; a `404`/`500` here strands the user before they ever
       reach a login screen — the one failure mode MOB-2 exists to prevent.
    2. **Anti-enumeration.** A miss (`{:error, :not_found}`), a deactivated tenant (GH #3252), a slug with no
       `idp_realm_id` set, a lookup exception, and a missing `?slug=` param
       all produce the byte-identical default body. A caller with a wordlist
       cannot distinguish "this slug does not exist" from "this slug exists
       but has no realm bound" from "the DB call failed" — none of them
       functions as an existence oracle.

  A caller can also infer, from a non-default `branding`, `locales` or
  `default_locale` value, that a resolved slug belongs to a tenant that
  configured its own settings — this is the same bounded, unavoidable
  inference this endpoint already makes via a non-default `realm_url`
  (record 0020's anti-enumeration argument, restated here rather than
  assumed carried over from an earlier version of this text): telling the
  mobile app which realm, branding, and locale defaults apply to a tenant is
  this endpoint's entire purpose, and every one of those values is exactly
  what any user of that tenant already sees at their own login/bootstrap
  screen — none of them is information withheld from a legitimate user of
  the tenant in question. What remains invariant is not "four of five fields
  never vary" (that claim no longer holds after REQ-282) but the
  **never-error guarantee itself**: an unknown slug, a lookup failure, and a
  missing `?slug=` parameter are structurally indistinguishable from each
  other and from "a resolved tenant that never configured any settings" —
  all four converge on the identical platform-default values for `branding`,
  `locales`, and `default_locale`, because all four route through the same
  `settings = nil` input to the same fallback helpers (see below). Only a
  genuine settings hit — a resolvable slug bound to a tenant that has
  written its own `app_name`/`logo_url`/`brand_colors`/`locales`/
  `default_locale` — can ever produce a non-default value for these three
  fields, exactly mirroring how only a resolvable slug with a bound realm
  can ever produce a non-default `realm_url`. `environment_kind` is the one
  field that is still, and remains, byte-identical across every branch by
  construction (env-derived, not tenant-derived, not touched by this
  requirement), and `client_id` joins it as a second such field (REQ-418) —
  resolved with no tenant input whatsoever, a stronger invariance than the
  three per-tenant fields' same-if-no-settings-stored convergence.

  ## What this endpoint discloses, and what it must never disclose

  It returns exactly six keys: `realm_url`, `locales`, `default_locale`,
  `branding`, `environment_kind`, `client_id`. All are values the mobile app
  must learn before it can even start authenticating, and none identifies the
  tenant beyond the realm URL a user of that tenant already sees at login.
  The response map is hand-built with exactly these six keys and is **never**
  derived from `%Letflow.Identity.Tenant{}` (INV-2) — it must never return a
  tenant id, slug, display name, status, user count, or any other tenant
  attribute.

  `client_id` (REQ-418) is added as a sixth disclosed value. It is safe to
  disclose unauthenticated for three reasons: (i) an OAuth public-client
  identifier is not a secret (RFC 6749 §2.2 — a public client has no
  credential to protect), and `Letflow.Routers.TenantConfig` already
  publishes its own equivalent `client_id` unauthenticated for the web SPA;
  (ii) the value is platform-global, not tenant-derived — byte-identical on
  every never-error branch (resolvable slug, unknown slug, missing `?slug=`,
  lookup failure), adding zero enumeration signal, the same status
  `environment_kind` already has; (iii) the alternative — compiling the
  client id into the mobile app — would work today but freezes it into every
  shipped build, so a deployment whose realm registers the client under a
  different name, or a later rename, would require an app store release;
  serving it from this endpoint keeps the platform's existing "one
  tenant-agnostic build" constraint (the same constraint that makes this
  whole endpoint exist) without that release coupling. This does **not**
  support a per-tenant client name — the value is platform-global by design
  (point ii) — a per-tenant client id would be a new requirement with its own
  disclosure analysis.

  **Adding a seventh key to this response is a security change, not
  a feature.**

  ## locales / default_locale / branding are per-tenant; environment_kind remains global

  `Letflow.Identity.Tenant`'s `:settings` column (`Letflow.Identity.TenantSettings`,
  REQ-280) stores a tenant's own `app_name`, `logo_url`, `brand_colors`,
  `locales` and `default_locale`, written through
  `Letflow.Identity.update_tenant_settings/2` and validated at write time by
  `Tenant.settings_changeset/2`. As of REQ-282, this endpoint reads that
  column: `locales`, `default_locale` and `branding` each resolve per
  sub-key from the resolved tenant's stored `settings` where set, and from a
  platform default (`@default_locales`, `@default_locale`, `@default_branding`)
  where not. A tenant that never wrote any settings, an unresolvable slug, a
  lookup failure, and a missing `?slug=` parameter all still produce the
  platform-default values for these three fields — see the never-error
  section above for why that convergence is exact, not approximate.
  `environment_kind` remains the one field genuinely sourced from application
  config/env (`LETFLOW_ENVIRONMENT_KIND`), unrelated to any tenant, unchanged
  by this requirement — it is global in the sense the whole paragraph used to
  claim of all four fields; the other three no longer are.

  ## Slug resolution — `?slug=` only, no `?host=` branch (design OQ-2)

  Unlike `Letflow.Routers.TenantConfig`'s web-SPA `?host=` fallback (used
  when no slug is known yet), MOB-2's mobile callers always resolve a slug
  (deep-link subdomain or manual entry) before calling this endpoint. This
  route therefore accepts a single `?slug=<tenant_slug>` parameter and has no
  `?host=` parameter or branch. If a future requirement needs server-side
  host resolution for mobile, that is a new parameter on this module, not a
  retrofit of `Letflow.Routers.TenantConfig`'s `?host=` handling — Letflow
  still has no host->tenant binding of any kind.

  ## No trace id on this endpoint

  Same as `Letflow.Routers.TenantConfig`: mounted outside
  `Letflow.Plugs.ApiPipeline`, so `Letflow.Api.Context.assign_trace_id/1`
  never runs and `conn.assigns[:trace_id]` is absent. Harmless — this module
  never emits a problem document.

  ## No tenant scoping call, deliberately

  Unauthenticated by design, reads only the **global** `tenants` table (via
  `Letflow.Identity.get_tenant_by_slug/1`) — outside every per-tenant schema,
  so there is no `:prefix` to derive and INV-1 does not apply.
  """

  use Plug.Router

  alias Letflow.Api.Response
  alias Letflow.Identity
  alias Letflow.Identity.Tenant

  # Ported in the same spirit as Letflow.Routers.TenantConfig's own
  # @default_idp_base_url/@default_realm -- adjustable placeholders (design
  # OQ-1/OQ-3), not load-bearing values.
  @default_idp_base_url "http://localhost:8081"
  @default_realm "bpm-default"
  @default_locales ["en"]
  @default_locale "en"
  @default_branding %{
    "app_name" => "Letflow",
    "logo_url" => nil,
    "primary_color" => "#228be6"
  }
  @default_environment_kind "development"
  @default_client_id "letflow-mobile"

  plug(:match)
  plug(:dispatch)

  get "/" do
    handle_mobile_tenant_config(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── GET /api/mobile/tenant-config (design §3) ─────────────────────────────
  #
  # There is no error map by design: EVERY path returns 200 with the full
  # 6-field body. See the moduledoc's never-error rule.

  @spec handle_mobile_tenant_config(conn :: Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_mobile_tenant_config(conn) do
    conn = fetch_query_params(conn)
    slug = non_empty(Map.get(conn.query_params, "slug"))

    {realm_id, settings} = resolve_tenant_config(slug)

    Response.ok(conn, mobile_config_map(realm_id, settings))
  end

  # Keyed only on ?slug= -- no ?host= branch (design OQ-2). A hit with a
  # non-nil, non-empty idp_realm_id wins and its (possibly nil) :settings is
  # threaded straight through, so mobile_config_map/2's fallback helpers never
  # perform a second, independent DB lookup for the same slug in the same
  # request. Every other case (miss, nil/empty realm, deactivated tenant, lookup error,
  # missing/absent slug) falls through to the default realm with settings
  # forced to nil (design §2 OQ-A resolution: a tenant found but with no
  # usable realm is treated as "not usably provisioned" across the board,
  # not just for realm_url, keeping the resolved-or-not distinction a single
  # boolean rather than split per-field).
  @spec resolve_tenant_config(slug :: String.t() | nil) ::
          {realm_id :: String.t(), settings :: map() | nil}
  defp resolve_tenant_config(nil), do: {@default_realm, nil}

  defp resolve_tenant_config(slug) when is_binary(slug) do
    case Identity.safe_get_tenant_by_slug(slug, "mobile-tenant-config") do
      {:ok, %Tenant{idp_realm_id: realm_id, settings: settings, status: status}}
      when is_binary(realm_id) and realm_id != "" and status != :inactive ->
        {realm_id, settings}

      _miss_or_nil_realm_or_error ->
        {@default_realm, nil}
    end
  end

  # The never-raise, INV-4-compliant lookup wrapper itself is shared with
  # Letflow.Routers.TenantConfig via Letflow.Identity.safe_get_tenant_by_slug/2
  # (hoisted there per REVIEWER's REQ-124 rework -- see that function's @doc).

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value
  defp non_empty(_other), do: nil

  # ── Response allowlist (INV-2) ────────────────────────────────────────────

  # EXACTLY six keys, hand-built, never derived from %Tenant{}. Adding a
  # seventh key here is a security change -- see the moduledoc.
  @doc """
  Builds the hand-built 6-key mobile tenant-config response map for the
  given (already-resolved) `realm_id` and the resolved tenant's `settings`
  (or `nil`). Never derived from `%Letflow.Identity.Tenant{}` or
  `Map.from_struct/1` -- see the moduledoc's INV-2 allowlist statement.
  `locales`, `default_locale` and `branding` each resolve per sub-key from
  `settings` where set and from a platform default otherwise (REQ-282);
  `environment_kind` and `client_id` (REQ-418) are env-derived and remain the
  two byte-identical-by-construction, platform-global constants.
  """
  @spec mobile_config_map(realm_id :: String.t(), settings :: map() | nil) :: %{
          required(String.t()) => String.t() | [String.t()] | map()
        }
  def mobile_config_map(realm_id, settings) do
    %{
      "realm_url" => idp_base_url() <> "/realms/" <> realm_id,
      "locales" => locales_from_settings(settings),
      "default_locale" => default_locale_from_settings(settings),
      "branding" => branding_from_settings(settings),
      "environment_kind" => environment_kind(),
      "client_id" => client_id()
    }
  end

  # ── Per-key fallback helpers (REQ-282, design §2/§3) ──────────────────────
  #
  # Three independently-varying keys, three separate helpers -- not one
  # combined helper returning a 3-tuple -- so a tenant with stored `locales`
  # but no `branding` gets its own `locales` and the platform-default
  # `branding`, and vice versa (per-sub-key, not all-or-nothing, fallback
  # discipline). `settings == nil` (tenant absent/miss/error/no-settings-ever-
  # written) makes every helper return its full platform-default value.

  @spec branding_from_settings(settings :: map() | nil) :: %{
          required(String.t()) => String.t() | nil | map()
        }
  defp branding_from_settings(settings) when is_map(settings) do
    %{
      "app_name" => Map.get(settings, "app_name", @default_branding["app_name"]),
      "logo_url" => Map.get(settings, "logo_url", @default_branding["logo_url"]),
      "primary_color" => primary_color_from_settings(settings)
    }
  end

  defp branding_from_settings(_nil_or_other), do: @default_branding

  # brand_colors is stored nested (REQ-280 shape: %{"primary" => ...}), but
  # this endpoint's disclosed branding shape stays FLAT (design §3) -- an
  # explicit, named-key translation at the read boundary, not a structural
  # copy of the stored shape. Missing either level (no "brand_colors" key at
  # all, or a brand_colors map without "primary") falls through to the flat
  # default in the same expression -- no partial nil leaking into
  # primary_color in place of a string.
  defp primary_color_from_settings(settings) do
    case Map.get(settings, "brand_colors") do
      %{"primary" => primary} when is_binary(primary) -> primary
      _absent_or_incomplete -> @default_branding["primary_color"]
    end
  end

  @spec locales_from_settings(settings :: map() | nil) :: [String.t()]
  defp locales_from_settings(settings) when is_map(settings),
    do: Map.get(settings, "locales", @default_locales)

  defp locales_from_settings(_nil_or_other), do: @default_locales

  @spec default_locale_from_settings(settings :: map() | nil) :: String.t()
  defp default_locale_from_settings(settings) when is_map(settings),
    do: Map.get(settings, "default_locale", @default_locale)

  defp default_locale_from_settings(_nil_or_other), do: @default_locale

  # Read at the point of use via System.get_env/1, never threaded through a
  # struct field and never logged (INV-4). Neither is secret material -- an
  # OIDC realm URL, locale defaults and an environment label are all values
  # the mobile app must learn before it can authenticate -- but the
  # resolution style follows INV-4 regardless.
  @spec idp_base_url() :: String.t()
  defp idp_base_url do
    System.get_env("BPM_IDP_BASE_URL") || System.get_env("KEYCLOAK_BASE_URL") ||
      @default_idp_base_url
  end

  @spec environment_kind() :: String.t()
  defp environment_kind,
    do: System.get_env("LETFLOW_ENVIRONMENT_KIND") || @default_environment_kind

  # Same env-then-constant resolution shape as Letflow.Routers.TenantConfig's
  # own client_id/0 (lib/letflow/routers/tenant_config.ex:361,
  # OIDC_CLIENT_ID || "letflow-web") but this module's own, independent env
  # var and default -- deliberately NOT shared/reused (mirrors this module's
  # own @default_branding independence from that module's branding defaults),
  # so a deployment can override the web client id without accidentally
  # overriding the mobile one. Read at point of use (INV-4 style, same as
  # idp_base_url/0 and environment_kind/0 above), never threaded through a
  # struct field, never logged. Not a secret (RFC 6749 §2.2 -- a public
  # client has no credential to protect) but the resolution style is
  # followed regardless (design req418-mobile-oidc-client.md §2.1).
  @spec client_id() :: String.t()
  defp client_id,
    do: System.get_env("MOBILE_OIDC_CLIENT_ID") || @default_client_id
end
