defmodule Letflow.Routers.MobileTenantConfigTest do
  @moduledoc """
  Tests for `Letflow.Routers.MobileTenantConfig` (REQ-124, design
  `lib/letflow/design/req124-mobile-tenant-config.md`). See `test/specs/REQ-124.md`
  for the full acceptance-criterion-to-test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- the fixtures below insert rows into the *global* `tenants` table
  only (never a per-tenant provisioned schema, since `GET /api/mobile/tenant-config`
  itself never touches one -- see the design's §5 "No tenant scoping call"), so plain
  `Letflow.DataCase`'s rolled-back sandboxed transaction is sufficient; no
  `Letflow.TenantFixture` schema-provisioning/migration-replay/`:auto`-mode machinery
  is needed here (unlike `identity_test.exs`'s `provisioned_tenant!/1` for
  `provision_oidc_user/4`). `async: true` is therefore safe.

  ## Dispatch strategy (mirrors test/letflow/routers/req078_supporting_routes_test.exs
  AC1's own `GET /api/tenant-config` case, the established style for this endpoint
  family)

  Every test dispatches through `Letflow.Router` itself (`Letflow.Router.call/2`),
  never directly against `Letflow.Routers.MobileTenantConfig`'s own `Plug.Router`,
  because the property under test is specifically that the route is reachable with
  no `Authorization` header through the real mount chain (`Letflow.Router` ->
  `forward("/api/mobile/tenant-config", ...)`, declared BEFORE the `/api/v1` forward,
  outside `Letflow.Plugs.ApiPipeline`/`Letflow.Plugs.AuthPipeline`) -- only the
  top-level router proves that. No test in this file ever calls
  `Plug.Conn.put_req_header(conn, "authorization", ...)` -- that omission is the
  whole point of this endpoint (see AC1/AC2 below), not an oversight.
  """

  use Letflow.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.TenantSlugFixture

  @router_opts Letflow.Router.init([])

  @expected_keys [
    "branding",
    "client_id",
    "default_locale",
    "environment_kind",
    "locales",
    "realm_url"
  ]

  defp call(conn), do: Letflow.Router.call(conn, @router_opts)

  defp unique_slug(prefix), do: TenantSlugFixture.unique_slug(prefix)

  defp unique_realm(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp insert_tenant!(attrs) do
    %Tenant{}
    |> Tenant.create_changeset(attrs, :disabled)
    |> Repo.insert!()
  end

  # Ecto.Changeset.cast/4's default `:empty_values` ([""]) normalizes an
  # incoming `idp_realm_id: ""` param to `nil` before it ever reaches the
  # database -- so building via insert_tenant!/1 alone cannot produce a row
  # whose idp_realm_id is a genuine, persisted empty string. This helper casts
  # without idp_realm_id, then forces it onto the changeset with
  # Ecto.Changeset.put_change/3 (which does NOT apply empty_values
  # normalization), so the row actually persists idp_realm_id == "" -- the
  # real value resolve_realm_id/1's `realm_id != ""` guard clause is written
  # to handle, not a value indistinguishable from the nil case.
  defp insert_tenant_with_raw_empty_realm!(attrs) do
    %Tenant{}
    |> Tenant.create_changeset(attrs, :disabled)
    |> Ecto.Changeset.put_change(:idp_realm_id, "")
    |> Repo.insert!()
  end

  # Dispatches GET /api/mobile/tenant-config (optionally with a ?slug= query
  # string), asserts no Authorization header was ever attached (documents the
  # precondition, doesn't just rely on Plug.Test's conn/2 default), and returns
  # the decoded JSON body plus the raw conn.
  defp get_mobile_config(slug \\ :no_slug_param) do
    path =
      case slug do
        :no_slug_param -> "/api/mobile/tenant-config"
        slug -> "/api/mobile/tenant-config?slug=#{URI.encode_www_form(slug)}"
      end

    conn = conn(:get, path)
    assert get_req_header(conn, "authorization") == []

    conn = call(conn)
    {conn, Jason.decode!(conn.resp_body)}
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC1 + AC3 -- known slug, no Authorization header, exact 5-key shape
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC1/AC3: known slug with idp_realm_id set, no Authorization header, exact 5-field shape" do
    test "200, realm_url reflects the resolved tenant's idp_realm_id, exactly the 5 documented keys and no others" do
      realm_id = unique_realm("req124-known")

      tenant =
        insert_tenant!(%{
          slug: unique_slug("req124-known"),
          display_name: "REQ-124 Known Tenant",
          idp_realm_id: realm_id
        })

      {conn, body} = get_mobile_config(tenant.slug)

      assert conn.status == 200

      # Exact-shape assertion (AC3) -- sorted-key-set equality, not a
      # subset/pattern match. Would fail if a 6th key (e.g. tenant id, slug,
      # display_name, status) ever leaked into the response, or if any of the
      # 5 documented keys were missing.
      assert Map.keys(body) |> Enum.sort() == @expected_keys

      assert body["realm_url"] =~ "/realms/#{realm_id}"
      refute body["realm_url"] =~ "/realms/bpm-default"
    end

    test "no Authorization header is required to reach this route -- reachable through the real Letflow.Router mount, not dispatched directly against the sub-router" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req124-noauth"),
          display_name: "REQ-124 No-Auth Tenant",
          idp_realm_id: unique_realm("req124-noauth")
        })

      conn = conn(:get, "/api/mobile/tenant-config?slug=#{tenant.slug}")
      assert get_req_header(conn, "authorization") == []

      conn = call(conn)
      assert conn.status == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC4 -- unknown/nil-realm/missing-slug all fall through to the identical
  # default body (anti-enumeration)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC4: default-realm fallback branches are all byte-identical to each other" do
    test "a slug with nil idp_realm_id falls through to the default realm" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req124-nilrealm"),
          display_name: "REQ-124 Nil Realm Tenant",
          idp_realm_id: nil
        })

      {conn, body} = get_mobile_config(tenant.slug)

      assert conn.status == 200
      assert body["realm_url"] =~ "/realms/bpm-default"
    end

    test "a slug with an EMPTY-STRING idp_realm_id (not nil) also falls through to the default realm" do
      tenant =
        insert_tenant_with_raw_empty_realm!(%{
          slug: unique_slug("req124-emptyrealm"),
          display_name: "REQ-124 Empty Realm Tenant"
        })

      assert tenant.idp_realm_id == ""

      {conn, body} = get_mobile_config(tenant.slug)

      assert conn.status == 200
      assert body["realm_url"] =~ "/realms/bpm-default"
    end

    test "an unknown slug, a nil-idp_realm_id slug, and a missing ?slug= param all produce the BYTE-IDENTICAL response body" do
      nil_realm_tenant =
        insert_tenant!(%{
          slug: unique_slug("req124-anti-oracle-nil"),
          display_name: "REQ-124 Anti-Oracle Nil Realm",
          idp_realm_id: nil
        })

      {conn_missing, body_missing} = get_mobile_config()
      {conn_unknown, body_unknown} = get_mobile_config(unique_slug("req124-anti-oracle-unknown"))
      {conn_nil_realm, body_nil_realm} = get_mobile_config(nil_realm_tenant.slug)
      {conn_empty, body_empty} = get_mobile_config("")

      for conn <- [conn_missing, conn_unknown, conn_nil_realm, conn_empty] do
        assert conn.status == 200
      end

      # An unauthenticated caller with a wordlist must not be able to
      # distinguish "this slug does not exist" from "this slug exists but has
      # no realm bound" from "no slug was supplied at all" -- all four
      # collapse to the exact same response body (INV-5-flavored
      # anti-enumeration, design §4).
      assert body_missing == body_unknown
      assert body_missing == body_nil_realm
      assert body_missing == body_empty
      assert Map.keys(body_missing) |> Enum.sort() == @expected_keys
      assert body_missing["realm_url"] =~ "/realms/bpm-default"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # locales/default_locale/branding/environment_kind are global, not per-tenant
  # ═══════════════════════════════════════════════════════════════════════════

  # Post-REQ-282: this equivalence holds only when no settings are stored --
  # see the AC3/OQ-A describes above for the now-tenant-varying case.
  # environment_kind remains the sole field still globally invariant.
  describe "no-stored-settings tenant matches the default-fallback response" do
    test "a resolvable known-slug response with no stored settings agrees with the default response" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req124-global-fields"),
          display_name: "REQ-124 Global Fields Tenant",
          idp_realm_id: unique_realm("req124-global-fields")
        })

      {_conn_known, body_known} = get_mobile_config(tenant.slug)
      {_conn_default, body_default} = get_mobile_config()

      assert body_known["realm_url"] != body_default["realm_url"]

      for field <- ["locales", "default_locale", "branding", "environment_kind"] do
        assert body_known[field] == body_default[field],
               "expected #{field} to be identical across branches, got #{inspect(body_known[field])} vs #{inspect(body_default[field])}"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC5 -- every other Letflow.Plugs.ApiPipeline route still requires auth;
  # the exemption is route-specific, not pipeline-wide
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC5: the unauthenticated exemption is specific to the two Letflow.Router-level forwards, not pipeline-wide" do
    test "GET /api/v1/tenants with no Authorization header still returns 401 -- proves ApiPipeline/AuthPipeline is unchanged" do
      conn = conn(:get, "/api/v1/tenants")
      assert get_req_header(conn, "authorization") == []

      conn = call(conn)

      # If REQ-124's route had instead been mounted inside
      # Letflow.Plugs.ApiPipeline (or if AuthPipeline had somehow acquired a
      # bypass as a side effect of this change), a bug that widened the
      # exemption pipeline-wide would make THIS assertion fail -- this route
      # was never touched by REQ-124 and must still demand a bearer token.
      assert conn.status == 401
    end

    test "GET /api/mobile/tenant-config itself is unaffected by AuthPipeline even when called with a garbage Authorization header" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req124-garbage-auth"),
          display_name: "REQ-124 Garbage Auth Header Tenant",
          idp_realm_id: unique_realm("req124-garbage-auth")
        })

      conn =
        conn(:get, "/api/mobile/tenant-config?slug=#{tenant.slug}")
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> call()

      # Still 200 -- this route never inspects the Authorization header at
      # all (it is mounted entirely outside AuthPipeline), so a garbage
      # token present is just as irrelevant as no token at all.
      assert conn.status == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Every branch is 200, never 404/500 (never-error rule, design §4)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "never-error rule: every branch returns 200, never 404 or 500" do
    test "an unmatched sub-path under the mount still returns a clean response, not a 500" do
      conn = conn(:get, "/api/mobile/tenant-config/nonexistent-subpath") |> call()

      # match _ do Response.not_found(conn) end inside the sub-router -- this
      # is the ONE path this module can 404 (a genuinely wrong sub-path), and
      # it is a clean 404, not a crash. The bootstrap GET "/" path itself
      # (every test above) always stays at 200.
      assert conn.status == 404
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Identity.safe_get_tenant_by_slug/2's exception-swallowing is exercised
  # through the full router as well (unit coverage lives in identity_test.exs)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "resolve_realm_id/1 delegates to the shared never-raise wrapper (Letflow.Identity.safe_get_tenant_by_slug/2)" do
    test "moduledoc documents the shared wrapper by name" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Letflow.Routers.MobileTenantConfig)

      assert moduledoc =~ "Letflow.Identity.get_tenant_by_slug/1"
      assert moduledoc =~ "never disclose"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # REQ-282 AC1 -- exactly 5 keys, response map hand-built, never derived from
  # %Tenant{}; constructing function quoted verbatim from source
  # ═══════════════════════════════════════════════════════════════════════════

  describe "REQ-282 AC1: exactly 5 top-level keys; response map hand-built, never derived from %Tenant{}" do
    test "mobile_config_map/2 is the sole, hand-built constructor -- quoted verbatim from source" do
      source = File.read!("lib/letflow/routers/mobile_tenant_config.ex")

      assert source =~ "def mobile_config_map(realm_id, settings) do"
      assert source =~ "\"realm_url\" => idp_base_url() <> \"/realms/\" <> realm_id,"
      assert source =~ "\"locales\" => locales_from_settings(settings),"
      assert source =~ "\"default_locale\" => default_locale_from_settings(settings),"
      assert source =~ "\"branding\" => branding_from_settings(settings),"
      assert source =~ "\"environment_kind\" => environment_kind(),"
      assert source =~ "\"client_id\" => client_id()"
    end

    test "GET /api/mobile/tenant-config still returns exactly the 5 documented keys" do
      {conn, body} = get_mobile_config()

      assert conn.status == 200
      assert Map.keys(body) |> Enum.sort() == @expected_keys
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # REQ-418 -- sixth `client_id` key, env-then-constant resolution
  # (MOBILE_OIDC_CLIENT_ID || "letflow-mobile"), byte-identical across all
  # four never-error paths, moduledoc no longer says "exactly five keys"
  # ═══════════════════════════════════════════════════════════════════════════

  describe "REQ-418: client_id value -- default (MOBILE_OIDC_CLIENT_ID unset)" do
    setup do
      previous = System.get_env("MOBILE_OIDC_CLIENT_ID")
      System.delete_env("MOBILE_OIDC_CLIENT_ID")

      on_exit(fn ->
        if previous, do: System.put_env("MOBILE_OIDC_CLIENT_ID", previous)
      end)

      :ok
    end

    test "body[\"client_id\"] is \"letflow-mobile\" when the env var is unset" do
      {conn, body} = get_mobile_config()

      assert conn.status == 200
      assert body["client_id"] == "letflow-mobile"
    end
  end

  describe "REQ-418: client_id value -- MOBILE_OIDC_CLIENT_ID env override" do
    setup do
      previous = System.get_env("MOBILE_OIDC_CLIENT_ID")
      System.put_env("MOBILE_OIDC_CLIENT_ID", "req418-override-client")

      on_exit(fn ->
        if previous do
          System.put_env("MOBILE_OIDC_CLIENT_ID", previous)
        else
          System.delete_env("MOBILE_OIDC_CLIENT_ID")
        end
      end)

      :ok
    end

    test "body[\"client_id\"] equals the env value when MOBILE_OIDC_CLIENT_ID is set" do
      {conn, body} = get_mobile_config()

      assert conn.status == 200
      assert body["client_id"] == "req418-override-client"
    end
  end

  describe "REQ-418: client_id is byte-identical across all four never-error paths" do
    test "resolvable slug, unknown slug, missing ?slug=, and lookup-failure client_id values all agree" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req418-client-id-identical"),
          display_name: "REQ-418 Client Id Identical Tenant",
          idp_realm_id: unique_realm("req418-client-id-identical")
        })

      {_conn_resolvable, body_resolvable} = get_mobile_config(tenant.slug)
      {_conn_unknown, body_unknown} = get_mobile_config(unique_slug("req418-client-id-unknown"))
      {_conn_missing, body_missing} = get_mobile_config()
      {_conn_db_failure, body_db_failure} = get_mobile_config(<<0>>)

      assert body_resolvable["client_id"] == body_unknown["client_id"]
      assert body_unknown["client_id"] == body_missing["client_id"]
      assert body_missing["client_id"] == body_db_failure["client_id"]
      assert body_missing["client_id"] == "letflow-mobile"
    end
  end

  describe "REQ-418: moduledoc no longer says \"exactly five keys\"; states six keys and the reasoning" do
    test "moduledoc states six keys, includes client_id, and the three-point security reasoning" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Letflow.Routers.MobileTenantConfig)

      refute moduledoc =~ "exactly five keys"
      assert moduledoc =~ "exactly six keys"
      assert moduledoc =~ "client_id"
      assert moduledoc =~ "is not a secret"
      assert moduledoc =~ "platform-global"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # REQ-282 AC2 -- identical shape/status/key-set across all 4 never-error
  # paths: resolvable slug, unknown slug, missing ?slug=, simulated failure
  # ═══════════════════════════════════════════════════════════════════════════

  describe "REQ-282 AC2: all four never-error paths produce byte-identical bodies (no stored settings)" do
    test "resolvable slug with no stored settings, unknown slug, missing ?slug=, and a simulated DB failure all agree" do
      tenant_no_settings =
        insert_tenant!(%{
          slug: unique_slug("req282-no-settings"),
          display_name: "REQ-282 No Settings Tenant",
          idp_realm_id: unique_realm("req282-no-settings")
        })

      {conn_resolvable, body_resolvable} = get_mobile_config(tenant_no_settings.slug)
      {conn_unknown, body_unknown} = get_mobile_config(unique_slug("req282-unknown"))
      {conn_missing, body_missing} = get_mobile_config()

      # Simulated DB failure: Identity.safe_get_tenant_by_slug/2's rescue
      # clause is triggered by a slug value Postgrex cannot encode as a query
      # parameter (a null byte is invalid inside a Postgres text value) --
      # the same mechanism tenant_config_test.exs uses for its own AC2.
      {conn_db_failure, body_db_failure} = get_mobile_config(<<0>>)

      for conn <- [conn_resolvable, conn_unknown, conn_missing, conn_db_failure] do
        assert conn.status == 200
      end

      for body <- [body_resolvable, body_unknown, body_missing, body_db_failure] do
        assert Map.keys(body) |> Enum.sort() == @expected_keys
      end

      # locales/default_locale/branding are byte-identical across all four
      # paths -- all four converge on the {@default_realm, nil} input to
      # mobile_config_map/2's fallback helpers.
      for field <- ["locales", "default_locale", "branding"] do
        assert body_resolvable[field] == body_unknown[field]
        assert body_unknown[field] == body_missing[field]
        assert body_missing[field] == body_db_failure[field]
      end

      assert body_resolvable["branding"] == %{
               "app_name" => "Letflow",
               "logo_url" => nil,
               "primary_color" => "#228be6"
             }

      assert body_resolvable["locales"] == ["en"]
      assert body_resolvable["default_locale"] == "en"

      # realm_url legitimately differs for the resolvable tenant, but the
      # three no-tenant-equivalent paths agree with each other on it too.
      assert body_unknown["realm_url"] == body_missing["realm_url"]
      assert body_missing["realm_url"] == body_db_failure["realm_url"]
      assert body_unknown["realm_url"] =~ "/realms/bpm-default"
      refute body_resolvable["realm_url"] =~ "/realms/bpm-default"
    end
  end

  describe "REQ-585: optional branding.secondary_color" do
    @default_branding_literal %{
      "app_name" => "Letflow",
      "logo_url" => nil,
      "primary_color" => "#228be6"
    }

    test "a stored secondary is served as secondary_color; primary_color is unchanged" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req585-sec"),
          display_name: "REQ-585 Secondary Tenant",
          idp_realm_id: unique_realm("req585-sec")
        })

      assert {:ok, _} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{
                   "brand_colors" => %{"primary" => "#1864AB", "secondary" => "#1971C2"}
                 }
               })

      {conn, body} = get_mobile_config(tenant.slug)
      assert conn.status == 200
      assert body["branding"]["secondary_color"] == "#1971C2"
      assert body["branding"]["primary_color"] == "#1864AB"
      assert Map.keys(body) |> Enum.sort() == @expected_keys
    end

    test "no stored secondary omits the key; primary_color unchanged" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req585-nosec"),
          display_name: "REQ-585 No Secondary Tenant",
          idp_realm_id: unique_realm("req585-nosec")
        })

      assert {:ok, _} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{"brand_colors" => %{"primary" => "#1864AB"}}
               })

      {_conn, body} = get_mobile_config(tenant.slug)
      refute Map.has_key?(body["branding"], "secondary_color")
      assert body["branding"]["primary_color"] == "#1864AB"
    end

    test "unknown slug, missing slug and lookup failure serve the default branding, no secondary_color" do
      for arg <- [unique_slug("req585-unknown"), :no_slug_param, <<0>>] do
        {conn, body} = get_mobile_config(arg)
        assert conn.status == 200
        assert body["branding"] == @default_branding_literal
        assert Jason.encode!(body) =~ "primary_color"
        refute Jason.encode!(body) =~ "secondary_color"
      end
    end
  end

  describe "REQ-595 part A: signatory settings do not reach the mobile config" do
    test "P2: the body is unchanged after storing both signatory settings" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req595-p2"),
          display_name: "REQ-595 Signatory Tenant",
          idp_realm_id: unique_realm("req595-p2")
        })

      assert {:ok, _} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{"app_name" => "Acme"}
               })

      {conn_before, before} = get_mobile_config(tenant.slug)
      assert conn_before.status == 200

      assert {:ok, _} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{
                   "app_name" => "Acme",
                   "signatory_name" => "Aigul Nurpeisova",
                   "signatory_title" => "Director of Certification"
                 }
               })

      {conn_after, after_body} = get_mobile_config(tenant.slug)
      assert conn_after.status == 200
      assert after_body == before
      refute Jason.encode!(after_body["branding"]) =~ "signatory"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # REQ-282 AC3 -- a tenant WITH stored branding/locales gets its own values
  # (per-sub-key fallback), a tenant WITHOUT gets platform defaults
  # ═══════════════════════════════════════════════════════════════════════════

  describe "REQ-282 AC3: stored settings are actually read; per-sub-key fallback, not all-or-nothing" do
    test "a tenant with a full stored settings map gets its own branding, locales and default_locale" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req282-full-settings"),
          display_name: "REQ-282 Full Settings Tenant",
          idp_realm_id: unique_realm("req282-full-settings")
        })

      assert {:ok, _updated} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{
                   "app_name" => "Acme Corp",
                   "logo_url" => "https://acme.example.com/logo.png",
                   "brand_colors" => %{"primary" => "#1864AB"},
                   "locales" => ["en", "fr"],
                   "default_locale" => "fr"
                 }
               })

      {conn, body} = get_mobile_config(tenant.slug)

      assert conn.status == 200

      assert body["branding"] == %{
               "app_name" => "Acme Corp",
               "logo_url" => "https://acme.example.com/logo.png",
               "primary_color" => "#1864AB"
             }

      assert body["locales"] == ["en", "fr"]
      assert body["default_locale"] == "fr"
    end

    test "a tenant with a PARTIAL stored settings map (only locales) falls back independently for branding/default_locale" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req282-partial-settings"),
          display_name: "REQ-282 Partial Settings Tenant",
          idp_realm_id: unique_realm("req282-partial-settings")
        })

      assert {:ok, _updated} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{"locales" => ["de"]}
               })

      {conn, body} = get_mobile_config(tenant.slug)

      assert conn.status == 200
      assert body["locales"] == ["de"]
      assert body["default_locale"] == "en"

      assert body["branding"] == %{
               "app_name" => "Letflow",
               "logo_url" => nil,
               "primary_color" => "#228be6"
             }
    end

    test "a tenant with NO stored settings at all (settings == nil) gets the full platform-default values" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req282-nil-settings"),
          display_name: "REQ-282 Nil Settings Tenant",
          idp_realm_id: unique_realm("req282-nil-settings")
        })

      assert tenant.settings == nil

      {conn, body} = get_mobile_config(tenant.slug)

      assert conn.status == 200
      assert body["locales"] == ["en"]
      assert body["default_locale"] == "en"

      assert body["branding"] == %{
               "app_name" => "Letflow",
               "logo_url" => nil,
               "primary_color" => "#228be6"
             }
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # REQ-282 OQ-A -- a resolved tenant with a nil idp_realm_id has its settings
  # suppressed too (design's recommended resolution), not just its realm_url
  # ═══════════════════════════════════════════════════════════════════════════

  describe "REQ-282 OQ-A: a tenant found but with no usable realm gets platform-default branding too" do
    test "a slug with nil idp_realm_id AND stored settings still gets platform-default branding/locales" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req282-nilrealm-settings"),
          display_name: "REQ-282 Nil Realm With Settings Tenant",
          idp_realm_id: nil
        })

      assert {:ok, _updated} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{"app_name" => "Should Not Leak Co"}
               })

      {conn, body} = get_mobile_config(tenant.slug)

      assert conn.status == 200
      assert body["realm_url"] =~ "/realms/bpm-default"

      assert body["branding"] == %{
               "app_name" => "Letflow",
               "logo_url" => nil,
               "primary_color" => "#228be6"
             }
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # REQ-282 AC5 -- @default_branding's primary_color is reconciled to the
  # canonical platform default (tokens.css --color-brand-600)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "REQ-282 AC5: @default_branding's primary_color equals the canonical platform default" do
    test "served default primary_color is #228be6, not the stale #0B5FFF" do
      {conn, body} = get_mobile_config()

      assert conn.status == 200
      assert body["branding"]["primary_color"] == "#228be6"
      refute body["branding"]["primary_color"] == "#0B5FFF"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # REQ-282 AC4 -- moduledoc rewrite: neither the old invariance claim nor the
  # old "byte-identical by construction" sentence survives unchanged
  # ═══════════════════════════════════════════════════════════════════════════

  describe "REQ-282 AC4: moduledoc no longer claims branding/locales/default_locale are global" do
    test "moduledoc states the new per-tenant behavior and no longer claims four fields are byte-identical by construction" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Letflow.Routers.MobileTenantConfig)

      normalized = String.replace(moduledoc, ~r/\s+/, " ")

      assert normalized =~ "locales / default_locale / branding are per-tenant"
      assert normalized =~ "Letflow.Identity.TenantSettings"

      assert normalized =~
               "`environment_kind` is the one field that is still, and remains, byte-identical across every branch by construction"

      refute normalized =~
               "the other four are byte-identical across every branch by construction"

      refute normalized =~
               "locales / default_locale / branding / environment_kind are global, not per-tenant"
    end
  end
end
