defmodule Letflow.EngineCancelInstanceTest do
  @moduledoc """
  Tests for REQ-052's `Letflow.Engine.cancel_instance/3` (EE-08 — instance cancellation).
  See `test/specs/REQ-052.md` for the full test-case rationale and AC traceability.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. Self-contained: does not share
  fixtures with `engine_test.exs`/`engine_complete_task_test.exs`, matching those files' own
  "no test pollution" discipline -- each test file provisions its own tenant schema.

  Mirrors `engine_complete_task_test.exs`'s own `provisioned_tenant/0` + Sandbox `:auto` +
  `async: false` pattern exactly, registering BOTH `"TASK_COMPLETED"` and
  `"INSTANCE_CANCELLED"` event types (this file's AC4 race needs `complete_task/3` to
  succeed too, not only `cancel_instance/3`) -- `EventStore.append/2`'s own
  `Registry.validate_payload/3` call fails the whole call with
  `{:error, :unknown_event_type}` otherwise (design doc OQ-6, inherited from
  `req045`/`req048`'s own identical gap).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Engine
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.JoinCounter
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.Token
  alias Letflow.Engine.TokenRecord
  alias Letflow.Engine.Transition
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366).
  # TASK_COMPLETED and INSTANCE_CANCELLED are auto-seeded by
  # TenantProvisioning.replay_migrations/2's default manifest (REQ-045 §9 OQ-3a,
  # extended by ISS-0072/GH#257) -- this fixture relies on that seed rather than
  # registering either type itself.
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req052",
      display_name: "REQ-052 Test Tenant"
    )
  end

  defp unique_name(prefix \\ "req052-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> task(HUMAN_TASK) -> END. The instance's only open task.
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

  # START -> PARALLEL_GATEWAY(split) -> HUMAN_TASK(a) / HUMAN_TASK(b) -> join -> END.
  # Both branches stop at their own HUMAN_TASK -- 2 concurrently open tasks/tokens
  # (AC1's own "more than one open task" scenario, mirroring engine_test.exs's own
  # graph_start_parallel_split_human_tasks/0 fixture shape).
  defp graph_parallel_split_two_tasks do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "task_a",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_a"}
        },
        %{
          "id" => "task_b",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_b"}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "task_a"},
        %{"id" => "e3", "source" => "split", "target" => "task_b"},
        %{"id" => "e4", "source" => "task_a", "target" => "join"},
        %{"id" => "e5", "source" => "task_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "end"}
      ]
    }
  end

  defp create_definition_attrs(graph) do
    %{
      name: unique_name(),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  defp active_definition!(schema_name, graph) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph), prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp start_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("start")
      },
      overrides
    )
  end

  defp cancel_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("cancel")
      },
      overrides
    )
  end

  defp complete_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        output_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("complete")
      },
      overrides
    )
  end

  defp task_count(schema_name) do
    Repo.aggregate(EngineTask, :count, prefix: schema_name)
  end

  defp cancelled_events(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "INSTANCE_CANCELLED")
    |> Repo.all(prefix: schema_name)
  end

  defp event_count(schema_name) do
    %{rows: [[count]]} = Repo.query!(~s[SELECT COUNT(*) FROM "#{schema_name}"."events"], [])
    count
  end

  # Starts an instance and returns {instance_id, schema_name, definition}.
  defp start_instance!(schema_name, graph) do
    definition = active_definition!(schema_name, graph)
    assert {:ok, result} = Engine.create(start_attrs(definition), prefix: schema_name)
    result.instance_id
  end

  # ---------------------------------------------------------------------------------
  # AC1
  # ---------------------------------------------------------------------------------

  describe "AC1 -- cancelling an ACTIVE instance with 2 open tasks" do
    test "cancels both tasks, the live tokens, sets the instance CANCELLED, appends one event" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_parallel_split_two_tasks())

      tasks_before = Repo.all(EngineTask, prefix: schema_name)
      assert length(tasks_before) == 2
      assert Enum.all?(tasks_before, &(&1.status == :pending))
      task_ids_before = Enum.map(tasks_before, & &1.id) |> Enum.sort()

      tokens_before = Repo.all(TokenRecord, prefix: schema_name)
      assert length(tokens_before) == 2
      token_ids_before = Enum.map(tokens_before, & &1.id) |> Enum.sort()

      assert {:ok, result} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      assert result.instance_id == instance_id
      assert result.status == :cancelled
      assert Enum.sort(result.cancelled_task_ids) == task_ids_before

      tasks_after = Repo.all(EngineTask, prefix: schema_name)
      assert length(tasks_after) == 2
      assert Enum.all?(tasks_after, &(&1.status == :cancelled))
      assert Enum.all?(tasks_after, &(&1.cancelled_at != nil))

      tokens_after = Repo.all(TokenRecord, prefix: schema_name)
      assert length(tokens_after) == 2
      assert Enum.all?(tokens_after, &(&1.status == :cancelled))
      assert Enum.map(tokens_after, & &1.id) |> Enum.sort() == token_ids_before

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :cancelled
      assert projection.cancelled_at != nil

      assert [event] = cancelled_events(schema_name, instance_id)
      assert Enum.sort(event.payload["cancelled_task_ids"]) == task_ids_before
      assert Enum.sort(event.payload["cancelled_token_ids"]) == token_ids_before
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2
  # ---------------------------------------------------------------------------------

  describe "AC2 -- already-terminal instances rejected, zero-open-tasks ACTIVE still cancels" do
    test "cancelling an already-CANCELLED instance returns a distinct conflict, writes nothing more" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_human_task_end())

      assert {:ok, _first} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      tasks_after_first = task_count(schema_name)
      events_after_first = event_count(schema_name)

      assert {:error, {:instance_already_terminal, :cancelled}} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      assert task_count(schema_name) == tasks_after_first
      assert event_count(schema_name) == events_after_first
    end

    test "cancelling an already-COMPLETED instance returns a distinct conflict, writes nothing" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_human_task_end())
      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)

      [task] = Repo.all(EngineTask, prefix: schema_name)

      assert {:ok, _completed} =
               Engine.complete_task(task.id, complete_attrs(), prefix: schema_name)

      assert {:error, {:instance_already_terminal, :completed}} =
               Engine.cancel_instance(created.instance_id, cancel_attrs(), prefix: schema_name)

      assert cancelled_events(schema_name, created.instance_id) == []

      untouched = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert untouched.status == :completed
    end

    test "an ACTIVE instance with zero open tasks still appends one event and cancels" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_human_task_end())
      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)

      [task] = Repo.all(EngineTask, prefix: schema_name)

      # Forces the zero-open-tasks-while-still-ACTIVE state directly (bypassing
      # complete_task/3 entirely) -- instance_projections.status stays :active while
      # tasks has zero :pending rows, the scenario design doc INV-EE52-4 names as
      # reachable (M1 may return []). Not exercised via any Engine call on purpose --
      # this is test fixture setup for cancel_instance/3's own edge case, not a claim
      # about how a real caller reaches this state.
      task
      |> Ecto.Changeset.change(status: :completed, completed_at: DateTime.utc_now())
      |> Repo.update!(prefix: schema_name)

      projection_before = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert projection_before.status == :active

      assert {:ok, result} =
               Engine.cancel_instance(created.instance_id, cancel_attrs(), prefix: schema_name)

      assert result.cancelled_task_ids == []

      assert [_one_event] = cancelled_events(schema_name, created.instance_id)

      projection_after = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert projection_after.status == :cancelled
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3
  # ---------------------------------------------------------------------------------

  describe "AC3 -- a further EventStore.append/2 call after cancellation" do
    test "returns {:error, {:instance_terminated, :cancelled}} against the real event store" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_human_task_end())

      assert {:ok, _cancelled} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      # The payload must satisfy INSTANCE_CANCELLED's own real json_schema (now
      # provisioning's stricter seed, not a permissive test-fixture stand-in --
      # ISS-0073/GH#267) so this append reaches the :instance_terminated check
      # inside EventStore.append/2's Multi at all -- Registry.validate_payload/3
      # runs in the pre-transaction phase, before that check (event_store.ex's own
      # P4 comment), so a schema-invalid payload like the prior bare `%{probe: true}`
      # now fails validation before :instance_terminated is ever reached, proving
      # the wrong thing.
      append_attrs = %{
        instance_id: instance_id,
        event_type: "INSTANCE_CANCELLED",
        payload: Jason.encode!(%{cancelled_task_ids: [], cancelled_token_ids: []}),
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("post-cancel-append")
      }

      assert {:error, {:instance_terminated, :cancelled}} =
               EventStore.append(append_attrs, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- run concurrently, not sequentially.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- cancel_instance/3 racing complete_task/3, run concurrently" do
    test "exactly one commits, the other observes a distinct conflict error" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_human_task_end())
      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)

      [task] = Repo.all(EngineTask, prefix: schema_name)

      # Real separate Postgres connections -- sandbox mode is :auto (provisioned_tenant/0
      # above), not the shared-connection :manual sandbox mode, so these two processes
      # genuinely race for the same FOR UPDATE task row rather than being serialized by
      # the test's own sandbox ownership (mirrors engine_complete_task_test.exs's own AC4).
      cancel_task =
        Elixir.Task.async(fn ->
          {:cancel,
           Engine.cancel_instance(created.instance_id, cancel_attrs(), prefix: schema_name)}
        end)

      complete_task =
        Elixir.Task.async(fn ->
          {:complete, Engine.complete_task(task.id, complete_attrs(), prefix: schema_name)}
        end)

      results = Elixir.Task.await_many([cancel_task, complete_task], 10_000)

      successes = Enum.filter(results, &match?({_which, {:ok, _}}, &1))
      assert length(successes) == 1
      assert length(results) == 2

      case successes do
        [{:cancel, {:ok, _}}] ->
          assert {:complete, {:error, {:task_not_pending, :cancelled}}} =
                   Enum.find(results, &match?({:complete, _}, &1))

          final_projection =
            Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)

          assert final_projection.status == :cancelled

          final_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
          assert final_task.status == :cancelled

        [{:complete, {:ok, _}}] ->
          assert {:cancel, {:error, {:instance_already_terminal, :completed}}} =
                   Enum.find(results, &match?({:cancel, _}, &1))

          final_projection =
            Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)

          assert final_projection.status == :completed

          final_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
          assert final_task.status == :completed
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5
  # ---------------------------------------------------------------------------------

  describe "AC5 -- REQ-051 join-path :cancel_join vs. a direct cancel_instance/3 call" do
    test "Transition's own :cancel_join outcome and the persisted status agree on :cancelled" do
      # Pure half, no DB -- one outstanding JoinCounter with a single expected branch,
      # nothing received yet: cancelling that last outstanding branch is join_outcome/1's
      # own :cancel_join clause (design doc §7.1's cited req051 §3.4 mechanism).
      join_counter = %JoinCounter{
        join_node_id: "join",
        origin_token_id: "root",
        expected_from_branches: MapSet.new(["b1"]),
        received_from_branches: MapSet.new(),
        cancelled_branches: MapSet.new()
      }

      token = %Token{token_id: "root/0", branch_id: "b1", node_id: "task_a"}

      instance_state = %InstanceState{
        instance_id: Ecto.UUID.generate(),
        tokens: [token],
        join_counters: %{"join" => join_counter}
      }

      assert {:ok, %InstanceState{status: pure_status}, _pending_events} =
               Transition.transition(%Graph{}, instance_state, {:cancel_branch, "b1"})

      assert pure_status == :cancelled

      # Real half, real DB -- an ordinary direct cancel_instance/3 call.
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_human_task_end())

      assert {:ok, _result} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      persisted_status =
        Repo.get!(InstanceProjection, instance_id, prefix: schema_name).status

      assert persisted_status == :cancelled

      # The explicit comparison the AC text calls for.
      assert pure_status == persisted_status
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 / AC7 -- moduledoc content assertions. Pure, no DB.
  # ---------------------------------------------------------------------------------

  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  describe "AC6 -- moduledoc names SCH-03/S6 and REQ-056 as explicit scope gaps" do
    test "names both hooks as undone, not implying EE-08 is fully covered" do
      doc = normalized_moduledoc(Engine)

      assert doc =~ "SCH-03"
      assert doc =~ "S6"
      assert doc =~ "SERVICE_TASK"
      assert doc =~ "REQ-056"
      assert doc =~ "Neither exists in Letflow yet, and `cancel_instance/3` performs neither."
    end
  end

  describe "AC7 -- moduledoc states the ParallelApproval/ApprovalSupervisor disposition" do
    test "states both are deleted, with the REQ-046 contrast reason, and both are actually gone" do
      doc = normalized_moduledoc(Engine)

      assert doc =~ "lib/letflow/parallel_approval.ex` (`Letflow.ParallelApproval`)"
      assert doc =~ "lib/letflow/approval_supervisor.ex` (`Letflow.ApprovalSupervisor`)"
      assert doc =~ "**deleted**"
      assert doc =~ "PARALLEL_GATEWAY"
      assert doc =~ "unlike"
      assert doc =~ "Letflow.ProcessInstance`'s own retirement"

      assert Code.ensure_loaded(Letflow.ParallelApproval) == {:error, :nofile}
      assert Code.ensure_loaded(Letflow.ApprovalSupervisor) == {:error, :nofile}
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0984
  # ---------------------------------------------------------------------------------

  describe "ISS-0984: run_cancel_instance/5's audit raise is rescue-hardened" do
    test "a genuine Postgres-level audit-insert failure returns {:error, {:transaction_failed, _}} and rolls back the whole transaction" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_parallel_split_two_tasks())

      tasks_before = Repo.all(EngineTask, prefix: schema_name)
      assert length(tasks_before) == 2
      assert Enum.all?(tasks_before, &(&1.status == :pending))
      assert Enum.all?(tasks_before, &(&1.cancelled_at == nil))
      task_ids_before = Enum.map(tasks_before, & &1.id) |> Enum.sort()

      tokens_before = Repo.all(TokenRecord, prefix: schema_name)
      assert length(tokens_before) == 2
      assert Enum.all?(tokens_before, &(&1.status != :cancelled))
      token_ids_before = Enum.map(tokens_before, & &1.id) |> Enum.sort()

      projection_before = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection_before.status == :active
      assert projection_before.cancelled_at == nil

      assert cancelled_events(schema_name, instance_id) == []

      Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{schema_name}".audit_entries (
          id uuid PRIMARY KEY,
          tenant_id uuid NOT NULL,
          actor_id uuid,
          actor_kind text,
          action text NOT NULL,
          resource_type text NOT NULL,
          resource_id text NOT NULL,
          "timestamp" timestamp(6) without time zone NOT NULL,
          before_state jsonb,
          after_state jsonb,
          trace_id text,
          chain_hash text NOT NULL,
          prev_chain_hash text,
          inserted_at timestamp(6) without time zone NOT NULL
        )
        """)
      end)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      tasks_after = Repo.all(EngineTask, prefix: schema_name)
      assert length(tasks_after) == 2
      assert Enum.all?(tasks_after, &(&1.status == :pending))
      assert Enum.all?(tasks_after, &(&1.cancelled_at == nil))
      assert Enum.map(tasks_after, & &1.id) |> Enum.sort() == task_ids_before

      tokens_after = Repo.all(TokenRecord, prefix: schema_name)
      assert length(tokens_after) == 2
      assert Enum.all?(tokens_after, &(&1.status != :cancelled))
      assert Enum.map(tokens_after, & &1.id) |> Enum.sort() == token_ids_before

      projection_after = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection_after.status == :active
      assert projection_after.cancelled_at == nil

      assert cancelled_events(schema_name, instance_id) == []
    end
  end
end
