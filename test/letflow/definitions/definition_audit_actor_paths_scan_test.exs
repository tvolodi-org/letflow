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
  The ROOT of the derivation may not shrink either: the last test requires every
  module of the definitions tree that CALLS an audit writer to be in
  `@context_files`, or the scan says so (the marking writer of
  `Letflow.Definitions.Reactivation` was outside the root while this moduledoc
  claimed every definition audit writer).

  The actor has FOUR sources in the context, and the scan reads which one
  applies from the function's own body -- the scan does not trust a hand-written
  list:

    * `:opts_actor` -- `Keyword.get(opts, :actor_id)`: the CALLER passes the
      person in the opts it hands over.
    * `:activator_actor` -- the activator document: the CALLER passes the
      person inside it.
    * `:arg_actor` -- the writer's audit call passes the actor as a plain
      ARGUMENT the caller supplies (no `:actor_id` key anywhere in the chain):
      the caller decides, and a route that reaches it must hand over the
      person.
    * `:system_actor` -- the writer's audit call passes the LITERAL `nil`: the
      row names the SYSTEM, not a person. That is the class of a caller that is
      not a person at all (module code, a seed task, the reactivation marker).

  A router path that reaches a function of the first three classes must carry
  the matching actor in its own body: the `:actor_id` for the first two, the
  `:activator` for the third. A path that reaches a `:system_actor` writer
  FAILS the scan: a person made that request, and a row that names the system
  is exactly the hidden actor decision (d) forbids. A path whose context
  function has no recognisable actor source fails the scan too (`:unknown` is
  not a class one may pass) -- the scan fails closed.

  The system class needs the LOWER arity of a def with a default argument: the
  marking writer reaches the row through `Definitions.record_audit/6` and calls
  it with FIVE arguments, so the default (`nil`) is what its row carries. The
  AST helpers below therefore read every arity a def defines, with the default
  standing in for the argument in the lower ones -- otherwise that call would
  be a leaf and the writer behind it invisible (the limit this scan used to
  state).

  The sibling scan of the PLATFORM-CALL check is
  `test/letflow/definitions/platform_call_write_paths_scan_test.exs`; the two
  scans read the same modules for different rules.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  @context_files %{
    "Letflow.Definitions" => "lib/letflow/definitions.ex",
    "Letflow.Definitions.ExportImport" => "lib/letflow/definitions/export_import.ex",
    # T-2588 (review of attempt 2): the marking writer of the definitions tree
    # writes a definition audit row too (`Definitions.record_audit/6`). Its module
    # belongs in the root, so a change in it is read by this scan and not
    # silently outside it.
    "Letflow.Definitions.Reactivation" => "lib/letflow/definitions/reactivation.ex"
  }

  @router_module "Letflow.Routers.Definitions"
  @router_file "lib/letflow/routers/definitions.ex"

  # The definitions tree: every module that may write a definition audit row.
  @definitions_tree ["lib/letflow/definitions.ex", "lib/letflow/definitions/**/*.ex"]

  # The names under which a definition audit row is written. A module that
  # CALLS one of them writes the row itself.
  @audit_writer_names [:record_audit, :record_definition_audit]

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
    arg_actor: :actor_id,
    activator_actor: :activator
  }

  # ── the AST helpers ─────────────────────────────────────────────────────────

  defp parse(path), do: path |> File.read!() |> Code.string_to_quoted!()

  # The module name a file defines.
  defp module_name({:defmodule, _, [{:__aliases__, _, parts}, _body]}), do: Enum.join(parts, ".")

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
  #
  # A def with a DEFAULT argument defines SEVERAL arities: `def f(a, b, c, d,
  # e, x \\ nil)` defines `f/6` as written and `f/5` with the default in the
  # place of `x`. The closure follows a call by its EXACT arity, so the lower
  # form has to be here as well -- without it, the five-argument call of
  # `Definitions.record_audit/6` (the marking writer's) is a leaf and the
  # writer behind it stays invisible.
  defp functions_of(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, %{functions: %{}, public: MapSet.new()}, fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          case head_args(head) do
            {name, args} ->
              {node,
               Enum.reduce(arity_variants(args, body), acc, fn {arity, variant}, acc ->
                 %{
                   functions: Map.put(acc.functions, {name, arity}, variant),
                   public:
                     if(kind == :def, do: MapSet.put(acc.public, {name, arity}), else: acc.public)
                 }
               end)}

            _other ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    {acc.functions, acc.public}
  end

  # The name and the argument list of a def's head (the head may carry guards).
  defp head_args({:when, _, [head | _]}), do: head_args(head)
  defp head_args({:\\, _, _}), do: nil

  defp head_args({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, args}

  defp head_args(_other), do: nil

  # Every arity a def defines, with the body of that arity: the head's own
  # arity, and one per DEFAULT argument below it, where the default stands in
  # for the argument.
  defp arity_variants(args, body) do
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    max_arity = length(args)

    if defaults == 0 do
      [{max_arity, body}]
    else
      for arity <- (max_arity - defaults)..max_arity do
        {arity, body_for_arity(args, arity, body)}
      end
    end
  end

  # The body of the given arity: the arguments BEYOND it stand for their
  # DEFAULT values (a default always applies to the trailing arguments), and
  # each default replaces its parameter in the body.
  defp body_for_arity(args, arity, body) do
    args
    |> Enum.drop(arity)
    |> Enum.filter(&match?({:\\, _, _}, &1))
    |> Enum.reduce(body, fn {:\\, _, [pattern, default]}, acc ->
      substitute_var(acc, pattern, default)
    end)
  end

  # Replaces every reference to the variable `pattern` in `body` with `value`.
  # Only a LITERAL default is substituted: an expression default is left alone
  # (the lower arity then reads like the higher one, which is the fail-closed
  # direction -- the scan asks for MORE, never for less).
  defp substitute_var(body, pattern, value) do
    {name, _meta, context} = pattern

    if literal?(value) do
      Macro.prewalk(body, fn
        {^name, _meta, ^context} -> value
        node -> node
      end)
    else
      body
    end
  end

  defp literal?(value) when is_atom(value) or is_number(value) or is_binary(value), do: true
  defp literal?(value) when is_list(value), do: Enum.all?(value, &literal?/1)
  defp literal?(_other), do: false

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

  # The ARGS of the audit writer's call inside one body, or nil when the body
  # does not call it. The actor is the SIXTH argument: a LITERAL `nil` there
  # is what makes the row name the system instead of a person.
  defp writer_call_args(body, aliases) do
    {_body, found} =
      Macro.prewalk(body, nil, fn
        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          if is_nil(acc) and name == :record_definition_audit and length(args) == 6 do
            {node, args}
          else
            {node, acc}
          end

        {{:., _, [{:__aliases__, _, parts}, name]}, _, args} = node, acc
        when is_atom(name) and is_list(args) ->
          if is_nil(acc) and name == :record_definition_audit and length(args) == 6 and
               resolve(parts, aliases) == "Letflow.Definitions" do
            {node, args}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  # The transitive closure of one function: the calls it reaches and the atoms
  # its body mentions. A call into a module outside the scanned set is a leaf
  # (its own body is not read). A call in `stop` is a leaf as well: the call
  # itself is recorded (that is how a writer is recognised), but its body is
  # not read -- the audit writer names the `actor_id` KEY of its own row, and
  # reading it would make every writer look alike.
  #
  # `writer_args` carries the ARGS of the audit writer's call wherever it sits
  # in the chain: the sixth one is the actor, and a literal `nil` there is the
  # system class.
  defp closure(module, {name, arity}, modules, stop, seen \\ MapSet.new()) do
    key = {module, name, arity}

    if MapSet.member?(seen, key) do
      %{calls: MapSet.new(), atoms: MapSet.new(), writer_args: nil}
    else
      seen = MapSet.put(seen, key)
      {functions, _public, aliases} = Map.fetch!(modules, module)

      case Map.get(functions, {name, arity}) do
        nil ->
          %{calls: MapSet.new(), atoms: MapSet.new(), writer_args: nil}

        body ->
          calls = calls_of(body, aliases)
          own_writer_args = writer_call_args(body, aliases)

          Enum.reduce(
            calls,
            %{calls: MapSet.new(), atoms: atoms_of(body), writer_args: own_writer_args},
            fn call, acc ->
              nested =
                if MapSet.member?(stop, call) do
                  %{calls: MapSet.new(), atoms: MapSet.new(), writer_args: nil}
                else
                  case call do
                    {:local, local_name, local_arity} ->
                      closure(module, {local_name, local_arity}, modules, stop, seen)

                    {:remote, target, remote_name, remote_arity} ->
                      if Map.has_key?(modules, target) do
                        closure(target, {remote_name, remote_arity}, modules, stop, seen)
                      else
                        %{calls: MapSet.new(), atoms: MapSet.new(), writer_args: nil}
                      end
                  end
                end

              %{
                calls: MapSet.union(acc.calls, MapSet.put(nested.calls, call)),
                atoms: MapSet.union(acc.atoms, nested.atoms),
                writer_args: acc.writer_args || nested.writer_args
              }
            end
          )
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
  # The ARITY is part of the key: `record_audit/5` (no actor -- the system) and
  # `record_audit/6` (the caller passes the actor) are two different writers.
  defp audit_writers(modules) do
    for {module, {functions, public, _aliases}} <- modules,
        {{name, arity}, _body} <- functions,
        MapSet.member?(public, {name, arity}),
        MapSet.member?(
          closure(module, {name, arity}, modules, @stop_at_writer).calls,
          @audit_writer
        ) do
      {module, name, arity}
    end
  end

  # Where the audit actor of one context function comes from, read from the
  # function's own body. `:unknown` when no source is there -- the scan
  # fails closed on it rather than passing a path it cannot judge.
  defp actor_source(modules, {module, name, arity}) do
    reached = closure(module, {name, arity}, modules, @stop_at_writer)

    cond do
      system_actor?(reached.writer_args) -> :system_actor
      MapSet.member?(reached.atoms, :actor_id) -> :opts_actor
      MapSet.member?(reached.atoms, :activator) -> :activator_actor
      arg_actor?(reached.writer_args) -> :arg_actor
      true -> :unknown
    end
  end

  # The audit writer's call passes the LITERAL nil as the actor: the row names
  # the SYSTEM. That is the class of a caller that is not a person.
  defp system_actor?(args) when is_list(args),
    do: length(args) == 6 and List.last(args) == nil

  defp system_actor?(_other), do: false

  # The audit writer's call passes the actor as a plain ARGUMENT (a variable,
  # not a literal): the caller decides what the row names.
  defp arg_actor?(args) when is_list(args),
    do: length(args) == 6 and match?({_name, _meta, _context}, List.last(args))

  defp arg_actor?(_other), do: false

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
          |> Enum.map(fn {:remote, module, fun, call_arity} -> {module, fun, call_arity} end)
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

      for source <- demanded, source != :system_actor do
        # The system class has its own rule below: a route may not reach a
        # writer that writes no actor at all.
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

  # A person made the request, so the row must name that person. A route that
  # reaches a writer which writes NO actor (the system class: module code, a
  # seed task, the reactivation marker) writes a row that claims the system
  # did it -- the hidden actor decision (d) forbids.
  test "no router path reaches a writer whose row would name the system" do
    context = module_map(@context_files)
    writers = MapSet.new(audit_writers(context))
    sources = Map.new(writers, &{&1, actor_source(context, &1)})

    for {path, demanded} <- router_paths(writers, sources) do
      refute :system_actor in demanded,
             """
             #{inspect(@router_module)}.#{path} reaches a definition audit writer that writes \
             NO actor: its row would name the system, although a person made the request.

             Give the writer the caller's user id (opts[:actor_id], or the activator), or \
             do not route it.
             """
    end
  end

  test "the derivation finds the audit-writing paths at all (the scan is not empty)" do
    context = module_map(@context_files)
    writers = MapSet.new(audit_writers(context))

    assert MapSet.member?(writers, {"Letflow.Definitions", :create, 2})
    assert MapSet.member?(writers, {"Letflow.Definitions", :deprecate, 2})
    assert MapSet.member?(writers, {"Letflow.Definitions", :archive, 2})
    assert MapSet.member?(writers, {"Letflow.Definitions", :activate, 2})
    assert MapSet.member?(writers, {"Letflow.Definitions", :reactivate, 2})

    assert MapSet.member?(
             writers,
             {"Letflow.Definitions.ExportImport", :import_with_variable_schemas, 4}
           )

    sources = Map.new(writers, &{&1, actor_source(context, &1)})

    assert sources[{"Letflow.Definitions", :create, 2}] == :opts_actor
    assert sources[{"Letflow.Definitions", :deprecate, 2}] == :opts_actor
    assert sources[{"Letflow.Definitions", :archive, 2}] == :opts_actor

    assert sources[{"Letflow.Definitions.ExportImport", :import_with_variable_schemas, 4}] ==
             :opts_actor

    assert sources[{"Letflow.Definitions", :activate, 2}] == :activator_actor
    assert sources[{"Letflow.Definitions", :reactivate, 2}] == :activator_actor
  end

  # The system class (T-2598, pilot gap G15): the writers whose row names the
  # system are DERIVED, not listed -- the marking writer of the definitions
  # tree and the no-actor form of the shared entry point. The scan used to
  # state this as a known limit (a default argument hid the five-argument
  # call); the arity-aware helpers above close it.
  test "the system-class writers are derived (the marking writer included)" do
    context = module_map(@context_files)
    writers = MapSet.new(audit_writers(context))
    sources = Map.new(writers, &{&1, actor_source(context, &1)})

    assert MapSet.member?(writers, {"Letflow.Definitions.Reactivation", :mark_definition, 3})
    assert sources[{"Letflow.Definitions.Reactivation", :mark_definition, 3}] == :system_actor

    assert MapSet.member?(writers, {"Letflow.Definitions", :record_audit, 5})
    assert sources[{"Letflow.Definitions", :record_audit, 5}] == :system_actor

    # The six-argument form takes the actor from its caller: the class that
    # says "the caller decides", not "the system".
    assert MapSet.member?(writers, {"Letflow.Definitions", :record_audit, 6})
    assert sources[{"Letflow.Definitions", :record_audit, 6}] == :arg_actor
  end

  # Every HTTP lifecycle route of the definitions router is one of the scanned
  # paths (T-2598, pilot gap G15): the scan is only a guard over the routes it
  # knows, so the list is pinned here.
  test "every HTTP lifecycle route is one of the scanned router paths" do
    context = module_map(@context_files)
    writers = MapSet.new(audit_writers(context))
    sources = Map.new(writers, &{&1, actor_source(context, &1)})

    paths = router_paths(writers, sources)

    assert {:handle_import, [:opts_actor]} in paths
    assert {:handle_create, [:opts_actor]} in paths
    assert {:handle_activate, [:activator_actor]} in paths
    assert {:handle_reactivate, [:activator_actor]} in paths
    assert {:handle_deprecate, [:opts_actor]} in paths
    assert {:handle_archive, [:opts_actor]} in paths
    assert {:handle_delete, [:opts_actor]} in paths
  end

  # The class ratchet (owner D-184): the ROOT of the derivation may not shrink.
  # A module of the definitions tree that writes a definition audit row and is
  # not in `@context_files` would write rows the scan never reads -- the
  # derivation would shrink silently. The reviewer of attempt 2 named this: the
  # marking writer (`Letflow.Definitions.Reactivation`) was outside the root
  # while the moduledoc claimed every definition audit writer.
  test "the scanned root covers every module that writes a definition audit row" do
    files =
      @definitions_tree
      |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
      |> Enum.sort()

    assert length(files) > 1, "the definitions tree must not be empty"

    for file <- files do
      ast = parse(file)
      module = module_name(ast)
      aliases = aliases_of(ast)
      {functions, _public} = functions_of(ast)

      writes? =
        Enum.any?(functions, fn {_name_arity, body} ->
          Enum.any?(calls_of(body, aliases), fn
            {:local, name, _arity} -> name in @audit_writer_names
            {:remote, _target, name, _arity} -> name in @audit_writer_names
            _other -> false
          end)
        end)

      if writes? do
        assert Map.has_key?(@context_files, module),
               """
               #{inspect(module)} writes a definition audit row but is not in the scan's root.

               Add it to @context_files, so the scan reads its actor wiring as well.
               """
      end
    end
  end
end
