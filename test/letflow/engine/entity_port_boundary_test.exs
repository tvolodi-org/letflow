defmodule Letflow.Engine.EntityPortBoundaryTest do
  @moduledoc """
  GH 2587 / REQ-499 PR A3 (design sections 4.1-4.4, 11 A3): the ONE engine-defined entity port.
  Pure file and module reads.

    * the engine names no `Letflow.Entities` module;
    * `EntityPort.impl/0` is the only reader of `:entity_port` in `lib/`;
    * `EntityPortImpl` implements every callback; `ScriptReadPort` is gone;
    * (SEC F8) the script paths (dispatcher and `Letflow.Scripts.*`) call only `prefetch/3` on
      the port.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.EntityPort

  @root Path.expand("../../..", __DIR__)
  @dispatcher "lib/letflow/engine/script_task_dispatcher.ex"
  @write_names [:prepare, :validate_lines, :multi]

  defp lib_files(pattern), do: Path.wildcard(Path.join(@root, pattern))

  test "no engine file names a Letflow.Entities module (docs included)" do
    files = [Path.join(@root, "lib/letflow/engine.ex")] ++ lib_files("lib/letflow/engine/**/*.ex")
    assert length(files) > 10
    assert Enum.filter(files, &(File.read!(&1) =~ ~r/Letflow\.Entities\b/)) == []
  end

  test "EntityPort.impl/0 is the only :entity_port reader in lib/" do
    readers =
      lib_files("lib/**/*.ex")
      |> Enum.filter(&(File.read!(&1) =~ ~r/(get_env|fetch_env!?)\(:letflow, :entity_port/))
      |> Enum.map(&Path.relative_to(&1, @root))

    assert readers == ["lib/letflow/engine/entity_port.ex"]
    assert EntityPort.impl() == Letflow.Entities.EntityPortImpl
  end

  test "the adapter implements the behaviour and ScriptReadPort is gone" do
    assert Code.ensure_loaded?(Letflow.Entities.EntityPortImpl)

    behaviours =
      Letflow.Entities.EntityPortImpl.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert EntityPort in behaviours

    callbacks = EntityPort.behaviour_info(:callbacks)
    assert length(callbacks) == 4

    for {name, arity} <- callbacks do
      assert function_exported?(Letflow.Entities.EntityPortImpl, name, arity), "#{name}/#{arity}"
    end

    refute Code.ensure_loaded?(Letflow.Engine.ScriptReadPort)
    assert EntityPort.applied_event_type() == "TASK_ENTITY_WRITES_APPLIED"
  end

  describe "script paths call only prefetch/3 on the port (SEC F8)" do
    test "the dispatcher and lib/letflow/scripts/** are clean" do
      files =
        [
          @dispatcher
          | Enum.map(lib_files("lib/letflow/scripts/**/*.ex"), &Path.relative_to(&1, @root))
        ]

      assert length(files) > 2

      for file <- files do
        assert violations(File.read!(Path.join(@root, file))) == [], file
      end
    end

    test "the dispatcher does call prefetch (non-vacuous)" do
      assert File.read!(Path.join(@root, @dispatcher)) =~ "EntityPort.impl().prefetch("
    end

    test "synthetic negatives are violations, positives are not" do
      assert violations("defmodule F do\n  def f(port, m, l, c), do: port.multi(m, l, c)\nend") !=
               []

      assert violations("defmodule F do\n  def f, do: EntityPort.impl().prepare([], %{})\nend") !=
               []

      assert violations("defmodule F do\n  def f, do: EntityPort.impl()\nend") != []
      assert violations("defmodule F do\n  def f, do: Ecto.Multi.new()\nend") == []

      assert violations("defmodule F do\n  def f, do: EntityPort.impl().prefetch(1, 2, 3)\nend") ==
               []
    end
  end

  # A remote call named prepare/validate_lines/multi whose receiver is NOT a bare alias, or an
  # `EntityPort.impl()` call that is not the receiver of `prefetch`.
  defp violations(source) do
    ast = Code.string_to_quoted!(source)

    {_, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [recv, name]}, _, _args} = node, acc when name in @write_names ->
          if match?({:__aliases__, _, _}, recv),
            do: {node, acc},
            else: {node, [{:write, name} | acc]}

        {{:., _, [{:__aliases__, _, _}, :impl]}, _, []} = node, acc ->
          {node, [:impl_call | acc]}

        node, acc ->
          {node, acc}
      end)

    impl_calls = Enum.count(found, &(&1 == :impl_call))
    others = Enum.reject(found, &(&1 == :impl_call))

    if impl_calls > count_prefetch_receivers(ast), do: [:impl_call | others], else: others
  end

  defp count_prefetch_receivers(ast) do
    {_, n} =
      Macro.prewalk(ast, 0, fn
        {{:., _, [{{:., _, [{:__aliases__, _, _}, :impl]}, _, []}, :prefetch]}, _, _} = node, n ->
          {node, n + 1}

        node, n ->
          {node, n}
      end)

    n
  end
end
