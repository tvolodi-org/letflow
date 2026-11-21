defmodule Letflow.Modules.Assets.AssetsApproveTasksTest do
  @moduledoc """
  T-2506: the assets post, reverse and approve HUMAN_TASK nodes of the module pack name
  `required_permission: "AssetsApprove"`; the storekeeper does not hold it, the tenant admin does.
  The graphs are the REAL ones read from `priv/modules/assets/pack.json`; requests use real API
  tokens through `Letflow.Router`. The module write is omitted from these isolated process fixtures
  so the allowed completion proves the task gate without posting a document.
  `async: false`: committed tenants.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 3]

  alias Letflow.Api.Authorization
  alias Letflow.Definitions.Graph
  alias Letflow.Identity
  alias Letflow.SodSupport, as: S

  @pack "priv/modules/assets/pack.json"

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
    # Activation refuses a module write without the stamp of an installed module; the write is
    # irrelevant to this task gate. Role, required_permission and shape stay exactly the pack's.
    node = Enum.find(graph["nodes"], &is_list(get_in(&1, ["attributes", "module_writes"])))

    graph =
      update_in(graph, ["nodes", Access.all()], fn node ->
        update_in(node, [Access.key("attributes", %{})], &Map.delete(&1, "module_writes"))
      end)

    ctx = S.new_case!(graph, %{}, %{})

    if Enum.any?(graph["nodes"], &(&1["id"] == "submit")) do
      user = S.insert_user!(ctx.schema_name, "submitter")
      S.complete_node!(ctx, "submit", user.id, %{})
    end

    Map.put(ctx, :task, S.pending_task!(ctx, node["id"]))
  end

  test "AA-1 every real assets post, reverse and approve node names AssetsApprove" do
    defs = definitions()
    assert length(defs) == 7

    for definition <- defs do
      node = approver_node(definition)
      assert node, definition["process_key"]
      assert get_in(node, ["attributes", "required_permission"]) == "AssetsApprove"
      assert get_in(node, ["attributes", "role"]) == "TENANT_ADMIN"

      assert {:ok, graph} = Graph.from_map(definition["graph"])
      assert %{valid: true} = Graph.validate_graph(graph), definition["process_key"]
    end
  end

  test "AA-2 AssetsPost does not let the storekeeper approve; the administrators hold AssetsApprove" do
    overlay = %{STOREKEEPER: [:AssetsRead, :AssetsPost]}
    assert Authorization.role_allows?(:STOREKEEPER, :AssetsPost, overlay)
    refute Authorization.role_allows?(:STOREKEEPER, :AssetsApprove, overlay)

    for role <- [:TENANT_ADMIN, :PLATFORM_ADMIN],
        do: assert(Authorization.role_allows?(role, :AssetsApprove))
  end

  @tag timeout: 120_000
  test "AA-3 the storekeeper cannot claim or complete a real assets task; the admin can" do
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

      completed = post(ctx, admin, ["TENANT_ADMIN"], ctx.task.id, "complete")
      assert completed.status == 200, "#{key} admin complete: #{completed.resp_body}"
      assert S.reload_task!(ctx, ctx.task).status == :completed
    end
  end
end
