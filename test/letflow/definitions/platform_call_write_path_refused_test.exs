defmodule Letflow.Definitions.PlatformCallWritePathRefusedTest do
  @moduledoc """
  S3 of the platform-call authority rule (T-2588, "Register a tenant" pilot, gap
  G2; decision record `docs/migration/decisions/0094-platform-call-authority.md`,
  decision (b)): EVERY definition write path refuses a company tenant's
  `platform_call` step with the one fixed code.

  The exploit the security gate showed: `create/2` calls the tenant check, but
  `validate_update_graph/1` took no prefix and omitted it, so a company
  TENANT_ADMIN could `PUT`/`PATCH` a `platform_call` graph into a DRAFT and
  store it.

  The rule: the check runs where the graph is written -- create, update (PUT and
  PATCH), import, promotion, rollback -- and the answer is the ONE fixed code
  `:platform_call_not_allowed` at the HTTP surface too (422), never a 500 and
  never a stored graph.

  `async: false`: the tenant fixture switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx

  @opts Letflow.Routers.Definitions.init([])

  setup do
    company = Fx.tenant!("t2588-write-path")
    %{company: company}
  end

  defp create_call do
    Fx.call("tenant.create", %{
      "slug" => %{"var" => "slug"},
      "name" => %{"const" => "Acme"}
    })
  end

  defp plain_graph do
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

  defp draft!(schema_name, name) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: name,
          version: "1",
          graph: plain_graph(),
          created_by: Ecto.UUID.generate()
        },
        prefix: schema_name
      )

    definition
  end

  defp stored_graph(schema_name, id) do
    Repo.get!(ProcessDefinition, id, prefix: schema_name).graph
  end

  defp build_conn(method, path, tenant, body) do
    conn(method, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Definitions.call(conn, @opts)

  test "S3g: the UPDATE path refuses a company-tenant graph with a platform_call", ctx do
    definition = draft!(ctx.company.schema_name, "pcf-write-update")
    before = stored_graph(ctx.company.schema_name, definition.id)

    assert {:error, {:platform_calls_invalid, [%{code: :platform_call_not_allowed}]}} =
             Definitions.update(definition.id, %{graph: Fx.graph(create_call())},
               prefix: ctx.company.schema_name
             )

    assert stored_graph(ctx.company.schema_name, definition.id) == before
  end

  test "S3i: PUT answers 422 with the one fixed code and stores nothing", ctx do
    definition = draft!(ctx.company.schema_name, "pcf-write-put")
    before = stored_graph(ctx.company.schema_name, definition.id)

    body = %{
      "name" => "pcf-write-put",
      "version" => "1",
      "graph" => Fx.graph(create_call())
    }

    conn =
      build_conn("PUT", "/#{definition.id}", ctx.company, body)
      |> dispatch()

    assert conn.status == 422

    payload = Jason.decode!(conn.resp_body)
    assert payload["error"] == "platform_calls_invalid"
    assert [%{"code" => "platform_call_not_allowed"}] = payload["violations"]

    assert stored_graph(ctx.company.schema_name, definition.id) == before
  end

  test "S3j: PATCH answers 422 with the one fixed code and stores nothing", ctx do
    definition = draft!(ctx.company.schema_name, "pcf-write-http-patch")
    before = stored_graph(ctx.company.schema_name, definition.id)

    body = %{"graph" => Fx.graph(create_call())}

    conn =
      build_conn("PATCH", "/#{definition.id}", ctx.company, body)
      |> dispatch()

    assert conn.status == 422

    payload = Jason.decode!(conn.resp_body)
    assert payload["error"] == "platform_calls_invalid"
    assert [%{"code" => "platform_call_not_allowed"}] = payload["violations"]

    assert stored_graph(ctx.company.schema_name, definition.id) == before
  end

  test "S3k: CREATE answers 422 with the one fixed code (never a 500)", ctx do
    body = %{
      "name" => "pcf-write-create",
      "version" => "1",
      "graph" => Fx.graph(create_call())
    }

    conn =
      build_conn("POST", "/", ctx.company, body)
      |> dispatch()

    assert conn.status == 422

    payload = Jason.decode!(conn.resp_body)
    assert payload["error"] == "platform_calls_invalid"
    assert [%{"code" => "platform_call_not_allowed"}] = payload["violations"]

    assert Repo.get_by(ProcessDefinition, [name: "pcf-write-create"],
             prefix: ctx.company.schema_name
           ) == nil
  end
end
