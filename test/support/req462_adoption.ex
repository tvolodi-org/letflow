defmodule Letflow.Req462Adoption do
  @moduledoc """
  Test support for REQ-462 (`required_outputs` adoption on twelve shipped HUMAN_TASK nodes).

  Drives the REAL fixtures through the REAL `Definitions` registration/activation,
  `Engine.create/2`, `Engine.complete_task/3` and the real timer path
  (`Scheduler.resolve_advance_target/3` + `Scheduler.fire_timer/2`). No mocks, no wall clock.

  `assert_omitted_refused!/5` is the shared assertion of the twelve per-node tests: the decision
  key is OMITTED (three different ways) and the completion must be refused with
  `{:error, {:output_refused, %{missing_keys: [key], rejected_keys: []}}}` -- the engine-side shape
  the tasks router renders as 422 `output_refused` (pinned in
  `test/letflow/routers/tasks_required_outputs_test.exs`) -- while the task stays open and the
  instance is byte-for-byte unchanged (status, current nodes, variables, event count, no
  EXECUTION_ERROR).

  No optional-argument defaults anywhere (anti-patterns.md ISS-0069).
  """

  import ExUnit.Assertions
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  @qa Path.expand("../fixtures/qa", __DIR__)

  @spec fixture_path(String.t()) :: String.t()
  def fixture_path(file), do: Path.join(@qa, file)

  @spec sandbox_auto!() :: :ok
  def sandbox_auto! do
    Sandbox.mode(Repo, :auto)
    :ok
  end

  @spec unique(String.t()) :: String.t()
  def unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  @doc "Registers (with variable_schemas), activates and starts a fresh instance in a fresh tenant."
  @spec started_instance!(String.t(), map()) :: {String.t(), Ecto.UUID.t()}
  def started_instance!(fixture_file, variables) do
    schema = TenantFixture.provisioned_tenant!(slug_prefix: "req462").schema_name
    doc = fixture_file |> fixture_path() |> File.read!() |> Jason.decode!()

    entries =
      Enum.map(doc["variable_schemas"], fn e ->
        %{variable_key: e["variable_key"], json_schema: e["json_schema"], description: nil}
      end)

    assert {:ok, definition} =
             Definitions.create_with_variable_schemas(
               %{
                 name: unique("req462-def"),
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
                 idempotency_key: unique("req462-start")
               },
               prefix: schema
             )

    {schema, result.instance_id}
  end

  @spec task!(String.t(), Ecto.UUID.t(), String.t()) :: EngineTask.t()
  def task!(schema, instance_id, node_id) do
    assert [task] =
             EngineTask
             |> where([t], t.instance_id == ^instance_id and t.node_id == ^node_id)
             |> Repo.all(prefix: schema)

    task
  end

  @spec complete(String.t(), EngineTask.t(), map()) :: term()
  def complete(schema, task, output) do
    Engine.complete_task(
      task.id,
      %{
        output_variables: output,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique("req462-complete")
      },
      prefix: schema
    )
  end

  @spec complete!(String.t(), EngineTask.t(), map()) :: term()
  def complete!(schema, task, output), do: assert({:ok, _} = complete(schema, task, output))

  @spec projection(String.t(), Ecto.UUID.t()) :: InstanceProjection.t()
  def projection(schema, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: schema)

  @spec task_status(String.t(), EngineTask.t()) :: atom()
  def task_status(schema, task), do: Repo.get!(EngineTask, task.id, prefix: schema).status

  @spec event_count(String.t(), Ecto.UUID.t()) :: non_neg_integer()
  def event_count(schema, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id)
    |> Repo.aggregate(:count, prefix: schema)
  end

  @spec event_count(String.t(), Ecto.UUID.t(), String.t()) :: non_neg_integer()
  def event_count(schema, instance_id, type) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == ^type)
    |> Repo.aggregate(:count, prefix: schema)
  end

  @spec dispatched_nodes(String.t(), Ecto.UUID.t()) :: [String.t()]
  def dispatched_nodes(schema, instance_id) do
    ServiceTaskDispatch
    |> where([d], d.instance_id == ^instance_id)
    |> Repo.all(prefix: schema)
    |> Enum.map(& &1.node_id)
  end

  @doc "Re-enters a service task's outcome without HTTP (the poller's `mark advanced` + re-entry)."
  @spec advance_service_task!(String.t(), Ecto.UUID.t(), String.t(), map()) :: term()
  def advance_service_task!(schema, instance_id, node_id, outputs) do
    assert [row] =
             ServiceTaskDispatch
             |> where([d], d.instance_id == ^instance_id and d.node_id == ^node_id)
             |> where([d], d.status == :pending)
             |> Repo.all(prefix: schema)

    row = row |> Ecto.Changeset.change(%{status: :advanced}) |> Repo.update!(prefix: schema)

    assert {:ok, :advanced} =
             Engine.advance_after_service_task_outcome(row.id, {:advance, outputs}, Repo, schema)
  end

  @doc """
  Fires the one pending escalation timer, exactly as POST /instances/:id/advance-timer does with
  no timer_id, and returns the timer so the caller can assert which node it armed on.
  """
  @spec fire_escalation!(String.t(), Ecto.UUID.t()) :: Timer.t()
  def fire_escalation!(schema, instance_id) do
    assert {:ok, %Timer{} = timer} = Scheduler.resolve_advance_target(instance_id, nil, schema)
    assert timer.timer_type == "escalation"
    assert {:ok, :fired} = Scheduler.fire_timer(timer.id, schema)
    timer
  end

  @doc """
  The shared REQ-462 assertion. Completes `node_id`'s task with `key` OMITTED three ways (empty
  output, an explicit `nil`, and `extra` -- other keys only) and asserts each is refused naming
  exactly `[key]`, with the task still open and the instance unchanged. Returns the (still open)
  task so the caller can complete it with a valid value.
  """
  @spec assert_omitted_refused!(String.t(), Ecto.UUID.t(), String.t(), String.t(), map()) ::
          EngineTask.t()
  def assert_omitted_refused!(schema, instance_id, node_id, key, extra) do
    task = task!(schema, instance_id, node_id)
    assert task.status == :pending
    refute Map.has_key?(extra, key), "extra output must not carry the decision key"

    before_state = snapshot(schema, instance_id)
    before_events = event_count(schema, instance_id)

    for output <- [%{}, %{key => nil}, extra] do
      assert {:error, {:output_refused, %{missing_keys: [^key], rejected_keys: []}}} =
               complete(schema, task, output),
             "#{node_id}: completing with #{inspect(output)} must be refused naming #{key}"

      assert task_status(schema, task) == :pending, "#{node_id}: the task must stay open"

      assert snapshot(schema, instance_id) == before_state,
             "#{node_id}: the instance must be unchanged by a refused completion"

      assert event_count(schema, instance_id) == before_events,
             "#{node_id}: a refused completion must append no event"

      assert event_count(schema, instance_id, "EXECUTION_ERROR") == 0
    end

    task
  end

  defp snapshot(schema, instance_id) do
    proj = projection(schema, instance_id)
    %{status: proj.status, current_nodes: proj.current_nodes, variables: proj.variables}
  end
end
