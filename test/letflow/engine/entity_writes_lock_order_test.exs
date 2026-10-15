defmodule Letflow.Engine.EntityWritesLockOrderTest do
  @moduledoc """
  GH #2587 / REQ-499 PR B2 (design 7.2, tests B-3 and the real-lock half of B-4; TDV blocker 1).

  Runs in Sandbox `:auto` mode (real commits, real parallel connections), exactly as
  `step_writes_prepare_test.exs` / `engine_concurrency_test.exs` do. Parallelism is bounded:
  at most two concurrent completions per round and at most three rounds; every wait has a
  timeout; no busy loop.

    * the statement log of ONE completion lists the type sequence rows in ascending type
      order (lines declared in the opposite order), after `tasks` and `instance_projections`,
      before the audit chain row and the instance's own sequence row; no `LOCK TABLE`
      (`ScopeNodePaths.lock!/1`, rule 3a, is not called in PR B);
    * `prepare/2` takes no `FOR UPDATE`;
    * completions with line sets (A, B) and (B, A) in parallel finish with no raw `40P01`;
      a contention victim maps to the 503 result, committed nothing, and a retry succeeds;
    * the sub-process cascade (child completion with lines vs parent parallel-branch
      completion with lines on the same type), design 7.2: either side may be the victim,
      nothing is committed for the victim, the retry succeeds;
    * a real `55P03`: a second connection holds the type's sequence row, the completion
      gets the contention result inside the lock timeout, nothing is committed, and a retry
      after release succeeds.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.StepWrites
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  @contention {:error, {:entity_write_refused, :contention, :entity_write_contention}}

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    base = Fx.committed_tenant_case!("gh2587-b2lock")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)

    Fx.define_type!(base.schema, "stock_move", %{})
    Fx.define_type!(base.schema, "stock_note", %{})
    %{base: base}
  end

  defp line(type), do: Fx.line(type, %{"label" => %{"const" => type}})

  defp start(base, definition) do
    {instance_id, task} = Fx.start!(base.schema, definition)
    %{schema: base.schema, user: base.user, instance_id: instance_id, task: task}
  end

  defp record_total(schema), do: length(Fx.all_records(schema))

  # `FOR UPDATE` statements of a captured log as `{table, first_param}`.
  defp row_locks(queries) do
    for %{query: sql} = q <- queries, sql =~ "FOR UPDATE" do
      [_, table] = Regex.run(~r/FROM "[^"]+"\."([a-z_]+)"/, sql)
      {table, q |> Map.get(:params, []) |> List.first()}
    end
  end

  defp pin_instance!(schema, type, id) do
    %Letflow.Entities.EntityTypeInstance{}
    |> Letflow.Entities.EntityTypeInstance.insert_changeset(%{entity_type: type, instance_id: id})
    |> Repo.insert!(prefix: schema)

    %Letflow.EventStore.InstanceProjection{}
    |> Letflow.EventStore.InstanceProjection.insert_changeset(%{
      instance_id: id,
      status: :active,
      definition_id: id
    })
    |> Repo.insert!(prefix: schema)

    :ok
  end

  defp type_instance_ids(schema) do
    EntityTypeInstance
    |> Repo.all(prefix: schema)
    |> Map.new(&{&1.entity_type, &1.instance_id})
  end

  describe "B-3 statement-log lock order" do
    test "type rows ascending, after tasks/projection, before audit chain and own sequence",
         %{base: base} do
      # declared in the OPPOSITE order of the execution order
      definition =
        Fx.activate!(base.schema, base.user, Fx.graph([line("stock_note"), line("stock_move")]))

      ctx = start(base, definition)

      # Pin the synthetic instance ids so they sort OPPOSITE to the type names: a "sort by
      # instance id" mutant would lock stock_note first and fail the assertion below.
      pin_instance!(base.schema, "stock_move", "ffffffff-ffff-4fff-8fff-ffffffffffff")
      pin_instance!(base.schema, "stock_note", "00000000-0000-4000-8000-000000000000")

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn -> Fx.complete(ctx, %{}) end)

      assert {:ok, _} = result
      locks = row_locks(queries)
      tables = Enum.map(locks, &elem(&1, 0))

      assert Enum.take(tables, 2) == ["tasks", "instance_projections"]
      refute Enum.any?(queries, &(&1.query =~ ~r/LOCK TABLE/i)), "rule 3a is not exercised"

      ids = type_instance_ids(base.schema)

      type_lock_positions = fn type ->
        id = Map.fetch!(ids, type)

        Enum.find_index(locks, fn {table, param} ->
          table == "instance_sequence" and normalize(param) == id
        end)
      end

      move = type_lock_positions.("stock_move")
      note = type_lock_positions.("stock_note")
      assert is_integer(move) and is_integer(note)
      assert move < note

      audit = Enum.find_index(locks, fn {table, _} -> table == "audit_chain_locks" end)
      assert is_integer(audit)
      # the instance's own sequence row (the tail events) comes AFTER every entity lock
      own_after_types =
        locks
        |> Enum.with_index()
        |> Enum.filter(fn {{table, param}, _} ->
          table == "instance_sequence" and normalize(param) == ctx.instance_id
        end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.min()

      assert own_after_types > note
      assert audit > note
    end

    test "prepare/2 takes no FOR UPDATE", %{base: base} do
      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          StepWrites.prepare([line("stock_note"), line("stock_move")], %{prefix: base.schema})
        end)

      assert result == :ok
      assert row_locks(queries) == []
    end
  end

  defp normalize(param) when is_binary(param) and byte_size(param) == 16,
    do: Ecto.UUID.load!(param)

  defp normalize(param), do: param

  # A second connection locking the stock_move type sequence row until told to release.
  defp hold_first_type_row(base) do
    type_instance = type_instance_ids(base.schema)["stock_move"]
    schema = base.schema
    test_pid = self()

    task =
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
            20_000 -> :ok
          end
        end)
      end)

    assert_receive :held, 10_000
    task
  end

  # Polls pg_locks (<= 30 x 50 ms, under the 2 s lock_timeout) for a waiting row-lock request.
  defp release_when_waiting(holder) do
    Enum.reduce_while(1..30, nil, fn _, _ ->
      %{rows: [[waiting]]} =
        Repo.query!(
          "SELECT count(*) FROM pg_locks WHERE NOT granted AND locktype IN ('transactionid', 'tuple')"
        )

      if waiting >= 1 do
        {:halt, :ok}
      else
        Process.sleep(50)
        {:cont, nil}
      end
    end)

    send(holder.pid, :release)
    Task.await(holder, 30_000)
  end

  describe "B-3 parallel completions (A,B) vs (B,A)" do
    test "no raw 40P01; a contention victim commits nothing and its retry succeeds",
         %{base: base} do
      ab =
        Fx.activate!(base.schema, base.user, Fx.graph([line("stock_move"), line("stock_note")]))

      ba =
        Fx.activate!(base.schema, base.user, Fx.graph([line("stock_note"), line("stock_move")]))

      # sequential warm-up: the FIRST creation of a type's synthetic instance is not part of
      # the race under test
      for definition <- [ab, ba] do
        assert {:ok, _} = Fx.complete(start(base, definition), %{})
      end

      for round <- 1..3 do
        pair = [start(base, ab), start(base, ba)]
        before = record_total(base.schema)

        # round 1: make the overlap deterministic. A second connection holds the first type's
        # sequence row; both completions are started, and the holder releases only once pg_locks
        # shows a waiting request (bounded poll, no busy loop).
        holder = if round == 1, do: hold_first_type_row(base), else: nil

        asyncs = Enum.map(pair, fn ctx -> {ctx, Task.async(fn -> Fx.complete(ctx, %{}) end)} end)
        if holder, do: release_when_waiting(holder)
        results = Enum.map(asyncs, fn {ctx, task} -> {ctx, Task.await(task, 30_000)} end)

        for {ctx, result} <- results do
          case result do
            {:ok, _} ->
              :ok

            @contention ->
              # nothing committed for the victim, and the retry goes through
              assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
              assert {:ok, _} = Fx.complete(ctx, %{})

            other ->
              flunk(
                "unexpected result (a raw 40P01 would be :transaction_failed): #{inspect(other)}"
              )
          end
        end

        assert record_total(base.schema) == before + 4
      end
    end
  end

  describe "B-3 sub-process cascade vs parallel-branch completion on the same type" do
    test "either side may be the victim; nothing partial; the retry succeeds", %{base: base} do
      child = Fx.activate!(base.schema, base.user, Fx.graph([line("stock_move")]))

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
          %{
            "id" => "p2",
            "node_type" => "HUMAN_TASK",
            "attributes" => %{"role" => "r", "entity_writes" => [line("stock_move")]}
          },
          %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "split"},
          %{"id" => "e2", "source" => "split", "target" => "h1"},
          %{"id" => "e3", "source" => "split", "target" => "p2"},
          %{"id" => "e4", "source" => "h1", "target" => "sp"},
          %{"id" => "e5", "source" => "sp", "target" => "join"},
          %{"id" => "e6", "source" => "p2", "target" => "join"},
          %{"id" => "e7", "source" => "join", "target" => "end"}
        ]
      }

      parent =
        Fx.legacy_activate!(base.schema, base.user, parent_graph, [{"stock_move", "create"}])

      for _round <- 1..2 do
        # two tasks are pending at once (h1 and p2): create directly, not through Fx.start!/2
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

        pending = fn node_id ->
          Repo.one!(
            from(t in Letflow.Engine.Task,
              where:
                t.instance_id == ^parent_id and t.node_id == ^node_id and t.status == :pending
            ),
            prefix: base.schema
          )
        end

        complete_task = fn task ->
          Engine.complete_task(
            task.id,
            %{output_variables: %{}, actor_id: base.user.id, idempotency_key: Fx.unique("k")},
            prefix: base.schema
          )
        end

        # h1 first: it spawns the child instance (sequentially, no race)
        assert {:ok, _} = complete_task.(pending.("h1"))

        child_instance =
          Repo.one!(
            from(p in Letflow.EventStore.InstanceProjection,
              where: p.parent_instance_id == ^parent_id
            ),
            prefix: base.schema
          )

        child_task = Fx.pending_task!(base.schema, child_instance.instance_id)
        p2_task = pending.("p2")
        before = record_total(base.schema)

        results =
          [child_task, p2_task]
          |> Enum.map(fn task -> {task, Task.async(fn -> complete_task.(task) end)} end)
          |> Enum.map(fn {task, async} -> {task, Task.await(async, 30_000)} end)

        for {task, result} <- results do
          case result do
            {:ok, _} ->
              :ok

            @contention ->
              assert Fx.task!(base.schema, task.id).status == :pending
              assert {:ok, _} = complete_task.(task)

            other ->
              flunk("unexpected result: #{inspect(other)}")
          end
        end

        # one record per line, none partial, none duplicated
        assert record_total(base.schema) == before + 2
        assert Fx.projection!(base.schema, parent_id).status == :completed
      end
    end
  end

  describe "B-4 real 55P03" do
    test "a second connection holding the type's sequence row gives the contention result",
         %{base: base} do
      definition =
        Fx.activate!(base.schema, base.user, Fx.graph([line("stock_move")]))

      # warm-up completion creates the synthetic instance and its sequence row
      warm = start(base, definition)
      assert {:ok, _} = Fx.complete(warm, %{})
      before = record_total(base.schema)

      ctx = start(base, definition)
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
              20_000 -> :ok
            end
          end)
        end)

      assert_receive :held, 10_000
      started = System.monotonic_time(:millisecond)
      result = Fx.complete(ctx, %{})
      elapsed = System.monotonic_time(:millisecond) - started
      send(holder.pid, :release)
      Task.await(holder, 30_000)

      assert result == @contention
      assert elapsed < 8_000
      assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
      assert record_total(base.schema) == before

      assert {:ok, _} = Fx.complete(ctx, %{})
      assert record_total(base.schema) == before + 1
    end
  end
end
