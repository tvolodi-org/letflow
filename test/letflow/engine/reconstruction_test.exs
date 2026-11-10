defmodule Letflow.Engine.ReconstructionTest do
  @moduledoc """
  Tests for REQ-053's `Letflow.Engine.Reconstruction.reconstruct_instance/2` (EE-11 --
  state reconstruction by event replay). See `test/specs/REQ-053.md` for the full
  AC-to-test-case mapping and rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. Mirrors
  `test/letflow/engine_cancel_instance_test.exs`'s own `provisioned_tenant/0` + Sandbox
  `:auto` + `async: false` pattern (real separate Postgres connections, needed for AC5's
  genuine lock-contention race) and its `Task.async` concurrency-test shape.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.SnapshotStore
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.Registry

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp register_event_type!(name, tenant_id) do
    assert {:ok, _event_type} =
             Registry.register_type(
               %{
                 "name" => name,
                 "schema_version" => 1,
                 "json_schema" => %{"type" => "object"},
                 "description" => "REQ-053 test fixture -- permissive schema"
               },
               tenant_id
             )

    :ok
  end

  # Adopts the shared `Letflow.TenantFixture` (ISS-0109/GH#358, ISS-0116/GH#370) in
  # place of this file's own hand-rolled `insert_tenant!/0` + `drop_schema!/1` +
  # `provisioned_tenant/0` copies -- same rationale as promotion_test.exs's own
  # adoption. Behaviour-preserving: `replay_migrations/1` still runs the real
  # default manifest via `TenantFixture`'s own `replay!/1`, so the auto-seeded
  # "INSTANCE_STARTED"/"TASK_COMPLETED"/"INSTANCE_CANCELLED"/"EXECUTION_ERROR"/
  # "SUB_PROCESS_COMPLETED" event types (REQ-045 §9 OQ-3a, extended by
  # ISS-0072/GH#257) are unaffected; only "BOGUS_EVENT_TYPE" (no production writer,
  # not auto-seeded) still needs explicit registration below. This module was named
  # alongside rollback_test.exs/engine_test.exs (ISS-0116's carried finding,
  # WF03-ISS0119-20260821/TEST-RUNNER) as a further un-instrumented site that
  # reproduced the same 3F000 signature from its own copy-pasted fixture.
  defp provisioned_tenant do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      Letflow.TenantFixture.provisioned_tenant!(
        slug_prefix: "req053",
        display_name: "REQ-053 Test Tenant"
      )

    :ok = register_event_type!("BOGUS_EVENT_TYPE", tenant_id)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req053-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> t1(HUMAN_TASK) -> t2(HUMAN_TASK) -> t3(HUMAN_TASK) -> END, sequential
  # (no gateway) -- 3 open-in-turn tasks, N appended events as each completes.
  defp graph_sequential_three_tasks do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "t1", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "r1"}},
        %{"id" => "t2", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "r2"}},
        %{"id" => "t3", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "r3"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "t1"},
        %{"id" => "e2", "source" => "t1", "target" => "t2"},
        %{"id" => "e3", "source" => "t2", "target" => "t3"},
        %{"id" => "e4", "source" => "t3", "target" => "end"}
      ]
    }
  end

  # START -> task(HUMAN_TASK) -> END. Simplest possible non-empty instance.
  defp graph_single_task do
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

  # req062 (SPC-01) fixtures -- START -> SUB_PROCESS("sp") -> after(HUMAN_TASK) -> END,
  # for a parent whose SUB_PROCESS child completion is the event this file's own new
  # replay clause must reconstruct. A trailing HUMAN_TASK (rather than a direct ->END)
  # is deliberate: it leaves a live token at a known, inspectable node_id
  # post-replay, the same reason engine_sub_process_test.exs's own AC5 fixture does.
  defp graph_parent_subprocess_then_task(child_definition_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_definition_name}
        },
        %{"id" => "after", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "closer"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "sp"},
        %{"id" => "e2", "source" => "sp", "target" => "after"},
        %{"id" => "e3", "source" => "after", "target" => "end"}
      ]
    }
  end

  # START -> work(HUMAN_TASK) -> END -- deliberately does not complete synchronously at
  # creation time, so the child's own completion is a separate, later, real
  # Engine.complete_task/3 call this test drives explicitly.
  defp graph_child_two_step do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "work", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "worker"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "work"},
        %{"id" => "e2", "source" => "work", "target" => "end"}
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
        initial_variables: %{"a" => 1},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("start")
      },
      overrides
    )
  end

  defp complete_attrs(output_variables) do
    %{
      output_variables: output_variables,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique_idempotency_key("complete")
    }
  end

  # Starts a sequential-3-task instance, completes t1 (output {"b" => 2}) and t2
  # (output {"c" => 3}), leaving t3 pending. 3 durable events: INSTANCE_STARTED,
  # TASK_COMPLETED(t1), TASK_COMPLETED(t2). Returns {instance_id, schema_name}.
  defp partially_completed_instance!(schema_name) do
    definition = active_definition!(schema_name, graph_sequential_three_tasks())
    assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)

    # Only the node the live token currently sits on has a `tasks` row -- t2/t3's rows
    # don't exist until each prior task completes and the token advances onto them.
    t1 = pending_task!(schema_name, created.instance_id, "t1")

    assert {:ok, _} =
             Engine.complete_task(t1.id, complete_attrs(%{"b" => 2}), prefix: schema_name)

    t2 = pending_task!(schema_name, created.instance_id, "t2")

    assert {:ok, _} =
             Engine.complete_task(t2.id, complete_attrs(%{"c" => 3}), prefix: schema_name)

    {created.instance_id, schema_name}
  end

  defp pending_task!(schema_name, instance_id, node_id) do
    Repo.one!(
      from(t in EngineTask,
        where: t.instance_id == ^instance_id and t.node_id == ^node_id and t.status == :pending
      ),
      prefix: schema_name
    )
  end

  # Multiset-of-node-id / variables / status comparison the design doc §6 defines
  # AC1's "field-for-field equal" against -- InstanceState.tokens' token_id/branch_id
  # are freshly minted on every reconstruct call and have no projection-side
  # counterpart at all, so raw struct equality is never the right comparison here.
  defp assert_state_matches_projection(instance_state, projection) do
    assert Enum.sort(Enum.map(instance_state.tokens, & &1.node_id)) ==
             Enum.sort(projection.current_nodes)

    assert instance_state.variables == projection.variables
    assert instance_state.status == projection.status
  end

  defp pending_task_node_ids(schema_name, instance_id) do
    EngineTask
    |> where([t], t.instance_id == ^instance_id and t.status == :pending)
    |> select([t], t.node_id)
    |> Repo.all(prefix: schema_name)
    |> Enum.sort()
  end

  defp instance_pending_node_ids(instance_state) do
    instance_state.pending_task_nodes |> Enum.map(& &1.node_id) |> Enum.sort()
  end

  # instance_projections.instance_id is FK-referenced by `tokens` -- deleting the
  # projection row (AC2/OQ-4's "projection deleted" scenario) requires clearing the
  # instance's token rows first, or Postgres rejects the delete outright.
  defp delete_projection_row!(schema_name, instance_id) do
    # tasks.token_id -> tokens.id -> instance_projections.instance_id: delete
    # child rows in FK-safe order (tasks, then tokens) before the projection row.
    Repo.delete_all(from(t in EngineTask, where: t.instance_id == ^instance_id),
      prefix: schema_name
    )

    Repo.delete_all(from(t in TokenRecord, where: t.instance_id == ^instance_id),
      prefix: schema_name
    )

    Repo.delete_all(from(p in InstanceProjection, where: p.instance_id == ^instance_id),
      prefix: schema_name
    )
  end

  # Backdates every one of instance_id's live events' created_at so a subsequent
  # EventStore.archive/1 call with a small positive retention_days actually moves
  # them -- retention_days: 0 is explicitly "archive nothing via the fallback rule"
  # (event_store.ex's own archive/1 moduledoc), not "archive everything now", and a
  # freshly-created event is never older than any positive retention_days cutoff
  # without backdating (mirrors event_store_test.exs's own seed_event!/5 pattern).
  defp backdate_events!(schema_name, instance_id, days_ago) do
    cutoff = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)

    Repo.update_all(
      from(e in Event, where: e.instance_id == ^instance_id),
      [set: [created_at: cutoff]],
      prefix: schema_name
    )
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- N-event instance reconstructs field-for-field equal to the projection.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- multi-event instance reconstructs equal to its persisted projection" do
    test "3 durable events (STARTED + 2 TASK_COMPLETED) reconstruct to matching tokens/variables/status/tasks" do
      %{schema_name: schema_name} = provisioned_tenant()
      {instance_id, schema_name} = partially_completed_instance!(schema_name)

      assert {:ok, result} = Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      assert result.instance_id == instance_id
      assert result.event_count == 3
      assert result.write_back == :skipped

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert_state_matches_projection(result.instance_state, projection)
      assert result.instance_state.variables == %{"a" => 1, "b" => 2, "c" => 3}
      assert result.instance_state.status == :active

      assert instance_pending_node_ids(result.instance_state) ==
               pending_task_node_ids(schema_name, instance_id)

      assert instance_pending_node_ids(result.instance_state) == ["t3"]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- ground truth is the event log, not the projection.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- deleting instance_projections entirely still reconstructs the correct state" do
    test "reconstruction succeeds with the right state after the projection row is gone" do
      %{schema_name: schema_name} = provisioned_tenant()
      {instance_id, schema_name} = partially_completed_instance!(schema_name)

      delete_projection_row!(schema_name, instance_id)

      assert Repo.get(InstanceProjection, instance_id, prefix: schema_name) == nil

      assert {:ok, result} = Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      assert result.instance_state.status == :active
      assert result.instance_state.variables == %{"a" => 1, "b" => 2, "c" => 3}
      assert Enum.map(result.instance_state.tokens, & &1.node_id) == ["t3"]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- events spanning both `events` and `events_archive`.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- events partly archived, some appended after, reconstruct to the correct merged state" do
    test "reconstructing across events/events_archive matches the unbroken pre-archival log" do
      %{schema_name: schema_name} = provisioned_tenant()
      {instance_id, schema_name} = partially_completed_instance!(schema_name)

      assert {:ok, before_result} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      # retention_days: 0 archives nothing via the fallback rule (event_store.ex's own
      # archive/1 moduledoc) -- backdate the 3 live events first, matching
      # event_store_test.exs's own seed_event!/5 backdating pattern, then archive
      # with a small positive retention_days so all 3 are eligible.
      backdate_events!(schema_name, instance_id, 2)

      assert {:ok, %{moved_count: 3}} =
               EventStore.archive(prefix: schema_name, retention_days: 1)

      assert {:ok, after_archive_result} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      # Archiving is a pure storage relocation -- reconstructing purely-archived
      # events must land on the identical logical state as before archival.
      assert Enum.sort(Enum.map(after_archive_result.instance_state.tokens, & &1.node_id)) ==
               Enum.sort(Enum.map(before_result.instance_state.tokens, & &1.node_id))

      assert after_archive_result.instance_state.variables ==
               before_result.instance_state.variables

      assert after_archive_result.instance_state.status == before_result.instance_state.status

      # Now a genuinely new event lands in the LIVE `events` table, while the
      # instance's earlier events remain in `events_archive` -- the log now
      # actually spans both tables at once (the AC's literal scenario).
      [t3] =
        EngineTask
        |> where([t], t.instance_id == ^instance_id and t.status == :pending)
        |> Repo.all(prefix: schema_name)

      assert {:ok, _} =
               Engine.complete_task(t3.id, complete_attrs(%{"d" => 4}), prefix: schema_name)

      assert {:ok, final_result} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      assert final_result.event_count == 4
      assert final_result.instance_state.status == :completed
      assert final_result.instance_state.tokens == []
      assert final_result.instance_state.variables == %{"a" => 1, "b" => 2, "c" => 3, "d" => 4}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- zero-events seed state, and EXECUTION_ERROR replay.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- zero-events instance seeds token-on-START/empty-variables/ACTIVE" do
    test "reconstructs a snapshot-only, zero-event instance to the seed state" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_single_task())

      # Mirrors the snapshot-committed, event-append-crashed window design doc §4/§5.1
      # names: a real instance_definition_snapshots row exists but no INSTANCE_STARTED
      # event (or instance_projections row) was ever appended -- Engine.create/2 is
      # deliberately NOT called here.
      instance_id = Ecto.UUID.generate()

      assert {:ok, _snapshot} =
               SnapshotStore.create(instance_id, definition.id, prefix: schema_name)

      assert {:ok, result} = Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      assert result.event_count == 0
      assert result.last_sequence_number == nil
      assert result.instance_state.status == :active
      assert result.instance_state.variables == %{}
      assert [%{node_id: "start"}] = result.instance_state.tokens
    end
  end

  describe "AC4 -- a log containing EXECUTION_ERROR reconstructs to status ERROR" do
    test "reconstructs status :error with the payload's variable snapshot" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_single_task())
      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)

      # Satisfies EXECUTION_ERROR's real json_schema (now provisioning's stricter
      # seed, not a permissive test-fixture stand-in -- ISS-0073/GH#267): "error_type",
      # "affected", and "reason" are all required. This AC only cares about the
      # `variables` snapshot surviving reconstruction, so the other required fields
      # are filled with minimal-but-valid placeholder values.
      error_payload =
        Jason.encode!(%{
          error_type: "test_forced_error",
          affected: %{kind: "node", node_id: "task"},
          reason: "REQ-053 AC4 test fixture -- forced error for reconstruction coverage",
          variables: %{"a" => 1, "error_snapshot" => true}
        })

      assert {:ok, _event} =
               EventStore.append(
                 %{
                   instance_id: created.instance_id,
                   event_type: "EXECUTION_ERROR",
                   payload: error_payload,
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_idempotency_key("error")
                 },
                 prefix: schema_name
               )

      assert {:ok, result} =
               Reconstruction.reconstruct_instance(created.instance_id, prefix: schema_name)

      assert result.instance_state.status == :error
      assert result.instance_state.variables == %{"a" => 1, "error_snapshot" => true}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- write-back: read-only by default, opt-in write, lock contention.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- reconstruction without write-back never mutates instance_projections" do
    test "the projection row is byte-identical before and after a plain (no write_back) call" do
      %{schema_name: schema_name} = provisioned_tenant()
      {instance_id, schema_name} = partially_completed_instance!(schema_name)

      before_row = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)

      assert {:ok, result} = Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)
      assert result.write_back == :skipped

      after_row = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)

      assert before_row.status == after_row.status
      assert before_row.current_nodes == after_row.current_nodes
      assert before_row.variables == after_row.variables
      assert before_row.last_event_seq == after_row.last_event_seq
      assert before_row.definition_id == after_row.definition_id
      assert before_row.correlation_key == after_row.correlation_key
    end
  end

  describe "AC5 -- write_back: true updates instance_projections to the reconstructed state" do
    test "the row's status/current_nodes/variables/last_event_seq reflect the replayed state" do
      %{schema_name: schema_name} = provisioned_tenant()
      {instance_id, schema_name} = partially_completed_instance!(schema_name)

      # Force the live projection row stale/wrong first, so the write-back assertion
      # actually proves a write happened rather than merely matching an
      # already-correct row by coincidence.
      Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      |> Ecto.Changeset.change(variables: %{"stale" => true}, current_nodes: ["stale_node"])
      |> Repo.update!(prefix: schema_name)

      assert {:ok, result} =
               Reconstruction.reconstruct_instance(instance_id,
                 prefix: schema_name,
                 write_back: true
               )

      assert result.write_back == :written

      row = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert row.status == :active
      assert row.current_nodes == ["t3"]
      assert row.variables == %{"a" => 1, "b" => 2, "c" => 3}
      assert row.last_event_seq == result.last_sequence_number
    end
  end

  describe "AC5/OQ-4 -- write_back: true inserts a fresh row when the projection was deleted" do
    test "a deleted projection row is re-created by write-back, sourcing definition_id from the snapshot" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_sequential_three_tasks())
      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)

      delete_projection_row!(schema_name, created.instance_id)

      assert {:ok, result} =
               Reconstruction.reconstruct_instance(created.instance_id,
                 prefix: schema_name,
                 write_back: true
               )

      assert result.write_back == :written

      row = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert row.status == :active
      assert row.definition_id == definition.id
      assert row.correlation_key == nil
      assert row.current_nodes == ["t1"]
      assert row.variables == %{"a" => 1}
    end
  end

  # A real second Postgres connection holds a plain `FOR UPDATE` lock on the
  # projection row until told to release -- write_back/3's own `FOR UPDATE NOWAIT`
  # must then fail immediately with :lock_contention rather than blocking. Sandbox
  # mode is :auto (provisioned_tenant/0), so this is a genuine two-connection race,
  # not serialized by shared sandbox ownership -- mirrors
  # engine_cancel_instance_test.exs's own AC4 concurrency shape.
  defp with_locked_projection(schema_name, instance_id, fun) do
    test_pid = self()

    holder =
      Elixir.Task.async(fn ->
        Repo.transaction(fn ->
          query =
            InstanceProjection
            |> where([p], p.instance_id == ^instance_id)
            |> lock("FOR UPDATE")

          _locked = Repo.one(query, prefix: schema_name)
          send(test_pid, :locked)

          receive do
            :release -> :ok
          after
            5_000 -> :ok
          end
        end)
      end)

    receive do
      :locked -> :ok
    after
      5_000 -> flunk("lock holder task never acquired the row lock")
    end

    result = fun.()

    send(holder.pid, :release)
    Elixir.Task.await(holder, 5_000)

    result
  end

  describe "AC5 -- a concurrent lock holder causes lock-contention, never a silent overwrite" do
    test "write_back: true returns {:error, {:lock_contention, id}} while a transaction holds FOR UPDATE" do
      %{schema_name: schema_name} = provisioned_tenant()
      {instance_id, schema_name} = partially_completed_instance!(schema_name)

      row_before = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)

      result =
        with_locked_projection(schema_name, instance_id, fn ->
          Reconstruction.reconstruct_instance(instance_id, prefix: schema_name, write_back: true)
        end)

      assert {:error, {:lock_contention, ^instance_id}} = result

      row_after = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert row_before.variables == row_after.variables
      assert row_before.current_nodes == row_after.current_nodes
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- 3 separately pattern-matchable errors, each with its own test.
  # ---------------------------------------------------------------------------------

  describe "AC6 -- :instance_not_found for an id with no events and no snapshot" do
    test "returns {:error, :instance_not_found}, never {:error, {:replay_failed, _}}" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, :instance_not_found} =
               Reconstruction.reconstruct_instance(Ecto.UUID.generate(), prefix: schema_name)
    end
  end

  describe "AC6 -- {:lock_contention, instance_id} is its own distinct error shape" do
    test "matches {:error, {:lock_contention, ^instance_id}}, never a bare generic error" do
      %{schema_name: schema_name} = provisioned_tenant()
      {instance_id, schema_name} = partially_completed_instance!(schema_name)

      result =
        with_locked_projection(schema_name, instance_id, fn ->
          Reconstruction.reconstruct_instance(instance_id, prefix: schema_name, write_back: true)
        end)

      assert {:error, {:lock_contention, ^instance_id}} = result
    end
  end

  describe "AC6 -- {:replay_failed, {:unrecognized_event_type, _, _}} for a persisted unknown event type" do
    test "an event type outside the closed 4-type set surfaces as a distinct replay_failed error" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_single_task())
      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)

      assert {:ok, %{event: %{event_id: event_id}}} =
               EventStore.append(
                 %{
                   instance_id: created.instance_id,
                   event_type: "BOGUS_EVENT_TYPE",
                   payload: Jason.encode!(%{}),
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_idempotency_key("bogus")
                 },
                 prefix: schema_name
               )

      assert {:error, {:replay_failed, {:unrecognized_event_type, "BOGUS_EVENT_TYPE", ^event_id}}} =
               Reconstruction.reconstruct_instance(created.instance_id, prefix: schema_name)
    end
  end

  describe "REQ-792 -- NODE_ENTERED is folded as a no-op" do
    test "T-792-3 an appended NODE_ENTERED leaves the replayed state unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      {instance_id, schema_name} = partially_completed_instance!(schema_name)

      assert {:ok, before} = Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      assert {:ok, _} =
               EventStore.append(
                 %{
                   instance_id: instance_id,
                   event_type: "NODE_ENTERED",
                   payload:
                     Jason.encode!(%{
                       "node_id" => "t3",
                       "node_type" => "HUMAN_TASK",
                       "via_edge_id" => nil
                     }),
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_idempotency_key("node_entered")
                 },
                 prefix: schema_name
               )

      assert {:ok, after_} = Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)
      assert after_.event_count == before.event_count + 1
      assert after_.instance_state.variables == before.instance_state.variables
      assert after_.instance_state.status == before.instance_state.status

      assert instance_pending_node_ids(after_.instance_state) ==
               instance_pending_node_ids(before.instance_state)

      assert "NODE_ENTERED" in Reconstruction.folded_event_types()
    end
  end

  # ---------------------------------------------------------------------------------
  # req062 (SPC-01) -- SUB_PROCESS_COMPLETED replay clause (apply_event/3's newest
  # clause, added this same branch as a rework-1 fix -- see this module's own
  # moduledoc "findings confirmed against shipped code" list). Not one of REQ-053's
  # own bare ACs (SUB_PROCESS_COMPLETED did not exist when REQ-053 was built) but
  # necessary regression coverage: reconstruct_instance/2 must replay a real, live
  # parent+child sub-process completion to the SAME state Letflow.Engine's own live
  # completion path produced, matching how EXECUTION_ERROR/TASK_COMPLETED are each
  # already covered above.
  # ---------------------------------------------------------------------------------

  describe "req062 -- SUB_PROCESS_COMPLETED replay reconstructs the same state the live completion path produced" do
    test "reconstructing a parent past its completed SUB_PROCESS child matches the live projection" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_definition = active_definition!(schema_name, graph_child_two_step())

      parent_definition =
        active_definition!(schema_name, graph_parent_subprocess_then_task(child_definition.name))

      assert {:ok, created} =
               Engine.create(start_attrs(parent_definition), prefix: schema_name)

      [child_projection] =
        InstanceProjection
        |> where([p], p.parent_instance_id == ^created.instance_id)
        |> Repo.all(prefix: schema_name)

      child_task =
        EngineTask
        |> where([t], t.instance_id == ^child_projection.instance_id and t.status == :pending)
        |> Repo.one!(prefix: schema_name)

      assert {:ok, _child_result} =
               Engine.complete_task(
                 child_task.id,
                 complete_attrs(%{"result" => true}),
                 prefix: schema_name
               )

      live_projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert live_projection.status == :active
      assert live_projection.current_nodes == ["after"]
      assert live_projection.variables == %{"a" => 1, "result" => true}

      assert {:ok, result} =
               Reconstruction.reconstruct_instance(created.instance_id, prefix: schema_name)

      # 2 durable events on the parent's own stream: INSTANCE_STARTED, then
      # SUB_PROCESS_COMPLETED (the child's own completion never appends anything to
      # the PARENT's stream except this one event -- design doc §3.4 point 4).
      assert result.event_count == 2
      assert_state_matches_projection(result.instance_state, live_projection)
      assert result.instance_state.variables == %{"a" => 1, "result" => true}
      assert Enum.map(result.instance_state.tokens, & &1.node_id) == ["after"]

      # The reconstructed token's own wait was genuinely cleared by replay (not just
      # coincidentally absent) -- confirms apply_event/3's SUB_PROCESS_COMPLETED
      # clause actually clears waiting_child_instance_id via
      # dispatch_sub_process_completion/3, not merely advances a token that never
      # carried the flag to begin with.
      assert Enum.all?(result.instance_state.tokens, &(&1.waiting_child_instance_id == nil))
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- moduledoc records R-Co's NFR-04 bound as documented context only.
  # ---------------------------------------------------------------------------------

  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  describe "AC7 -- moduledoc states NFR-04 as R-Co context Letflow has not adopted" do
    test "names the 10,000-events/5-seconds bound and explicitly disclaims it as a Letflow AC" do
      doc = normalized_moduledoc(Reconstruction)

      assert doc =~ "NFR-04"
      assert doc =~ "10,000 events"
      assert doc =~ "5 seconds"
      assert doc =~ "Letflow has not adopted an NFR requirement"
      assert doc =~ "no code in this module is written, tuned, or tested against it"
    end
  end
end
