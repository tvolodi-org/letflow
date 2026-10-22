defmodule Letflow.Engine.VariableMergeCallersTest do
  @moduledoc """
  T-5 (decision 0062, GH #2616 part 1): a static allow-list over the AST of every `lib/**/*.ex`
  file. `VariableMerge.merge/5` is the only writer of variable labels, so a path that still calls
  the labels-blind `merge/3` would silently drop them. Only `transition.ex` may (its
  empty-incoming probe, which merges nothing); every labelled path calls `merge/5`.

  AST, not grep: a mention in a comment or a doc string is not a call.
  """

  use ExUnit.Case, async: true

  @merge3_callers ["lib/letflow/engine/transition.ex"]
  @merge5_callers [
    "lib/letflow/engine.ex",
    "lib/letflow/engine/reconstruction.ex",
    "lib/letflow/engine/sub_process.ex"
  ]

  defp remote_merge_arities(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

    {_ast, arities} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, aliases}, :merge]}, _, args} = node, acc ->
          if List.last(aliases) == :VariableMerge,
            do: {node, [length(args) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    arities
  end

  defp callers_with_arity(arity) do
    for path <- Enum.sort(Path.wildcard("lib/**/*.ex")),
        arity in remote_merge_arities(path),
        do: path
  end

  test "only transition.ex still calls the labels-blind merge/3" do
    assert callers_with_arity(3) == @merge3_callers
  end

  test "every labelled merge path calls merge/5" do
    assert callers_with_arity(5) == @merge5_callers
  end

  test "the scan sees a real call (non-vacuous)" do
    assert remote_merge_arities("lib/letflow/engine/transition.ex") == [3]
  end
end
