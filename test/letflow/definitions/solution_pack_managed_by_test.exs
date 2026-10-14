defmodule Letflow.Definitions.SolutionPackManagedByTest do
  @moduledoc """
  REQ-496 / GH #2530 AC3, design `lib/letflow/design/req496-managed-by-and-scope-node-paths.md`
  §2.6 and §9 T-13 (spec `test/specs/REQ-496.md`): `managed_by` is set only from a module's compiled
  manifest, never from pack data, so a pack document carrying the key -- at the document top level,
  on an `entity_definitions[]` entry, or inside its `definition_json` -- is
  `{:error, :invalid_pack_document}` from `SolutionPack.install/3` and a 422 "invalid pack document"
  from `POST /solution-packs/install`, with nothing written. A control proves the same pack minus
  the key installs, so the key alone causes the refusal.

  `async: false`: tenant provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EntityDefinition
  alias Letflow.TenantFixture

  @solution_packs_opts Letflow.Routers.SolutionPacks.init([])

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req496-pack-key")

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )
    end)

    {:ok, tenant: tenant}
  end

  defp entity_entry(name) do
    %{
      "entity_definition_id" => Ecto.UUID.generate(),
      "name" => name,
      "display_name" => "REQ-496 #{name}",
      "logical_shape_version" => Base.encode16(:crypto.hash(:sha256, name), case: :lower),
      "definition_json" => %{
        "name" => name,
        "display_name" => "REQ-496 #{name}",
        "fields" => [%{"name" => "name", "type" => "string", "required" => true}]
      }
    }
  end

  defp document(entries) do
    %{
      "pack_id" => "req496-key-pack-#{System.unique_integer([:positive])}",
      "version" => "1.0.0",
      "bpm_export_schema_version" => "bpm/definition/v1",
      "exported_at" => "2026-10-14T00:00:00Z",
      "manifest" => %{"required_roles" => []},
      "definitions" => [],
      "variable_schemas" => [],
      "service_catalog_entries" => [],
      "entity_definitions" => entries
    }
  end

  # The three levels of design §2.6's table that must reject, each with a string and a null value.
  defp carrying_documents(name) do
    for value <- ["fixture_managed", nil] do
      [
        {"document top level #{inspect(value)}",
         document([entity_entry(name)]) |> Map.put("managed_by", value)},
        {"entity_definitions[] entry #{inspect(value)}",
         document([Map.put(entity_entry(name), "managed_by", value)])},
        {"inside definition_json #{inspect(value)}",
         document([put_in(entity_entry(name), ["definition_json", "managed_by"], value)])}
      ]
    end
    |> List.flatten()
  end

  defp nothing_written!(schema, tenant_id, name, pack_id) do
    assert Repo.aggregate(from(d in EntityDefinition, where: d.name == ^name), :count,
             prefix: schema
           ) == 0

    refute Repo.exists?(
             from(i in SolutionPackInstall,
               where: i.tenant_id == ^tenant_id and i.pack_id == ^pack_id
             )
           )
  end

  test "T-13: SolutionPack.install/3 rejects managed_by at each level with :invalid_pack_document",
       %{tenant: tenant} do
    name = "fxm_pack_key"

    for {label, doc} <- carrying_documents(name) do
      assert SolutionPack.install(doc, Ecto.UUID.generate(), prefix: tenant.schema_name) ==
               {:error, :invalid_pack_document},
             label

      nothing_written!(tenant.schema_name, tenant.tenant_id, name, doc["pack_id"])
    end

    # Control: the identical pack without the key installs the type, unstamped.
    assert {:ok, _result} =
             SolutionPack.install(document([entity_entry(name)]), Ecto.UUID.generate(),
               prefix: tenant.schema_name
             )

    assert [nil] =
             Repo.all(from(d in EntityDefinition, where: d.name == ^name, select: d.managed_by),
               prefix: tenant.schema_name
             )
  end

  test "T-13: POST /solution-packs/install answers 422 invalid pack document at each level",
       %{tenant: tenant} do
    name = "fxm_pack_key_http"

    for {label, doc} <- carrying_documents(name) do
      conn =
        Plug.Test.conn(:post, "/install")
        |> Map.put(:body_params, doc)
        |> put_req_header("content-type", "application/json")
        |> assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: tenant.tenant_id,
          roles: ["TENANT_ADMIN"]
        })
        |> assign(:trace_id, "req496-pack-key-trace")
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert conn.status == 422, "#{label}: #{conn.status} #{conn.resp_body}"
      assert Jason.decode!(conn.resp_body)["detail"] == "invalid pack document", label
      nothing_written!(tenant.schema_name, tenant.tenant_id, name, doc["pack_id"])
    end
  end
end
