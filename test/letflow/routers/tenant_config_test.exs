defmodule Letflow.Routers.TenantConfigTest do
  @moduledoc """
  Tests for REQ-281 (`lib/letflow/design/req281-tenant-config-branding-key.md`) —
  the new `branding` third key on `GET /api/tenant-config`. The pre-existing
  2-key coverage for this endpoint (oidc_authority/client_id shape,
  no-Authorization-header reachability) lives in
  `test/letflow/routers/req078_supporting_routes_test.exs`; this file covers
  only what REQ-281 added.

  Uses `Letflow.DataCase` (real Postgres, per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1) — every fixture here
  inserts into the *global* `tenants` table only (this endpoint never touches
  a per-tenant provisioned schema — see the module's own moduledoc, "No
  tenant scoping call"), so plain `Letflow.DataCase`'s rolled-back sandboxed
  transaction is sufficient and `async: true` is safe, mirroring
  `mobile_tenant_config_test.exs`'s own reasoning.

  ## Dispatch strategy

  Every test dispatches through `Letflow.Router` itself, not directly against
  `Letflow.Routers.TenantConfig`'s own `Plug.Router`, because the property
  under test includes that the route is reachable with no `Authorization`
  header through the real mount chain — mirrors
  `req078_supporting_routes_test.exs` AC1's own `GET /api/tenant-config` case
  and `mobile_tenant_config_test.exs`'s established convention for this
  endpoint family.
  """

  use Letflow.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.TenantSlugFixture

  @router_opts Letflow.Router.init([])

  @expected_keys ["branding", "client_id", "oidc_authority", "tenant_type"]
  @expected_branding_keys ["app_name", "brand_colors", "logo_url"]

  @default_app_name "Letflow"
  @default_logo_url nil
  @default_brand_colors %{"primary" => "#228be6"}

  defp call(conn), do: Letflow.Router.call(conn, @router_opts)

  defp unique_slug(prefix), do: TenantSlugFixture.unique_slug(prefix)

  defp unique_realm(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp insert_tenant!(attrs) do
    %Tenant{}
    |> Tenant.create_changeset(attrs, :disabled)
    |> Repo.insert!()
  end

  defp get_config(realm_slug \\ :none) do
    path =
      case realm_slug do
        :none -> "/api/tenant-config"
        slug -> "/api/tenant-config?realm=#{URI.encode_www_form(slug)}"
      end

    conn = conn(:get, path)
    assert get_req_header(conn, "authorization") == []

    conn = call(conn)
    {conn, Jason.decode!(conn.resp_body)}
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC1 — exactly 3 top-level keys, response map hand-built not derived from
  # %Tenant{}
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC1: exactly 3 top-level keys; response map hand-built, never derived from %Tenant{}" do
    test "GET /api/tenant-config returns exactly oidc_authority, client_id and branding" do
      {conn, body} = get_config()

      assert conn.status == 200
      assert Map.keys(body) |> Enum.sort() == @expected_keys
      assert Map.keys(body["branding"]) |> Enum.sort() == @expected_branding_keys
    end

    test "config_map/2 is the sole, hand-built constructor -- quoted verbatim from source" do
      source = File.read!("lib/letflow/routers/tenant_config.ex")

      assert source =~ "defp config_map(realm_id, tenant) do"
      assert source =~ "\"oidc_authority\" => idp_base_url() <> \"/realms/\" <> realm_id,"
      assert source =~ "\"client_id\" => client_id(),"
      assert source =~ "\"branding\" => branding_map(tenant)"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC2 — identical shape/status/key-presence across all 4 never-error paths
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC2: all four never-error paths produce byte-identical branding (and full response shape)" do
    test "resolvable slug with no branding stored, unknown slug, malformed slug, and a simulated DB failure all agree" do
      tenant_no_settings =
        insert_tenant!(%{
          slug: unique_slug("req281-no-settings"),
          display_name: "REQ-281 No Settings Tenant",
          idp_realm_id: unique_realm("req281-no-settings")
        })

      {conn_resolvable, body_resolvable} = get_config(tenant_no_settings.slug)
      {conn_unknown, body_unknown} = get_config(unique_slug("req281-unknown"))
      # A malformed/empty slug -- non_empty/1 normalizes "" to nil before any
      # lookup is attempted (same branch as no slug at all).
      {conn_malformed, body_malformed} = get_config("")

      # Simulated DB failure: Identity.safe_get_tenant_by_slug/2's rescue
      # clause is triggered by a slug value Postgrex cannot encode as a
      # query parameter (a null byte is invalid inside a Postgres text
      # value) -- exactly the mechanism identity_test.exs's own
      # "a raise inside get_tenant_by_slug/1 is swallowed" test exercises,
      # reached here through the real HTTP path via a URL-encoded null byte.
      {conn_db_failure, body_db_failure} = get_config(<<0>>)

      for conn <- [conn_resolvable, conn_unknown, conn_malformed, conn_db_failure] do
        assert conn.status == 200
      end

      for body <- [body_resolvable, body_unknown, body_malformed, body_db_failure] do
        assert Map.keys(body) |> Enum.sort() == @expected_keys
        assert Map.keys(body["branding"]) |> Enum.sort() == @expected_branding_keys
      end

      # The three "no tenant"/"no settings" paths are byte-identical to each
      # other in their branding block (design §4 cases 3/4).
      assert body_resolvable["branding"] == body_unknown["branding"]
      assert body_unknown["branding"] == body_malformed["branding"]
      assert body_malformed["branding"] == body_db_failure["branding"]

      assert body_resolvable["branding"] == %{
               "app_name" => @default_app_name,
               "logo_url" => @default_logo_url,
               "brand_colors" => @default_brand_colors
             }

      # Full response bodies agree too, apart from oidc_authority (which
      # legitimately differs by realm id) -- client_id and branding must be
      # identical across all four.
      assert body_resolvable["client_id"] == body_db_failure["client_id"]
      assert body_unknown["oidc_authority"] == body_malformed["oidc_authority"]
      assert body_unknown["oidc_authority"] == body_db_failure["oidc_authority"]
      assert body_unknown["oidc_authority"] =~ "/realms/bpm-default"
      refute body_resolvable["oidc_authority"] =~ "/realms/bpm-default"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # GH #2936 — a normal page load (?host= or no parameter) names the default
  # realm; it must carry that realm's tenant's saved branding.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "GH #2936: the host/no-parameter branch returns the default realm's own saved branding" do
    defp get_config_by_host(host),
      do: get_config_path("/api/tenant-config?host=#{URI.encode_www_form(host)}")

    defp get_config_path(path) do
      conn = call(conn(:get, path))
      {conn, Jason.decode!(conn.resp_body)}
    end

    defp save_default_tenant_colour!(colour) do
      assert {:ok, _} =
               Identity.update_tenant_settings("bpm-default", %{
                 "settings" => %{"brand_colors" => %{"primary" => colour}}
               })
    end

    test "?host= and no parameter return the saved colour of the default tenant" do
      save_default_tenant_colour!("#1864ab")

      {conn_host, body_host} = get_config_by_host("qa.example.invalid")
      {conn_none, body_none} = get_config()

      assert conn_host.status == 200 and conn_none.status == 200
      assert body_host["branding"]["brand_colors"] == %{"primary" => "#1864ab"}
      assert body_none["branding"]["brand_colors"] == %{"primary" => "#1864ab"}
      assert body_host["oidc_authority"] =~ "/realms/bpm-default"
      assert Map.keys(body_host) |> Enum.sort() == @expected_keys
    end

    test "an unknown ?realm= slug falls through to the same answer as no parameter" do
      save_default_tenant_colour!("#1864ab")

      {_, body_unknown} = get_config(unique_slug("gh2936-unknown"))
      {_, body_none} = get_config()

      assert body_unknown == body_none
    end

    test "cross-tenant: another tenant's saved branding is not exposed through the host branch" do
      other =
        insert_tenant!(%{
          slug: unique_slug("gh2936-other"),
          display_name: "GH 2936 Other Tenant",
          idp_realm_id: unique_realm("gh2936-other")
        })

      assert {:ok, _} =
               Identity.update_tenant_settings(other.slug, %{
                 "settings" => %{
                   "app_name" => "Other Co",
                   "brand_colors" => %{"primary" => "#c92a2a"}
                 }
               })

      {_, body_host} = get_config_by_host("qa.example.invalid")
      {_, body_none} = get_config()

      for body <- [body_host, body_none] do
        refute body["branding"]["app_name"] == "Other Co"
        refute body["branding"]["brand_colors"] == %{"primary" => "#c92a2a"}
        refute body["oidc_authority"] =~ other.idp_realm_id
      end

      # the other tenant's branding is still reachable only through its own slug
      {_, body_own} = get_config(other.slug)
      assert body_own["branding"]["app_name"] == "Other Co"
    end

    test "default tenant with no saved settings still answers the platform default branding" do
      {_, body} = get_config_by_host("qa.example.invalid")

      assert body["branding"] == %{
               "app_name" => @default_app_name,
               "logo_url" => @default_logo_url,
               "brand_colors" => @default_brand_colors
             }
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC3 — a tenant WITH stored branding gets its own values (per-sub-key
  # fallback), a tenant WITHOUT gets platform defaults -- proves the store is
  # actually read
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC3: stored settings are actually read; per-sub-key fallback, not all-or-nothing" do
    test "a tenant with a full stored branding block gets its own values for all three sub-keys" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req281-full-branding"),
          display_name: "REQ-281 Full Branding Tenant",
          idp_realm_id: unique_realm("req281-full-branding")
        })

      assert {:ok, _updated} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{
                   "app_name" => "Acme Corp",
                   "logo_url" => "https://acme.example.com/logo.png",
                   "brand_colors" => %{"primary" => "#1864AB"}
                 }
               })

      {conn, body} = get_config(tenant.slug)

      assert conn.status == 200

      assert body["branding"] == %{
               "app_name" => "Acme Corp",
               "logo_url" => "https://acme.example.com/logo.png",
               "brand_colors" => %{"primary" => "#1864AB"}
             }
    end

    test "a tenant with a PARTIAL stored settings map (only app_name) falls back independently for the other two sub-keys" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req281-partial-branding"),
          display_name: "REQ-281 Partial Branding Tenant",
          idp_realm_id: unique_realm("req281-partial-branding")
        })

      assert {:ok, _updated} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{"app_name" => "Only App Name Co"}
               })

      {conn, body} = get_config(tenant.slug)

      assert conn.status == 200

      assert body["branding"] == %{
               "app_name" => "Only App Name Co",
               "logo_url" => @default_logo_url,
               "brand_colors" => @default_brand_colors
             }
    end

    test "a tenant with NO stored settings at all (settings == nil) gets the full platform-default branding block" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req281-nil-settings"),
          display_name: "REQ-281 Nil Settings Tenant",
          idp_realm_id: unique_realm("req281-nil-settings")
        })

      assert tenant.settings == nil

      {conn, body} = get_config(tenant.slug)

      assert conn.status == 200

      assert body["branding"] == %{
               "app_name" => @default_app_name,
               "logo_url" => @default_logo_url,
               "brand_colors" => @default_brand_colors
             }
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC4 — closed allowlist: an out-of-allowlist value stored through whatever
  # path can reach the settings store does NOT appear in the response
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC4: closed allowlist -- an out-of-allowlist settings key can never reach the response" do
    test "Identity.update_tenant_settings/2 rejects an unrecognized top-level key outright (write-time enforcement, TenantSettings.cast/1)" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req281-allowlist-reject"),
          display_name: "REQ-281 Allowlist Reject Tenant",
          idp_realm_id: unique_realm("req281-allowlist-reject")
        })

      assert {:error, %Ecto.Changeset{} = changeset} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{"app_name" => "Fine", "secret_admin_token" => "leak-me"}
               })

      refute changeset.valid?

      # The value never even reaches storage -- reload and confirm settings
      # is unaffected (still nil, the update was rejected wholesale).
      reloaded = Repo.get_by!(Tenant, slug: tenant.slug)
      assert reloaded.settings == nil

      {conn, body} = get_config(tenant.slug)
      assert conn.status == 200
      refute body["branding"] |> Map.keys() |> Enum.member?("secret_admin_token")
      refute Jason.encode!(body) =~ "leak-me"
      refute Jason.encode!(body) =~ "secret_admin_token"
    end

    test "an out-of-allowlist inner key inside brand_colors is also rejected at write time (Tenant.settings_changeset/2)" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req281-brandcolors-reject"),
          display_name: "REQ-281 Brand Colors Reject Tenant",
          idp_realm_id: unique_realm("req281-brandcolors-reject")
        })

      assert {:error, %Ecto.Changeset{} = changeset} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{
                   "brand_colors" => %{"primary" => "#123456", "tertiary" => "#abcdef"}
                 }
               })

      refute changeset.valid?

      {conn, body} = get_config(tenant.slug)
      assert conn.status == 200
      refute Map.has_key?(body["branding"]["brand_colors"], "tertiary")
      refute Jason.encode!(body) =~ "tertiary"
    end

    test "REQ-585: both stored colours are returned; none stored is exactly the default" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req585-both"),
          display_name: "REQ-585 Both",
          idp_realm_id: unique_realm("req585-both")
        })

      {:ok, _} =
        Identity.update_tenant_settings(tenant.slug, %{
          "settings" => %{"brand_colors" => %{"primary" => "#1864AB", "secondary" => "#1971C2"}}
        })

      {_conn, body} = get_config(tenant.slug)

      assert body["branding"]["brand_colors"] == %{
               "primary" => "#1864AB",
               "secondary" => "#1971C2"
             }

      bare =
        insert_tenant!(%{
          slug: unique_slug("req585-none"),
          display_name: "REQ-585 None",
          idp_realm_id: unique_realm("req585-none")
        })

      {_conn, body} = get_config(bare.slug)
      assert body["branding"]["brand_colors"] == %{"primary" => "#228be6"}
    end

    test "REQ-585: branding_from_settings reads named keys only (bypassed extra key not served)" do
      branding =
        Letflow.Routers.TenantConfig.branding_from_settings(%{
          "brand_colors" => %{"secondary" => "#1971C2", "tertiary" => "#000000", "primary" => 5}
        })

      assert branding["brand_colors"] == %{"secondary" => "#1971C2"}

      assert Letflow.Routers.TenantConfig.branding_from_settings(%{"brand_colors" => %{}})[
               "brand_colors"
             ] == %{"primary" => "#228be6"}
    end

    test "REQ-595 P3: branding_from_settings returns the same three keys with signatory settings" do
      branding =
        Letflow.Routers.TenantConfig.branding_from_settings(%{
          "app_name" => "A",
          "signatory_name" => "N",
          "signatory_title" => "T"
        })

      assert Map.keys(branding) |> Enum.sort() == ["app_name", "brand_colors", "logo_url"]
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC5 — moduledoc paragraph updated (before/after quoted; the "before" text
  # must be GONE and the "after" text present)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC5: moduledoc's security-change paragraph names the third key and states the fourth-key rule" do
    test "moduledoc no longer says 'exactly two values' and now documents branding's 3 sub-keys and the 4th-key rule" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Letflow.Routers.TenantConfig)

      refute moduledoc =~ "It returns exactly two values"
      assert moduledoc =~ "It returns exactly three values"
      assert moduledoc =~ "`branding` block"
      assert moduledoc =~ "app_name"
      assert moduledoc =~ "logo_url"
      assert moduledoc =~ "brand_colors"
      assert moduledoc =~ "Letflow.Identity.Tenant"
      assert moduledoc =~ "Adding a fourth top-level key to this response"
      assert moduledoc =~ "fourth sub-key"
      assert moduledoc =~ "is a security change, not a feature."
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC7 — mobile_tenant_config.ex is untouched (also re-verified at the repo
  # level; this is a fast in-suite sanity check)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC7: mobile_tenant_config.ex is not this requirement's concern" do
    test "Letflow.Routers.MobileTenantConfig's key count is unaffected by the branding key added here" do
      assert Code.ensure_loaded?(Letflow.Routers.MobileTenantConfig)

      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Letflow.Routers.MobileTenantConfig)

      # REQ-418 (2026-09) legitimately grew this module's own allowlist from
      # five keys to six (added `client_id`) -- unrelated to this
      # requirement's branding key. Assert on that current, approved count
      # rather than a number this requirement never touched, so this guard
      # stays meaningful instead of drifting stale against REQ-418's own
      # reviewed change.
      refute moduledoc =~ "exactly five keys"
      assert moduledoc =~ "exactly six keys"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # ISS-0720 regression — oidc_issuer_base/0 must read :keycloak_base_url, not
  # the retired :issuer key (design lib/letflow/design/
  # iss0720-tenant-config-stale-issuer-key.md §1). Pre-fix, oidc_issuer_base/0
  # read `Application.get_env(:letflow, :oidc, [])[:issuer]`, which REQ-370
  # retired everywhere -- always nil -- so idp_base_url/0's chain fell through
  # to the compiled localhost default whenever BPM_IDP_BASE_URL/
  # KEYCLOAK_BASE_URL were unset. That is ISS-0719's live-QA symptom. This
  # test sets a distinctive, unmistakable :keycloak_base_url and asserts it
  # (not localhost) reaches oidc_authority.
  #
  # Global-state note: like test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs
  # (async: false, in its own module, for exactly this reason), this test
  # mutates the process-global `:letflow, :oidc` Application env. It is kept
  # in this async: true file rather than split into a dedicated async: false
  # module because no other test anywhere in the suite asserts on the
  # *literal host value* inside oidc_authority -- verified by grepping the
  # full test/ tree for "localhost" combined with oidc_authority/
  # keycloak_base_url assertions (none found); every other caller of
  # GET /api/tenant-config only asserts on the realm-id suffix
  # (`/realms/<slug>`) or on shape (`is_binary/1`, key presence), which this
  # test's temporary host swap does not disturb. on_exit/1 restores the
  # original :oidc config keyword list unconditionally (even on test
  # failure), so config/test.exs's literal keycloak_base_url is never left
  # mutated for a later test.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "ISS-0720: oidc_authority reflects configured :keycloak_base_url, not the retired :issuer key" do
    test "GET /api/tenant-config's oidc_authority is built from :letflow, :oidc, :keycloak_base_url when BPM_IDP_BASE_URL/KEYCLOAK_BASE_URL are unset" do
      # Precondition: confirm the two env vars idp_base_url/0 checks BEFORE
      # :keycloak_base_url are actually unset in this test run -- if either
      # were set it would win over :keycloak_base_url and this test would
      # stop discriminating the bug (it would pass identically pre- and
      # post-fix).
      refute System.get_env("BPM_IDP_BASE_URL")
      refute System.get_env("KEYCLOAK_BASE_URL")

      original_oidc_config = Application.get_env(:letflow, :oidc, [])

      on_exit(fn ->
        Application.put_env(:letflow, :oidc, original_oidc_config)
      end)

      Application.put_env(
        :letflow,
        :oidc,
        Keyword.put(
          original_oidc_config,
          :keycloak_base_url,
          "https://iss0720-regression-test-authority.example"
        )
      )

      {conn, body} = get_config()

      assert conn.status == 200

      assert String.starts_with?(
               body["oidc_authority"],
               "https://iss0720-regression-test-authority.example/realms/"
             )

      refute body["oidc_authority"] =~ "localhost"
    end
  end
end
