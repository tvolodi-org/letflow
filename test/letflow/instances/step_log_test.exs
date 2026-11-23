defmodule Letflow.Instances.StepLogTest do
  @moduledoc """
  The STEP LOG of one instance (pilot gap G6 of the "Register a tenant" pilot).

  The log is derived from what the engine already writes -- the instance's own
  events and the dispatch rows of the automatic steps -- so these tests build
  those two sources directly and read the log back:

    * a human task visit is ONE step: who ran it, when it started and ended,
      how it ended, how long it took and how many attempts it took;
    * a pass-through node (a gateway) is closed by the NEXT node visit, because
      the token leaves it as soon as it arrives;
    * a failed step is closed by the EXECUTION_ERROR and names the failure
      kind of its dispatch row;
    * a cancelled instance closes every open step as `cancelled`;
    * a step that is still open is `running`;
    * a platform step names the FUNCTION it ran and takes its attempts and its
      failure kind from its own dispatch row.

  `async: false`: the tenant fixture provisions a schema and replays the
  tenant migrations.
  """

  use Letflow.DataCase, async: false

  alias Letflow.EventStore.Event
  alias Letflow.Instances.StepLog
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @t0 ~U[2026-11-23 10:00:00.000000Z]

  setup do
    %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "g6-steplog")}
  end

  test "a human task visit is one step: who, when, result, duration, attempts", %{tenant: tenant} do
    instance_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()

    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{
        "node_id" => "ht",
        "node_type" => "HUMAN_TASK",
        "via_edge_id" => "e1"
      },
      user_id,
      @t0,
      1
    )

    insert_event!(
      tenant.schema_name,
      instance_id,
      "TASK_COMPLETED",
      %{
        "node_id" => "ht",
        "task_id" => "task-1"
      },
      user_id,
      DateTime.add(@t0, 1500, :millisecond),
      2
    )

    assert {:ok, [step]} = StepLog.steps(instance_id, prefix: tenant.schema_name)

    assert step.node_id == "ht"
    assert step.node_type == "HUMAN_TASK"
    assert step.result == "completed"
    assert step.actor_id == user_id
    assert step.started_at == @t0
    assert step.ended_at == DateTime.add(@t0, 1500, :millisecond)
    assert step.duration_ms == 1500
    assert step.attempts == 1
    assert step.last_failure_kind == nil
  end

  test "a pass-through node is closed by the next node visit", %{tenant: tenant} do
    instance_id = Ecto.UUID.generate()

    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{
        "node_id" => "g1",
        "node_type" => "EXCLUSIVE_GATEWAY",
        "via_edge_id" => "e1"
      },
      nil,
      @t0,
      1
    )

    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{
        "node_id" => "ht",
        "node_type" => "HUMAN_TASK",
        "via_edge_id" => "e2"
      },
      nil,
      DateTime.add(@t0, 10, :millisecond),
      2
    )

    assert {:ok, [gateway, task]} = StepLog.steps(instance_id, prefix: tenant.schema_name)

    assert gateway.node_id == "g1"
    assert gateway.result == "completed"
    assert gateway.duration_ms == 10

    # The human task is still open: no completion event closed it.
    assert task.node_id == "ht"
    assert task.result == "running"
    assert task.ended_at == nil
    assert task.duration_ms == nil
  end

  test "a failed step is closed by the EXECUTION_ERROR", %{tenant: tenant} do
    instance_id = Ecto.UUID.generate()

    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{
        "node_id" => "svc",
        "node_type" => "SERVICE_TASK",
        "via_edge_id" => "e1"
      },
      nil,
      @t0,
      1
    )

    # The payload the ENGINE writes (`Letflow.Engine.ExecutionError`): the
    # affected resource is under `affected`, never a top-level `node_id`.
    insert_event!(
      tenant.schema_name,
      instance_id,
      "EXECUTION_ERROR",
      %{
        "error_type" => "service_task_failed",
        "affected" => %{"kind" => "node", "node_id" => "svc"},
        "reason" => "retries exhausted after 3 attempts",
        "variables" => %{},
        "details" => %{}
      },
      nil,
      DateTime.add(@t0, 300, :millisecond),
      2
    )

    assert {:ok, [step]} = StepLog.steps(instance_id, prefix: tenant.schema_name)

    assert step.node_id == "svc"
    assert step.result == "failed"
    assert step.duration_ms == 300
  end

  test "an error that names a node closes THAT visit, not the oldest open one", %{tenant: tenant} do
    instance_id = Ecto.UUID.generate()

    # A parallel branch: the human task is still open when the service task
    # fails.
    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{"node_id" => "ht", "node_type" => "HUMAN_TASK", "via_edge_id" => "e1"},
      nil,
      @t0,
      1
    )

    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{"node_id" => "svc", "node_type" => "SERVICE_TASK", "via_edge_id" => "e2"},
      nil,
      DateTime.add(@t0, 10, :millisecond),
      2
    )

    insert_event!(
      tenant.schema_name,
      instance_id,
      "EXECUTION_ERROR",
      %{
        "error_type" => "service_task_failed",
        "affected" => %{"kind" => "node", "node_id" => "svc"},
        "reason" => "retries exhausted after 3 attempts",
        "variables" => %{},
        "details" => %{}
      },
      nil,
      DateTime.add(@t0, 300, :millisecond),
      3
    )

    assert {:ok, [human, service]} = StepLog.steps(instance_id, prefix: tenant.schema_name)

    # The node the error names is the failed one ...
    assert service.node_id == "svc"
    assert service.result == "failed"
    assert service.duration_ms == 290

    # ... and the other open visit is untouched.
    assert human.node_id == "ht"
    assert human.result == "running"
    assert human.ended_at == nil
    assert human.duration_ms == nil
  end

  test "an error that names no node closes the oldest open visit", %{tenant: tenant} do
    instance_id = Ecto.UUID.generate()

    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{"node_id" => "ht", "node_type" => "HUMAN_TASK", "via_edge_id" => "e1"},
      nil,
      @t0,
      1
    )

    # A FIELD error: the engine writes `{"kind": "field", "key": ...}` -- it
    # names no node, so the oldest open visit is the one that failed.
    insert_event!(
      tenant.schema_name,
      instance_id,
      "EXECUTION_ERROR",
      %{
        "error_type" => "variable_merge_rejected",
        "affected" => %{"kind" => "field", "key" => "amount"},
        "reason" => "the merged value was rejected",
        "variables" => %{},
        "details" => %{}
      },
      nil,
      DateTime.add(@t0, 400, :millisecond),
      2
    )

    assert {:ok, [step]} = StepLog.steps(instance_id, prefix: tenant.schema_name)

    assert step.node_id == "ht"
    assert step.result == "failed"
    assert step.duration_ms == 400
  end

  test "a sub-process step is closed by the SUB_PROCESS_COMPLETED of the parent", %{
    tenant: tenant
  } do
    instance_id = Ecto.UUID.generate()

    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{"node_id" => "sp", "node_type" => "SUB_PROCESS", "via_edge_id" => "e1"},
      nil,
      @t0,
      1
    )

    # The event the engine writes on the PARENT's stream: it names the
    # parent's own node (`node_id`), so the parent's visit closes.
    insert_event!(
      tenant.schema_name,
      instance_id,
      "SUB_PROCESS_COMPLETED",
      %{
        "node_id" => "sp",
        "child_instance_id" => Ecto.UUID.generate(),
        "output_variables" => %{},
        "merged_variable_events" => [],
        "activated_nodes" => []
      },
      nil,
      DateTime.add(@t0, 2500, :millisecond),
      2
    )

    assert {:ok, [step]} = StepLog.steps(instance_id, prefix: tenant.schema_name)

    assert step.node_id == "sp"
    assert step.node_type == "SUB_PROCESS"
    assert step.result == "completed"
    assert step.ended_at == DateTime.add(@t0, 2500, :millisecond)
    assert step.duration_ms == 2500
  end

  test "a cancelled instance closes every open step", %{tenant: tenant} do
    instance_id = Ecto.UUID.generate()

    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{
        "node_id" => "ht",
        "node_type" => "HUMAN_TASK",
        "via_edge_id" => "e1"
      },
      nil,
      @t0,
      1
    )

    insert_event!(
      tenant.schema_name,
      instance_id,
      "INSTANCE_CANCELLED",
      %{"reason" => "stopped"},
      nil,
      DateTime.add(@t0, 700, :millisecond),
      2
    )

    assert {:ok, [step]} = StepLog.steps(instance_id, prefix: tenant.schema_name)

    assert step.result == "cancelled"
    assert step.duration_ms == 700
  end

  test "a platform step names the function and takes its attempts and failure kind from its dispatch row",
       %{tenant: tenant} do
    instance_id = Ecto.UUID.generate()

    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{
        "node_id" => "call",
        "node_type" => "SERVICE_TASK",
        "via_edge_id" => "e1"
      },
      nil,
      @t0,
      1
    )

    insert_platform_dispatch!(tenant, instance_id, "call", "tenant.provision", %{
      attempt_index: 2,
      status: :given_up,
      last_failure_kind: "platform_call_tenant_not_found"
    })

    insert_event!(
      tenant.schema_name,
      instance_id,
      "EXECUTION_ERROR",
      %{
        "error_type" => "platform_call_failed",
        "affected" => %{"kind" => "node", "node_id" => "call"},
        "reason" => "the platform function gave up",
        "variables" => %{},
        "details" => %{}
      },
      nil,
      DateTime.add(@t0, 900, :millisecond),
      2
    )

    assert {:ok, [step]} = StepLog.steps(instance_id, prefix: tenant.schema_name)

    assert step.node_id == "call"
    assert step.node_type == "SERVICE_TASK"
    assert step.step == "tenant.provision"
    assert step.attempts == 2
    assert step.last_failure_kind == "platform_call_tenant_not_found"
    assert step.result == "failed"
  end

  test "a step with no dispatch row counts one attempt", %{tenant: tenant} do
    instance_id = Ecto.UUID.generate()

    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{
        "node_id" => "ht",
        "node_type" => "HUMAN_TASK",
        "via_edge_id" => "e1"
      },
      nil,
      @t0,
      1
    )

    assert {:ok, [step]} = StepLog.steps(instance_id, prefix: tenant.schema_name)
    assert step.attempts == 1
  end

  test "an instance with no events has an empty step log", %{tenant: tenant} do
    assert {:ok, []} = StepLog.steps(Ecto.UUID.generate(), prefix: tenant.schema_name)
  end

  defp insert_event!(schema, instance_id, event_type, payload, actor_id, at, sequence_number) do
    attrs = %{
      event_id: Ecto.UUID.generate(),
      instance_id: instance_id,
      event_type: event_type,
      payload: payload,
      metadata: %{},
      # An event row always names an actor: the platform sentinel is the
      # engine itself.
      actor_id: actor_id || Letflow.EventStore.platform_actor_id(),
      sequence_number: sequence_number,
      idempotency_key: "g6-#{System.unique_integer([:positive, :monotonic])}",
      created_at: at
    }

    {:ok, event} =
      %Event{}
      |> Event.insert_changeset(attrs)
      |> Repo.insert(prefix: schema)

    event
  end

  defp insert_platform_dispatch!(tenant, instance_id, node_id, function_name, overrides) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      instance_id: instance_id,
      definition_id: Ecto.UUID.generate(),
      node_id: node_id,
      function_name: function_name,
      call_key: "g6-#{System.unique_integer([:positive, :monotonic])}",
      input_fingerprint: "fingerprint",
      status: :pending,
      attempt_index: Map.get(overrides, :attempt_index, 0),
      next_attempt_at: now,
      created_at: now
    }

    {:ok, dispatch} =
      %StepDispatch{}
      |> StepDispatch.arm_changeset(attrs)
      |> Repo.insert(prefix: tenant.schema_name)

    case Map.get(overrides, :status) do
      nil ->
        dispatch

      status ->
        {:ok, dispatch} =
          dispatch
          |> StepDispatch.terminal_changeset(%{
            status: status,
            last_failure_kind: Map.get(overrides, :last_failure_kind),
            dispatched_at: now
          })
          |> Repo.update(prefix: tenant.schema_name)

        dispatch
    end
  end
end
