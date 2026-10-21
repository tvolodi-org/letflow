defmodule Letflow.EngineIdempotentReplayTest do
  @moduledoc """
  GH #2577 -- a same-key replay of instance start, cancel and rebind answers the original
  result and writes no second projection row, snapshot, event or side effect. A key claimed by a
  different request answers `{:error, :idempotency_key_reuse}` (GH #2543's binding rule).

  Red proof for the start replay: before the change the second `Engine.create/2` with the same
  key failed with `{:error, {:transaction_failed, %DBConnection.ConnectionError{}}}` (the nested
  `EventStore.append/2` transaction aborts the engine's transaction on a duplicate key) and left
  an orphan `InstanceDefinitionSnapshot` row.

  Real Postgres, Sandbox `:auto`, `async: false`, one provisioned tenant per test (same pattern
  as `engine_cancel_instance_test.exs`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Engine
  alias Letflow.Engine.PinRebind
  alias Letflow.Engine.PinResolver.Lookup
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(slug_prefix: "gh2577", display_name: "GH-2577 Test Tenant")
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
                 name: unique("gh2577-def"),
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

  defp v1_pin_lookup do
    %Lookup{
      catalog_lookup: fn _ref -> {:error, :not_found} end,
      module_lookup: fn _ref -> {:error, :not_found} end,
      variable_schema_lookup: fn _tenant_id, _process_key ->
        {:ok, %{version: "v1", json_schema: nil}}
      end
    }
  end

  defp start_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{"amount" => 10, "note" => "x"},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique("start"),
        pin_lookup: v1_pin_lookup(),
        pin_overrides: [%{kind: :variable_schema, ref: definition.name, version: "v1"}]
      },
      overrides
    )
  end

  defp count(schema, queryable), do: Repo.aggregate(queryable, :count, prefix: schema)

  defp events_of(schema, instance_id, type) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == ^type)
    |> Repo.all(prefix: schema)
  end

  defp started_events(schema),
    do: Event |> where([e], e.event_type == "INSTANCE_STARTED") |> Repo.all(prefix: schema)

  defp projection(schema, instance_id),
    do: Repo.get_by!(InstanceProjection, [instance_id: instance_id], prefix: schema)

  # For every state change of the instance exactly one event exists, the sequence is
  # contiguous, and the log alone reproduces the projection.
  defp assert_projection_matches_events(schema, instance_id) do
    events = Event |> where([e], e.instance_id == ^instance_id) |> Repo.all(prefix: schema)

    assert events |> Enum.map(& &1.sequence_number) |> Enum.sort() ==
             Enum.to_list(1..length(events))

    proj = projection(schema, instance_id)
    assert proj.last_event_seq == length(events)

    # The replay engine does not fold INSTANCE_PINS_REBOUND (the pin fold reads it separately).
    unless Enum.any?(events, &(&1.event_type == "INSTANCE_PINS_REBOUND")) do
      assert {:ok, %{instance_state: state}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema)

      assert state.status == proj.status
      assert state.variables == proj.variables

      if proj.status == :active do
        assert Enum.sort(Enum.map(state.tokens, & &1.node_id)) == Enum.sort(proj.current_nodes)
      end
    end

    types = Enum.map(events, & &1.event_type)

    assert Enum.count(types, &(&1 == "INSTANCE_STARTED")) == 1

    assert Enum.count(types, &(&1 == "INSTANCE_CANCELLED")) ==
             if(proj.status == :cancelled, do: 1, else: 0)

    events
  end

  describe "start" do
    test "a same-key replay returns the original instance and writes nothing" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      attrs = start_attrs(definition)

      assert {:ok, first} = Engine.create(attrs, prefix: schema)
      refute Map.has_key?(first, :replayed)

      projections = count(schema, InstanceProjection)
      snapshots = count(schema, InstanceDefinitionSnapshot)
      events = length(started_events(schema))

      # red proof: this was {:error, {:transaction_failed, %DBConnection.ConnectionError{}}}
      assert {:ok, replay} = Engine.create(attrs, prefix: schema)
      assert replay.instance_id == first.instance_id
      assert replay.definition_id == first.definition_id
      assert replay.started_at == first.started_at
      assert replay.variables == first.variables
      assert replay.current_nodes == first.current_nodes
      assert replay.status == :active
      assert replay.replayed == true

      assert count(schema, InstanceProjection) == projections
      assert count(schema, InstanceDefinitionSnapshot) == snapshots
      assert length(started_events(schema)) == events
      assert count(schema, EngineTask) == 1
      assert_projection_matches_events(schema, first.instance_id)
    end

    test "a replay by definition_name answers the original too" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)

      attrs =
        definition
        |> start_attrs()
        |> Map.delete(:definition_id)
        |> Map.put(:definition_name, definition.name)

      assert {:ok, first} = Engine.create(attrs, prefix: schema)
      assert {:ok, %{instance_id: id, replayed: true}} = Engine.create(attrs, prefix: schema)
      assert id == first.instance_id
    end

    test "a different key creates a new instance with its own event" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      attrs = start_attrs(definition)

      assert {:ok, first} = Engine.create(attrs, prefix: schema)
      other = %{attrs | idempotency_key: unique("start")}
      assert {:ok, second} = Engine.create(other, prefix: schema)

      refute second.instance_id == first.instance_id
      assert count(schema, InstanceProjection) == 2
      assert length(started_events(schema)) == 2
    end

    test "the same key with a different request is idempotency_key_reuse and writes nothing" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      other_definition = active_definition!(schema)
      attrs = start_attrs(definition)
      assert {:ok, _first} = Engine.create(attrs, prefix: schema)

      projections = count(schema, InstanceProjection)
      snapshots = count(schema, InstanceDefinitionSnapshot)

      for changed <- [
            %{initial_variables: %{"amount" => 11, "note" => "x"}},
            %{definition_id: other_definition.id},
            %{correlation_key: "other-correlation"},
            %{actor_id: Ecto.UUID.generate()}
          ] do
        assert {:error, :idempotency_key_reuse} =
                 Engine.create(Map.merge(attrs, changed), prefix: schema)
      end

      assert count(schema, InstanceProjection) == projections
      assert count(schema, InstanceDefinitionSnapshot) == snapshots
      assert length(started_events(schema)) == 1
    end

    test "a key claimed by another event type is idempotency_key_reuse" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      attrs = start_attrs(definition)
      assert {:ok, instance} = Engine.create(attrs, prefix: schema)

      key = unique("rebind")

      assert {:ok, _} =
               PinRebind.rebind_pins(
                 instance.instance_id,
                 %{
                   entries: [%{kind: :variable_schema, ref: definition.name, version: "v1"}],
                   reason: "r",
                   actor_id: attrs.actor_id,
                   idempotency_key: key
                 },
                 prefix: schema
               )

      assert {:error, :idempotency_key_reuse} =
               Engine.create(%{attrs | idempotency_key: key}, prefix: schema)
    end

    test "tenant B replaying tenant A's key starts a fresh instance in B (INV-1)" do
      %{schema_name: schema_a} = provisioned_tenant()
      %{schema_name: schema_b} = provisioned_tenant()
      definition_a = active_definition!(schema_a)
      definition_b = active_definition!(schema_b)
      key = unique("shared")

      assert {:ok, a} =
               Engine.create(start_attrs(definition_a, %{idempotency_key: key}), prefix: schema_a)

      assert {:ok, b} =
               Engine.create(start_attrs(definition_b, %{idempotency_key: key}), prefix: schema_b)

      refute b.instance_id == a.instance_id
      refute Map.has_key?(b, :replayed)
      assert count(schema_a, InstanceProjection) == 1
      assert count(schema_b, InstanceProjection) == 1
    end
  end

  describe "cancel" do
    defp cancel_attrs(actor_id, key \\ nil),
      do: %{actor_id: actor_id, idempotency_key: key || unique("cancel")}

    test "a same-key replay returns the original result and writes nothing" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      assert {:ok, instance} = Engine.create(start_attrs(definition), prefix: schema)
      id = instance.instance_id
      attrs = cancel_attrs(Ecto.UUID.generate())

      assert {:ok, first} = Engine.cancel_instance(id, attrs, prefix: schema)
      refute Map.has_key?(first, :replayed)
      assert length(first.cancelled_task_ids) == 1
      before = projection(schema, id)

      assert {:ok, replay} = Engine.cancel_instance(id, attrs, prefix: schema)
      assert replay.replayed == true
      assert replay.status == :cancelled
      assert replay.cancelled_task_ids == first.cancelled_task_ids
      assert replay.cancelled_at == first.cancelled_at

      assert projection(schema, id) == before
      assert [_one] = events_of(schema, id, "INSTANCE_CANCELLED")
      assert_projection_matches_events(schema, id)
    end

    test "a different key on an already cancelled instance keeps the terminal conflict" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      assert {:ok, instance} = Engine.create(start_attrs(definition), prefix: schema)
      id = instance.instance_id
      actor = Ecto.UUID.generate()

      assert {:ok, _} = Engine.cancel_instance(id, cancel_attrs(actor), prefix: schema)

      assert {:error, {:instance_already_terminal, :cancelled}} =
               Engine.cancel_instance(id, cancel_attrs(actor), prefix: schema)

      assert [_one] = events_of(schema, id, "INSTANCE_CANCELLED")
    end

    test "a key claimed by another event, another actor or another instance is idempotency_key_reuse" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      assert {:ok, instance} = Engine.create(start_attrs(definition), prefix: schema)
      assert {:ok, other} = Engine.create(start_attrs(definition), prefix: schema)
      id = instance.instance_id
      actor = Ecto.UUID.generate()

      # claimed by an INSTANCE_PINS_REBOUND of the same instance
      rebind_key = unique("rebind")

      assert {:ok, _} =
               PinRebind.rebind_pins(
                 id,
                 %{
                   entries: [%{kind: :variable_schema, ref: definition.name, version: "v1"}],
                   reason: "r",
                   actor_id: actor,
                   idempotency_key: rebind_key
                 },
                 prefix: schema
               )

      assert {:error, :idempotency_key_reuse} =
               Engine.cancel_instance(id, cancel_attrs(actor, rebind_key), prefix: schema)

      # claimed by this actor's cancel of ANOTHER instance
      key = unique("cancel")

      assert {:ok, _} =
               Engine.cancel_instance(other.instance_id, cancel_attrs(actor, key), prefix: schema)

      assert {:error, :idempotency_key_reuse} =
               Engine.cancel_instance(id, cancel_attrs(actor, key), prefix: schema)

      # claimed by another actor's cancel of the same instance
      assert {:error, :idempotency_key_reuse} =
               Engine.cancel_instance(
                 other.instance_id,
                 cancel_attrs(Ecto.UUID.generate(), key),
                 prefix: schema
               )

      proj = projection(schema, id)
      assert proj.status == :active
      assert events_of(schema, id, "INSTANCE_CANCELLED") == []

      assert [%{status: :pending}] =
               Repo.all(from(t in EngineTask, where: t.instance_id == ^id), prefix: schema)
    end
  end

  describe "rebind" do
    defp rebind_attrs(definition, version, overrides \\ %{}) do
      Map.merge(
        %{
          entries: [%{kind: :variable_schema, ref: definition.name, version: version}],
          reason: "bump",
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("rebind")
        },
        overrides
      )
    end

    test "a same-key replay returns the original result and writes nothing" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      assert {:ok, instance} = Engine.create(start_attrs(definition), prefix: schema)
      id = instance.instance_id
      attrs = rebind_attrs(definition, "v2")

      assert {:ok, first} = PinRebind.rebind_pins(id, attrs, prefix: schema)
      assert [%{prior_version: "v1", new_version: "v2"}] = first.changed
      refute Map.has_key?(first, :replayed)
      before = projection(schema, id)

      assert {:ok, replay} = PinRebind.rebind_pins(id, attrs, prefix: schema)
      assert replay.replayed == true
      assert replay.changed == first.changed
      assert replay.instance_id == id
      assert [event] = events_of(schema, id, "INSTANCE_PINS_REBOUND")
      assert replay.rebound_at == event.created_at

      assert projection(schema, id) == before
      assert_projection_matches_events(schema, id)
    end

    test "a different key with a new version appends a second event" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      assert {:ok, instance} = Engine.create(start_attrs(definition), prefix: schema)
      id = instance.instance_id

      assert {:ok, _} = PinRebind.rebind_pins(id, rebind_attrs(definition, "v2"), prefix: schema)

      assert {:ok, second} =
               PinRebind.rebind_pins(id, rebind_attrs(definition, "v3"), prefix: schema)

      refute Map.has_key?(second, :replayed)
      assert [%{prior_version: "v2", new_version: "v3"}] = second.changed
      assert length(events_of(schema, id, "INSTANCE_PINS_REBOUND")) == 2
    end

    test "a replay still answers after the instance was cancelled" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      assert {:ok, instance} = Engine.create(start_attrs(definition), prefix: schema)
      id = instance.instance_id
      attrs = rebind_attrs(definition, "v2")

      assert {:ok, first} = PinRebind.rebind_pins(id, attrs, prefix: schema)

      assert {:ok, _} =
               Engine.cancel_instance(id, cancel_attrs(Ecto.UUID.generate()), prefix: schema)

      assert {:ok, replay} = PinRebind.rebind_pins(id, attrs, prefix: schema)
      assert replay.changed == first.changed
      assert length(events_of(schema, id, "INSTANCE_PINS_REBOUND")) == 1
    end

    test "the same key with another reason, actor, version or event type is idempotency_key_reuse" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      assert {:ok, instance} = Engine.create(start_attrs(definition), prefix: schema)
      id = instance.instance_id
      attrs = rebind_attrs(definition, "v2")
      assert {:ok, _} = PinRebind.rebind_pins(id, attrs, prefix: schema)

      for changed <- [
            %{reason: "another reason"},
            %{actor_id: Ecto.UUID.generate()},
            %{entries: [%{kind: :variable_schema, ref: definition.name, version: "v3"}]}
          ] do
        assert {:error, :idempotency_key_reuse} =
                 PinRebind.rebind_pins(id, Map.merge(attrs, changed), prefix: schema)
      end

      # a key claimed by the instance's own cancel
      cancel_key = unique("cancel")

      other_attrs =
        rebind_attrs(definition, "v3", %{idempotency_key: cancel_key, actor_id: attrs.actor_id})

      assert {:ok, other} = Engine.create(start_attrs(definition), prefix: schema)

      assert {:ok, _} =
               Engine.cancel_instance(other.instance_id, cancel_attrs(attrs.actor_id, cancel_key),
                 prefix: schema
               )

      assert {:error, :idempotency_key_reuse} =
               PinRebind.rebind_pins(id, other_attrs, prefix: schema)

      assert length(events_of(schema, id, "INSTANCE_PINS_REBOUND")) == 1
    end
  end
end
