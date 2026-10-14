defmodule Letflow.Routers.TenantModulesSettingsTest do
  @moduledoc """
  Tests for `PUT /api/v1/tenant/modules/:module_id/settings` (REQ-414).

  Covers all acceptance criteria:
    AC1  200 for TENANT_ADMIN with valid body; list_installed shows updated settings.
    AC2  422 on wrong type for a declared key; settings unchanged.
    AC3  422 on undeclared key (fixture schema has additionalProperties:false); unchanged.
    AC4  403 for every role without :ModulesManage (incl. a non-platform PLATFORM_ADMIN); 404 when module not installed.
    AC5  Two-tenant isolation — tenant A's PUT changes only tenant A's row.
    AC6  Covered in `Letflow.Modules.InstallsPutSettingsTest`.

  Dispatch strategy: real `Letflow.Routers.TenantModules.call/2`, mirroring
  `test/letflow/routers/tenant_modules_test.exs`'s established convention.
  `async: false` — tenant provisioning/migration replay needs
  `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Modules.Installs
  alias Letflow.TenantFixture

  @opts Letflow.Routers.TenantModules.init([])

  defp build_conn(tenant_id, roles, module_id, body) do
    conn(:put, "/#{module_id}/settings")
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req414-tenant-modules-settings-test-trace-id")
  end

  defp put_settings(tenant_id, roles, module_id, body) do
    build_conn(tenant_id, roles, module_id, body)
    |> Letflow.Routers.TenantModules.call(@opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # ═══════════════════════════════════════════════════════════════════════
  # AC1 — 200 for TENANT_ADMIN with valid body; list_installed shows
  #        updated settings
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC1 -- 200 for TENANT_ADMIN with valid body" do
    test "PUT valid settings → 200, response contains settings, list_installed shows update" do
      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ac1")

      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix, rationale: "test: module install")

      conn = put_settings(tenant_id, ["TENANT_ADMIN"], "fixture", %{"greeting" => "hello"})

      assert conn.status == 200
      assert json(conn)["settings"] == %{"greeting" => "hello"}

      [installed] = Installs.list_installed(prefix: prefix)
      assert installed.settings == %{"greeting" => "hello"}
    end

    test "PUT empty settings → 200 (empty map is valid per fixture schema)" do
      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ac1-empty")

      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix, rationale: "test: module install")

      conn = put_settings(tenant_id, ["TENANT_ADMIN"], "fixture", %{})

      assert conn.status == 200
      assert json(conn)["settings"] == %{}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC2 — 422 on wrong type for a declared key; settings unchanged
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC2 -- 422 on wrong type for a declared key" do
    test "greeting must be a string; integer → 422, row settings unchanged" do
      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ac2")

      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix, rationale: "test: module install")

      # Set a known-good value first
      put_settings(tenant_id, ["TENANT_ADMIN"], "fixture", %{"greeting" => "original"})

      conn = put_settings(tenant_id, ["TENANT_ADMIN"], "fixture", %{"greeting" => 123})

      assert conn.status == 422

      [installed] = Installs.list_installed(prefix: prefix)
      assert installed.settings == %{"greeting" => "original"}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC3 — 422 on undeclared key; settings unchanged
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC3 -- 422 on undeclared key (additionalProperties: false)" do
    test "extra key not in fixture schema → 422, row settings unchanged" do
      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ac3")

      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix, rationale: "test: module install")

      put_settings(tenant_id, ["TENANT_ADMIN"], "fixture", %{"greeting" => "original"})

      conn =
        put_settings(tenant_id, ["TENANT_ADMIN"], "fixture", %{
          "greeting" => "hi",
          "extra_field" => "should be rejected"
        })

      assert conn.status == 422

      [installed] = Installs.list_installed(prefix: prefix)
      assert installed.settings == %{"greeting" => "original"}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC4 — 403 for every role without :ModulesManage; 404 when not installed
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC4 -- role gate and 404 when not installed" do
    test "403 for every role other than TENANT_ADMIN (a non-platform-tenant PLATFORM_ADMIN holds nothing)" do
      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ac4-roles")

      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix, rationale: "test: module install")

      # REQ-447: TENANT_ADMIN holds :ModulesManage (tenant scope); its 200 is the next test.
      # PR 2: PLATFORM_ADMIN is NOT excluded any more: outside the platform tenant it is dropped
      # at resolution and holds nothing (the legacy own-tenant power is removed), so it is 403.
      for role <- Authorization.roles(), role != :TENANT_ADMIN do
        conn =
          put_settings(tenant_id, [Atom.to_string(role)], "fixture", %{"greeting" => "hi"})

        assert conn.status == 403,
               "expected 403 for role #{inspect(role)}, got #{conn.status}"
      end

      # Settings should be unchanged (still %{} from install)
      [installed] = Installs.list_installed(prefix: prefix)
      assert installed.settings == %{}
    end

    test "REQ-447: 200 for TENANT_ADMIN updating its own tenant's module settings" do
      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req447-settings")

      {:ok, _} =
        Installs.install("fixture", Ecto.UUID.generate(),
          prefix: prefix,
          rationale: "test: module install"
        )

      conn = put_settings(tenant_id, ["TENANT_ADMIN"], "fixture", %{"greeting" => "hi"})
      assert conn.status == 200
    end

    test "404 when the module is not installed in the caller's tenant" do
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ac4-404")

      # fixture not installed — expect 404
      conn = put_settings(tenant_id, ["TENANT_ADMIN"], "fixture", %{"greeting" => "hi"})

      assert conn.status == 404
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC5 — two-tenant isolation: PUT as tenant A changes only tenant A's row
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC5 -- two-tenant isolation" do
    test "TENANT_ADMIN of tenant A changes only tenant A's row, tenant B's settings unchanged" do
      %{tenant_id: tenant_id_a, schema_name: prefix_a} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ac5-a")

      %{schema_name: prefix_b} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ac5-b")

      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix_a, rationale: "test: module install")

      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix_b, rationale: "test: module install")

      # Only authenticate as tenant A — the prefix derives server-side from
      # tenant_id_a, never from anything in the body (INV-1).
      conn =
        put_settings(tenant_id_a, ["TENANT_ADMIN"], "fixture", %{
          "greeting" => "tenant_a_update"
        })

      assert conn.status == 200

      [installed_a] = Installs.list_installed(prefix: prefix_a)
      [installed_b] = Installs.list_installed(prefix: prefix_b)

      assert installed_a.settings == %{"greeting" => "tenant_a_update"}
      # Tenant B's row is still at its post-install default
      assert installed_b.settings == %{}
    end
  end
end
