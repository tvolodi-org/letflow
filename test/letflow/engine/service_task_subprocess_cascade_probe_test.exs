defmodule Letflow.Engine.ServiceTaskSubprocessCascadeProbeTest do
  @moduledoc """
  GH #2587 / REQ-499 PR C, OQ-C8 prerequisite (design `gh2587-req499-pr-c-service-task-writes.md`
  section 15 and F-C10): a RUNNING probe of the current behaviour of the sub-process completion
  cascade on the SERVICE_TASK apply path.

  Question: a child instance whose LAST node is a SERVICE_TASK is applied through
  `Engine.advance_after_service_task_outcome/4`. The child completes. Does the parent's token,
  waiting at its `SUB_PROCESS` node, wake?

  Observed (this test pins it, so a future fix is a visible diff): it does NOT. The child
  projection becomes `:completed`, but the parent stays `:active` at the `SUB_PROCESS` node, no
  `SUB_PROCESS_COMPLETED` event is appended on the parent, and the parent's human task after the
  sub-process is never created. The cascade (`append_sub_process_completion_cascade_multi/6`) is
  composed in the HUMAN_TASK completion tail only; `do_persist_service_task_advance/10` has no
  call to it. This is PRE-EXISTING and not caused by PR C (an ISS is filed separately by the
  orchestrator; PR C does not fix it). PR C relies on it only in design section 7.3, where the
  service apply is never the cascade initiator.

  Real Postgres, `async: false`. No HTTP: the poller's re-entry (mark `advanced` +
  `advance_after_service_task_outcome/4`) is performed by the test, as
  `sub_process_service_task_after_test.exs` does.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.TenantFixture

  setup do
    Sandbox.mode(Repo, :auto)
    :ok
  end

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp create_active!(schema, name, graph) do
    assert {:ok, definition} =
             Definitions.create(
               %{name: name, version: "1.0", graph: graph, created_by: Ecto.UUID.generate()},
               prefix: schema
             )

    assert {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)
    active
  end

  # START -> HUMAN_TASK "ct" -> SERVICE_TASK "svc" (the child's LAST node) -> END. The human
  # task comes first because a child created by a SUB_PROCESS node arms no dispatch row for a
  # SERVICE_TASK directly after START; completing "ct" arms it through the completion hop chain.
  defp child_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ct", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "role-x"}},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "endpoint" => "https://example.test/child",
            "method" => "POST",
            "timeout_ms" => 300_000
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "c0", "source" => "start", "target" => "ct"},
        %{"id" => "c1", "source" => "ct", "target" => "svc"},
        %{"id" => "c2", "source" => "svc", "target" => "end"}
      ]
    }
  end

  # START -> SUB_PROCESS(child) -> HUMAN_TASK "after" -> END
  defp parent_graph(child_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sub",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        %{"id" => "after", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "role-x"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "p0", "source" => "start", "target" => "sub"},
        %{"id" => "p1", "source" => "sub", "target" => "after"},
        %{"id" => "p2", "source" => "after", "target" => "end"}
      ]
    }
  end

  test "OQ-C8: applying the child's last SERVICE_TASK completes the child but does NOT wake the parent token" do
    schema = TenantFixture.provisioned_tenant!(slug_prefix: "gh2587c-probe").schema_name
    child_name = unique("c8-child")
    create_active!(schema, child_name, child_graph())
    parent = create_active!(schema, unique("c8-parent"), parent_graph(child_name))

    assert {:ok, %{instance_id: parent_id}} =
             Engine.create(
               %{
                 definition_id: parent.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("c8-start")
               },
               prefix: schema
             )

    assert [child_id] =
             InstanceProjection
             |> where([p], p.parent_instance_id == ^parent_id)
             |> select([p], p.instance_id)
             |> Repo.all(prefix: schema)

    assert [child_task] =
             EngineTask
             |> where([t], t.instance_id == ^child_id and t.status == :pending)
             |> Repo.all(prefix: schema)

    assert {:ok, _} =
             Engine.complete_task(
               child_task.id,
               %{
                 output_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("c8-complete")
               },
               prefix: schema
             )

    assert [row] =
             ServiceTaskDispatch
             |> where([d], d.instance_id == ^child_id)
             |> Repo.all(prefix: schema)

    # attempt_dispatch/2's precondition (status "advanced"), without the HTTP call
    advanced = row |> Ecto.Changeset.change(%{status: "advanced"}) |> Repo.update!(prefix: schema)

    assert {:ok, :advanced} =
             Engine.advance_after_service_task_outcome(advanced.id, {:advance, %{}}, Repo, schema)

    # the child completed ...
    assert Repo.get!(InstanceProjection, child_id, prefix: schema).status == :completed

    # ... and the parent did not wake: still active at the SUB_PROCESS node, no completion
    # event on the parent, and the parent's following human task was never created.
    parent_projection = Repo.get!(InstanceProjection, parent_id, prefix: schema)
    assert parent_projection.status == :active
    assert parent_projection.current_nodes == ["sub"]

    assert {:ok, events} = Reconstruction.read_full_log(parent_id, schema, 1)
    refute "SUB_PROCESS_COMPLETED" in Enum.map(events, & &1.event_type)

    assert [] =
             EngineTask
             |> where([t], t.instance_id == ^parent_id)
             |> Repo.all(prefix: schema)
  end
end
