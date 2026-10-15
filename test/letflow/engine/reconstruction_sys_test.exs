defmodule Letflow.Engine.ReconstructionSysTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A1 (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  2.5, D-A1.10, D-A1.13, 11 A1 "engine-only writer + reconstruction"): replay of the two
  decision 0054 instance event types, through the REAL `Reconstruction.reconstruct_instance/2`
  over a REAL instance (`Engine.create/2`, `Engine.complete_task/3`).

  GH #2587 PR B2 (CO-2): the engine writer of `INSTANCE_SYS_VARIABLES_SET` is real, so the
  main case completes a HUMAN_TASK whose node declares `entity_writes` through
  `Engine.complete_task/3` (`Letflow.EntityWritesFixture`); the rebuilt state must equal the
  live projection, `_sys` values included, with the same token positions after a gateway
  evaluated on the completion. Raw-inserted events (`insert_raw_event!/4`) stay ONLY for
  malformed and wide-tier cases (GH #2621, CO-7). The "replay invokes no EntityPort write
  callback" case is in `complete_task_entity_writes_test.exs` (B-14).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
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

  # GH #2621 (design F1/F-A): inserts one `events` row directly, so neither EventStore.append/2
  # nor Registry.validate_payload/3 (and the strict append guard) is traversed: it stands for an
  # event stored BEFORE the guard existed. Explicit columns: event_id and created_at (the
  # composite primary key), instance_id, event_type, payload, actor_id, sequence_number (the
  # next value for the instance), idempotency_key, metadata. global_seq is assigned by the
  # database (read_after_writes). It does not touch event_idempotency or the projection.
  defp insert_raw_event!(schema, instance_id, type, payload) do
    max_seq =
      Repo.one!(
        from(e in Event, where: e.instance_id == ^instance_id, select: max(e.sequence_number)),
        prefix: schema
      )

    row = %{
      event_id: Ecto.UUID.generate(),
      created_at: DateTime.utc_now(),
      instance_id: instance_id,
      event_type: type,
      payload: payload,
      actor_id: Ecto.UUID.generate(),
      sequence_number: max_seq + 1,
      idempotency_key: uniq("gh2621-raw"),
      metadata: %{}
    }

    assert {1, _} = Repo.insert_all(Event, [row], prefix: schema)
    row
  end

  defp raw_sys_event!(schema, instance_id, values) do
    insert_raw_event!(schema, instance_id, "INSTANCE_SYS_VARIABLES_SET", %{
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

  test "real writer: the SYS event precedes TASK_COMPLETED; rebuilt variables equal the live ones; the gateway takes the live edge" do
    alias Letflow.EntityWritesFixture, as: Fx

    base = Fx.tenant_case!("gh2587-rc-b2")
    Fx.define_type!(base.schema, "stock_move", %{})

    lines = [
      Map.put(
        Fx.line("stock_move", %{"label" => %{"const" => "L"}}),
        "output_record_id_var",
        "_sys.r"
      )
    ]

    lines_graph =
      update_in(graph(), ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "t1"} = node -> put_in(node, ["attributes", "entity_writes"], lines)
          node -> node
        end)
      end)

    definition = Fx.activate!(base.schema, base.user, lines_graph)
    {instance_id, task} = Fx.start!(base.schema, definition)

    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: %{"ok" => true},
                 actor_id: base.user.id,
                 idempotency_key: uniq("c")
               },
               prefix: base.schema
             )

    schema = base.schema
    live = projection(schema, instance_id)
    assert live.current_nodes == ["a"]
    assert Map.has_key?(live.variables, "_sys.r")
    assert is_integer(live.variables["_sys.r.seq"])

    assert {:ok, %{instance_state: state}} =
             Reconstruction.reconstruct_instance(instance_id, prefix: schema)

    assert state.variables == live.variables
    assert nodes(state) == Enum.sort(live.current_nodes)
    assert state.status == live.status

    # D-A1.10 order: the SYS event precedes the step's completion event.
    {:ok, events} = EventStore.read(instance_id, prefix: schema)
    types = Enum.map(events, & &1.event_type)
    sys_index = Enum.find_index(types, &(&1 == "INSTANCE_SYS_VARIABLES_SET"))
    assert sys_index < Enum.find_index(types, &(&1 == "TASK_COMPLETED"))
    assert Enum.count(types, &(&1 == "TASK_ENTITY_WRITES_APPLIED")) == 1
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
      event = raw_sys_event!(schema, instance_id, unquote(Macro.escape(values)))
      event_id = event.event_id

      assert {:error, {:replay_failed, {:invalid_sys_variables_event, ^event_id}}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema)
    end
  end

  test "a stored pre-change event with wide values replays unchanged (GH #2621)" do
    {schema, instance_id} = started_instance!()
    values = %{"_sys.line_0.id" => "any string", "_sys.r.seq" => 3}
    raw_sys_event!(schema, instance_id, values)

    count = fn ->
      Repo.aggregate(from(e in Event, where: e.instance_id == ^instance_id), :count,
        prefix: schema
      )
    end

    before = count.()

    assert {:ok, %{instance_state: state}} =
             Reconstruction.reconstruct_instance(instance_id, prefix: schema)

    assert state.variables == %{"n" => 1, "_sys.line_0.id" => "any string", "_sys.r.seq" => 3}

    # CO-7: replay appends, repairs and rewrites nothing
    assert count.() == before
  end

  test "a stored 41-key v1 event replays unchanged: the append cap does not touch replay (GH #2621)" do
    {schema, instance_id} = started_instance!()

    values =
      Map.new(0..40, fn i -> {"_sys.k#{i}", Ecto.UUID.generate()} end)

    assert map_size(values) == 41
    raw_sys_event!(schema, instance_id, values)

    assert {:ok, %{instance_state: state}} =
             Reconstruction.reconstruct_instance(instance_id, prefix: schema)

    assert state.variables == Map.put(values, "n", 1)
  end

  test "the strict append guard refuses a wide-value event before it is stored (GH #2621)" do
    {schema, instance_id} = started_instance!()

    assert {:error, {:payload_validation_failed, [%{constraint: "sys_value_type"}]}} =
             EventStore.append(
               %{
                 instance_id: instance_id,
                 event_type: "INSTANCE_SYS_VARIABLES_SET",
                 payload:
                   Jason.encode!(%{
                     "node_id" => "t1",
                     "cause" => "entity_writes",
                     "values" => %{"_sys.r" => "not-a-uuid"}
                   }),
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: uniq("gh2621-refused")
               },
               prefix: schema
             )
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

  # GH #2627 (C0): an entity-record event stored BEFORE StepSource existed (flat 8-key
  # source.* metadata and its sys:step: key, hand-built literals; it lives on the entity
  # type's synthetic instance, which is never replayed) reads back byte-identical, the
  # process instance's replay is unchanged, and the new code derives exactly the stored
  # metadata and key from the same values.
  test "a legacy step event with flat source.* metadata reads back and replays unchanged" do
    {schema, instance_id} = started_instance!()
    complete_t1!(schema, instance_id, %{"ok" => true})

    assert {:ok, %{instance_state: before, event_count: count_before}} =
             Reconstruction.reconstruct_instance(instance_id, prefix: schema)

    task_id = "22222222-2222-4222-8222-222222222222"
    synthetic_instance = Ecto.UUID.generate()

    legacy_metadata = %{
      "source.kind" => "process_step",
      "source.instance_id" => instance_id,
      "source.task_id" => task_id,
      "source.node_id" => "t1",
      "source.definition_id" => "44444444-4444-4444-8444-444444444444",
      "source.definition_version" => "1.0.0",
      "source.line_index" => "3",
      "source.activator_id" => "55555555-5555-4555-8555-555555555555"
    }

    key = "sys:step:" <> task_id <> ":3"

    row = %{
      event_id: Ecto.UUID.generate(),
      created_at: DateTime.utc_now(),
      instance_id: synthetic_instance,
      event_type: "ENTITY_RECORD_CREATED",
      payload: %{"record_id" => Ecto.UUID.generate()},
      actor_id: Ecto.UUID.generate(),
      sequence_number: 1,
      idempotency_key: key,
      metadata: legacy_metadata
    }

    assert {1, _} = Repo.insert_all(Event, [row], prefix: schema)

    stored = Repo.one!(from(e in Event, where: e.event_id == ^row.event_id), prefix: schema)
    assert stored.metadata == legacy_metadata
    assert stored.idempotency_key == key

    # The process instance's replay is unchanged.
    assert {:ok, %{instance_state: after_legacy, event_count: ^count_before}} =
             Reconstruction.reconstruct_instance(instance_id, prefix: schema)

    assert after_legacy.variables == before.variables
    assert nodes(after_legacy) == nodes(before)
    assert after_legacy.status == before.status

    # The new code produces exactly the stored bytes from the same values.
    assert {:ok, source} =
             Letflow.Entities.StepSource.new(%{
               instance_id: instance_id,
               task_id: task_id,
               node_id: "t1",
               definition_id: "44444444-4444-4444-8444-444444444444",
               definition_version: "1.0.0",
               line_index: 3,
               activator_id: "55555555-5555-4555-8555-555555555555"
             })

    assert Letflow.Entities.StepSource.to_metadata(source) == stored.metadata
    assert Letflow.Entities.StepSource.idempotency_key(source) == stored.idempotency_key
  end
end
