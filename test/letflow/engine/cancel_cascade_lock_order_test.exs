defmodule Letflow.Engine.CancelCascadeLockOrderTest do
  @moduledoc """
  GH #2695 (design `lib/letflow/design/gh2695-cancel-cascade-lock-order.md`, section 5): a parent
  `cancel_instance/3` against the completion of its sub-process child, in both orders, on the
  HUMAN path (H, `complete_task/3`) and the HTTP service path (S,
  `advance_after_service_task_outcome/4`).

  The forced-overlap harness (barrier row, pinned workers, deadlock telemetry handler) is the
  shared `Letflow.LockOrderHelpers`; this file only supplies the scenarios.

  Sandbox `:auto` mode (real commits, real connections), hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Engine
  alias Letflow.Engine.SubProcess
  alias Letflow.Engine.TokenRecord
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  @await_ms 15_000

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    base = Fx.committed_tenant_case!("gh2695-lock")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)

    :ok = H.attach_error_handler(__MODULE__)

    %{base: base}
  end

  # ---- fixtures ---------------------------------------------------------------------------------

  defp family(path) when path in [:human, :human_continuing], do: :human
  defp family(path) when path in [:service, :service_continuing], do: :service

  defp child_graph(:human), do: Fx.graph([])

  # CONTINUING children: the step under test does not finish the child (a second HUMAN node
  # follows), so no cascade runs; the child's projection is still UPDATEd.
  defp child_graph(:human_continuing) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "h1", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "h2", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "h1"},
        %{"id" => "e2", "source" => "h1", "target" => "h2"},
        %{"id" => "e3", "source" => "h2", "target" => "end"}
      ]
    }
  end

  defp child_graph(:service_continuing) do
    graph = child_graph(:service)

    %{
      "nodes" =>
        List.insert_at(graph["nodes"], 3, %{
          "id" => "h2",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "REVIEWER"}
        }),
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ct"},
        %{"id" => "e2", "source" => "ct", "target" => "svc"},
        %{"id" => "e3", "source" => "svc", "target" => "h2"},
        %{"id" => "e4", "source" => "h2", "target" => "end"}
      ]
    }
  end

  # START -> HUMAN "ct" -> SERVICE_TASK "svc" (HTTP) -> END. The human task comes first because a
  # child created by a SUB_PROCESS node arms no dispatch row for a SERVICE_TASK directly after
  # START; completing "ct" (done in `scenario/2`, before any race) arms it.
  defp child_graph(:service) do
    svc = Fx.service_graph([])["nodes"] |> Enum.find(&(&1["id"] == "svc"))

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ct", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        svc,
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ct"},
        %{"id" => "e2", "source" => "ct", "target" => "svc"},
        %{"id" => "e3", "source" => "svc", "target" => "end"}
      ]
    }
  end

  defp parent_graph(child_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "sp"},
        %{"id" => "e2", "source" => "sp", "target" => "end"}
      ]
    }
  end

  # Parent `start -> sp -> end`, its running child (HUMAN or HTTP SERVICE node), and the two
  # closures: `complete` (the child's completion, D) and `cancel` (the parent's cancel, C).
  defp scenario(base, path) do
    child_def = Fx.activate!(base.schema, base.user, child_graph(path))
    parent_def = Fx.activate!(base.schema, base.user, parent_graph(child_def.name))

    {:ok, %{instance_id: parent_id}} =
      Engine.create(
        %{
          definition_id: parent_def.id,
          initial_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("cc-start")
        },
        prefix: base.schema
      )

    child =
      Repo.one!(from(p in InstanceProjection, where: p.parent_instance_id == ^parent_id),
        prefix: base.schema
      )

    {complete, dispatch_id} =
      case family(path) do
        :human ->
          task = Fx.pending_task!(base.schema, child.instance_id)

          {fn ->
             Engine.complete_task(
               task.id,
               %{
                 output_variables: %{},
                 actor_id: base.user.id,
                 idempotency_key: Fx.unique("cc-complete")
               },
               prefix: base.schema
             )
           end, nil}

        :service ->
          ct = Fx.pending_task!(base.schema, child.instance_id)

          assert {:ok, _} =
                   Engine.complete_task(
                     ct.id,
                     %{
                       output_variables: %{},
                       actor_id: base.user.id,
                       idempotency_key: Fx.unique("cc-ct")
                     },
                     prefix: base.schema
                   )

          dispatch =
            from(d in Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch,
              where: d.instance_id == ^child.instance_id
            )
            |> Repo.one!(prefix: base.schema)
            |> Ecto.Changeset.change(%{status: :advanced})
            |> Repo.update!(prefix: base.schema)

          {fn ->
             Engine.advance_after_service_task_outcome(
               dispatch.id,
               {:advance, %{}},
               Repo,
               base.schema
             )
           end, dispatch.id}
      end

    cancel = fn ->
      Engine.cancel_instance(
        parent_id,
        %{actor_id: base.user.id, idempotency_key: Fx.unique("cc-cancel")},
        prefix: base.schema
      )
    end

    %{
      path: path,
      dispatch_id: dispatch_id,
      parent_id: parent_id,
      child_id: child.instance_id,
      complete: complete,
      cancel: cancel
    }
  end

  # ---- barrier and workers ----------------------------------------------------------------------

  # first/second are :complete or :cancel; the barrier row is held until both are parked.
  defp run(base, path, barrier, order) do
    s = scenario(base, path)

    spec =
      case barrier do
        :child -> {:sequence, s.child_id}
        :parent -> {:sequence, s.parent_id}
        :parent_projection -> {:projection, s.parent_id}
      end

    {first, second} =
      case order do
        :complete_first -> {s.complete, s.cancel}
        :cancel_first -> {s.cancel, s.complete}
      end

    %{first: r1, second: r2} = H.forced_overlap(base.schema, spec, first, second)

    results =
      case order do
        :complete_first -> %{complete: r1, cancel: r2}
        :cancel_first -> %{complete: r2, cancel: r1}
      end

    Map.merge(s, %{results: results})
  end

  # ---- shared end-state assertions ---------------------------------------------------------------

  defp token_statuses(schema, instance_id) do
    TokenRecord
    |> where([t], t.instance_id == ^instance_id)
    |> select([t], t.status)
    |> Repo.all(prefix: schema)
  end

  defp assert_invariants(base, s, expected_cancel_audits) do
    schema = base.schema

    assert Fx.projection!(schema, s.child_id).status == :completed
    assert Fx.instance_events(schema, s.child_id, "EXECUTION_ERROR") == []

    # exactly one completion event for the child's last node, never two
    last_node_event = if s.path == :human, do: "TASK_COMPLETED", else: "SERVICE_TASK_COMPLETED"
    assert [_one] = Fx.instance_events(schema, s.child_id, last_node_event)

    if s.dispatch_id do
      assert Fx.dispatch!(schema, s.dispatch_id).status == :advanced
    end

    assert Fx.dlq_entries(schema) == []
    assert Fx.instance_events(schema, s.parent_id, "EXECUTION_ERROR") == []

    assert length(Fx.audit_rows(schema, "instance.cancel")) == expected_cancel_audits
    assert {:ok, :valid} = Audit.verify_chain(schema)
  end

  defp assert_cancel_won(base, s) do
    schema = base.schema
    assert {:ok, _} = s.results.cancel
    assert {:ok, _} = s.results.complete
    assert Fx.projection!(schema, s.parent_id).status == :cancelled
    assert token_statuses(schema, s.parent_id) == [:cancelled]
    assert Fx.instance_events(schema, s.parent_id, "SUB_PROCESS_COMPLETED") == []
    assert_invariants(base, s, 1)
  end

  defp assert_cascade_won(base, s) do
    schema = base.schema
    assert {:ok, _} = s.results.complete
    assert {:error, {:instance_already_terminal, :completed}} = s.results.cancel
    assert Fx.projection!(schema, s.parent_id).status == :completed
    assert [_one] = Fx.instance_events(schema, s.parent_id, "SUB_PROCESS_COMPLETED")
    assert_invariants(base, s, 0)
  end

  # Continuing child: the parent is cancelled, the child's step committed and the child goes on.
  defp assert_continuing_cancel_won(base, s) do
    schema = base.schema
    assert {:ok, _} = s.results.cancel
    assert {:ok, _} = s.results.complete
    assert Fx.projection!(schema, s.parent_id).status == :cancelled
    assert token_statuses(schema, s.parent_id) == [:cancelled]
    assert Fx.projection!(schema, s.child_id).status == :active
    assert Fx.instance_events(schema, s.parent_id, "SUB_PROCESS_COMPLETED") == []
    assert Fx.instance_events(schema, s.child_id, "EXECUTION_ERROR") == []
    assert Fx.dlq_entries(schema) == []
    assert {:ok, :valid} = Audit.verify_chain(schema)
  end

  # ---- the interleavings -------------------------------------------------------------------------

  describe "HUMAN child completion (H)" do
    test "T1: completion first, cancel second, barrier on the child's sequence row", %{base: base} do
      s = run(base, :human, :child, :complete_first)
      assert_cascade_won(base, s)
    end

    test "T2: cancel first, completion second, barrier on the parent's sequence row", %{
      base: base
    } do
      s = run(base, :human, :parent, :cancel_first)
      assert_cancel_won(base, s)
    end

    test "T6: cancel first (parked on the parent projection row), completion second", %{
      base: base
    } do
      s = run(base, :human, :parent_projection, :cancel_first)
      assert_cancel_won(base, s)
    end
  end

  describe "HTTP service child completion (S)" do
    test "T3: completion first, cancel second, barrier on the parent's sequence row", %{
      base: base
    } do
      s = run(base, :service, :parent, :complete_first)
      assert_cascade_won(base, s)
    end

    test "T4: cancel first, completion second, barrier on the parent's sequence row", %{
      base: base
    } do
      s = run(base, :service, :parent, :cancel_first)
      assert_cancel_won(base, s)
    end

    test "T5: cancel first (parked on the parent projection row), completion second", %{
      base: base
    } do
      s = run(base, :service, :parent_projection, :cancel_first)
      assert_cancel_won(base, s)
    end
  end

  describe "CONTINUING child step (does not complete the child)" do
    test "T7: HUMAN step, cancel parked first on the parent projection row", %{base: base} do
      s = run(base, :human_continuing, :parent_projection, :cancel_first)
      assert_continuing_cancel_won(base, s)
    end

    test "T8: HTTP service step, cancel parked first on the parent projection row", %{base: base} do
      s = run(base, :service_continuing, :parent_projection, :cancel_first)
      assert_continuing_cancel_won(base, s)
    end

    test "T9: two siblings key-share the parent group concurrently; FOR UPDATE would block", %{
      base: base
    } do
      schema = base.schema
      child_def = Fx.activate!(schema, base.user, child_graph(:service_continuing))

      sp = fn id ->
        %{
          "id" => id,
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_def.name}
        }
      end

      parent_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
          sp.("sp1"),
          sp.("sp2"),
          %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "split"},
          %{"id" => "e2", "source" => "split", "target" => "sp1"},
          %{"id" => "e3", "source" => "split", "target" => "sp2"},
          %{"id" => "e4", "source" => "sp1", "target" => "join"},
          %{"id" => "e5", "source" => "sp2", "target" => "join"},
          %{"id" => "e6", "source" => "join", "target" => "end"}
        ]
      }

      parent_def = Fx.legacy_activate!(schema, base.user, parent_graph, [])

      {:ok, %{instance_id: parent_id}} =
        Engine.create(
          %{
            definition_id: parent_def.id,
            initial_variables: %{},
            actor_id: base.user.id,
            idempotency_key: Fx.unique("cc-sib")
          },
          prefix: schema
        )

      children =
        Repo.all(from(p in InstanceProjection, where: p.parent_instance_id == ^parent_id),
          prefix: schema
        )

      assert length(children) == 2

      [child1, child2] = children
      test_pid = self()

      # sibling 1 holds its parent group (key-share) in an open transaction
      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            {:ok, %TokenRecord{}} =
              SubProcess.lock_waiting_parent(Repo, child1.instance_id, schema, :key_share)

            send(test_pid, :sibling_held)

            receive do
              :release -> :ok
            after
              @await_ms -> :ok
            end
          end)
        end)

      on_exit(fn -> send(holder.pid, :release) end)
      assert_receive :sibling_held, 10_000

      try_lock = fn mode ->
        Task.async(fn ->
          try do
            Repo.transaction(fn ->
              Repo.query!("SET LOCAL lock_timeout = '1500ms'")
              SubProcess.lock_waiting_parent(Repo, child2.instance_id, schema, mode)
            end)
          rescue
            error in Postgrex.Error -> {:raised, error}
          end
        end)
        |> Task.await(@await_ms)
      end

      # sibling 2 key-shares the same parent projection while sibling 1 still holds it
      assert {:ok, {:ok, %TokenRecord{}}} = try_lock.(:key_share)

      # control: a FOR UPDATE request on the same group is blocked by it (lock timeout), so this
      # test does discriminate between the two modes
      assert {:raised, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
               try_lock.(:update)

      # the control's 55P03 reaches the telemetry handler; drain it
      assert_receive {:deadlock_detected, %Postgrex.Error{postgres: %{code: :lock_not_available}}}

      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, @await_ms)
    end
  end

  describe "statement order of an uncontended child completion (GH #2695, AC 1)" do
    # The parent projection `FOR UPDATE` comes before the waiting-token `FOR UPDATE`, which comes
    # before the audit chain row (both paths: the `:lock_ancestors` step, which the cascade's own
    # lookup then re-locks). Deterministic: no concurrency, the statement log of one completion.
    for path <- [:human, :service] do
      test "#{path}: parent projection, then waiting token, then the audit chain row", %{
        base: base
      } do
        s = scenario(base, unquote(path))

        {result, queries} = PlatformTenantFixture.capture_repo_queries(s.complete)
        assert {:ok, _} = result

        locks =
          for %{query: sql} = q <- queries, sql =~ "FOR UPDATE" do
            param = q |> Map.get(:params, []) |> List.first() |> H.normalize()

            cond do
              sql =~ "instance_projections" and param == s.parent_id -> :parent_projection
              sql =~ "tokens" and sql =~ "waiting_child_instance_id" -> :waiting_token
              sql =~ "audit_chain_locks" -> :audit_chain
              true -> :other
            end
          end

        index = fn kind -> Enum.find_index(locks, &(&1 == kind)) end

        assert is_integer(index.(:parent_projection)),
               "the parent projection is locked FOR UPDATE"

        assert is_integer(index.(:waiting_token))
        assert index.(:parent_projection) < index.(:waiting_token)

        if unquote(path) == :human do
          assert is_integer(index.(:audit_chain))
          assert index.(:waiting_token) < index.(:audit_chain)
        end
      end
    end
  end

  describe "HUMAN child completion WITH entity_writes (statement trace)" do
    # GH #2704 (decision 0061, change C-P): the parent group is taken right after the pure
    # `:transition` step and BEFORE the entity-type rows (this test used to pin the reverse
    # order, entity-type row first), and both precede the first UPDATE of the child's projection.
    test "the parent group, then the entity-type row, all before the first UPDATE of the child's projection",
         %{base: base} do
      schema = base.schema
      Fx.define_type!(schema, "stock_move", %{})

      child_def =
        Fx.activate!(
          schema,
          base.user,
          Fx.graph([Fx.line("stock_move", %{"label" => %{"const" => "x"}})])
        )

      parent_def = Fx.activate!(schema, base.user, parent_graph(child_def.name))

      {:ok, %{instance_id: parent_id}} =
        Engine.create(
          %{
            definition_id: parent_def.id,
            initial_variables: %{},
            actor_id: base.user.id,
            idempotency_key: Fx.unique("cc-ew")
          },
          prefix: schema
        )

      child =
        Repo.one!(from(p in InstanceProjection, where: p.parent_instance_id == ^parent_id),
          prefix: schema
        )

      task = Fx.pending_task!(schema, child.instance_id)

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Engine.complete_task(
            task.id,
            %{
              output_variables: %{},
              actor_id: base.user.id,
              idempotency_key: Fx.unique("cc-ew-complete")
            },
            prefix: schema
          )
        end)

      assert {:ok, _} = result

      index = fn pred -> Enum.find_index(queries, pred) end
      params = fn q -> q |> Map.get(:params, []) |> Enum.map(&H.normalize/1) end

      # the TYPE's sequence row, not the child's own (which the event appends also lock)
      {:ok, type_id} = Letflow.Entities.EntityTypeInstance.fetch_instance_id("stock_move", schema)

      first_type_row =
        index.(fn q ->
          q.query =~ "instance_sequence" and q.query =~ "FOR UPDATE" and type_id in params.(q)
        end)

      first_parent_lock =
        index.(fn q ->
          q.query =~ "FOR UPDATE" and q.query =~ "instance_projections" and
            parent_id in params.(q)
        end)

      first_child_update =
        index.(fn q ->
          q.query =~ ~r/UPDATE "[^"]+"\."instance_projections"/ and
            child.instance_id in params.(q)
        end)

      assert is_integer(first_type_row) and is_integer(first_parent_lock)
      assert is_integer(first_child_update)
      assert first_parent_lock < first_type_row
      assert first_type_row < first_child_update
    end
  end

  describe "SubProcess.lock_waiting_parent/3 and lock_waiting_parent_chain/3" do
    test "nil for a non-child, the token for a waiting parent, nil once cancelled", %{base: base} do
      s = scenario(base, :human)
      schema = base.schema

      {:ok, result} =
        Repo.transaction(fn ->
          {:ok, none} = SubProcess.lock_waiting_parent(Repo, Ecto.UUID.generate(), schema)
          {:ok, orphan} = SubProcess.lock_waiting_parent(Repo, s.parent_id, schema)
          {:ok, token} = SubProcess.lock_waiting_parent(Repo, s.child_id, schema)
          {:ok, delegate} = SubProcess.find_waiting_parent_token(Repo, s.child_id, schema)
          {none, orphan, token, delegate}
        end)

      assert {nil, nil, %TokenRecord{} = token, %TokenRecord{id: same_id}} = result
      assert token.id == same_id
      assert token.instance_id == s.parent_id
      assert token.status == :waiting

      assert {:ok, _} = s.cancel.()

      assert {:ok, nil} =
               Repo.transaction(fn ->
                 {:ok, t} = SubProcess.lock_waiting_parent(Repo, s.child_id, schema)
                 t
               end)
    end

    test "chain terminates on an A<->B cycle", %{base: base} do
      schema = base.schema
      s = scenario(base, :human)

      # A<->B: the child's own token waits for the parent
      {1, _} =
        Repo.update_all(
          from(t in TokenRecord, where: t.instance_id == ^s.child_id),
          [set: [status: :waiting, waiting_child_instance_id: s.parent_id]],
          prefix: schema
        )

      assert {:ok, {:ok, tokens}} =
               Repo.transaction(fn ->
                 SubProcess.lock_waiting_parent_chain(Repo, s.child_id, schema)
               end)

      assert Enum.map(tokens, & &1.instance_id) == [s.parent_id, s.child_id]
    end

    test "chain terminates on a self-waiting token", %{base: base} do
      schema = base.schema
      s = scenario(base, :human)

      {1, _} =
        Repo.update_all(
          from(t in TokenRecord, where: t.instance_id == ^s.parent_id),
          [set: [waiting_child_instance_id: s.parent_id]],
          prefix: schema
        )

      assert {:ok, {:ok, [token]}} =
               Repo.transaction(fn ->
                 SubProcess.lock_waiting_parent_chain(Repo, s.parent_id, schema)
               end)

      assert token.instance_id == s.parent_id
    end

    test "key-share mode returns the waiting token", %{base: base} do
      s = scenario(base, :human)

      assert {:ok, {:ok, %TokenRecord{} = token}} =
               Repo.transaction(fn ->
                 SubProcess.lock_waiting_parent(Repo, s.child_id, base.schema, :key_share)
               end)

      assert token.instance_id == s.parent_id
    end

    test "chain: a three-level fixture returns the two tokens, nearest first", %{base: base} do
      schema = base.schema
      leaf = Fx.activate!(schema, base.user, Fx.graph([]))

      # START -> HUMAN "mt" -> SUB_PROCESS(leaf) -> END: a child's own initial hop chain spawns
      # no grandchild, so the leaf is created when "mt" completes.
      middle_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "mt", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
          %{
            "id" => "sp",
            "node_type" => "SUB_PROCESS",
            "attributes" => %{"definition_name" => leaf.name}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "mt"},
          %{"id" => "e2", "source" => "mt", "target" => "sp"},
          %{"id" => "e3", "source" => "sp", "target" => "end"}
        ]
      }

      middle = Fx.activate!(schema, base.user, middle_graph)
      top = Fx.activate!(schema, base.user, parent_graph(middle.name))

      {:ok, %{instance_id: top_id}} =
        Engine.create(
          %{
            definition_id: top.id,
            initial_variables: %{},
            actor_id: base.user.id,
            idempotency_key: Fx.unique("cc-chain")
          },
          prefix: schema
        )

      middle_id =
        Repo.one!(
          from(p in InstanceProjection,
            where: p.parent_instance_id == ^top_id,
            select: p.instance_id
          ),
          prefix: schema
        )

      mt = Fx.pending_task!(schema, middle_id)

      assert {:ok, _} =
               Engine.complete_task(
                 mt.id,
                 %{
                   output_variables: %{},
                   actor_id: base.user.id,
                   idempotency_key: Fx.unique("cc-mt")
                 },
                 prefix: schema
               )

      leaf_id =
        Repo.one!(
          from(p in InstanceProjection,
            where: p.parent_instance_id == ^middle_id,
            select: p.instance_id
          ),
          prefix: schema
        )

      assert {:ok, {:ok, tokens}} =
               Repo.transaction(fn ->
                 SubProcess.lock_waiting_parent_chain(Repo, leaf_id, schema)
               end)

      assert Enum.map(tokens, & &1.instance_id) == [middle_id, top_id]
    end
  end
end
