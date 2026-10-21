defmodule Letflow.Engine.RegulatoryReviewTimerPathTest do
  @moduledoc """
  ISS-0932 / Q-915 end-to-end regression (E1/E2 of
  `lib/letflow/design/q915-regulatory-review-21day-timer-path.md` section 7.2).

  Loads the REAL Meridian "Regulatory Compliance Review" fixture and proves:

    * E1 -- after `evidence-collection` completes, exactly one pending P21D escalation
      timer exists on `risk-evaluation` (the resolver `POST /instances/:id/advance-timer`
      uses finds it; pre-fix it returned `:no_pending_timer` = HTTP 404), firing it
      cancels the task, dispatches `regulatory-auto-escalation`, and after the service
      task outcome the instance is COMPLETED at `end-closed`.
    * E2 -- normal path: the risk manager completing `risk-evaluation` still goes to
      `findings-sign-off` via `severity-routing`.

  No HTTP is made: the dispatcher is not run; the test performs the poller's re-entry
  (`mark advanced` + `advance_after_service_task_outcome/4`) itself, as
  `engine_catalog_service_task_test.exs` does. Real Postgres, `async: false`.
  See `test/specs/ISS-0932.md`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  @fixture Path.expand(
             "../../fixtures/qa/meridian_regulatory_compliance_review_process_definition.json",
             __DIR__
           )

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # ---------------------------------------------------------------------------------
  # Helpers (no optional-argument defaults -- anti-patterns.md ISS-0069)
  # ---------------------------------------------------------------------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  defp started_instance! do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0932")
    schema = tenant.schema_name
    doc = fixture()

    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique("iss0932-def"),
                 version: doc["version"],
                 graph: doc["graph"],
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema
             )

    assert {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: active.id,
                 initial_variables: %{"review_id" => "sim-q915-001"},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss0932-start")
               },
               prefix: schema
             )

    {schema, result.instance_id}
  end

  defp pending_task!(schema, instance_id, node_id) do
    tasks =
      EngineTask
      |> where([t], t.instance_id == ^instance_id and t.node_id == ^node_id)
      |> Repo.all(prefix: schema)

    assert [task] = tasks
    task
  end

  defp complete!(schema, task, output) do
    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: output,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss0932-complete")
               },
               prefix: schema
             )
  end

  defp projection(schema, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: schema)

  defp dispatches(schema, instance_id) do
    ServiceTaskDispatch
    |> where([d], d.instance_id == ^instance_id)
    |> Repo.all(prefix: schema)
  end

  # Reproduce attempt_dispatch/2's precondition (status "advanced") -- no HTTP.
  defp mark_advanced!(schema, row) do
    row |> Ecto.Changeset.change(%{status: :advanced}) |> Repo.update!(prefix: schema)
  end

  # ---------------------------------------------------------------------------------
  # E1 -- required outcome of ISS-0932
  # ---------------------------------------------------------------------------------

  test "E1 evidence-collection done -> pending P21D timer -> advance-timer fires -> BaFin notice -> COMPLETED at end-closed" do
    {schema, instance_id} = started_instance!()

    complete!(schema, pending_task!(schema, instance_id, "evidence-collection"), %{})

    # Step 2: parked at risk-evaluation for the risk manager.
    proj = projection(schema, instance_id)
    assert proj.status == :active
    assert "risk-evaluation" in proj.current_nodes
    risk_task = pending_task!(schema, instance_id, "risk-evaluation")
    assert risk_task.status == :pending

    # Step 3: the exact resolver the advance-timer router calls (pre-fix: no_pending_timer = 404).
    assert {:ok, %Timer{} = timer} = Scheduler.resolve_advance_target(instance_id, nil, schema)
    assert timer.timer_type == "escalation"
    assert timer.node_id == "risk-evaluation"
    assert timer.status == "pending"

    delta = DateTime.diff(timer.fire_at, timer.created_at, :second)
    assert abs(delta - 21 * 86_400) <= 60

    # Step 4: the second call the router makes.
    assert {:ok, :fired} = Scheduler.fire_timer(timer.id, schema)

    # Step 5: task cancelled, BaFin notice dispatch created.
    assert Repo.get!(EngineTask, risk_task.id, prefix: schema).status == :cancelled
    assert projection(schema, instance_id).current_nodes == ["regulatory-auto-escalation"]

    assert [row] = dispatches(schema, instance_id)
    assert row.node_id == "regulatory-auto-escalation"
    assert row.status == :pending

    assert row.config_snapshot["rendered_url"] ==
             "https://httpbin.org/anything/compliance/regulatory-notice"

    # Step 6: dispatcher stub -> poller re-entry.
    assert {:ok, :advanced} =
             Engine.advance_after_service_task_outcome(
               mark_advanced!(schema, row).id,
               {:advance, %{}},
               Repo,
               schema
             )

    # Step 7: COMPLETED at end-closed, nothing left dangling.
    assert projection(schema, instance_id).status == :completed

    tokens = TokenRecord |> where([t], t.instance_id == ^instance_id) |> Repo.all(prefix: schema)
    # The token row keeps the last non-END node id (END is not persisted as a token
    # position); the only edge into end-closed is e5 from the BaFin notice, proven below.
    assert [%TokenRecord{status: :completed, node_id: "regulatory-auto-escalation"}] = tokens

    assert {:ok, events} = Reconstruction.read_full_log(instance_id, schema, 1)
    types = Enum.map(events, & &1.event_type)

    assert types == [
             "INSTANCE_STARTED",
             "TASK_COMPLETED",
             "TIMER_FIRED",
             "SERVICE_TASK_COMPLETED"
           ]

    refute Enum.any?(events, &(&1.event_type == "EXECUTION_ERROR"))

    assert Enum.all?(dispatches(schema, instance_id), &(&1.status != :pending))

    pending_timers =
      Timer
      |> where([t], t.instance_id == ^instance_id and t.status == "pending")
      |> Repo.all(prefix: schema)

    assert pending_timers == []
  end

  # ---------------------------------------------------------------------------------
  # E2 -- normal path still works
  # ---------------------------------------------------------------------------------

  test "E2 risk manager completes risk-evaluation -> severity-routing -> findings-sign-off (no BaFin dispatch)" do
    {schema, instance_id} = started_instance!()

    complete!(schema, pending_task!(schema, instance_id, "evidence-collection"), %{})
    risk_task = pending_task!(schema, instance_id, "risk-evaluation")
    complete!(schema, risk_task, %{"highest_severity" => "low"})

    proj = projection(schema, instance_id)
    assert proj.status == :active
    assert proj.current_nodes == ["findings-sign-off"]

    assert Repo.get!(EngineTask, risk_task.id, prefix: schema).status == :completed

    sign_off = pending_task!(schema, instance_id, "findings-sign-off")
    assert sign_off.status == :pending
    assert dispatches(schema, instance_id) == []
  end
end
