defmodule Letflow.Definitions.PlatformCallWritePathsScanTest do
  @moduledoc """
  The closing scan of the platform-call authority rule (T-2588, "Register a
  tenant" pilot, gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (b)).

  The exploit the security gate showed: the write path of a definition did not
  run the platform-call check on every path -- `create/2` did, `update/3` (PUT
  and PATCH) did not. "One path forgotten" must not be able to come back.

  The scan is an AST scan of the definition context modules, in the form of
  `test/letflow/ledger/credential_callers_test.exs` and
  `test/letflow/entities/handler_writes_callers_test.exs`: every PUBLIC
  function of the definition context that writes a definition row is an entry
  point, and every entry point is classified here.

    * `:graph_write` -- the path stores a graph. It must reach
      `check_platform_call_tenant/2` (the company-tenant rule: one fixed code).
    * `:switch_on` -- the path switches a version ON. It must reach
      `check_platform_calls/3` (the activation fence: the entry's permission in
      the signed activator).
    * `:status_only` -- the path changes the status of a row and can never
      change its graph. The scan proves that mechanically: the atom `:graph`
      does not appear anywhere in the path.

  A NEW entry point -- a public function that writes a definition row and is
  not in the table below -- fails this test, so a forgotten path cannot be
  added quietly.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  @context_files %{
    "Letflow.Definitions" => "lib/letflow/definitions.ex",
    "Letflow.Definitions.ExportImport" => "lib/letflow/definitions/export_import.ex",
    "Letflow.Definitions.Promotion" => "lib/letflow/definitions/promotion.ex"
  }

  # The entry points of the definition write paths, and what each of them must
  # reach. A new public function that writes a definition row must be added
  # here with its class -- and the class is checked below, not trusted.
  @entry_points %{
    {"Letflow.Definitions", :create} => :graph_write,
    {"Letflow.Definitions", :create_owned} => :graph_write,
    {"Letflow.Definitions", :create_with_variable_schemas} => :graph_write,
    {"Letflow.Definitions", :update} => :graph_write,
    {"Letflow.Definitions", :activate} => :switch_on,
    {"Letflow.Definitions", :reactivate} => :switch_on,
    {"Letflow.Definitions", :rollback_definition_version} => :switch_on,
    {"Letflow.Definitions", :deprecate} => :status_only,
    {"Letflow.Definitions", :archive} => :status_only,
    {"Letflow.Definitions", :hard_delete} => :status_only,
    {"Letflow.Definitions.ExportImport", :import} => :graph_write,
    {"Letflow.Definitions.ExportImport", :import_with_variable_schemas} => :graph_write,
    {"Letflow.Definitions.Promotion", :promote_definition} => :switch_on,
    {"Letflow.Definitions.Promotion", :promote_active_definition} => :switch_on,
    {"Letflow.Definitions.Promotion", :apply_review} => :switch_on
  }

  @tenant_check :check_platform_call_tenant
  @activation_check :check_platform_calls

  # ── the AST helpers ──────────────────────────────────────────────────────────

  defp module_ast(path), do: path |> File.read!() |> Code.string_to_quoted!()

  defp aliases_of(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, path}]} = node, acc ->
          {node, Map.put(acc, List.last(path), path)}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  # {fun_name, arity} => body AST, for every def and defp of the module, and
  # the set of the PUBLIC ones.
  defp functions_of(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, %{functions: %{}, public: MapSet.new()}, fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          case head_of(head) do
            {name, arity} ->
              {node,
               %{
                 functions: Map.put(acc.functions, {name, arity}, body),
                 public:
                   if(kind == :def, do: MapSet.put(acc.public, {name, arity}), else: acc.public)
               }}

            _other ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    {acc.functions, acc.public}
  end

  defp head_of({:when, _, [head | _]}), do: head_of(head)
  defp head_of({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp head_of(_other), do: nil

  # The calls of one body: `{:local, name, arity}` and `{:remote, module_path, name, arity}`.
  defp calls_of(ast, aliases) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        # `value |> fun(args)` is `fun(value, args)`: the pipe adds one argument.
        {:|>, _, [_left, {name, _, args}]} = node, acc
        when is_atom(name) and is_list(args) ->
          {node, [{:local, name, length(args) + 1} | acc]}

        {:|>, _, [_left, {{:., _, [{:__aliases__, _, mods}, fun]}, _, args}]} = node, acc
        when is_atom(fun) and is_list(args) ->
          {node, [{:remote, resolve(mods, aliases), fun, length(args) + 1} | acc]}

        {{:., _, [{:__aliases__, _, mods}, fun]}, _, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          {node, [{:remote, resolve(mods, aliases), fun, length(args)} | acc]}

        {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, mods}, fun]}, _, args}, _]}]} = node, acc
        when is_atom(fun) and is_list(args) ->
          {node, [{:remote, resolve(mods, aliases), fun, length(args)} | acc]}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, [{:local, name, length(args)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(calls)
  end

  defp resolve(mods, aliases) do
    case aliases[List.last(mods)] do
      nil -> Enum.join(mods, ".")
      full -> Enum.join(full, ".")
    end
  end

  # Every atom the body mentions: a keyword key (`:graph`), a module alias
  # segment (`:ProcessDefinition`), a function name.
  defp atoms_of(ast) do
    {_ast, atoms} =
      Macro.prewalk(ast, MapSet.new(), fn
        node, acc when is_atom(node) ->
          {node, MapSet.put(acc, node)}

        node, acc ->
          {node, acc}
      end)

    atoms
  end

  # The transitive closure of one function: the calls it reaches and the atoms
  # its body mentions. A call into a module outside the scanned set is a leaf
  # (its own body is not read).
  defp closure({module, name, arity}, modules, seen \\ MapSet.new()) do
    key = {module, name, arity}

    if MapSet.member?(seen, key) do
      %{calls: MapSet.new(), atoms: MapSet.new()}
    else
      seen = MapSet.put(seen, key)
      {functions, _public, aliases} = Map.fetch!(modules, module)

      case Map.get(functions, {name, arity}) do
        nil ->
          %{calls: MapSet.new(), atoms: MapSet.new()}

        body ->
          calls = calls_of(body, aliases)

          Enum.reduce(calls, %{calls: MapSet.new(), atoms: atoms_of(body)}, fn call, acc ->
            nested =
              case call do
                {:local, local_name, local_arity} ->
                  closure({module, local_name, local_arity}, modules, seen)

                {:remote, target, remote_name, remote_arity} ->
                  if Map.has_key?(modules, target) do
                    closure({target, remote_name, remote_arity}, modules, seen)
                  else
                    %{calls: MapSet.new(), atoms: MapSet.new()}
                  end
              end

            %{
              calls: MapSet.union(acc.calls, MapSet.put(nested.calls, call)),
              atoms: MapSet.union(acc.atoms, nested.atoms)
            }
          end)
      end
    end
  end

  defp modules do
    Enum.into(@context_files, %{}, fn {module, path} ->
      ast = module_ast(Path.join(@root, path))
      {functions, public} = functions_of(ast)
      {module, {functions, public, aliases_of(ast)}}
    end)
  end

  # The public functions of a module that write a definition row.
  defp write_entry_points(modules) do
    for {module, {functions, public, _aliases}} <- modules,
        {{name, arity}, _body} <- functions,
        MapSet.member?(public, {name, arity}) do
      reached = closure({module, name, arity}, modules)

      if writes_definition_row?(reached) do
        {module, name}
      end
    end
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # The write of a DEFINITION row: a mutating Repo call in a path that mentions
  # the `ProcessDefinition` schema. A write of another table (the variable
  # schema rows) is not a definition write.
  defp writes_definition_row?(reached) do
    mutating =
      Enum.any?(reached.calls, fn
        {:remote, mods, fun, _arity} ->
          (mods == "Repo" or String.ends_with?(mods, ".Repo")) and
            fun in [:insert, :insert_all, :update_all, :delete, :delete_all]

        _other ->
          false
      end)

    mutating and MapSet.member?(reached.atoms, :ProcessDefinition)
  end

  # ── the tests ─────────────────────────────────────────────────────────────────

  test "every public function that writes a definition row is classified here" do
    found = modules() |> write_entry_points()

    assert MapSet.new(found) == MapSet.new(Map.keys(@entry_points)),
           """
           the definition write entry points changed.

           found (not classified): #{inspect(MapSet.difference(MapSet.new(found), MapSet.new(Map.keys(@entry_points))) |> MapSet.to_list())}
           classified (not found): #{inspect(MapSet.difference(MapSet.new(Map.keys(@entry_points)), MapSet.new(found)) |> MapSet.to_list())}

           A new entry point must be classified here (and reach the check its class demands).
           """
  end

  test "every graph-writing entry point reaches the company-tenant check" do
    modules = modules()

    for {{module, name}, class} <- @entry_points, class == :graph_write do
      reached = closure({module, name, arity_of(modules, module, name)}, modules)

      assert MapSet.member?(reached.calls, {:local, @tenant_check, 2}) or
               MapSet.member?(
                 reached.calls,
                 {:remote, "Letflow.Definitions", @tenant_check, 2}
               ),
             "#{inspect(module)}.#{name} does not reach #{@tenant_check}/2"
    end
  end

  test "every switching-on entry point reaches the activation fence" do
    modules = modules()

    for {{module, name}, class} <- @entry_points, class == :switch_on do
      reached = closure({module, name, arity_of(modules, module, name)}, modules)

      assert MapSet.member?(reached.calls, {:local, @activation_check, 3}) or
               MapSet.member?(
                 reached.calls,
                 {:remote, "Letflow.Definitions", @activation_check, 3}
               ),
             "#{inspect(module)}.#{name} does not reach #{@activation_check}/3"
    end
  end

  test "a status-only entry point can never change the graph" do
    modules = modules()

    for {{module, name}, class} <- @entry_points, class == :status_only do
      reached = closure({module, name, arity_of(modules, module, name)}, modules)

      refute MapSet.member?(reached.atoms, :graph),
             "#{inspect(module)}.#{name} can reach the :graph column -- it is not status-only"
    end
  end

  # The arity of the classified function: the table names the function, the
  # scan resolves its arity from the module itself.
  defp arity_of(modules, module, name) do
    {functions, _public, _aliases} = Map.fetch!(modules, module)

    case Enum.find(functions, fn {{fun_name, _arity}, _body} -> fun_name == name end) do
      {{_fun_name, arity}, _body} -> arity
      nil -> flunk("#{inspect(module)}.#{name} is not defined")
    end
  end
end
