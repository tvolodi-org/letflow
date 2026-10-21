defmodule Letflow.Scripts.Vortex8dReminderTest do
  @moduledoc """
  GH #2553 (REQ-494): the shipped Vortex "8D Corrective Action" definition replaces its E6 waiver
  with a non-cancelling reminder (`reminder_timer_duration` P14D, `reminder_role`
  role-procurement-manager). Runs the real fixture graph through the engine: the reminder timer is
  armed at task creation, firing it writes `task.remind` and leaves the task open and the
  instance running. Timers are fired directly via `Scheduler.fire_timer/2`, so nothing waits on
  the clock.

  Real Postgres, `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  @fixture Path.expand("../../fixtures/qa/vortex_8d_corrective_action_definition.json", __DIR__)

  test "the reminder fires, writes task.remind, and the 8D task stays open" do
    %{schema_name: schema} =
      TenantFixture.provisioned_tenant!(slug_prefix: "vx8d", display_name: "Vortex 8D reminder")

    graph = @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("graph")

    {:ok, definition} =
      Definitions.create(
        %{
          name: "vx8d-" <> to_string(System.unique_integer([:positive])),
          version: "1.2",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        prefix: schema
      )

    {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: schema)

    {:ok, created} =
      Engine.create(
        %{
          definition_id: activated.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: "vx8d-start-" <> to_string(System.unique_integer([:positive]))
        },
        prefix: schema
      )

    task =
      Repo.one!(
        from(t in EngineTask,
          where: t.instance_id == ^created.instance_id and t.node_id == "corrective-action-8d"
        ),
        prefix: schema
      )

    assert task.status == :pending

    timers =
      Repo.all(
        from(t in Timer,
          where: t.instance_id == ^created.instance_id and t.timer_type == "reminder"
        ),
        prefix: schema
      )

    assert [%Timer{status: "pending"} = timer] = timers

    assert abs(DateTime.diff(timer.fire_at, DateTime.add(task.inserted_at, 14 * 86_400, :second))) <=
             1

    assert {:ok, :fired} = Scheduler.fire_timer(timer.id, schema)

    entries =
      Repo.all(
        from(e in Entry,
          where:
            e.resource_type == "task" and e.resource_id == ^task.id and e.action == "task.remind"
        ),
        prefix: schema
      )

    assert [_one] = entries

    assert %EngineTask{status: :pending} = Repo.get!(EngineTask, task.id, prefix: schema)

    assert Repo.aggregate(
             from(t in Timer,
               where: t.instance_id == ^created.instance_id and t.timer_type == "escalation"
             ),
             :count,
             prefix: schema
           ) == 0
  end
end
