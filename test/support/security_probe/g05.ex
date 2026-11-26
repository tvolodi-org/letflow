defmodule Letflow.TestSupport.SecurityProbe.G05 do
  @moduledoc """
  Pure source scanner for the G-05 audit-writer by caller matrix.

  It parses, rather than executes, `lib/**/*.ex`; normalises pipes and resolves aliases,
  including renamed ones. Every `Letflow.Audit.insert_entry/3` and `append_multi/4` call
  becomes one matrix row with its containing function, actor kind, required attribute set
  and before/after payload shape. Literal maps, local `attrs` variables and simple local
  attribute-builder functions are read statically. An opaque builder stays `:computed`:
  the checked-in matrix must still name its call site, but its field set is not guessed.

  Actor classes are the model on main: the landed `audit_entries.actor_kind` column (T-2588,
  D-0094 decision (d)) is DERIVED by `Audit.insert_entry/3` -- a UUID actor names a person,
  anything else does not -- so a call site that states no kind is not a violation. The probe
  reads the actor each call site supplies and classifies it: nobody, a platform sentinel, a
  person, a non-person, or an actor the caller supplies. A call site that DOES state a kind
  must state a known one, and it must agree with the actor it names.

  ## One aggregate entry point

  `scan_sources/1` is the aggregate: it turns a list of `{path, source}` pairs into the
  matrix rows and the direct writes of those files. The real-tree tests and the synthetic
  non-vacuity cases go through the SAME function, so a rule dropped from the accumulator,
  or neutered inside its own function, fails the synthetic cases instead of passing
  quietly (the convention the sibling G-06 probe states). `violations/1` is that
  aggregate's anti-bypass half and `sources/1` reads the tree it scans.

  ## What a name resolves to

  A module reference is resolved through the aliases in scope -- the module's own aliases
  and the aliases the file declares above it -- and through the `Elixir` root marker, which
  is not part of a module's name. An `import` binds the imported module's functions, so a
  bare `insert_entry/3` in a module that imports `Letflow.Audit` IS a call to the central
  writer and becomes a matrix row.

  ## The anti-bypass half

  Only `Letflow.Audit` may write the tenant's audit chain. The anti-bypass rule refuses an
  `Audit.Entry` struct literal, a call on the audit schema, a bulk write that names the
  audit table (by table name, by schema, through a module attribute or through an
  interpolated name), an `Ecto.Multi` operation that carries the audit schema, and a raw
  `INSERT` into the table. The write is found per function, so a struct literal in another
  function of the same module does not launder it.

  ## Accepted limits

  * A macro, a call through a computed module and a value computed at runtime are not
    evaluated. A remote or computed attribute builder stays `:computed` in the matrix, and
    adding or changing one is matrix drift. This is an audit-writer ratchet, not the
    general secret-taint proof owned by G-04.
  * The exhaustive inventory of every Ecto write verb and of every `Ecto.Multi` operation
    belongs to gap G-02 of the coverage map. The anti-bypass rule refuses the audit chain
    through the verbs it reads (`insert`, `insert_all`, `update`, `update_all`, `delete`,
    `delete_all` and their bang forms) and through `Multi.insert/3` and
    `Multi.insert_all/3`; a verb outside that set is G-02's work.
  * A raw SQL write that names the audit table in a way no literal segment carries (a table
    name built at runtime) is not seen.
  * A bare name that no `alias` binds is resolved against the modules its scope imports,
    because such a name cannot compile otherwise. The rule fires only on code that does
    not compile, and it names the audit schema only when the resulting path ends in the
    schema's own last two segments (`Audit.Entry`).
  * A module reference whose last two segments are `Audit.Entry` is the audit chain's
    schema: the tree holds exactly one such module (`Letflow.Audit.Entry`), which a test
    asserts, so the rule cannot fire on an unrelated schema.
  """

  @writers %{insert_entry: 3, append_multi: 4}
  @required_fields [:actor_id, :action, :resource_type, :resource_id]
  @repo_mutations ~w(insert insert! insert_all update update! update_all delete delete! delete_all)a
  @multi_mutations ~w(insert insert_all)a
  @audit_module "Letflow.Audit"
  @audit_schema "Letflow.Audit.Entry"
  @audit_schema_suffix ["Audit", "Entry"]
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
  @sensitive_exact_keys ~w(authorization password password_hash token access_token
    refresh_token bootstrap_token api_token secret client_secret credential
    credentials set-cookie cookie secret_key_base)
  @sensitive_suffixes ~w(_token _secret _password _credential)

  @doc "The production sources under a root, as `{path, source}` pairs."
  def sources(root \\ File.cwd!()) do
    root
    |> Path.join("lib/**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path -> {relative_path(path, root), File.read!(path)} end)
  end

  @doc """
  The aggregate entry point: the matrix rows and the direct writes of a list of sources.

  The real-tree tests and the synthetic non-vacuity cases go through this one function,
  so a rule that is dropped from the accumulator, or neutered inside its own function,
  fails the synthetic cases instead of passing quietly.
  """
  def scan_sources(sources) do
    files = Enum.map(sources, fn {path, source} -> scan_file(path, source) end)

    %{
      entries: files |> Enum.flat_map(& &1.entries),
      direct_writes: files |> Enum.flat_map(& &1.direct_writes),
      paths: Enum.map(sources, &elem(&1, 0))
    }
  end

  @doc "The anti-bypass violations of a list of sources -- the aggregate's W1 half."
  def violations(sources) do
    sources |> scan_sources() |> direct_writer_violations()
  end

  @doc "The matrix rows of a real tree."
  def scan(root \\ File.cwd!()) do
    root |> sources() |> scan_sources() |> Map.get(:entries)
  end

  @doc "One real or synthetic source file through the same aggregate and the same rules."
  def scan_source(path, source) do
    scan_sources([{path, source}])
  end

  @doc "Returns added and missing matrix lines, capped to keep a failure readable."
  def matrix_drift(entries, expected_text) do
    actual = entries |> render_matrix() |> String.split("\n", trim: true)
    expected = String.split(expected_text, "\n", trim: true)

    Enum.map(Enum.take(actual -- expected, 30), &{:added, &1}) ++
      Enum.map(Enum.take(expected -- actual, 30), &{:missing, &1})
  end

  @doc "Stable rendering: source line movement alone never changes the matrix."
  def render_matrix(entries) do
    entries
    |> Enum.map(fn entry ->
      {name, arity} = entry.caller

      [
        entry.path,
        "#{entry.module}.#{name}/#{arity}##{entry.ordinal}",
        "#{entry.writer}/#{entry.writer_arity}",
        "actor=#{render_actor(entry)}",
        "action=#{entry.action}",
        "fields=#{render_fields(entry.fields)}",
        "before=#{entry.before_payload}",
        "after=#{entry.after_payload}"
      ]
      |> Enum.join(" | ")
    end)
    |> Enum.sort()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc "A literal call-site map must name every field the central writer does not supply."
  def required_field_violations(entries) do
    Enum.flat_map(entries, fn entry ->
      case entry.fields do
        :computed -> []
        fields -> Enum.map(@required_fields -- fields, &{:missing_field, identity(entry), &1})
      end
    end)
  end

  @doc """
  Checks a stated actor kind against the actor the call site supplies.

  The persisted kind is the writer's business (T-2588, D-0094 decision (d): a UUID actor
  names a person, anything else does not), so a call site that states no kind is not a
  violation. A call site that states one must state a known kind, and it must agree with
  the actor: `user` only where the actor names a person, `system` only where it names none.
  """
  def actor_violations(entries) do
    Enum.flat_map(entries, fn entry ->
      explicit = entry.explicit_actor_kind
      class = entry.actor_class

      cond do
        not is_nil(explicit) and explicit not in ["user", "system"] ->
          [{:unknown_actor_kind, identity(entry), explicit}]

        explicit == "user" and class in ["nobody", "sentinel", "non-person", "missing"] ->
          [{:user_kind_without_user_actor, identity(entry)}]

        explicit == "system" and class in ["person", "caller"] ->
          [{:system_kind_with_actor_id, identity(entry)}]

        true ->
          []
      end
    end)
  end

  @doc "Rejects plaintext literal values under sensitive keys in before/after states."
  def payload_violations(entries) do
    Enum.flat_map(entries, fn entry ->
      for field <- [:before_state, :after_state],
          value <- Map.get(entry.payload_values, field, []),
          {key, _value} <- sensitive_literal_values(value),
          do: {:plaintext_payload, identity(entry), field, key}
    end)
  end

  @doc "Only Audit itself may write the audit chain: the Entry schema, a bulk write naming the audit table, or a raw audit row."
  def direct_writer_violations(scan) do
    Enum.map(scan.direct_writes, fn write ->
      {:direct_audit_write, write.path, write.module, write.caller, write.form}
    end)
  end

  @doc "Short identity shared by violation messages and seeded assertions."
  def identity(entry) do
    {name, arity} = entry.caller
    "#{entry.path}:#{entry.module}.#{name}/#{arity}##{entry.ordinal}"
  end

  # ── the scan ────────────────────────────────────────────────────────────────────────────────

  defp scan_file(path, source) do
    ast = source |> Code.string_to_quoted!(columns: true) |> executable_ast() |> unpipe()
    file_aliases = file_aliases_of(ast)

    entries =
      ast
      |> module_asts()
      |> Enum.flat_map(fn {module, body} ->
        scope = scope_of(body, file_aliases)
        functions = functions_of(body)

        Enum.flat_map(functions, &writer_entries(path, module, scope, functions, &1))
      end)
      |> add_ordinals()

    %{entries: entries, direct_writes: direct_writes(ast, path, file_aliases)}
  end

  defp relative_path(path, root) do
    path |> Path.relative_to(root) |> String.replace("\\", "/")
  end

  # ── the scope of a module body ─────────────────────────────────────────────────────────────

  defp scope_of(body, file_aliases) do
    %{
      aliases: Map.merge(file_aliases, aliases_of(body)),
      imports: imports_of(body),
      attributes: attributes_of(body)
    }
  end

  # An alias outside every module binds its short name for the whole file, so a module
  # below it sees the name too.
  defp file_aliases_of(ast) do
    {_ast, {aliases, _depth}} =
      Macro.traverse(
        ast,
        {%{}, 0},
        fn
          {:defmodule, _, [{:__aliases__, _, _parts}, [do: _body]]} = node, {acc, depth} ->
            {node, {acc, depth + 1}}

          {:alias, _, [{:__aliases__, _, parts}, opts]} = node, {acc, depth}
          when depth == 0 and is_list(opts) ->
            {node, {put_alias(acc, parts, opts), depth}}

          {:alias, _, [{:__aliases__, _, parts}]} = node, {acc, depth} when depth == 0 ->
            {node, {put_alias(acc, parts, []), depth}}

          {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} = node,
          {acc, depth}
          when depth == 0 ->
            {node, {put_grouped_aliases(acc, base, children), depth}}

          node, acc ->
            {node, acc}
        end,
        fn
          {:defmodule, _, _} = node, {acc, depth} -> {node, {acc, depth - 1}}
          node, acc -> {node, acc}
        end
      )

    aliases
  end

  defp aliases_of(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}, opts]} = node, acc when is_list(opts) ->
          {node, put_alias(acc, parts, opts)}

        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, put_alias(acc, parts, [])}

        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} = node, acc ->
          {node, put_grouped_aliases(acc, base, children)}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp put_alias(acc, parts, opts) do
    full = join_parts(parts)

    case Keyword.get(opts, :as) do
      nil -> Map.put(acc, List.last(parts), full)
      {:__aliases__, _, alias_parts} -> Map.put(acc, List.last(alias_parts), full)
      _other -> acc
    end
  end

  defp put_grouped_aliases(acc, base, children) do
    Enum.reduce(children, acc, fn
      {:__aliases__, _, rest}, aliases ->
        Map.put(aliases, List.last(rest), join_parts(base ++ rest))

      _other, aliases ->
        aliases
    end)
  end

  # An import binds the imported module's functions, so a bare call to one of them is a
  # call to that module's function.
  defp imports_of(ast) do
    {_ast, imports} =
      Macro.prewalk(ast, [], fn
        {:import, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, [%{parts: parts, include: :all, exclude: []} | acc]}

        {:import, _, [{:__aliases__, _, parts}, opts]} = node, acc when is_list(opts) ->
          {node, [import_entry(parts, opts) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(imports)
  end

  defp import_entry(parts, opts) do
    %{
      parts: parts,
      include: imported_names(Keyword.get(opts, :only)),
      exclude: imported_names(Keyword.get(opts, :except))
    }
  end

  defp imported_names(list) when is_list(list), do: Enum.map(list, fn {name, _arity} -> name end)
  defp imported_names(_other), do: []

  defp imports_function?(import, name) do
    included = import.include == :all or name in import.include
    included and name not in import.exclude
  end

  # A module attribute with a literal value: a table name or a module name.
  defp attributes_of(ast) do
    {_ast, attributes} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          case attribute_literal(value) do
            :none -> {node, acc}
            literal -> {node, Map.put(acc, name, literal)}
          end

        node, acc ->
          {node, acc}
      end)

    attributes
  end

  defp attribute_literal({:__block__, _, [value]}), do: attribute_literal(value)
  defp attribute_literal(value) when is_binary(value), do: value
  defp attribute_literal({:__aliases__, _, parts}), do: {:module, join_parts(parts)}
  defp attribute_literal(_other), do: :none

  # ── name resolution ───────────────────────────────────────────────────────────────────────

  # The canonical path of a module reference, or nil when the name binds nothing in
  # scope. The `Elixir` root marker is not part of a module's name.
  defp resolve_module(parts, scope) do
    parts = strip_root(parts)

    case parts do
      [] ->
        nil

      [first | rest] ->
        case Map.fetch(scope.aliases, first) do
          {:ok, base} -> join_parts([base | rest])
          :error -> if rest == [], do: nil, else: join_parts(parts)
        end
    end
  end

  # A part of a module path is not always an atom: `alias __MODULE__.Foo` names one.
  defp join_parts(parts), do: Enum.map_join(parts, ".", &part_to_string/1)

  defp part_to_string(part) when is_atom(part), do: to_string(part)
  defp part_to_string(part) when is_binary(part), do: part

  defp part_to_string(part),
    do: part |> Macro.to_string() |> String.replace(~r/\s+/, " ")

  defp strip_root([:"Elixir" | rest]), do: strip_root(rest)
  defp strip_root(parts), do: parts

  # The canonical path of a name that no alias binds, resolved against the modules its
  # scope imports: such a name cannot compile otherwise, so the rule is conservative.
  defp candidate_modules(parts, scope) do
    case resolve_module(parts, scope) do
      nil -> imported_namespace_candidates(parts, scope)
      path -> [path]
    end
  end

  defp imported_namespace_candidates([first], scope) when is_atom(first) do
    scope.imports
    |> Enum.map(fn import ->
      case resolve_module(import.parts, scope) do
        nil -> nil
        base -> Enum.join([base, to_string(first)], ".")
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp imported_namespace_candidates(_parts, _scope), do: []

  defp audit_schema_path?(path) do
    path == @audit_schema or audit_schema_suffix?(path)
  end

  defp audit_schema_suffix?(path) do
    path |> String.split(".") |> Enum.take(-2) == @audit_schema_suffix
  end

  # ── the matrix rows ───────────────────────────────────────────────────────────────────────

  defp writer_entries(path, module, scope, functions, function) do
    direct = direct_writer_entries(path, module, scope, functions, function)
    alternate = alternate_writer_entries(path, module, scope, function)
    direct ++ alternate
  end

  defp direct_writer_entries(path, module, scope, functions, function) do
    {_ast, entries} =
      Macro.prewalk(function.body, [], fn
        {{:., _, [{:__aliases__, _, parts}, writer]}, meta, args} = node, acc
        when is_map_key(@writers, writer) and is_list(args) ->
          if resolve_module(parts, scope) == @audit_module and
               length(args) == Map.fetch!(@writers, writer) do
            attrs = Enum.at(args, if(writer == :insert_entry, do: 1, else: 2))
            resolved = resolve_attrs(attrs, function, functions, scope)
            row = new_entry(path, module, function, writer, resolved, meta)
            {node, [row | acc]}
          else
            {node, acc}
          end

        {name, meta, args} = node, acc when is_atom(name) and is_list(args) ->
          if imported_writer?(scope, name, length(args)) do
            attrs = Enum.at(args, if(name == :insert_entry, do: 1, else: 2))
            resolved = resolve_attrs(attrs, function, functions, scope)
            row = new_entry(path, module, function, name, resolved, meta)
            {node, [row | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(entries)
  end

  # apply/3 and captures cannot carry a readable call-site payload in the general case. They are
  # still caller rows (with computed attrs), so choosing that syntax never bypasses M1.
  defp alternate_writer_entries(path, module, scope, function) do
    {_ast, entries} =
      Macro.prewalk(function.body, [], fn
        {:apply, meta, [{:__aliases__, _, parts}, writer, args]} = node, acc ->
          {node, add_applied_entry(acc, path, module, scope, function, parts, writer, args, meta)}

        {{:., _, [receiver, :apply]}, meta, [{:__aliases__, _, parts}, writer, args]} = node,
        acc ->
          if kernel_module?(receiver) do
            {node,
             add_applied_entry(acc, path, module, scope, function, parts, writer, args, meta)}
          else
            {node, acc}
          end

        {:&, meta, [{:/, _, [capture, arity]}]} = node, acc when is_integer(arity) ->
          case capture do
            {{:., _, [{:__aliases__, _, parts}, writer]}, _capture_meta, _capture_args} ->
              if resolve_module(parts, scope) == @audit_module and
                   Map.get(@writers, writer) == arity do
                row = new_entry(path, module, function, writer, computed_attrs(), meta)
                {node, [row | acc]}
              else
                {node, acc}
              end

            {name, _capture_meta, capture_context}
            when is_atom(name) and is_atom(capture_context) ->
              if imported_writer?(scope, name, arity) do
                row = new_entry(path, module, function, name, computed_attrs(), meta)
                {node, [row | acc]}
              else
                {node, acc}
              end

            _other ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(entries)
  end

  # `apply/3` is a Kernel macro: `Kernel.apply(Audit, ...)` is the qualified form of the same
  # call and `:erlang.apply/3` is the runtime function. Both reach the audit writers.
  defp kernel_module?(:erlang), do: true
  defp kernel_module?({:__aliases__, _, [:Kernel]}), do: true
  defp kernel_module?(_other), do: false

  defp add_applied_entry(acc, path, module, scope, function, parts, writer, args, meta) do
    if resolve_module(parts, scope) == @audit_module and
         (is_map_key(@writers, writer) or not is_atom(writer)) do
      {writer, resolved} =
        case {writer, args} do
          {name, values} when is_map_key(@writers, name) and is_list(values) ->
            attrs = Enum.at(values, if(name == :insert_entry, do: 1, else: 2))
            {name, resolve_attrs(attrs, function, [], scope)}

          _dynamic ->
            {:dynamic, computed_attrs()}
        end

      [new_entry(path, module, function, writer, resolved, meta) | acc]
    else
      acc
    end
  end

  # A bare call to a writer the scope imports IS a call to the central writer.
  defp imported_writer?(scope, name, arity) do
    Map.get(@writers, name) == arity and
      Enum.any?(scope.imports, fn import ->
        resolve_module(import.parts, scope) == @audit_module and
          imports_function?(import, name)
      end)
  end

  defp new_entry(path, module, function, writer, resolved, meta) do
    %{
      path: path,
      module: module,
      caller: {function.name, function.arity},
      writer: writer,
      writer_arity: Map.get(@writers, writer, 0),
      line: Keyword.get(meta, :line, 0),
      fields: resolved.fields,
      actor_class: actor_class(resolved),
      explicit_actor_kind: explicit_actor_kind(resolved),
      action: action(resolved),
      before_payload: payload_class(resolved, :before_state),
      after_payload: payload_class(resolved, :after_state),
      payload_values: %{
        before_state: Map.get(resolved.values, :before_state, []),
        after_state: Map.get(resolved.values, :after_state, [])
      }
    }
  end

  defp resolve_attrs({:%{}, _, _} = map, _function, _functions, _scope),
    do: resolved_maps([map])

  defp resolve_attrs({name, _, context}, function, functions, scope)
       when is_atom(name) and is_atom(context) do
    assignments =
      Macro.prewalk(function.body, [], fn
        {:=, meta, [{^name, _, var_context}, value]} = node, acc when is_atom(var_context) ->
          {node, [{Keyword.get(meta, :line, 0), value} | acc]}

        node, acc ->
          {node, acc}
      end)
      |> elem(1)
      |> Enum.reverse()

    case assignments do
      [] -> computed_attrs()
      values -> values |> List.last() |> elem(1) |> resolve_attrs(function, functions, scope)
    end
  end

  defp resolve_attrs({name, _, args}, _function, functions, scope)
       when is_atom(name) and is_list(args) do
    case Enum.filter(functions, &(&1.name == name and &1.arity == length(args))) do
      [] ->
        computed_attrs()

      matches ->
        maps = Enum.flat_map(matches, &returned_maps(&1.body, scope))
        if maps == [], do: computed_attrs(), else: resolved_maps(maps)
    end
  end

  defp resolve_attrs(
         {{:., _, [{:__aliases__, _, _parts}, fun]}, _, args},
         function,
         functions,
         scope
       )
       when fun in [:merge, :put, :put_new] and is_list(args) do
    if Enum.all?(args, &map_producing?(&1, function, functions, scope)) do
      resolved =
        Enum.map(args, &resolve_attrs(&1, function, functions, scope))

      if Enum.all?(resolved, &(&1.fields != :computed)) do
        maps = Enum.flat_map(args, &literal_maps(&1, function, functions, scope))
        if maps == [], do: computed_attrs(), else: resolved_maps(maps)
      else
        computed_attrs()
      end
    else
      computed_attrs()
    end
  end

  defp resolve_attrs(_other, _function, _functions, _scope), do: computed_attrs()

  defp computed_attrs do
    %{
      fields: :computed,
      values: %{},
      value_sets: %{},
      payload_shapes: %{before_state: [:computed], after_state: [:computed]}
    }
  end

  defp resolved_maps(maps) do
    fields =
      maps
      |> Enum.map(&map_fields/1)
      |> Enum.reduce(nil, fn
        fields, nil -> MapSet.new(fields)
        fields, acc -> MapSet.intersection(acc, MapSet.new(fields))
      end)
      |> MapSet.to_list()
      |> Enum.sort()

    value_sets =
      for field <- @required_fields ++ [:actor_kind, :before_state, :after_state], into: %{} do
        values = Enum.flat_map(maps, &map_values(&1, field))
        {field, values}
      end

    %{
      fields: fields,
      values: value_sets,
      value_sets: value_sets,
      payload_shapes: %{
        before_state: Enum.map(Map.get(value_sets, :before_state, []), &payload_shape/1),
        after_state: Enum.map(Map.get(value_sets, :after_state, []), &payload_shape/1)
      }
    }
  end

  defp returned_maps(body, scope) do
    body
    |> return_expressions()
    |> Enum.flat_map(fn expression -> literal_maps(expression, nil, [], scope) end)
  end

  defp return_expressions({:__block__, _, expressions}),
    do: return_expressions(List.last(expressions))

  defp return_expressions({:case, _, [_value, [do: clauses]]}),
    do: Enum.flat_map(clauses, fn {:->, _, [_head, body]} -> return_expressions(body) end)

  defp return_expressions({:if, _, [_condition, branches]}) do
    Enum.flat_map([:do, :else], fn key ->
      case Keyword.get(branches, key) do
        nil -> []
        body -> return_expressions(body)
      end
    end)
  end

  defp return_expressions(other), do: [other]

  defp literal_maps({:%{}, _, _} = map, _function, _functions, _scope), do: [map]

  defp literal_maps(
         {{:., _, [{:__aliases__, _, parts}, fun]}, _, args},
         function,
         functions,
         scope
       )
       when fun in [:merge, :put, :put_new] and is_list(args) do
    if resolve_alias(parts, scope) == "Elixir.Map" do
      Enum.flat_map(args, &literal_maps(&1, function, functions, scope))
    else
      []
    end
  end

  defp literal_maps(_other, _function, _functions, _scope), do: []

  defp map_producing?({:%{}, _, _}, _function, _functions, _scope), do: true

  defp map_producing?(
         {{:., _, [{:__aliases__, _, parts}, fun]}, _, args},
         function,
         functions,
         scope
       )
       when fun in [:merge, :put, :put_new] and is_list(args) do
    resolve_alias(parts, scope) == "Elixir.Map" and
      Enum.all?(args, &map_producing?(&1, function, functions, scope))
  end

  defp map_producing?(_other, _function, _functions, _scope), do: false

  defp map_fields({:%{}, _, pairs}) do
    for {key, _value} <- pairs, is_atom(key), do: key
  end

  defp map_values({:%{}, _, pairs}, field) do
    for {key, value} <- pairs, key == field, do: value
  end

  # The actor a call site supplies, in the probe's own classes. `person` is a UUID that names
  # a person; `sentinel` is one of the platform/system ids the codebase uses for "nobody
  # acted" (the all-zero UUID family, including `EventStore.platform_actor_id/0`); `caller`
  # is an actor the call site does not resolve here, so the writer decides the kind when the
  # row is written.
  defp actor_class(resolved) do
    if resolved.fields == :computed do
      "computed"
    else
      supplied_actor_class(resolved)
    end
  end

  defp supplied_actor_class(resolved) do
    case Map.get(resolved.value_sets, :actor_id, []) do
      [] -> "missing"
      values -> values |> Enum.map(&actor_value_class/1) |> Enum.uniq() |> one_actor_class()
    end
  end

  defp one_actor_class([class]), do: class
  defp one_actor_class(_many), do: "mixed"

  defp actor_value_class(nil), do: "nobody"

  defp actor_value_class({{:., _, [{:__aliases__, _, parts}, :platform_actor_id]}, _, []}),
    do: if(List.last(parts) == :EventStore, do: "sentinel", else: "caller")

  defp actor_value_class({:@, _, [{name, _, _}]})
       when name in [:release_actor_id, :platform_actor_id, :system_actor_id],
       do: "sentinel"

  defp actor_value_class(value) when is_binary(value) do
    cond do
      sentinel_id?(value) -> "sentinel"
      person_id?(value) -> "person"
      true -> "non-person"
    end
  end

  defp actor_value_class({name, _, context}) when is_atom(name) and is_atom(context), do: "caller"

  defp actor_value_class(_other), do: "caller"

  # The platform/system ids the codebase uses for "nobody acted": the all-zero UUID family
  # (`EventStore.platform_actor_id/0` is `...-000000000002`, `@system_actor_id` is the nil
  # UUID). A person id is a random UUID and never starts with eight zero groups.
  defp sentinel_id?(value) when is_binary(value) do
    String.starts_with?(value, "00000000-0000-0000-0000-")
  end

  defp person_id?(value) when is_binary(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp explicit_actor_kind(resolved) do
    case Map.get(resolved.value_sets, :actor_kind, []) do
      [kind] when is_binary(kind) -> kind
      [] -> nil
      values -> Enum.map_join(values, ",", &Macro.to_string/1)
    end
  end

  defp action(resolved) do
    values = Map.get(resolved.value_sets, :action, [])

    case Enum.uniq(values) do
      [] -> if(resolved.fields == :computed, do: "computed", else: "missing")
      [action] when is_binary(action) -> action
      actions -> actions |> Enum.map_join(",", &Macro.to_string/1) |> one_line()
    end
  end

  defp payload_class(resolved, field) do
    case Map.get(resolved.payload_shapes, field, []) do
      [] ->
        if(field in List.wrap(resolved.fields), do: "missing", else: "absent")

      shapes ->
        shapes |> Enum.uniq() |> Enum.map(&Atom.to_string/1) |> Enum.sort() |> Enum.join(",")
    end
  end

  defp one_line(value), do: String.replace(value, ~r/\s+/, " ")

  defp payload_shape(nil), do: nil
  defp payload_shape({:%{}, _, _}), do: :literal_map

  defp payload_shape({{:., _, [{:__aliases__, _, parts}, :struct_state]}, _, args})
       when is_list(args),
       do: if(List.last(parts) == :Audit, do: :struct_state, else: :computed)

  defp payload_shape(_other), do: :computed

  defp sensitive_literal_values(ast) do
    {_ast, hits} =
      Macro.prewalk(ast, [], fn
        {key, value} = node, acc when is_atom(key) or is_binary(key) ->
          if sensitive_key?(key) and not safe_payload_value?(key, value),
            do: {node, [{key, value} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(hits)
  end

  defp safe_payload_value?(_key, nil), do: true
  defp safe_payload_value?(_key, "[REDACTED]"), do: true

  # Existing identity audits use `credential` for the mechanism (:oidc/:api_token), never
  # its secret. Any other sensitive key/value shape still fails; the matrix pins these sites.
  defp safe_payload_value?(key, {{:., _, [{name, _, context}, :credential]}, _, []})
       when key in [:credential, "credential"] and name in [:actor, :auth] and
              is_atom(context),
       do: true

  defp safe_payload_value?(
         key,
         {{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, [{name, _, context}, :credential]}
       )
       when key in [:credential, "credential"] and name in [:actor, :auth] and
              is_atom(context),
       do: true

  defp safe_payload_value?(_key, _other), do: false

  defp sensitive_key?(key) do
    normalized = key |> to_string() |> String.downcase()

    normalized in @sensitive_exact_keys or
      Enum.any?(@sensitive_suffixes, &String.ends_with?(normalized, &1))
  end

  # ── the anti-bypass half ───────────────────────────────────────────────────────────────────

  defp direct_writes(ast, path, file_aliases) do
    ast
    |> module_asts()
    |> Enum.reject(fn {module, _body} -> audit_writer_module?(module, file_aliases) end)
    |> Enum.flat_map(fn {module, body} ->
      scope = scope_of(body, file_aliases)

      Enum.flat_map(functions_of(body), fn function ->
        facts = write_facts(function.body, scope)
        writes = facts.writes

        if facts.entry_schema? or facts.raw_sql? or audit_table_write?(writes) do
          cond do
            writes != [] ->
              Enum.map(writes, fn write ->
                %{path: path, module: module, caller: function.name, form: write.form}
              end)

            facts.raw_sql? ->
              [%{path: path, module: module, caller: function.name, form: :raw_sql}]

            true ->
              []
          end
        else
          []
        end
      end)
    end)
  end

  defp audit_writer_module?(module, file_aliases) do
    module == @audit_module or
      resolve_module(String.split(module, "."), %{aliases: file_aliases}) == @audit_module
  end

  # One pass over a function body collects everything the anti-bypass rule needs: an
  # `Audit.Entry` struct literal, a call on the audit schema, a raw `INSERT INTO
  # audit_entries`, and every Ecto write with the table it targets. The target is what
  # makes the bulk form visible: `Repo.insert_all("audit_entries", rows)` and
  # `Repo.insert_all(Entry, rows)` write the tenant's audit chain without ever naming
  # the schema struct, so a struct-literal-only precondition would miss exactly the
  # bypass form this codebase already uses for other tenant tables.
  defp write_facts(body, scope) do
    {_ast, facts} =
      Macro.prewalk(body, %{entry_schema?: false, raw_sql?: false, writes: []}, fn
        {:%, _, [{:__aliases__, _, parts}, _]} = node, acc ->
          entry? = audit_schema?(parts, scope)
          {node, %{acc | entry_schema?: acc.entry_schema? or entry?}}

        {:<<>>, _, parts} = node, acc when is_list(parts) ->
          {node, %{acc | raw_sql?: acc.raw_sql? or audit_insert_sql?(literal_segments(parts))}}

        value, acc when is_binary(value) ->
          {value, %{acc | raw_sql?: acc.raw_sql? or audit_insert_sql?(value)}}

        {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = node, acc
        when fun in @repo_mutations and is_list(args) ->
          target = resolve_module(parts, scope)

          cond do
            repo_receiver?(parts, target) ->
              {node, %{acc | writes: acc.writes ++ [mutation(fun, args, scope)]}}

            multi_receiver?(target) and fun in @multi_mutations ->
              {node, %{acc | writes: acc.writes ++ [multi_mutation(fun, args, scope)]}}

            true ->
              {node, acc}
          end

        {{:., _, [{:__aliases__, _, parts}, _fun]}, _, args} = node, acc when is_list(args) ->
          {node, %{acc | entry_schema?: acc.entry_schema? or audit_schema?(parts, scope)}}

        {{:., _, [{name, _, context}, fun]}, _, args} = node, acc
        when name in [:repo, :repo_mod] and is_atom(context) and fun in @repo_mutations and
               is_list(args) ->
          {node, %{acc | writes: acc.writes ++ [mutation(fun, args, scope)]}}

        node, acc ->
          {node, acc}
      end)

    facts
  end

  defp repo_receiver?(parts, target) do
    List.last(parts) == :Repo or target == "Letflow.Repo"
  end

  defp multi_receiver?(target), do: target == "Ecto.Multi"

  # The audit schema module, however it is named: through an alias, through the file's own
  # alias, with the `Elixir` root marker, or through a name the scope imports.
  defp audit_schema?(parts, scope) do
    parts |> candidate_modules(scope) |> Enum.any?(&audit_schema_path?/1)
  end

  defp mutation(fun, args, scope) do
    %{form: fun, audit_target?: audit_target?(args, scope)}
  end

  # A Multi operation names its schema after the operation name, so every argument after
  # the first is read for an audit target.
  defp multi_mutation(fun, args, scope) do
    audit? = args |> Enum.drop(1) |> Enum.any?(&audit_target?([&1], scope))
    %{form: :"multi_#{fun}", audit_target?: audit?}
  end

  defp audit_table_write?(writes), do: Enum.any?(writes, & &1.audit_target?)

  # A bulk write names the audit table either by name (`"audit_entries"`), by schema
  # (`Entry`, `Letflow.Audit.Entry`), through a module attribute that holds either, or by
  # an interpolated table name. All of them write the tenant's audit chain directly.
  defp audit_target?(args, scope) do
    case args do
      [source | _rest] -> audit_source?(source, scope)
      _other -> false
    end
  end

  defp audit_source?(source, _scope) when is_binary(source), do: audit_table_name?(source)

  defp audit_source?({:__aliases__, _, parts}, scope),
    do: parts |> candidate_modules(scope) |> Enum.any?(&audit_schema_path?/1)

  defp audit_source?({:<<>>, _, parts}, _scope) when is_list(parts),
    do: audit_table_name?(literal_segments(parts))

  defp audit_source?({:@, _, [{name, _, _}]}, scope) do
    case Map.get(scope.attributes, name) do
      nil -> false
      literal -> audit_source?(literal, scope)
    end
  end

  defp audit_source?({:module, path}, _scope), do: audit_schema_path?(path)

  defp audit_source?(_other, _scope), do: false

  defp audit_table_name?(source) do
    Regex.match?(~r/(^|[^A-Za-z0-9_])audit_entries([^A-Za-z0-9_]|$)/i, source)
  end

  # The literal parts of an interpolated string; the interpolated values themselves are
  # unknown, so only the constant segments are read.
  defp literal_segments(parts) when is_list(parts) do
    parts |> Enum.filter(&is_binary/1) |> Enum.join("")
  end

  defp audit_insert_sql?(value) do
    Regex.match?(~r/\bINSERT\s+INTO\s+[^;]*\baudit_entries\b/i, value)
  end

  # ── the shape of the tree ──────────────────────────────────────────────────────────────────

  defp module_asts(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts}, [do: body]]} = node, acc ->
          {node, [{join_parts(parts), body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(modules)
  end

  defp functions_of(body) do
    {_ast, functions} =
      Macro.prewalk(body, [], fn
        {kind, _, [head, clauses]} = node, acc
        when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(clauses) ->
          if Keyword.has_key?(clauses, :do) do
            {name, args} = function_head(head)
            function_body = {:__block__, [], Keyword.values(clauses)}
            data = %{name: name, arity: length(args), args: args, body: function_body}
            {node, [data | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(functions)
  end

  defp function_head({:when, _, [head | _guards]}), do: function_head(head)
  defp function_head({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp function_head({name, _, context}) when is_atom(name) and is_atom(context), do: {name, []}

  # The joined path of a module reference, without the `nil` a single unbound name has.
  defp resolve_alias(parts, scope) do
    case resolve_module(parts, scope) do
      nil -> join_parts(parts)
      path -> path
    end
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

  defp add_ordinals(entries) do
    {entries, _counts} =
      entries
      |> Enum.sort_by(& &1.line)
      |> Enum.map_reduce(%{}, fn entry, counts ->
        key = {entry.path, entry.module, entry.caller, entry.writer}
        ordinal = Map.get(counts, key, 0) + 1
        {Map.put(entry, :ordinal, ordinal), Map.put(counts, key, ordinal)}
      end)

    entries
  end

  # The actor the call site supplies, and the kind it states when it states one. The kind is
  # rare under the landed model (the writer derives it), so a call site that starts stating
  # one shows up in the matrix instead of passing unnoticed.
  defp render_actor(entry) do
    case entry.explicit_actor_kind do
      nil -> entry.actor_class
      stated -> "#{entry.actor_class},kind=#{stated}"
    end
  end

  defp render_fields(:computed), do: "computed"
  defp render_fields(fields), do: Enum.map_join(fields, ",", &to_string/1)
end
