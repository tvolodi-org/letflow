defmodule Letflow.Engine.ReconstructionSysTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A1 (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  2.5, D-A1.10, D-A1.13, 11 A1 "engine-only writer + reconstruction"): replay of the two
  decision 0054 instance event types, through the REAL `Reconstruction.reconstruct_instance/2`
  over a REAL instance (`Engine.create/2`, `Engine.complete_task/3`).

  The engine writer of `INSTANCE_SYS_VARIABLES_SET` is PR B, so this file appends the event
  directly with `EventStore.append/2` (the type is registered by the tenant seed), in the
  D-A1.10 order: before the step's `TASK_COMPLETED`. The live projection therefore does not
  hold the reserved values (no live writer yet); the rebuilt state must equal it PLUS exactly
  those values, with the same token positions after a gateway evaluated on the completion.
  (The "replay invokes no EntityPort write callback" case is PR B's, CDV-2.)
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection

  # START -> t1(HUMAN_TASK) -> xg(EXCLUSIVE_GATEWAY) -> a (ok == true) | b (default)
  defp graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "t1", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "r1"}},
        %{"id" => "xg", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "a", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "ra"}},
        %{"id" => "b", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "rb"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "t1"},
        %{"id" => "e2", "source" => "t1", "target" => "xg"},
        %{"id" => "e3", "source" => "xg", "target" => "a", "condition" => "variables.ok == true"},
        %{"id" => "e4", "source" => "xg", "target" => "b", "is_default" => true},
        %{"id" => "e5", "source" => "a", "target" => "end"},
        %{"id" => "e6", "source" => "b", "target" => "end"}
      ]
    }
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp started_instance! do
    %{schema_name: schema} = Letflow.TenantFixture.provisioned_tenant!(slug_prefix: "gh2587-rc")

    {:ok, definition} =
      Definitions.create(
        %{
          name: uniq("gh2587-rc"),
          version: "1.0.0",
          graph: graph(),
          created_by: Ecto.UUID.generate()
        },
        prefix: schema
      )

    {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)

    {:ok, %{instance_id: instance_id}} =
      Engine.create(
        %{
          definition_id: active.id,
          initial_variables: %{"n" => 1},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: uniq("start")
        },
        prefix: schema
      )

    {schema, instance_id}
  end

  defp append!(schema, instance_id, type, payload) do
    assert {:ok, %{event: event}} =
             EventStore.append(
               %{
                 instance_id: instance_id,
                 event_type: type,
                 payload: Jason.encode!(payload),
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: uniq("gh2587-rc-ev")
               },
               prefix: schema
             )

    event
  end

  defp sys_event!(schema, instance_id, values) do
    append!(schema, instance_id, "INSTANCE_SYS_VARIABLES_SET", %{
      "node_id" => "t1",
      "cause" => "entity_writes",
      "values" => values
    })
  end

  defp complete_t1!(schema, instance_id, output) do
    task =
      Repo.one!(
        from(t in EngineTask,
          where: t.instance_id == ^instance_id and t.node_id == "t1" and t.status == :pending
        ),
        prefix: schema
      )

    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: output,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: uniq("c")
               },
               prefix: schema
             )
  end

  defp projection(schema, id), do: Repo.get!(InstanceProjection, id, prefix: schema)

  defp nodes(state), do: state.tokens |> Enum.map(& &1.node_id) |> Enum.sort()

  test "SYS event before TASK_COMPLETED: rebuilt variables hold both reserved keys; the gateway after the completion takes the live edge" do
    {schema, instance_id} = started_instance!()
    record_id = Ecto.UUID.generate()
    values = %{"_sys.r" => record_id, "_sys.r.seq" => 7}

    sys = sys_event!(schema, instance_id, values)
    complete_t1!(schema, instance_id, %{"ok" => true})

    live = projection(schema, instance_id)
    assert live.current_nodes == ["a"]

    assert {:ok, %{instance_state: state}} =
             Reconstruction.reconstruct_instance(instance_id, prefix: schema)

    assert state.variables == Map.merge(live.variables, values)
    assert state.variables["_sys.r"] == record_id
    assert state.variables["_sys.r.seq"] == 7
    assert nodes(state) == Enum.sort(live.current_nodes)
    assert state.status == live.status

    # D-A1.10 order: the SYS event precedes the step's completion event.
    {:ok, events} = EventStore.read(instance_id, prefix: schema)
    types = Enum.map(events, & &1.event_type)
    sys_index = Enum.find_index(events, &(&1.event_id == sys.event_id))
    assert sys_index < Enum.find_index(types, &(&1 == "TASK_COMPLETED"))
  end

  test "the same stream without the SYS event rebuilds without reserved keys (control)" do
    {schema, instance_id} = started_instance!()
    complete_t1!(schema, instance_id, %{"ok" => false})

    assert {:ok, %{instance_state: state}} =
             Reconstruction.reconstruct_instance(instance_id, prefix: schema)

    live = projection(schema, instance_id)
    assert state.variables == live.variables
    assert Letflow.Engine.VariableMerge.reserved_keys(state.variables) == []
    assert nodes(state) == ["b"]
  end

  for {label, values} <- [
        {"key \"x\"", %{"x" => 1}},
        {"bare reserved name", %{"_sys" => 1}},
        {"value %{}", %{"_sys.r" => %{}}},
        {"value -1", %{"_sys.r.seq" => -1}}
      ] do
    test "malformed SYS event (#{label}) -> {:invalid_sys_variables_event, id}, no raise" do
      {schema, instance_id} = started_instance!()
      event = sys_event!(schema, instance_id, unquote(Macro.escape(values)))
      event_id = event.event_id

      assert {:error, {:replay_failed, {:invalid_sys_variables_event, ^event_id}}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema)
    end
  end

  test "TASK_ENTITY_WRITES_APPLIED changes no state" do
    {schema, instance_id} = started_instance!()
    complete_t1!(schema, instance_id, %{"ok" => true})

    assert {:ok, %{instance_state: before}} =
             Reconstruction.reconstruct_instance(instance_id, prefix: schema)

    append!(schema, instance_id, "TASK_ENTITY_WRITES_APPLIED", %{
      "node_id" => "t1",
      "task_id" => Ecto.UUID.generate(),
      "dispatch_id" => nil,
      "lines_hash" => String.duplicate("0", 64),
      "lines" => [
        %{
          "line_index" => 0,
          "entity_type" => "invoice",
          "record_id" => Ecto.UUID.generate(),
          "event_global_seq" => 3
        }
      ]
    })

    assert {:ok, %{instance_state: after_applied, event_count: count}} =
             Reconstruction.reconstruct_instance(instance_id, prefix: schema)

    assert count == 3
    assert after_applied.variables == before.variables
    assert nodes(after_applied) == nodes(before)
    assert after_applied.status == before.status
    assert after_applied.pending_task_nodes |> Enum.map(& &1.node_id) == ["a"]
  end
end
