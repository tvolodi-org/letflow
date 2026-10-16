defmodule Letflow.Definitions.CreateOwnedCallersTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R2 (design `lib/letflow/design/gh2590-req501-module-write-handlers.md`
  4.8, scan H5): `Letflow.Definitions.create_owned/3` is the only function that writes the
  module ownership stamp of a process definition. Its callers are pinned statically.

  Pure AST over `lib/**/*.ex` and `test/support/**/*.ex` (`test/**/*.exs` is excluded, as in
  the sibling caller scans). A call is a remote call `X.create_owned(...)`, a capture
  `&X.create_owned/3`, or `apply/3` / `Kernel.apply/3` naming the atom `:create_owned`.
  Accepted limit, same as the sibling scans: a function name built at run time is not seen.

  Allowed: `lib/letflow/definitions/solution_pack.ex` (called from
  `Letflow.Modules.Installs` through `SolutionPack.install/4`). R4a's
  `handler_writes_callers_test.exs` may fold this rule in.
  """

  use ExUnit.Case, async: true

  @allowed ["lib/letflow/definitions/solution_pack.ex"]

  defp files do
    (Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/support/**/*.ex")) |> Enum.sort()
  end

  # Names of the lines (or :hit markers) of every create_owned call form in `source`.
  @spec call_sites(String.t()) :: [non_neg_integer()]
  defp call_sites(source) do
    {:ok, ast} = Code.string_to_quoted(source, columns: false)

    {_ast, hits} =
      Macro.prewalk(ast, [], fn
        # X.create_owned(...) and &X.create_owned/3 (the dot node carries the name)
        {{:., meta, [_receiver, :create_owned]}, _call_meta, _args} = node, acc ->
          {node, [Keyword.get(meta, :line, 0) | acc]}

        # apply(Mod, :create_owned, args) / Kernel.apply(...)
        {:apply, meta, [_mod, :create_owned, _args]} = node, acc ->
          {node, [Keyword.get(meta, :line, 0) | acc]}

        {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, meta, [_mod, :create_owned, _args]} =
            node,
        acc ->
          {node, [Keyword.get(meta, :line, 0) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(hits)
  end

  defp offenders(file_sources) do
    for {path, source} <- file_sources,
        path not in @allowed,
        call_sites(source) != [],
        do: path
  end

  test "create_owned/3 is called only from solution_pack.ex" do
    sources = Enum.map(files(), &{&1, File.read!(&1)})
    assert offenders(sources) == []
  end

  test "the scan is not vacuous: solution_pack.ex is seen calling it, and files are scanned" do
    assert length(files()) > 100
    assert call_sites(File.read!("lib/letflow/definitions/solution_pack.ex")) != []
  end

  describe "non-vacuity on synthetic sources" do
    test "a remote call, a capture and apply/3 are each flagged" do
      for snippet <- [
            "defmodule A do\n  def f(a, o), do: Letflow.Definitions.create_owned(a, [], o)\nend",
            "defmodule A do\n  def f, do: &Letflow.Definitions.create_owned/3\nend",
            "defmodule A do\n  def f(a), do: apply(Letflow.Definitions, :create_owned, a)\nend",
            "defmodule A do\n  alias Letflow.Definitions\n  def f(a, o) do\n    a |> Definitions.create_owned([], o)\n  end\nend"
          ] do
        assert call_sites(snippet) != [], snippet
      end
    end

    test "an unrelated call is not flagged" do
      assert call_sites("defmodule A do\n  def f(a), do: Letflow.Definitions.create(a, [])\nend") ==
               []
    end
  end
end
