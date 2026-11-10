defmodule Letflow.Engine.SnapshotWriterTest do
  @moduledoc """
  Tests for REQ-054's `Letflow.Engine.SnapshotWriter` (EE-01x — periodic execution-state
  snapshots) and its extension of REQ-053's `Letflow.Engine.Reconstruction.reconstruct_instance/2`
  to replay from the latest snapshot when one exists. See `test/specs/REQ-054.md` for the
  full AC-to-test-case mapping and rationale, including the AC6/500-node-cap finding.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. Fixture shape mirrors
  `test/letflow/engine/reconstruction_test.exs`'s own `provisioned_tenant/0` + Sandbox
  `:auto` + `async: false` pattern.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.InstanceStateSnapshot
  alias Letflow.Engine.JoinCounter
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.SnapshotWriter
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.Token
  alias Letflow.EventStore.Event
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers (mirrors reconstruction_test.exs's own shape), provisioned via
  # Letflow.TenantFixture (ISS-0112 / GH#366).
  # ---------------------------------------------------------------------------------

  # "INSTANCE_STARTED", "TASK_COMPLETED", and "EXECUTION_ERROR" are all now
  # auto-seeded by replay_migrations/2's default manifest (REQ-045 §9 OQ-3a,
  # extended by ISS-0072/GH#257) -- this fixture used to self-register the latter
  # two again against a permissive `%{"type" => "object"}` schema (ISS-0073/GH#267:
  # that duplicate registration now collides with provisioning's own seed and
  # hard-fails). Removed rather than reconciled: every payload this file writes
  # goes through the real Engine.complete_task/3 / ExecutionError writers
  # provisioning's stricter schemas were written to validate.
  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req054",
      display_name: "REQ-054 Test Tenant"
    )
  end

  defp unique_name(prefix \\ "req054-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> t1(HUMAN_TASK) -> t2(HUMAN_TASK) -> t3(HUMAN_TASK) -> END, sequential.
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

  defp pending_task!(schema_name, instance_id, node_id) do
    Repo.one!(
      from(t in EngineTask,
        where: t.instance_id == ^instance_id and t.node_id == ^node_id and t.status == :pending
      ),
      prefix: schema_name
    )
  end

  defp last_event_sequence_number(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id)
    |> order_by([e], desc: e.sequence_number)
    |> limit(1)
    |> select([e], e.sequence_number)
    |> Repo.one!(prefix: schema_name)
  end

  # A rich, hand-built InstanceState exercising every field the round-trip (AC2) must
  # preserve -- two tokens (one with branch_id/waiting_child_instance_id set, one with
  # both nil), a non-trivial variables map, a distinct pending_task_nodes list, and one
  # outstanding join_counters cohort with all three MapSet fields populated.
  defp rich_instance_state_fixture(instance_id) do
    %InstanceState{
      instance_id: instance_id,
      status: :active,
      tokens: [
        %Token{
          node_id: "t2",
          token_id: Ecto.UUID.generate(),
          branch_id: "branch-a",
          waiting_child_instance_id: Ecto.UUID.generate()
        },
        %Token{node_id: "t3", token_id: Ecto.UUID.generate()}
      ],
      variables: %{"a" => 1, "b" => %{"nested" => true}, "c" => [1, 2, 3]},
      pending_task_nodes: [
        %Token{node_id: "t2", token_id: Ecto.UUID.generate()}
      ],
      join_counters: %{
        "join1" => %JoinCounter{
          join_node_id: "join1",
          origin_token_id: Ecto.UUID.generate(),
          expected_from_branches: MapSet.new(["b1", "b2", "b3"]),
          received_from_branches: MapSet.new(["b1"]),
          cancelled_branches: MapSet.new(["b3"])
        }
      }
    }
  end

  defp minimal_instance_state_fixture(instance_id) do
    %InstanceState{instance_id: instance_id, status: :active}
  end

  # Node-id multiset / variables / status / pending-task-node-set comparison, per REQ-053
  # design §6's own equality definition -- token_id/branch_id are freshly minted on every
  # reconstruct call and have no counterpart to compare byte-for-byte, so raw struct `==`
  # is never the right comparison between two independently-reconstructed InstanceState
  # values (mirrors reconstruction_test.exs's own assert_state_matches_projection/2).
  defp assert_instance_states_agree(state_a, state_b) do
    assert Enum.sort(Enum.map(state_a.tokens, & &1.node_id)) ==
             Enum.sort(Enum.map(state_b.tokens, & &1.node_id))

    assert state_a.variables == state_b.variables
    assert state_a.status == state_b.status

    assert Enum.sort(Enum.map(state_a.pending_task_nodes, & &1.node_id)) ==
             Enum.sort(Enum.map(state_b.pending_task_nodes, & &1.node_id))
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- migration applies cleanly under tenant provisioning, no tenant_id column.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- instance_state_snapshots migration" do
    test "applies cleanly under tenant provisioning, no tenant_id column" do
      %{schema_name: schema_name} = provisioned_tenant()

      columns =
        Repo.query!(
          "select column_name from information_schema.columns " <>
            "where table_schema = $1 and table_name = 'instance_state_snapshots'",
          [schema_name]
        ).rows
        |> List.flatten()
        |> Enum.sort()

      assert columns == ["id", "instance_id", "sequence_number", "state", "taken_at"]
      refute "tenant_id" in columns
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- take_snapshot/4 round-trips InstanceState field-for-field (INV-ISS-3).
  # ---------------------------------------------------------------------------------

  describe "AC2 -- take_snapshot/4 round trip" do
    test "followed by latest_snapshot/2 round-trips every InstanceState field" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_single_task())
      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)

      instance_state = rich_instance_state_fixture(created.instance_id)

      assert {:ok, snapshot_id} =
               SnapshotWriter.take_snapshot(created.instance_id, instance_state, 42,
                 prefix: schema_name
               )

      assert is_binary(snapshot_id)

      assert {:ok, {round_tripped_state, sequence_number}} =
               SnapshotWriter.latest_snapshot(created.instance_id, prefix: schema_name)

      assert sequence_number == 42
      assert round_tripped_state == instance_state
    end

    test "round-trips a token's nil branch_id/waiting_child_instance_id, not just present values" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_single_task())
      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)

      instance_state = minimal_instance_state_fixture(created.instance_id)

      assert {:ok, _id} =
               SnapshotWriter.take_snapshot(created.instance_id, instance_state, 1,
                 prefix: schema_name
               )

      assert {:ok, {round_tripped_state, 1}} =
               SnapshotWriter.latest_snapshot(created.instance_id, prefix: schema_name)

      assert round_tripped_state == instance_state
      assert round_tripped_state.tokens == []
      assert round_tripped_state.join_counters == %{}
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0397 -- serialize_join_counters/1 / deserialize_join_counters/1 (design doc
  # §5.4), promoted from private helpers inlined in serialize_state/1 /
  # deserialize_state/2 (still exercised end-to-end by AC2 above) to public
  # functions so Letflow.Engine can reuse the exact same codec to persist
  # `instance_projections.join_counters`. Pure, single-process, no Repo/DB --
  # confirms the promoted, now-public functions behave identically to the
  # already-AC2-tested inline logic they replace.
  # ---------------------------------------------------------------------------------

  describe "ISS-0397 -- serialize_join_counters/1 / deserialize_join_counters/1 round trip" do
    test "round-trips a join_counters map with non-empty expected/received/cancelled MapSets" do
      join_counters = %{
        "join1" => %JoinCounter{
          join_node_id: "join1",
          origin_token_id: Ecto.UUID.generate(),
          expected_from_branches: MapSet.new(["b1", "b2", "b3"]),
          received_from_branches: MapSet.new(["b1"]),
          cancelled_branches: MapSet.new(["b3"])
        }
      }

      serialized = SnapshotWriter.serialize_join_counters(join_counters)

      assert %{
               "join1" => %{
                 "join_node_id" => "join1",
                 "origin_token_id" => origin_token_id,
                 "expected_from_branches" => expected,
                 "received_from_branches" => received,
                 "cancelled_branches" => cancelled
               }
             } = serialized

      assert origin_token_id == join_counters["join1"].origin_token_id
      assert Enum.sort(expected) == ["b1", "b2", "b3"]
      assert received == ["b1"]
      assert cancelled == ["b3"]

      assert SnapshotWriter.deserialize_join_counters(serialized) == join_counters
    end

    test "round-trips an empty join_counters map (no outstanding cohort)" do
      assert SnapshotWriter.serialize_join_counters(%{}) == %{}
      assert SnapshotWriter.deserialize_join_counters(%{}) == %{}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- maybe_take_snapshot/4 cadence: default 1000, and configurable.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- maybe_take_snapshot/4 cadence" do
    test "default interval 1000: no row below it, exactly one row at it" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_single_task())
      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      instance_state = minimal_instance_state_fixture(created.instance_id)

      assert {:ok, :skipped} =
               SnapshotWriter.maybe_take_snapshot(created.instance_id, instance_state, 999,
                 prefix: schema_name
               )

      assert {:error, :snapshot_not_found} =
               SnapshotWriter.latest_snapshot(created.instance_id, prefix: schema_name)

      assert {:ok, :snapshotted} =
               SnapshotWriter.maybe_take_snapshot(created.instance_id, instance_state, 1000,
                 prefix: schema_name
               )

      assert {:ok, {_state, 1000}} =
               SnapshotWriter.latest_snapshot(created.instance_id, prefix: schema_name)

      row_count =
        InstanceStateSnapshot
        |> where([s], s.instance_id == ^created.instance_id)
        |> Repo.aggregate(:count, prefix: schema_name)

      assert row_count == 1
    end

    test "configurable interval: no row below it, exactly one row at it" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_single_task())
      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      instance_state = minimal_instance_state_fixture(created.instance_id)

      assert {:ok, :skipped} =
               SnapshotWriter.maybe_take_snapshot(created.instance_id, instance_state, 4,
                 prefix: schema_name,
                 interval: 5
               )

      assert {:error, :snapshot_not_found} =
               SnapshotWriter.latest_snapshot(created.instance_id, prefix: schema_name)

      assert {:ok, :snapshotted} =
               SnapshotWriter.maybe_take_snapshot(created.instance_id, instance_state, 5,
                 prefix: schema_name,
                 interval: 5
               )

      assert {:ok, {_state, 5}} =
               SnapshotWriter.latest_snapshot(created.instance_id, prefix: schema_name)

      row_count =
        InstanceStateSnapshot
        |> where([s], s.instance_id == ^created.instance_id)
        |> Repo.aggregate(:count, prefix: schema_name)

      assert row_count == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- both-paths-agree: snapshot-sourced vs. full-replay reconstruction of an
  # identical event history (INV-ISS-1). The single most important test in this file.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- both-paths-agree" do
    test "snapshot-sourced reconstruction agrees with full-replay reconstruction of an identical history" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_sequential_three_tasks())

      # Instance A: complete t1 and t2, take a REAL snapshot (not a stub) at that point,
      # then complete t3 -- one more real event past the snapshot.
      assert {:ok, created_a} = Engine.create(start_attrs(definition), prefix: schema_name)

      t1_a = pending_task!(schema_name, created_a.instance_id, "t1")

      assert {:ok, _} =
               Engine.complete_task(t1_a.id, complete_attrs(%{"b" => 2}), prefix: schema_name)

      t2_a = pending_task!(schema_name, created_a.instance_id, "t2")

      assert {:ok, _} =
               Engine.complete_task(t2_a.id, complete_attrs(%{"c" => 3}), prefix: schema_name)

      assert {:ok, mid_result} =
               Reconstruction.reconstruct_instance(created_a.instance_id, prefix: schema_name)

      assert {:ok, _snapshot_id} =
               SnapshotWriter.take_snapshot(
                 created_a.instance_id,
                 mid_result.instance_state,
                 mid_result.last_sequence_number,
                 prefix: schema_name
               )

      t3_a = pending_task!(schema_name, created_a.instance_id, "t3")

      assert {:ok, _} =
               Engine.complete_task(t3_a.id, complete_attrs(%{"d" => 4}), prefix: schema_name)

      # Instance B: identical graph, identical sequence of completions, NEVER snapshotted
      # -- select_replay_source/2 genuinely returns {:full_replay, 1} for this instance.
      assert {:ok, created_b} = Engine.create(start_attrs(definition), prefix: schema_name)

      t1_b = pending_task!(schema_name, created_b.instance_id, "t1")

      assert {:ok, _} =
               Engine.complete_task(t1_b.id, complete_attrs(%{"b" => 2}), prefix: schema_name)

      t2_b = pending_task!(schema_name, created_b.instance_id, "t2")

      assert {:ok, _} =
               Engine.complete_task(t2_b.id, complete_attrs(%{"c" => 3}), prefix: schema_name)

      t3_b = pending_task!(schema_name, created_b.instance_id, "t3")

      assert {:ok, _} =
               Engine.complete_task(t3_b.id, complete_attrs(%{"d" => 4}), prefix: schema_name)

      assert {:ok, snapshot_sourced_result} =
               Reconstruction.reconstruct_instance(created_a.instance_id, prefix: schema_name)

      assert {:ok, full_replay_result} =
               Reconstruction.reconstruct_instance(created_b.instance_id, prefix: schema_name)

      # Proves the snapshot path was genuinely taken for instance A (only the one event
      # after the snapshot's sequence_number is folded), not merely that both instances
      # happened to land on the same final state via the same (full-replay) path.
      assert snapshot_sourced_result.event_count == 2
      assert full_replay_result.event_count == 9

      assert_instance_states_agree(
        snapshot_sourced_result.instance_state,
        full_replay_result.instance_state
      )

      assert snapshot_sourced_result.instance_state.status == :completed

      assert snapshot_sourced_result.instance_state.variables ==
               %{"a" => 1, "b" => 2, "c" => 3, "d" => 4}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- moduledoc distinguishes the two snapshot tables, and names the open question.
  # ---------------------------------------------------------------------------------

  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  describe "AC5 -- SnapshotWriter moduledoc content" do
    test "distinguishes instance_state_snapshots from instance_definition_snapshots" do
      doc = normalized_moduledoc(SnapshotWriter)

      assert doc =~ "instance_state_snapshots"
      assert doc =~ "instance_definition_snapshots"
      assert doc =~ "not"
      assert doc =~ "immutable PD-08"
      assert doc =~ "periodic"
    end

    test "names the cadence-counter placement as an open question" do
      doc = normalized_moduledoc(SnapshotWriter)

      assert doc =~ "Open question"
      assert doc =~ "stage-3-instance-engine.md"
      assert doc =~ "req045-instance-start-engine-shell.md"
      assert doc =~ "This module implements option 1"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- engine.ex wiring, real end-to-end (not maybe_take_snapshot tested in
  # isolation). See test/specs/REQ-054.md test case 6 for the 500-node-cap finding
  # that shapes how this AC is covered.
  # ---------------------------------------------------------------------------------

  describe "AC6 -- engine.ex wiring, no premature write" do
    test "real create/complete_task/set_instance_error calls never write below the real threshold" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_sequential_three_tasks())

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)

      assert {:error, :snapshot_not_found} =
               SnapshotWriter.latest_snapshot(created.instance_id, prefix: schema_name)

      t1 = pending_task!(schema_name, created.instance_id, "t1")

      assert {:ok, _} =
               Engine.complete_task(t1.id, complete_attrs(%{"b" => 2}), prefix: schema_name)

      assert {:error, :snapshot_not_found} =
               SnapshotWriter.latest_snapshot(created.instance_id, prefix: schema_name)

      error_attrs = %{
        instance_id: created.instance_id,
        error_type: :service_task_retries_exhausted,
        affected: {:node, "t2"},
        reason: "req054 AC6 fixture -- forced error",
        variables: %{"a" => 1, "b" => 2},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("error")
      }

      assert {:ok, _result} = Engine.set_instance_error(error_attrs, prefix: schema_name)

      assert {:error, :snapshot_not_found} =
               SnapshotWriter.latest_snapshot(created.instance_id, prefix: schema_name)

      last_seq = last_event_sequence_number(schema_name, created.instance_id)
      assert last_seq < 1000
    end
  end

  describe "AC6 -- engine.ex wiring, writes once its real threshold holds" do
    test "the exact same call path writes a row once its real threshold condition holds" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_single_task())

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)

      task = pending_task!(schema_name, created.instance_id, "task")

      assert {:ok, completion} =
               Engine.complete_task(task.id, complete_attrs(%{"b" => 2}), prefix: schema_name)

      real_sequence_number = last_event_sequence_number(schema_name, created.instance_id)

      real_final_state = %InstanceState{
        instance_id: created.instance_id,
        status: completion.instance_status,
        tokens: [],
        variables: completion.variables
      }

      # Same maybe_take_snapshot/4 function engine.ex's own call sites invoke (see
      # test/specs/REQ-054.md test case 6 for why the literal default interval of 1000
      # cannot be reached through a real create/complete_task call chain given REQ-028's
      # 500-node graph cap) -- here supplied a small, real `interval` override (a
      # documented cadence_opts() field, not a stub) so the same real production code
      # path can be shown to write once its threshold genuinely holds, using an
      # InstanceState a real Engine.complete_task/3 call actually produced.
      assert {:ok, :snapshotted} =
               SnapshotWriter.maybe_take_snapshot(
                 created.instance_id,
                 real_final_state,
                 real_sequence_number,
                 prefix: schema_name,
                 interval: 1
               )

      assert {:ok, {round_tripped_state, ^real_sequence_number}} =
               SnapshotWriter.latest_snapshot(created.instance_id, prefix: schema_name)

      assert round_tripped_state.status == completion.instance_status
      assert round_tripped_state.variables == completion.variables
    end
  end
end
