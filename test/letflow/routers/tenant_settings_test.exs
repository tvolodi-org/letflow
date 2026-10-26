defmodule Letflow.Routers.TenantSettingsTest do
  @moduledoc """
  Tests for `Letflow.Routers.TenantSettings` (REQ-382) — the first
  HTTP-reachable write path onto `tenants.settings`. See
  `lib/letflow/design/req382-tenant-branding-write-path.md` and
  `test/specs/REQ-382.md` for the full design/test-case rationale.

  Uses `Letflow.DataCase` (real Postgres, per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1) and
  `Letflow.TenantFixture` for real provisioned tenant schemas —
  `async: false`, matching `test/letflow/routers/tenants_test.exs`'s and
  `test/letflow/routers/req196_audit_route_test.exs`'s own established
  convention for this exact fixture (tenant provisioning/migration replay
  needs `Sandbox.mode(Letflow.Repo, :auto)`).

  ## Dispatch strategy

  Every PATCH test below dispatches through `Letflow.Routers.TenantSettings`'s
  own `call/2` with `conn.assigns[:auth_context]` set directly, mirroring
  `tenants_test.exs`'s and `req196_audit_route_test.exs`'s established
  convention: `use Letflow.Api.AuthorizedRouter` wires `plug(:match) ->
  plug(Letflow.Plugs.Authorize) -> plug(:dispatch)` into the router's own
  `call/2` (see `lib/letflow/api/authorized_router.ex`), so this exercises
  the REAL authorization plug (`scoped_repo_opts/1` resolution,
  `Authorization.evaluate_access/2`, `scoped_opts`/`access_decision` assigns)
  over a real `Plug.Conn` built with `Plug.Test.conn/3` and dispatched as
  Plug itself would — this is "real HTTP" in the sense the acceptance
  criteria ask for (never a direct call to
  `Letflow.Identity.update_tenant_settings/2`), just without also
  re-exercising `Letflow.Plugs.AuthPipeline`'s own token-verification
  machinery, which is that plug's own test file's job, not this router's.

  AC1's round-trip additionally dispatches a real `GET /api/tenant-config`
  through the full, unmodified `Letflow.Router` (no `Authorization` header,
  matching `test/letflow/routers/tenant_config_test.exs`'s own established
  dispatch strategy for that endpoint) — proving the value this router wrote
  is visible through the actual read-side endpoint, not just back through
  this router's own response body.

  AC4's audit assertion dispatches a real `GET /api/v1/audit` through
  `Letflow.Routers.Audit`'s own `call/2`, mirroring
  `req196_audit_route_test.exs`'s `get_audit/2` helper exactly — proving
  `AuditLogPage.tsx`'s existing query surfaces the new entry with zero
  frontend change (design §0), per this requirement's own AC4 wording.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture

  @settings_opts Letflow.Routers.TenantSettings.init([])
  @audit_opts Letflow.Routers.Audit.init([])
  @router_opts Letflow.Router.init([])

  # ── Shared test dispatch helpers ─────────────────────────────────────────

  defp build_conn(method, path, tenant_fixture, fields) do
    roles = Keyword.get(fields, :roles, ["TENANT_ADMIN"])
    body = Keyword.get(fields, :body, %{})

    conn(method, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_fixture.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req382-test-trace-id")
  end

  defp patch_settings(tenant_fixture, fields) do
    build_conn(:patch, "/", tenant_fixture, fields)
    |> Letflow.Routers.TenantSettings.call(@settings_opts)
  end

  defp get_tenant_config(slug) do
    conn = conn(:get, "/api/tenant-config?realm=#{URI.encode_www_form(slug)}")
    assert get_req_header(conn, "authorization") == []

    conn = Letflow.Router.call(conn, @router_opts)
    {conn, Jason.decode!(conn.resp_body)}
  end

  defp get_audit(tenant_fixture, fields) do
    roles = Keyword.get(fields, :roles, ["TENANT_ADMIN"])
    query_string = Keyword.get(fields, :query_string, "")
    path = if query_string == "", do: "/", else: "/?" <> query_string

    conn(:get, path)
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_fixture.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req382-audit-trace-id")
    |> Letflow.Routers.Audit.call(@audit_opts)
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC1 — authenticated PATCH round-trips through GET /api/tenant-config
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC1: authenticated PATCH round-trips through GET /api/tenant-config" do
    test "a valid brand_colors.primary written via PATCH is visible on the very next GET /api/tenant-config call" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-ac1")

      # config/2's `?realm=<slug>` lookup (design §0) only returns this
      # tenant's own branding -- rather than falling through to the
      # default-realm/nil-tenant branch -- for a tenant with a non-nil,
      # non-empty `idp_realm_id` (`TenantConfig.resolve_realm/2`). The
      # `:disabled` oidc_mode `TenantFixture.provisioned_tenant!/1` uses by
      # default leaves this nil, and `create_changeset/3` requires a
      # non-empty `idp_realm_id` when cast with `:enabled` (which
      # `TenantFixture` has no opt to also supply), so it is set directly
      # here via a raw update rather than by re-provisioning through
      # `:enabled` mode.
      {1, nil} =
        Repo.update_all(
          from(t in Tenant, where: t.id == ^tenant.tenant_id),
          set: [idp_realm_id: "req382-ac1-realm-#{tenant.tenant_id}"]
        )

      resp =
        patch_settings(tenant, body: %{"brand_colors" => %{"primary" => "#1864AB"}})

      assert resp.status == 200
      patch_body = Jason.decode!(resp.resp_body)
      assert patch_body["tenant_id"] == tenant.tenant_id
      assert patch_body["settings"]["brand_colors"] == %{"primary" => "#1864AB"}

      {config_conn, config_body} = get_tenant_config(tenant.tenant.slug)

      assert config_conn.status == 200
      assert config_body["branding"]["brand_colors"] == %{"primary" => "#1864AB"}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC2 — WCAG-AA-failing colour refused with a plain-language message;
  # previously-stored colour unchanged
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC2: WCAG-AA-failing colour is refused, previous colour unchanged" do
    test "a hex-valid but contrast-failing primary is refused 422 naming the WCAG threshold, prior colour retained" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-ac2")

      # Establish a known-good, WCAG-AA-passing stored colour first.
      setup_resp =
        patch_settings(tenant, body: %{"brand_colors" => %{"primary" => "#1864AB"}})

      assert setup_resp.status == 200

      # #228be6 passes the hex-format regex but fails the 4.5:1 AA contrast
      # check against both tokens.css reference backgrounds (~3.37:1/~3.56:1,
      # pinned independently in color_contrast_test.exs).
      reject_resp =
        patch_settings(tenant, body: %{"brand_colors" => %{"primary" => "#228be6"}})

      assert reject_resp.status == 422
      reject_body = Jason.decode!(reject_resp.resp_body)
      assert reject_body["detail"] =~ "4.5"
      assert reject_body["detail"] =~ "contrast" or reject_body["detail"] =~ "WCAG"

      # The previously-stored colour must be unchanged -- both in this
      # router's own read of the tenant row, and structurally (the whole
      # :settings changeset was rejected, nothing persisted).
      reloaded = Repo.get!(Tenant, tenant.tenant_id)
      assert reloaded.settings == %{"brand_colors" => %{"primary" => "#1864AB"}}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC3 — an out-of-allowlist top-level key or brand_colors sub-key applies
  # only the recognized/valid part, never 500s, never rejects the whole
  # request for that reason alone
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC3: out-of-allowlist keys apply only the recognized/valid part" do
    test "an out-of-allowlist top-level key is dropped, the recognized app_name key still applies, no 500" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-ac3-top")

      resp =
        patch_settings(tenant,
          body: %{"app_name" => "Acme Corp", "warning_color" => "#ff0000"}
        )

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["settings"]["app_name"] == "Acme Corp"
      refute Map.has_key?(body["settings"], "warning_color")

      reloaded = Repo.get!(Tenant, tenant.tenant_id)
      refute Map.has_key?(reloaded.settings, "warning_color")
    end

    test "an out-of-allowlist brand_colors sub-key is dropped, the recognized primary sub-key still applies" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-ac3-sub")

      resp =
        patch_settings(tenant,
          body: %{
            "brand_colors" => %{"primary" => "#1864AB", "tertiary" => "#00ff00"}
          }
        )

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["settings"]["brand_colors"] == %{"primary" => "#1864AB"}

      reloaded = Repo.get!(Tenant, tenant.tenant_id)
      assert reloaded.settings == %{"brand_colors" => %{"primary" => "#1864AB"}}
    end

    test "a request consisting ONLY of out-of-allowlist keys still succeeds 200 with an unchanged settings map, never 500" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-ac3-onlybad")

      resp = patch_settings(tenant, body: %{"not_a_real_key" => "value"})

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["settings"] == %{}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Contract regression (ISS-0887): a wrapped {settings: {...}} body is
  # inert, never persists. This is not a true fail-first test -- the router's
  # behavior here is unchanged by ISS-0887's fix (the fix is entirely
  # client-side, see lib/letflow/design/iss0887-tenant-settings-contract-mismatch.md
  # §4) -- it pins today's real, tested, REQ-382-AC3-consistent behavior as a
  # permanent regression guard: if this router ever changes to unwrap
  # "settings", this test fails loudly, forcing a conscious decision rather
  # than a silent contract widening.
  # ═══════════════════════════════════════════════════════════════════════

  describe "contract regression (ISS-0887): a wrapped {settings: {...}} body is inert, never persists" do
    test "a {settings: {brand_colors: {...}}} wrapped body (the shape the web client sent before ISS-0887's fix) is treated as an unrecognized key and never persists" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0887-wrapped")
      before = Repo.get!(Tenant, tenant.tenant_id)

      resp =
        patch_settings(tenant,
          body: %{"settings" => %{"brand_colors" => %{"primary" => "#1864AB"}}}
        )

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["settings"] == %{}

      reloaded = Repo.get!(Tenant, tenant.tenant_id)
      assert (reloaded.settings || %{}) == (before.settings || %{})
    end

    test "the corrected flat {brand_colors: {...}} body (the shape the web client sends after ISS-0887's fix) persists and round-trips through GET /api/tenant-config" do
      # A one-line, explicitly ISS-0887-labeled restatement of AC1's existing
      # full round-trip test above -- documents that this is the shape
      # ISS-0887's client fix now sends, and that it already round-trips
      # (no router change was needed or made for this issue).
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0887-flat")

      {1, nil} =
        Repo.update_all(
          from(t in Tenant, where: t.id == ^tenant.tenant_id),
          set: [idp_realm_id: "iss0887-flat-realm-#{tenant.tenant_id}"]
        )

      resp = patch_settings(tenant, body: %{"brand_colors" => %{"primary" => "#1864AB"}})

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["settings"]["brand_colors"] == %{"primary" => "#1864AB"}

      {config_conn, config_body} = get_tenant_config(tenant.tenant.slug)

      assert config_conn.status == 200
      assert config_body["branding"]["brand_colors"] == %{"primary" => "#1864AB"}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC4 — the same rejected-key request writes exactly one Letflow.Audit
  # entry naming the tenant, actor, rejected key(s), and attempted value(s);
  # GET /api/v1/audit surfaces it with zero frontend change
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC4: exactly one audit entry for a rejected-key request, surfaced via GET /api/v1/audit" do
    test "records tenant/actor/rejected top-level key+value and rejected brand_colors sub-key+value in one entry" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-ac4")

      resp =
        patch_settings(tenant,
          body: %{
            "app_name" => "Kept",
            "text_size" => "large",
            "brand_colors" => %{"primary" => "#1864AB", "tertiary" => "#00ff00"}
          }
        )

      assert resp.status == 200

      audit_resp = get_audit(tenant, query_string: "resource_type=tenant_settings")
      assert audit_resp.status == 200
      audit_body = Jason.decode!(audit_resp.resp_body)

      # Exactly one entry for this one request.
      assert audit_body["count"] == 1
      assert [item] = audit_body["items"]

      assert item["resource_type"] == "tenant_settings"
      assert item["resource_id"] == tenant.tenant_id
      assert item["action"] == "tenant_settings.reject_unrecognized_keys"
      refute is_nil(item["actor_id"])

      assert item["after_state"]["rejected_top_level_keys"] == %{"text_size" => "large"}

      assert item["after_state"]["rejected_brand_colors_keys"] == %{
               "tertiary" => "#00ff00"
             }
    end

    test "REQ-585: a valid secondary is stored, tertiary is dropped and audited once" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req585-sec")

      resp =
        patch_settings(tenant,
          body: %{"brand_colors" => %{"secondary" => "#1971C2", "tertiary" => "#000000"}}
        )

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert Map.keys(body) |> Enum.sort() == ["settings", "tenant_id"]
      assert body["settings"]["brand_colors"] == %{"secondary" => "#1971C2"}

      reloaded = Repo.get!(Tenant, tenant.tenant_id)
      assert reloaded.settings == %{"brand_colors" => %{"secondary" => "#1971C2"}}

      audit_resp = get_audit(tenant, query_string: "resource_type=tenant_settings")
      audit_body = Jason.decode!(audit_resp.resp_body)
      assert audit_body["count"] == 1
      assert [item] = audit_body["items"]
      assert item["action"] == "tenant_settings.reject_unrecognized_keys"
      assert item["after_state"]["rejected_brand_colors_keys"] == %{"tertiary" => "#000000"}
    end

    test "no audit entry is written when every key in the request is recognized" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-ac4-clean")

      resp = patch_settings(tenant, body: %{"app_name" => "All Clean"})
      assert resp.status == 200

      audit_resp = get_audit(tenant, query_string: "resource_type=tenant_settings")
      assert audit_resp.status == 200
      assert Jason.decode!(audit_resp.resp_body)["count"] == 0
    end

    test "no audit entry is written on a value-validation (WCAG) rejection -- only key-rejections are audited" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-ac4-wcag")

      resp =
        patch_settings(tenant, body: %{"brand_colors" => %{"primary" => "#228be6"}})

      assert resp.status == 422

      audit_resp = get_audit(tenant, query_string: "resource_type=tenant_settings")
      assert Jason.decode!(audit_resp.resp_body)["count"] == 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC5 — settings_changeset/2's cast list stays [:settings] only;
  # TenantSettings' closed vocabulary unchanged; this endpoint cannot touch
  # :status/:slug/:idp_realm_id/:display_name
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC5: cannot touch status/slug/idp_realm_id/display_name" do
    test "status/slug/idp_realm_id/display_name in the request body are silently rejected as unrecognized keys, never applied" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-ac5")
      before = Repo.get!(Tenant, tenant.tenant_id)

      resp =
        patch_settings(tenant,
          body: %{
            "status" => "inactive",
            "slug" => "hijacked-slug",
            "idp_realm_id" => "hijacked-realm",
            "display_name" => "Hijacked Display Name",
            "app_name" => "Still Applies"
          }
        )

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["settings"] == %{"app_name" => "Still Applies"}

      reloaded = Repo.get!(Tenant, tenant.tenant_id)
      assert reloaded.status == before.status
      assert reloaded.slug == before.slug
      assert reloaded.idp_realm_id == before.idp_realm_id
      assert reloaded.display_name == before.display_name
      assert reloaded.settings == %{"app_name" => "Still Applies"}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Router merge behavior (ELIXIR-DEV logic beyond the literal AC text,
  # design §3 step 5 / REVIEWER-confirmed at Step 2d)
  # ═══════════════════════════════════════════════════════════════════════

  describe "shallow top-level merge: a partial PATCH never erases previously-set keys it did not mention" do
    test "a PATCH containing only app_name does not erase a previously-set brand_colors/logo_url/locales/default_locale" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-merge")

      full_resp =
        patch_settings(tenant,
          body: %{
            "app_name" => "Original",
            "logo_url" => "https://example.com/logo.png",
            "brand_colors" => %{"primary" => "#1864AB"},
            "locales" => ["en", "en-US"],
            "default_locale" => "en"
          }
        )

      assert full_resp.status == 200

      partial_resp = patch_settings(tenant, body: %{"app_name" => "Renamed Only"})
      assert partial_resp.status == 200
      body = Jason.decode!(partial_resp.resp_body)

      assert body["settings"]["app_name"] == "Renamed Only"
      assert body["settings"]["logo_url"] == "https://example.com/logo.png"
      assert body["settings"]["brand_colors"] == %{"primary" => "#1864AB"}
      assert body["settings"]["locales"] == ["en", "en-US"]
      assert body["settings"]["default_locale"] == "en"

      reloaded = Repo.get!(Tenant, tenant.tenant_id)
      assert reloaded.settings["app_name"] == "Renamed Only"
      assert reloaded.settings["brand_colors"] == %{"primary" => "#1864AB"}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Authorization
  # ═══════════════════════════════════════════════════════════════════════

  describe "authorization: :TenantSettingsManage is a tenant-admin permission" do
    test "a non-TENANT_ADMIN authenticated caller gets 403, row unchanged" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-authz-403")
      before = Repo.get!(Tenant, tenant.tenant_id)

      resp =
        patch_settings(tenant,
          roles: ["PROCESS_DESIGNER"],
          body: %{"app_name" => "Should Not Apply"}
        )

      assert resp.status == 403
      assert Repo.get!(Tenant, tenant.tenant_id) == before
    end

    test "REQ-447 PR 2: a PLATFORM_ADMIN of an ordinary tenant holds nothing and gets 403, row unchanged" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req447-authz-legacy")
      before = Repo.get!(Tenant, tenant.tenant_id)

      resp =
        patch_settings(tenant,
          roles: ["PLATFORM_ADMIN"],
          body: %{"app_name" => "Should Not Apply"}
        )

      assert resp.status == 403
      assert Repo.get!(Tenant, tenant.tenant_id) == before
    end

    test "a caller with no roles at all gets 403, row unchanged" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-authz-noroles")
      before = Repo.get!(Tenant, tenant.tenant_id)

      resp = patch_settings(tenant, roles: [], body: %{"app_name" => "Should Not Apply"})

      assert resp.status == 403
      assert Repo.get!(Tenant, tenant.tenant_id) == before
    end

    test "an unauthenticated request (no Authorization header) through the real Letflow.Router mount is rejected, never reaches the handler" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req382-authz-401")
      before = Repo.get!(Tenant, tenant.tenant_id)

      conn =
        conn(:patch, "/api/v1/tenant/settings")
        |> Map.put(:body_params, %{"app_name" => "Should Not Apply"})
        |> put_req_header("content-type", "application/json")

      assert get_req_header(conn, "authorization") == []

      resp = Letflow.Router.call(conn, @router_opts)

      assert resp.status == 401
      assert Repo.get!(Tenant, tenant.tenant_id) == before
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # ISS-0980 — maybe_record_rejected_keys/5 is rescue-hardened, never raises
  # ═══════════════════════════════════════════════════════════════════════

  describe "ISS-0980: maybe_record_rejected_keys/5 is rescue-hardened, never raises" do
    test "a genuine Postgres-level audit-insert failure during a PATCH with a rejected key is logged and swallowed -- the settings mutation still returns 200, not 500" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0980-ts-a")

      Repo.query!(~s(DROP TABLE "#{tenant.schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{tenant.schema_name}".audit_entries (
          id uuid PRIMARY KEY,
          tenant_id uuid NOT NULL,
          actor_id uuid,
          action text NOT NULL,
          resource_type text NOT NULL,
          resource_id text NOT NULL,
          "timestamp" timestamp(6) without time zone NOT NULL,
          before_state jsonb,
          after_state jsonb,
          trace_id text,
          chain_hash text NOT NULL,
          prev_chain_hash text,
          inserted_at timestamp(6) without time zone NOT NULL
        )
        """)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          resp =
            patch_settings(tenant,
              body: %{"app_name" => "ISS-0980 App", "not_a_real_key" => "x"}
            )

          assert resp.status == 200
          assert Jason.decode!(resp.resp_body)["settings"]["app_name"] == "ISS-0980 App"
        end)

      assert log =~ "tenant_settings.reject_unrecognized_keys audit write raised"
      assert log =~ "#{tenant.tenant_id}"
      assert log =~ "Postgrex.Error"
    end
  end
end
