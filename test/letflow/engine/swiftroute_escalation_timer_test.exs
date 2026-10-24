defmodule Letflow.Engine.SwiftrouteEscalationTimerTest do
  @moduledoc """
  ISS-1007 / Q-989 (GH #2276) -- engine-level proof of the D-ESC escalation chains (BA ruling
  GH #2281) on the REAL SwiftRoute fixtures: "Shipment Approval" (QA JSON, v1.4) and "Driver
  Incident Report" (simulation YAML; the QA fixture is test/fixtures/qa/swiftroute_incident_process_definition.json, ISS-1022 / Q-1004), through the real
  `Definitions` registration/activation, `Engine.create/2`, `Engine.complete_task/3` and the real
  timer path the advance-timer route uses (`Scheduler.resolve_advance_target/3` +
  `Scheduler.fire_timer/2`).

    * ops-review's timer escalates to the `ceo-approval` task (role-ceo): the original task is
      CANCELLED; ceo-approval now has its own timer, and when THAT is stalled the flow fails
      closed to `auto-reject`, NEVER `release-shipment`;
    * ceo-approval reached the normal way (ops approve, value > 500) fails closed the same way,
      and an explicit CEO approve still releases (the timer pair did not break the decision);
    * ops-assessment / finance-estimate (parallel branches) each escalate to a role-ceo task,
      whose own timer lands on that branch's `*-auto-close` notice; a completed escalation task
      rejoins the AND-join exactly like the original.

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

  @approval Path.expand("../../fixtures/qa/swiftroute_process_definition.json", __DIR__)
  @incident Path.expand(
              "../../fixtures/simulation/swiftroute/process_shipment_dispatch.yaml",
              __DIR__
            )

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # --- helpers (no optional-argument defaults: anti-patterns.md ISS-0069) ---------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp read_fixture(path) do
    if String.ends_with?(path, ".json"),
      do: path |> File.read!() |> Jason.decode!(),
      else: YamlElixir.read_from_file!(path)
  end

  defp started_instance!(fixture, variables) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss1007")
    schema = tenant.schema_name
    doc = read_fixture(fixture)

    entries =
      Enum.map(doc["variable_schemas"] || [], fn e ->
        %{variable_key: e["variable_key"], json_schema: e["json_schema"], description: nil}
      end)

    assert {:ok, definition} =
             Definitions.create_with_variable_schemas(
               %{
                 name: unique("iss1007-def"),
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
                 idempotency_key: unique("iss1007-start")
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
                 idempotency_key: unique("iss1007-complete")
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

  # Fires the one pending escalation timer, exactly as POST /instances/:id/advance-timer does with
  # no timer_id, and returns the timer so the caller can assert which node it armed on.
  defp fire_only_escalation!(schema, instance_id) do
    assert {:ok, %Timer{} = timer} = Scheduler.resolve_advance_target(instance_id, nil, schema)
    assert timer.timer_type == "escalation"
    assert {:ok, :fired} = Scheduler.fire_timer(timer.id, schema)
    timer
  end

  # With several timers pending at once (the parallel incident branches) the route needs a
  # timer_id: this is that request.
  defp fire_escalation_at!(schema, instance_id, node_id) do
    timer =
      Timer
      |> where(
        [t],
        t.instance_id == ^instance_id and t.node_id == ^node_id and t.status == "pending"
      )
      |> Repo.one!(prefix: schema)

    assert timer.timer_type == "escalation"
    assert {:ok, %Timer{}} = Scheduler.resolve_advance_target(instance_id, timer.id, schema)
    assert {:ok, :fired} = Scheduler.fire_timer(timer.id, schema)
    timer
  end

  defp assert_duration!(timer, seconds),
    do: assert(abs(DateTime.diff(timer.fire_at, timer.created_at, :second) - seconds) <= 60)

  defp shipment!(value),
    do: started_instance!(@approval, %{"shipment_id" => "ship-1007", "declared_value" => value})

  defp incident!,
    do: started_instance!(@incident, %{"incident_id" => "inc-1007", "injury_involved" => false})

  # --- Shipment Approval: ops-review -> ceo-approval -> fail closed ---------------------------

  test "ops-review timer: the original is cancelled and the role-ceo ceo-approval task is created" do
    {schema, id} = shipment!(800)
    original = task!(schema, id, "ops-review")
    assert original.assignee_ref == "role-ops-manager"

    timer = fire_only_escalation!(schema, id)
    assert timer.node_id == "ops-review"
    assert_duration!(timer, 2 * 3600)

    assert Repo.get!(EngineTask, original.id, prefix: schema).status == :cancelled
    esc = task!(schema, id, "ceo-approval")
    assert esc.status == :pending
    assert esc.assignee_ref == "role-ceo"
    assert projection(schema, id).current_nodes == ["ceo-approval"]
    assert projection(schema, id).status == :active
    # an escalation is not a decision: nothing was released or rejected yet
    assert dispatched_nodes(schema, id) == []
  end

  test "a stalled CEO escalation fails closed: auto-reject, never release-shipment" do
    {schema, id} = shipment!(800)
    fire_only_escalation!(schema, id)
    esc = task!(schema, id, "ceo-approval")

    # ceo-approval now carries its own timer (v1.4): it is the one pending timer
    timer = fire_only_escalation!(schema, id)
    assert timer.node_id == "ceo-approval"
    assert_duration!(timer, 4 * 3600)

    assert Repo.get!(EngineTask, esc.id, prefix: schema).status == :cancelled
    assert projection(schema, id).current_nodes == ["auto-reject"]
    assert dispatched_nodes(schema, id) == ["auto-reject"]

    advance_service_task!(schema, id, "auto-reject", %{})
    assert projection(schema, id).status == :completed
    refute "release-shipment" in dispatched_nodes(schema, id)
  end

  test "ceo-approval reached the normal way (ops approve, value > 500) also fails closed" do
    {schema, id} = shipment!(800)
    complete!(schema, task!(schema, id, "ops-review"), %{"ops_decision" => "approve"})
    assert projection(schema, id).current_nodes == ["ceo-approval"]
    ceo = task!(schema, id, "ceo-approval")

    timer = fire_only_escalation!(schema, id)
    assert timer.node_id == "ceo-approval"

    assert Repo.get!(EngineTask, ceo.id, prefix: schema).status == :cancelled
    assert projection(schema, id).current_nodes == ["auto-reject"]
    assert dispatched_nodes(schema, id) == ["auto-reject"]
  end

  test "an explicit CEO approve still releases the shipment (the timer pair left the decision intact)" do
    {schema, id} = shipment!(800)
    complete!(schema, task!(schema, id, "ops-review"), %{"ops_decision" => "approve"})
    complete!(schema, task!(schema, id, "ceo-approval"), %{"ceo_decision" => "approve"})

    assert projection(schema, id).current_nodes == ["release-shipment"]
    assert dispatched_nodes(schema, id) == ["release-shipment"]
  end

  # --- Driver Incident Report: each branch -> CEO -> notice ------------------------------------

  test "starting the incident arms an escalation timer on each human task (P1D)" do
    {schema, id} = incident!()

    pending =
      Timer
      |> where([t], t.instance_id == ^id and t.status == "pending")
      |> Repo.all(prefix: schema)

    by_node = Map.new(pending, &{&1.node_id, &1})

    assert Map.keys(by_node) |> Enum.sort() == ["finance-estimate", "ops-assessment"]

    assert by_node["ops-assessment"].timer_type == "escalation"
    assert by_node["finance-estimate"].timer_type == "escalation"
    assert_duration!(by_node["ops-assessment"], 86_400)
    assert_duration!(by_node["finance-estimate"], 86_400)

    # without a timer_id the route cannot pick one
    assert {:error, :ambiguous_pending_timers} = Scheduler.resolve_advance_target(id, nil, schema)
  end

  test "ops-assessment timer: original cancelled, role-ceo task created, finance branch untouched" do
    {schema, id} = incident!()
    original = task!(schema, id, "ops-assessment")
    assert original.assignee_ref == "role-ops-manager"
    finance = task!(schema, id, "finance-estimate")

    fire_escalation_at!(schema, id, "ops-assessment")

    assert Repo.get!(EngineTask, original.id, prefix: schema).status == :cancelled
    esc = task!(schema, id, "escalate-ops-assessment-to-ceo")
    assert esc.status == :pending
    assert esc.assignee_ref == "role-ceo"
    assert Repo.get!(EngineTask, finance.id, prefix: schema).status == :pending
    assert dispatched_nodes(schema, id) == []
    assert projection(schema, id).status == :active
  end

  test "finance-estimate timer: original cancelled, role-ceo task created, ops branch untouched" do
    {schema, id} = incident!()
    original = task!(schema, id, "finance-estimate")
    assert original.assignee_ref == "role-accountant"
    ops = task!(schema, id, "ops-assessment")

    fire_escalation_at!(schema, id, "finance-estimate")

    assert Repo.get!(EngineTask, original.id, prefix: schema).status == :cancelled
    esc = task!(schema, id, "escalate-finance-estimate-to-ceo")
    assert esc.status == :pending
    assert esc.assignee_ref == "role-ceo"
    assert Repo.get!(EngineTask, ops.id, prefix: schema).status == :pending
    assert dispatched_nodes(schema, id) == []
  end

  test "a stalled ops escalation fails closed: the ops-timeout notice, the incident is not closed" do
    {schema, id} = incident!()
    fire_escalation_at!(schema, id, "ops-assessment")
    esc = task!(schema, id, "escalate-ops-assessment-to-ceo")

    timer = fire_escalation_at!(schema, id, "escalate-ops-assessment-to-ceo")
    assert_duration!(timer, 86_400)

    assert Repo.get!(EngineTask, esc.id, prefix: schema).status == :cancelled
    assert "ops-auto-close" in projection(schema, id).current_nodes
    assert dispatched_nodes(schema, id) == ["ops-auto-close"]

    # the notice joins the branch; the finance estimate is still outstanding, so no case summary
    advance_service_task!(schema, id, "ops-auto-close", %{})
    assert projection(schema, id).status == :active
    refute "case-summary" in dispatched_nodes(schema, id)
    assert "finance-estimate" in projection(schema, id).current_nodes
  end

  test "a stalled finance escalation fails closed: the finance-timeout notice" do
    {schema, id} = incident!()
    fire_escalation_at!(schema, id, "finance-estimate")
    esc = task!(schema, id, "escalate-finance-estimate-to-ceo")

    fire_escalation_at!(schema, id, "escalate-finance-estimate-to-ceo")

    assert Repo.get!(EngineTask, esc.id, prefix: schema).status == :cancelled
    assert "finance-auto-close" in projection(schema, id).current_nodes
    assert dispatched_nodes(schema, id) == ["finance-auto-close"]
  end

  test "a completed CEO escalation task rejoins the AND-join exactly like the original would" do
    {schema, id} = incident!()
    fire_escalation_at!(schema, id, "ops-assessment")

    complete!(schema, task!(schema, id, "escalate-ops-assessment-to-ceo"), %{
      "assessment_notes" => "escalated assessment"
    })

    # the ops branch is done and waiting at the join; finance is still outstanding
    assert projection(schema, id).status == :active
    assert "finance-estimate" in projection(schema, id).current_nodes
    refute "case-summary" in dispatched_nodes(schema, id)

    # an ordinary (non-escalated) completion of the other branch still works (e8 carries `true`)
    complete!(schema, task!(schema, id, "finance-estimate"), %{"estimated_cost_eur" => 0})
    refute "finance-estimate" in projection(schema, id).current_nodes
  end

  # GH #2933: the join must not wait on a third (timer) branch.
  test "ops-assessment and finance-estimate completing reaches case-summary with no timer fired" do
    {schema, id} = incident!()
    complete!(schema, task!(schema, id, "ops-assessment"), %{"assessment_notes" => "assessed"})

    complete!(schema, task!(schema, id, "finance-estimate"), %{"estimated_cost_eur" => 1200})

    assert "case-summary" in dispatched_nodes(schema, id)
    advance_service_task!(schema, id, "case-summary", %{})
    assert projection(schema, id).status == :completed
  end
end
