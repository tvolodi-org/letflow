defmodule Letflow.EngineProjectionEventInvariantTest do
  @moduledoc """
  GH #2577 -- for every projection state change of the engine commands that take an idempotency
  key, exactly one corresponding event exists, and a rebuild from the events reproduces the
  projection. A same-key replay must not add a second change, so the invariant holds after it.

  Paths: start, cancel, rebind, complete_task. Each runs once and then again with the same key.
  Real Postgres, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.PinRebind
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(slug_prefix: "gh2577i", display_name: "GH-2577 Invariant")
  end

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp active_definition!(schema_name) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique("gh2577i-def"),
                 version: "1.0.0",
                 graph: graph_human_task_end(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp events(schema, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id)
    |> order_by([e], asc: e.sequence_number)
    |> Repo.all(prefix: schema)
  end

  defp projection(schema, instance_id),
    do: Repo.get_by!(InstanceProjection, [instance_id: instance_id], prefix: schema)

  # Sequence numbers are contiguous, the projection points at the last one, and the number of
  # events of each type is the number of projection changes that type makes.
  defp assert_one_event_per_change(schema, instance_id, expected_counts) do
    all = events(schema, instance_id)
    proj = projection(schema, instance_id)

    assert all |> Enum.map(& &1.sequence_number) == Enum.to_list(1..length(all))
    assert proj.last_event_seq == length(all)

    for {type, count} <- expected_counts do
      assert Enum.count(all, &(&1.event_type == type)) == count, "event count for #{type}"
    end

    proj
  end

  # A rebuild from the events reproduces the projection's status and variables. Rebind pins are
  # not folded by the replay engine (see Reconstruction), so it is skipped for those instances.
  defp assert_rebuild_matches(schema, instance_id, proj) do
    assert {:ok, %{instance_state: state}} =
             Reconstruction.reconstruct_instance(instance_id, prefix: schema)

    assert state.status == proj.status
    assert state.variables == proj.variables
  end

  test "start: a same-key replay leaves one INSTANCE_STARTED and a rebuildable projection" do
    %{schema_name: schema} = provisioned_tenant()
    definition = active_definition!(schema)

    attrs = %{
      definition_id: definition.id,
      initial_variables: %{},
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique("start")
    }

    assert {:ok, first} = Engine.create(attrs, prefix: schema)
    assert {:ok, %{instance_id: id}} = Engine.create(attrs, prefix: schema)
    assert id == first.instance_id

    proj = assert_one_event_per_change(schema, id, %{"INSTANCE_STARTED" => 1})
    assert proj.status == :active
    assert_rebuild_matches(schema, id, proj)
  end

  test "cancel: a same-key replay leaves one INSTANCE_CANCELLED and a rebuildable projection" do
    %{schema_name: schema} = provisioned_tenant()
    definition = active_definition!(schema)

    assert {:ok, %{instance_id: id}} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("start")
               },
               prefix: schema
             )

    attrs = %{actor_id: Ecto.UUID.generate(), idempotency_key: unique("cancel")}

    assert {:ok, first} = Engine.cancel_instance(id, attrs, prefix: schema)
    assert {:ok, replay} = Engine.cancel_instance(id, attrs, prefix: schema)
    assert Map.delete(replay, :replayed) == Map.delete(first, :replayed)

    proj =
      assert_one_event_per_change(schema, id, %{
        "INSTANCE_STARTED" => 1,
        "INSTANCE_CANCELLED" => 1
      })

    assert proj.status == :cancelled
    assert_rebuild_matches(schema, id, proj)
  end

  test "rebind: a same-key replay leaves one INSTANCE_PINS_REBOUND" do
    %{schema_name: schema} = provisioned_tenant()
    definition = active_definition!(schema)

    assert {:ok, %{instance_id: id}} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("start")
               },
               prefix: schema
             )

    attrs = %{
      entries: [%{kind: :variable_schema, ref: definition.name, version: "v1"}],
      reason: "r",
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique("rebind")
    }

    assert {:ok, first} = PinRebind.rebind_pins(id, attrs, prefix: schema)
    assert {:ok, replay} = PinRebind.rebind_pins(id, attrs, prefix: schema)
    assert Map.delete(replay, :replayed) == Map.delete(first, :replayed)

    assert_one_event_per_change(schema, id, %{
      "INSTANCE_STARTED" => 1,
      "INSTANCE_PINS_REBOUND" => 1
    })
  end

  test "complete_task: a same-key retry leaves one TASK_COMPLETED and a rebuildable projection" do
    %{schema_name: schema} = provisioned_tenant()
    definition = active_definition!(schema)

    assert {:ok, %{instance_id: id}} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("start")
               },
               prefix: schema
             )

    task =
      EngineTask
      |> where([t], t.instance_id == ^id and t.status == :pending)
      |> Repo.one!(prefix: schema)

    attrs = %{output_variables: %{}, actor_id: Ecto.UUID.generate(), idempotency_key: unique("c")}

    assert {:ok, _} = Engine.complete_task(task.id, attrs, prefix: schema)

    assert {:error, {:task_not_pending, :completed}} =
             Engine.complete_task(task.id, attrs, prefix: schema)

    proj =
      assert_one_event_per_change(schema, id, %{
        "INSTANCE_STARTED" => 1,
        "TASK_COMPLETED" => 1
      })

    assert proj.status == :completed
    assert_rebuild_matches(schema, id, proj)
  end
end
