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
  @write_names [:prepare, :validate_lines, :multi, :interpret_failure]
  @forbidden_aliases [:StepWrites, :EntityPortImpl]

  defp lib_files(pattern), do: Path.wildcard(Path.join(@root, pattern))

  test "no engine file names a Letflow.Entities module (docs included)" do
    files = [Path.join(@root, "lib/letflow/engine.ex")] ++ lib_files("lib/letflow/engine/**/*.ex")
    assert length(files) > 10
    assert Enum.filter(files, &(File.read!(&1) =~ ~r/Letflow\.Entities\b/)) == []
  end

  test "EntityPort.impl/0 is the only :entity_port reader in lib/" do
    readers =
      lib_files("lib/**/*.ex")
      |> Enum.filter(&(env_readers(File.read!(&1)) > 0))
      |> Enum.map(&Path.relative_to(&1, @root))

    assert readers == ["lib/letflow/engine/entity_port.ex"]
    assert EntityPort.impl() == Letflow.Entities.EntityPortImpl
  end

  test "the reader scan is AST-based: a multi-line fetch_env! is found" do
    assert env_readers("Application.fetch_env!(
  :letflow,
  :entity_port
)") == 1
    assert env_readers("Application.get_env(:letflow, :entity_port, nil)") == 1
    assert env_readers("Application.fetch_env!(:letflow, :other)") == 0
  end

  test "the adapter implements the behaviour and ScriptReadPort is gone" do
    assert Code.ensure_loaded?(Letflow.Entities.EntityPortImpl)

    behaviours =
      Letflow.Entities.EntityPortImpl.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert EntityPort in behaviours

    callbacks = EntityPort.behaviour_info(:callbacks)
    assert length(callbacks) == 5

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

      assert violations(
               "defmodule F do\n  def f(port, s, r), do: port.interpret_failure(s, r)\nend"
             ) != []

      assert violations("defmodule F do\n  def f, do: EntityPort.impl()\nend") != []
      assert violations("defmodule F do\n  def f, do: Ecto.Multi.new()\nend") == []

      assert violations("defmodule F do\n  def f, do: EntityPort.impl().prefetch(1, 2, 3)\nend") ==
               []
    end
  end

  # Violations (SEC F8 / TDV F3):
  #   * a remote call named prepare/validate_lines/multi whose receiver is NOT a bare alias;
  #   * any alias whose last segment is `StepWrites` or `EntityPortImpl`, however it is spelled
  #     (direct, `alias ..., as: P`, multi-alias);
  #   * any `EntityPort` alias reference beyond the single allowed shape
  #     `EntityPort.impl().prefetch(...)` (one per call) and a plain `alias Letflow.Engine.EntityPort`.
  defp violations(source) do
    ast = Code.string_to_quoted!(source)

    {_, found} =
      Macro.prewalk(ast, [], fn
        {:alias, _, [{:__aliases__, _, segs} | rest]}, acc when segs != [] ->
          last = List.last(segs)

          cond do
            last in @forbidden_aliases ->
              {{:alias_seen, [], []}, [{:alias, last} | acc]}

            last == :EntityPort and rest != [] ->
              {{:alias_seen, [], []}, [{:alias_as, last} | acc]}

            true ->
              {{:alias_seen, [], []}, acc}
          end

        {{:., _, [recv, name]}, _, _args} = node, acc when name in @write_names ->
          if match?({:__aliases__, _, _}, recv),
            do: {node, acc},
            else: {node, [{:write, name} | acc]}

        {:__aliases__, _, segs} = node, acc when is_list(segs) and segs != [] ->
          last = List.last(segs)

          cond do
            last in @forbidden_aliases -> {node, [{:alias, last} | acc]}
            last == :EntityPort -> {node, [:entity_port_ref | acc]}
            true -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    refs = Enum.count(found, &(&1 == :entity_port_ref))
    others = Enum.reject(found, &(&1 == :entity_port_ref))

    if refs > count_prefetch_receivers(ast), do: [:entity_port_ref | others], else: others
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

  defp env_readers(source) do
    {_, n} =
      Macro.prewalk(Code.string_to_quoted!(source), 0, fn
        {{:., _, [{:__aliases__, _, [:Application]}, fun]}, _, [:letflow, :entity_port | _]} =
            node,
        n
        when fun in [:get_env, :fetch_env, :fetch_env!] ->
          {node, n + 1}

        node, n ->
          {node, n}
      end)

    n
  end
end
