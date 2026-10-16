defmodule Letflow.Routers.DefinitionsOwnerStampTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R2 (design 4.8, OQ-R11, F-10): the module ownership stamp over HTTP.

    * POST / PUT / PATCH / import / rollback bodies naming any of `owner_module`,
      `owner_module_version`, `owner_manifest_hash`, `owner_body_hash` (and, as a labelled
      scope extension, `activated_by`) are refused 422 BEFORE anything is written, even with
      a null value;
    * a stamped row cannot be PUT/PATCHed (409), and can be read;
    * `owner_module` / `owner_module_version` are read-only fields of the definition
      representation; the two hashes are never serialised; export omits the stamp.

  Same dispatch mechanism as `definitions_write_test.exs` (direct `call/2`, auth context set
  on the conn). `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.FixtureLedger
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Definitions.init([])
  @designer "PROCESS_DESIGNER"

  @graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{"id" => "end", "node_type" => "END"}
    ],
    "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
  }

  @stamp_keys ~w(owner_module owner_module_version owner_manifest_hash owner_body_hash)

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-r2-http")
    {:ok, tenant: tenant, schema: tenant.schema_name}
  end

  defp call(method, path, tenant, body, roles \\ [@designer]) do
    base = conn(method, path)
    base = if body, do: %{base | body_params: body}, else: base

    base
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
    |> then(&Letflow.Routers.Definitions.call(&1, @opts))
  end

  defp stamped!(schema, name \\ nil) do
    assert {:ok, %ProcessDefinition{} = row} =
             Definitions.create_owned(
               %{
                 name: name || "gh2590-r2-http-#{System.unique_integer([:positive])}",
                 version: "1.0.0",
                 graph: @graph,
                 created_by: Ecto.UUID.generate()
               },
               [prefix: schema],
               ManagedTypes.module_owner(FixtureLedger)
             )

    row
  end

  defp plain!(schema) do
    assert {:ok, %ProcessDefinition{} = row} =
             Definitions.create(
               %{
                 name: "gh2590-r2-plain-#{System.unique_integer([:positive])}",
                 version: "1.0.0",
                 graph: @graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema
             )

    row
  end

  defp count(schema) do
    Repo.aggregate(ProcessDefinition, :count, prefix: schema)
  end

  defp fields_of(conn) do
    conn.resp_body |> Jason.decode!() |> Map.fetch!("errors") |> Enum.map(& &1["field"])
  end

  describe "stamp fields are refused on every definition write path (422, nothing written)" do
    test "POST /definitions", %{tenant: tenant, schema: schema} do
      for key <- @stamp_keys ++ ["activated_by"], value <- ["x", nil, %{"a" => 1}] do
        before = count(schema)

        body =
          Map.put(
            %{
              "name" => "n-#{System.unique_integer([:positive])}",
              "version" => "1",
              "graph" => @graph
            },
            key,
            value
          )

        conn = call("POST", "/", tenant, body)
        assert conn.status == 422, "#{key}=#{inspect(value)}"
        assert fields_of(conn) == [key]
        assert count(schema) == before
      end
    end

    test "PUT and PATCH /definitions/:id", %{tenant: tenant, schema: schema} do
      row = plain!(schema)

      for key <- @stamp_keys ++ ["activated_by"] do
        put_body = %{"name" => row.name, "version" => "2", "graph" => @graph, key => "x"}
        conn = call("PUT", "/#{row.id}", tenant, put_body)
        assert conn.status == 422
        assert fields_of(conn) == [key]

        conn = call("PATCH", "/#{row.id}", tenant, %{"description" => "d", key => nil})
        assert conn.status == 422
      end

      assert Repo.get!(ProcessDefinition, row.id, prefix: schema).version == "1.0.0"
    end

    test "POST /definitions/import", %{tenant: tenant, schema: schema} do
      for key <- @stamp_keys ++ ["activated_by"] do
        before = count(schema)

        body = %{
          "bpm_export_schema_version" => Definitions.ExportImport.export_schema_version(),
          "name" => "imp-#{System.unique_integer([:positive])}",
          "version" => "1",
          "graph" => @graph,
          key => "x"
        }

        conn = call("POST", "/import", tenant, body)
        assert conn.status == 422
        assert fields_of(conn) == [key]
        assert count(schema) == before
      end
    end

    test "POST /definitions/:process_key/rollback", %{tenant: tenant} do
      for key <- @stamp_keys do
        conn =
          call(
            "POST",
            "/some_key/rollback",
            tenant,
            %{"target_version" => "1", key => "x"},
            ["TENANT_ADMIN"]
          )

        assert conn.status == 422
        assert fields_of(conn) == [key]
      end
    end

    test "a body without the keys is unaffected", %{tenant: tenant, schema: schema} do
      before = count(schema)

      body = %{
        "name" => "ok-#{System.unique_integer([:positive])}",
        "version" => "1",
        "graph" => @graph
      }

      conn = call("POST", "/", tenant, body)
      assert conn.status == 201
      assert count(schema) == before + 1
    end
  end

  describe "a stamped version over HTTP" do
    test "PUT and PATCH answer 409 and change nothing", %{tenant: tenant, schema: schema} do
      row = stamped!(schema)

      conn =
        call("PUT", "/#{row.id}", tenant, %{
          "name" => row.name,
          "version" => "1.0.0",
          "graph" => @graph
        })

      assert conn.status == 409

      conn = call("PATCH", "/#{row.id}", tenant, %{"description" => "changed"})
      assert conn.status == 409

      assert Repo.get!(ProcessDefinition, row.id, prefix: schema).description == nil
    end

    test "GET shows owner_module and owner_module_version, never a hash", %{
      tenant: tenant,
      schema: schema
    } do
      row = stamped!(schema)
      conn = call("GET", "/#{row.id}", tenant, nil)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert body["owner_module"] == "fixture_ledger"
      assert body["owner_module_version"] == FixtureLedger.manifest().version
      refute Map.has_key?(body, "owner_manifest_hash")
      refute Map.has_key?(body, "owner_body_hash")
      refute conn.resp_body =~ row.owner_manifest_hash
      refute conn.resp_body =~ row.owner_body_hash
    end

    test "an unstamped definition shows null owner fields", %{tenant: tenant, schema: schema} do
      row = plain!(schema)
      body = call("GET", "/#{row.id}", tenant, nil).resp_body |> Jason.decode!()
      assert body["owner_module"] == nil
      assert body["owner_module_version"] == nil
    end

    test "list and active-by-name representations carry no hash", %{
      tenant: tenant,
      schema: schema
    } do
      row = stamped!(schema)
      conn = call("GET", "/", tenant, nil)
      assert conn.status == 200
      refute conn.resp_body =~ row.owner_manifest_hash
      refute conn.resp_body =~ row.owner_body_hash
      assert conn.resp_body =~ "fixture_ledger"
    end

    test "export omits the whole stamp", %{tenant: tenant, schema: schema} do
      row = stamped!(schema)
      conn = call("GET", "/#{row.id}/export", tenant, nil)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      for key <- @stamp_keys, do: refute(Map.has_key?(body, key))
      refute conn.resp_body =~ row.owner_manifest_hash
      refute conn.resp_body =~ "fixture_ledger"
    end

    test "an exported-then-imported stamped definition lands unstamped", %{
      tenant: tenant,
      schema: schema
    } do
      row = stamped!(schema)
      exported = call("GET", "/#{row.id}/export", tenant, nil).resp_body |> Jason.decode!()
      imported = Map.put(exported, "name", "reimported-#{System.unique_integer([:positive])}")

      conn = call("POST", "/import", tenant, imported)
      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["owner_module"] == nil

      copy = Repo.get!(ProcessDefinition, body["id"], prefix: schema)
      assert {copy.owner_module, copy.owner_body_hash} == {nil, nil}
    end
  end
end
