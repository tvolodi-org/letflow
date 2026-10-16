defmodule Letflow.Engine.ModuleWriteLockOrderTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R4b (design 6.1 M2, 6.2, D-R.7, section 11 row "Handler runs inside the
  step Multi with the D3 lock order"): a completion of a node with `module_writes` takes the
  `instance_sequences` row of EVERY type it may write (the ascending union of the declarative
  types and the handlers' registered targets) BEFORE any write step, whatever the order in which
  the lines are declared or the handler writes.

  Runs in Sandbox `:auto` mode (real commits, real parallel connections), bounded exactly like
  `entity_writes_lock_order_test.exs`: at most two concurrent completions per round and three
  rounds, every wait has a timeout, no busy loop.

    * the step list of the built Multi lists the `{:type_lock, _}` steps ascending, right after
      `:entity_writes_started` and before every `{:line, _, _}` step;
    * the statement log of ONE completion lists the type rows ascending although their instance
      ids sort the OTHER way (a "sort by instance id" mutant would fail);
    * a node without `module_writes` builds NO type-lock step (byte-identical step names);
    * a mixed node and a module-only node completing in parallel finish with no raw `40P01`; a
      contention victim commits nothing and its retry succeeds.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Entities.EntityPortImpl
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  @contention {:error, {:entity_write_refused, :contention, :entity_write_contention}}

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    %{base: Mw.committed_tenant!("gh2590-r4b-lock")}
  end

  defp start(base, process_key) do
    definition = Mw.activate_installed!(base.schema, base.user, process_key)
    {instance_id, task} = Fx.start!(base.schema, definition)

    %{
      schema: base.schema,
      user: base.user,
      instance_id: instance_id,
      task: task,
      definition: definition
    }
  end

  defp node_lines(definition) do
    node = Enum.find(definition.graph["nodes"], &(&1["id"] == "ht"))
    {node["attributes"]["entity_writes"] || [], node["attributes"]["module_writes"] || []}
  end

  # The step names of the inner Multi `StepWrites.multi/3` builds lazily for the case's node.
  defp inner_step_names(ctx) do
    {lines, module_lines} = node_lines(ctx.definition)
    :ok = EntityPortImpl.prepare(lines, %{prefix: ctx.schema, module_writes: module_lines})

    multi_ctx = %{
      prefix: ctx.schema,
      task_id: ctx.task.id,
      instance_id: ctx.instance_id,
      node_id: "ht",
      definition_id: ctx.definition.id,
      definition_version: ctx.definition.version,
      actor_id: ctx.user.id,
      activator_id: ctx.user.id,
      authorized: [{"stock_move", "create"}],
      variables: fn _changes -> %{"label" => "L1"} end,
      skip?: fn _changes -> false end,
      module_writes: module_lines,
      owner: nil,
      entity_write_count: length(lines)
    }

    [{:merge, {:merge, fun}}] =
      Multi.new() |> EntityPortImpl.multi(lines, multi_ctx) |> Multi.to_list()

    fun.(%{}) |> Multi.to_list() |> Enum.map(&elem(&1, 0))
  end

  describe "the built steps" do
    test "type locks ascending, directly after :entity_writes_started, before every line step",
         %{base: base} do
      ctx = start(base, "fxl_post_mixed")
      names = inner_step_names(ctx)

      assert hd(names) == :entity_writes_started

      locks = for {:type_lock, type} <- names, do: type
      assert locks == ["fxl_balance", "fxl_ledger", "stock_move"]

      first_line = Enum.find_index(names, &match?({:line, _, _}, &1))
      last_lock = Enum.find_index(names, &match?({:type_lock, _}, &1))
      assert last_lock < first_line

      assert Enum.take(names, 4) == [
               :entity_writes_started,
               {:type_lock, "fxl_balance"},
               {:type_lock, "fxl_ledger"},
               {:type_lock, "stock_move"}
             ]

      # declarative line (index 0) first, then the handler call (declared index 1, key 70)
      line_keys = for {:line, key, _} <- names, do: key
      assert Enum.min(line_keys) == 0
      assert Enum.sort(line_keys) == line_keys
      assert 70 in line_keys
    end

    test "a node without module_writes builds no type-lock step", %{base: base} do
      Fx.define_type!(base.schema, "stock_note", %{})

      definition =
        Fx.activate!(
          base.schema,
          base.user,
          Fx.graph([Fx.line("stock_move", %{"label" => %{"const" => "v"}})])
        )

      {instance_id, task} = Fx.start!(base.schema, definition)
      ctx = %{schema: base.schema, user: base.user, instance_id: instance_id, task: task}

      assert {:ok, names} =
               Letflow.Engine.__complete_task_multi_step_names__(
                 ctx.task.id,
                 ctx.user.id,
                 ctx.schema
               )

      refute Enum.any?(names, &match?({:type_lock, _}, &1))
    end
  end

  describe "the statement log" do
    test "type rows are locked ascending by type name, not by instance id", %{base: base} do
      ctx = start(base, "fxl_post_mixed")

      # pin the synthetic instance ids to sort OPPOSITE to the type names
      for {type, id} <- [
            {"fxl_balance", "ffffffff-ffff-4fff-8fff-ffffffffffff"},
            {"fxl_ledger", "88888888-8888-4888-8888-888888888888"},
            {"stock_move", "00000000-0000-4000-8000-000000000000"}
          ] do
        %EntityTypeInstance{}
        |> EntityTypeInstance.insert_changeset(%{entity_type: type, instance_id: id})
        |> Repo.insert!(prefix: base.schema)

        %Letflow.EventStore.InstanceProjection{}
        |> Letflow.EventStore.InstanceProjection.insert_changeset(%{
          instance_id: id,
          status: :active,
          definition_id: id
        })
        |> Repo.insert!(prefix: base.schema)
      end

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn -> Fx.complete(ctx, %{"label" => "L1"}) end)

      assert {:ok, _} = result

      locks =
        for %{query: sql} = q <- queries, sql =~ "FOR UPDATE", sql =~ "instance_sequence" do
          q |> Map.get(:params, []) |> List.first() |> normalize()
        end

      position = fn id -> Enum.find_index(locks, &(&1 == id)) end
      balance = position.("ffffffff-ffff-4fff-8fff-ffffffffffff")
      ledger = position.("88888888-8888-4888-8888-888888888888")
      move = position.("00000000-0000-4000-8000-000000000000")

      assert is_integer(balance) and is_integer(ledger) and is_integer(move)
      assert balance < ledger and ledger < move
    end
  end

  defp normalize(param) when is_binary(param) and byte_size(param) == 16,
    do: Ecto.UUID.load!(param)

  defp normalize(param), do: param

  describe "parallel completions" do
    test "a mixed node and a module-only node: no raw 40P01; a victim commits nothing, retry works",
         %{base: base} do
      # sequential warm-up: the FIRST creation of a type's synthetic instance is not the race
      for key <- ["fxl_post_mixed", "fxl_post_module"] do
        assert {:ok, _} = Fx.complete(start(base, key), %{"label" => "warm"})
      end

      for _round <- 1..3 do
        pair = [start(base, "fxl_post_mixed"), start(base, "fxl_post_module")]
        before = length(Fx.all_records(base.schema))

        asyncs =
          Enum.map(pair, fn ctx ->
            {ctx, Task.async(fn -> Fx.complete(ctx, %{"label" => "L1"}) end)}
          end)

        results = Enum.map(asyncs, fn {ctx, task} -> {ctx, Task.await(task, 30_000)} end)

        for {ctx, result} <- results do
          case result do
            {:ok, _} ->
              :ok

            @contention ->
              assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
              assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})

            other ->
              flunk(
                "unexpected result (a raw 40P01 would be :transaction_failed): #{inspect(other)}"
              )
          end
        end

        # mixed: stock_move + ledger + balance (3); module-only: ledger + balance (2)
        assert length(Fx.all_records(base.schema)) == before + 5
      end
    end

    test "a declarative type sorting AFTER the handler targets vs one sorting BEFORE them, released together",
         %{base: base} do
      # stock_move sorts after fxl_*, aaa_move before: the two unions interleave differently
      # with the shared handler targets, and only the ascending union order keeps them apart
      for key <- ["fxl_post_mixed", "fxl_post_mixed_first"] do
        assert {:ok, _} = Fx.complete(start(base, key), %{"label" => "warm"})
      end

      for _round <- 1..3 do
        pair = [start(base, "fxl_post_mixed"), start(base, "fxl_post_mixed_first")]
        before = length(Fx.all_records(base.schema))
        parent = self()

        asyncs =
          Enum.map(pair, fn ctx ->
            task =
              Task.async(fn ->
                send(parent, {:ready, self()})

                receive do
                  :go -> :ok
                after
                  10_000 -> :ok
                end

                Fx.complete(ctx, %{"label" => "L1"})
              end)

            {ctx, task}
          end)

        # barrier: both completions start together
        pids =
          for _ <- 1..2 do
            assert_receive {:ready, pid}, 10_000
            pid
          end

        Enum.each(pids, &send(&1, :go))
        results = Enum.map(asyncs, fn {ctx, task} -> {ctx, Task.await(task, 30_000)} end)

        for {ctx, result} <- results do
          case result do
            {:ok, _} ->
              :ok

            @contention ->
              assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
              assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})

            other ->
              flunk("unexpected result: #{inspect(other)}")
          end
        end

        # each node writes its declarative record plus the handler's ledger and balance
        assert length(Fx.all_records(base.schema)) == before + 6
      end
    end

    test "a real 55P03: a second connection holds a registered target's row; nothing is committed",
         %{base: base} do
      ctx = start(base, "fxl_post_module")
      # create the synthetic instances through a first completion of another instance
      assert {:ok, _} = Fx.complete(start(base, "fxl_post_module"), %{"label" => "warm"})

      ledger_instance =
        Repo.one!(from(i in EntityTypeInstance, where: i.entity_type == "fxl_ledger"),
          prefix: base.schema
        ).instance_id

      schema = base.schema
      test_pid = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!(
              ~s(SELECT 1 FROM "#{schema}"."instance_sequence" WHERE instance_id = $1 FOR UPDATE),
              [Ecto.UUID.dump!(ledger_instance)]
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
      before = length(Fx.all_records(base.schema))

      assert @contention = Fx.complete(ctx, %{"label" => "L1"})
      assert length(Fx.all_records(base.schema)) == before
      assert Fx.task!(base.schema, ctx.task.id).status == :pending

      send(holder.pid, :release)
      Task.await(holder, 30_000)

      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
      assert length(Fx.all_records(base.schema)) == before + 2
    end
  end
end
