defmodule Letflow.Entities.ManagedTypesCallersTest do
  @moduledoc """
  REQ-496 / GH #2530, design `lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §3.5
  and §9 T-34 (widened per SECURITY-REVIEWER advisory 1; spec `test/specs/REQ-496.md`).

  "The owner is identified by caller, never by request data" (AC1/AC2, design D5) rests on WHO can
  hold a `Letflow.Entities.ManagedTypes.Owner`. `mix letflow.check_boundaries` cannot express a
  per-function caller allow-list, so this test pins it over the AST of every `lib/**/*.ex` file:

    * `module_owner(` is called only in `lib/letflow/modules/installs.ex` (and defined in
      `lib/letflow/entities/managed_types.ex`);
    * the `Owner` struct is built (`%Owner{}`, `%ManagedTypes.Owner{}`,
      `%Letflow.Entities.ManagedTypes.Owner{}`, `struct(Owner, ...)`, `struct!(...)`) only in
      `managed_types.ex`;
    * `create_definition/3` is called with anything but the literal `:tenant` only where an owner
      is threaded through from `SolutionPack.install/4` (`solution_pack.ex`), and
      `SolutionPack.install/4` with anything but `:tenant` only in `installs.ex`.

  AST, not grep: a comment or a moduledoc mentioning these names (several do) is not a call.
  Pure file reads, so `async: true`.
  """

  use ExUnit.Case, async: true

  @managed_types "lib/letflow/entities/managed_types.ex"
  @installs "lib/letflow/modules/installs.ex"
  @solution_pack "lib/letflow/definitions/solution_pack.ex"
  @definitions "lib/letflow/entities/definitions.ex"

  defp lib_files do
    "lib/**/*.ex" |> Path.wildcard() |> Enum.sort()
  end

  # Every call node `{name, meta, args}` (local or remote) anywhere in `ast`, as
  # {function_name, receiver_alias_segments_or_nil, args}.
  defp calls(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, segments}, name]}, _, args} = node, acc
        when is_atom(name) and is_list(args) ->
          {node, [{name, segments, args} | acc]}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, [{name, nil, args} | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp owner_alias?({:__aliases__, _, segments}), do: List.last(segments) == :Owner
  defp owner_alias?(_other), do: false

  defp builds_owner?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:%, _, [struct_alias, _fields]} = node, acc ->
          {node, acc or owner_alias?(struct_alias)}

        {:struct, _, [struct_alias | _]} = node, acc ->
          {node, acc or owner_alias?(struct_alias)}

        {:struct!, _, [struct_alias | _]} = node, acc ->
          {node, acc or owner_alias?(struct_alias)}

        {{:., _, [{:__aliases__, _, [:Kernel]}, fun]}, _, [struct_alias | _]} = node, acc
        when fun in [:struct, :struct!] ->
          {node, acc or owner_alias?(struct_alias)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp parsed do
    for path <- lib_files() do
      {path, path |> File.read!() |> Code.string_to_quoted!(file: path)}
    end
  end

  test "lib/ has files to scan (the scan cannot pass vacuously)" do
    files = lib_files()
    assert @managed_types in files
    assert @installs in files
    assert length(files) > 100
  end

  test "module_owner( is called only in installs.ex (defined in managed_types.ex)" do
    callers =
      for {path, ast} <- parsed(),
          Enum.any?(calls(ast), fn {name, _receiver, _args} -> name == :module_owner end),
          do: path

    assert Enum.sort(callers) == Enum.sort([@managed_types, @installs])
  end

  test "the Owner struct is built (literal or struct/2) only in managed_types.ex" do
    builders = for {path, ast} <- parsed(), builds_owner?(ast), do: path
    assert builders == [@managed_types]
  end

  test "create_definition/3 with a non-:tenant owner only in solution_pack.ex, threading install/4's owner" do
    # definitions.ex is excluded: it DEFINES create_definition/3 (its head and @spec look like
    # 3-argument call nodes to the walk) and its only call is the /2 -> :tenant delegate.
    sites =
      for {path, ast} <- parsed(),
          path != @definitions,
          {:create_definition, _receiver, [_attrs, _prefix, owner]} <- calls(ast),
          owner != :tenant,
          uniq: true,
          do: {path, Macro.to_string(owner)}

    assert sites == [{@solution_pack, "owner"}],
           "create_definition/3 called with a non-:tenant owner outside the pack path: " <>
             inspect(sites)
  end

  test "SolutionPack.install/4 with a non-:tenant owner is called only in installs.ex" do
    callers =
      for {path, ast} <- parsed(),
          {:install, receiver, [_doc, _actor, _opts, owner]} <- calls(ast),
          receiver != nil and List.last(receiver) == :SolutionPack,
          owner != :tenant,
          uniq: true,
          do: path

    assert callers == [@installs]
  end
end
