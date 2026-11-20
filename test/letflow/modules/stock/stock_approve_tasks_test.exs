defmodule Letflow.Modules.Stock.StockApproveTasksTest do
  @moduledoc """
  Decision 0093 F2 (T1-T3, T6 of the stock part): the stock approve, post and reverse HUMAN_TASK nodes of the module
  pack name `required_permission: "StockApprove"`; the storekeeper does not hold it, the tenant admin does. The
  graphs are the REAL ones read from `priv/modules/stock/pack.json`; requests use real API tokens through
  `Letflow.Router` (claim is exercised, not completion with its module write: the refusal happens before it).
  `async: false`: committed tenants.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 3]

  alias Letflow.Api.Authorization
  alias Letflow.Definitions.Graph
  alias Letflow.Identity
  alias Letflow.SodSupport, as: S

  @pack "priv/modules/stock/pack.json"

  defp definitions, do: @pack |> File.read!() |> Jason.decode!() |> Map.fetch!("definitions")

  defp approver_node(definition) do
    definition["graph"]["nodes"]
    |> Enum.find(fn node ->
      node["node_type"] == "HUMAN_TASK" and
        is_list(get_in(node, ["attributes", "module_writes"]))
    end)
  end

  defp post(ctx, user, roles, task_id, action, body \\ %{}) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema_name)

    conn(:post, "/api/v1/tasks/#{task_id}/#{action}", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  # Starts the real process and returns the context with the pending approve/post/reverse task.
  defp case!(graph) do
    # Activation refuses a module write without the stamp of an installed module; the write is irrelevant to the
    # claim check, so it is dropped here. Role, required_permission and shape stay exactly the pack's.
    graph =
      update_in(graph, ["nodes", Access.all()], fn node ->
        update_in(node, [Access.key("attributes", %{})], &Map.delete(&1, "module_writes"))
      end)

    ctx = S.new_case!(graph, %{}, %{})

    node =
      Enum.find(
        graph["nodes"],
        &(get_in(&1, ["attributes", "required_permission"]) == "StockApprove")
      )

    if Enum.any?(graph["nodes"], &(&1["id"] == "submit")) do
      user = S.insert_user!(ctx.schema_name, "submitter")
      S.complete_node!(ctx, "submit", user.id, %{})
    end

    Map.put(ctx, :task, S.pending_task!(ctx, node["id"]))
  end

  test "T6a: the permission is held by the admins and not by the storekeeper (pure)" do
    assert Authorization.permission_scope(:StockApprove) == :tenant

    for role <- [:TENANT_ADMIN, :PLATFORM_ADMIN],
        do: assert(Authorization.role_allows?(role, :StockApprove))

    for role <- Authorization.roles() -- [:TENANT_ADMIN, :PLATFORM_ADMIN],
        do: refute(Authorization.role_allows?(role, :StockApprove), inspect(role))
  end

  test "T5/T6b: every real stock posting node names StockApprove and the graph is valid" do
    defs = definitions()
    assert length(defs) == 10

    for definition <- defs do
      node = approver_node(definition)
      assert node, definition["process_key"]
      assert get_in(node, ["attributes", "required_permission"]) == "StockApprove"
      assert get_in(node, ["attributes", "role"]) == "TENANT_ADMIN"

      assert {:ok, graph} = Graph.from_map(definition["graph"])
      assert %{valid: true} = Graph.validate_graph(graph), definition["process_key"]
    end
  end

  test "T1: the storekeeper cannot claim or complete the approve, post and reverse tasks; the admin can claim" do
    for definition <- definitions() do
      key = definition["process_key"]
      ctx = case!(definition["graph"])
      storekeeper = S.insert_user!(ctx.schema_name, "storekeeper")
      admin = S.insert_user!(ctx.schema_name, "admin")
      :ok = S.grant_role!(ctx.schema_name, "TENANT_ADMIN", [storekeeper.id, admin.id])

      for action <- ["claim", "complete"] do
        conn = post(ctx, storekeeper, ["STOREKEEPER"], ctx.task.id, action)
        assert conn.status == 404, "#{key} #{action}: #{conn.resp_body}"
      end

      assert S.reload_task!(ctx, ctx.task).status == :pending

      claimed = post(ctx, admin, ["TENANT_ADMIN"], ctx.task.id, "claim")
      assert claimed.status == 200, "#{key} admin claim: #{claimed.resp_body}"
    end
  end

  test "T2: reassigning the real receipt and reversal tasks to the storekeeper does not let them in" do
    for key <- ["stock_receipt", "stock_reversal"] do
      definition = Enum.find(definitions(), &(&1["process_key"] == key))
      ctx = case!(definition["graph"])
      storekeeper = S.insert_user!(ctx.schema_name, "storekeeper")
      admin = S.insert_user!(ctx.schema_name, "admin")
      :ok = S.grant_role!(ctx.schema_name, "TENANT_ADMIN", [storekeeper.id, admin.id])

      reassigned =
        post(ctx, admin, ["TENANT_ADMIN"], ctx.task.id, "reassign", %{"user_id" => storekeeper.id})

      assert reassigned.status == 200, reassigned.resp_body
      assert S.reload_task!(ctx, ctx.task).assignee_ref == storekeeper.id

      for action <- ["claim", "complete"] do
        conn = post(ctx, storekeeper, ["STOREKEEPER"], ctx.task.id, action)
        assert conn.status == 404, "#{key} #{action} after reassignment: #{conn.resp_body}"
      end

      assert S.reload_task!(ctx, ctx.task).status == :pending
    end
  end

  test "T3: renaming the routing label to the storekeeper's own role changes nothing" do
    definition = Enum.find(definitions(), &(&1["process_key"] == "stock_receipt"))

    graph =
      put_in(definition["graph"], ["nodes", Access.at(1), "attributes", "role"], "STOREKEEPER")

    ctx = case!(graph)
    storekeeper = S.insert_user!(ctx.schema_name, "storekeeper")
    :ok = S.grant_role!(ctx.schema_name, "STOREKEEPER", [storekeeper.id])

    assert S.reload_task!(ctx, ctx.task).assignee_ref == "STOREKEEPER"

    for action <- ["claim", "complete"] do
      conn = post(ctx, storekeeper, ["STOREKEEPER"], ctx.task.id, action)
      assert conn.status == 404, "#{action}: #{conn.resp_body}"
    end

    assert S.reload_task!(ctx, ctx.task).status == :pending
  end
end
