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
  import Ecto.Query, only: [from: 2]

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
        assert fields_of(conn) == [key]
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
      for key <- @stamp_keys ++ ["activated_by"] do
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
      assert conn.resp_body =~ "module-owned"

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

    test "an unkeyed rollback body passes the field check (control for the 422 loop)",
         %{tenant: tenant} do
      conn =
        call("POST", "/no_such_key/rollback", tenant, %{"target_version" => "1"}, ["TENANT_ADMIN"])

      assert conn.status == 404
    end

    test "PATCH with non-empty variable_schemas on a stamped draft is 409 module-owned and writes nothing",
         %{tenant: tenant, schema: schema} do
      row = stamped!(schema)

      entries = [%{"variable_key" => "k1", "json_schema" => %{"type" => "string"}}]
      conn = call("PATCH", "/#{row.id}", tenant, %{"variable_schemas" => entries})

      assert conn.status == 409
      assert conn.resp_body =~ "module-owned"

      assert Repo.all(
               from(v in Letflow.Engine.VariableSchema, where: v.definition_id == ^row.id),
               prefix: schema
             ) == []

      assert Repo.get!(ProcessDefinition, row.id, prefix: schema).description == nil
    end

    # A stamped row that has been ACTIVATED is not a draft any more: PUT/PATCH answer the
    # ordinary 409 "only a DRAFT definition can be modified" (:not_draft), not the
    # module-owned message. Both are 409 and both write nothing.
    test "an activated stamped row answers the ordinary not-draft 409", %{
      tenant: tenant,
      schema: schema
    } do
      row = stamped!(schema)
      assert {:ok, %{definition: _}} = Definitions.activate(row.id, prefix: schema)

      conn = call("PATCH", "/#{row.id}", tenant, %{"description" => "late"})
      assert conn.status == 409
      assert conn.resp_body =~ "DRAFT"
    end

    # T-3014 (class test): EVERY tenant-API path that retires a definition refuses a module-owned
    # version and leaves the row untouched -- the incident was DELETE answering 200 and archiving
    # the module's ACTIVE stock_receipt on a QA tenant.
    test "DELETE, deprecate and archive of a stamped ACTIVE or DEPRECATED row answer 409 and write nothing",
         %{tenant: tenant, schema: schema} do
      active = stamped!(schema)
      assert {:ok, %{definition: _}} = Definitions.activate(active.id, prefix: schema)

      dep = stamped!(schema)
      assert {:ok, %{definition: _}} = Definitions.activate(dep.id, prefix: schema)

      Letflow.Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^dep.id),
        [set: [status: :deprecated]],
        prefix: schema
      )

      for {row, status} <- [{active, :active}, {dep, :deprecated}],
          {method, path} <- [
            {"DELETE", "/#{row.id}"},
            {"POST", "/#{row.id}/deprecate"},
            {"POST", "/#{row.id}/archive"}
          ] do
        conn = call(method, path, tenant, nil, ["TENANT_ADMIN"])

        assert conn.status == 409,
               "#{method} #{path} (#{status}): #{conn.status} #{conn.resp_body}"

        assert conn.resp_body =~ "module-owned"
        reloaded = Letflow.Repo.get!(ProcessDefinition, row.id, prefix: schema)
        assert reloaded.status == status
        assert is_nil(reloaded.archived_at)
      end

      assert {:error, :module_owned_definition} = Definitions.deprecate(active.id, prefix: schema)
      assert {:error, :module_owned_definition} = Definitions.archive(dep.id, prefix: schema)

      # control: a tenant-made row is still retired by DELETE
      plain = plain!(schema)
      assert {:ok, %{definition: _}} = Definitions.activate(plain.id, prefix: schema)
      assert call("DELETE", "/#{plain.id}", tenant, nil, ["TENANT_ADMIN"]).status == 200
    end

    test "activate, deprecate, archive and rollback of a stamped row are refused without leaking a hash",
         %{tenant: tenant, schema: schema} do
      name = "gh2590-r2-life-#{System.unique_integer([:positive])}"
      v1 = stamped!(schema, name)

      # T-3014: the tenant API refuses every one of them (409), and the body carries no hash
      for action <- ["activate", "deprecate", "archive"] do
        conn = call("POST", "/#{v1.id}/#{action}", tenant, nil, ["TENANT_ADMIN"])
        assert conn.status == 409, "#{action}: #{conn.resp_body}"
        refute conn.resp_body =~ v1.owner_manifest_hash
        refute conn.resp_body =~ v1.owner_body_hash
        refute conn.resp_body =~ "owner_manifest_hash"
        refute conn.resp_body =~ "owner_body_hash"
      end

      assert Repo.get!(ProcessDefinition, v1.id, prefix: schema).status == :draft

      # rollback over a stamped version is refused too
      name = name <> "-rb"
      v1 = stamped!(schema, name)
      assert {:ok, %{definition: _}} = Definitions.activate(v1.id, prefix: schema)

      assert {:ok, v2} =
               Definitions.create(
                 %{name: name, version: "2.0.0", graph: @graph, created_by: Ecto.UUID.generate()},
                 prefix: schema
               )

      assert {:ok, %{definition: _}} = Definitions.activate(v2.id, prefix: schema)

      conn =
        call("POST", "/#{name}/rollback", tenant, %{"target_version" => "1.0.0"}, ["TENANT_ADMIN"])

      assert conn.status == 409, conn.resp_body
      refute conn.resp_body =~ v1.owner_manifest_hash
      refute conn.resp_body =~ "owner_"
      assert Repo.get!(ProcessDefinition, v2.id, prefix: schema).status == :active
    end

    test "GET /active/:name shows the module, never a hash", %{tenant: tenant, schema: schema} do
      name = "gh2590-r2-active-#{System.unique_integer([:positive])}"
      row = stamped!(schema, name)
      assert {:ok, %{definition: _}} = Definitions.activate(row.id, prefix: schema)

      conn = call("GET", "/active/#{name}", tenant, nil)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert body["owner_module"] == "fixture_ledger"
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

    # T-3014 (class table): EVERY mutating tenant route x EVERY module's module-owned definition.
    # The modules come from the catalog, not from a hand list. Each refused attempt answers 409,
    # changes nothing and leaves an audit row with the caller as the actor.
    @tag timeout: 120_000
    test "class table: every mutating route refuses a module-owned definition of every module",
         %{tenant: tenant, schema: schema} do
      modules = Letflow.Modules.Catalog.entry_modules()
      assert length(modules) >= 8

      for mod <- modules do
        owner = ManagedTypes.module_owner(mod)
        id = owner.module_id
        n = System.unique_integer([:positive])

        make = fn name, version ->
          assert {:ok, row} =
                   Definitions.create_owned(
                     %{
                       name: name,
                       version: version,
                       graph: @graph,
                       created_by: Ecto.UUID.generate()
                     },
                     [prefix: schema],
                     owner
                   )

          row
        end

        active_name = "cls-#{id}-act-#{n}"
        active = make.(active_name, "1.0.0")
        assert {:ok, _} = Definitions.activate(active.id, prefix: schema)
        draft = make.("cls-#{id}-draft-#{n}", "1.0.0")

        dep = make.("cls-#{id}-dep-#{n}", "1.0.0")
        assert {:ok, _} = Definitions.activate(dep.id, prefix: schema)

        Letflow.Repo.update_all(
          from(d in ProcessDefinition, where: d.id == ^dep.id),
          [set: [status: :deprecated]],
          prefix: schema
        )

        # a tenant draft of the module's ACTIVE name: activating it would retire the module's row
        assert {:ok, tenant_draft} =
                 Definitions.create(
                   %{
                     name: active_name,
                     version: "9.0.0",
                     graph: @graph,
                     created_by: Ecto.UUID.generate()
                   },
                   prefix: schema
                 )

        snapshot = fn ->
          Repo.all(from(d in ProcessDefinition, order_by: d.id), prefix: schema)
          |> Enum.map(&{&1.id, &1.status, &1.updated_at, &1.description})
        end

        before = snapshot.()
        body = %{"description" => "x"}

        attempts = [
          {"DELETE", "/#{active.id}", nil},
          {"DELETE", "/#{dep.id}", nil},
          {"DELETE", "/#{draft.id}", nil},
          {"POST", "/#{active.id}/deprecate", nil},
          {"POST", "/#{dep.id}/archive", nil},
          {"POST", "/#{draft.id}/activate", nil},
          {"POST", "/#{tenant_draft.id}/activate", nil},
          {"PUT", "/#{draft.id}",
           %{"name" => draft.name, "version" => "1.0.0", "graph" => @graph}},
          {"PATCH", "/#{draft.id}", body},
          {"POST", "/#{active_name}/rollback", %{"target_version" => "9.0.0"}}
        ]

        for {method, path, req_body} <- attempts do
          conn = call(method, path, tenant, req_body, ["TENANT_ADMIN"])

          assert conn.status in [403, 404, 409], "#{id} #{method} #{path}: #{conn.status}"
          refute conn.status == 200
        end

        assert snapshot.() == before, "#{id}: a refused attempt changed state"
      end

      %{rows: [[refused]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          ~s|SELECT count(*) FROM "#{schema}"."audit_entries" WHERE action LIKE '%.refused'|,
          []
        )

      assert refused >= length(modules) * 9
    end

    test "tenant-owned definitions (and a tenant copy of a module definition) stay retirable",
         %{tenant: tenant, schema: schema} do
      plain = plain!(schema)
      assert {:ok, %{definition: _}} = Definitions.activate(plain.id, prefix: schema)

      assert call("POST", "/#{plain.id}/deprecate", tenant, nil, ["TENANT_ADMIN"]).status == 200
      assert call("POST", "/#{plain.id}/archive", tenant, nil, ["TENANT_ADMIN"]).status == 200

      # the tenant's own copy of a module definition (export, import: lands unstamped)
      row = stamped!(schema)
      exported = call("GET", "/#{row.id}/export", tenant, nil).resp_body |> Jason.decode!()
      imported = Map.put(exported, "name", "fork-#{System.unique_integer([:positive])}")
      copy = call("POST", "/import", tenant, imported).resp_body |> Jason.decode!()

      assert {:ok, %{definition: _}} = Definitions.activate(copy["id"], prefix: schema)
      assert call("POST", "/#{copy["id"]}/deprecate", tenant, nil, ["TENANT_ADMIN"]).status == 200
      assert call("POST", "/#{copy["id"]}/archive", tenant, nil, ["TENANT_ADMIN"]).status == 200
      assert Repo.get!(ProcessDefinition, copy["id"], prefix: schema).status == :archived
    end
  end
end
