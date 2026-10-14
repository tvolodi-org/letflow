defmodule Letflow.Routers.SolutionPacksModuleOwnedPackTest do
  @moduledoc """
  REQ-411 AC5/AC6/AC7 — tests the module-owned pack refusal added to
  `POST /api/v1/solution-packs/install`.

  AC5: posting the bilimbaga pack (pack_id = "bilimbaga-question-bank") returns
       HTTP 409 with type containing "module-owned-pack", and afterwards the
       tenant has no solution_pack_installs row, no exam entity definitions, and
       no tenant_modules row.

  AC6: posting a pack whose pack_id is not owned by any catalog module installs
       successfully (HTTP 200).

  AC7: installing the exam MODULE via `Letflow.Modules.Installs.install/3`
       succeeds for the same pack, proving the refusal does not block the
       module-install path.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @solution_packs_opts Letflow.Routers.SolutionPacks.init([])
  @pack_schema_version "bpm/definition/v1"
  @bilimbaga_pack_path Path.join([File.cwd!(), "priv", "modules", "exam", "pack.json"])

  defp bilimbaga_pack_document do
    @bilimbaga_pack_path |> File.read!() |> Jason.decode!()
  end

  defp unowned_pack_document do
    %{
      "pack_id" => "test-unowned-pack-#{:erlang.unique_integer([:positive])}",
      "version" => "1.0.0",
      "bpm_export_schema_version" => @pack_schema_version,
      "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "definitions" => [],
      "service_catalog_entries" => [],
      "variable_schemas" => [],
      "entity_definitions" => [],
      "manifest" => %{"required_roles" => []}
    }
  end

  defp build_conn(method, path, tenant_fixture, body) do
    conn =
      conn(method, path)
      |> Map.put(:body_params, body)
      |> put_req_header("content-type", "application/json")

    conn
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_fixture.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, "req411-module-owned-pack-test")
  end

  defp install_conn(tenant_fixture, body) do
    build_conn(:post, "/install", tenant_fixture, body)
    |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)
  end

  defp cleanup_global_rows!(tenant_id) do
    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
    end)
  end

  # ── AC5 ──────────────────────────────────────────────────────────────────

  describe "AC5: POST /install with a module-owned pack returns 409 module_owned_pack" do
    test "refuses the bilimbaga pack with HTTP 409, type 'module-owned-pack'" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req411-ac5-refuse")
      cleanup_global_rows!(tenant.tenant_id)
      {:ok, _} = EventTypes.seed!(tenant.schema_name)

      resp = install_conn(tenant, bilimbaga_pack_document())

      assert resp.status == 409
      body = Jason.decode!(resp.resp_body)
      assert body["type"] =~ "module-owned-pack"
    end

    test "after refusal: no solution_pack_installs row, no entity definitions, no tenant_modules row" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req411-ac5-clean")
      cleanup_global_rows!(tenant.tenant_id)
      {:ok, _} = EventTypes.seed!(tenant.schema_name)

      resp = install_conn(tenant, bilimbaga_pack_document())
      assert resp.status == 409

      # No solution_pack_installs row created.
      refute Repo.exists?(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      # No exam entity definitions created.
      entity_defs = Repo.all(EntityDefinition, prefix: tenant.schema_name)

      assert entity_defs == [],
             "expected no entity definitions after refused install, got #{inspect(Enum.map(entity_defs, & &1.name))}"

      # No tenant_modules row created.
      refute Repo.exists?(
               from(m in TenantModule, where: m.module_id == "exam"),
               prefix: tenant.schema_name
             )
    end
  end

  # ── AC6 ──────────────────────────────────────────────────────────────────

  describe "AC6: POST /install with an unowned pack succeeds" do
    test "a pack whose pack_id is not owned by any module installs with HTTP 200" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req411-ac6-unowned")
      cleanup_global_rows!(tenant.tenant_id)

      resp = install_conn(tenant, unowned_pack_document())

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert is_binary(body["pack_id"])
      assert body["pack_id"] != "bilimbaga-question-bank"
    end
  end

  # ── AC7 ──────────────────────────────────────────────────────────────────

  describe "AC7: module install bypasses the refusal" do
    test "Installs.install/3 for the exam module succeeds even though POST /install refuses the same pack" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req411-ac7-mod-install")
      cleanup_global_rows!(tenant.tenant_id)
      {:ok, _} = EventTypes.seed!(tenant.schema_name)

      # The HTTP route refuses the pack directly.
      http_resp = install_conn(tenant, bilimbaga_pack_document())
      assert http_resp.status == 409

      # The module install path succeeds for the same pack.
      actor_id = Ecto.UUID.generate()

      assert {:ok, tenant_module} =
               Installs.install("exam", actor_id,
                 prefix: tenant.schema_name,
                 rationale: "test: module install"
               )

      assert tenant_module.module_id == "exam"
    end
  end
end
