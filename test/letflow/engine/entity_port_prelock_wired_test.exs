defmodule Letflow.Engine.EntityPortPrelockWiredTest do
  @moduledoc """
  GH #2704 (decision 0061 rule 4): the service-path pre-lock of the entity-type rows is wired
  through the entity port, and omitting it from the PRODUCTION adapter cannot go unnoticed.

  `Letflow.Engine.EntityPort.lock_types/4` is an OPTIONAL callback (test doubles that
  `@behaviour` the port keep compiling and fall back to a no-op), so the compiler cannot flag a
  missing adapter function. The guarantee is therefore three explicit pieces:

    * `@impl true` on the production adapter's `lock_types/4` (compile-time arity check);
    * `EntityPort.verify_adapter!/0`, called from `Letflow.Application.start/2`, which raises when
      the configured adapter does not export `lock_types/4`;
    * THIS test: (a) the production adapter exports it and `verify_adapter!` accepts it and
      rejects a stub without it; (b) behaviourally, the real service Multi built through the
      production adapter has a `{:pre_type_lock, type}` step between `:lock_ancestors` and the
      first token-insert step, for a declared line type and for a handler-only target type.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine.EntityPort
  alias Letflow.Entities.EntityPortImpl
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw

  defmodule StubWithoutPrelock do
    @moduledoc false
    # A port implementation that predates the pre-lock: it has the write half but no lock_types/4.
    def multi(multi, _lines, _ctx), do: multi
  end

  describe "the production adapter exports the pre-lock" do
    test "EntityPortImpl exports lock_types/4 and the boot check accepts it" do
      assert Code.ensure_loaded?(EntityPortImpl)
      assert function_exported?(EntityPortImpl, :lock_types, 4)
      assert :ok = EntityPort.verify_adapter!(EntityPortImpl)
      assert :ok = EntityPort.verify_adapter!()
    end

    test "the boot check raises, naming the adapter, for an adapter without it" do
      assert_raise RuntimeError, ~r/StubWithoutPrelock.*lock_types\/4/s, fn ->
        EntityPort.verify_adapter!(StubWithoutPrelock)
      end
    end

    test "the wrapper is the identity for a double without the callback" do
      multi = Ecto.Multi.new()
      assert EntityPort.lock_types(StubWithoutPrelock, multi, [], [], %{prefix: "x"}) == multi
    end
  end

  # Every probe is the real engine path: the service Multi the apply is about to run, captured
  # by the test seam (compiled only when `config :letflow, :engine_test_seams` is true).
  defp service_step_names(ctx) do
    Application.put_env(:letflow, :service_multi_probe, self())
    on_exit(fn -> Application.delete_env(:letflow, :service_multi_probe) end)

    assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "wired"})
    assert_receive {:service_multi_names, names}, 5_000
    names
  end

  # the pre-lock steps sit strictly between :lock_ancestors and the token-insert merge
  defp assert_prelock_between(names, type) do
    ancestors = Enum.find_index(names, &(&1 == :lock_ancestors))
    prelock = Enum.find_index(names, &(&1 == {:pre_type_lock, type}))
    first_merge = Enum.find_index(names, &(&1 == :__merge__))

    assert is_integer(ancestors), "no :lock_ancestors step in #{inspect(names)}"
    # nil would make `prelock < first_merge` vacuously true (Erlang term order: number < atom)
    assert is_integer(first_merge), "no merge step in #{inspect(names)}"
    assert is_integer(prelock), "no {:pre_type_lock, #{inspect(type)}} step in #{inspect(names)}"
    assert ancestors < prelock
    assert prelock < first_merge

    # the pre-lock group is contiguous and directly followed by the first merge, which is the
    # token-insert step (the first merge in the service Multi's code; entity_parent_lock_order_test
    # E0s pins it with the statement trace: type row before the first `tokens` INSERT)
    last_prelock =
      names
      |> Enum.with_index()
      |> Enum.filter(&match?({{:pre_type_lock, _}, _}, &1))
      |> List.last()

    assert Enum.at(names, elem(last_prelock, 1) + 1) == :__merge__
  end

  defmodule FailingPrelockPort do
    @moduledoc false
    # The production adapter, except that the pre-lock's one step fails the way a database fault
    # would (`{:sequence_conflict, _}`).
    @behaviour Letflow.Engine.EntityPort

    @impl true
    defdelegate prefetch(prefix, reads, vars), to: EntityPortImpl
    @impl true
    defdelegate authorize_module_writes(lines, ctx), to: EntityPortImpl
    @impl true
    defdelegate prepare(lines, ctx), to: EntityPortImpl
    @impl true
    defdelegate validate_lines(lines, ctx), to: EntityPortImpl
    @impl true
    defdelegate multi(multi, lines, ctx), to: EntityPortImpl
    @impl true
    defdelegate interpret_failure(step, reason), to: EntityPortImpl

    @impl true
    def lock_types(multi, _lines, _module_lines, _ctx),
      do: Ecto.Multi.error(multi, {:pre_type_lock, "stock_move"}, {:sequence_conflict, :boom})
  end

  describe "a failed pre-lock step (SEC L1)" do
    test "the port maps it like a failed type lock: an internal fault, never a refusal" do
      assert {:failed, 0, :type_lock} =
               Letflow.Entities.StepWrites.interpret_failure(
                 {:pre_type_lock, "stock_move"},
                 {:sequence_conflict, :boom}
               )
    end

    test "the service apply lands it as an entity_write_failed ERROR + one DLQ entry" do
      ctx =
        Fx.service_case!(
          "gh2704-wire-f",
          Fx.service_then_human_graph([Fx.line("stock_move", %{"label" => %{"const" => "x"}})])
        )

      previous = Application.fetch_env!(:letflow, :entity_port)
      Application.put_env(:letflow, :entity_port, FailingPrelockPort)
      on_exit(fn -> Application.put_env(:letflow, :entity_port, previous) end)

      # the failed step is interpreted by the port instead of leaking as a bare reason
      Fx.apply_http(ctx, %{})

      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "entity_write_failed"
      assert Fx.all_records(ctx.schema) == []
    end
  end

  describe "the service Multi built through the production adapter" do
    test "a declared line type is pre-locked right after :lock_ancestors" do
      ctx =
        Fx.service_case!(
          "gh2704-wire",
          Fx.service_then_human_graph([Fx.line("stock_move", %{"label" => %{"const" => "x"}})])
        )

      names = service_step_names(ctx)
      assert_prelock_between(names, "stock_move")
    end

    test "E6 shape: a handler-only target type is pre-locked as well (the union)" do
      ctx = Mw.service_case!("gh2704-wire-h", :svc_module)
      names = service_step_names(ctx)

      # no declared line: both registered targets of post_entry are reached only by the handler,
      # and are locked in ascending order
      assert_prelock_between(names, "fxl_balance")
      assert_prelock_between(names, "fxl_ledger")

      assert Enum.find_index(names, &(&1 == {:pre_type_lock, "fxl_balance"})) <
               Enum.find_index(names, &(&1 == {:pre_type_lock, "fxl_ledger"}))
    end

    test "a completion without an entity plan adds no pre-lock step" do
      ctx = Fx.service_case!("gh2704-wire-n", Fx.service_then_human_graph([]))
      names = service_step_names(ctx)
      refute Enum.any?(names, &match?({:pre_type_lock, _}, &1))
    end
  end
end
