defmodule Letflow.Routers.TenantModulesTest do
  @moduledoc """
  Tests for `Letflow.Routers.TenantModules` (REQ-403) — the HTTP install
  path onto 0039 D5. See
  `lib/letflow/design/req403-module-install-route.md` for the full design.
  ELIXIR-DEV inline coverage (this project's established convention when
  the design is fully specified — no separate TEST-DESIGNER dispatch).

  Covers AC1 (role gate, no row written on 403), AC2 (INV-1 — a
  body-supplied `tenant_id`/`tenant` never redirects the write), AC3
  (404/409/422 error mapping).

  Dispatch strategy: real `Letflow.Routers.TenantModules.call/2`, mirroring
  `test/letflow/routers/tenant_settings_test.exs`'s own established
  convention — `use Letflow.Api.AuthorizedRouter` wires
  `plug(:match) -> plug(Letflow.Plugs.Authorize) -> plug(:dispatch)`, so
  this exercises the REAL authorization plug over a real `Plug.Conn`.

  `async: false` — tenant provisioning/migration replay needs
  `Sandbox.mode(Letflow.Repo, :auto)` (`TenantFixture.provisioned_tenant!/1`'s
  own requirement).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.TenantFixture

  @opts Letflow.Routers.TenantModules.init([])

  defp build_conn(tenant_id, roles, body) do
    conn(:post, "/")
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req403-tenant-modules-test-trace-id")
  end

  # GH 2531 (decision 0052 D3): `rationale` is required; the existing tests are about
  # other things, so this helper supplies one unless the body already carries the key.
  defp install(tenant_id, roles, body) when is_map(body) do
    install_raw(tenant_id, roles, Map.put_new(body, "rationale", "test: module install"))
  end

  defp install(tenant_id, roles, body), do: install_raw(tenant_id, roles, body)

  defp install_raw(tenant_id, roles, body) do
    build_conn(tenant_id, roles, body)
    |> Letflow.Routers.TenantModules.call(@opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # ═══════════════════════════════════════════════════════════════════════
  # AC1 — 201 for TENANT_ADMIN, 403 for every other role (incl. an ordinary tenant's PLATFORM_ADMIN), no row on 403
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC1 -- role gate" do
    test "201 for TENANT_ADMIN, 403 for every other role, no tenant_modules row written on a 403" do
      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac1")

      # REQ-447 PR 2: TENANT_ADMIN holds :ModulesManage (tenant scope) and is the allowed role;
      # an ordinary (non-platform) tenant's PLATFORM_ADMIN holds nothing, so it stays in the 403 loop.
      for role <- Authorization.roles(), role != :TENANT_ADMIN do
        conn = install(tenant_id, [Atom.to_string(role)], %{"module_id" => "fixture"})

        assert conn.status == 403,
               "expected 403 for role #{inspect(role)}, got #{conn.status}"

        assert Installs.list_installed(prefix: prefix) == []
      end

      conn = install(tenant_id, ["TENANT_ADMIN"], %{"module_id" => "fixture"})

      assert conn.status == 201
      body = json(conn)
      assert body["module_id"] == "fixture"
      assert body["version"] == "0.1.0"
      assert is_binary(body["installed_at"])

      assert [%TenantModule{module_id: "fixture"}] = Installs.list_installed(prefix: prefix)
    end
  end

  describe "REQ-447 -- TENANT_ADMIN of the caller's own tenant" do
    test "201 for TENANT_ADMIN installing a module into its own tenant" do
      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req447-modules")

      conn = install(tenant_id, ["TENANT_ADMIN"], %{"module_id" => "fixture"})
      assert conn.status == 201
      assert [%TenantModule{module_id: "fixture"}] = Installs.list_installed(prefix: prefix)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC2 — a body-supplied tenant_id/tenant is ignored (INV-1)
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC2 -- prefix is server-derived only, a body tenant_id/tenant is ignored" do
    test "installing as tenant A's TENANT_ADMIN with tenant B named in the body lands only in tenant A" do
      %{tenant_id: tenant_id_a, schema_name: prefix_a} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac2-a")

      %{tenant_id: tenant_id_b, schema_name: prefix_b} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac2-b")

      conn =
        install(tenant_id_a, ["TENANT_ADMIN"], %{
          "module_id" => "fixture",
          "tenant_id" => tenant_id_b,
          "tenant" => tenant_id_b
        })

      assert conn.status == 201

      assert [%TenantModule{module_id: "fixture"}] = Installs.list_installed(prefix: prefix_a)
      assert Installs.list_installed(prefix: prefix_b) == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC3 — error mapping: 404 unknown module, 409 already installed,
  # 422 missing dependency
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC3 -- error mapping" do
    test "404 for an unknown module id" do
      %{tenant_id: tenant_id} = TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac3-404")

      conn = install(tenant_id, ["TENANT_ADMIN"], %{"module_id" => "does-not-exist"})

      assert conn.status == 404
    end

    test "409 for a second install of the same module" do
      %{tenant_id: tenant_id} = TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac3-409")

      assert install(tenant_id, ["TENANT_ADMIN"], %{"module_id" => "fixture"}).status == 201

      conn = install(tenant_id, ["TENANT_ADMIN"], %{"module_id" => "fixture"})

      assert conn.status == 409
    end

    test "422 for a module whose depends_on is not installed" do
      %{tenant_id: tenant_id} = TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac3-422")

      conn = install(tenant_id, ["TENANT_ADMIN"], %{"module_id" => "fixture_dependent"})

      assert conn.status == 422
      assert json(conn)["detail"] =~ "fixture"
    end

    test "422 when the request body is not a JSON object or module_id is missing/not a string" do
      %{tenant_id: tenant_id} = TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac3-body")

      assert install(tenant_id, ["TENANT_ADMIN"], %{}).status == 422
      assert install(tenant_id, ["TENANT_ADMIN"], %{"module_id" => 123}).status == 422
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # GH 2531 / decision 0052 D3 — `rationale` is REQUIRED (breaking contract)
  # ═══════════════════════════════════════════════════════════════════════

  describe "GH 2531 -- required rationale" do
    test "missing, null, non-string and blank rationale give 422 'rationale is required' and install nothing; a valid one gives 201" do
      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "gh2531-mod")

      for body <- [
            %{"module_id" => "fixture"},
            %{"module_id" => "fixture", "rationale" => nil},
            %{"module_id" => "fixture", "rationale" => 7},
            %{"module_id" => "fixture", "rationale" => ""},
            %{"module_id" => "fixture", "rationale" => "   "}
          ] do
        conn = install_raw(tenant_id, ["TENANT_ADMIN"], body)
        assert conn.status == 422, "#{inspect(body)}: #{conn.status} #{conn.resp_body}"
        assert json(conn)["detail"] == "rationale is required"
        assert Installs.list_installed(prefix: prefix) == []
      end

      conn =
        install_raw(tenant_id, ["TENANT_ADMIN"], %{
          "module_id" => "fixture",
          "rationale" => "enable the fixture module for the pilot"
        })

      assert conn.status == 201, conn.resp_body
      assert [%TenantModule{module_id: "fixture"}] = Installs.list_installed(prefix: prefix)
    end
  end
end
