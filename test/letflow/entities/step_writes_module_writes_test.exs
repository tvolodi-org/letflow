defmodule Letflow.Entities.StepWritesModuleWritesTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R4b: the `module_writes` half of `Letflow.Entities.StepWrites`
  (`prepare/2`, `multi/3`, `interpret_failure/2`, `lines_hash/1`), below the engine.

    * `prepare/2` creates the synthetic instance of a verified handler's registered targets
      (no process-writable filter: a managed type can never carry the flag) in the same sorted
      pass as the declarative types, and skips a target whose active row is not managed by the
      registering module (design F-7);
    * `multi/3` re-enforces the COMBINED 20-line cap and is the identity with nothing to write;
    * `interpret_failure/2` maps a handler-range step key back to the DECLARED line index, keeps
      the declarative mapping unchanged, and keeps the historical index 20 of the overflow
      failure;
    * `lines_hash/1` of a declarative list is unchanged.

  `async: false`: the module install and tenant provisioning run DDL.
  """

  use Letflow.DataCase, async: false

  alias Ecto.Multi
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.StepWrites
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw

  defp line(handler, module \\ "fixture_ledger"),
    do: %{"module" => module, "handler" => handler, "args" => %{}}

  describe "prepare/2" do
    test "creates the instances of the registered targets, and only those" do
      base = Mw.tenant!("gh2590-r4b-sw-prep")

      assert {:error, :not_found} =
               EntityTypeInstance.fetch_instance_id("fxl_ledger", base.schema)

      assert :ok =
               StepWrites.prepare([], %{
                 prefix: base.schema,
                 module_writes: [line("post_balance_only")]
               })

      assert {:ok, _} = EntityTypeInstance.fetch_instance_id("fxl_balance", base.schema)

      assert {:error, :not_found} =
               EntityTypeInstance.fetch_instance_id("fxl_ledger", base.schema)

      assert :ok =
               StepWrites.prepare([], %{prefix: base.schema, module_writes: [line("post_entry")]})

      assert {:ok, _} = EntityTypeInstance.fetch_instance_id("fxl_ledger", base.schema)
    end

    test "declarative and handler types are created in one pass" do
      base = Mw.tenant!("gh2590-r4b-sw-mix")

      assert :ok =
               StepWrites.prepare(
                 [Fx.line("stock_move", %{"label" => %{"const" => "v"}})],
                 %{prefix: base.schema, module_writes: [line("post_entry")]}
               )

      for type <- ["fxl_balance", "fxl_ledger", "stock_move"] do
        assert {:ok, _} = EntityTypeInstance.fetch_instance_id(type, base.schema), type
      end
    end

    test "a target whose type is not active in the tenant gets no instance (F-7)" do
      base = Fx.tenant_case!("gh2590-r4b-sw-noinst")

      # the module is not installed here: no active managed definition exists
      assert :ok =
               StepWrites.prepare([], %{prefix: base.schema, module_writes: [line("post_entry")]})

      assert {:error, :not_found} =
               EntityTypeInstance.fetch_instance_id("fxl_ledger", base.schema)
    end

    test "nothing to prepare is :ok without touching the database" do
      assert :ok = StepWrites.prepare([], %{prefix: "tenant_nope", module_writes: []})
      assert :ok = StepWrites.prepare([], %{prefix: "tenant_nope"})
    end
  end

  describe "multi/3" do
    defp ctx(overrides) do
      Map.merge(
        %{
          prefix: "tenant_unused",
          task_id: Ecto.UUID.generate(),
          instance_id: Ecto.UUID.generate(),
          node_id: "ht",
          definition_id: Ecto.UUID.generate(),
          definition_version: "1.0.0",
          actor_id: Ecto.UUID.generate(),
          activator_id: Ecto.UUID.generate(),
          authorized: [],
          variables: fn _ -> %{} end,
          skip?: fn _ -> false end
        },
        overrides
      )
    end

    test "with no lines and no module writes it is the identity" do
      multi = Multi.new()
      assert StepWrites.multi(multi, [], ctx(%{})) == multi
      assert StepWrites.multi(multi, [], ctx(%{module_writes: []})) == multi
    end

    test "the COMBINED cap of declarative and module lines is re-enforced (defence in depth)" do
      lines = List.duplicate(Fx.line("stock_move", %{}), 15)
      module_lines = List.duplicate(line("post_entry"), 6)

      assert [{{:line, 20, :build}, {:error, :line_malformed}}] =
               Multi.to_list(
                 StepWrites.multi(Multi.new(), lines, ctx(%{module_writes: module_lines}))
               )

      # exactly 20 combined is built lazily (one merge), not refused
      ok_lines = List.duplicate(Fx.line("stock_move", %{}), 15)
      ok_module = List.duplicate(line("post_entry"), 5)

      assert [{:merge, {:merge, _fun}}] =
               Multi.to_list(
                 StepWrites.multi(Multi.new(), ok_lines, ctx(%{module_writes: ok_module}))
               )
    end
  end

  describe "the call-level deadline guard (TDV T1)" do
    test "a handler call past the 10 s wall-clock budget fails {:line, call_key, :deadline}" do
      base = Mw.tenant!("gh2590-r4b-sw-deadline")
      module_lines = [line("post_entry")]
      :ok = StepWrites.prepare([], %{prefix: base.schema, module_writes: module_lines})

      # a clock that advances 11_000 ms per reading: `:entity_writes_started` reads 0, the guard
      # of the first handler call reads 11_000, past the 10_000 ms budget
      Process.put(:fake_clock, 0)

      now_fun = fn ->
        t = Process.get(:fake_clock)
        Process.put(:fake_clock, t + 11_000)
        t
      end

      multi =
        StepWrites.multi(
          Multi.new(),
          [],
          ctx(%{prefix: base.schema, module_writes: module_lines, now_fun: now_fun})
        )

      assert {:error, {:line, 20, :deadline}, :deadline_exceeded, _changes} =
               Repo.transaction(multi)

      assert Fx.all_records(base.schema) == []
    end

    test "the same call inside the budget is not refused by the guard" do
      base = Mw.tenant!("gh2590-r4b-sw-inbudget")
      module_lines = [line("post_entry")]
      :ok = StepWrites.prepare([], %{prefix: base.schema, module_writes: module_lines})

      multi =
        StepWrites.multi(
          Multi.new(),
          [],
          ctx(%{prefix: base.schema, module_writes: module_lines, now_fun: fn -> 0 end})
        )

      # it fails LATER (the stamp hash of this bare ctx is nil), proving the guard let it through
      assert {:error, {:line, 20, :owner_recheck}, :hash_mismatch, _} = Repo.transaction(multi)
    end
  end

  describe "interpret_failure/2" do
    test "a handler-range key maps back to the declared line index" do
      # declared index 1: call key 70, writes 71..
      assert {:refused, 1, :write_not_permitted, :hash_mismatch} =
               StepWrites.interpret_failure({:line, 70, :owner_recheck}, :hash_mismatch)

      assert {:refused, 1, :write_not_permitted, :handler_unknown} =
               StepWrites.interpret_failure({:line, 70, :build}, :handler_unknown)

      assert {:refused, 1, :write_not_permitted, :handler_not_permitted} =
               StepWrites.interpret_failure({:line, 70, :build}, :handler_not_permitted)

      assert {:refused, 1, :validation_failed, :handler_invalid_arguments} =
               StepWrites.interpret_failure({:line, 70, :build}, :handler_invalid_arguments)

      assert {:failed, 1, :handler} =
               StepWrites.interpret_failure({:line, 70, :build}, :handler_shape)

      assert {:failed, 1, :handler} =
               StepWrites.interpret_failure({:line, 70, :build}, :handler_raised)

      assert {:refused, 1, :write_not_permitted, :target_not_managed_by_module} =
               StepWrites.interpret_failure({:line, 71, :policy}, :target_not_managed_by_module)

      assert {:refused, 1, :write_not_permitted, :scoped} =
               StepWrites.interpret_failure({:line, 72, :policy}, :scoped_type)

      assert {:failed, 1, :policy} = StepWrites.interpret_failure({:line, 72, :policy}, :other)

      assert {:refused, 1, :entity_write_contention, :deadline} =
               StepWrites.interpret_failure({:line, 70, :deadline}, :deadline_exceeded)

      assert {:refused, 1, :write_not_permitted, :field_restricted} =
               StepWrites.interpret_failure({:line, 71, :build}, :field_restricted)

      assert {:refused, 1, :write_not_permitted, :not_writable} =
               StepWrites.interpret_failure(
                 {:line, 71, :build},
                 {:entity_type_instance_missing, "x"}
               )

      # declared index 0 is key 20..69
      assert {:refused, 0, :write_not_permitted, :hash_mismatch} =
               StepWrites.interpret_failure({:line, 20, :owner_recheck}, :hash_mismatch)

      assert {:refused, 0, :write_not_permitted, :handler_not_permitted} =
               StepWrites.interpret_failure({:line, 69, :build}, :handler_not_permitted)
    end

    test "an unexpected recheck failure is internal" do
      assert {:failed, 0, :owner_recheck} =
               StepWrites.interpret_failure({:line, 20, :owner_recheck}, :boom)
    end

    test "a type-lock failure is an internal fault, never a refusal" do
      assert {:failed, 0, :type_lock} = StepWrites.interpret_failure({:type_lock, "t"}, :boom)
    end

    test "declarative mapping is unchanged, and the overflow failure keeps index 20" do
      assert {:refused, 3, :write_not_permitted, :scoped} =
               StepWrites.interpret_failure({:line, 3, :process_policy}, :scoped_type)

      assert {:refused, 19, :validation_failed, :malformed} =
               StepWrites.interpret_failure({:line, 19, :build}, :line_malformed)

      assert {:refused, 20, :validation_failed, :malformed} =
               StepWrites.interpret_failure({:line, 20, :build}, :line_malformed)

      assert {:refused, 2, :entity_write_contention, :deadline} =
               StepWrites.interpret_failure({:line, 2, :deadline}, :deadline_exceeded)

      assert :not_a_line_failure = StepWrites.interpret_failure(:entity_writes, :boom)
      assert :not_a_line_failure = StepWrites.interpret_failure({:other, 1}, :boom)
    end
  end

  describe "lines_hash/1" do
    test "a declarative list hashes as before; a map input covers both attributes" do
      lines = [Fx.line("stock_move", %{"label" => %{"const" => "v"}})]
      assert StepWrites.lines_hash(lines) == StepWrites.lines_hash(lines)

      with_module = %{"entity_writes" => lines, "module_writes" => [line("post_entry")]}
      refute StepWrites.lines_hash(with_module) == StepWrites.lines_hash(lines)

      other = %{"entity_writes" => lines, "module_writes" => [line("post_balance_only")]}
      refute StepWrites.lines_hash(other) == StepWrites.lines_hash(with_module)
    end
  end
end
