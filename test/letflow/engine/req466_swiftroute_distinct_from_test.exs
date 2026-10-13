defmodule Letflow.Engine.Req466SwiftrouteDistinctFromTest do
  @moduledoc """
  REQ-466 (swiftroute half) -- the shipped SwiftRoute "Shipment Approval" fixture (v1.7) adopts
  `distinct_from` (REQ-459 rule A, enforced by REQ-463) on its CEO co-signature: `ceo-approval`
  names `ops-review`, so the person who completed the operations review of a shipment may not
  also co-sign it.

  The refusal is asserted on the HTTP surface (`Letflow.Routers.Tasks.call/2`): 403
  `application/problem+json` with the body exactly `{"detail":"separation of duties","status":403}`,
  the task still open, and every instance row byte-for-byte unchanged. Accepted completions are
  200. Real Postgres: tenant, users and role groups from `Letflow.SodSupport`; instance start and
  the service-task outcome from `Letflow.Req462Adoption`. No mocks, no wall clock. `async: false`.

  The fixture-shape assertions live in `test/letflow/scripts/req466_distinct_from_fixture_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.SnapshotStore
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Req462Adoption, as: A
  alias Letflow.SodSupport, as: S

  @opts Letflow.Routers.Tasks.init([])
  @sod_body ~s({"detail":"separation of duties","status":403})
  @fixture Path.expand(
             "../../fixtures/qa/swiftroute_process_definition.json",
             __DIR__
           )

  # -- fixtures -----------------------------------------------------------------------------

  defp definition_doc, do: @fixture |> File.read!() |> Jason.decode!()

  defp schemas(doc),
    do: Map.new(doc["variable_schemas"], &{&1["variable_key"], &1["json_schema"]})

  # A fresh tenant with the shipped definition active and one instance started. A declared value
  # above 500 routes the shipment through ceo-approval (edge e3) after ops-review.
  defp case!(declared_value) do
    doc = definition_doc()

    S.new_case!(doc["graph"], schemas(doc), %{
      "shipment_id" => "shp-466",
      "declared_value" => declared_value
    })
  end

  defp current_nodes(ctx), do: A.projection(ctx.schema_name, ctx.instance_id).current_nodes

  # -- HTTP ----------------------------------------------------------------------------------

  # POST /tasks/:id/complete as `user`; the request body is the output variables.
  defp complete_http(ctx, user, node_id, output) do
    task = S.pending_task!(ctx, node_id)

    conn(:post, "/#{task.id}/complete")
    |> Map.put(:body_params, output)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{user_id: user.id, tenant_id: ctx.tenant_id, roles: ["TASK_WORKER"]})
    |> assign(:trace_id, "req466-trace")
    |> then(&Letflow.Routers.Tasks.call(&1, @opts))
  end

  defp assert_accepted!(conn),
    do: assert(conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}")

  # The one fixed separation refusal: 403, problem+json, the constant body byte for byte.
  defp assert_separation!(conn) do
    assert conn.status == 403, "expected 403, got #{conn.status}: #{conn.resp_body}"
    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "application/problem+json")
    assert conn.resp_body == @sod_body
  end

  # The engine records no END id: END dispatch writes no event, and the completion result carries
  # only current_nodes, which is empty at END. So each END is named by a step that actually
  # finished -- a COMPLETED human task or an ADVANCED service task -- whose outgoing edge into an
  # END node is the edge taken.
  defp reached_ends(ctx) do
    {:ok, snapshot} = SnapshotStore.get_by_instance_id(ctx.instance_id, prefix: ctx.schema_name)
    {:ok, graph} = Graph.from_map(snapshot.graph)
    ends = for n <- graph.nodes, n.node_type == :END, into: MapSet.new(), do: n.id

    completed =
      EngineTask
      |> where([t], t.instance_id == ^ctx.instance_id and t.status == :completed)
      |> select([t], t.node_id)
      |> Repo.all(prefix: ctx.schema_name)

    advanced =
      ServiceTaskDispatch
      |> where([d], d.instance_id == ^ctx.instance_id and d.status == "advanced")
      |> select([d], d.node_id)
      |> Repo.all(prefix: ctx.schema_name)

    for source <- completed ++ advanced,
        e <- graph.edges,
        e.source == source and MapSet.member?(ends, e.target),
        uniq: true,
        do: e.target
  end

  # -- ceo-approval ------------------------------------------------------------------------

  test "ceo-approval: a user holding role-ops-manager and role-ceo who completed ops-review is refused at ceo-approval (403, fixed body), nothing changes; a second CEO is accepted and the shipment is released" do
    ctx = case!(750)
    u = S.insert_user!(ctx.schema_name, "u")
    v = S.insert_user!(ctx.schema_name, "v")
    S.grant_role!(ctx.schema_name, "role-ops-manager", [u.id])
    S.grant_role!(ctx.schema_name, "role-ceo", [u.id, v.id])
    assert current_nodes(ctx) == ["ops-review"]

    assert_accepted!(complete_http(ctx, u, "ops-review", %{"ops_decision" => "approve"}))
    assert current_nodes(ctx) == ["ceo-approval"]

    ceo_task = S.pending_task!(ctx, "ceo-approval")
    before = S.rows(ctx)
    assert_separation!(complete_http(ctx, u, "ceo-approval", %{"ceo_decision" => "approve"}))
    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, ceo_task).status == :pending

    assert_accepted!(complete_http(ctx, v, "ceo-approval", %{"ceo_decision" => "approve"}))
    assert current_nodes(ctx) == ["release-shipment"]

    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "release-shipment", %{})
    assert A.projection(ctx.schema_name, ctx.instance_id).status == :completed
    assert reached_ends(ctx) == ["end-approved"]
  end

  # -- REQ-464 validator on the live, activated definition ----------------------------------

  test "the REQ-464 validator (the function POST /definitions/:id/validate calls) reports the activated swiftroute definition valid, with no single-member warning" do
    ctx = case!(750)

    assert {:ok, %{valid: true, violations: [], warnings: warnings}} =
             Definitions.validate_definition_graph(ctx.definition.id, prefix: ctx.schema_name)

    refute Enum.any?(
             warnings,
             &(is_binary(&1) and String.starts_with?(&1, "distinct_from_single_member_role:"))
           )
  end
end
