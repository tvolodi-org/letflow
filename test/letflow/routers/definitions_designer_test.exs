defmodule Letflow.Routers.DefinitionsDesignerTest do
  @moduledoc """
  T-1563 (process designer, slice 2): the backend half of in-diagram editing.

    * `POST /definitions/:id/validate` with an optional `{"graph": ...}` body runs the SAME
      validators on that graph and persists nothing (B1..B7).
    * `PATCH /definitions/:id` (the draft save) and `POST /definitions` with
      `copy_variable_schemas_from` (the new-version save) are the existing write routes (H1..H6).

  Dispatch is the convention of `definitions_write_test.exs`: a real `Plug.Router` dispatch of
  `Letflow.Routers.Definitions` with `auth_context` set directly, real Postgres.
  The fixtures under `test/fixtures/process_designer/` are shared with the web tests.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SemanticValidation
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Definitions.init([])
  @designer "PROCESS_DESIGNER"
  @reader "PROCESS_OPERATOR"
  @fixtures Path.expand("../../fixtures/process_designer", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
  defp cases, do: fixture("validation_cases.json")["cases"]

  defp build_conn(method, path, tenant, roles, body \\ nil) do
    conn = conn(method, path)

    conn =
      if body,
        do: %{conn | body_params: body} |> put_req_header("content-type", "application/json"),
        else: conn

    conn
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "t1563-trace")
  end

  defp dispatch(conn), do: Letflow.Routers.Definitions.call(conn, @opts)
  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp uniq(p), do: p <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp base_graph, do: Enum.find(cases(), &(&1["name"] == "valid"))["graph"]

  defp create_definition!(schema, graph \\ nil, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: uniq("t1563"),
          version: "1.0.0",
          graph: graph || base_graph(),
          created_by: Ecto.UUID.generate()
        },
        extra
      )

    assert {:ok, d} = Definitions.create(attrs, prefix: schema)
    d
  end

  defp register_vars!(definition, schema) do
    entries = [
      %{variable_key: "amount", json_schema: %{"type" => "number"}, description: "sum"},
      %{variable_key: "customer", json_schema: %{"type" => "string"}, description: nil}
    ]

    assert {:ok, 2} =
             Definitions.register_variable_schemas(definition.id, entries, prefix: schema)
  end

  defp codes(violations), do: violations |> Enum.map(&to_string(&1.code)) |> Enum.sort()
  defp err_codes(body), do: body["errors"] |> Enum.map(& &1["code"]) |> Enum.sort()

  defp oracle(graph_map, declared) do
    {:ok, g} = Graph.from_map(graph_map)

    codes(
      Graph.validate_graph(g).violations ++
        Graph.validate_node_attributes(g).violations ++
        Graph.validate_edge_conditions(g).violations ++
        Graph.validate_flow(g).violations ++
        SemanticValidation.validate(g, declared).violations
    )
  end

  describe "validate preview" do
    test "B1 parity: preview codes = the validators called directly = stored validate" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-b1")
      schema = tenant.schema_name
      host = create_definition!(schema)
      register_vars!(host, schema)
      declared = %{"amount" => %{"type" => "number"}, "customer" => %{"type" => "string"}}

      for c <- cases() do
        resp =
          build_conn("POST", "/#{host.id}/validate", tenant, [@designer], %{"graph" => c["graph"]})
          |> dispatch()

        got = if resp.status == 200, do: [], else: err_codes(json(resp))
        assert got == oracle(c["graph"], declared), "preview vs oracle: #{c["name"]}"

        # Cases the create path accepts are also compared with the stored validate.
        if Map.get(c, "storable", true) and not c["blocking"] do
          d = create_definition!(schema, c["graph"])
          register_vars!(d, schema)

          stored = build_conn("POST", "/#{d.id}/validate", tenant, [@designer]) |> dispatch()
          assert stored.status == resp.status, "stored status: #{c["name"]}"

          stored_codes = if stored.status == 200, do: [], else: err_codes(json(stored))
          assert stored_codes == got, "stored vs preview: #{c["name"]}"
        end
      end
    end

    test "B1b the fixture's blocking flag agrees with Definitions.create" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-b1b")

      for c <- cases() do
        attrs = %{
          name: uniq("blk"),
          version: "1",
          graph: c["graph"],
          created_by: Ecto.UUID.generate()
        }

        created = Definitions.create(attrs, prefix: tenant.schema_name)

        assert match?({:error, _}, created) == c["blocking"],
               "case #{c["name"]} classified blocking=#{c["blocking"]} but create returned #{inspect(created)}"
      end
    end

    test "B2 valid graph is 200 and B3 nothing is persisted" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-b3")
      d = create_definition!(tenant.schema_name)
      edited = fixture("edited_graph.json")

      resp =
        build_conn("POST", "/#{d.id}/validate", tenant, [@designer], %{"graph" => edited})
        |> dispatch()

      assert resp.status == 200
      assert json(resp)["status"] == "valid"

      row = Repo.get!(ProcessDefinition, d.id, prefix: tenant.schema_name)
      assert row.graph == d.graph
      assert row.updated_at == d.updated_at
    end

    test "B4 no body keeps the stored-graph behaviour" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-b4")
      d = create_definition!(tenant.schema_name)
      resp = build_conn("POST", "/#{d.id}/validate", tenant, [@designer]) |> dispatch()
      assert resp.status == 200
      assert json(resp)["definition_id"] == d.id
    end

    test "B5 another tenant's id is the same bytes as an absent id (INV-10)" do
      mine = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-b5a")
      other = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-b5b")
      foreign = create_definition!(other.schema_name)
      body = %{"graph" => base_graph()}

      cross =
        build_conn("POST", "/#{foreign.id}/validate", mine, [@designer], body) |> dispatch()

      absent =
        build_conn("POST", "/#{Ecto.UUID.generate()}/validate", mine, [@designer], body)
        |> dispatch()

      assert cross.status == 404
      assert absent.status == 404
      assert strip_ids(cross.resp_body) == strip_ids(absent.resp_body)
    end

    defp strip_ids(body),
      do: Regex.replace(~r/[0-9a-f]{8}-[0-9a-f-]{27}/, body, "ID")

    test "B6 graph that is not an object is a field error" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-b6")
      d = create_definition!(tenant.schema_name)

      resp =
        build_conn("POST", "/#{d.id}/validate", tenant, [@designer], %{"graph" => "nope"})
        |> dispatch()

      assert resp.status == 422
    end

    test "B7 a reader role may preview (DefinitionsRead)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-b7")
      d = create_definition!(tenant.schema_name)
      body = %{"graph" => base_graph()}
      resp = build_conn("POST", "/#{d.id}/validate", tenant, [@reader], body) |> dispatch()
      refute resp.status in [401, 403, 404]
    end

    test "B8 the request body limit is the root parser's 2 MiB" do
      src = File.read!(Path.expand("../../../lib/letflow/plugs/api_pipeline.ex", __DIR__))
      assert src =~ "length: 2_097_152"
    end
  end

  describe "save through the existing routes" do
    test "H1 PATCH {graph} stores it and leaves name/version/stage/variables alone" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-h1")
      schema = tenant.schema_name
      d = create_definition!(schema, nil, %{description: "keep me", stage: "S1"})
      register_vars!(d, schema)
      edited = fixture("edited_graph.json")

      resp =
        build_conn("PATCH", "/#{d.id}", tenant, [@designer], %{"graph" => edited}) |> dispatch()

      assert resp.status == 200
      row = Repo.get!(ProcessDefinition, d.id, prefix: schema)
      assert Enum.map(row.graph["nodes"], & &1["id"]) == Enum.map(edited["nodes"], & &1["id"])
      assert Enum.map(row.graph["edges"], & &1["id"]) == Enum.map(edited["edges"], & &1["id"])

      assert {row.name, row.version, row.description, row.stage} ==
               {d.name, d.version, "keep me", "S1"}

      kept =
        Repo.all(from(v in Letflow.Engine.VariableSchema, where: v.definition_id == ^d.id),
          prefix: schema
        )

      assert length(kept) == 2
    end

    test "H2 a non-draft is saved as a new draft that keeps the declared variables" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-h2")
      schema = tenant.schema_name
      d = create_definition!(schema)
      register_vars!(d, schema)
      assert {:ok, %{definition: active}} = Definitions.activate(d.id, prefix: schema)

      body = %{
        "name" => active.name,
        "version" => "1.0.1",
        "graph" => fixture("edited_graph.json"),
        "copy_variable_schemas_from" => active.id
      }

      resp = build_conn("POST", "/", tenant, [@designer], body) |> dispatch()
      assert resp.status == 201
      new = json(resp)
      assert new["status"] in ["DRAFT", "draft"]
      assert new["id"] != active.id

      assert {:ok, entries} = Definitions.variable_schema_entries(new["id"], prefix: schema)
      assert Enum.map(entries, & &1.variable_key) == ["amount", "customer"]
      assert Repo.get!(ProcessDefinition, active.id, prefix: schema).graph == active.graph

      v =
        build_conn("POST", "/#{new["id"]}/validate", tenant, [@designer], %{
          "graph" => body["graph"]
        })
        |> dispatch()

      assert v.status == 200
    end

    test "H2b copy field with another tenant's source id is 404 and creates nothing" do
      mine = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-h2b")
      other = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-h2c")
      foreign = create_definition!(other.schema_name)
      name = uniq("h2b")

      body = %{
        "name" => name,
        "version" => "1",
        "graph" => base_graph(),
        "copy_variable_schemas_from" => foreign.id
      }

      resp = build_conn("POST", "/", mine, [@designer], body) |> dispatch()
      assert resp.status == 404

      assert Repo.all(from(d in ProcessDefinition, where: d.name == ^name),
               prefix: mine.schema_name
             ) == []
    end

    test "H2c variable_schemas and copy_variable_schemas_from together are 422" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-h2d")
      d = create_definition!(tenant.schema_name)

      body = %{
        "name" => uniq("h2c"),
        "version" => "1",
        "graph" => base_graph(),
        "variable_schemas" => [],
        "copy_variable_schemas_from" => d.id
      }

      assert build_conn("POST", "/", tenant, [@designer], body) |> dispatch() |> Map.get(:status) ==
               422
    end

    test "H3 PATCH on an ACTIVE definition is 409" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-h3")
      d = create_definition!(tenant.schema_name)
      assert {:ok, _} = Definitions.activate(d.id, prefix: tenant.schema_name)

      resp =
        build_conn("PATCH", "/#{d.id}", tenant, [@designer], %{"graph" => base_graph()})
        |> dispatch()

      assert resp.status == 409
    end

    test "H5 creating a version that already exists is 409" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-h5")
      d = create_definition!(tenant.schema_name)
      body = %{"name" => d.name, "version" => d.version, "graph" => base_graph()}

      assert build_conn("POST", "/", tenant, [@designer], body) |> dispatch() |> Map.get(:status) ==
               409
    end

    test "H6 script task: a pair saves, a key without a version or with service_id is 422" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1563-h6")
      d = create_definition!(tenant.schema_name)

      save = fn graph ->
        build_conn("PATCH", "/#{d.id}", tenant, [@designer], %{"graph" => graph}) |> dispatch()
      end

      assert save.(fixture("edited_graph_script.json")).status == 200

      by_name = Map.new(cases(), &{&1["name"], &1["graph"]})
      no_version = save.(by_name["script_key_no_version"])
      assert no_version.status == 422
      assert "invalid_script_reference" in err_codes(json(no_version))

      conflict = save.(by_name["script_and_service_id"])
      assert conflict.status == 422
      assert "conflicting_service_task_routes" in err_codes(json(conflict))
    end
  end
end
