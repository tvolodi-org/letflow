defmodule Letflow.Engine.ServiceTaskEntityWritesLockOrderTest do
  @moduledoc """
  GH #2587 / REQ-499 PR C2 (design `gh2587-req499-pr-c-service-task-writes.md`, 7.3, tests C-3
  statement half and C-5 service cases).

  Sandbox `:auto` mode (real commits, real parallel connections). Parallelism is bounded (two
  concurrent applies per round); every wait has a timeout; no busy loop.

    * the statement log of ONE service apply: the two `SET LOCAL` statements are the first
      statements of the outer transaction, then the dispatch row, the projection, the type
      sequence rows in ascending type order (lines declared in the opposite order) and the audit
      chain row LAST; no `LOCK TABLE`;
    * an apply of a node WITHOUT lines issues no `SET LOCAL` at all;
    * two applies with line sets (A, B) and (B, A) in parallel both commit (both execute A then
      B, so the second waits at A's type row: no cycle);
    * a real `55P03`: a second connection holds a type's sequence row, the apply gets the
      contention class inside the lock timeout, nothing is committed, and the bounded re-apply
      ends in ERROR + DLQ `entity_write_contention`;
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    base = Fx.committed_tenant_case!("gh2587c-lock")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)

    Fx.define_type!(base.schema, "stock_move", %{})
    Fx.define_type!(base.schema, "stock_note", %{})
    %{base: base}
  end

  defp line(type), do: Fx.line(type, %{"label" => %{"const" => type}})

  defp row_locks(queries) do
    for %{query: sql} = q <- queries, sql =~ "FOR UPDATE" do
      [_, table] = Regex.run(~r/FROM "[^"]+"\."([a-z_]+)"/, sql)
      {table, q |> Map.get(:params, []) |> List.first()}
    end
  end

  defp normalize(param) when is_binary(param) and byte_size(param) == 16,
    do: Ecto.UUID.load!(param)

  defp normalize(param), do: param

  defp type_instance_ids(schema) do
    EntityTypeInstance |> Repo.all(prefix: schema) |> Map.new(&{&1.entity_type, &1.instance_id})
  end

  describe "statement log of one service apply" do
    test "SET LOCAL first; dispatch, projection, type rows ascending, audit chain last", %{
      base: base
    } do
      # declared in the OPPOSITE order of the execution order
      ctx = Fx.attach_service!(base, Fx.service_graph([line("stock_note"), line("stock_move")]))

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn -> Fx.apply_http(ctx, %{}) end)

      assert {:ok, :advanced} = result

      statements = Enum.map(queries, & &1.query)

      # the OUTER transaction's pair (2 s / 5 s; `prepare/2`'s own pair is 2 s / 2 s and runs in
      # its own earlier transaction): consecutive, and before the first row lock of the apply
      set_stmt = Enum.find_index(statements, &(&1 =~ "SET LOCAL statement_timeout = '5s'"))
      assert is_integer(set_stmt)
      assert Enum.at(statements, set_stmt - 1) =~ "SET LOCAL lock_timeout = '2s'"

      refute statements |> Enum.take(set_stmt) |> Enum.any?(&(&1 =~ "FOR UPDATE")),
             "the SET LOCAL pair bounds the dispatch and projection lock waits"

      locks = row_locks(queries)
      tables = Enum.map(locks, &elem(&1, 0))

      assert Enum.take(tables, 2) == ["service_task_dispatches", "instance_projections"]
      refute Enum.any?(queries, &(&1.query =~ ~r/LOCK TABLE/i))

      ids = type_instance_ids(base.schema)

      position = fn type ->
        id = Map.fetch!(ids, type)

        Enum.find_index(locks, fn {table, param} ->
          table == "instance_sequence" and normalize(param) == id
        end)
      end

      move = position.("stock_move")
      note = position.("stock_note")
      assert is_integer(move) and is_integer(note)
      assert move < note

      audit = locks |> Enum.map(&elem(&1, 0)) |> Enum.find_index(&(&1 == "audit_chain_locks"))
      assert is_integer(audit)
      # one chain lock per audited line: every lock from the first on is the chain row
      assert locks
             |> Enum.drop(audit)
             |> Enum.all?(fn {table, _} -> table == "audit_chain_locks" end),
             "the audit chain row is the LAST lock taken"
    end

    test "an apply of a node WITHOUT lines issues no SET LOCAL and no entity lock", %{base: base} do
      ctx = Fx.attach_service!(base, Fx.service_graph([]))

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn -> Fx.apply_http(ctx, %{}) end)

      assert {:ok, :advanced} = result
      refute Enum.any?(queries, &(&1.query =~ "SET LOCAL"))
      refute Enum.any?(row_locks(queries), fn {table, _} -> table == "audit_chain_locks" end)
    end
  end

  describe "parallel applies (A,B) vs (B,A)" do
    test "both commit: sorted execution order, no cycle", %{base: base} do
      first = Fx.attach_service!(base, Fx.service_graph([line("stock_move"), line("stock_note")]))

      second =
        Fx.attach_service!(base, Fx.service_graph([line("stock_note"), line("stock_move")]))

      results =
        [first, second]
        |> Enum.map(fn ctx -> Task.async(fn -> Fx.apply_http(ctx, %{}) end) end)
        |> Enum.map(&Task.await(&1, 30_000))

      assert results == [{:ok, :advanced}, {:ok, :advanced}]
      assert length(Fx.all_records(base.schema)) == 4
      assert Fx.dlq_entries(base.schema) == []
    end
  end

  describe "a real 55P03" do
    test "a second connection holding the type row: contention, nothing committed, bounded, then ERROR",
         %{base: base} do
      # one earlier apply creates the type's sequence row (a row that does not exist cannot be held)
      warmup = Fx.attach_service!(base, Fx.service_graph([line("stock_move")]))
      assert {:ok, :advanced} = Fx.apply_http(warmup, %{})

      ctx = Fx.attach_service!(base, Fx.service_graph([line("stock_move")]))
      # the synthetic per-type instance exists once `prepare/2` ran
      :ok = Letflow.Entities.StepWrites.prepare([line("stock_move")], %{prefix: base.schema})
      type_instance = type_instance_ids(base.schema)["stock_move"]
      schema = base.schema
      test_pid = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!(
              ~s(SELECT 1 FROM "#{schema}"."instance_sequence" WHERE instance_id = $1 FOR UPDATE),
              [Ecto.UUID.dump!(type_instance)]
            )

            send(test_pid, :held)

            receive do
              :release -> :ok
            after
              30_000 -> :ok
            end
          end)
        end)

      assert_receive :held, 10_000

      # 3 attempts x the 2 s lock timeout, zero backoff under the test seam
      assert {:ok, :error_set} = Fx.apply_http(ctx, %{})

      send(holder.pid, :release)
      Task.await(holder, 10_000)

      # only the warm-up apply's record exists
      assert length(Fx.all_records(schema)) == 1
      assert Fx.step_idempotency_count(schema) == 1
      assert Fx.projection!(schema, ctx.instance_id).status == :error
      assert [entry] = Fx.dlq_entries(schema)
      assert entry.error_detail["code"] == "entity_write_contention"
      assert Fx.dispatch!(schema, ctx.dispatch.id).status == "advanced"
    end
  end

  describe "sub-process cascade vs a parent SERVICE apply on the same type" do
    test "the service apply is the parent-side participant: either side may be the victim; nothing partial",
         %{base: base} do
      alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch

      warm_up_types!(base)
      type_instance = type_instance_ids(base.schema)["stock_move"]

      child = Fx.activate!(base.schema, base.user, Fx.graph([line("stock_move")]))

      svc_node =
        Fx.service_graph([line("stock_move")])["nodes"] |> Enum.find(&(&1["id"] == "svc"))

      parent_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
          %{"id" => "h1", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "r"}},
          %{
            "id" => "sp",
            "node_type" => "SUB_PROCESS",
            "attributes" => %{"definition_name" => child.name}
          },
          svc_node,
          %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "split"},
          %{"id" => "e2", "source" => "split", "target" => "h1"},
          %{"id" => "e3", "source" => "split", "target" => "svc"},
          %{"id" => "e4", "source" => "h1", "target" => "sp"},
          %{"id" => "e5", "source" => "sp", "target" => "join"},
          %{"id" => "e6", "source" => "svc", "target" => "join"},
          %{"id" => "e7", "source" => "join", "target" => "end"}
        ]
      }

      parent =
        Fx.legacy_activate!(base.schema, base.user, parent_graph, [{"stock_move", "create"}])

      for _round <- 1..2 do
        {:ok, %{instance_id: parent_id}} =
          Engine.create(
            %{
              definition_id: parent.id,
              initial_variables: %{},
              actor_id: base.user.id,
              idempotency_key: Fx.unique("ew-start")
            },
            prefix: base.schema
          )

        h1 =
          Repo.one!(
            from(t in Letflow.Engine.Task,
              where: t.instance_id == ^parent_id and t.node_id == "h1" and t.status == :pending
            ),
            prefix: base.schema
          )

        complete = fn task ->
          Engine.complete_task(
            task.id,
            %{output_variables: %{}, actor_id: base.user.id, idempotency_key: Fx.unique("k")},
            prefix: base.schema
          )
        end

        assert {:ok, _} = complete.(h1)

        child_instance =
          Repo.one!(
            from(p in Letflow.EventStore.InstanceProjection,
              where: p.parent_instance_id == ^parent_id
            ),
            prefix: base.schema
          )

        child_task = Fx.pending_task!(base.schema, child_instance.instance_id)

        dispatch =
          from(d in ServiceTaskDispatch, where: d.instance_id == ^parent_id)
          |> Repo.one!(prefix: base.schema)
          |> Ecto.Changeset.change(%{status: "advanced"})
          |> Repo.update!(prefix: base.schema)

        before = length(Fx.all_records(base.schema))

        apply_service = fn ->
          Engine.advance_after_service_task_outcome(
            dispatch.id,
            {:advance, %{}},
            Repo,
            base.schema
          )
        end

        # T3: the overlap is FORCED. A second connection holds the type's sequence row; the child
        # completion and the parent service apply are both started and both block there (the
        # child with the parent's projection wanted by its cascade, the service apply holding
        # it), then the row is released. Without the hold the two could finish one after the
        # other and the test would prove nothing.
        holder =
          hold_row(
            ~s(SELECT 1 FROM "#{base.schema}"."instance_sequence" WHERE instance_id = $1 FOR UPDATE),
            [Ecto.UUID.dump!(type_instance)],
            self()
          )

        results = [
          Task.async(fn -> {:child, complete.(child_task)} end),
          Task.async(fn -> {:service, apply_service.()} end)
        ]

        assert wait_for_blocked(2) >= 2, "both transactions must be blocked on the held row"
        send(holder.pid, :release)
        Task.await(holder, 30_000)

        for async <- results do
          case Task.await(async, 30_000) do
            {:child, {:ok, _}} ->
              :ok

            {:child, {:error, {:entity_write_refused, :contention, _}}} ->
              assert Fx.task!(base.schema, child_task.id).status == :pending
              assert {:ok, _} = complete.(child_task)

            {:service, {:ok, :advanced}} ->
              :ok

            {:service, {:ok, :error_set}} ->
              flunk("the service apply must re-apply contention, not land ERROR")

            other ->
              flunk("unexpected result: #{inspect(other)}")
          end
        end

        # one record per line (the child's and the service node's), none partial or duplicated
        assert length(Fx.all_records(base.schema)) == before + 2
        assert Fx.projection!(base.schema, parent_id).status == :completed
      end
    end
  end

  # ---- T2 / T3 / T5 additions ------------------------------------------------------------------

  defp warm_up_types!(base) do
    # the first creation of a type's synthetic instance and sequence row is not part of the races
    warm = Fx.attach_service!(base, Fx.service_graph([line("stock_move"), line("stock_note")]))
    assert {:ok, :advanced} = Fx.apply_http(warm, %{})
  end

  defp hold_row(sql, params, test_pid) do
    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(sql, params)
          send(test_pid, :held)

          receive do
            :release -> :ok
          after
            30_000 -> :ok
          end
        end)
      end)

    assert_receive :held, 10_000
    task
  end

  # Polls pg_stat_activity of this database (bounded: <= 30 x 50 ms, under the 2 s lock_timeout)
  # until at least `n` sessions wait on a lock; returns the last observed count. Scoped to the
  # current database so sibling sessions on a shared cluster are not counted.
  defp wait_for_blocked(n) do
    Enum.reduce_while(1..30, 0, fn _, _ ->
      %{rows: [[waiting]]} =
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
        )

      if waiting >= n do
        {:halt, waiting}
      else
        Process.sleep(50)
        {:cont, waiting}
      end
    end)
  end

  describe "T2: a service apply (A,B) vs a human completion (B,A)" do
    test "both commit, a human victim is retried; overlap is forced in round 1", %{base: base} do
      ba =
        Fx.activate!(base.schema, base.user, Fx.graph([line("stock_note"), line("stock_move")]))

      warm_up_types!(base)
      # warm up the human definition too
      {warm_instance, warm_task} = Fx.start!(base.schema, ba)
      assert warm_instance
      assert {:ok, _} = Fx.complete(%{task: warm_task, user: base.user, schema: base.schema}, %{})

      type_instance = type_instance_ids(base.schema)["stock_move"]

      for round <- 1..2 do
        service =
          Fx.attach_service!(base, Fx.service_graph([line("stock_move"), line("stock_note")]))

        {_instance, task} = Fx.start!(base.schema, ba)
        human = %{task: task, user: base.user, schema: base.schema}
        before = length(Fx.all_records(base.schema))

        holder =
          if round == 1 do
            hold_row(
              ~s(SELECT 1 FROM "#{base.schema}"."instance_sequence" WHERE instance_id = $1 FOR UPDATE),
              [Ecto.UUID.dump!(type_instance)],
              self()
            )
          end

        asyncs = [
          Task.async(fn -> {:service, Fx.apply_http(service, %{})} end),
          Task.async(fn -> {:human, Fx.complete(human, %{})} end)
        ]

        if holder do
          # both blocked at the held type row: the overlap really happened
          assert wait_for_blocked(2) >= 2
          send(holder.pid, :release)
          Task.await(holder, 30_000)
        end

        for async <- asyncs do
          case Task.await(async, 30_000) do
            {:service, {:ok, :advanced}} ->
              :ok

            {:human, {:ok, _}} ->
              :ok

            {:human, {:error, {:entity_write_refused, :contention, _}}} ->
              assert Fx.task!(base.schema, task.id).status == :pending
              assert {:ok, _} = Fx.complete(human, %{})

            other ->
              flunk("unexpected result: #{inspect(other)}")
          end
        end

        assert length(Fx.all_records(base.schema)) == before + 4
        assert Fx.dlq_entries(base.schema) == []
      end
    end
  end

  describe "T2: N-parallel service applies (A,B)" do
    test "four parallel applies all commit", %{base: base} do
      warm_up_types!(base)

      contexts =
        for _ <- 1..4,
            do:
              Fx.attach_service!(base, Fx.service_graph([line("stock_move"), line("stock_note")]))

      before = length(Fx.all_records(base.schema))

      results =
        contexts
        |> Enum.map(fn ctx -> Task.async(fn -> Fx.apply_http(ctx, %{}) end) end)
        |> Enum.map(&Task.await(&1, 60_000))

      assert results == List.duplicate({:ok, :advanced}, 4)
      assert length(Fx.all_records(base.schema)) == before + 8
      assert Fx.dlq_entries(base.schema) == []
    end
  end

  describe "T5: the ERROR landing itself under contention" do
    defp dispatch_row_sql(schema),
      do: ~s(SELECT 1 FROM "#{schema}"."service_task_dispatches" WHERE id = $1 FOR UPDATE)

    test "a contention in the landing transaction is re-run and then lands", %{base: base} do
      ctx = Fx.attach_service!(base, Fx.service_graph([line("stock_move")]))
      holder = hold_row(dispatch_row_sql(base.schema), [Ecto.UUID.dump!(ctx.dispatch.id)], self())

      landing =
        Task.async(fn ->
          Engine.__land_http_entity_write_failure__(
            ctx.dispatch.id,
            :validation_failed,
            0,
            base.schema
          )
        end)

      # attempt 1 waits out the 2 s lock timeout (55P03) and is re-run; release during attempt 2
      Process.sleep(2_600)
      send(holder.pid, :release)
      Task.await(holder, 30_000)

      assert {:ok, :error_set} = Task.await(landing, 30_000)
      assert Fx.projection!(base.schema, ctx.instance_id).status == :error
      assert [_entry] = Fx.dlq_entries(base.schema)
    end

    test "residual (d): a landing that exhausts its budget leaves the instance active and says so",
         %{base: base} do
      ctx = Fx.attach_service!(base, Fx.service_graph([line("stock_move")]))
      holder = hold_row(dispatch_row_sql(base.schema), [Ecto.UUID.dump!(ctx.dispatch.id)], self())

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result =
            Engine.__land_http_entity_write_failure__(
              ctx.dispatch.id,
              :validation_failed,
              0,
              base.schema
            )

          # classified tag, not an opaque :rollback
          assert result == {:error, {:entity_write_landing_failed, :contention}}
        end)

      send(holder.pid, :release)
      Task.await(holder, 30_000)

      assert log =~ "landing failed"
      assert log =~ "reason=contention"
      assert Fx.projection!(base.schema, ctx.instance_id).status == :active
      assert Fx.dispatch!(base.schema, ctx.dispatch.id).status == "advanced"
      assert Fx.dlq_entries(base.schema) == []
    end

    test "two applies racing on a refusing dispatch: one incident, the other is already_final",
         %{base: base} do
      refusing = [
        Fx.line("stock_move", %{"label" => %{"var" => "label"}}),
        Fx.line("stock_note", %{"note" => %{"var" => "note"}})
      ]

      ctx = Fx.attach_service!(base, Fx.service_graph(refusing))
      body = %{"label" => "L1", "note" => "N1"}

      results =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> Fx.apply_http(ctx, body) end) end)
        |> Enum.map(&Task.await(&1, 60_000))

      assert Enum.sort(results) == [{:ok, :already_final}, {:ok, :error_set}]
      assert Fx.projection!(base.schema, ctx.instance_id).status == :error
      assert [_one] = Fx.dlq_entries(base.schema)
      assert [_one] = Fx.instance_events(base.schema, ctx.instance_id, "EXECUTION_ERROR")
    end
  end
end
