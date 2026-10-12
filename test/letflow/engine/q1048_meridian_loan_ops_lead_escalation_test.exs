defmodule Letflow.Engine.Q1048MeridianLoanOpsLeadEscalationTest do
  @moduledoc """
  Q-1048 / GH #2390 (REQ-467 / ISS-1048) -- the disbursement escalation of the shipped Meridian
  "Loan Origination" fixture (v1.15) is rerouted from role-credit-director to a new
  role-loan-ops-lead, and its node `escalate-disburse-loan-to-loan-ops-lead` carries
  `distinct_from` on all six approval nodes (l1-approval, l2-approval, escalate-l2-approval-to-ceo,
  committee-vote-cro, committee-vote-director, committee-vote-ceo). Decision: Q-1044 option (b).

  Refusals are asserted on the HTTP surface (`Letflow.Routers.Tasks.call/2`): the separation-of-duties
  refusal is 403 `application/problem+json` with the body exactly
  `{"detail":"separation of duties","status":403}`, and the task stays open with every instance row
  byte-for-byte unchanged. The role barrier is the existing eligibility refusal (`authorize_completion`
  runs before the separation guard), so it is asserted by its own detail text, never by the separation
  body. Real Postgres: tenant, users and role groups from `Letflow.SodSupport`; instance start,
  service-task outcomes and the disbursement escalation timer (no wall clock) from
  `Letflow.Req462Adoption`. No mocks, no roster file.

  The escalation node's only completion edge is `e27-escalated` (to `end-disbursed`); its timeout edge
  leads to `disbursement-held-notice` -> `end-disbursement-held`. So a completed escalation with no
  held notice dispatched ends at end-disbursed, and a stalled escalation ends held.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Req462Adoption, as: A
  alias Letflow.SodSupport, as: S

  @opts Letflow.Routers.Tasks.init([])
  @sod_body ~s({"detail":"separation of duties","status":403})
  @escalation "escalate-disburse-loan-to-loan-ops-lead"
  @fixture Path.expand(
             "../../fixtures/qa/meridian_loan_origination_process_definition.json",
             __DIR__
           )

  # -- fixtures -----------------------------------------------------------------------------

  defp definition_doc, do: @fixture |> File.read!() |> Jason.decode!()

  defp schemas(doc),
    do: Map.new(doc["variable_schemas"], &{&1["variable_key"], &1["json_schema"]})

  # A fresh tenant with the shipped definition active and one instance started.
  defp case!(requested_amount_eur) do
    doc = definition_doc()

    S.new_case!(doc["graph"], schemas(doc), %{
      "application_id" => "app-1048",
      "requested_amount_eur" => requested_amount_eur
    })
  end

  # KYC cleared (service task), credit memo passed, risk rated low: the eligibility gate lets the
  # application on to authority routing. These prerequisite steps are engine completions by fresh
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

  defp current_nodes(ctx), do: A.projection(ctx.schema_name, ctx.instance_id).current_nodes

  # -- HTTP ----------------------------------------------------------------------------------

  # POST /tasks/:id/complete as `user`; the request body is the output variables.
  defp complete_http(ctx, user, node_id, output) do
    task = S.pending_task!(ctx, node_id)

    conn(:post, "/#{task.id}/complete")
    |> Map.put(:body_params, output)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{user_id: user.id, tenant_id: ctx.tenant_id, roles: ["TASK_WORKER"]})
    |> assign(:trace_id, "q1048-trace")
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

  # The existing eligibility refusal (ISS-0942): 403, and not the separation body.
  defp assert_not_eligible!(conn) do
    assert conn.status == 403, "expected 403, got #{conn.status}: #{conn.resp_body}"
    assert conn.resp_body =~ "caller does not hold the assigned role"
    refute conn.resp_body == @sod_body
  end

  # -- routes to the disbursement escalation ----------------------------------------------------

  # -- (a) small-loan path ----------------------------------------------------------------------

  test "small loan: U completes l2-approval; disburse-loan's timer fires; U (also role-loan-ops-lead) is refused at the escalation (403, fixed body), nothing changes; another loan-ops lead completes it and the instance ends at end-disbursed" do
    ctx = case!(100_000) |> assessed!()
    lars = S.insert_user!(ctx.schema_name, "lars")
    u = S.insert_user!(ctx.schema_name, "u")
    v = S.insert_user!(ctx.schema_name, "v")
    S.grant_role!(ctx.schema_name, "role-credit-approver-l1", [lars.id])
    S.grant_role!(ctx.schema_name, "role-credit-director", [u.id])
    S.grant_role!(ctx.schema_name, "role-loan-ops-lead", [u.id, v.id])

    assert_accepted!(complete_http(ctx, lars, "l1-approval", %{"l1_decision" => "approve"}))
    assert_accepted!(complete_http(ctx, u, "l2-approval", %{"l2_decision" => "approve"}))
    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "create-facility", %{})
    assert current_nodes(ctx) == ["disburse-loan"]

    timer = A.fire_escalation!(ctx.schema_name, ctx.instance_id)
    assert timer.node_id == "disburse-loan"
    assert current_nodes(ctx) == [@escalation]

    escalation = S.pending_task!(ctx, @escalation)
    before = S.rows(ctx)
    assert_separation!(complete_http(ctx, u, @escalation, %{}))
    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, escalation).status == :pending

    assert_accepted!(complete_http(ctx, v, @escalation, %{}))
    assert S.reload_task!(ctx, escalation).status == :completed

    # The only completion edge of the escalation is e27-escalated -> end-disbursed: no held notice
    # is ever dispatched, and the instance completes.
    assert A.projection(ctx.schema_name, ctx.instance_id).status == :completed
    refute "disbursement-held-notice" in A.dispatched_nodes(ctx.schema_name, ctx.instance_id)
  end

  # -- (b) committee path ----------------------------------------------------------------------

  test "committee path: the completer of committee-vote-director (also role-loan-ops-lead) is refused at the escalation (403, fixed body), nothing changes; another loan-ops lead completes it and the instance ends at end-disbursed" do
    ctx = case!(600_000) |> assessed!()
    x = S.insert_user!(ctx.schema_name, "x")
    y = S.insert_user!(ctx.schema_name, "y")
    z = S.insert_user!(ctx.schema_name, "z")
    v = S.insert_user!(ctx.schema_name, "v")
    S.grant_role!(ctx.schema_name, "role-cro", [x.id])
    S.grant_role!(ctx.schema_name, "role-credit-director", [y.id])
    S.grant_role!(ctx.schema_name, "role-loan-ops-lead", [y.id, v.id])
    S.grant_role!(ctx.schema_name, "role-ceo", [z.id])

    assert_accepted!(
      complete_http(ctx, x, "committee-vote-cro", %{"committee_vote_cro" => "approve"})
    )

    assert_accepted!(
      complete_http(ctx, y, "committee-vote-director", %{
        "committee_vote_director" => "approve"
      })
    )

    assert_accepted!(
      complete_http(ctx, z, "committee-vote-ceo", %{"committee_vote_ceo" => "approve"})
    )

    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "create-facility", %{})
    assert current_nodes(ctx) == ["disburse-loan"]

    timer = A.fire_escalation!(ctx.schema_name, ctx.instance_id)
    assert timer.node_id == "disburse-loan"
    assert current_nodes(ctx) == [@escalation]

    escalation = S.pending_task!(ctx, @escalation)
    before = S.rows(ctx)
    assert_separation!(complete_http(ctx, y, @escalation, %{}))
    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, escalation).status == :pending

    assert_accepted!(complete_http(ctx, v, @escalation, %{}))
    assert S.reload_task!(ctx, escalation).status == :completed
    assert A.projection(ctx.schema_name, ctx.instance_id).status == :completed
    refute "disbursement-held-notice" in A.dispatched_nodes(ctx.schema_name, ctx.instance_id)
  end

  # -- (c) the other two named approvals -------------------------------------------------------

  test "the completer of l1-approval (also role-loan-ops-lead) is refused at the escalation (403, fixed body), nothing changes; another loan-ops lead completes it and the instance ends at end-disbursed" do
    ctx = case!(100_000) |> assessed!()
    u = S.insert_user!(ctx.schema_name, "u")
    d = S.insert_user!(ctx.schema_name, "d")
    v = S.insert_user!(ctx.schema_name, "v")
    S.grant_role!(ctx.schema_name, "role-credit-approver-l1", [u.id])
    S.grant_role!(ctx.schema_name, "role-credit-director", [d.id])
    S.grant_role!(ctx.schema_name, "role-loan-ops-lead", [u.id, v.id])

    assert_accepted!(complete_http(ctx, u, "l1-approval", %{"l1_decision" => "approve"}))
    assert_accepted!(complete_http(ctx, d, "l2-approval", %{"l2_decision" => "approve"}))
    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "create-facility", %{})
    assert current_nodes(ctx) == ["disburse-loan"]

    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "disburse-loan"
    assert current_nodes(ctx) == [@escalation]

    escalation = S.pending_task!(ctx, @escalation)
    before = S.rows(ctx)
    assert_separation!(complete_http(ctx, u, @escalation, %{}))
    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, escalation).status == :pending

    assert_accepted!(complete_http(ctx, v, @escalation, %{}))
    assert A.projection(ctx.schema_name, ctx.instance_id).status == :completed
    refute "disbursement-held-notice" in A.dispatched_nodes(ctx.schema_name, ctx.instance_id)
  end

  test "the completer of escalate-l2-approval-to-ceo (also role-loan-ops-lead) is refused at the escalation (403, fixed body), nothing changes; another loan-ops lead completes it and the instance ends at end-disbursed" do
    ctx = case!(100_000) |> assessed!()
    lars = S.insert_user!(ctx.schema_name, "lars")
    c = S.insert_user!(ctx.schema_name, "c")
    v = S.insert_user!(ctx.schema_name, "v")
    S.grant_role!(ctx.schema_name, "role-credit-approver-l1", [lars.id])
    S.grant_role!(ctx.schema_name, "role-ceo", [c.id])
    S.grant_role!(ctx.schema_name, "role-loan-ops-lead", [c.id, v.id])

    assert_accepted!(complete_http(ctx, lars, "l1-approval", %{"l1_decision" => "approve"}))

    # l2-approval's P2D escalation timer fires onto the CEO task (the real timer path, no wall clock).
    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "l2-approval"
    assert current_nodes(ctx) == ["escalate-l2-approval-to-ceo"]

    assert_accepted!(
      complete_http(ctx, c, "escalate-l2-approval-to-ceo", %{"l2_decision" => "approve"})
    )

    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "create-facility", %{})
    assert current_nodes(ctx) == ["disburse-loan"]

    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "disburse-loan"
    assert current_nodes(ctx) == [@escalation]

    escalation = S.pending_task!(ctx, @escalation)
    before = S.rows(ctx)
    assert_separation!(complete_http(ctx, c, @escalation, %{}))
    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, escalation).status == :pending

    assert_accepted!(complete_http(ctx, v, @escalation, %{}))
    assert A.projection(ctx.schema_name, ctx.instance_id).status == :completed
    refute "disbursement-held-notice" in A.dispatched_nodes(ctx.schema_name, ctx.instance_id)
  end

  # -- (d) role barrier -------------------------------------------------------------------------

  test "role barrier: a user holding only role-credit-director (who completed l2-approval) is refused by the existing eligibility check, not the separation body; a loan-ops lead then completes it" do
    ctx = case!(100_000) |> assessed!()
    lars = S.insert_user!(ctx.schema_name, "lars")
    w = S.insert_user!(ctx.schema_name, "w")
    v = S.insert_user!(ctx.schema_name, "v")
    S.grant_role!(ctx.schema_name, "role-credit-approver-l1", [lars.id])
    S.grant_role!(ctx.schema_name, "role-credit-director", [w.id])
    S.grant_role!(ctx.schema_name, "role-loan-ops-lead", [v.id])

    assert_accepted!(complete_http(ctx, lars, "l1-approval", %{"l1_decision" => "approve"}))
    assert_accepted!(complete_http(ctx, w, "l2-approval", %{"l2_decision" => "approve"}))
    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "create-facility", %{})
    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "disburse-loan"
    assert current_nodes(ctx) == [@escalation]

    # w completed l2-approval, so the separation guard WOULD refuse w here if the eligibility check
    # did not run first. The refusal must be the eligibility one: w does not hold role-loan-ops-lead.
    escalation = S.pending_task!(ctx, @escalation)
    before = S.rows(ctx)
    assert_not_eligible!(complete_http(ctx, w, @escalation, %{}))
    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, escalation).status == :pending

    assert_accepted!(complete_http(ctx, v, @escalation, %{}))
    assert A.projection(ctx.schema_name, ctx.instance_id).status == :completed
    refute "disbursement-held-notice" in A.dispatched_nodes(ctx.schema_name, ctx.instance_id)
  end

  # -- (e) fail-closed --------------------------------------------------------------------------

  # The stalled escalation: its P1D timer fires onto the hold notice, which ends the instance held.
  defp assert_held_never_disbursed!(ctx, escalation) do
    timer = A.fire_escalation!(ctx.schema_name, ctx.instance_id)
    assert timer.node_id == @escalation
    assert S.reload_task!(ctx, escalation).status == :cancelled
    assert current_nodes(ctx) == ["disbursement-held-notice"]

    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "disbursement-held-notice", %{})
    assert A.projection(ctx.schema_name, ctx.instance_id).status == :completed
    assert "disbursement-held-notice" in A.dispatched_nodes(ctx.schema_name, ctx.instance_id)
  end

  test "fail-closed: the only holder of role-loan-ops-lead is the refused completer, so the escalation timer ends the loan at end-disbursement-held, never end-disbursed" do
    ctx = case!(100_000) |> assessed!()
    lars = S.insert_user!(ctx.schema_name, "lars")
    u = S.insert_user!(ctx.schema_name, "u")
    S.grant_role!(ctx.schema_name, "role-credit-approver-l1", [lars.id])
    S.grant_role!(ctx.schema_name, "role-credit-director", [u.id])
    S.grant_role!(ctx.schema_name, "role-loan-ops-lead", [u.id])

    assert_accepted!(complete_http(ctx, lars, "l1-approval", %{"l1_decision" => "approve"}))
    assert_accepted!(complete_http(ctx, u, "l2-approval", %{"l2_decision" => "approve"}))
    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "create-facility", %{})
    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "disburse-loan"

    escalation = S.pending_task!(ctx, @escalation)
    before = S.rows(ctx)
    assert_separation!(complete_http(ctx, u, @escalation, %{}))
    assert S.rows(ctx) == before

    assert_held_never_disbursed!(ctx, escalation)
    assert S.reload_task!(ctx, escalation).status == :cancelled
  end

  test "fail-closed: no user holds role-loan-ops-lead at all, so the escalation stalls and the loan is held at end-disbursement-held, never end-disbursed" do
    ctx = case!(100_000) |> assessed!()
    lars = S.insert_user!(ctx.schema_name, "lars")
    u = S.insert_user!(ctx.schema_name, "u")
    S.grant_role!(ctx.schema_name, "role-credit-approver-l1", [lars.id])
    S.grant_role!(ctx.schema_name, "role-credit-director", [u.id])

    assert_accepted!(complete_http(ctx, lars, "l1-approval", %{"l1_decision" => "approve"}))
    assert_accepted!(complete_http(ctx, u, "l2-approval", %{"l2_decision" => "approve"}))
    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "create-facility", %{})
    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "disburse-loan"

    escalation = S.pending_task!(ctx, @escalation)
    assert_held_never_disbursed!(ctx, escalation)
    assert S.reload_task!(ctx, escalation).status == :cancelled
  end
end
