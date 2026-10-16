defmodule Letflow.Entities.HandlerWritesCallersTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R4a (design `lib/letflow/design/gh2590-req501-module-write-handlers.md`
  7.4, scans H1-H5): who may resolve, call, construct and be a module write handler. Pure AST
  over `lib/**/*.ex` and `test/support/**/*.ex` (`test/**/*.exs` is excluded: test bodies forge
  values on purpose), the same shape and accepted limits as the sibling caller scans
  (`managed_types_callers_test`, `command_multi_callers_test`, `step_source_callers_test`).
  Each rule is a pure function over source text; the real-tree tests and the synthetic
  non-vacuity tests run the SAME function.

    * H1: `owner_for_handler` (call, capture, `apply/3`) only in `managed_types.ex` (definer)
      and `handler_writes.ex`.
    * H2: `%WriteHandler{}` literals / `struct/2` / `%{__struct__: ..}` only in `catalog.ex`;
      `%HandlerContext{}` only in `handler_writes.ex`.
    * H3: `write_handler` (the resolver) only in `catalog.ex`, `handler_writes.ex`,
      `managed_types.ex` (`owner_for_handler/2` re-resolves) and `definitions/module_writes.ex`
      (R3 activation validation, read-only; design rev 3 moved it out of the port, so the design
      text's "definitions NOT allowed" no longer holds); `call_write_handler` only in
      `catalog.ex` (definer) and `handler_writes.ex`; `write_handler_in` only in `catalog.ex`
      (the test seam).
    * H4: handler PURITY. The handler files are derived at run time from the compiled
      manifests (`Catalog.all_manifests/0` and each handler's module `compile` source), and
      none may reference `Repo`, a `repo` variable, `Ecto.Query`/`from`, any `Ecto.Multi` call
      but `new/0` and `append/2`, `Records`, `Owner`, `StepSource`, `ManagedTypes`,
      `EventStore`, process / I/O / clock modules, atom-creating calls, `apply/3` with a
      non-literal module, a map update or `Map.put`-style change of a context key, or any
      `HandlerWrites` call but `create/3`. R4b (SECURITY re-review of R4a) closes the scan gaps:
      a remote call with an ATOM-LITERAL receiver outside a short allowlist (`:ets`,
      `:persistent_term`, `:code`, a quoted `:"Elixir.Process"`, ...), a remote call on a
      VARIABLE receiver (`m.put(..)`), a `%Multi{}` literal, a field access on the Multi
      parameter (`multi.operations`), and `Map.*`/`Keyword.*` on the Multi or context variable;
      the source is pipe-normalised first, so `multi |> Map.put(..)` is seen. It is a tripwire,
      not the boundary: the boundary is that the API hands a handler nothing dangerous. The
      negative control is the deliberately misbehaving `FixtureLedgerRogue` file, which MUST be
      flagged.
    * H5: `Definitions.create_owned/3` only in `solution_pack.ex` (folded in from R2's
      `create_owned_callers_test.exs`).

  Accepted limits, as in the siblings: computed function names, `Code.eval_*`, macros defined
  away from the call site, `%__MODULE__{}` forms and dependencies are not seen.
  """

  use ExUnit.Case, async: true

  @managed_types "lib/letflow/entities/managed_types.ex"
  @handler_writes "lib/letflow/entities/handler_writes.ex"
  @catalog "lib/letflow/modules/catalog.ex"
  @module_writes "lib/letflow/definitions/module_writes.ex"
  @solution_pack "lib/letflow/definitions/solution_pack.ex"
  @rogue "test/support/modules/fixture_ledger_rogue/fixture_ledger_rogue.ex"

  @h1_allowed [@managed_types, @handler_writes]
  @h3_resolver_allowed [@catalog, @handler_writes, @managed_types, @module_writes]
  @h3_call_allowed [@catalog, @handler_writes]
  @h3_seam_allowed [@catalog]
  @h5_allowed [@solution_pack]

  @context_keys ~w(prefix instance_id origin node_id definition_id definition_version line_index
                   actor_id subject_id activator_id handler)a

  @forbidden_aliases ~w(Repo Records Owner StepSource ManagedTypes EventStore Task Process GenServer
                        Agent Req Finch HTTPoison System File IO Code Query Application
                        HandlerContext)a
  @forbidden_calls ~w(spawn spawn_link spawn_monitor send from)a
  @forbidden_atom_modules ~w(httpc inets gen_tcp os file erlang)a
  @atom_creators [{[:String], :to_atom}, {[:String], :to_existing_atom}, {[:Module], :concat}]
  @map_changers ~w(put put_new put_new_lazy replace replace! merge update update! delete
                   from_struct pop pop_lazy drop take reject filter split get_and_update
                   get_and_update! new)a

  # Erlang modules a pure handler may legitimately call by atom receiver (data transformation
  # only). Any OTHER atom-literal receiver, including a quoted `:"Elixir.Process"`, is flagged.
  @atom_receivers_allowed ~w(maps lists string binary math unicode)a

  defp scanned_files do
    (Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/support/**/*.ex")) |> Enum.sort()
  end

  defp sources, do: for(path <- scanned_files(), do: {path, File.read!(path)})

  defp parse(source), do: Code.string_to_quoted!(source, columns: false)

  # ── name references (calls, captures, applies) ──────────────────────────────────────────────

  # Lines of every call / capture / apply naming `name` in `source`. A `@spec`/`@doc` attribute
  # and a definition head `def name(..)` are not references.
  defp name_refs(source, name) do
    {_ast, hits} =
      source
      |> parse()
      |> Macro.prewalk([], fn
        {:@, _, _}, acc ->
          {{:__attribute__, [], []}, acc}

        {kind, meta, [head | rest]}, acc when kind in [:def, :defp, :defmacro, :defmacrop] ->
          params =
            case head do
              {:when, _, [{_name, _, params} | _guards]} -> params
              {_name, _, params} -> params
            end

          {{kind, meta, [{:__head__, [], params || []} | rest]}, acc}

        {^name, meta, args}, acc when is_list(args) ->
          {{:__local_call__, [], args}, [Keyword.get(meta, :line, 0) | acc]}

        # a local capture `&name/2`
        {:&, _, [{:/, _, [{^name, meta, ctx}, _arity]}]}, acc when is_atom(ctx) ->
          {{:__capture__, [], []}, [Keyword.get(meta, :line, 0) | acc]}

        {{:., meta, [_receiver, ^name]}, _call_meta, _args} = node, acc ->
          {node, [Keyword.get(meta, :line, 0) | acc]}

        {:apply, meta, [_mod, ^name, _args]} = node, acc ->
          {node, [Keyword.get(meta, :line, 0) | acc]}

        {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, meta, [_mod, ^name, _args]} = node,
        acc ->
          {node, [Keyword.get(meta, :line, 0) | acc]}

        {{:., _, [:erlang, :apply]}, meta, [_mod, ^name, _args]} = node, acc ->
          {node, [Keyword.get(meta, :line, 0) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(hits)
  end

  defp offenders(file_sources, name, allowed) do
    for {path, source} <- file_sources,
        path not in allowed,
        name_refs(source, name) != [],
        do: path
  end

  # ── struct construction (H2) ────────────────────────────────────────────────────────────────

  # True when `source` builds the struct whose alias ends in `last`: `%X{}`, `struct/struct!(X, ..)`,
  # `%{__struct__: X}`, `Map.put*(m, :__struct__, X)`.
  defp builds_struct?(source, last) do
    {_ast, found} =
      source
      |> parse()
      |> Macro.prewalk(false, fn
        {:%, _, [{:__aliases__, _, parts}, _]} = node, acc ->
          {node, acc or List.last(parts) == last}

        {fun, _, [{:__aliases__, _, parts} | _]} = node, acc when fun in [:struct, :struct!] ->
          {node, acc or List.last(parts) == last}

        {{:., _, [{:__aliases__, _, [:Kernel]}, fun]}, _, [{:__aliases__, _, parts} | _]} = node,
        acc
        when fun in [:struct, :struct!] ->
          {node, acc or List.last(parts) == last}

        {:%{}, _, pairs} = node, acc when is_list(pairs) ->
          hit? =
            Enum.any?(pairs, fn
              {:__struct__, {:__aliases__, _, parts}} -> List.last(parts) == last
              _ -> false
            end)

          {node, acc or hit?}

        {{:., _, [{:__aliases__, _, [:Map]}, fun]}, _,
         [_map, :__struct__, {:__aliases__, _, parts}]} =
            node,
        acc
        when fun in [:put, :put_new, :replace, :replace!] ->
          {node, acc or List.last(parts) == last}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp struct_offenders(file_sources, last, allowed) do
    for {path, source} <- file_sources,
        path not in allowed,
        builds_struct?(source, last),
        do: path
  end

  # ── H4: handler purity ──────────────────────────────────────────────────────────────────────

  # Human-readable violations of one handler file (empty when clean).
  defp purity_violations(source) do
    ast = source |> parse() |> unpipe()
    ctx_vars = ctx_names(ast, 1) ++ ctx_names(ast, 0)
    multi_vars = ctx_names(ast, 0)

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        # `alias X, as: Y` hides which module a later call names; `import Ecto.Multi/Query` hides
        # the receiver altogether
        {:alias, _, [_module, opts]} = node, acc when is_list(opts) ->
          {node, if(Keyword.has_key?(opts, :as), do: [{:alias, :as} | acc], else: acc)}

        {:import, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          last = List.last(parts)
          {node, if(last in [:Multi, :Query], do: [{:import, last} | acc], else: acc)}

        # module attributes (docs, specs) are data
        {:@, _, _}, acc ->
          {{:__attribute__, [], []}, acc}

        {:__aliases__, _, parts} = node, acc ->
          last = List.last(parts)
          {node, if(last in @forbidden_aliases, do: [{:alias, last} | acc], else: acc)}

        {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [mod | _]} = node, acc ->
          {node, acc ++ non_literal_apply(mod)}

        {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = node, acc when is_list(args) ->
          {node, acc ++ remote_violations(parts, fun, args, ctx_vars)}

        # an ATOM-literal receiver (`:ets.insert(..)`, `:"Elixir.Process".put(..)`)
        {{:., _, [receiver, fun]}, _, args} = node, acc
        when is_atom(receiver) and not is_nil(receiver) and not is_boolean(receiver) and
               is_list(args) ->
          hit? = receiver not in @atom_receivers_allowed
          {node, if(hit?, do: [{:atom_receiver, receiver}, {:atom_call, fun} | acc], else: acc)}

        # a VARIABLE receiver: a call (`m.put(..)`) or a field access on the Multi parameter
        {{:., _, [{name, _, var_ctx}, fun]}, call_meta, args} = node, acc
        when is_atom(name) and is_atom(var_ctx) and name != :__MODULE__ and is_list(args) ->
          cond do
            not Keyword.get(call_meta, :no_parens, false) ->
              {node, [{:var_receiver, name} | acc]}

            name in multi_vars ->
              {node, [{:multi_field, fun} | acc]}

            true ->
              {node, acc}
          end

        # a `%Multi{}` / `%Ecto.Multi{}` literal (forging or rebuilding a Multi)
        {:%, _, [{:__aliases__, _, parts}, _]} = node, acc ->
          {node, if(List.last(parts) == :Multi, do: [{:multi_literal, :Multi} | acc], else: acc)}

        {:apply, _, [mod | _]} = node, acc ->
          {node, acc ++ non_literal_apply(mod)}

        {fun, _, args} = node, acc when fun in @forbidden_calls and is_list(args) ->
          {node, [{:call, fun} | acc]}

        {:repo, _, _} = node, acc ->
          {node, [{:repo, :variable} | acc]}

        {fun, _, args} = node, acc
        when fun in [:struct, :struct!, :put_in, :update_in] and is_list(args) ->
          {node, [{:call, fun} | acc]}

        # `%{ctx | handler: x}` / `%HandlerContext{ctx | ..}` (a context forgery)
        {:%{}, _, [{:|, _, _} | _]} = node, acc ->
          {node, [{:map_update, :context} | acc]}

        atom, acc when is_atom(atom) and atom in @forbidden_atom_modules ->
          {atom, [{:erlang_module, atom} | acc]}

        node, acc ->
          {node, acc}
      end)

    found |> Enum.uniq() |> Enum.sort()
  end

  defp non_literal_apply({:__aliases__, _, _}), do: []
  defp non_literal_apply(atom) when is_atom(atom), do: []
  defp non_literal_apply(_other), do: [{:apply, :non_literal_module}]

  # `a |> f(b)` becomes `f(a, b)` (also for remote calls), innermost first, so the checks below see
  # the piped value as the first argument.
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

  # The names of the parameter at position `position` (0 = the Multi, 1 = the context) of every
  # arity-3 `def`/`defp`.
  defp ctx_names(ast, position) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head | _]} = node, acc when kind in [:def, :defp] ->
          params =
            case head do
              {:when, _, [{_name, _, params} | _guards]} -> params
              {_name, _, params} -> params
            end

          case params do
            [_, _, _] ->
              case Enum.at(params, position) do
                {name, _, ctx} when is_atom(name) and is_atom(ctx) -> {node, [name | acc]}
                _other -> {node, acc}
              end

            _other ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp ctx_var?({name, _, ctx}, names) when is_atom(name) and is_atom(ctx), do: name in names
  defp ctx_var?(_other, _names), do: false

  defp remote_violations([:Multi], fun, _args, _ctx) when fun in [:new, :append], do: []
  defp remote_violations([:Ecto, :Multi], fun, _args, _ctx) when fun in [:new, :append], do: []
  defp remote_violations([:Multi], fun, _args, _ctx), do: [{:multi, fun}]
  defp remote_violations([:Ecto, :Multi], fun, _args, _ctx), do: [{:multi, fun}]

  defp remote_violations(parts, fun, args, ctx_vars) do
    last = List.last(parts)

    cond do
      last == :HandlerWrites ->
        if fun == :create and length(args) == 3, do: [], else: [{:handler_writes, fun}]

      {parts, fun} in @atom_creators ->
        [{:atom_creation, fun}]

      parts in [[:Map], [:Keyword]] and fun in @map_changers and
          Enum.any?(args, &(context_key?(&1) or ctx_var?(&1, ctx_vars))) ->
        [{:map_change, fun}]

      true ->
        []
    end
  end

  defp context_key?(atom) when is_atom(atom), do: atom in @context_keys
  defp context_key?(_other), do: false

  # The handler FILES, derived from the compiled manifests (relative paths): EVERY .ex file under
  # the directory of each entry module that registers a handler and of each handler module (a
  # helper file in the module's namespace is as much handler code as the function's own file).
  defp handler_files do
    entries =
      for entry <- Letflow.Modules.Catalog.entry_modules(),
          Map.get(entry.manifest(), :write_handlers, []) != [],
          do: entry

    sources =
      for entry <- entries,
          mod <- [entry | Enum.map(entry.manifest().write_handlers, &elem(&1.function, 0))],
          path = compile_source(mod),
          do: path

    sources
    |> Enum.flat_map(fn path -> Path.wildcard(Path.join(Path.dirname(path), "**/*.ex")) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp compile_source(mod) do
    case mod.module_info(:compile)[:source] do
      nil -> nil
      source -> source |> to_string() |> Path.relative_to_cwd() |> String.replace("\\", "/")
    end
  end

  # ── real tree ───────────────────────────────────────────────────────────────────────────────

  setup_all do
    {:ok, files: sources()}
  end

  describe "real tree" do
    test "the scan set is non-trivial and includes the definers", %{files: files} do
      paths = Enum.map(files, &elem(&1, 0))
      assert length(paths) > 100

      for path <- [@managed_types, @handler_writes, @catalog, @module_writes, @solution_pack] do
        assert path in paths, path
      end
    end

    test "H1: owner_for_handler only in managed_types.ex and handler_writes.ex", %{files: files} do
      assert offenders(files, :owner_for_handler, @h1_allowed) == []

      # positive control: the allowed callers do reference it
      assert name_refs(File.read!(@handler_writes), :owner_for_handler) != []
    end

    test "H2: WriteHandler is built only in catalog.ex, HandlerContext only in handler_writes.ex",
         %{files: files} do
      # definers: catalog.ex builds %WriteHandler{}, handler_writes.ex builds %HandlerContext{}
      assert struct_offenders(files, :WriteHandler, [@catalog]) == []
      assert struct_offenders(files, :HandlerContext, [@handler_writes]) == []

      assert builds_struct?(File.read!(@catalog), :WriteHandler)
      assert builds_struct?(File.read!(@handler_writes), :HandlerContext)
    end

    test "H3: the resolver, the applier and the test seam have a closed set of callers",
         %{files: files} do
      assert offenders(files, :write_handler, @h3_resolver_allowed) == []
      assert offenders(files, :call_write_handler, @h3_call_allowed) == []
      assert offenders(files, :write_handler_in, @h3_seam_allowed) == []

      # positive controls
      assert name_refs(File.read!(@handler_writes), :call_write_handler) != []
      assert name_refs(File.read!(@module_writes), :write_handler) != []
    end

    test "H4: every handler file is pure, and the negative control is flagged" do
      files = handler_files()

      # non-vacuity: the registered fixture handler files are in the derived set
      assert "test/support/modules/fixture_ledger/handlers.ex" in files
      assert "test/support/modules/fixture_ledger_other/fixture_ledger_other.ex" in files
      assert @rogue in files

      for path <- files, path != @rogue do
        assert purity_violations(File.read!(path)) == [], path
      end

      # the deliberately misbehaving handler module IS flagged (the scan is not vacuous)
      flagged = purity_violations(File.read!(@rogue))

      for tag <- [
            {:multi, :run},
            {:multi, :insert_all},
            {:alias, :as},
            {:import, :Multi},
            {:map_change, :merge},
            {:repo, :variable},
            {:multi_field, :operations},
            {:map_update, :context}
          ] do
        assert tag in flagged, inspect(tag)
      end
    end

    test "H4: the real fixture handlers reach the platform only through HandlerWrites.create/3" do
      source = File.read!("test/support/modules/fixture_ledger/handlers.ex")
      assert source =~ "HandlerWrites.create("
      assert purity_violations(source) == []
    end

    test "H5: create_owned/3 is called only from solution_pack.ex", %{files: files} do
      assert offenders(files, :create_owned, @h5_allowed) == []
      assert name_refs(File.read!(@solution_pack), :create_owned) != []
    end
  end

  # ── synthetic positives and negatives ───────────────────────────────────────────────────────

  describe "non-vacuity on synthetic sources" do
    test "H1/H3/H5 name references: calls, captures and apply forms are flagged, docs are not" do
      for {name, snippet} <- [
            {:owner_for_handler,
             "defmodule A do\n  def f(m, h), do: ManagedTypes.owner_for_handler(m, h)\nend"},
            {:owner_for_handler,
             "defmodule A do\n  def f, do: &ManagedTypes.owner_for_handler/2\nend"},
            {:owner_for_handler,
             "defmodule A do\n  def f(a), do: apply(ManagedTypes, :owner_for_handler, a)\nend"},
            {:owner_for_handler,
             "defmodule A do\n  def f(m, h), do: m |> ManagedTypes.owner_for_handler(h)\nend"},
            {:owner_for_handler,
             "defmodule A do\n  import ManagedTypes, only: [owner_for_handler: 2]\n  def f(m, h), do: owner_for_handler(m, h)\nend"},
            {:write_handler,
             "defmodule A do\n  def f(m, h), do: Catalog.write_handler(m, h)\nend"},
            {:call_write_handler,
             "defmodule A do\n  def f(h, m, c, a), do: Catalog.call_write_handler(h, m, c, a)\nend"},
            {:call_write_handler,
             "defmodule A do\n  def f(a), do: Kernel.apply(Catalog, :call_write_handler, a)\nend"},
            {:write_handler_in,
             "defmodule A do\n  def f(l), do: Catalog.write_handler_in(l, 1, 2)\nend"},
            {:create_owned,
             "defmodule A do\n  def f(a, o), do: Letflow.Definitions.create_owned(a, [], o)\nend"},
            {:create_owned,
             "defmodule A do\n  def f, do: &Letflow.Definitions.create_owned/3\nend"},
            {:create_owned,
             "defmodule A do\n  def f(a), do: apply(Letflow.Definitions, :create_owned, a)\nend"},
            {:create_owned,
             "defmodule A do\n  import Letflow.Definitions, only: [create_owned: 3]\n  def f(a, o), do: a |> create_owned([], o)\nend"}
          ] do
        assert name_refs(snippet, name) != [], snippet
      end

      for {name, snippet} <- [
            {:owner_for_handler,
             "defmodule A do\n  @moduledoc \"see ManagedTypes.owner_for_handler/2\"\n  @spec owner_for_handler(term(), term()) :: term()\n  def owner_for_handler(a, b), do: {a, b}\nend"},
            {:create_owned,
             "defmodule A do\n  # Definitions.create_owned(a, b, c)\n  def f, do: 1\nend"},
            {:write_handler, "defmodule A do\n  def f(a), do: Catalog.fetch(a)\nend"}
          ] do
        assert name_refs(snippet, name) == [], snippet
      end
    end

    test "H2: every struct-construction form is flagged" do
      for snippet <- [
            "defmodule A do\n  def f, do: %HandlerContext{prefix: 1}\nend",
            "defmodule A do\n  def f, do: %Letflow.Entities.HandlerContext{}\nend",
            "defmodule A do\n  def f, do: struct(HandlerContext, [])\nend",
            "defmodule A do\n  def f, do: struct!(HandlerContext, [])\nend",
            "defmodule A do\n  def f, do: %{__struct__: HandlerContext}\nend",
            "defmodule A do\n  def f(m), do: Map.put(m, :__struct__, HandlerContext)\nend"
          ] do
        assert builds_struct?(snippet, :HandlerContext), snippet
      end

      refute builds_struct?("defmodule A do\n  def f, do: %WriteHandler{}\nend", :HandlerContext)

      refute builds_struct?(
               "defmodule A do\n  @type t :: HandlerContext.t()\nend",
               :HandlerContext
             )
    end

    test "H4: each forbidden form is flagged with its tag, and a compliant handler is clean" do
      body = fn expr -> "defmodule H do
  def h(m, c, a), do: #{expr}
end" end

      cases = [
        {body.("Repo.transaction(fn -> m end)"), {:alias, :Repo}},
        {body.("repo.query!(\"select 1\")"), {:repo, :variable}},
        {body.("Ecto.Multi.insert(m, :x, c)"), {:multi, :insert}},
        {body.("Ecto.Multi.run(m, :x, fn _, _ -> {:ok, 1} end)"), {:multi, :run}},
        {body.("Ecto.Multi.insert_all(m, :x, \"t\", [])"), {:multi, :insert_all}},
        {"defmodule H do
  alias Ecto.Multi
  def h(m, _c, _a), do: Multi.merge(m, fn _ -> m end)
end", {:multi, :merge}},
        {"defmodule H do
  alias Ecto.Multi, as: M
  def h(m, _c, _a), do: M.run(m, :x, fn _, _ -> {:ok, 1} end)
end", {:alias, :as}},
        {"defmodule H do
  import Ecto.Multi, only: [run: 3]
  def h(m, _c, _a), do: run(m, :x, fn _, _ -> {:ok, 1} end)
end", {:import, :Multi}},
        {"defmodule H do
  import Ecto.Query
  def h(_m, _c, _a), do: from(x in \"t\", select: x)
end", {:import, :Query}},
        {"defmodule H do
  import Ecto.Query
  def h(_m, _c, _a), do: from(x in \"t\", select: x)
end", {:call, :from}},
        {body.("Records.create_record(c, \"p\", :tenant)"), {:alias, :Records}},
        {body.("%Owner{module_id: \"x\", manages: nil}"), {:alias, :Owner}},
        {body.("StepSource.new(%{})"), {:alias, :StepSource}},
        {body.("ManagedTypes.owner_for_handler(\"a\", \"b\")"), {:alias, :ManagedTypes}},
        {body.("EventStore.append(%{}, [])"), {:alias, :EventStore}},
        {body.("File.read!(\"/etc/passwd\")"), {:alias, :File}},
        {body.("System.cmd(\"ls\", [])"), {:alias, :System}},
        {body.("Task.async(fn -> 1 end)"), {:alias, :Task}},
        {body.("Process.put(:k, 1)"), {:alias, :Process}},
        {body.("Agent.start_link(fn -> 1 end)"), {:alias, :Agent}},
        {body.("IO.puts(\"x\")"), {:alias, :IO}},
        {body.("Code.eval_string(a)"), {:alias, :Code}},
        {body.("Application.get_env(:a, :b)"), {:alias, :Application}},
        {body.("Req.get!(\"http://x\")"), {:alias, :Req}},
        {body.("Finch.request(a, b)"), {:alias, :Finch}},
        {body.("HTTPoison.get(\"http://x\")"), {:alias, :HTTPoison}},
        {body.("%HandlerContext{prefix: \"p\"}"), {:alias, :HandlerContext}},
        {body.("spawn(fn -> 1 end)"), {:call, :spawn}},
        {body.("send(self(), 1)"), {:call, :send}},
        {body.(":httpc.request(\"http://x\")"), {:erlang_module, :httpc}},
        {body.(":os.cmd(~c\"ls\")"), {:erlang_module, :os}},
        {body.(":file.read_file(\"x\")"), {:erlang_module, :file}},
        {body.(":gen_tcp.connect(~c\"h\", 1, [])"), {:erlang_module, :gen_tcp}},
        {body.(":erlang.put(:k, 1)"), {:erlang_module, :erlang}},
        {body.("apply(a, :f, [])"), {:apply, :non_literal_module}},
        {body.("Kernel.apply(a, :f, [])"), {:apply, :non_literal_module}},
        {body.("String.to_atom(a)"), {:atom_creation, :to_atom}},
        {body.("String.to_existing_atom(a)"), {:atom_creation, :to_existing_atom}},
        {body.("Module.concat(a, B)"), {:atom_creation, :concat}},
        {body.("%{c | handler: nil}"), {:map_update, :context}},
        {body.("Map.put(c, :handler, nil)"), {:map_change, :put}},
        {body.("Map.merge(c, %{prefix: \"other\"})"), {:map_change, :merge}},
        {body.("Map.update(c, :k, 1, & &1)"), {:map_change, :update}},
        {body.("Keyword.merge(c, [])"), {:map_change, :merge}},
        {body.("struct(c, prefix: \"p\")"), {:call, :struct}},
        {body.("struct!(c, prefix: \"p\")"), {:call, :struct!}},
        {body.("put_in(c.prefix, \"p\")"), {:call, :put_in}},
        {body.("update_in(c.prefix, & &1)"), {:call, :update_in}},
        {body.("HandlerWrites.build_call(m, c, %{}, %{})"), {:handler_writes, :build_call}},
        {body.("HandlerWrites.lock_types(m, [], \"p\")"), {:handler_writes, :lock_types}},
        {body.("HandlerWrites.create(m, c)"), {:handler_writes, :create}},
        {body.("HandlerWrites.authorize_module_writes([], %{})"),
         {:handler_writes, :authorize_module_writes}},
        # R4b, SECURITY re-review of R4a: the scan gaps
        {body.(":ets.insert(:t, {1})"), {:atom_receiver, :ets}},
        {body.(":persistent_term.put(:k, 1)"), {:atom_receiver, :persistent_term}},
        {body.(":code.load_file(M)"), {:atom_receiver, :code}},
        {body.(":\"Elixir.Process\".put(:k, 1)"), {:atom_receiver, :"Elixir.Process"}},
        {body.(":\"Elixir.Repo\".query!(\"select 1\")"), {:atom_receiver, :"Elixir.Repo"}},
        {body.("m.put(:x, 1, 2)"), {:var_receiver, :m}},
        {body.("c.fetch(:prefix)"), {:var_receiver, :c}},
        {body.("%Ecto.Multi{}"), {:multi_literal, :Multi}},
        {body.("%Multi{names: nil, operations: []}"), {:multi_literal, :Multi}},
        {body.("m.operations"), {:multi_field, :operations}},
        {body.("Map.put(m, :operations, [])"), {:map_change, :put}},
        {body.("Map.delete(m, :names)"), {:map_change, :delete}},
        {body.("Map.drop(m, [:operations])"), {:map_change, :drop}},
        {body.("m |> Map.put(:operations, [])"), {:map_change, :put}},
        {body.("m |> Ecto.Multi.run(:x, fn _, _ -> {:ok, 1} end)"), {:multi, :run}},
        {body.("%{m | operations: []}"), {:map_update, :context}}
      ]

      for {snippet, tag} <- cases do
        assert tag in purity_violations(snippet), "#{inspect(tag)} not flagged in: #{snippet}"
      end

      compliant = """
      defmodule H do
        alias Ecto.Multi
        alias Letflow.Entities.HandlerWrites

        @spec h(Multi.t(), Letflow.Entities.HandlerContext.t(), map()) ::
                {:ok, Multi.t()} | {:error, atom()}
        def h(multi, ctx, %{"item" => item}) when is_binary(item) do
          case HandlerWrites.create(multi, ctx, %{entity_type: "t", field_values: %{"item" => item}}) do
            {:ok, multi} ->
              _prefix = ctx.prefix
              _sorted = :lists.sort([2, 1])
              {:ok, multi |> Ecto.Multi.append(Ecto.Multi.new())}
            {:error, _} -> {:error, :not_permitted}
          end
        end

        def h(_multi, _ctx, _args), do: {:error, :invalid_arguments}
      end
      """

      assert purity_violations(compliant) == []

      full_alias = """
      defmodule H do
        def h(multi, ctx, _args) do
          Letflow.Entities.HandlerWrites.create(multi, ctx, %{entity_type: "t", field_values: %{}})
        end
      end
      """

      assert purity_violations(full_alias) == []
    end
  end
end
