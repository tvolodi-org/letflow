defmodule Letflow.TestSupport.SecurityProbe.G02 do
  @moduledoc """
  Pure AST and local call-graph support for the G-02 writer/start-path probe.

  The real tree and the synthetic non-vacuity fixtures use these same functions. The scanner
  normalises pipes, resolves ordinary and renamed aliases, includes captures and literal/dynamic
  `apply/3`, and sees writes through transaction/Multi callback repositories and otherwise-unknown
  repository variables. Documentation and type attributes are excluded, so prose and `Repo.t()` do
  not become inventory entries.

  Deliberate limits: macros defined elsewhere and a non-literal dynamic module/function cannot be
  resolved without executing untrusted code. A literal function applied with `apply/3` keeps its name;
  a computed function is inventoried as `:dynamic`. A computed start option is retained as `:computed`,
  never assumed to be false or true. A read through an otherwise-unknown variable is not assumed to
  be a Repo read; an unknown variable's Repo mutation verb is retained conservatively.

  The option inventory covers every syntactic write of `:module_start`: the `Keyword` verbs, the
  `Map` verbs, `List.keystore/4` and a literal keyword pair, through renamed aliases as well. A
  `module_start` merged from a computed keyword list is not resolvable without executing code and is
  stated as a limit in the class table.
  """

  @repo_mutations ~w(insert insert! insert_all update update! update_all delete delete! delete_all)a
  @multi_mutations @repo_mutations
  @ignored_attributes [
    :moduledoc,
    :doc,
    :typedoc,
    :spec,
    :type,
    :typep,
    :opaque,
    :callback,
    :macrocallback
  ]

  @doc "Scans every Elixir source under lib/ and priv/ without executing it."
  def scan(root \\ File.cwd!()) do
    paths =
      for dir <- ["lib", "priv"],
          path <- Path.wildcard(Path.join([root, dir, "**", "*.{ex,exs}"])),
          do: path |> Path.relative_to(root) |> String.replace("\\", "/")

    paths
    |> Enum.sort()
    |> Enum.map(&scan_source(&1, File.read!(Path.join(root, &1))))
    |> merge_scans()
  end

  @doc "Parses one source file. Synthetic fixtures use the same entry point as the real tree."
  def scan_source(path, source) do
    ast = source |> Code.string_to_quoted!(columns: true) |> executable_ast()

    modules =
      ast
      |> module_asts()
      |> Enum.map(fn {module, body} ->
        body = unpipe(body)
        functions = functions_of(body)
        aliases = aliases_of(body)

        {module,
         %{
           path: path,
           aliases: aliases,
           functions: functions,
           public: public_functions(body),
           options: option_writes(body, path, aliases)
         }}
      end)

    calls = Enum.flat_map(modules, fn {module, data} -> call_records(module, data) end)
    options = Enum.flat_map(modules, fn {_module, data} -> data.options end)
    %{modules: Map.new(modules), calls: calls, options: options, token: make_ref()}
  end

  @doc "Combines independently scanned source files, including synthetic mutations."
  def merge_scans(scans) do
    Enum.reduce(scans, %{modules: %{}, calls: [], options: [], token: make_ref()}, fn scan, acc ->
      %{
        modules: Map.merge(acc.modules, scan.modules),
        calls: acc.calls ++ scan.calls,
        options: acc.options ++ scan.options,
        token: make_ref()
      }
    end)
  end

  @doc "All Repo calls and all Ecto.Multi calls, including reads, transactions and callbacks."
  def repo_inventory(scan) do
    Enum.filter(scan.calls, &(&1.class in [:repo, :multi]))
  end

  @doc "Stable, line-independent rendering: moving a call does not hide an added/removed call."
  def render_repo_inventory(scan_or_calls) do
    calls =
      if is_map(scan_or_calls) and Map.has_key?(scan_or_calls, :calls),
        do: repo_inventory(scan_or_calls),
        else: scan_or_calls

    calls
    |> Enum.map(fn call ->
      {name, arity} = call.caller

      [
        call.path,
        "#{name}/#{arity}",
        to_string(call.class),
        "#{call.target}.#{call.fun}/#{call.arity}",
        to_string(call.form)
      ]
      |> Enum.join(" ")
    end)
    |> Enum.sort()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc "Returns added and missing inventory lines, bounded for a useful assertion failure."
  def inventory_drift(scan_or_calls, expected_text) do
    actual = scan_or_calls |> render_repo_inventory() |> String.split("\n", trim: true)
    expected = String.split(expected_text, "\n", trim: true)

    added = actual -- expected
    missing = expected -- actual

    Enum.map(Enum.take(added, 30), &{:added, &1}) ++
      Enum.map(Enum.take(missing, 30), &{:missing, &1})
  end

  @doc "Public functions in the definition namespace whose transitive local call graph writes."
  def definition_entries(scan) do
    for {module, data} <- scan.modules,
        definition_module?(module),
        {{name, arity}, _bodies} <- data.functions,
        MapSet.member?(data.public, {name, arity}),
        closure = closure(scan, module, name, arity),
        writes_definition_row?(closure),
        do: {module, name, arity}
  end

  @doc "A closed-set mismatch is a failing probe: both new and missing entry points are reported."
  def definition_drift(scan, expected) do
    actual = definition_entries(scan)

    Enum.map(actual -- expected, &{:unclassified, &1}) ++
      Enum.map(expected -- actual, &{:no_longer_a_writer, &1})
  end

  @doc "Recognises direct Repo writes, callback-repo writes and Ecto.Multi write operations."
  def writes_definition_row?(closure) do
    Enum.any?(closure.calls, fn
      {:remote, target, fun, _arity, _form} ->
        (repo_target?(target) and (fun in @repo_mutations or fun == :dynamic)) or
          (multi_target?(target) and (fun in @multi_mutations or fun == :dynamic))

      {:repo_variable, _receiver, fun, _arity, _form} ->
        fun in @repo_mutations

      _other ->
        false
    end)
  end

  defp definition_module?(module) do
    module == "Letflow.Definitions" or String.starts_with?(module, "Letflow.Definitions.")
  end

  @doc "Direct, captured, literal/dynamic apply root and SUB_PROCESS activation call sites."
  def start_calls(scan) do
    Enum.filter(scan.calls, fn call ->
      (call.target == "Letflow.Engine" and
         ((call.fun == :create and call.arity == 2) or call.fun == :dynamic)) or
        (call.target == "Letflow.Engine.SubProcess" and
           ((call.fun == :append_start_multi and call.arity == 7) or
              (call.fun == :prepare_child_activation and call.arity == 4) or
              call.fun == :dynamic))
    end)
  end

  @doc "Start-path identity deliberately excludes line numbers but retains duplicate call sites."
  def start_keys(scan) do
    scan
    |> start_calls()
    |> Enum.map(&{&1.path, &1.target, &1.fun, &1.form})
    |> Enum.sort()
  end

  @doc "Both an unexpected start path and a disappeared reviewed path are drift."
  def start_drift(scan, expected) do
    actual = start_keys(scan)

    Enum.map(actual -- expected, &{:unclassified_start, &1}) ++
      Enum.map(expected -- actual, &{:missing_start, &1})
  end

  @doc """
  True when an entry point's transitive call graph reaches target.fun of any arity.

  A local call carries the module it was written in, so a call to a private function of another
  module (the SUB_PROCESS child gate) is recognised as well as a remote one.
  """
  def reaches_call?(scan, {module, name, arity}, target, fun) do
    closure = closure(scan, module, name, arity)

    Enum.any?(closure.calls, fn
      {:remote, ^target, ^fun, _arity, _form} -> true
      {:local, ^target, ^fun, _arity, _form} -> true
      _other -> false
    end)
  end

  @doc "Public Engine roots that start a root instance or reach a SUB_PROCESS child activation."
  def start_roots(scan) do
    direct =
      if get_in(scan.modules, ["Letflow.Engine", :functions, {:create, 2}]),
        do: [{"Letflow.Engine", :create, 2}],
        else: []

    children =
      case Map.fetch(scan.modules, "Letflow.Engine") do
        {:ok, data} ->
          for {{name, arity}, _bodies} <- data.functions,
              MapSet.member?(data.public, {name, arity}),
              entry = {"Letflow.Engine", name, arity},
              reaches_call?(scan, entry, "Letflow.Engine.SubProcess", :append_start_multi) or
                reaches_call?(
                  scan,
                  entry,
                  "Letflow.Engine.SubProcess",
                  :prepare_child_activation
                ),
              do: entry

        :error ->
          []
      end

    Enum.uniq(direct ++ children)
  end

  @doc """
  Engine start entries that reach neither module-start gate.

  A root instance passes `Letflow.Engine.gate_module_only_start/2`; a SUB_PROCESS child passes
  `Letflow.Engine.SubProcess.refuse_module_only_child/4`. An entry that reaches neither one can
  start an instance without the module-only refusal (the T-2444/T-2588 class).
  """
  def unguarded_start_roots(scan) do
    roots = start_roots(scan)

    root_uncovered = guard_drift(scan, roots, "Letflow.Engine", :gate_module_only_start, :present)

    Enum.filter(root_uncovered, fn {:missing_guard, _target, _fun, entry} ->
      not reaches_call?(scan, entry, "Letflow.Engine.SubProcess", :refuse_module_only_child)
    end)
  end

  @doc "Fail closed on guard absence/partial coverage; :absent also pins deliberate introduction."
  def guard_drift(scan, entries, target, fun, expected_mode)
      when expected_mode in [:absent, :present] do
    covered = Enum.filter(entries, &reaches_call?(scan, &1, target, fun))

    case expected_mode do
      :absent -> Enum.map(covered, &{:unexpected_guard_introduction, target, fun, &1})
      :present -> Enum.map(entries -- covered, &{:missing_guard, target, fun, &1})
    end
  end

  @doc "Every syntactic write of :module_start, with literal and computed values distinguished."
  def module_start_writes(scan) do
    Enum.filter(scan.options, &(&1.key == :module_start))
  end

  @doc "Only reviewed module start files may opt in, and only with the literal boolean true."
  def module_start_violations(scan, allowed_paths) do
    for write <- module_start_writes(scan),
        write.path not in allowed_paths or write.value != :literal_true,
        do: {:unapproved_module_start, write.path, write.form, write.value, write.line}
  end

  defp module_asts(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts}, [do: body]]} = node, acc ->
          {node, [{Enum.join(parts, "."), body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(modules)
  end

  defp executable_ast(ast) do
    Macro.prewalk(ast, fn
      {:@, meta, [{attr, _, _}]} when attr in @ignored_attributes -> {:@, meta, [nil]}
      other -> other
    end)
  end

  defp unpipe(ast) do
    Macro.postwalk(ast, fn
      {:|>, _, [lhs, {{:., _, _} = dot, meta, args}]} when is_list(args) ->
        {dot, meta, [lhs | args]}

      {:|>, _, [lhs, {fun, meta, args}]} when is_atom(fun) and is_list(args) ->
        {fun, meta, [lhs | args]}

      node ->
        node
    end)
  end

  defp aliases_of(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}, opts]} = node, acc when is_list(opts) ->
          name = Keyword.get(opts, :as, {:__aliases__, [], [List.last(parts)]})
          {node, put_alias(acc, name, parts)}

        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), parts)}

        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} = node, acc ->
          acc =
            Enum.reduce(children, acc, fn
              {:__aliases__, _, rest}, aliases -> Map.put(aliases, List.last(rest), base ++ rest)
              _other, aliases -> aliases
            end)

          {node, acc}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp put_alias(acc, {:__aliases__, _, [name]}, parts), do: Map.put(acc, name, parts)
  defp put_alias(acc, _other, _parts), do: acc

  defp functions_of(ast) do
    {_ast, functions} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp, :defmacro, :defmacrop] ->
          case head_of(head) do
            nil ->
              {node, acc}

            {name, arities} ->
              functions =
                Enum.reduce(arities, acc, fn arity, functions ->
                  Map.update(functions, {name, arity}, [body], &(&1 ++ [body]))
                end)

              {node, functions}
          end

        node, acc ->
          {node, acc}
      end)

    functions
  end

  defp public_functions(ast) do
    {_ast, public} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:def, _, [head, _body]} = node, acc ->
          case head_of(head) do
            nil ->
              {node, acc}

            {name, arities} ->
              {node, Enum.reduce(arities, acc, &MapSet.put(&2, {name, &1}))}
          end

        node, acc ->
          {node, acc}
      end)

    public
  end

  defp head_of({:when, _, [head | _]}), do: head_of(head)

  defp head_of({name, _, args}) when is_atom(name) and is_list(args) do
    required =
      Enum.count(args, fn
        {:\\, _, _} -> false
        _other -> true
      end)

    {name, Enum.to_list(required..length(args))}
  end

  defp head_of({name, _, context}) when is_atom(name) and is_atom(context), do: {name, [0]}

  defp head_of(_other), do: nil

  defp remote_call(parts, aliases, fun, arity, form) do
    if Enum.all?(parts, &is_atom/1) do
      resolved = resolve_alias_parts(parts, aliases)
      [{:remote, Enum.join(resolved, "."), fun, arity, form}]
    else
      []
    end
  end

  defp resolve_alias_parts(parts, aliases) do
    case Map.fetch(aliases, hd(parts)) do
      {:ok, base} -> base ++ tl(parts)
      :error -> parts
    end
  end

  defp calls_of(body, aliases) do
    {_ast, calls} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _,
         [{:__aliases__, _, parts}, fun, args]} = node,
        acc
        when is_atom(fun) and is_list(args) ->
          {node, remote_call(parts, aliases, fun, length(args), :apply) ++ acc}

        {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _,
         [{:__aliases__, _, parts}, fun, args]} = node,
        acc
        when not is_atom(fun) and is_list(args) ->
          {node, remote_call(parts, aliases, :dynamic, length(args), :dynamic_apply) ++ acc}

        {:apply, _, [{:__aliases__, _, parts}, fun, args]} = node, acc
        when is_atom(fun) and is_list(args) ->
          {node, remote_call(parts, aliases, fun, length(args), :apply) ++ acc}

        {:apply, _, [{:__aliases__, _, parts}, fun, args]} = node, acc
        when not is_atom(fun) and is_list(args) ->
          {node, remote_call(parts, aliases, :dynamic, length(args), :dynamic_apply) ++ acc}

        {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, parts}, fun]}, _, _}, arity]}]} = node, acc
        when is_atom(fun) and is_integer(arity) ->
          {node, remote_call(parts, aliases, fun, arity, :capture) ++ acc}

        {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          {node, remote_call(parts, aliases, fun, length(args), :call) ++ acc}

        {{:., _, [:erlang, :apply]}, _, [{:__aliases__, _, parts}, fun, args]} = node, acc
        when is_atom(fun) and is_list(args) ->
          {node, remote_call(parts, aliases, fun, length(args), :apply) ++ acc}

        {{:., _, [:erlang, :apply]}, _, [{:__aliases__, _, parts}, fun, args]} = node, acc
        when not is_atom(fun) and is_list(args) ->
          {node, remote_call(parts, aliases, :dynamic, length(args), :dynamic_apply) ++ acc}

        {:&, _, [{:/, _, [{fun, _, context}, arity]}]} = node, acc
        when is_atom(fun) and is_atom(context) and is_integer(arity) ->
          {node, [{:local, fun, arity, :capture} | acc]}

        {fun, _, args} = node, acc when is_atom(fun) and is_list(args) ->
          {node, [{:local, fun, length(args), :call} | acc]}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp call_records(module, data) do
    aliases = data.aliases

    for {caller, bodies} <- data.functions,
        body <- bodies,
        call <- calls_of(body, aliases) ++ variable_repo_calls(body, aliases),
        record = call_record(call, data.path, caller, module),
        record != nil,
        do: record
  end

  defp call_record({:remote, target, fun, arity, form}, path, caller, module) do
    class =
      cond do
        repo_target?(target) -> :repo
        multi_target?(target) -> :multi
        target in ["Letflow.Engine", "Letflow.Engine.SubProcess"] -> :start
        true -> nil
      end

    if class do
      %{
        class: class,
        path: path,
        module: module,
        caller: caller,
        target: target,
        fun: fun,
        arity: arity,
        form: form
      }
    end
  end

  defp call_record({:repo_variable, receiver, fun, arity, form}, path, caller, module) do
    %{
      class: :repo,
      path: path,
      module: module,
      caller: caller,
      target: "$" <> Atom.to_string(receiver),
      fun: fun,
      arity: arity,
      form: form
    }
  end

  defp call_record(_other, _path, _caller, _module), do: nil

  defp variable_repo_calls(body, aliases) do
    callback_repos = callback_repo_variables(body, aliases)

    {_ast, calls} =
      Macro.prewalk(body, [], fn
        {{:., _, [{receiver, _, context}, fun]}, _, args} = node, acc
        when is_atom(receiver) and is_atom(context) and is_atom(fun) and is_list(args) ->
          if repo_variable_call?(receiver, fun, callback_repos),
            do: {node, [{:repo_variable, receiver, fun, length(args), :call} | acc]},
            else: {node, acc}

        {:&, _, [{:/, _, [{{:., _, [{receiver, _, context}, fun]}, _, _}, arity]}]} = node, acc
        when is_atom(receiver) and is_atom(context) and is_atom(fun) and is_integer(arity) ->
          if repo_variable_call?(receiver, fun, callback_repos),
            do: {node, [{:repo_variable, receiver, fun, arity, :capture} | acc]},
            else: {node, acc}

        {:apply, _, [{receiver, _, context}, fun, args]} = node, acc
        when is_atom(receiver) and is_atom(context) and is_atom(fun) and is_list(args) ->
          if repo_variable_call?(receiver, fun, callback_repos),
            do: {node, [{:repo_variable, receiver, fun, length(args), :apply} | acc]},
            else: {node, acc}

        {:apply, _, [{receiver, _, context}, fun, args]} = node, acc
        when is_atom(receiver) and is_atom(context) and not is_atom(fun) and is_list(args) ->
          if known_repo_variable?(receiver, callback_repos),
            do:
              {node, [{:repo_variable, receiver, :dynamic, length(args), :dynamic_apply} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp repo_variable_call?(receiver, fun, callback_repos) do
    known_repo_variable?(receiver, callback_repos) or fun in @repo_mutations
  end

  defp known_repo_variable?(receiver, callback_repos) do
    repo_variable?(receiver) or MapSet.member?(callback_repos, receiver)
  end

  defp callback_repo_variables(body, aliases) do
    {_ast, variables} =
      Macro.prewalk(body, MapSet.new(), fn
        {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          if Enum.all?(parts, &is_atom/1) do
            target = parts |> resolve_alias_parts(aliases) |> Enum.join(".")

            if (fun == :transaction and repo_target?(target)) or
                 (fun == :run and multi_target?(target)) do
              {node, Enum.reduce(callback_parameters(args), acc, &MapSet.put(&2, &1))}
            else
              {node, acc}
            end
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    variables
  end

  defp callback_parameters(args) do
    for {:fn, _, clauses} <- args,
        {:->, _, [[{name, _, context} | _other_parameters], _body]} <- clauses,
        is_atom(name) and is_atom(context),
        do: name
  end

  defp repo_variable?(name) do
    name = name |> Atom.to_string() |> String.trim_leading("_")
    name == "repo" or String.ends_with?(name, "_repo") or name == "repo_mod"
  end

  defp repo_target?(target), do: target |> String.split(".") |> List.last() == "Repo"
  defp multi_target?(target), do: target in ["Multi", "Ecto.Multi"]

  defp atoms_of(body) do
    {_ast, atoms} =
      Macro.prewalk(body, MapSet.new(), fn
        atom, acc when is_atom(atom) -> {atom, MapSet.put(acc, atom)}
        node, acc -> {node, acc}
      end)

    atoms
  end

  defp closure(scan, module, name, arity) do
    scan
    |> reachable_nodes({module, name, arity})
    |> Enum.reduce(%{calls: MapSet.new(), atoms: MapSet.new()}, fn node, acc ->
      {calls, atoms} = node_calls(scan, node)

      %{
        calls: MapSet.union(acc.calls, calls),
        atoms: MapSet.union(acc.atoms, atoms)
      }
    end)
  end

  # The reachable set is a fixpoint over the local call graph: every function the entry point can
  # reach, cycle or not. A node's own calls are memoised per scan, so a large module (the Engine)
  # is walked once instead of once per entry point.
  defp reachable_nodes(scan, root) do
    do_reachable(scan, root, MapSet.new([root]), [root])
  end

  defp do_reachable(_scan, _root, seen, []) do
    seen
  end

  defp do_reachable(scan, root, seen, [current | rest]) do
    {calls, _atoms} = node_calls(scan, current)

    {fresh, seen} =
      Enum.reduce(calls, {[], seen}, fn call, {acc, seen} ->
        case successor(call, current) do
          nil ->
            {acc, seen}

          next ->
            if MapSet.member?(seen, next) do
              {acc, seen}
            else
              {[next | acc], MapSet.put(seen, next)}
            end
        end
      end)

    do_reachable(scan, root, seen, Enum.reverse(fresh) ++ rest)
  end

  defp successor({:local, module, name, arity, _form}, _current), do: {module, name, arity}
  defp successor({:remote, target, name, arity, _form}, _current), do: {target, name, arity}
  defp successor({:repo_variable, _receiver, _fun, _arity, _form}, _current), do: nil

  defp node_calls(scan, node) do
    cache_key = {:g02_node_calls, scan.token}
    cache = Process.get(cache_key, %{})

    case Map.fetch(cache, node) do
      {:ok, value} ->
        value

      :error ->
        value = compute_node_calls(scan.modules, node)
        Process.put(cache_key, Map.put(cache, node, value))
        value
    end
  end

  defp compute_node_calls(modules, {module, name, arity}) do
    case Map.fetch(modules, module) do
      {:ok, data} ->
        bodies = Map.get(data.functions, {name, arity}, [])

        calls =
          Enum.flat_map(bodies, fn body ->
            calls_of(body, data.aliases) ++ variable_repo_calls(body, data.aliases)
          end)

        calls = Enum.map(calls, &qualify_local_call(&1, module))
        atoms = Enum.flat_map(bodies, &atoms_of/1)
        {MapSet.new(calls), MapSet.new(atoms)}

      :error ->
        {MapSet.new(), MapSet.new()}
    end
  end

  # A local call is only meaningful together with the module it was written in.
  defp qualify_local_call({:local, name, arity, form}, module),
    do: {:local, module, name, arity, form}

  defp qualify_local_call(call, _module), do: call

  defp option_writes(ast, path, aliases) do
    {_ast, writes} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, parts}, operation]}, meta, args} = node, acc
        when is_atom(operation) and is_list(args) ->
          if Enum.all?(parts, &is_atom/1) do
            target = parts |> resolve_alias_parts(aliases) |> Enum.join(".")

            case option_call_record(target, operation, args, path, meta) do
              nil -> {node, acc}
              record -> {node, [record | acc]}
            end
          else
            {node, acc}
          end

        {:module_start, value} = node, acc ->
          {node, [option_record(path, :keyword, value, []) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(writes)
  end

  defp option_call_record("Keyword", operation, [_opts, :module_start, value], path, meta)
       when operation in [:put, :put_new, :replace, :replace!] do
    option_record(path, operation, value, meta)
  end

  defp option_call_record("Keyword", :delete, [_opts, :module_start], path, meta) do
    option_record(path, :keyword_delete, :removed, meta)
  end

  defp option_call_record("Map", operation, [_opts, :module_start, value], path, meta)
       when operation in [:put, :put_new, :replace, :replace!] do
    option_record(path, map_option_form(operation), value, meta)
  end

  defp option_call_record("Map", :delete, [_opts, :module_start], path, meta) do
    option_record(path, :map_delete, :removed, meta)
  end

  defp option_call_record("List", :keystore, [_opts, :module_start, _position, value], path, meta) do
    option_record(path, :list_keystore, value, meta)
  end

  defp option_call_record(_target, _operation, _args, _path, _meta), do: nil

  defp map_option_form(:put), do: :map_put
  defp map_option_form(:put_new), do: :map_put_new
  defp map_option_form(:replace), do: :map_replace
  defp map_option_form(:replace!), do: :map_replace!

  defp option_record(path, form, value, meta) do
    value_class =
      case value do
        true -> :literal_true
        false -> :literal_false
        nil -> :literal_nil
        :removed -> :removed
        _other -> :computed
      end

    %{
      path: path,
      key: :module_start,
      form: form,
      value: value_class,
      line: Keyword.get(meta, :line, 0)
    }
  end
end
