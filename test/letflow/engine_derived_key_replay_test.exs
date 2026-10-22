defmodule Letflow.EngineDerivedKeyReplayTest do
  @moduledoc """
  GH #2577 (D-1, D-2) -- a command whose idempotency key is already claimed by ANOTHER request
  answers a typed error and writes nothing: no second projection change, no second event, no raw
  event in the answer (INV-4/5), no raise (INV-8).

  The claim is made with a real event of another instance, so the command's own append is the
  duplicate. A same-task retry of complete_task is not a replay: fetch_and_lock_task answers
  `task_not_pending` first (see the last test).

  Real Postgres, Sandbox `:auto`, `async: false`, one provisioned tenant per test.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "gh2577d",
      display_name: "GH-2577 Derived Keys"
    )
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
                 name: unique("gh2577d-def"),
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

  defp start!(schema, definition) do
    assert {:ok, created} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("start")
               },
               prefix: schema
             )

    created.instance_id
  end

  defp pending_task!(schema, instance_id) do
    EngineTask
    |> where([t], t.instance_id == ^instance_id and t.status == :pending)
    |> Repo.one!(prefix: schema)
  end

  defp events_of(schema, instance_id, type) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == ^type)
    |> Repo.all(prefix: schema)
  end

  defp projection(schema, instance_id),
    do: Repo.get_by!(InstanceProjection, [instance_id: instance_id], prefix: schema)

  # Claims `key` for `instance_id` with a real EXECUTION_ERROR (the first claimant).
  defp claim_with_execution_error!(schema, instance_id, key) do
    assert {:ok, _} =
             Engine.set_instance_error(
               %{
                 instance_id: instance_id,
                 error_type: :variable_schema_rejected,
                 affected: {:field, "approved"},
                 reason: "rejected",
                 variables: %{},
                 details: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: key
               },
               prefix: schema
             )
  end

  describe "set_instance_error (row 10: EXECUTION_ERROR, D-2)" do
    test "a key claimed by another instance answers idempotency_key_reuse and writes nothing" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      claimant = start!(schema, definition)
      target = start!(schema, definition)
      key = unique("xe-claimed")

      claim_with_execution_error!(schema, claimant, key)

      projection_before = projection(schema, target)

      assert {:error, :idempotency_key_reuse} =
               Engine.set_instance_error(
                 %{
                   instance_id: target,
                   error_type: :variable_schema_rejected,
                   affected: {:field, "approved"},
                   reason: "rejected",
                   variables: %{},
                   details: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: key
                 },
                 prefix: schema
               )

      # the target is not flipped to ERROR, has no EXECUTION_ERROR and no second DLQ-style write
      assert projection(schema, target) == projection_before
      assert projection(schema, target).status == :active
      assert events_of(schema, target, "EXECUTION_ERROR") == []

      # the claimant keeps its single event
      assert [_one] = events_of(schema, claimant, "EXECUTION_ERROR")
    end
  end

  describe "complete_task (row 7: TASK_COMPLETED, D-1, AC 6)" do
    test "a key claimed by another request answers idempotency_key_reuse and changes nothing" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      claimant = start!(schema, definition)
      target = start!(schema, definition)
      key = unique("complete-claimed")

      claim_with_execution_error!(schema, claimant, key)

      task = pending_task!(schema, target)
      projection_before = projection(schema, target)

      assert {:error, :idempotency_key_reuse} =
               Engine.complete_task(
                 task.id,
                 %{output_variables: %{}, actor_id: Ecto.UUID.generate(), idempotency_key: key},
                 prefix: schema
               )

      assert pending_task!(schema, target).id == task.id
      assert projection(schema, target) == projection_before
      assert events_of(schema, target, "TASK_COMPLETED") == []
    end

    test "a same-task retry with the same key stays task_not_pending (D-1, owner decision)" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema)
      instance_id = start!(schema, definition)
      task = pending_task!(schema, instance_id)
      key = unique("complete-once")
      attrs = %{output_variables: %{}, actor_id: Ecto.UUID.generate(), idempotency_key: key}

      assert {:ok, _} = Engine.complete_task(task.id, attrs, prefix: schema)

      assert {:error, {:task_not_pending, :completed}} =
               Engine.complete_task(task.id, attrs, prefix: schema)

      assert [_one] = events_of(schema, instance_id, "TASK_COMPLETED")
    end
  end
end
