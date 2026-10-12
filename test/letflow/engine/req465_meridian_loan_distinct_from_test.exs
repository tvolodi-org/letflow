defmodule Letflow.Engine.Req465MeridianLoanDistinctFromTest do
  @moduledoc """
  REQ-465 (loan half) -- the shipped Meridian "Loan Origination" fixture (v1.14) adopts
  `distinct_from` (REQ-459 rule A, enforced by REQ-463) on its approve, pay and commit nodes:
  `l2-approval` and `escalate-l2-approval-to-ceo` name `l1-approval`; `disburse-loan` names every
  approval node; the three committee votes name each other (see the fixture description).

  Refusals are asserted on the HTTP surface (`Letflow.Routers.Tasks.call/2`, the dispatch
  `tasks_distinct_from_test.exs` uses): 403 `application/problem+json` with the body exactly
  `{"detail":"separation of duties","status":403}`, the task still open, and every instance row
  byte-for-byte unchanged. Accepted completions are 200. Real Postgres: tenant, users and role
  groups from `Letflow.SodSupport`; instance start, service-task outcomes and the escalation timer
  (no wall clock) from `Letflow.Req462Adoption`. No mocks.

  The fixture-shape assertions live in `test/letflow/scripts/req465_meridian_distinct_from_fixture_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.Req462Adoption, as: A
  alias Letflow.SodSupport, as: S

  @opts Letflow.Routers.Tasks.init([])
  @sod_body ~s({"detail":"separation of duties","status":403})
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
      "application_id" => "app-465",
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
    |> assign(:trace_id, "req465-trace")
    |> then(&Letflow.Routers.Tasks.call(&1, @opts))
  end

  defp assert_accepted!(conn),
    do: assert(conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}")

  # The one fixed refusal: 403, problem+json, the constant body byte for byte.
  defp assert_separation!(conn) do
    assert conn.status == 403, "expected 403, got #{conn.status}: #{conn.resp_body}"
    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "application/problem+json")
    assert conn.resp_body == @sod_body
  end

  # -- l2-approval --------------------------------------------------------------------------

  test "l2-approval: a user holding role-credit-approver-l1 and role-credit-director who completed l1-approval is refused (403, fixed body), nothing changes; a second director is accepted" do
    ctx = case!(100_000) |> assessed!()
    u = S.insert_user!(ctx.schema_name, "u")
    v = S.insert_user!(ctx.schema_name, "v")
    S.grant_role!(ctx.schema_name, "role-credit-approver-l1", [u.id])
    S.grant_role!(ctx.schema_name, "role-credit-director", [u.id, v.id])
    assert current_nodes(ctx) == ["l1-approval"]

    assert_accepted!(complete_http(ctx, u, "l1-approval", %{"l1_decision" => "approve"}))
    assert current_nodes(ctx) == ["l2-approval"]

    l2_task = S.pending_task!(ctx, "l2-approval")
    before = S.rows(ctx)
    assert_separation!(complete_http(ctx, u, "l2-approval", %{"l2_decision" => "approve"}))
    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, l2_task).status == :pending

    assert_accepted!(complete_http(ctx, v, "l2-approval", %{"l2_decision" => "approve"}))
    assert current_nodes(ctx) == ["create-facility"]
  end

  # -- escalate-l2-approval-to-ceo ----------------------------------------------------------

  test "escalate-l2-approval-to-ceo: a user holding role-ceo who completed l1-approval is refused at the CEO escalation (403, fixed body), nothing changes; a different CEO is accepted" do
    ctx = case!(100_000) |> assessed!()
    u = S.insert_user!(ctx.schema_name, "u")
    c = S.insert_user!(ctx.schema_name, "c")
    S.grant_role!(ctx.schema_name, "role-credit-approver-l1", [u.id])
    S.grant_role!(ctx.schema_name, "role-ceo", [u.id, c.id])

    assert_accepted!(complete_http(ctx, u, "l1-approval", %{"l1_decision" => "approve"}))

    # l2-approval's P2D escalation timer fires (the real timer path, no wall clock).
    assert A.fire_escalation!(ctx.schema_name, ctx.instance_id).node_id == "l2-approval"
    assert current_nodes(ctx) == ["escalate-l2-approval-to-ceo"]

    escalation = S.pending_task!(ctx, "escalate-l2-approval-to-ceo")
    before = S.rows(ctx)

    assert_separation!(
      complete_http(ctx, u, "escalate-l2-approval-to-ceo", %{"l2_decision" => "approve"})
    )

    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, escalation).status == :pending

    assert_accepted!(
      complete_http(ctx, c, "escalate-l2-approval-to-ceo", %{"l2_decision" => "reject"})
    )

    assert current_nodes(ctx) == ["decline-application"]
  end

  # -- disburse-loan ------------------------------------------------------------------------

  test "disburse-loan: a user who completed l2-approval is refused at disburse-loan (403, fixed body), nothing changes; a different loan-ops user is accepted" do
    ctx = case!(100_000) |> assessed!()
    lars = S.insert_user!(ctx.schema_name, "lars")
    w = S.insert_user!(ctx.schema_name, "w")
    m = S.insert_user!(ctx.schema_name, "m")
    S.grant_role!(ctx.schema_name, "role-credit-approver-l1", [lars.id])
    S.grant_role!(ctx.schema_name, "role-credit-director", [w.id])
    S.grant_role!(ctx.schema_name, "role-loan-ops", [w.id, m.id])

    assert_accepted!(complete_http(ctx, lars, "l1-approval", %{"l1_decision" => "approve"}))
    assert_accepted!(complete_http(ctx, w, "l2-approval", %{"l2_decision" => "approve"}))
    assert current_nodes(ctx) == ["create-facility"]

    A.advance_service_task!(ctx.schema_name, ctx.instance_id, "create-facility", %{})
    assert current_nodes(ctx) == ["disburse-loan"]

    payment = S.pending_task!(ctx, "disburse-loan")
    before = S.rows(ctx)
    assert_separation!(complete_http(ctx, w, "disburse-loan", %{}))
    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, payment).status == :pending

    assert_accepted!(complete_http(ctx, m, "disburse-loan", %{}))
    assert S.reload_task!(ctx, payment).status == :completed
  end

  # -- committee votes ----------------------------------------------------------------------

  test "committee votes: one user holding role-cro and role-credit-director refuses the second vote (403, fixed body), nothing changes; three distinct users are accepted and the committee decides" do
    ctx = case!(600_000) |> assessed!()
    x = S.insert_user!(ctx.schema_name, "x")
    y = S.insert_user!(ctx.schema_name, "y")
    z = S.insert_user!(ctx.schema_name, "z")
    S.grant_role!(ctx.schema_name, "role-cro", [x.id])
    S.grant_role!(ctx.schema_name, "role-credit-director", [x.id, y.id])
    S.grant_role!(ctx.schema_name, "role-ceo", [z.id])

    assert Enum.sort(current_nodes(ctx)) ==
             ["committee-vote-ceo", "committee-vote-cro", "committee-vote-director"]

    assert_accepted!(
      complete_http(ctx, x, "committee-vote-cro", %{"committee_vote_cro" => "approve"})
    )

    director_vote = S.pending_task!(ctx, "committee-vote-director")
    before = S.rows(ctx)

    assert_separation!(
      complete_http(ctx, x, "committee-vote-director", %{"committee_vote_director" => "approve"})
    )

    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, director_vote).status == :pending

    assert_accepted!(
      complete_http(ctx, y, "committee-vote-director", %{"committee_vote_director" => "approve"})
    )

    assert_accepted!(
      complete_http(ctx, z, "committee-vote-ceo", %{"committee_vote_ceo" => "approve"})
    )

    assert current_nodes(ctx) == ["create-facility"]
  end

  # -- REQ-464 validator on the live, activated definition -----------------------------------

  test "the REQ-464 validator (the function POST /definitions/:id/validate calls) reports the activated loan definition valid, with no single-member warning" do
    ctx = case!(100_000)

    assert {:ok, %{valid: true, violations: [], warnings: warnings}} =
             Definitions.validate_definition_graph(ctx.definition.id, prefix: ctx.schema_name)

    refute Enum.any?(
             warnings,
             &(is_binary(&1) and String.starts_with?(&1, "distinct_from_single_member_role:"))
           )
  end
end
