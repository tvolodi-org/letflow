defmodule Letflow.Definitions.DefinitionAuditActorPathsScanTest do
  @moduledoc """
  The scan of the definition router's ACTOR wiring (T-2588, "Register a tenant"
  pilot, gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (d)).

  The exploit the security gate showed: `POST /definitions/import` writes its
  `definition.create` audit row with NO actor. The handler handed
  `ExportImport.import_with_variable_schemas/4` the prefix-only `scoped_opts`
  and passed the caller as the separate `imported_by` argument -- which reaches
  only the definition's `created_by` column -- so the audit row named nobody
  and claimed the system did it. That defeats the control which makes a stolen
  PLATFORM_ADMIN session VISIBLE in the audit.

  "One path forgotten" must not be able to come back. This scan derives, from
  the AST of the definition context modules, EVERY public function that writes a
  definition AUDIT row (a function whose path reaches the context's own
  `record_definition_audit/6`), reads WHERE that function's audit actor comes
  from, and then requires every router path that calls it to carry that actor.

  The audit actor has exactly two sources in the context, and the scan reads
  which one applies from the function's own body -- the scan does not trust a
  hand-written list:

    * `:opts_actor` -- `Keyword.get(opts, :actor_id)`: the CALLER passes the
      person in the opts it hands over.
    * `:activator_actor` -- the activator document: the CALLER passes the
      person inside it.

  A router path that reaches such a function must carry the matching actor in
  its own body: the `:actor_id` for the first, the `:activator` for the second.
  A path whose context function has no recognisable actor source fails the scan
  (`:unknown` is not a class one may pass) -- the scan fails closed.

  The sibling scan of the PLATFORM-CALL check is
  `test/letflow/definitions/platform_call_write_paths_scan_test.exs`; the two
  scans read the same modules for different rules.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  @context_files %{
    "Letflow.Definitions" => "lib/letflow/definitions.ex",
    "Letflow.Definitions.ExportImport" => "lib/letflow/definitions/export_import.ex"
  }

  @router_module "Letflow.Routers.Definitions"
  @router_file "lib/letflow/routers/definitions.ex"

  # The context's own audit writer. A public context function whose path
  # reaches it writes a definition audit row.
  @audit_writer {:local, :record_definition_audit, 6}

  # The closure stops AT the audit writer: the call is recorded (that is how a
  # writer is recognised), but the writer's own body is not read. Its row names
  # the `actor_id` KEY of the row it writes, so reading it would make every
  # writer look like an opts-actor and the classification would be worthless.
  @stop_at_writer MapSet.new([@audit_writer])
  @stop_at_nothing MapSet.new()

  # The bare atom each actor source is read through. A bare atom only: a
  # VARIABLE (`actor_id`) is not an atom in the AST and cannot satisfy -- or
  # fake -- a class. A map literal's key IS a bare atom, which is why the
  # closure stops at the audit writer (it names the `actor_id` key of the row
  # it writes, and every writer would look alike).
  @actor_atoms %{
    opts_actor: :actor_id,
    activator_actor: :activator
  }

  # ── the AST helpers ─────────────────────────────────────────────────────────

  defp parse(path), do: path |> File.read!() |> Code.string_to_quoted!()

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

  # The calls of one body: `{:local, name, arity}` and `{:remote, module, name, arity}`.
  defp calls_of(body, aliases) do
    {_body, calls} =
      Macro.prewalk(body, [], fn
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

  # Every BARE atom the body mentions.
  defp atoms_of(body) do
    {_body, atoms} =
      Macro.prewalk(body, MapSet.new(), fn
        node, acc when is_atom(node) -> {node, MapSet.put(acc, node)}
        node, acc -> {node, acc}
      end)

    atoms
  end

  # The transitive closure of one function: the calls it reaches and the atoms
  # its body mentions. A call into a module outside the scanned set is a leaf
  # (its own body is not read). A call in `stop` is a leaf as well: the call
  # itself is recorded (that is how a writer is recognised), but its body is
  # not read -- the audit writer names the `actor_id` KEY of its own row, and
  # reading it would make every writer look alike.
  defp closure(module, {name, arity}, modules, stop, seen \\ MapSet.new()) do
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
              if MapSet.member?(stop, call) do
                %{calls: MapSet.new(), atoms: MapSet.new()}
              else
                case call do
                  {:local, local_name, local_arity} ->
                    closure(module, {local_name, local_arity}, modules, stop, seen)

                  {:remote, target, remote_name, remote_arity} ->
                    if Map.has_key?(modules, target) do
                      closure(target, {remote_name, remote_arity}, modules, stop, seen)
                    else
                      %{calls: MapSet.new(), atoms: MapSet.new()}
                    end
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

  defp module_map(files) do
    Enum.into(files, %{}, fn {module, path} ->
      ast = parse(Path.join(@root, path))
      {functions, public} = functions_of(ast)
      {module, {functions, public, aliases_of(ast)}}
    end)
  end

  # ── the derivation ───────────────────────────────────────────────────────────

  # The public context functions that write a definition AUDIT row: their path
  # reaches the context's own `record_definition_audit/6`. Derived, never listed.
  defp audit_writers(modules) do
    for {module, {functions, public, _aliases}} <- modules,
        {{name, arity}, _body} <- functions,
        MapSet.member?(public, {name, arity}),
        MapSet.member?(
          closure(module, {name, arity}, modules, @stop_at_writer).calls,
          @audit_writer
        ) do
      {module, name}
    end
  end

  # Where the audit actor of one context function comes from, read from the
  # function's own body. `:unknown` when neither source is there -- the scan
  # fails closed on it rather than passing a path it cannot judge.
  defp actor_source(modules, {module, name}) do
    reached = closure(module, {name, arity_of(modules, module, name)}, modules, @stop_at_writer)

    cond do
      MapSet.member?(reached.atoms, :actor_id) -> :opts_actor
      MapSet.member?(reached.atoms, :activator) -> :activator_actor
      true -> :unknown
    end
  end

  # The router paths (functions of the router) that call an audit-writing
  # context function, and the actor sources those functions demand.
  defp router_paths(writers, sources) do
    router = module_map(%{@router_module => @router_file})
    {functions, _public, _aliases} = Map.fetch!(router, @router_module)

    for {{name, arity}, _body} <- functions,
        reached = closure(@router_module, {name, arity}, router, @stop_at_nothing),
        demanded =
          reached.calls
          |> Enum.filter(&match?({:remote, _module, _fun, _arity}, &1))
          |> Enum.map(fn {:remote, module, fun, _arity} -> {module, fun} end)
          |> Enum.filter(&MapSet.member?(writers, &1))
          |> Enum.map(&Map.fetch!(sources, &1))
          |> Enum.uniq(),
        demanded != [] do
      {name, demanded}
    end
  end

  defp arity_of(modules, module, name) do
    {functions, _public, _aliases} = Map.fetch!(modules, module)

    case Enum.find(functions, fn {{fun_name, _arity}, _body} -> fun_name == name end) do
      {{_fun_name, arity}, _body} -> arity
      nil -> flunk("#{inspect(module)}.#{name} is not defined")
    end
  end

  # ── the tests ───────────────────────────────────────────────────────────────

  test "every router path that writes a definition audit row carries the actor" do
    context = module_map(@context_files)
    writers = MapSet.new(audit_writers(context))
    sources = Map.new(writers, &{&1, actor_source(context, &1)})
    router = module_map(%{@router_module => @router_file})

    for {path, demanded} <- router_paths(writers, sources) do
      reached =
        closure(
          @router_module,
          {path, arity_of(router, @router_module, path)},
          router,
          @stop_at_nothing
        )

      for source <- demanded do
        assert Map.has_key?(@actor_atoms, source),
               """
               #{inspect(@router_module)}.#{path} writes a definition audit row whose actor \
               source the scan cannot read (#{inspect(source)}).

               Classify the actor source of the context function it calls, or the scan \
               fails closed here.
               """

        atom = Map.fetch!(@actor_atoms, source)

        assert MapSet.member?(reached.atoms, atom),
               """
               #{inspect(@router_module)}.#{path} writes a definition audit row whose actor \
               comes from #{inspect(source)}, but its own body never mentions #{inspect(atom)}.

               The lifecycle audit row would name nobody -- or claim the system did it.
               """
      end
    end
  end

  test "the derivation finds the audit-writing paths at all (the scan is not empty)" do
    context = module_map(@context_files)
    writers = MapSet.new(audit_writers(context))

    assert MapSet.member?(writers, {"Letflow.Definitions", :create})
    assert MapSet.member?(writers, {"Letflow.Definitions", :deprecate})
    assert MapSet.member?(writers, {"Letflow.Definitions", :archive})
    assert MapSet.member?(writers, {"Letflow.Definitions", :activate})
    assert MapSet.member?(writers, {"Letflow.Definitions", :reactivate})

    assert MapSet.member?(
             writers,
             {"Letflow.Definitions.ExportImport", :import_with_variable_schemas}
           )

    sources = Map.new(writers, &{&1, actor_source(context, &1)})

    assert sources[{"Letflow.Definitions", :create}] == :opts_actor
    assert sources[{"Letflow.Definitions", :deprecate}] == :opts_actor
    assert sources[{"Letflow.Definitions", :archive}] == :opts_actor

    assert sources[{"Letflow.Definitions.ExportImport", :import_with_variable_schemas}] ==
             :opts_actor

    assert sources[{"Letflow.Definitions", :activate}] == :activator_actor
    assert sources[{"Letflow.Definitions", :reactivate}] == :activator_actor
  end

  test "the import route is one of the scanned router paths" do
    context = module_map(@context_files)
    writers = MapSet.new(audit_writers(context))
    sources = Map.new(writers, &{&1, actor_source(context, &1)})

    paths = router_paths(writers, sources)

    assert {:handle_import, [:opts_actor]} in paths
    assert {:handle_create, [:opts_actor]} in paths
    assert {:handle_activate, [:activator_actor]} in paths
  end
end
