defmodule Letflow.Engine.Q1051MeridianL1CroAndAssessmentSodTest do
  @moduledoc """
  Q-1051 / GH #2395 (ISS-1051) -- the shipped Meridian "Loan Origination" fixture (v1.16) on real
  Postgres, driven through the HTTP completion surface, the real timer path and the engine.

    * (a) l1-approval's P2D timer hands the decision to `escalate-l1-approval-to-cro` (role-cro,
      Q-1047 option b). U completes that node and also holds role-credit-director, so U is refused
      at `l2-approval` (403, the fixed body, nothing changes); a second role-credit-director is
      accepted.
    * (b) a timeout on `escalate-l1-approval-to-cro` ends at `end-declined`, never at l2-approval or
      create-facility.
    * (c) graph-walk: every path to create-facility on the small-loan branch passes one of the L1
      nodes and one of the L2 nodes. The walk is structural: it follows every edge, conditions
      ignored, so timeout edges are included.
    * (d) for each payment node (`disburse-loan`, `escalate-disburse-loan-to-loan-ops-lead`), a user
      who completed kyc-manual-review and also holds the payment role is refused (403, fixed body);
      a distinct user holding the payment role is accepted (Q-1050, assessment/payment separation).

  No mocks. Tenant, users and role groups from `Letflow.SodSupport`; instance start, service-task
  outcomes and the escalation timer (no wall clock) from `Letflow.Req462Adoption`. `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.SnapshotStore
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Req462Adoption, as: A
  alias Letflow.SodSupport, as: S

  @opts Letflow.Routers.Tasks.init([])
  @sod_body ~s({"detail":"separation of duties","status":403})
  @fixture Path.expand(
             "../../fixtures/qa/meridian_loan_origination_process_definition.json",
             __DIR__
           )

  @l1 ["l1-approval", "escalate-l1-approval-to-cro"]
  @l2 ["l2-approval", "escalate-l2-approval-to-ceo"]

  # -- fixtures -----------------------------------------------------------------------------

  defp definition_doc, do: @fixture |> File.read!() |> Jason.decode!()

  defp schemas(doc),
    do: Map.new(doc["variable_schemas"], &{&1["variable_key"], &1["json_schema"]})

  # A fresh tenant with the shipped definition active and one small-loan instance started.
  defp case!(requested_amount_eur) do
    doc = definition_doc()

    S.new_case!(doc["graph"], schemas(doc), %{
      "application_id" => "app-1051",
      "requested_amount_eur" => requested_amount_eur
    })
  end

  # KYC cleared (service task), credit memo passed, risk rated low: the eligibility gate lets the
  # application on to authority routing. The prerequisite steps are engine completions by fresh
  # actors; the engine does not check role membership, and the refusals under test are all HTTP.
  defp assessed!(ctx) do
    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "kyc-aml-check", %{
      "kyc_status" => "clear"
    })

    S.complete_node!(ctx, "credit-memo-review", Ecto.UUID.generate(), %{
      "credit_decision" => "pass"
    })

    S.complete_node!(ctx, "risk-assessment", Ecto.UUID.generate(), %{"risk_rating" => "low"})
    ctx
  end

  # KYC routed to manual review (kyc_status 'hit'). `reviewer` records kyc_outcome 'cleared' over
  # HTTP, so the reviewer is a real completer in the instance history that the payment nodes name.
  defp assessed_via_manual_kyc!(ctx, reviewer) do
    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "kyc-aml-check", %{
      "kyc_status" => "hit"
    })

    assert "kyc-manual-review" in current_nodes(ctx)

    assert_accepted!(
      complete_http(ctx, reviewer, "kyc-manual-review", %{"kyc_outcome" => "cleared"})
    )

    S.complete_node!(ctx, "credit-memo-review", Ecto.UUID.generate(), %{
      "credit_decision" => "pass"
    })

    S.complete_node!(ctx, "risk-assessment", Ecto.UUID.generate(), %{"risk_rating" => "low"})
    ctx
  end

  # lars decides L1 (approve), w decides L2 (approve): the loan reaches create-facility, then
  # disburse-loan. Both approvals are distinct users, so nothing here is refused.
  defp to_disburse_loan!(ctx, lars, w) do
    assert_accepted!(complete_http(ctx, lars, "l1-approval", %{"l1_decision" => "approve"}))
    assert_accepted!(complete_http(ctx, w, "l2-approval", %{"l2_decision" => "approve"}))
    assert current_nodes(ctx) == ["create-facility"]

    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "create-facility", %{})
    assert current_nodes(ctx) == ["disburse-loan"]
    ctx
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
    |> assign(:trace_id, "q1051-trace")
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

  defp task_nodes(ctx),
    do:
      EngineTask
      |> where([t], t.instance_id == ^ctx.instance_id)
      |> select([t], t.node_id)
      |> Repo.all(prefix: ctx.schema_name)

  # -- (a) L1 timer -> CRO escalation -> L2 separation -----------------------------------------

  test "l1-approval timer hands the decision to escalate-l1-approval-to-cro (role-cro); U (also role-credit-director) is refused at l2-approval (403, fixed body), nothing changes; a second director is accepted" do
    ctx = case!(100_000) |> assessed!()
    u = S.insert_user!(ctx.schema_name, "u")
    v = S.insert_user!(ctx.schema_name, "v")
    S.grant_role!(ctx.schema_name, "role-cro", [u.id])
    S.grant_role!(ctx.schema_name, "role-credit-director", [u.id, v.id])
    assert current_nodes(ctx) == ["l1-approval"]

    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "l1-approval"
    assert current_nodes(ctx) == ["escalate-l1-approval-to-cro"]

    assert_accepted!(
      complete_http(ctx, u, "escalate-l1-approval-to-cro", %{"l1_decision" => "approve"})
    )

    assert current_nodes(ctx) == ["l2-approval"]

    l2_task = S.pending_task!(ctx, "l2-approval")
    before = S.rows(ctx)
    assert_separation!(complete_http(ctx, u, "l2-approval", %{"l2_decision" => "approve"}))
    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, l2_task).status == :pending

    assert_accepted!(complete_http(ctx, v, "l2-approval", %{"l2_decision" => "approve"}))
    assert current_nodes(ctx) == ["create-facility"]
  end

  # -- (b) timeout on the new node -> end-declined ----------------------------------------------

  test "a timeout on escalate-l1-approval-to-cro ends at end-declined by name, never at l2-approval or create-facility" do
    ctx = case!(100_000) |> assessed!()

    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "l1-approval"

    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id ==
             "escalate-l1-approval-to-cro"

    assert current_nodes(ctx) == ["decline-application"]

    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "decline-application", %{})
    assert A.projection(ctx.schema_name, ctx.instance_id).status == :completed
    assert reached_ends(ctx) == ["end-declined"]

    nodes = task_nodes(ctx)
    refute "l2-approval" in nodes
    refute "create-facility" in nodes
    refute "disburse-loan" in nodes
  end

  # -- (c) graph-walk over every edge ------------------------------------------------------------

  # Every simple path from `from` to `to`, following every edge; conditions are ignored, so the
  # timeout (unconditioned) edges are walked too.
  defp paths_to(_edges, to, to, _seen), do: [[to]]

  defp paths_to(edges, from, to, seen) do
    for edge <- edges,
        edge["source"] == from,
        edge["target"] not in seen,
        rest <- paths_to(edges, edge["target"], to, [edge["target"] | seen]),
        do: [from | rest]
  end

  # The small-loan branch: the authority-routing -> l1-approval edge (e17) and everything after it.
  defp small_loan_paths(edges) do
    %{"target" => first} = Enum.find(edges, &(&1["id"] == "e17"))

    for rest <- paths_to(edges, first, "create-facility", [first]),
        do: ["authority-routing" | rest]
  end

  test "graph-walk: every path to create-facility on the small-loan branch passes an L1 node and an L2 node" do
    edges = definition_doc()["graph"]["edges"]
    paths = small_loan_paths(edges)

    # Two L1 routes (l1-approval, or the CRO escalation after its timeout) times two L2 routes
    # (l2-approval, or the CEO escalation after its timeout): four structural paths in all.
    assert length(paths) == 4

    for path <- paths do
      assert Enum.any?(path, &(&1 in @l1)), "no L1 node on #{inspect(path)}"
      assert Enum.any?(path, &(&1 in @l2)), "no L2 node on #{inspect(path)}"
    end

    assert Enum.any?(paths, &("escalate-l1-approval-to-cro" in &1))
    assert Enum.any?(paths, &("escalate-l2-approval-to-ceo" in &1))
  end

  # -- (d) payment nodes: assessment completer refused, distinct payer accepted -----------------

  test "disburse-loan: a user who completed kyc-manual-review and holds role-loan-ops is refused (403, fixed body), nothing changes; a distinct loan-ops user is accepted" do
    ctx = case!(100_000)
    k = S.insert_user!(ctx.schema_name, "k")
    lars = S.insert_user!(ctx.schema_name, "lars")
    w = S.insert_user!(ctx.schema_name, "w")
    m = S.insert_user!(ctx.schema_name, "m")
    S.grant_role!(ctx.schema_name, "role-compliance-officer", [k.id])
    S.grant_role!(ctx.schema_name, "role-loan-ops", [k.id, m.id])
    S.grant_role!(ctx.schema_name, "role-credit-approver-l1", [lars.id])
    S.grant_role!(ctx.schema_name, "role-credit-director", [w.id])

    ctx |> assessed_via_manual_kyc!(k) |> to_disburse_loan!(lars, w)

    payment = S.pending_task!(ctx, "disburse-loan")
    before = S.rows(ctx)
    assert_separation!(complete_http(ctx, k, "disburse-loan", %{}))
    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, payment).status == :pending

    assert_accepted!(complete_http(ctx, m, "disburse-loan", %{}))
    assert S.reload_task!(ctx, payment).status == :completed
    assert A.projection(ctx.schema_name, ctx.instance_id).status == :completed
    assert reached_ends(ctx) == ["end-disbursed"]
  end

  test "escalate-disburse-loan-to-loan-ops-lead: a user who completed kyc-manual-review and holds role-loan-ops-lead is refused (403, fixed body), nothing changes; a distinct loan-ops lead is accepted and the loan is disbursed" do
    ctx = case!(100_000)
    k = S.insert_user!(ctx.schema_name, "k")
    lars = S.insert_user!(ctx.schema_name, "lars")
    w = S.insert_user!(ctx.schema_name, "w")
    n = S.insert_user!(ctx.schema_name, "n")
    S.grant_role!(ctx.schema_name, "role-compliance-officer", [k.id])
    S.grant_role!(ctx.schema_name, "role-loan-ops-lead", [k.id, n.id])
    S.grant_role!(ctx.schema_name, "role-credit-approver-l1", [lars.id])
    S.grant_role!(ctx.schema_name, "role-credit-director", [w.id])

    ctx |> assessed_via_manual_kyc!(k) |> to_disburse_loan!(lars, w)

    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "disburse-loan"
    assert current_nodes(ctx) == ["escalate-disburse-loan-to-loan-ops-lead"]

    escalation = S.pending_task!(ctx, "escalate-disburse-loan-to-loan-ops-lead")
    before = S.rows(ctx)
    assert_separation!(complete_http(ctx, k, "escalate-disburse-loan-to-loan-ops-lead", %{}))
    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, escalation).status == :pending

    assert_accepted!(complete_http(ctx, n, "escalate-disburse-loan-to-loan-ops-lead", %{}))
    assert S.reload_task!(ctx, escalation).status == :completed
    assert A.projection(ctx.schema_name, ctx.instance_id).status == :completed
    assert reached_ends(ctx) == ["end-disbursed"]
  end
end
