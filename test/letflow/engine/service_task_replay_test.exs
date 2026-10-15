defmodule Letflow.Engine.ServiceTaskReplayTest do
  @moduledoc """
  GH #2595: `Letflow.Engine.Reconstruction` replays the HTTP SERVICE_TASK route's
  `SERVICE_TASK_COMPLETED` event (payload `%{dispatch_id, node_id, decoded_body}`) with the
  live `:advance` path's fold semantics -- `decoded_body` merged verbatim via
  `VariableMerge.merge/3`, then the token advances off the node. Before the fix every such
  instance failed replay with `{:unrecognized_event_type, "SERVICE_TASK_COMPLETED", _}`.

  The instance runs a real HTTP dispatch against `Letflow.WebhookTestServer`, the fixture
  pattern of `service_task_wiring_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.SnapshotWriter
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture
  alias Letflow.WebhookTestServer

  @body ~s({"approved":true,"limit":5000})

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # START -> SERVICE_TASK(inline_url) -> HUMAN_TASK -> END: the instance continues past the
  # service task to a later node, where it parks.
  defp graph(endpoint) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => endpoint, "timeout_ms" => 5_000}
        },
        %{"id" => "review", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "role-any"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "review"},
        %{"id" => "e3", "source" => "review", "target" => "end"}
      ]
    }
  end

  defp enable_ssrf_bypass do
    Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
    on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)
  end

  # Starts an instance parked at "svc" with a pending dispatch row (no HTTP call yet).
  defp start_parked_instance! do
    enable_ssrf_bypass()
    %{url: server_url} = WebhookTestServer.start(200, @body)

    %{schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "gh2595-replay",
        display_name: "GH 2595 Service Task Replay Tenant"
      )

    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_name("gh2595-def"),
                 version: "1.0.0",
                 graph: graph(server_url),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    assert {:ok, created} =
             Engine.create(
               %{
                 definition_id: activated.id,
                 initial_variables: %{"applicant" => "a-1"},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_name("gh2595-start")
               },
               prefix: schema_name
             )

    %{schema_name: schema_name, instance_id: created.instance_id}
  end

  # The live HTTP :advance path, called exactly as ServiceTaskDispatcher.poll_and_dispatch/1
  # calls it.
  defp run_dispatch!(schema_name, instance_id) do
    [dispatch] =
      ServiceTaskDispatch
      |> where([d], d.instance_id == ^instance_id)
      |> Repo.all(prefix: schema_name)

    assert {:ok, {:advance, decoded_body}} =
             ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

    assert {:ok, :advanced} =
             Engine.advance_after_service_task_outcome(
               dispatch.id,
               {:advance, decoded_body},
               Repo,
               schema_name
             )
  end

  defp live_state(schema_name, instance_id) do
    projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)

    tokens =
      TokenRecord
      |> where([t], t.instance_id == ^instance_id and t.status == :active)
      |> Repo.all(prefix: schema_name)
      |> Enum.map(&{&1.node_id, &1.branch_id})
      |> Enum.sort()

    pending_task_nodes =
      EngineTask
      |> where([t], t.instance_id == ^instance_id and t.status == :pending)
      |> Repo.all(prefix: schema_name)
      |> Enum.map(& &1.node_id)
      |> Enum.sort()

    %{
      status: projection.status,
      current_nodes: Enum.sort(projection.current_nodes),
      variables: projection.variables,
      tokens: tokens,
      pending_task_nodes: pending_task_nodes
    }
  end

  defp replayed_state(state) do
    %{
      status: state.status,
      current_nodes: state.tokens |> Enum.map(& &1.node_id) |> Enum.sort(),
      variables: state.variables,
      tokens: state.tokens |> Enum.map(&{&1.node_id, &1.branch_id}) |> Enum.sort(),
      pending_task_nodes: state.pending_task_nodes |> Enum.map(& &1.node_id) |> Enum.sort()
    }
  end

  defp service_task_completed_event!(schema_name, instance_id) do
    [event] =
      Event
      |> where([e], e.instance_id == ^instance_id and e.event_type == "SERVICE_TASK_COMPLETED")
      |> Repo.all(prefix: schema_name)

    event
  end

  describe "SERVICE_TASK_COMPLETED replay (GH 2595)" do
    test "an instance past an HTTP service task reconstructs equal to its live state, then again after it continues" do
      %{schema_name: schema_name, instance_id: instance_id} = start_parked_instance!()
      run_dispatch!(schema_name, instance_id)

      live = live_state(schema_name, instance_id)
      assert live.status == :active
      assert live.current_nodes == ["review"]

      assert live.variables == %{"applicant" => "a-1", "approved" => true, "limit" => 5000}

      assert {:ok, %{instance_state: state}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      assert replayed_state(state) == live
      assert state.pending_service_task_nodes == []

      # Continue to a later node: completing the human task replays TASK_COMPLETED on top of
      # the replayed SERVICE_TASK_COMPLETED.
      [task] =
        EngineTask
        |> where([t], t.instance_id == ^instance_id and t.status == :pending)
        |> Repo.all(prefix: schema_name)

      assert {:ok, _} =
               Engine.complete_task(
                 task.id,
                 %{
                   output_variables: %{"decision" => "ok"},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_name("gh2595-complete")
                 },
                 prefix: schema_name
               )

      live_after = live_state(schema_name, instance_id)
      assert live_after.status == :completed

      assert {:ok, %{instance_state: state_after}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      assert replayed_state(state_after) == live_after
    end

    test "incremental replay from a state snapshot taken before SERVICE_TASK_COMPLETED equals full replay" do
      %{schema_name: schema_name, instance_id: instance_id} = start_parked_instance!()

      # The pre-dispatch state, snapshotted as of the last event before the dispatch outcome.
      assert {:ok, %{instance_state: parked_state, last_sequence_number: parked_seq}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      assert Enum.map(parked_state.tokens, & &1.node_id) == ["svc"]

      run_dispatch!(schema_name, instance_id)
      event = service_task_completed_event!(schema_name, instance_id)
      assert event.sequence_number > parked_seq

      assert {:ok, %{instance_state: full_state, event_count: full_count}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      assert {:ok, _snapshot_id} =
               SnapshotWriter.take_snapshot(instance_id, parked_state, parked_seq,
                 prefix: schema_name
               )

      assert {:ok, %{instance_state: incremental_state, event_count: incremental_count}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      # The snapshot path folded only the events after the snapshot, the
      # SERVICE_TASK_COMPLETED event among them.
      assert incremental_count < full_count
      assert replayed_state(incremental_state) == replayed_state(full_state)
      assert replayed_state(full_state) == live_state(schema_name, instance_id)
    end

    test "a SERVICE_TASK_COMPLETED payload missing node_id is the malformed-payload replay error" do
      %{schema_name: schema_name, instance_id: instance_id} = start_parked_instance!()
      run_dispatch!(schema_name, instance_id)

      event = service_task_completed_event!(schema_name, instance_id)
      event_id = event.event_id

      # The write side validates the payload against the seeded json_schema (node_id is
      # required), so a malformed row can only come from corrupted storage.
      {1, _} =
        Repo.update_all(
          from(e in Event, where: e.event_id == ^event_id),
          [set: [payload: Map.delete(event.payload, "node_id")]],
          prefix: schema_name
        )

      assert {:error, {:replay_failed, {:malformed_payload, ^event_id, {"node_id", nil}}}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)
    end
  end
end
