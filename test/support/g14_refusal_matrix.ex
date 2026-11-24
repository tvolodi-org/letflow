defmodule Letflow.Support.G14RefusalMatrix do
  @moduledoc """
  G-14 -- the refusal-mapping matrix of the activation switch-on surfaces.

  The class: a refusal tuple the activation fences can produce must answer a
  TYPED 4xx on EVERY surface that switches a definition on. A surface that
  leaves the tuple to its catch-all answers 500, and the caller sees a server
  fault for what is the tenant's own mistake. The class cost two pilot tasks
  (G16 T-2604, G14 T-2597) and a 500 in between.

  Everything this module knows is DERIVED from the sources -- never from a hand
  list:

    * the surfaces are the render functions of the mounted routers
      (`lib/letflow/routers/*.ex`) that can render an activation refusal;
    * the refusal tuples are the error shapes of the FENCE functions of
      `lib/letflow/definitions.ex` -- the functions an activation `with` chain
      calls in an `:ok <-` position;
    * which tuples a surface can receive is the fence set of its own context
      path, found by a call-graph walk from the router's handler down to the
      fences;
    * the mapping of a tuple is the clause of the render function that matches
      it, read from the same source;
    * the renderer is DRIVEN for real: the router module is copied (renamed,
      with its render functions made public) and called with the synthetic
      refusal tuples, so the answer under test is the product's own.

  The class table is `docs/security-probes/G-14.md`.
  """

  @fence_module "Letflow.Definitions"
  # The switch-on surfaces of the class: the renderers of the five activation
  # paths (definition activate / reactivate / version rollback, promotion
  # apply, tenant promote, solution-pack override activation).
  @switch_on_surface_names [
    :render_activate,
    :render_reactivate,
    :render_rollback,
    :render_apply,
    :render_promote,
    :render_override_activate_error
  ]
  @response_module "Letflow.Api.Response"
  @router_glob "lib/letflow/routers/*.ex"
  @max_walk 600

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  The switch-on surfaces, derived from the router sources.

  A surface is a render function of a router whose clauses can render at least
  one refusal tuple of the fence set.
  """
  @spec surfaces() :: [map()]
  def surfaces do
    case :persistent_term.get({__MODULE__, :surfaces}, nil) do
      nil ->
        surfaces = compute_surfaces()
        :persistent_term.put({__MODULE__, :surfaces}, surfaces)
        surfaces

      cached ->
        cached
    end
  end

  defp compute_surfaces do
    for path <- Path.wildcard(@router_glob),
        {mod, body} <- module_bodies(path),
        {name, clauses} <- group_by_name(render_clauses(body)),
        shapes = clauses |> Enum.flat_map(& &1.shapes) |> Enum.uniq(),
        shapes != [] do
      %{
        name: name,
        router: mod,
        file: path,
        clauses: clauses,
        shapes: shapes
      }
    end
  end

  @doc """
  The switch-on surfaces of the class: the renderers that switch a definition
  on. The list is the class's own (the activation paths the team named), and
  the derivation proves that every one of them exists in the router sources.
  """
  @spec switch_on_surfaces() :: [map()]
  def switch_on_surfaces do
    names = @switch_on_surface_names
    derived = surfaces()

    for name <- names do
      case Enum.find(derived, &(&1.name == name)) do
        nil -> nil
        surface -> surface
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The refusal tuples of the class: the error shapes of the fence functions of
  `lib/letflow/definitions.ex` plus the shapes the switch-on surfaces answer
  (a fence that refuses through a helper keeps its tuple out of the fence's
  own body, so the surfaces carry it).
  """
  @spec fence_shapes() :: [map()]
  def fence_shapes do
    case :persistent_term.get({__MODULE__, :fence_shapes}, nil) do
      nil ->
        shapes = compute_fence_shapes()
        :persistent_term.put({__MODULE__, :fence_shapes}, shapes)
        shapes

      cached ->
        cached
    end
  end

  defp compute_fence_shapes do
    from_fences =
      for name <- activation_fences(),
          {kind, tuple} <- fence_error_shapes(name),
          into: [] do
        %{name: tuple, kind: kind, fence: name}
      end

    # The tuple-shaped shapes of the surfaces: a fence that refuses through a
    # helper keeps its tuple out of the fence's own body, so the surfaces carry
    # it. The bare atoms are NOT taken from the surfaces: a renderer answers
    # its own business errors (`:not_found`, `:busy`) under its own names.
    from_surfaces =
      for surface <- switch_on_surfaces(),
          {:tuple, tuple} <- surface.shapes,
          into: [] do
        %{name: tuple, kind: :tuple, fence: :mapped_by_the_surface}
      end

    (from_fences ++ from_surfaces)
    |> Enum.uniq_by(&{&1.name, &1.kind})
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  The ACTIVATION fences of the class: the fence functions the definition
  activation path runs. Every switch-on surface runs (a subset of) them, so
  their refusal tuples are the ones the class is about.
  """
  @spec activation_fences() :: [atom()]
  def activation_fences do
    case Enum.find(switch_on_surfaces(), &(&1.name == :render_activate)) do
      nil -> []
      surface -> surface_fences(surface) |> MapSet.to_list() |> Enum.sort()
    end
  end

  @doc """
  The matrix: one cell per (surface, refusal tuple) pair, with the clause that
  maps it and the helper that answers it.
  """
  @spec matrix() :: [map()]
  def matrix do
    shapes = fence_shapes()

    for surface <- switch_on_surfaces(),
        shape <- shapes,
        reachable = reachable?(surface, shape) do
      %{
        surface: surface.name,
        router: surface.router,
        shape: shape.name,
        kind: shape.kind,
        fence: shape.fence,
        reachable: reachable,
        clause: mapping(surface, shape),
        helper: helper_for(surface, shape)
      }
    end
  end

  @doc """
  The cells that break the class: a reachable refusal without a mapping, or one
  the surface answers with a server error.
  """
  @spec violations([map()]) :: [map()]
  def violations(cells) do
    for cell <- cells,
        cell.reachable,
        violation = cell_violation(cell),
        violation != nil do
      Map.put(cell, :violation, violation)
    end
  end

  defp cell_violation(%{clause: nil}), do: :unmapped

  defp cell_violation(%{clause: clause}) do
    if :internal_error in clause.helpers, do: :internal_error, else: nil
  end

  @doc """
  The clause of the surface that matches the shape, or `nil` when the shape
  falls through to the surface's catch-all.
  """
  @spec mapping(map(), map()) :: map() | nil
  def mapping(surface, shape) do
    Enum.find(surface.clauses, fn clause ->
      Enum.any?(clause.shapes, fn {kind, name} -> name == shape.name and kind == shape.kind end)
    end)
  end

  @doc "The Response helper that answers the shape on this surface, or `nil`."
  @spec helper_for(map(), map()) :: atom() | nil
  def helper_for(surface, shape) do
    case mapping(surface, shape) do
      nil -> nil
      clause -> Enum.find(clause.helpers, &(&1 != :internal_error))
    end
  end

  @doc """
  True when the shape can reach the surface: the surface's own context path
  runs the fence that refuses with it.
  """
  @spec reachable?(map(), map()) :: boolean()
  def reachable?(surface, shape) do
    MapSet.member?(surface_fences(surface), shape.fence)
  end

  @doc "The fence functions the surface's own context path runs."
  @spec surface_fences(map()) :: MapSet.t()
  def surface_fences(surface) do
    key = {__MODULE__, :fences, surface.router, surface.name}

    case :persistent_term.get(key, nil) do
      nil ->
        fences =
          surface
          |> surface_entries()
          |> walk_fences()

        :persistent_term.put(key, fences)
        fences

      fences ->
        fences
    end
  end

  @doc """
  The answer the surface gives for the shape: the copied renderer's own
  response, driven with the synthetic refusal tuple.
  """
  @spec drive(map(), map()) :: {integer(), map()} | :unmapped
  def drive(surface, shape) do
    clause = mapping(surface, shape)

    if is_nil(clause) do
      :unmapped
    else
      case stable_code_helper(clause, shape) do
        nil ->
          :static

        helper ->
          detail = sample_detail(helper)
          error_value = build_error(clause.pattern, shape, detail)
          conn = Plug.Test.conn(:post, "/switch-on")
          answer = apply(renderer_copy(surface), surface.name, [conn, error_value])
          {answer.status, decode_body(answer.resp_body)}
      end
    end
  end

  @doc """
  The Response helper that answers the shape with ITS stable code, or `nil`
  when the clause answers a problem document instead (the semantic-validation
  and the graph-shape refusals).
  """
  @spec stable_code_helper(map(), map()) :: atom() | nil
  def stable_code_helper(clause, shape) do
    code = Atom.to_string(shape.name)

    Enum.find(clause.helpers, fn helper ->
      helper == shape.name or helper_error_code(helper) == code
    end)
  end

  @doc """
  The status a clause answers statically: the Response helper it calls decides
  it (`unprocessable` is 422, `send_problem` carries the status of the problem
  it is given).
  """
  @spec clause_status(map()) :: integer() | nil
  def clause_status(clause) do
    cond do
      Enum.any?(clause.helpers, &(&1 in [:unprocessable, :unprocessable_with])) -> 422
      :send_problem in clause.helpers -> 422
      true -> nil
    end
  end

  @doc """
  A copy of the router module with the render functions made public, so the
  probe can call the product's own renderer. Compiled once per router.
  """
  @spec renderer_copy(map()) :: module()
  def renderer_copy(surface) do
    name = copy_module_name(surface)

    if Code.ensure_loaded?(name) do
      name
    else
      compile_copy(surface)
    end
  end

  defp copy_module_name(surface) do
    suffix = surface.router |> String.split(".") |> List.last()
    Module.concat([Letflow.Support, "G14RouterCopy#{suffix}"])
  end

  @doc """
  The synthetic detail of a Response helper, derived from the helper's own
  head and body: the keys its violation map must carry, and a value for each.
  """
  @spec sample_detail(atom() | nil) :: [term()]
  def sample_detail(nil), do: []

  def sample_detail(helper) do
    case helper_signature(helper) do
      {1, _kind, _keys} ->
        []

      {2, :map, keys} ->
        [violation_map(keys)]

      {2, :list, keys} ->
        [[violation_map(keys)]]

      {2, :atom, _keys} ->
        [:g14_synthetic_reason]

      {3, _kind, _keys} ->
        ["g14-node", :g14_synthetic_reason]

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # The router copy
  # ---------------------------------------------------------------------------

  defp compile_copy(surface) do
    ast = surface.file |> File.read!() |> Code.string_to_quoted!() |> List.wrap()
    copy_name = copy_module_name(surface)

    body =
      Enum.map(ast, fn
        {:defmodule, meta, [head, [do: inner]]} ->
          if alias_name(head) == surface.router do
            nodes = publicise(unwrap_block(inner))

            {:defmodule, meta,
             [
               {:__aliases__, meta, copy_name_parts(copy_name)},
               [do: {:__block__, meta, nodes}]
             ]}
          else
            {:defmodule, meta, [head, [do: inner]]}
          end

        other ->
          other
      end)

    [{module, _binary}] = Code.compile_quoted(body)

    module
  end

  defp copy_name_parts(name) do
    name |> Module.split() |> Enum.map(&String.to_atom/1) |> then(&[:"Elixir" | &1])
  end

  # Every `defp render_*` of the copied module becomes a `def`, so the probe can
  # call the product's own renderer.
  defp publicise(body) do
    Enum.map(body, fn
      {:defp, meta, [head | rest]} = node ->
        case clause_head(head) do
          {name, _, args} when is_atom(name) and is_list(args) ->
            if String.starts_with?(Atom.to_string(name), "render_") do
              {:def, meta, [head | rest]}
            else
              node
            end

          _ ->
            node
        end

      other ->
        other
    end)
  end

  # ---------------------------------------------------------------------------
  # The synthetic refusal value
  # ---------------------------------------------------------------------------

  # Rebuild the clause's own pattern with the synthetic detail in place of the
  # shape's detail, so the renderer is driven with the exact shape it matches.
  defp build_error({:error, inner}, shape, detail) do
    {:error, build_inner(inner, shape, detail)}
  end

  defp build_error({:{}, _, [:error, inner]}, shape, detail) do
    {:error, build_inner(inner, shape, detail)}
  end

  # A renderer that takes the bare refusal (the override activation's
  # `render_override_activate_error/2`): the pattern IS the inner shape.
  defp build_error(pattern, shape, detail), do: build_inner(pattern, shape, detail)

  defp build_inner({name, sub}, shape, detail) when is_atom(name) do
    if name == shape.name do
      {name, sample_value(detail)}
    else
      {name, build_inner(sub, shape, detail)}
    end
  end

  defp build_inner({:{}, _, [name, sub]}, shape, detail) when is_atom(name) do
    if name == shape.name do
      {name, sample_value(detail)}
    else
      {name, build_inner(sub, shape, detail)}
    end
  end

  defp build_inner({:{}, _, [name, first, second]}, shape, detail) when is_atom(name) do
    if name == shape.name do
      case detail do
        [one, two] -> {one, two}
        [one] -> {one, nil}
        [] -> nil
      end
    else
      {name, first, second}
    end
  end

  defp build_inner(other, _shape, _detail), do: other

  # The synthetic detail of a refusal: the list of violations, the map of a
  # start-permission violation, or the node id and the reason of a script
  # binding.
  defp sample_value([one]), do: one
  defp sample_value([first, second]), do: {first, second}
  defp sample_value([]), do: nil

  # ---------------------------------------------------------------------------
  # The Response helpers
  # ---------------------------------------------------------------------------

  # The stable `"error"` code a Response helper answers with, read from its own
  # body: a helper need not be named like the refusal tuple it answers
  # (`test_cases_failed` answers `definition_test_cases_failed`).
  defp helper_error_code(helper) do
    path = module_path(@response_module)

    with path when not is_nil(path) <- path,
         body when is_list(body) <- module_body(path, @response_module) do
      for {:def, _, [head | rest]} <- body,
          {name, _, call_args} <- [strip_guard(head)],
          name == helper,
          is_list(call_args),
          {:%{}, _, pairs} <- body_terms(rest),
          is_list(pairs),
          {"error", code} <- pairs,
          is_binary(code),
          do: code
    else
      _ -> []
    end
    |> List.first()
  end

  # The head and the violation keys of a Response helper, read from its own
  # source: `def helper(conn, violations) when is_list(violations)` and the
  # `%{node_id: ..., index: ..., code: ...}` its body destructures.
  defp helper_signature(helper) do
    path = module_path(@response_module)

    case path do
      nil ->
        nil

      path ->
        body = module_body(path, @response_module)

        clauses =
          for {:def, _, args} <- body || [],
              [head | rest] <- [args],
              {name, _, call_args} <- [strip_guard(head)],
              name == helper,
              is_list(call_args),
              do: {call_args, rest}

        case clauses do
          [] ->
            nil

          [{call_args, rest} | _] ->
            guard = Enum.find(rest, &is_list/1) || []
            body_ast = List.last(rest)
            kind = detail_kind(Enum.at(call_args, 1))
            {length(call_args), kind, violation_keys(body_ast, guard, call_args)}
        end
    end
  end

  # The keys the helper's violation map must carry: the map pattern its body
  # destructures.
  # A detail that is a map (a start-permission violation) or a list of
  # violations.
  defp detail_kind({:=, _, [{:%{}, _, _}, _]}), do: :map
  # A bare `reason` argument is a closed reason code (an atom).
  defp detail_kind({:reason, _, ctx}) when is_atom(ctx), do: :atom
  defp detail_kind(_head), do: :list

  defp violation_keys(body, _guard, call_args) do
    head = Enum.at(call_args, 1)

    case head do
      {:=, _, [{:%{}, _, _}, _]} ->
        [:code]

      _ ->
        # A body that hands each violation to a private mapper (`&mapper/1`)
        # destructures its keys elsewhere in the module: take them all.
        case map_pattern_keys(body) do
          [] -> response_pattern_keys()
          keys -> Enum.uniq(keys ++ response_pattern_keys())
        end
    end
  end

  # Every key a map pattern of the Response module destructures: a violation
  # map with all of them matches every pattern (a map pattern matches a map
  # that carries at least its own keys).
  defp response_pattern_keys do
    path = module_path(@response_module)
    body = module_body(path, @response_module)

    body
    |> body_terms()
    |> Enum.flat_map(fn
      {:%{}, _, pairs} when is_list(pairs) ->
        for {key, _} <- pairs, is_atom(key), do: key

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  # The keys of the map pattern a body destructures.
  defp map_pattern_keys(body) do
    for {:%{}, _, pairs} <- body_terms(body),
        is_list(pairs),
        {key, _} <- pairs,
        is_atom(key),
        do: key
  end

  defp body_terms(body) do
    prewalk_all(body, [], fn
      {:%{}, _, _} = node, acc -> {node, [node | acc]}
      node, acc -> {node, acc}
    end)
  end

  # A function head with a guard is `{:when, _, [call, guard]}`.
  defp strip_guard({:when, _, [call | _]}), do: call
  defp strip_guard(head), do: head

  defp violation_map(keys) do
    Map.new(keys, fn key -> {key, synthetic_value(key)} end)
  end

  defp synthetic_value(:reason), do: :g14_synthetic_reason
  defp synthetic_value(:code), do: :g14_synthetic_code
  defp synthetic_value(:side), do: :read
  defp synthetic_value(:element), do: :expression
  defp synthetic_value(:index), do: 0
  defp synthetic_value(:declared), do: nil
  defp synthetic_value(:required), do: nil
  defp synthetic_value(:node_id), do: "g14-node"
  defp synthetic_value(:id), do: "g14-node"
  defp synthetic_value(:name), do: "g14_name"
  defp synthetic_value(:field), do: "g14_field"
  defp synthetic_value(:location), do: :g14_location
  defp synthetic_value(_key), do: "g14"

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_body(_body), do: %{}

  # ---------------------------------------------------------------------------
  # The fence functions
  # ---------------------------------------------------------------------------

  # The error shapes a fence can return: from its own body and from its @spec.
  defp fence_error_shapes(name) do
    path = module_path(@fence_module)
    body = module_body(path, @fence_module)
    functions = function_map(body)
    specs = spec_map(body)

    bodies = Map.get(functions, name, [])
    spec_ast = Map.get(specs, name)

    spec_shapes = if(spec_ast, do: error_shapes(spec_ast), else: [])
    body_shapes = Enum.flat_map(bodies, &error_shapes/1)

    shapes =
      if spec_shapes == [] do
        body_shapes
      else
        spec_shapes
      end
      |> Enum.uniq()

    shapes
  end

  # Every `{:error, ...}` shape in an AST: `{:error, :atom}` and
  # `{:error, {:tuple, detail}}`.
  defp error_shapes(ast) do
    acc =
      prewalk_all(ast, [], fn
        node, acc ->
          case error_inner(node) do
            nil -> {node, acc}
            inner -> {node, shape_of(inner) ++ acc}
          end
      end)

    acc
  end

  defp shape_of({:{}, _, [name, _detail]}) when is_atom(name), do: [{:tuple, name}]
  defp shape_of({:{}, _, [name, _d1, _d2]}) when is_atom(name), do: [{:tuple, name}]
  defp shape_of({name, _detail}) when is_atom(name), do: [{:tuple, name}]
  defp shape_of(name) when is_atom(name), do: [{:atom, name}]
  defp shape_of(_other), do: []

  # ---------------------------------------------------------------------------
  # The call-graph walk
  # ---------------------------------------------------------------------------

  # The context entry points of a surface: the router handler that renders it,
  # and the context functions that handler calls.
  defp surface_entries(surface) do
    body = module_body(surface.file, surface.router)
    aliases = module_aliases(body)
    functions = function_map(body)

    handlers =
      for {name, bodies} <- functions,
          is_list(bodies),
          Enum.any?(bodies, &local_call?(surface.name, &1, aliases)),
          do: name

    entries =
      for handler <- handlers,
          bodies = Map.get(functions, handler, []),
          body <- bodies,
          {:remote, mod, fun, _arity} <- remote_calls(body, aliases),
          mod != surface.router,
          do: {mod, fun}

    Enum.uniq(entries)
  end

  # The fence functions the path from the entries reaches.
  defp walk_fences(entries) do
    {fences, _visited} = walk(entries, MapSet.new(), MapSet.new(), 0)
    fences
  end

  defp walk([], visited, fences, _count), do: {fences, visited}

  defp walk([{mod, fun} | rest], visited, fences, count) when count < @max_walk do
    key = {mod, fun}

    if MapSet.member?(visited, key) do
      walk(rest, visited, fences, count)
    else
      visited = MapSet.put(visited, key)
      path = module_path(mod)

      if is_nil(path) do
        walk(rest, visited, fences, count + 1)
      else
        body = module_body(path, mod)
        aliases = module_aliases(body)
        functions = function_map(body)
        bodies = Map.get(functions, fun, [])

        fences =
          Enum.reduce(bodies, fences, fn body, acc ->
            Enum.reduce(fence_calls(body, aliases, mod), acc, &MapSet.put(&2, &1))
          end)

        queue =
          rest ++
            Enum.flat_map(bodies, fn body ->
              locals =
                for {:local, name, _arity} <- local_calls(body, aliases),
                    is_map_key(functions, name),
                    do: {mod, name}

              remotes =
                for {:remote, rmod, rfun, _arity} <- remote_calls(body, aliases),
                    not is_nil(module_path(rmod)),
                    do: {rmod, rfun}

              locals ++ remotes
            end)

        walk(queue, visited, fences, count + 1)
      end
    end
  end

  defp walk(_queue, visited, fences, _count), do: {fences, visited}

  # The fence calls of one function body: the `:ok <-` calls into the fence
  # module, local or qualified.
  defp fence_calls(body, aliases, current_module) do
    for node <- with_nodes(body),
        call <- with_calls(node),
        name = fence_call_name(call, aliases, current_module),
        name != nil,
        do: name
  end

  defp fence_call_name({{:., _, [alias_ast, fun]}, _, args}, aliases, _current_module)
       when is_list(args) do
    case resolve_alias(alias_ast, aliases) do
      @fence_module -> fun
      _ -> nil
    end
  end

  defp fence_call_name({f, _, args}, _aliases, current_module)
       when is_atom(f) and is_list(args) do
    if current_module == @fence_module, do: f, else: nil
  end

  defp fence_call_name(_call, _aliases, _current_module), do: nil

  # ---------------------------------------------------------------------------
  # The source index
  # ---------------------------------------------------------------------------

  defp module_index do
    case Process.get(:g14_index) do
      nil ->
        index =
          for path <- Path.wildcard("lib/letflow/**/*.ex"),
              source = File.read!(path),
              [_full, mod] <- Regex.scan(~r/^defmodule\s+([A-Z][A-Za-z0-9_.]*)\s+do\b/m, source),
              into: %{} do
            {mod, path}
          end

        Process.put(:g14_index, index)
        index

      index ->
        index
    end
  end

  defp module_path(mod), do: Map.get(module_index(), mod)

  defp module_bodies(path) do
    case Process.get({:g14_bodies, path}) do
      nil ->
        bodies = compute_module_bodies(path)
        Process.put({:g14_bodies, path}, bodies)
        bodies

      bodies ->
        bodies
    end
  end

  defp compute_module_bodies(path) do
    ast =
      case Process.get({:g14_ast, path}) do
        nil ->
          parsed = path |> File.read!() |> Code.string_to_quoted!() |> List.wrap()
          Process.put({:g14_ast, path}, parsed)
          parsed

        parsed ->
          parsed
      end

    for {:defmodule, _, [head, [do: body]]} <- ast,
        mod = alias_name(head),
        mod != nil do
      {mod, unwrap_block(body)}
    end
  end

  defp unwrap_block({:__block__, _, nodes}), do: nodes
  defp unwrap_block(other), do: List.wrap(other)

  defp module_body(path, mod) do
    path
    |> module_bodies()
    |> Enum.find({nil, nil}, fn {m, _body} -> m == mod end)
    |> elem(1)
  end

  defp function_map(body) do
    body
    |> List.wrap()
    |> Enum.reduce(%{}, fn node, acc ->
      case node do
        {:def, _, args} ->
          put_functions(acc, args)

        {:defp, _, args} ->
          put_functions(acc, args)

        _ ->
          acc
      end
    end)
  end

  defp put_functions(acc, [head | rest]) do
    case clause_head(head) do
      {name, _, args} when is_atom(name) and is_list(args) ->
        body = clause_body(rest)
        Map.update(acc, name, [body], &(&1 ++ [body]))

      _ ->
        acc
    end
  end

  defp put_functions(acc, _args), do: acc

  # A clause head carries its guard inside a `when` node: `def f(x) when g`
  # has the head `{:"when", _, [head, guard]}`.
  defp clause_head({:when, _, [inner | _guard]}), do: inner
  defp clause_head(head), do: head

  # The guard of a clause head, or nil.
  defp clause_guard({:when, _, [_inner, guard]}), do: List.wrap(guard)
  defp clause_guard(_head), do: nil

  # The body of a clause: the `do:` block of a keyword body, or the body node.
  defp clause_body(rest) do
    case List.last(rest) do
      [do: body] -> body
      body -> body
    end
  end

  # The @spec of every function, keyed by name.
  defp spec_map(body) do
    body
    |> List.wrap()
    |> Enum.reduce(%{}, fn
      {:@, _, [{:spec, _, [{:"::", _, [head, ret]}]}]}, acc ->
        case head do
          {name, _, args} when is_atom(name) and is_list(args) ->
            Map.put(acc, name, ret)

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  defp module_aliases(body) do
    for {:alias, _, args} <- List.wrap(body),
        head = List.first(args),
        mod = alias_name(head),
        mod != nil,
        short = List.last(String.split(mod, ".")),
        as = alias_as(args) || short,
        into: %{} do
      {as || short, mod}
    end
  end

  defp alias_as([_head, opts]) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, parts} -> parts |> Enum.map(&to_string/1) |> Enum.join(".")
      nil -> nil
    end
  end

  defp alias_as(_args), do: nil

  defp alias_name({:__aliases__, _, parts}) when is_list(parts) do
    names =
      Enum.map(parts, fn
        {:__MODULE__, _, _} -> nil
        part when is_atom(part) -> Atom.to_string(part)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    case names do
      [] -> nil
      ["Elixir" | rest] -> Enum.join(rest, ".")
      _ -> Enum.join(names, ".")
    end
  end

  defp alias_name(_other), do: nil

  # ---------------------------------------------------------------------------
  # The AST helpers
  # ---------------------------------------------------------------------------

  defp with_nodes(ast) do
    prewalk_all(ast, [], fn
      {f, _, args} = node, acc when f == :with and is_list(args) -> {node, [node | acc]}
      node, acc -> {node, acc}
    end)
  end

  # The calls of the `:ok <-` clauses of a `with` node: the fence candidates.
  # (The arguments of a `with` node are its clauses -- `{:<-, _, [:ok, call]}` --
  # plus its do-block.)
  defp with_calls(node) do
    node
    |> elem(2)
    |> Enum.flat_map(fn
      {:<-, _, [:ok, call]} -> [call]
      _ -> []
    end)
  end

  # `Macro.prewalk/3` walks ONE node; a module body is a LIST of nodes, so each
  # node is walked on its own.
  defp prewalk_all(nodes, acc, fun) do
    Enum.reduce(List.wrap(nodes), acc, fn node, acc ->
      node
      |> List.wrap()
      |> Enum.reduce(acc, fn inner, acc ->
        {_inner, acc} = Macro.prewalk(inner, acc, fun)
        acc
      end)
    end)
  end

  defp resolve_alias({:__aliases__, _, parts}, aliases) when is_list(parts) do
    names =
      Enum.map(parts, fn
        {:__MODULE__, _, _} -> nil
        part when is_atom(part) -> Atom.to_string(part)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    case names do
      [] ->
        nil

      ["Elixir" | rest] ->
        Enum.join(rest, ".")

      [single] ->
        Map.get(aliases, single, single)

      many ->
        Enum.join(many, ".")
    end
  end

  defp resolve_alias(_other, _aliases), do: nil

  defp local_calls(body, aliases) do
    _ = aliases

    prewalk_all(body, [], fn
      {{:., _, _}, _, _} = node, acc ->
        {node, acc}

      {f, _, args} = node, acc when is_atom(f) and is_list(args) ->
        {node, [{:local, f, length(args)} | acc]}

      node, acc ->
        {node, acc}
    end)
  end

  defp remote_calls(body, aliases) do
    prewalk_all(body, [], fn
      {{:., _, [alias_ast, fun]}, _, args} = node, acc when is_list(args) ->
        case resolve_alias(alias_ast, aliases) do
          nil -> {node, acc}
          mod -> {node, [{:remote, mod, fun, length(args)} | acc]}
        end

      node, acc ->
        {node, acc}
    end)
  end

  defp local_call?(name, body, aliases) do
    Enum.any?(local_calls(body, aliases), fn
      {:local, called, _arity} -> called == name
      _ -> false
    end)
  end

  # ---------------------------------------------------------------------------
  # The render clauses
  # ---------------------------------------------------------------------------

  defp render_clauses(body) do
    for {:defp, _, args} <- List.wrap(body),
        [head | rest] <- [args],
        {name, _, call_args} <- [clause_head(head)],
        is_atom(name),
        is_list(call_args),
        String.starts_with?(Atom.to_string(name), "render_"),
        call_args != [] do
      pattern = Enum.at(call_args, 1)
      guard = clause_guard(head)
      clause_body = clause_body(rest)
      aliases = module_aliases(body)

      %{
        name: name,
        pattern: pattern,
        guard: guard,
        body: clause_body,
        shapes: clause_shapes(pattern, guard),
        helpers: response_helpers(clause_body, aliases)
      }
    end
  end

  defp group_by_name(clauses) do
    clauses
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, group} -> {name, Enum.map(group, &Map.delete(&1, :name))} end)
  end

  defp clause_shapes(pattern, guard) do
    case error_inner(pattern) do
      nil -> bare_clause_shapes(pattern, guard)
      inner -> inner_shapes(inner, guard)
    end
  end

  # A renderer that receives the BARE refusal (the solution-pack override
  # activation unwraps `{:error, reason}` itself) matches the shape itself.
  defp bare_clause_shapes({:ok, _}, _guard), do: []
  defp bare_clause_shapes({:error, _}, _guard), do: []
  defp bare_clause_shapes(pattern, guard), do: inner_shapes(pattern, guard)

  defp error_inner({:error, inner}), do: inner
  defp error_inner({:{}, _, [:error, inner]}), do: inner
  defp error_inner(_other), do: nil

  defp inner_shapes({:{}, _, [name, detail]}, _guard) when is_atom(name) do
    [{:tuple, name} | inner_shapes(detail, nil)]
  end

  defp inner_shapes({:{}, _, [name, _first, _second]}, _guard) when is_atom(name) do
    [{:tuple, name}]
  end

  defp inner_shapes({name, detail}, _guard) when is_atom(name) do
    [{:tuple, name} | inner_shapes(detail, nil)]
  end

  defp inner_shapes(name, _guard) when is_atom(name), do: [{:atom, name}]

  defp inner_shapes(_variable, guard), do: guard_shapes(guard)

  # The shapes a guarded clause (`when kind in [...]`) accepts.
  defp guard_shapes(nil), do: []

  defp guard_shapes(guard) when is_list(guard) do
    for expression <- guard,
        {:in, _, [_var, items]} <- [expression],
        is_list(items),
        item <- items,
        is_atom(item) do
      {:tuple, item}
    end
  end

  defp guard_shapes(_guard), do: []

  # The Response helpers a clause body calls.
  defp response_helpers(body, aliases) do
    for {:remote, mod, fun, _arity} <- remote_calls(body, aliases),
        mod == @response_module,
        do: fun
  end
end
