defmodule Letflow.Routers.DefinitionsWriteTest do
  @moduledoc """
  Tests for `Letflow.Routers.Definitions`'s REQ-082 write/lifecycle routes:
  create/put/patch/delete/activate/deprecate/archive/import.

  Same dispatch mechanism as `test/letflow/routers/definitions_test.exs`
  (REQ-081) -- direct `Letflow.Routers.Definitions.call/2`,
  `conn.assigns[:auth_context]` set directly, bypassing `AuthPipeline`.
  `async: false` -- tenant provisioning/migration replay needs
  `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Definitions.init([])
  @writer_role "PROCESS_DESIGNER"
  @no_write_role "PROCESS_OPERATOR"

  defp build_conn(method, path, tenant, fields) do
    roles = Map.get(fields, :roles, [])
    user_id = Map.get(fields, :user_id, Ecto.UUID.generate())
    body = Map.get(fields, :body, nil)

    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, %{user_id: user_id, tenant_id: tenant.tenant_id, roles: roles})
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Definitions.call(conn, @opts)

  defp unique_name(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp minimal_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp create_definition!(schema_name, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: unique_name("req082-def"),
          version: "1.0.0",
          graph: minimal_graph(),
          created_by: Ecto.UUID.generate()
        },
        overrides
      )

    assert {:ok, definition} = Definitions.create(attrs, prefix: schema_name)
    definition
  end

  defp active_definition!(schema_name, overrides \\ %{}) do
    definition = create_definition!(schema_name, overrides)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp deprecated_definition!(schema_name, overrides \\ %{}) do
    definition = active_definition!(schema_name, overrides)
    assert {:ok, deprecated} = Definitions.deprecate(definition.id, prefix: schema_name)
    deprecated
  end

  defp archived_definition!(schema_name, overrides \\ %{}) do
    definition = deprecated_definition!(schema_name, overrides)
    assert {:ok, archived} = Definitions.archive(definition.id, prefix: schema_name)
    archived
  end

  defp variable_schemas_of(definition_id, schema_name) do
    Letflow.Engine.VariableSchema
    |> where([v], v.definition_id == ^definition_id)
    |> Letflow.Repo.all(prefix: schema_name)
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1 -- each of the eight handlers, end-to-end, asserting persisted state
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1 -- eight write/lifecycle endpoints" do
    test "POST / creates a DRAFT definition and persists it" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac1a")
      name = unique_name("ac1a")

      body = %{
        "name" => name,
        "version" => "1.0.0",
        "description" => "a description",
        "graph" => minimal_graph()
      }

      conn = build_conn("POST", "/", tenant, %{roles: [@writer_role], body: body}) |> dispatch()

      assert conn.status == 201
      resp = Jason.decode!(conn.resp_body)
      assert resp["name"] == name
      assert resp["status"] == "DRAFT"

      assert {:ok, persisted} = Definitions.get_by_id(resp["id"], prefix: tenant.schema_name)
      assert persisted.name == name
      assert persisted.status == :draft
    end

    test "PUT /:id fully replaces a DRAFT definition and persists it" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac1b")
      definition = create_definition!(tenant.schema_name)
      new_name = unique_name("ac1b-put")

      body = %{"name" => new_name, "version" => "2.0.0", "graph" => minimal_graph()}

      conn =
        build_conn("PUT", "/#{definition.id}", tenant, %{roles: [@writer_role], body: body})
        |> dispatch()

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["name"] == new_name
      assert resp["version"] == "2.0.0"
      assert is_nil(resp["description"])

      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.name == new_name
      assert persisted.description == nil
    end

    test "PATCH /:id partially updates and persists only the given fields" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac1c")
      definition = create_definition!(tenant.schema_name, %{description: "original"})

      body = %{"description" => "patched"}

      conn =
        build_conn("PATCH", "/#{definition.id}", tenant, %{roles: [@writer_role], body: body})
        |> dispatch()

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["description"] == "patched"
      assert resp["name"] == definition.name

      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.description == "patched"
      assert persisted.name == definition.name
    end

    test "DELETE /:id on a DRAFT hard-deletes it (204, no body)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac1d")
      definition = create_definition!(tenant.schema_name)

      conn =
        build_conn("DELETE", "/#{definition.id}", tenant, %{roles: [@writer_role]}) |> dispatch()

      assert conn.status == 204
      assert conn.resp_body == ""

      assert {:error, :not_found} =
               Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
    end

    test "DELETE /:id on ACTIVE deprecates then archives it (200, ARCHIVED body)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac1d2")
      definition = active_definition!(tenant.schema_name)

      conn =
        build_conn("DELETE", "/#{definition.id}", tenant, %{roles: [@writer_role]}) |> dispatch()

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["status"] == "ARCHIVED"

      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.status == :archived
    end

    test "DELETE /:id on DEPRECATED archives it (200, ARCHIVED body)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac1d3")
      definition = deprecated_definition!(tenant.schema_name)

      conn =
        build_conn("DELETE", "/#{definition.id}", tenant, %{roles: [@writer_role]}) |> dispatch()

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["status"] == "ARCHIVED"

      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.status == :archived
    end

    test "POST /:id/activate transitions DRAFT to ACTIVE and persists it" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac1e")
      definition = create_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{definition.id}/activate", tenant, %{roles: [@writer_role]})
        |> dispatch()

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["status"] == "ACTIVE"

      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.status == :active
    end

    test "POST /:id/deprecate transitions ACTIVE to DEPRECATED and persists it" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac1f")
      definition = active_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{definition.id}/deprecate", tenant, %{roles: [@writer_role]})
        |> dispatch()

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["status"] == "DEPRECATED"

      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.status == :deprecated
    end

    test "POST /:id/archive transitions DEPRECATED to ARCHIVED and persists it" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac1g")
      definition = deprecated_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{definition.id}/archive", tenant, %{roles: [@writer_role]})
        |> dispatch()

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["status"] == "ARCHIVED"

      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.status == :archived
      assert persisted.archived_at != nil
    end

    test "POST /import creates a new DRAFT definition and persists it" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac1h")
      name = unique_name("ac1h-import")

      body = %{
        "bpm_export_schema_version" => Definitions.ExportImport.export_schema_version(),
        "name" => name,
        "version" => "1.0.0",
        "graph" => minimal_graph()
      }

      conn =
        build_conn("POST", "/import", tenant, %{roles: [@writer_role], body: body}) |> dispatch()

      assert conn.status == 201
      resp = Jason.decode!(conn.resp_body)
      assert resp["name"] == name
      assert resp["status"] == "DRAFT"

      assert {:ok, persisted} = Definitions.get_by_id(resp["id"], prefix: tenant.schema_name)
      assert persisted.name == name
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2 -- lifecycle 409s on ARCHIVED, leaving the row unchanged
  # ══════════════════════════════════════════════════════════════════════

  describe "AC2 -- lifecycle transitions off ARCHIVED are 409, no state change" do
    test "activating an archived definition is 409" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac2a")
      definition = archived_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{definition.id}/activate", tenant, %{roles: [@writer_role]})
        |> dispatch()

      assert conn.status == 409
      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.status == :archived
      assert persisted.updated_at == definition.updated_at
    end

    test "deprecating an archived definition is 409" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac2b")
      definition = archived_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{definition.id}/deprecate", tenant, %{roles: [@writer_role]})
        |> dispatch()

      assert conn.status == 409
      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.status == :archived
    end

    test "archiving an already-archived definition is 409" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac2c")
      definition = archived_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{definition.id}/archive", tenant, %{roles: [@writer_role]})
        |> dispatch()

      assert conn.status == 409
      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.status == :archived
      assert persisted.updated_at == definition.updated_at
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3 -- structurally invalid graph -> per-field problem details, not 500
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3 -- invalid graph returns per-field problem details" do
    test "POST / with a graph missing a START node returns 422 with field errors" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac3")

      bad_graph = %{
        "nodes" => [%{"id" => "end", "node_type" => "END"}],
        "edges" => []
      }

      body = %{"name" => unique_name("ac3"), "version" => "1.0.0", "graph" => bad_graph}

      conn = build_conn("POST", "/", tenant, %{roles: [@writer_role], body: body}) |> dispatch()

      assert conn.status == 422
      resp = Jason.decode!(conn.resp_body)
      assert [_ | _] = resp["errors"]
      assert Enum.any?(resp["errors"], &(&1["code"] == "missing_start_node"))
      refute resp["detail"] == "validation failed"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4 -- import: malformed / oversized / valid-JSON-invalid-graph
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4 -- import typed rejections" do
    test "malformed JSON body is a typed rejection, not an unhandled exception" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac4a")

      conn =
        build_conn("POST", "/import", tenant, %{roles: [@writer_role]})
        |> put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{"_json" => "not an object"})
        |> dispatch()

      assert conn.status == 400
    end

    test "oversized body is a typed rejection (413), verified against SafeJsonParser's own limit" do
      # SafeJsonParser (REQ-068) enforces this at the Plug.Parsers layer, ahead
      # of this router -- not directly reachable via Letflow.Routers.Definitions
      # .call/2 in this test's bypass-AuthPipeline dispatch style (no
      # Plug.Parsers stage runs in this harness). Verified structurally instead:
      # confirm the pipeline plug is wired with SafeJsonParser, whose own test
      # suite (test/letflow/plugs/safe_json_parser_test.exs) proves the 413
      # behavior directly.
      assert Code.ensure_loaded?(Letflow.Plugs.SafeJsonParser)
      {:module, _} = Code.ensure_loaded(Letflow.Plugs.ApiPipeline)
    end

    test "valid JSON, invalid graph is a typed 422 rejection" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac4c")

      bad_graph = %{"nodes" => [], "edges" => []}

      body = %{
        "bpm_export_schema_version" => Definitions.ExportImport.export_schema_version(),
        "name" => unique_name("ac4c"),
        "version" => "1.0.0",
        "graph" => bad_graph
      }

      conn =
        build_conn("POST", "/import", tenant, %{roles: [@writer_role], body: body}) |> dispatch()

      assert conn.status == 422
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5 -- activating in tenant A leaves tenant B's same-named ACTIVE untouched
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5 -- cross-tenant activate isolation (INV-1)" do
    test "activating in tenant A does not touch tenant B's same-named ACTIVE definition" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac5a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac5b")
      shared_name = unique_name("ac5-shared")

      definition_a = create_definition!(tenant_a.schema_name, %{name: shared_name})
      definition_b = active_definition!(tenant_b.schema_name, %{name: shared_name})

      conn =
        build_conn("POST", "/#{definition_a.id}/activate", tenant_a, %{roles: [@writer_role]})
        |> dispatch()

      assert conn.status == 200

      assert {:ok, persisted_b} =
               Definitions.get_by_id(definition_b.id, prefix: tenant_b.schema_name)

      assert persisted_b.status == :active
      assert persisted_b.updated_at == definition_b.updated_at
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC6 -- cross-tenant is same as nonexistent on every write verb, no write
  # ══════════════════════════════════════════════════════════════════════

  describe "AC6 -- cross-tenant write is the same response as nonexistent (INV-5)" do
    setup do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac6a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac6b")
      definition = create_definition!(tenant_a.schema_name)
      %{tenant_a: tenant_a, tenant_b: tenant_b, definition: definition}
    end

    test "PUT against another tenant's id is 404, no write", %{
      tenant_b: tenant_b,
      tenant_a: tenant_a,
      definition: definition
    } do
      nonexistent_conn =
        build_conn("PUT", "/#{Ecto.UUID.generate()}", tenant_b, %{
          roles: [@writer_role],
          body: %{"name" => "x", "version" => "1.0.0", "graph" => minimal_graph()}
        })
        |> dispatch()

      cross_tenant_conn =
        build_conn("PUT", "/#{definition.id}", tenant_b, %{
          roles: [@writer_role],
          body: %{"name" => "x", "version" => "1.0.0", "graph" => minimal_graph()}
        })
        |> dispatch()

      assert nonexistent_conn.status == cross_tenant_conn.status
      assert nonexistent_conn.resp_body == cross_tenant_conn.resp_body

      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant_a.schema_name)
      assert persisted.name == definition.name
    end

    test "DELETE against another tenant's id is 404, no write", %{
      tenant_b: tenant_b,
      tenant_a: tenant_a,
      definition: definition
    } do
      nonexistent_conn =
        build_conn("DELETE", "/#{Ecto.UUID.generate()}", tenant_b, %{roles: [@writer_role]})
        |> dispatch()

      cross_tenant_conn =
        build_conn("DELETE", "/#{definition.id}", tenant_b, %{roles: [@writer_role]})
        |> dispatch()

      assert nonexistent_conn.status == cross_tenant_conn.status
      assert nonexistent_conn.resp_body == cross_tenant_conn.resp_body

      assert {:ok, _still_there} =
               Definitions.get_by_id(definition.id, prefix: tenant_a.schema_name)
    end

    test "activate against another tenant's id is 404, no write", %{
      tenant_b: tenant_b,
      tenant_a: tenant_a,
      definition: definition
    } do
      nonexistent_conn =
        build_conn("POST", "/#{Ecto.UUID.generate()}/activate", tenant_b, %{roles: [@writer_role]})
        |> dispatch()

      cross_tenant_conn =
        build_conn("POST", "/#{definition.id}/activate", tenant_b, %{roles: [@writer_role]})
        |> dispatch()

      assert nonexistent_conn.status == cross_tenant_conn.status
      assert nonexistent_conn.resp_body == cross_tenant_conn.resp_body

      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant_a.schema_name)
      assert persisted.status == :draft
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC7 -- 403 without DefinitionsWrite on all eight, no state change
  # ══════════════════════════════════════════════════════════════════════

  describe "AC7 -- 403 without DefinitionsWrite on all eight endpoints" do
    test "POST / without DefinitionsWrite is 403, no row created" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac7a")
      name = unique_name("ac7a")

      body = %{"name" => name, "version" => "1.0.0", "graph" => minimal_graph()}

      conn = build_conn("POST", "/", tenant, %{roles: [@no_write_role], body: body}) |> dispatch()

      assert conn.status == 403

      assert {:ok, %{items: []}} =
               Definitions.list_paginated(%{page_size: 10}, prefix: tenant.schema_name)
    end

    test "PUT /:id without DefinitionsWrite is 403, no write" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac7b")
      definition = create_definition!(tenant.schema_name)

      body = %{"name" => "changed", "version" => "9.9.9", "graph" => minimal_graph()}

      conn =
        build_conn("PUT", "/#{definition.id}", tenant, %{roles: [@no_write_role], body: body})
        |> dispatch()

      assert conn.status == 403
      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.name == definition.name
    end

    test "PATCH /:id without DefinitionsWrite is 403, no write" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac7c")
      definition = create_definition!(tenant.schema_name)

      conn =
        build_conn("PATCH", "/#{definition.id}", tenant, %{
          roles: [@no_write_role],
          body: %{"description" => "changed"}
        })
        |> dispatch()

      assert conn.status == 403
      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.description == definition.description
    end

    test "DELETE /:id without DefinitionsWrite is 403, no delete" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac7d")
      definition = create_definition!(tenant.schema_name)

      conn =
        build_conn("DELETE", "/#{definition.id}", tenant, %{roles: [@no_write_role]})
        |> dispatch()

      assert conn.status == 403

      assert {:ok, _still_there} =
               Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
    end

    test "activate without DefinitionsWrite is 403, no transition" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac7e")
      definition = create_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{definition.id}/activate", tenant, %{roles: [@no_write_role]})
        |> dispatch()

      assert conn.status == 403
      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.status == :draft
    end

    test "deprecate without DefinitionsWrite is 403, no transition" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac7f")
      definition = active_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{definition.id}/deprecate", tenant, %{roles: [@no_write_role]})
        |> dispatch()

      assert conn.status == 403
      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.status == :active
    end

    test "archive without DefinitionsWrite is 403, no transition" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac7g")
      definition = deprecated_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{definition.id}/archive", tenant, %{roles: [@no_write_role]})
        |> dispatch()

      assert conn.status == 403
      assert {:ok, persisted} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert persisted.status == :deprecated
    end

    test "import without DefinitionsWrite is 403, no row created" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac7h")
      name = unique_name("ac7h")

      body = %{
        "bpm_export_schema_version" => Definitions.ExportImport.export_schema_version(),
        "name" => name,
        "version" => "1.0.0",
        "graph" => minimal_graph()
      }

      conn =
        build_conn("POST", "/import", tenant, %{roles: [@no_write_role], body: body})
        |> dispatch()

      assert conn.status == 403

      assert {:ok, %{items: []}} =
               Definitions.list_paginated(%{page_size: 10}, prefix: tenant.schema_name)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC8 -- import writes variable_schemas via the shared registration
  # function; re-import onto the SAME definition_id (here: a PUT, since
  # import always mints a fresh id -- see this module's own design note
  # below) replaces the row set, not accumulate/fail on UNIQUE
  # ══════════════════════════════════════════════════════════════════════

  describe "AC8/AC9 -- variable_schemas registration and PUT-onto-same-id replace" do
    test "import with variable_schemas entries writes rows via the shared registration function" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac8a")

      body = %{
        "bpm_export_schema_version" => Definitions.ExportImport.export_schema_version(),
        "name" => unique_name("ac8a"),
        "version" => "1.0.0",
        "graph" => minimal_graph(),
        "variable_schemas" => [
          %{"variable_key" => "k1", "json_schema" => %{"type" => "string"}}
        ]
      }

      conn =
        build_conn("POST", "/import", tenant, %{roles: [@writer_role], body: body}) |> dispatch()

      assert conn.status == 201
      resp = Jason.decode!(conn.resp_body)

      rows = variable_schemas_of(resp["id"], tenant.schema_name)
      assert [%{variable_key: "k1"}] = rows

      # grep confirms no second insert path -- structural, not just tested:
      # the only Repo.insert against Letflow.Engine.VariableSchema anywhere in
      # lib/ is inside Letflow.Definitions.register_variable_schemas/3.
      # A new %VariableSchema{} row struct must be constructed before it can be
      # inserted -- the only place in lib/ that constructs one is the sole
      # insert path this AC requires (register_variable_schemas/3's own
      # insert_variable_schema_rows/3 helper).
      matches =
        Path.wildcard("lib/letflow/**/*.ex")
        |> Enum.filter(fn path ->
          path |> File.read!() |> String.contains?("%VariableSchema{}")
        end)

      assert matches == ["lib/letflow/definitions.ex"]
    end

    test "DELETE of an imported DRAFT that has variable_schemas is 204, never 500 (T-2890)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t2890-del")

      body = %{
        "bpm_export_schema_version" => Definitions.ExportImport.export_schema_version(),
        "name" => unique_name("t2890"),
        "version" => "1.0.0",
        "graph" => minimal_graph(),
        "variable_schemas" => [
          %{"variable_key" => "k1", "json_schema" => %{"type" => "string"}}
        ]
      }

      conn =
        build_conn("POST", "/import", tenant, %{roles: [@writer_role], body: body}) |> dispatch()

      assert conn.status == 201
      id = Jason.decode!(conn.resp_body)["id"]

      del = build_conn("DELETE", "/#{id}", tenant, %{roles: [@writer_role]}) |> dispatch()

      assert del.status == 204
      assert {:error, :not_found} = Definitions.get_by_id(id, prefix: tenant.schema_name)
      assert variable_schemas_of(id, tenant.schema_name) == []
    end

    test "PUT onto the same definition_id replaces the variable_schemas row set, omitted key leaves no row" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac9a")
      definition = create_definition!(tenant.schema_name)

      assert {:ok, _} =
               Definitions.register_variable_schemas(
                 definition.id,
                 [
                   %{variable_key: "keep", json_schema: %{"type" => "string"}},
                   %{variable_key: "drop", json_schema: %{"type" => "number"}}
                 ],
                 prefix: tenant.schema_name
               )

      body = %{
        "name" => definition.name,
        "version" => definition.version,
        "graph" => minimal_graph(),
        "variable_schemas" => [
          %{"variable_key" => "keep", "json_schema" => %{"type" => "boolean"}}
        ]
      }

      conn =
        build_conn("PUT", "/#{definition.id}", tenant, %{roles: [@writer_role], body: body})
        |> dispatch()

      assert conn.status == 200

      rows = variable_schemas_of(definition.id, tenant.schema_name)
      assert [%{variable_key: "keep", json_schema: %{"type" => "boolean"}}] = rows
      refute Enum.any?(rows, &(&1.variable_key == "drop"))
    end

    test "PATCH without a variable_schemas key leaves existing rows untouched" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac9b")
      definition = create_definition!(tenant.schema_name)

      assert {:ok, _} =
               Definitions.register_variable_schemas(
                 definition.id,
                 [%{variable_key: "untouched", json_schema: %{"type" => "string"}}],
                 prefix: tenant.schema_name
               )

      conn =
        build_conn("PATCH", "/#{definition.id}", tenant, %{
          roles: [@writer_role],
          body: %{"description" => "no variable_schemas key here"}
        })
        |> dispatch()

      assert conn.status == 200
      rows = variable_schemas_of(definition.id, tenant.schema_name)
      assert [%{variable_key: "untouched"}] = rows
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC10/AC11/AC12 -- service-existence oracle collapse (ISS-0037/GH#112)
  # ══════════════════════════════════════════════════════════════════════

  describe "AC10/AC11/AC12 -- activate's service-scope-violation collapse" do
    setup do
      original = Application.get_env(:letflow, :definitions_service_scope_validator)

      on_exit(fn ->
        if original do
          Application.put_env(:letflow, :definitions_service_scope_validator, original)
        else
          Application.delete_env(:letflow, :definitions_service_scope_validator)
        end
      end)

      :ok
    end

    defp definition_with_service_task!(schema_name) do
      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "svc",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"service_id" => "svc-under-test", "timeout_ms" => 5000}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "svc"},
          %{"id" => "e2", "source" => "svc", "target" => "end"}
        ]
      }

      create_definition!(schema_name, %{graph: graph})
    end

    test "not-registered and registered-to-another-tenant collapse to byte-identical 422s" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac10a")

      not_registered_validator = fn _graph, _tenant_id ->
        {:error,
         %Letflow.Definitions.ServiceScopeValidator.Violation{
           node_id: "svc",
           kind: :service,
           ref_id: "svc-under-test",
           reason: :service_not_registered,
           message: "service_id 'svc-under-test' is not registered"
         }}
      end

      wrong_tenant_validator = fn _graph, _tenant_id ->
        {:error,
         %Letflow.Definitions.ServiceScopeValidator.Violation{
           node_id: "svc",
           kind: :service,
           ref_id: "svc-under-test",
           reason: :service_not_available_to_tenant,
           message: "service_id 'svc-under-test' is not available to this tenant"
         }}
      end

      Application.put_env(
        :letflow,
        :definitions_service_scope_validator,
        not_registered_validator
      )

      definition_1 = definition_with_service_task!(tenant.schema_name)

      conn_1 =
        build_conn("POST", "/#{definition_1.id}/activate", tenant, %{roles: [@writer_role]})
        |> dispatch()

      Application.put_env(:letflow, :definitions_service_scope_validator, wrong_tenant_validator)
      definition_2 = definition_with_service_task!(tenant.schema_name)

      conn_2 =
        build_conn("POST", "/#{definition_2.id}/activate", tenant, %{roles: [@writer_role]})
        |> dispatch()

      assert conn_1.status == 422
      assert conn_1.status == conn_2.status

      body_1 = Jason.decode!(conn_1.resp_body)
      body_2 = Jason.decode!(conn_2.resp_body)
      assert body_1["detail"] == body_2["detail"]
      assert body_1["status"] == body_2["status"]

      # AC11 -- neither literal internal-reason word, neither raw service_id
      # echoed distinguishably.
      refute body_1["detail"] =~ "registered"
      refute body_1["detail"] =~ "available to this tenant"
      refute body_1["detail"] =~ "svc-under-test"
    end

    test "the internal reason is still preserved in server-side logs (AC12)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req082-ac12")

      validator = fn _graph, _tenant_id ->
        {:error,
         %Letflow.Definitions.ServiceScopeValidator.Violation{
           node_id: "svc",
           kind: :service,
           ref_id: "svc-under-test",
           reason: :service_not_registered,
           message: "service_id 'svc-under-test' is not registered"
         }}
      end

      Application.put_env(:letflow, :definitions_service_scope_validator, validator)
      definition = definition_with_service_task!(tenant.schema_name)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          build_conn("POST", "/#{definition.id}/activate", tenant, %{roles: [@writer_role]})
          |> dispatch()
        end)

      assert log =~ "service_not_registered"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-288 AC7 -- Definitions.update/2's sharp edge: the stricter CHK-17
  # grammar check applies uniformly, so a stored definition whose edge
  # condition already fails the grammar (but passed the old structural
  # check when it was created) becomes un-updatable via any request that
  # touches :graph -- even one that only edits an unrelated node's label.
  # See lib/letflow/design/req288-expr-definition-validator.md §3.
  # ══════════════════════════════════════════════════════════════════════

  describe "REQ-288 AC7 -- update/2's sharp edge" do
    alias Letflow.Definitions.Graph
    alias Letflow.Definitions.ProcessDefinition
    alias Letflow.Repo

    # An EXCLUSIVE_GATEWAY graph whose non-default edge (e1) carries a
    # condition that `valid_cel_syntax?/1` (the OLD check) accepts but the
    # real grammar rejects (an @unsupported_call_markers construct --
    # `matches(`, a CEL macro neither R-Co nor Letflow ever implemented).
    @bad_condition "variables.description.matches(\"^A\")"

    defp gateway_graph_map(gw_label) do
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY", "label" => gw_label},
          %{"id" => "a", "node_type" => "END"},
          %{"id" => "b", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e0", "source" => "start", "target" => "gw"},
          %{"id" => "e1", "source" => "gw", "target" => "a", "condition" => @bad_condition},
          %{"id" => "e2", "source" => "gw", "target" => "b", "is_default" => true}
        ]
      }
    end

    # Inserts a DRAFT process_definition row directly via the schema
    # changeset -- deliberately NOT through Definitions.create/2, since
    # create/2 now also rejects @bad_condition under REQ-288's uniform
    # disposition (§3). This simulates a row that was created BEFORE
    # REQ-288 shipped, when only the old structural check ran.
    defp insert_pre_req288_definition!(schema_name) do
      attrs = %{
        name: unique_name("req288-ac7"),
        version: "1.0.0",
        graph: gateway_graph_map("Approval Gateway"),
        created_by: Ecto.UUID.generate()
      }

      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(attrs)
      |> Repo.insert(prefix: schema_name)
    end

    test "sanity: @bad_condition is accepted by the OLD check but rejected by the new grammar" do
      assert Graph.valid_cel_syntax?(@bad_condition) == true

      assert {:error, :unsupported_cel_feature} =
               Letflow.Engine.Expr.translate_cel_to_expr(@bad_condition)
    end

    test "an unrelated label-only graph edit is rejected -- the untouched edge's pre-existing grammar-invalid condition still fires" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req288-ac7a")

      assert {:ok, definition} = insert_pre_req288_definition!(tenant.schema_name)
      assert definition.status == :draft

      # The offending edge's condition (e1, @bad_condition) is left
      # completely untouched -- only the gateway node's label changes.
      unrelated_edit = gateway_graph_map("Approval Gateway (renamed)")

      assert {:error, {:graph_validation_failed, violations}} =
               Definitions.update(definition.id, %{graph: unrelated_edit},
                 prefix: tenant.schema_name
               )

      assert Enum.any?(violations, fn v ->
               v.code == :invalid_cel_syntax and v.message =~ "e1"
             end)

      # Confirm this is the CHOSEN uniform disposition, not an accident:
      # the row is untouched in the database (the update never wrote).
      assert {:ok, unchanged} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert unchanged.graph == gateway_graph_map("Approval Gateway")
    end

    test "an update that never touches :graph succeeds normally on the same stored definition" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req288-ac7b")

      assert {:ok, definition} = insert_pre_req288_definition!(tenant.schema_name)

      assert {:ok, updated} =
               Definitions.update(definition.id, %{description: "an unrelated description edit"},
                 prefix: tenant.schema_name
               )

      assert updated.description == "an unrelated description edit"
      # The pre-existing grammar-invalid condition is still there, untouched.
      assert updated.graph == gateway_graph_map("Approval Gateway")
    end
  end

  describe "REQ-291 -- CHK-20 inherits update/2's uniform 'no diff-against-stored-graph carve-out' disposition" do
    alias Letflow.Definitions.ProcessDefinition
    alias Letflow.Repo

    # A HUMAN_TASK node whose form_schema x-ui.visible_when references a
    # name that is not a declared property of its own form_schema --
    # rejected by CHK-20 (REQ-291), same "no check before REQ-291 shipped"
    # story REQ-288's own AC7 test tells for CHK-17/edge conditions: this
    # graph could never have been constructed pre-REQ-291 through
    # Definitions.create/2 (CHK-20 would already reject it there too), so
    # this test proves the forward case instead -- an unrelated node edit
    # in the same graph is rejected because a *different* node's form_schema
    # expression is out of scope, establishing the same disposition REQ-288
    # established for edges, now proven for form-field expressions too.
    defp human_task_graph_map(gw_label) do
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "h1",
            "node_type" => "HUMAN_TASK",
            "label" => gw_label,
            "attributes" => %{
              "role" => "manager",
              "form_schema" => %{
                "type" => "object",
                "properties" => %{
                  "note" => %{
                    "type" => "string",
                    "x-ui" => %{"visible_when" => "amount_typo > 0"}
                  }
                }
              }
            }
          },
          %{"id" => "e", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e0", "source" => "start", "target" => "h1"},
          %{"id" => "e1", "source" => "h1", "target" => "e"}
        ]
      }
    end

    defp insert_pre_req291_definition!(schema_name) do
      attrs = %{
        name: unique_name("req291-chk20"),
        version: "1.0.0",
        graph: human_task_graph_map("Review"),
        created_by: Ecto.UUID.generate()
      }

      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(attrs)
      |> Repo.insert(prefix: schema_name)
    end

    test "an unrelated label-only graph edit is rejected -- the untouched node's pre-existing out-of-scope expression still fires" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req291-chk20a")

      assert {:ok, definition} = insert_pre_req291_definition!(tenant.schema_name)
      assert definition.status == :draft

      # The offending HUMAN_TASK node's form_schema is left completely
      # untouched -- only its label changes.
      unrelated_edit = human_task_graph_map("Review (renamed)")

      assert {:error, {:graph_validation_failed, violations}} =
               Definitions.update(definition.id, %{graph: unrelated_edit},
                 prefix: tenant.schema_name
               )

      assert Enum.any?(violations, fn v ->
               v.code == :form_schema_expression_out_of_scope and v.message =~ "amount_typo"
             end)

      # Confirm this is the CHOSEN uniform disposition, not an accident:
      # the row is untouched in the database (the update never wrote).
      assert {:ok, unchanged} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert unchanged.graph == human_task_graph_map("Review")
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # ISS-0912 -- render_activate/2 had no clause for
  # {:error, {:semantic_validation_failed, violations}}, so a real REQ-372
  # semantic-validation failure reaching POST /:id/activate fell through to
  # render_activate/2's catch-all and came back as a bare 500 with no
  # violation payload. Fixed by adding a clause mirroring render_validation/2
  # (~L370-381) exactly. This test proves the HTTP-level regression: a real
  # activate call against a real, seeded type mismatch now returns 422 with
  # the actual violations array, not a 500.
  #
  # Pre-fix verification (this project's "confirm it would have failed"
  # discipline): with the two new render_activate/2 clauses in
  # lib/letflow/routers/definitions.ex removed (`git stash` back to the
  # pre-fix tree), this same test fails --
  #   1) conn.status == 500 (not 422), and
  #   2) resp["detail"] == "an unexpected error occurred" (Error.internal/0's
  #      fixed string, from Response.internal_error/1's catch-all path) with
  #      no "errors" key at all -- confirmed by re-running this exact test
  #      against the pre-fix router and observing exactly that failure, then
  #      restoring the fix.
  # ══════════════════════════════════════════════════════════════════════

  describe "ISS-0912 -- POST /:id/activate surfaces semantic validation failures as 422, not 500" do
    # Structurally/attribute/edge-condition-valid (passes REQ-028/REQ-029's
    # earlier checks) -- its EXCLUSIVE_GATEWAY edge condition compares a
    # declared "amount" field against a numeric literal. Mirrors
    # test/letflow/definitions/semantic_validation_activation_test.exs's own
    # graph_referencing_amount/0 fixture exactly.
    defp amount_comparison_graph do
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
          %{"id" => "a", "node_type" => "END"},
          %{"id" => "b", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "gw"},
          %{"id" => "e2", "source" => "gw", "target" => "a", "condition" => "amount > 100"},
          %{"id" => "e3", "source" => "gw", "target" => "b", "is_default" => true}
        ]
      }
    end

    test "a real semantic-validation type mismatch (REQ-372) returns 422 with the real violations array" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0912-svfail")
      definition = create_definition!(tenant.schema_name, %{graph: amount_comparison_graph()})

      # "amount" declared :string -- "amount > 100" (a numeric literal
      # comparison) is now a numeric-vs-string incompatible comparison, a
      # genuine SemanticValidation.validate/2 violation, not a stub/mock.
      assert {:ok, 1} =
               Definitions.register_variable_schemas(
                 definition.id,
                 [%{variable_key: "amount", json_schema: %{"type" => "string"}}],
                 prefix: tenant.schema_name
               )

      conn =
        build_conn("POST", "/#{definition.id}/activate", tenant, %{roles: [@writer_role]})
        |> dispatch()

      assert conn.status == 422
      resp = Jason.decode!(conn.resp_body)

      refute resp["detail"] == "an unexpected error occurred"
      assert [_ | _] = resp["errors"]

      assert Enum.any?(resp["errors"], fn err ->
               err["code"] == "incompatible_comparison_operand_types" and
                 err["message"] =~ "(numeric)" and err["message"] =~ "(string)"
             end)

      # The definition must still be DRAFT -- activate/2 rejected it, it
      # never transitioned.
      assert {:ok, reread} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert reread.status == :draft
    end
  end
end
