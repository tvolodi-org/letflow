defmodule Letflow.Engine.MeridianLoanEscalationTimerTest do
  @moduledoc """
  ISS-1013 / Q-995 (GH #2282) -- engine-level proof of the D-ESC escalation chain (BA ruling
  GH #2281) on the REAL Meridian "Loan Origination" fixture (v1.15), through the real
  `Definitions` registration/activation, `Engine.create/2`, `Engine.complete_task/3` and the real
  timer path the advance-timer route uses (`Scheduler.resolve_advance_target/3` +
  `Scheduler.fire_timer/2`).

    * l1-approval's timer escalates to l2-approval (role-credit-director): the l1 task is CANCELLED;
    * l2-approval's timer escalates to `escalate-l2-approval-to-ceo` (role-ceo): l2 CANCELLED, a new
      task for role-ceo is created; its own timer fails closed to `decline-application`
      (NEVER `create-facility`); an explicit 'approve' by the CEO still creates the facility;
    * disburse-loan's timer escalates to `escalate-disburse-loan-to-loan-ops-lead` (role-loan-ops-lead,
      Q-1048 / GH #2390; formerly the credit-director node); its own timer
      holds the loan (`disbursement-held-notice` -> `end-disbursement-held`), no payout.

  No HTTP: the dispatcher is not run; service-task outcomes are re-entered by hand exactly as
  `regulatory_review_timer_path_test.exs` does. Real Postgres, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.SodSupport, as: S
  alias Letflow.TenantFixture

  @fixture Path.expand(
             "../../fixtures/qa/meridian_loan_origination_process_definition.json",
             __DIR__
           )

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # --- helpers (no optional-argument defaults: anti-patterns.md ISS-0069) ---------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp started_instance! do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss1013")
    schema = tenant.schema_name
    doc = @fixture |> File.read!() |> Jason.decode!()

    entries =
      Enum.map(doc["variable_schemas"], fn e ->
        %{variable_key: e["variable_key"], json_schema: e["json_schema"], description: nil}
      end)

    assert {:ok, definition} =
             Definitions.create_with_variable_schemas(
               %{
                 name: unique("iss1013-def"),
                 version: doc["version"],
                 graph: doc["graph"],
                 created_by: Ecto.UUID.generate()
               },
               entries,
               prefix: schema
             )

    assert {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: active.id,
                 initial_variables: %{
                   "application_id" => "app-1013",
                   "requested_amount_eur" => 100_000
                 },
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss1013-start")
               },
               prefix: schema
             )

    {schema, result.instance_id}
  end

  defp tasks(schema, instance_id, node_id) do
    EngineTask
    |> where([t], t.instance_id == ^instance_id and t.node_id == ^node_id)
    |> Repo.all(prefix: schema)
  end

  defp task!(schema, instance_id, node_id) do
    assert [task] = tasks(schema, instance_id, node_id)
    task
  end

  defp complete!(schema, task, output) do
    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: output,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss1013-complete")
               },
               prefix: schema
             )
  end

  # Completion as a named actor (the escalation tests need a real holder of the node's role).
  defp complete_as!(schema, task, actor_id, output) do
    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: output,
                 actor_id: actor_id,
                 idempotency_key: unique("q1048-complete")
               },
               prefix: schema
             )
  end

  # A real user holding role-loan-ops-lead, the escalation node's role (Q-1048 / GH #2390).
  defp loan_ops_lead!(schema) do
    user = S.insert_user!(schema, "ops-lead")
    S.grant_role!(schema, "role-loan-ops-lead", [user.id])
    user
  end

  defp projection(schema, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: schema)

  defp dispatches(schema, instance_id) do
    ServiceTaskDispatch
    |> where([d], d.instance_id == ^instance_id)
    |> Repo.all(prefix: schema)
  end

  # Re-enter a service task's outcome without HTTP (the poller's `mark advanced` + re-entry).
  defp advance_service_task!(schema, instance_id, node_id, outputs) do
    assert [row] =
             ServiceTaskDispatch
             |> where([d], d.instance_id == ^instance_id and d.node_id == ^node_id)
             |> where([d], d.status == "pending")
             |> Repo.all(prefix: schema)

    row = row |> Ecto.Changeset.change(%{status: "advanced"}) |> Repo.update!(prefix: schema)

    assert {:ok, :advanced} =
             Engine.advance_after_service_task_outcome(row.id, {:advance, outputs}, Repo, schema)
  end

  # Fires the one pending escalation timer, exactly as POST /instances/:id/advance-timer does, and
  # returns the timer so the caller can assert which node it armed on.
  defp fire_escalation!(schema, instance_id) do
    assert {:ok, %Timer{} = timer} = Scheduler.resolve_advance_target(instance_id, nil, schema)
    assert timer.timer_type == "escalation"
    assert {:ok, :fired} = Scheduler.fire_timer(timer.id, schema)
    timer
  end

  # Drives a fresh instance to the l1-approval task (clear KYC, credit pass, risk low).
  defp at_l1_approval! do
    {schema, id} = started_instance!()

    assert [row] =
             ServiceTaskDispatch
             |> where([d], d.instance_id == ^id and d.node_id == "kyc-aml-check")
             |> Repo.all(prefix: schema)

    row = row |> Ecto.Changeset.change(%{status: "advanced"}) |> Repo.update!(prefix: schema)

    assert {:ok, :advanced} =
             Engine.advance_after_service_task_outcome(
               row.id,
               {:advance, %{"kyc_status" => "clear"}},
               Repo,
               schema
             )

    complete!(schema, task!(schema, id, "credit-memo-review"), %{"credit_decision" => "pass"})
    complete!(schema, task!(schema, id, "risk-assessment"), %{"risk_rating" => "low"})
    assert projection(schema, id).current_nodes == ["l1-approval"]
    {schema, id}
  end

  # l1 approve -> l2-approval pending.
  defp at_l2_approval! do
    {schema, id} = at_l1_approval!()
    complete!(schema, task!(schema, id, "l1-approval"), %{"l1_decision" => "approve"})
    assert projection(schema, id).current_nodes == ["l2-approval"]
    {schema, id}
  end

  defp at_escalated_l2! do
    {schema, id} = at_l2_approval!()
    l2 = task!(schema, id, "l2-approval")
    timer = fire_escalation!(schema, id)
    assert timer.node_id == "l2-approval"
    {schema, id, l2}
  end

  # --- l1 -> l2 --------------------------------------------------------------------------------

  test "l1-approval timer: the l1 task is cancelled and l2-approval (role-credit-director) is created" do
    {schema, id} = at_l1_approval!()
    l1 = task!(schema, id, "l1-approval")

    timer = fire_escalation!(schema, id)
    assert timer.node_id == "l1-approval"
    assert abs(DateTime.diff(timer.fire_at, timer.created_at, :second) - 2 * 86_400) <= 60

    assert Repo.get!(EngineTask, l1.id, prefix: schema).status == :cancelled
    l2 = task!(schema, id, "l2-approval")
    assert l2.status == :pending
    assert l2.assignee_ref == "role-credit-director"
    assert projection(schema, id).current_nodes == ["l2-approval"]
  end

  # --- l2 -> CEO -> fail closed -----------------------------------------------------------------

  test "l2-approval timer: l2 is cancelled and a role-ceo task is created at escalate-l2-approval-to-ceo" do
    {schema, id, l2} = at_escalated_l2!()

    assert Repo.get!(EngineTask, l2.id, prefix: schema).status == :cancelled
    esc = task!(schema, id, "escalate-l2-approval-to-ceo")
    assert esc.status == :pending
    assert esc.assignee_ref == "role-ceo"
    assert projection(schema, id).current_nodes == ["escalate-l2-approval-to-ceo"]
    assert projection(schema, id).status == :active

    # not an approval: nothing was created or declined yet
    assert dispatches(schema, id)
           |> Enum.map(& &1.node_id)
           |> Enum.reject(&(&1 == "kyc-aml-check")) == []
  end

  test "a stalled CEO escalation fails closed: decline-application, never create-facility" do
    {schema, id, _l2} = at_escalated_l2!()
    esc = task!(schema, id, "escalate-l2-approval-to-ceo")

    timer = fire_escalation!(schema, id)
    assert timer.node_id == "escalate-l2-approval-to-ceo"

    assert Repo.get!(EngineTask, esc.id, prefix: schema).status == :cancelled
    assert projection(schema, id).current_nodes == ["decline-application"]

    nodes = dispatches(schema, id) |> Enum.map(& &1.node_id)
    assert "decline-application" in nodes
    refute "create-facility" in nodes

    advance_service_task!(schema, id, "decline-application", %{})
    assert projection(schema, id).status == :completed
    refute "create-facility" in (dispatches(schema, id) |> Enum.map(& &1.node_id))
    assert tasks(schema, id, "disburse-loan") == []
  end

  test "the CEO escalation task takes the same decision: an explicit 'approve' creates the facility, 'reject' declines" do
    {schema, id, _l2} = at_escalated_l2!()

    complete!(schema, task!(schema, id, "escalate-l2-approval-to-ceo"), %{
      "l2_decision" => "approve"
    })

    assert projection(schema, id).current_nodes == ["create-facility"]

    {schema2, id2, _} = at_escalated_l2!()

    complete!(schema2, task!(schema2, id2, "escalate-l2-approval-to-ceo"), %{
      "l2_decision" => "reject"
    })

    assert projection(schema2, id2).current_nodes == ["decline-application"]
  end

  test "normal path is unchanged: completing l2-approval in time approves and cancels its escalation timer" do
    {schema, id} = at_l2_approval!()
    complete!(schema, task!(schema, id, "l2-approval"), %{"l2_decision" => "approve"})
    assert projection(schema, id).current_nodes == ["create-facility"]

    assert Timer
           |> where([t], t.instance_id == ^id and t.status == "pending")
           |> Repo.all(prefix: schema) == []
  end

  # --- disbursement -> credit director -> hold --------------------------------------------------

  defp at_disburse_loan! do
    {schema, id} = at_l2_approval!()
    complete!(schema, task!(schema, id, "l2-approval"), %{"l2_decision" => "approve"})
    advance_service_task!(schema, id, "create-facility", %{"facility_id" => "FAC-1013"})
    assert projection(schema, id).current_nodes == ["disburse-loan"]
    {schema, id}
  end

  test "disburse-loan timer escalates to role-loan-ops-lead; a stalled escalation holds the loan with a notice (no payout)" do
    {schema, id} = at_disburse_loan!()
    original = task!(schema, id, "disburse-loan")
    assert original.assignee_ref == "role-loan-ops"

    timer = fire_escalation!(schema, id)
    assert timer.node_id == "disburse-loan"
    assert abs(DateTime.diff(timer.fire_at, timer.created_at, :second) - 86_400) <= 60

    assert Repo.get!(EngineTask, original.id, prefix: schema).status == :cancelled
    esc = task!(schema, id, "escalate-disburse-loan-to-loan-ops-lead")
    assert esc.assignee_ref == "role-loan-ops-lead"

    timer2 = fire_escalation!(schema, id)
    assert timer2.node_id == "escalate-disburse-loan-to-loan-ops-lead"
    assert Repo.get!(EngineTask, esc.id, prefix: schema).status == :cancelled
    assert projection(schema, id).current_nodes == ["disbursement-held-notice"]

    advance_service_task!(schema, id, "disbursement-held-notice", %{})
    proj = projection(schema, id)
    assert proj.status == :completed

    # the held path never completed a disbursement: no task for it was ever completed
    for t <-
          tasks(schema, id, "disburse-loan") ++
            tasks(schema, id, "escalate-disburse-loan-to-loan-ops-lead") do
      assert t.status == :cancelled
    end
  end

  test "a role-loan-ops-lead holder completing the escalated disbursement in time ends disbursed" do
    {schema, id} = at_disburse_loan!()
    fire_escalation!(schema, id)
    ops = loan_ops_lead!(schema)

    complete_as!(
      schema,
      task!(schema, id, "escalate-disburse-loan-to-loan-ops-lead"),
      ops.id,
      %{}
    )

    assert projection(schema, id).status == :completed

    assert dispatches(schema, id)
           |> Enum.map(& &1.node_id)
           |> Enum.member?("disbursement-held-notice") == false
  end
end
