defmodule Letflow.Routers.DefinitionsDistinctFromTest do
  @moduledoc """
  HTTP surface of REQ-464's checks through `Letflow.Routers.Definitions` (same dispatch as
  `definitions_required_outputs_test.exs`: direct `call/2`, `auth_context` assigned). See
  `test/specs/REQ-464.md`.

    * checks 1-3 -> 422 `errors[].code` at POST /, PUT /:id, PATCH /:id, POST /import and
      POST /:id/validate (the violation is in `findings`); nothing stored on a refused write
    * check 4 -> the `distinct_from_single_member_role:` WARNING in the POST /:id/validate 200
      body `warnings` (`status` stays `valid`), absent with two members, and NOT in the
      POST /:id/activate 200 body (activation with only a warning succeeds)

  `async: false` (tenant provisioning). No helper has a default argument (ISS-0069).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.SodSupport, as: S
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Definitions.init([])
  @writer_role "PROCESS_DESIGNER"
  @prefix "distinct_from_single_member_role:"

  defp unique(prefix), do: S.unique(prefix)
  defp tenant!(slug), do: TenantFixture.provisioned_tenant!(slug_prefix: slug)

  defp build_conn(method, path, tenant, body) do
    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: [@writer_role]
    })
    |> assign(:trace_id, "req464-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Definitions.call(conn, @opts)

  defp task(id, role, extra),
    do: %{
      "id" => id,
      "node_type" => "HUMAN_TASK",
      "attributes" => Map.merge(%{"role" => role}, extra)
    }

  # start -> first-review -> second-review -> end, `second_extra` merged onto the second.
  defp seq_graph(role, second_extra) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        task("first-review", role, %{}),
        task("second-review", role, second_extra),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e0", "source" => "start", "target" => "first-review"},
        %{"id" => "e1", "source" => "first-review", "target" => "second-review"},
        %{"id" => "e2", "source" => "second-review", "target" => "end"}
      ]
    }
  end

  defp create_body(graph),
    do: %{"name" => unique("req464-http"), "version" => "1.0.0", "graph" => graph}

  defp post_create!(tenant, graph) do
    conn = build_conn("POST", "/", tenant, create_body(graph)) |> dispatch()
    assert conn.status == 201, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  defp errors(conn), do: conn.resp_body |> Jason.decode!() |> Map.fetch!("errors")

  defp definition_count(tenant),
    do:
      Letflow.Repo.aggregate(Definitions.ProcessDefinition, :count, :id,
        prefix: tenant.schema_name
      )

  defp members!(tenant, role, n) do
    users = for i <- 1..n//1, do: S.insert_user!(tenant.schema_name, "http#{i}")
    :ok = S.grant_role!(tenant.schema_name, role, Enum.map(users, & &1.id))
    users
  end

  # Each of the five negative / shape cases: {expected code, listed id in message or nil, graph}.
  defp refused_cases do
    [
      {"invalid_distinct_from", nil, seq_graph("r", %{"distinct_from" => "first-review"})},
      {"invalid_distinct_from", "first-review",
       seq_graph("r", %{"distinct_from" => ["first-review", "first-review"]})},
      {"distinct_from_self_reference", nil,
       seq_graph("r", %{"distinct_from" => ["second-review"]})},
      {"distinct_from_unknown_node", "ghost", seq_graph("r", %{"distinct_from" => ["ghost"]})},
      {"distinct_from_not_human_task", "end", seq_graph("r", %{"distinct_from" => ["end"]})},
      {"distinct_from_downstream_only", "second-review",
       %{
         seq_graph("r", %{})
         | "nodes" => [
             %{"id" => "start", "node_type" => "START"},
             task("first-review", "r", %{"distinct_from" => ["second-review"]}),
             task("second-review", "r", %{}),
             %{"id" => "end", "node_type" => "END"}
           ]
       }},
      {"distinct_from_on_non_human_task", nil,
       %{
         seq_graph("r", %{})
         | "nodes" => [
             %{"id" => "start", "node_type" => "START"},
             task("first-review", "r", %{}),
             task("second-review", "r", %{}),
             %{
               "id" => "end",
               "node_type" => "END",
               "attributes" => %{"distinct_from" => ["first-review"]}
             }
           ]
       }}
    ]
  end

  # =======================================================================================
  # Checks 1-3 over HTTP
  # =======================================================================================

  describe "checks 1-3 over HTTP" do
    test "POST / refuses each violating definition with 422, the reserved code and the node id; no row" do
      tenant = tenant!("req464-http-create")

      for {code, listed, graph} <- refused_cases() do
        conn = build_conn("POST", "/", tenant, create_body(graph)) |> dispatch()

        assert conn.status == 422, "#{code}: #{conn.resp_body}"
        assert [error] = errors(conn), code
        assert error["code"] == code
        assert error["message"] =~ "Node '"
        if listed, do: assert(error["message"] =~ listed)
      end

      assert definition_count(tenant) == 0
    end

    test "PUT /:id and PATCH /:id refuse a violating graph with 422 and store nothing" do
      tenant = tenant!("req464-http-update")
      created = post_create!(tenant, seq_graph("r", %{"distinct_from" => ["first-review"]}))
      bad_graph = seq_graph("r", %{"distinct_from" => ["ghost"]})

      put_conn =
        build_conn("PUT", "/#{created["id"]}", tenant, %{
          "name" => unique("req464-put"),
          "version" => "2.0.0",
          "graph" => bad_graph
        })
        |> dispatch()

      assert put_conn.status == 422
      assert [%{"code" => "distinct_from_unknown_node"}] = errors(put_conn)

      patch_conn =
        build_conn("PATCH", "/#{created["id"]}", tenant, %{"graph" => bad_graph}) |> dispatch()

      assert patch_conn.status == 422
      assert [%{"code" => "distinct_from_unknown_node"}] = errors(patch_conn)

      assert {:ok, stored} = Definitions.get_by_id(created["id"], prefix: tenant.schema_name)

      assert stored.graph["nodes"]
             |> Enum.find(&(&1["id"] == "second-review"))
             |> get_in(["attributes", "distinct_from"]) == ["first-review"]
    end

    test "POST /import refuses a violating graph with 422 and the reserved code" do
      tenant = tenant!("req464-http-import")

      body = %{
        "bpm_export_schema_version" => Definitions.ExportImport.export_schema_version(),
        "name" => unique("req464-import"),
        "version" => "1.0.0",
        "graph" => seq_graph("r", %{"distinct_from" => ["second-review"]})
      }

      conn = build_conn("POST", "/import", tenant, body) |> dispatch()

      assert conn.status == 422
      assert Enum.any?(errors(conn), &(&1["code"] == "distinct_from_self_reference"))
      assert definition_count(tenant) == 0
    end

    test "valid neighbour: POST / accepts a well-formed distinct_from (201 DRAFT)" do
      tenant = tenant!("req464-http-ok")
      body = post_create!(tenant, seq_graph("r", %{"distinct_from" => ["first-review"]}))
      assert body["status"] == "DRAFT"
    end

    test "POST /:id/validate on a stored definition that is clean returns 200 valid with no findings" do
      tenant = tenant!("req464-http-validate-clean")
      created = post_create!(tenant, seq_graph("r", %{"distinct_from" => ["first-review"]}))

      conn = build_conn("POST", "/#{created["id"]}/validate", tenant, nil) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "valid"
      assert body["findings"] == []
    end
  end

  # =======================================================================================
  # Check 4 over HTTP
  # =======================================================================================

  describe "check 4 over HTTP" do
    test "POST /:id/validate 200 carries the single-member warning naming both nodes and the role; status valid, findings []" do
      tenant = tenant!("req464-http-warn")
      role = unique("shared-role")
      _ = members!(tenant, role, 1)
      created = post_create!(tenant, seq_graph(role, %{"distinct_from" => ["first-review"]}))

      conn = build_conn("POST", "/#{created["id"]}/validate", tenant, nil) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "valid"
      assert body["findings"] == []
      assert [line] = Enum.filter(body["warnings"], &String.starts_with?(&1, @prefix))
      assert line =~ role
      assert line =~ "first-review"
      assert line =~ "second-review"
    end

    test "the warning body discloses no member id, username or email" do
      tenant = tenant!("req464-http-leak")
      role = unique("shared-role")
      [member] = members!(tenant, role, 1)
      created = post_create!(tenant, seq_graph(role, %{"distinct_from" => ["first-review"]}))

      conn = build_conn("POST", "/#{created["id"]}/validate", tenant, nil) |> dispatch()

      assert conn.status == 200

      for secret <- [member.id, member.email, member.username, member.display_name] do
        refute conn.resp_body =~ secret
      end
    end

    test "valid neighbour: with two members the validate body has no single-member warning" do
      tenant = tenant!("req464-http-two")
      role = unique("shared-role")
      _ = members!(tenant, role, 2)
      created = post_create!(tenant, seq_graph(role, %{"distinct_from" => ["first-review"]}))

      conn = build_conn("POST", "/#{created["id"]}/validate", tenant, nil) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      refute Enum.any?(body["warnings"], &String.starts_with?(&1, @prefix))
      refute conn.resp_body =~ "distinct_from_single_member_role"
    end

    test "POST /:id/activate of a definition that WOULD warn is 200 ACTIVE; the body carries no warnings and no warning text" do
      tenant = tenant!("req464-http-activate")
      role = unique("shared-role")
      _ = members!(tenant, role, 1)
      created = post_create!(tenant, seq_graph(role, %{"distinct_from" => ["first-review"]}))

      conn = build_conn("POST", "/#{created["id"]}/activate", tenant, nil) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ACTIVE"
      refute Map.has_key?(body, "warnings")
      refute conn.resp_body =~ "distinct_from_single_member_role"
    end
  end
end
