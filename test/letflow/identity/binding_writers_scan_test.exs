defmodule Letflow.Identity.BindingWritersScanTest do
  @moduledoc """
  REQ-519 slice 2e-a (GH #2535), AC 1 completeness (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` section 3.4, tests T-C1 and T-C2;
  SEC code gate step-06 merge condition F-2; spec `test/specs/REQ-519-2e-a.md`): "an ExUnit
  source scan lists every call site under lib/ of RoleScopeGrants.reconcile_widening!,
  reconcile_non_widening!, ensure_tenant_wide_group_row!, repair_group_row!, move_group_rows!,
  delete_group_principal_rows! and Backfill.run, and fails when a call site is not named in the
  writer registry" (GH #2848: the registry names the entry point each site calls, so a site that
  moves from the widening to the non-widening entry point is a registry change too).

  T-C1: the AST scan of `lib/**/*.ex` (aliases resolved; remote calls, piped calls, `&M.f/n`
  captures and a bare function-name atom as in `apply/3` are all call sites; docs and comments
  are not in the AST) finds the multiset of `{file, enclosing function}` that must EQUAL the
  SCANNED rows of `Letflow.Identity.BindingWriters.binding_rows/0`. `converge_existing_role/5`
  holds two sites, so the comparison is a MULTISET. The scanner is proven LIVE on seeded sources
  (an unregistered call, three alias spellings, a pipe, a capture, a dynamic `apply/3`, a
  look-alike `Backfill.run` of ANOTHER module that must not match) and the comparison is proven
  to fail both ways (a site missing from the registry, a registry row with no site).

  T-C2 (SEC F-2 "indirect-row existence check"): each INDIRECT row names a function that exists
  in its file AND still reaches a scanned site, by an AST reachability walk over the file's own
  local calls; the remote entry points an indirect row may end in (`RoleRegistry.upsert_role/4`
  and friends) are themselves checked to reach a scanned site inside `role_registry.ex`. A
  renamed function, or an indirect writer that stops calling its entry point, cannot silently
  become unclassified.

  Also here: the INTERNAL option `binding_policy` occurs only in `role_registry.ex` (a text scan
  of `lib/`, comments and docs included).

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Identity.BindingWriters

  # The AC's six, spelled out here (the registry's own list is asserted equal to this one).
  @grants "Letflow.Identity.RoleScopeGrants"
  @backfill "Letflow.Identity.RoleScopeGrants.Backfill"
  @targets %{
    @grants => [
      reconcile_widening!: 3,
      reconcile_non_widening!: 3,
      ensure_tenant_wide_group_row!: 3,
      repair_group_row!: 3,
      move_group_rows!: 4,
      delete_group_principal_rows!: 2
    ],
    @backfill => [run: 1]
  }
  @distinctive_atoms [
    :reconcile_widening!,
    :reconcile_non_widening!,
    :ensure_tenant_wide_group_row!,
    :repair_group_row!,
    :move_group_rows!,
    :delete_group_principal_rows!
  ]
  # The internal dispatch of the grants module and the registry itself are not call sites.
  @excluded_files [
    "lib/letflow/identity/role_scope_grants.ex",
    "lib/letflow/identity/binding_writers.ex"
  ]
  @def_kinds [:def, :defp, :defmacro, :defmacrop]
  @doc_attrs [:doc, :moduledoc, :typedoc]
  @type_attrs [:type, :typep, :opaque, :spec, :callback]

  # The remote entry points an indirect row may end in, by `{module-last-part, function}`.
  @indirect_terminals [
    {"RoleRegistry", :upsert_role},
    {"RoleRegistry", :upsert_role_report},
    {"RoleRegistry", :rebind_role},
    {"RoleRegistry", :rebind_role_report},
    {"RoleRegistry", :seed_default_platform_role_groups},
    {"RoleRegistry", :seed_default_platform_role_groups_report}
  ]

  # ---- the scanner ---------------------------------------------------------------------------

  # alias map of one file: short atom => full parts
  defp aliases(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), parts)}

        {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [short]}]]} = node, acc ->
          {node, Map.put(acc, short, parts)}

        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, subs}]} = node, acc ->
          added =
            for {:__aliases__, _, sub} <- subs, into: %{}, do: {List.last(sub), base ++ sub}

          {node, Map.merge(acc, added)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp resolve({:__aliases__, _, [first | rest]}, aliases) when is_atom(first) do
    parts = Map.get(aliases, first, [first]) ++ rest
    Enum.map_join(parts, ".", &Atom.to_string/1)
  end

  defp resolve(_other, _aliases), do: nil

  defp label({:when, _, [head | _]}), do: label(head)
  defp label({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp label({name, _, _}) when is_atom(name), do: {name, 0}
  defp label(_other), do: :unknown

  # Every call-like use found by one walk: {kind, module_string | nil, name, arity, enclosing}
  defp uses(ast) do
    aliases = aliases(ast)
    walk(ast, :module, aliases, [])
  end

  defp walk({:@, _, [{attr, _, _}]}, _ctx, _aliases, acc) when attr in @doc_attrs, do: acc
  defp walk({:@, _, [{attr, _, _}]}, _ctx, _aliases, acc) when attr in @type_attrs, do: acc

  defp walk({kind, _, [head | rest]}, _ctx, aliases, acc) when kind in @def_kinds do
    ctx = label(head)
    Enum.reduce(rest, acc, &walk(&1, ctx, aliases, &2))
  end

  # &Mod.fun/n
  defp walk(
         {:&, _, [{:/, _, [{{:., _, [mod, fun]}, _, []}, arity]}]},
         ctx,
         aliases,
         acc
       )
       when is_atom(fun) and is_integer(arity) do
    [{:call, resolve(mod, aliases), fun, arity, ctx} | acc]
  end

  # lhs |> Mod.fun(args): one more argument than written
  defp walk({:|>, _, [lhs, {{:., _, [mod, fun]}, _, args}]}, ctx, aliases, acc)
       when is_atom(fun) and is_list(args) do
    acc = walk(lhs, ctx, aliases, acc)
    acc = [{:call, resolve(mod, aliases), fun, length(args) + 1, ctx} | acc]
    Enum.reduce(args, acc, &walk(&1, ctx, aliases, &2))
  end

  defp walk({{:., _, [mod, fun]}, _, args}, ctx, aliases, acc)
       when is_atom(fun) and is_list(args) do
    acc = [{:call, resolve(mod, aliases), fun, length(args), ctx} | acc]
    acc = walk(mod, ctx, aliases, acc)
    Enum.reduce(args, acc, &walk(&1, ctx, aliases, &2))
  end

  defp walk(atom, ctx, _aliases, acc) when atom in @distinctive_atoms,
    do: [{:atom, nil, atom, 0, ctx} | acc]

  defp walk({head, _, args}, ctx, aliases, acc) when is_list(args) do
    acc = walk(head, ctx, aliases, acc)
    Enum.reduce(args, acc, &walk(&1, ctx, aliases, &2))
  end

  defp walk({l, r}, ctx, aliases, acc), do: walk(r, ctx, aliases, walk(l, ctx, aliases, acc))

  defp walk(list, ctx, aliases, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, ctx, aliases, &2))

  defp walk(_other, _ctx, _aliases, acc), do: acc

  # The scanned sites of one source: [{file, {fun, arity}, entry}] (sorted), where `entry` is the
  # entry point the site calls (GH #2848: the widening and non-widening entry points are
  # different sites, so a call that switches between them is a classification change). Flagged
  # dynamic uses are included under the enclosing function.
  defp sites(file, source) do
    source
    |> Code.string_to_quoted!()
    |> uses()
    |> Enum.filter(fn
      {:call, mod, fun, arity, _ctx} -> Keyword.get(Map.get(@targets, mod, []), fun) == arity
      {:atom, _, _fun, _arity, _ctx} -> true
    end)
    |> Enum.map(fn {_kind, _mod, fun, _arity, ctx} -> {file, ctx, fun} end)
    |> Enum.sort()
  end

  defp lib_files do
    Path.wildcard("lib/**/*.ex") |> Enum.sort() |> Enum.reject(&(&1 in @excluded_files))
  end

  defp lib_sites do
    Enum.flat_map(lib_files(), fn file -> sites(file, File.read!(file)) end) |> Enum.sort()
  end

  defp scanned_rows, do: Enum.reject(BindingWriters.binding_rows(), & &1.indirect)
  defp indirect_rows, do: Enum.filter(BindingWriters.binding_rows(), & &1.indirect)

  defp registry_sites,
    do:
      scanned_rows()
      |> Enum.map(&{&1.site.file, &1.site.function, &1.site.entry})
      |> Enum.sort()

  # {found - registry, registry - found} as multisets
  defp diff(found, registry), do: {found -- registry, registry -- found}

  # ===========================================================================================
  describe "T-C1 completeness: every call site of the scanned functions is a registered row" do
    test "the registry's entry points are exactly the scanned functions (the AC's six, with reconcile_binding! split in two)" do
      expected =
        @targets
        |> Enum.flat_map(fn {_mod, fns} -> fns end)
        |> Enum.sort()

      assert Enum.sort(BindingWriters.entry_points()) == expected
    end

    test "the multiset of {file, enclosing function, entry point} found under lib/ equals the SCANNED rows" do
      assert diff(lib_sites(), registry_sites()) == {[], []}
    end

    test "the scan is not empty and sees converge_existing_role/5 three times, one per entry point (a multiset)" do
      found = lib_sites()
      assert length(found) == 11

      converge = for {file, {:converge_existing_role, 5}, entry} <- found, do: {file, entry}

      assert Enum.sort(converge) == [
               {"lib/letflow/identity/role_registry.ex", :reconcile_non_widening!},
               {"lib/letflow/identity/role_registry.ex", :reconcile_non_widening!},
               {"lib/letflow/identity/role_registry.ex", :reconcile_widening!}
             ]
    end

    test "every row carries a state, a transition and a reason; ids are unique" do
      rows = BindingWriters.binding_rows()
      assert Enum.uniq_by(rows, & &1.id) == rows
      assert Enum.all?(rows, &(&1.state in [:refused, :no_row, :unchanged]))
      assert Enum.all?(rows, &(is_binary(&1.why) and &1.why != ""))
      assert Enum.all?(rows, &File.exists?(&1.site.file))
    end

    test "a registry row for the registered AC states: REFUSED a/b, NO-ROW c/e, UNCHANGED f" do
      by_id = Map.new(BindingWriters.binding_rows(), &{&1.id, &1.state})

      assert %{w_a: :refused, w_b: :refused, w_c1: :no_row, w_c2: :no_row, w_c3: :no_row} =
               by_id

      assert %{w_e: :no_row, w_e2: :no_row, w_f1: :unchanged, w_f2: :unchanged} = by_id
      assert %{w_g1: :no_row, w_g2: :no_row, w_h: :refused, w_d: :unchanged} = by_id
    end
  end

  describe "T-C1 the scanner is live (seeded sources)" do
    test "a NEW unregistered call site is found and the comparison FAILS (MU-1)" do
      source = """
      defmodule Letflow.Seeded.A do
        alias Letflow.Identity.RoleScopeGrants

        def sneaky(group_id, role, prefix) do
          RoleScopeGrants.ensure_tenant_wide_group_row!(group_id, role, prefix)
        end
      end
      """

      seeded = sites("lib/letflow/seeded/a.ex", source)
      assert seeded == [{"lib/letflow/seeded/a.ex", {:sneaky, 3}, :ensure_tenant_wide_group_row!}]

      {unregistered, stale} = diff(lib_sites() ++ seeded, registry_sites())
      assert unregistered == seeded
      assert stale == []
    end

    test "a registry row whose site no longer exists is reported as stale" do
      [dropped | _] = registry_sites()
      {unregistered, stale} = diff(lib_sites() -- [dropped], registry_sites())
      assert unregistered == []
      assert stale == [dropped]
    end

    test "dropping a row from the registry makes its real site unregistered" do
      [dropped | rest] = registry_sites()
      {unregistered, stale} = diff(lib_sites(), rest)
      assert unregistered == [dropped]
      assert stale == []
    end

    test "alias spellings, a pipe, a capture and a dynamic apply/3 are all found" do
      source = """
      defmodule Letflow.Seeded.B do
        alias Letflow.Identity.RoleScopeGrants, as: RSG
        alias Letflow.Identity.{RoleScopeGrants.Backfill}

        def as_alias(a, b, c), do: RSG.repair_group_row!(a, b, c)
        def full_name(a, b, c, d), do: Letflow.Identity.RoleScopeGrants.move_group_rows!(a, b, c, d)
        def piped(a, b, c), do: a |> RSG.reconcile_widening!(b, c)
        def captured, do: Enum.map([], &RSG.delete_group_principal_rows!/2)
        def dynamic(a), do: apply(RSG, :reconcile_non_widening!, [a, a, a])
        def sweep(opts), do: Backfill.run(opts)
      end
      """

      assert sites("lib/b.ex", source) == [
               {"lib/b.ex", {:as_alias, 3}, :repair_group_row!},
               {"lib/b.ex", {:captured, 0}, :delete_group_principal_rows!},
               {"lib/b.ex", {:dynamic, 1}, :reconcile_non_widening!},
               {"lib/b.ex", {:full_name, 4}, :move_group_rows!},
               {"lib/b.ex", {:piped, 3}, :reconcile_widening!},
               {"lib/b.ex", {:sweep, 1}, :run}
             ]
    end

    test "look-alikes are NOT call sites: another module's Backfill.run, a wrong arity, docs and comments" do
      source = """
      defmodule Letflow.Seeded.C do
        @moduledoc "calls RoleScopeGrants.repair_group_row!(a, b, c) in prose"
        alias Letflow.LoginDirectory.Backfill
        alias Letflow.Identity.RoleScopeGrants

        # RoleScopeGrants.move_group_rows!(a, b, c, d) in a comment
        @doc "RoleScopeGrants.reconcile_widening!(a, b, c)"
        def other(opts), do: Backfill.run(opts)
        def wrong_arity(a), do: RoleScopeGrants.repair_group_row!(a)
        def remove(a, b, c), do: RoleScopeGrants.remove_group_rows!(a, b, c)
      end
      """

      assert sites("lib/c.ex", source) == []
    end
  end

  # ===========================================================================================
  describe "T-C2 each INDIRECT row still reaches a scanned site (SEC F-2)" do
    # function graph of one file: {name, arity} => [call descriptors]
    defp function_graph(file) do
      ast = file |> File.read!() |> Code.string_to_quoted!()
      aliases = aliases(ast)

      {_ast, graph} =
        Macro.prewalk(ast, %{}, fn
          {kind, _, [head | rest]} = node, acc when kind in @def_kinds ->
            key = label(head)
            calls = calls_in(rest, aliases)
            {node, Map.update(acc, key, calls, &(&1 ++ calls))}

          node, acc ->
            {node, acc}
        end)

      graph
    end

    defp calls_in(ast, aliases) do
      {_ast, calls} =
        Macro.prewalk(ast, [], fn
          {{:., _, [mod, fun]}, _, args} = node, acc when is_atom(fun) and is_list(args) ->
            {node, [{:remote, resolve(mod, aliases), fun, length(args)} | acc]}

          {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
            # a local call; a piped call has one argument fewer than its arity, so both
            {node, [{:local, name, length(args)}, {:local, name, length(args) + 1} | acc]}

          node, acc ->
            {node, acc}
        end)

      calls
    end

    # Does `start` reach a scanned entry call or one of the remote terminals, through the file's
    # own local functions?
    defp reaches?(graph, start, terminal?, seen \\ MapSet.new()) do
      cond do
        MapSet.member?(seen, start) -> false
        not Map.has_key?(graph, start) -> false
        true -> reach_calls?(graph, graph[start], terminal?, MapSet.put(seen, start))
      end
    end

    defp reach_calls?(graph, calls, terminal?, seen) do
      Enum.any?(calls, fn
        {:remote, _mod, _fun, _arity} = call ->
          terminal?.(call)

        {:local, name, arity} ->
          reaches?(graph, {name, arity}, terminal?, seen)
      end)
    end

    defp scanned_call?({:remote, mod, fun, arity}),
      do: Keyword.get(Map.get(@targets, mod, []), fun) == arity

    defp indirect_terminal?({:remote, mod, fun, _arity} = call) when is_binary(mod) do
      scanned_call?(call) or {mod |> String.split(".") |> List.last(), fun} in @indirect_terminals
    end

    defp indirect_terminal?(_call), do: false

    test "there are indirect rows and each names an existing function of its file" do
      assert Enum.map(indirect_rows(), & &1.id) |> Enum.sort() == [:w_g1, :w_g2, :w_h]

      for row <- indirect_rows() do
        graph = function_graph(row.site.file)

        assert Map.has_key?(graph, row.site.function),
               "#{row.id}: #{inspect(row.site.function)} is not defined in #{row.site.file}"
      end
    end

    test "each indirect row reaches a scanned site or a registry entry point" do
      for row <- indirect_rows() do
        graph = function_graph(row.site.file)

        assert reaches?(graph, row.site.function, &indirect_terminal?/1),
               "#{row.id}: #{inspect(row.site.function)} in #{row.site.file} no longer reaches a binding writer"
      end
    end

    test "the registry entry points themselves reach a scanned site inside role_registry.ex" do
      graph = function_graph("lib/letflow/identity/role_registry.ex")

      for entry <- [
            {:upsert_role, 4},
            {:upsert_role_report, 4},
            {:rebind_role, 4},
            {:rebind_role_report, 4},
            {:seed_default_platform_role_groups, 1},
            {:seed_default_platform_role_groups_report, 1}
          ] do
        assert reaches?(graph, entry, &scanned_call?/1),
               "#{inspect(entry)} no longer reaches a binding writer"
      end
    end

    test "the reachability walk is live: a function that stopped calling the writer does not reach it" do
      source = """
      defmodule Letflow.Seeded.D do
        alias Letflow.Identity.RoleScopeGrants
        def writer(a, b, c), do: helper(a, b, c)
        defp helper(a, b, c), do: RoleScopeGrants.reconcile_non_widening!(a, b, c)
        def orphan(a), do: String.upcase(a)
        def cyclic(a), do: cyclic(a)
      end
      """

      {:defmodule, _, [_name, [do: body]]} = ast = Code.string_to_quoted!(source)
      aliases = aliases(ast)

      graph =
        for {kind, _, [head | rest]} <- block(body),
            kind in @def_kinds,
            into: %{},
            do: {label(head), calls_in(rest, aliases)}

      assert reaches?(graph, {:writer, 3}, &scanned_call?/1)
      refute reaches?(graph, {:orphan, 1}, &scanned_call?/1)
      refute reaches?(graph, {:cyclic, 1}, &scanned_call?/1)
    end

    defp block({:__block__, _, exprs}), do: exprs
    defp block(expr), do: [expr]
  end

  # ===========================================================================================
  describe "the internal option binding_policy" do
    test "occurs only in lib/letflow/identity/role_registry.ex (no router, no other module passes or names it)" do
      holders =
        for file <- Path.wildcard("lib/**/*.ex"),
            File.read!(file) =~ "binding_policy",
            do: file

      assert holders == ["lib/letflow/identity/role_registry.ex"]
    end
  end
end
