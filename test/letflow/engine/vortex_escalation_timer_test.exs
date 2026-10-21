defmodule Letflow.Engine.VortexEscalationTimerTest do
  @moduledoc """
  ISS-1002 / Q-984 (GH #2271) -- engine-level proof of the D-ESC escalation chains (BA ruling
  GH #2281) on the REAL Vortex fixtures "Production Order Release" (v1.5) and "Supplier Quality
  Deviation" (v1.6), through the real `Definitions` registration/activation, `Engine.create/2`,
  `Engine.complete_task/3` and the real timer path the advance-timer route uses
  (`Scheduler.resolve_advance_target/3` + `Scheduler.fire_timer/2`).

    * capacity-review's timer escalates to `escalate-to-ceo` (role-ceo): the original task is
      CANCELLED; the CEO level's own timer fails closed to `auto-reject-order`, NEVER `assign-line`;
    * budget-approval's timer escalates to the new `escalate-budget-approval-to-ceo` (role-ceo, same
      budget_decision); its own timer fails closed to `auto-reject-order`;
    * severity-classification's timer escalates to `escalate-severity-classification-to-ceo`; its
      own timer reaches `default-to-critical` (severity critical, 8D), never a quarantine release.

  No HTTP: the dispatcher is not run; service-task outcomes are re-entered by hand. Real Postgres,
  `async: false`.
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
  alias Letflow.TenantFixture

  @order Path.expand(
           "../../fixtures/qa/vortex_production_order_release_process_definition.json",
           __DIR__
         )
  @deviation Path.expand(
               "../../fixtures/qa/vortex_supplier_quality_deviation_process_definition.json",
               __DIR__
             )

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # --- helpers (no optional-argument defaults: anti-patterns.md ISS-0069) ---------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp started_instance!(fixture, variables) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss1002")
    schema = tenant.schema_name
    doc = fixture |> File.read!() |> Jason.decode!()

    entries =
      Enum.map(doc["variable_schemas"], fn e ->
        %{variable_key: e["variable_key"], json_schema: e["json_schema"], description: nil}
      end)

    assert {:ok, definition} =
             Definitions.create_with_variable_schemas(
               %{
                 name: unique("iss1002-def"),
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
                 initial_variables: variables,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss1002-start")
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
                 idempotency_key: unique("iss1002-complete")
               },
               prefix: schema
             )
  end

  defp projection(schema, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: schema)

  defp dispatched_nodes(schema, instance_id) do
    ServiceTaskDispatch
    |> where([d], d.instance_id == ^instance_id)
    |> Repo.all(prefix: schema)
    |> Enum.map(& &1.node_id)
  end

  # Re-enter a service task's outcome without HTTP (the poller's `mark advanced` + re-entry).
  defp advance_service_task!(schema, instance_id, node_id, outputs) do
    assert [row] =
             ServiceTaskDispatch
             |> where([d], d.instance_id == ^instance_id and d.node_id == ^node_id)
             |> where([d], d.status == :pending)
             |> Repo.all(prefix: schema)

    row = row |> Ecto.Changeset.change(%{status: :advanced}) |> Repo.update!(prefix: schema)

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

  defp assert_duration!(timer, seconds),
    do: assert(abs(DateTime.diff(timer.fire_at, timer.created_at, :second) - seconds) <= 60)

  defp order!(value),
    do: started_instance!(@order, %{"order_id" => "ord-1002", "order_value_eur" => value})

  # capacity-review approved with value > 10000 -> budget-approval pending.
  defp at_budget_approval! do
    {schema, id} = order!(50_000)
    complete!(schema, task!(schema, id, "capacity-review"), %{"capacity_decision" => "approve"})
    assert projection(schema, id).current_nodes == ["budget-approval"]
    {schema, id}
  end

  # --- capacity-review -> CEO -> fail closed ---------------------------------------------------

  test "capacity-review timer: the original is cancelled and a role-ceo task is created at escalate-to-ceo" do
    {schema, id} = order!(50_000)
    original = task!(schema, id, "capacity-review")
    assert original.assignee_ref == "role-production-manager"

    timer = fire_escalation!(schema, id)
    assert timer.node_id == "capacity-review"
    assert_duration!(timer, 4 * 3600)

    assert Repo.get!(EngineTask, original.id, prefix: schema).status == :cancelled
    esc = task!(schema, id, "escalate-to-ceo")
    assert esc.status == :pending
    assert esc.assignee_ref == "role-ceo"
    assert projection(schema, id).current_nodes == ["escalate-to-ceo"]
    assert projection(schema, id).status == :active
    # an escalation is not a decision: nothing was assigned or rejected yet
    assert dispatched_nodes(schema, id) == []
  end

  test "a stalled CEO escalation fails closed: auto-reject-order, never assign-line" do
    {schema, id} = order!(50_000)
    fire_escalation!(schema, id)
    esc = task!(schema, id, "escalate-to-ceo")

    timer = fire_escalation!(schema, id)
    assert timer.node_id == "escalate-to-ceo"
    assert_duration!(timer, 4 * 3600)

    assert Repo.get!(EngineTask, esc.id, prefix: schema).status == :cancelled
    assert projection(schema, id).current_nodes == ["auto-reject-order"]
    assert dispatched_nodes(schema, id) == ["auto-reject-order"]

    advance_service_task!(schema, id, "auto-reject-order", %{})
    assert projection(schema, id).status == :completed
    refute "assign-line" in dispatched_nodes(schema, id)
    assert tasks(schema, id, "budget-approval") == []
  end

  test "the CEO escalation task takes the same decision: an explicit 'approve' proceeds, 'reject' rejects" do
    {schema, id} = order!(5_000)
    fire_escalation!(schema, id)
    complete!(schema, task!(schema, id, "escalate-to-ceo"), %{"capacity_decision" => "approve"})
    # value <= 10000: budget-gate -> assign-line
    assert projection(schema, id).current_nodes == ["assign-line"]

    {schema2, id2} = order!(5_000)
    fire_escalation!(schema2, id2)
    complete!(schema2, task!(schema2, id2, "escalate-to-ceo"), %{"capacity_decision" => "reject"})
    assert projection(schema2, id2).current_nodes == ["auto-reject-order"]
  end

  test "normal path is unchanged: completing capacity-review in time cancels its escalation timer" do
    {schema, id} = order!(5_000)
    complete!(schema, task!(schema, id, "capacity-review"), %{"capacity_decision" => "approve"})
    assert projection(schema, id).current_nodes == ["assign-line"]

    assert Timer
           |> where([t], t.instance_id == ^id and t.status == "pending")
           |> Repo.all(prefix: schema) == []
  end

  # --- budget-approval -> CEO -> fail closed ---------------------------------------------------

  test "budget-approval timer: the controller's task is cancelled and a role-ceo task is created at escalate-budget-approval-to-ceo" do
    {schema, id} = at_budget_approval!()
    original = task!(schema, id, "budget-approval")
    assert original.assignee_ref == "role-controller"

    timer = fire_escalation!(schema, id)
    assert timer.node_id == "budget-approval"
    assert_duration!(timer, 2 * 86_400)

    assert Repo.get!(EngineTask, original.id, prefix: schema).status == :cancelled
    esc = task!(schema, id, "escalate-budget-approval-to-ceo")
    assert esc.status == :pending
    assert esc.assignee_ref == "role-ceo"
    assert projection(schema, id).current_nodes == ["escalate-budget-approval-to-ceo"]
    assert dispatched_nodes(schema, id) == []
  end

  test "a stalled budget escalation fails closed: auto-reject-order, never assign-line" do
    {schema, id} = at_budget_approval!()
    fire_escalation!(schema, id)
    esc = task!(schema, id, "escalate-budget-approval-to-ceo")

    timer = fire_escalation!(schema, id)
    assert timer.node_id == "escalate-budget-approval-to-ceo"
    assert_duration!(timer, 2 * 86_400)

    assert Repo.get!(EngineTask, esc.id, prefix: schema).status == :cancelled
    assert projection(schema, id).current_nodes == ["auto-reject-order"]
    advance_service_task!(schema, id, "auto-reject-order", %{})
    assert projection(schema, id).status == :completed
    refute "assign-line" in dispatched_nodes(schema, id)
  end

  test "the budget CEO escalation takes the same decision: 'approve' assigns the line, 'reject' rejects" do
    {schema, id} = at_budget_approval!()
    fire_escalation!(schema, id)

    complete!(schema, task!(schema, id, "escalate-budget-approval-to-ceo"), %{
      "budget_decision" => "approve"
    })

    assert projection(schema, id).current_nodes == ["assign-line"]

    {schema2, id2} = at_budget_approval!()
    fire_escalation!(schema2, id2)

    complete!(schema2, task!(schema2, id2, "escalate-budget-approval-to-ceo"), %{
      "budget_decision" => "reject"
    })

    assert projection(schema2, id2).current_nodes == ["auto-reject-order"]
  end

  # --- severity-classification -> CEO -> default-to-critical -----------------------------------

  defp at_severity_classification! do
    {schema, id} =
      started_instance!(@deviation, %{"batch_ref" => "batch-1002", "deviation_id" => "dev-1002"})

    advance_service_task!(schema, id, "quarantine-batch", %{})
    assert projection(schema, id).current_nodes == ["severity-classification"]
    {schema, id}
  end

  test "severity-classification timer escalates to role-ceo; a stalled escalation lands on default-to-critical, the quarantine stays" do
    {schema, id} = at_severity_classification!()
    original = task!(schema, id, "severity-classification")
    assert original.assignee_ref == "role-quality-manager"

    timer = fire_escalation!(schema, id)
    assert timer.node_id == "severity-classification"
    assert_duration!(timer, 4 * 3600)

    assert Repo.get!(EngineTask, original.id, prefix: schema).status == :cancelled
    esc = task!(schema, id, "escalate-severity-classification-to-ceo")
    assert esc.assignee_ref == "role-ceo"
    assert projection(schema, id).current_nodes == ["escalate-severity-classification-to-ceo"]

    timer2 = fire_escalation!(schema, id)
    assert timer2.node_id == "escalate-severity-classification-to-ceo"
    assert Repo.get!(EngineTask, esc.id, prefix: schema).status == :cancelled
    assert projection(schema, id).current_nodes == ["default-to-critical"]
    refute "release-quarantine" in dispatched_nodes(schema, id)
  end

  test "the CEO classification takes the same decision: 'major' routes to supplier-warning, a false positive still releases only by a human decision" do
    {schema, id} = at_severity_classification!()
    fire_escalation!(schema, id)

    complete!(schema, task!(schema, id, "escalate-severity-classification-to-ceo"), %{
      "false_positive" => false,
      "severity" => "major"
    })

    assert projection(schema, id).current_nodes == ["supplier-warning"]

    {schema2, id2} = at_severity_classification!()
    fire_escalation!(schema2, id2)

    # REQ-462: the escalation task declares required_outputs [severity], so even a false
    # positive must carry a severity (the routing still releases by the false_positive decision).
    complete!(schema2, task!(schema2, id2, "escalate-severity-classification-to-ceo"), %{
      "false_positive" => true,
      "severity" => "minor"
    })

    assert projection(schema2, id2).current_nodes == ["release-quarantine"]
  end

  test "normal path is unchanged: completing severity-classification in time cancels its escalation timer" do
    {schema, id} = at_severity_classification!()

    complete!(schema, task!(schema, id, "severity-classification"), %{
      "false_positive" => false,
      "severity" => "minor"
    })

    assert projection(schema, id).current_nodes == ["supplier-notification"]

    assert Timer
           |> where([t], t.instance_id == ^id and t.status == "pending")
           |> Repo.all(prefix: schema) == []
  end
end
