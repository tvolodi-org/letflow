defmodule Letflow.Engine.Req466VortexDistinctFromTest do
  @moduledoc """
  REQ-466 (vortex half) -- the shipped Vortex "Production Order Release" fixture (v1.8) adopts
  `distinct_from` (REQ-459 rule A, enforced by REQ-463) on its two budget approval nodes:

    * `budget-approval` (role-controller) names `capacity-review` and `escalate-to-ceo`.
    * `escalate-budget-approval-to-finance-director` (role-finance-director, REQ-471 / GH #2479)
      names `capacity-review`, `escalate-to-ceo` and `budget-approval`. Its role differs from every
      node it names, so the shipped-definition guard (same-role pairs) stays unchanged.

  Refusals are asserted on the HTTP surface (`Letflow.Routers.Tasks.call/2`): 403
  `application/problem+json` with the body exactly `{"detail":"separation of duties","status":403}`,
  the task still open, and every instance row byte-for-byte unchanged. Accepted completions are
  200. Real Postgres: tenant, users and role groups from `Letflow.SodSupport`; instance start,
  service-task outcomes and the escalation timer (no wall clock) from `Letflow.Req462Adoption`.
  No mocks. `async: false`.

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
             "../../fixtures/qa/vortex_production_order_release_process_definition.json",
             __DIR__
           )

  # -- fixtures -----------------------------------------------------------------------------

  defp definition_doc, do: @fixture |> File.read!() |> Jason.decode!()

  defp schemas(doc),
    do: Map.new(doc["variable_schemas"], &{&1["variable_key"], &1["json_schema"]})

  # A fresh tenant with the shipped definition active and one instance started. An order value
  # above 10000 routes the order through budget-approval (edge e5) after capacity-review.
  defp case!(order_value_eur) do
    doc = definition_doc()

    S.new_case!(doc["graph"], schemas(doc), %{
      "order_id" => "ord-466",
      "order_value_eur" => order_value_eur
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
      |> where([d], d.instance_id == ^ctx.instance_id and d.status == :advanced)
      |> select([d], d.node_id)
      |> Repo.all(prefix: ctx.schema_name)

    for source <- completed ++ advanced,
        e <- graph.edges,
        e.source == source and MapSet.member?(ends, e.target),
        uniq: true,
        do: e.target
  end

  # The released path after an accepted budget decision: assign-line, then notify-planner, then
  # end-released. Both service tasks are re-entered without HTTP (the poller's outcome path).
  defp release!(ctx) do
    assert current_nodes(ctx) == ["assign-line"]
    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "assign-line", %{})
    assert current_nodes(ctx) == ["notify-planner"]
    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "notify-planner", %{})
    assert A.projection(ctx.schema_name, ctx.instance_id).status == :completed
    assert reached_ends(ctx) == ["end-released"]
  end

  # -- budget-approval -----------------------------------------------------------------------

  test "budget-approval: a user holding role-production-manager and role-controller who completed capacity-review is refused at budget-approval (403, fixed body), nothing changes; a different controller is accepted and the order is released" do
    ctx = case!(15_000)
    u = S.insert_user!(ctx.schema_name, "u")
    v = S.insert_user!(ctx.schema_name, "v")
    S.grant_role!(ctx.schema_name, "role-production-manager", [u.id])
    S.grant_role!(ctx.schema_name, "role-controller", [u.id, v.id])
    assert current_nodes(ctx) == ["capacity-review"]

    assert_accepted!(
      complete_http(ctx, u, "capacity-review", %{"capacity_decision" => "approve"})
    )

    assert current_nodes(ctx) == ["budget-approval"]

    budget_task = S.pending_task!(ctx, "budget-approval")
    before = S.rows(ctx)

    assert_separation!(
      complete_http(ctx, u, "budget-approval", %{"budget_decision" => "approve"})
    )

    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, budget_task).status == :pending

    assert_accepted!(complete_http(ctx, v, "budget-approval", %{"budget_decision" => "approve"}))
    release!(ctx)
  end

  # -- escalate-budget-approval-to-finance-director ------------------------------------------

  @escalation "escalate-budget-approval-to-finance-director"

  # Drive the order to the budget escalation node: capacity-review approved by `reviewer`, then
  # budget-approval's P2D timer fires (the real timer path, no wall clock).
  defp to_budget_escalation!(ctx, reviewer) do
    assert_accepted!(
      complete_http(ctx, reviewer, "capacity-review", %{"capacity_decision" => "approve"})
    )

    assert current_nodes(ctx) == ["budget-approval"]
    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "budget-approval"
    assert current_nodes(ctx) == [@escalation]
  end

  test "T1 escalation: a user holding role-ceo and role-finance-director who completed escalate-to-ceo is refused at the budget escalation (403, fixed body), nothing changes; a different finance director is accepted and the order is released" do
    ctx = case!(15_000)
    u = S.insert_user!(ctx.schema_name, "u")
    f = S.insert_user!(ctx.schema_name, "f")
    S.grant_role!(ctx.schema_name, "role-ceo", [u.id])
    S.grant_role!(ctx.schema_name, "role-finance-director", [u.id, f.id])

    # capacity-review's PT4H timer fires; u decides escalate-to-ceo; budget-approval's P2D timer fires.
    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "capacity-review"
    assert current_nodes(ctx) == ["escalate-to-ceo"]

    assert_accepted!(
      complete_http(ctx, u, "escalate-to-ceo", %{"capacity_decision" => "approve"})
    )

    assert current_nodes(ctx) == ["budget-approval"]
    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "budget-approval"
    assert current_nodes(ctx) == [@escalation]

    escalation = S.pending_task!(ctx, @escalation)
    before = S.rows(ctx)

    assert_separation!(complete_http(ctx, u, @escalation, %{"budget_decision" => "approve"}))

    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, escalation).status == :pending

    assert_accepted!(complete_http(ctx, f, @escalation, %{"budget_decision" => "approve"}))
    release!(ctx)
  end

  test "T2 escalation: a user holding role-production-manager and role-finance-director who completed capacity-review is refused at the budget escalation (403, fixed body), nothing changes" do
    ctx = case!(15_000)
    u = S.insert_user!(ctx.schema_name, "u")
    f = S.insert_user!(ctx.schema_name, "f")
    S.grant_role!(ctx.schema_name, "role-production-manager", [u.id])
    S.grant_role!(ctx.schema_name, "role-finance-director", [u.id, f.id])

    to_budget_escalation!(ctx, u)

    escalation = S.pending_task!(ctx, @escalation)
    before = S.rows(ctx)

    assert_separation!(complete_http(ctx, u, @escalation, %{"budget_decision" => "approve"}))

    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, escalation).status == :pending

    assert_accepted!(complete_http(ctx, f, @escalation, %{"budget_decision" => "approve"}))
    release!(ctx)
  end

  test "T3 escalation: a user holding only role-ceo is refused at the budget escalation by the role check, not by the separation body" do
    ctx = case!(15_000)
    p = S.insert_user!(ctx.schema_name, "p")
    c = S.insert_user!(ctx.schema_name, "c")
    S.grant_role!(ctx.schema_name, "role-production-manager", [p.id])
    S.grant_role!(ctx.schema_name, "role-ceo", [c.id])

    to_budget_escalation!(ctx, p)

    escalation = S.pending_task!(ctx, @escalation)
    before = S.rows(ctx)

    conn = complete_http(ctx, c, @escalation, %{"budget_decision" => "approve"})

    assert conn.status == 403
    refute conn.resp_body == @sod_body
    assert conn.resp_body =~ "caller does not hold the assigned role"
    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, escalation).status == :pending
  end

  test "T4 escalation: with no action, the budget escalation's P2D timer fails closed to auto-reject-order and end-rejected, never to assign-line" do
    ctx = case!(15_000)
    p = S.insert_user!(ctx.schema_name, "p")
    S.grant_role!(ctx.schema_name, "role-production-manager", [p.id])

    to_budget_escalation!(ctx, p)

    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == @escalation
    assert current_nodes(ctx) == ["auto-reject-order"]
    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "auto-reject-order", %{})

    assert A.projection(ctx.schema_name, ctx.instance_id).status == :completed
    assert reached_ends(ctx) == ["end-rejected"]
  end

  test "T5 escalation: the refusal body is constant -- identical for both separation refusals and free of node ids and user ids" do
    bodies =
      for reviewer_role <- ["role-ceo", "role-production-manager"] do
        # which earlier step u completed: escalate-to-ceo, or capacity-review
        ctx = case!(15_000)
        u = S.insert_user!(ctx.schema_name, "u")
        f = S.insert_user!(ctx.schema_name, "f")
        S.grant_role!(ctx.schema_name, "role-production-manager", [u.id])
        S.grant_role!(ctx.schema_name, "role-finance-director", [u.id, f.id])
        if reviewer_role == "role-ceo", do: S.grant_role!(ctx.schema_name, "role-ceo", [u.id])

        if reviewer_role == "role-ceo" do
          A.fire_escalation!(ctx.schema_name, ctx.instance_id)

          assert_accepted!(
            complete_http(ctx, u, "escalate-to-ceo", %{"capacity_decision" => "approve"})
          )

          A.fire_escalation!(ctx.schema_name, ctx.instance_id)
        else
          to_budget_escalation!(ctx, u)
        end

        conn = complete_http(ctx, u, @escalation, %{"budget_decision" => "approve"})
        assert_separation!(conn)
        refute conn.resp_body =~ @escalation
        refute conn.resp_body =~ "capacity-review"
        refute conn.resp_body =~ "escalate-to-ceo"
        refute conn.resp_body =~ u.id
        conn.resp_body
      end

    assert bodies == [@sod_body, @sod_body]
  end

  # -- REQ-464 validator on the live, activated definition -----------------------------------

  test "the REQ-464 validator (the function POST /definitions/:id/validate calls) reports the activated vortex release definition valid, with no single-member warning" do
    ctx = case!(15_000)

    assert {:ok, %{valid: true, violations: [], warnings: warnings}} =
             Definitions.validate_definition_graph(ctx.definition.id, prefix: ctx.schema_name)

    refute Enum.any?(
             warnings,
             &(is_binary(&1) and String.starts_with?(&1, "distinct_from_single_member_role:"))
           )
  end
end
