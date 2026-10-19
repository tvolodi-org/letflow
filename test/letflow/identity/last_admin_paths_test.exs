defmodule Letflow.Identity.LastAdminPathsTest do
  @moduledoc """
  GH #2869 part (a) (design `lib/letflow/design/gh2869-last-interactive-admin-guard.md` r4,
  D-9, T-LA-18 and T-LA-30; spec `test/specs/GH2869-last-interactive-admin-guard.md`): the
  standing controls for "every write path that takes lock A".

    * T-LA-30 completeness: the `{file, function}` pairs of every call of
      `Letflow.Identity.lock_tenant_admins!/1` in `lib/` (AST, the definition excluded) equal the
      `Letflow.Identity.LastAdminPaths` inventory (23 sites); every guarded row names, in the
      `:guard` field, a function that exists in its file and calls the function named in its
      `:guard_call` field; no non-guarded row does; and the functions that call either guard
      function in `lib/` (outside the guard module) are exactly the guarded rows' `:guard`
      functions. A new lock-A writer with no row, a guarded row whose guard call was removed, and
      a guard call in an unregistered function each fail (proven live on a seeded offender);
    * T-LA-18 one predicate, not a copy: (i) the new functions of the guard module contain no
      query (no `from`, no `Repo` read, no schema alias of users, memberships, bindings, grants
      or tokens) and reach the count through `Identity.count_interactive_explicit_tenant_wide_admins/1`;
      (ii) exactly ONE function in `lib/` builds a query for the `:interactive_explicit` mode
      (`tenant_wide_admins_query/3`), so the gate (fact 4) and the guard cannot disagree. The pin is
      on the number of query builders, not on atom occurrences. Each is proven live on a seeded
      offender.

  No database: `async: true`. Paths are assembled from parts (the CI path-filter guard reads
  string literals).
  """

  use ExUnit.Case, async: true

  alias Letflow.Identity.LastAdminPaths

  @lock :lock_tenant_admins!
  @guard_fns [:ensure_interactive_admin_remains!, :interactive_admin_check]
  @classes [:guarded, :no_lower, :not_admin_writer]
  @actions ~w(deactivate_user remove_tenant_admin_member unbind_tenant_admin rebind_tenant_admin
              revoke_tenant_admin_grant flag_service_principal)a
  @schema_aliases [:User, :GroupMember, :TenantRole, :RoleScopeGrant, :ApiToken]

  # --- AST toolkit -----------------------------------------------------------------------------

  defp rel(path), do: String.replace(path, "\\", "/")

  defp lib_files, do: ["lib", "**", "*.ex"] |> Path.join() |> Path.wildcard() |> Enum.map(&rel/1)

  defp guard_file, do: rel(Path.join(["lib", "letflow", "identity", "tenant_admin_guard.ex"]))
  defp identity_file, do: rel(Path.join(["lib", "letflow", "identity.ex"]))

  defp quoted!(source), do: Code.string_to_quoted!(source)

  # every def/defp of the file as {name, arity, body_ast} (one entry per clause)
  defp functions(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          case head_label(head) do
            nil -> {node, acc}
            {name, arity} -> {node, [{name, arity, head, body} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp head_label({:when, _, [head | _guards]}), do: head_label(head)
  defp head_label({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp head_label({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, 0}
  defp head_label(_other), do: nil

  # Does the AST call (local, remote or capture) a function named one of `names`?
  defp calls?(ast, names) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, acc -> {node, acc or call_of?(node, names)} end)

    found?
  end

  defp call_of?({name, _, args}, names) when is_atom(name) and is_list(args), do: name in names
  defp call_of?({{:., _, [_mod, name]}, _, args}, names) when is_list(args), do: name in names
  defp call_of?(_node, _names), do: false

  defp mentions_atom?(ast, atom) do
    {_ast, found?} = Macro.prewalk(ast, false, fn node, acc -> {node, acc or node == atom} end)
    found?
  end

  defp builds_query?(ast), do: calls?(ast, [:from])

  # a field access `x.admin_flagged_service_principal`: the predicate of the interactive count is
  # the only QUERY that filters on the flag (writers set it through a keyword or a changeset)
  defp reads_flag_field?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [_var, :admin_flagged_service_principal]}, _, []} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  # {file, {name, arity}} of every function that calls `names`, deduplicated
  defp call_sites(path, source, names) do
    for {name, arity, _head, body} <- functions(quoted!(source)),
        calls?(body, names),
        uniq: true do
      %{file: rel(path), function: {name, arity}}
    end
  end

  defp lock_sites do
    for path <- lib_files(),
        site <- call_sites(path, File.read!(path), [@lock]),
        # the definition of the lock function itself is not a call site
        site.function != {@lock, 1} do
      site
    end
    |> Enum.sort()
  end

  defp inventory_sites, do: LastAdminPaths.rows() |> Enum.map(& &1.site) |> Enum.sort()

  defp guard_call_sites do
    for path <- lib_files(),
        path != guard_file(),
        site <- call_sites(path, File.read!(path), @guard_fns) do
      site
    end
    |> Enum.sort()
  end

  # does `source` define the function `{name, arity}` and does one of its clauses call `call`?
  defp function_calls?(source, {name, arity}, call) do
    source
    |> quoted!()
    |> functions()
    |> Enum.any?(fn {n, a, _head, body} -> {n, a} == {name, arity} and calls?(body, [call]) end)
  end

  defp function_defined?(source, {name, arity}),
    do:
      source
      |> quoted!()
      |> functions()
      |> Enum.any?(fn {n, a, _head, _body} -> {n, a} == {name, arity} end)

  # ===========================================================================================
  describe "T-LA-30 completeness of the lock-A inventory" do
    test "the inventory has 23 rows with unique ids and unique sites, valid classes and fields" do
      rows = LastAdminPaths.rows()

      assert length(rows) == 23
      assert rows |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 23
      assert rows |> Enum.map(& &1.site) |> Enum.uniq() |> length() == 23
      assert Enum.all?(rows, &(&1.class in @classes))

      for row <- rows do
        if row.class == :guarded do
          assert row.action in @actions
          assert {_name, _arity} = row.guard
          assert row.guard_call in @guard_fns
          assert row.reason == nil
        else
          assert row.action == nil and row.guard == nil and row.guard_call == nil
          assert is_binary(row.reason) and row.reason != ""
        end
      end

      assert rows |> Enum.filter(&(&1.class == :guarded)) |> Enum.map(& &1.action) |> Enum.sort() ==
               Enum.sort(@actions)
    end

    test "every call site of lock_tenant_admins! in lib/ is in the inventory, and every row is a call site" do
      sites = lock_sites()

      assert length(sites) == 23, "expected 23 lock-A call sites, found #{length(sites)}"
      assert sites -- inventory_sites() == [], "unclassified lock-A call sites"
      assert inventory_sites() -- sites == [], "inventory rows that are not lock-A call sites"
    end

    test "every guarded row's :guard function exists in its file and calls its :guard_call" do
      for %{class: :guarded} = row <- LastAdminPaths.rows() do
        source = File.read!(row.site.file)

        assert function_defined?(source, row.guard),
               "#{row.id}: #{inspect(row.guard)} is not defined in #{row.site.file}"

        assert function_calls?(source, row.guard, row.guard_call),
               "#{row.id}: #{inspect(row.guard)} does not call #{row.guard_call}"
      end
    end

    test "no non-guarded row's site function calls either guard function" do
      for %{class: class} = row <- LastAdminPaths.rows(), class != :guarded do
        source = File.read!(row.site.file)

        for guard <- @guard_fns do
          refute function_calls?(source, row.site.function, guard),
                 "#{row.id} is classified #{class} but calls #{guard}"
        end
      end
    end

    test "the functions calling a guard function in lib/ (outside the guard module) are exactly the guarded rows' :guard functions" do
      expected =
        for %{class: :guarded} = row <- LastAdminPaths.rows() do
          %{file: row.site.file, function: row.guard}
        end

      assert guard_call_sites() == Enum.sort(expected)
    end

    test "seeded offenders: an unregistered lock-A site, a dropped guard call and a stray guard call are each detected" do
      rogue_source = """
      defmodule Rogue do
        def rogue(prefix), do: Letflow.Identity.lock_tenant_admins!(prefix)
        def quiet(prefix), do: prefix
      end
      """

      # the scanner finds an unregistered call site ...
      assert [%{function: {:rogue, 1}}] = call_sites("lib/rogue.ex", rogue_source, [@lock])
      # ... and the comparison against the inventory reports it
      seeded = lock_sites() ++ call_sites("lib/rogue.ex", rogue_source, [@lock])
      assert seeded -- inventory_sites() == [%{file: "lib/rogue.ex", function: {:rogue, 1}}]

      # a guarded function that lost its guard call is detected
      guarded_ok = """
      defmodule G do
        def removal(prefix), do: Letflow.Identity.TenantAdminGuard.ensure_interactive_admin_remains!(prefix, :a, "t", 1)
      end
      """

      guarded_dropped =
        String.replace(
          guarded_ok,
          "Letflow.Identity.TenantAdminGuard.ensure_interactive_admin_remains!(prefix, :a, \"t\", 1)",
          ":ok"
        )

      assert function_calls?(guarded_ok, {:removal, 1}, :ensure_interactive_admin_remains!)
      refute function_calls?(guarded_dropped, {:removal, 1}, :ensure_interactive_admin_remains!)

      # a guard call in a function that no row names is detected
      assert [%{function: {:removal, 1}}] = call_sites("lib/g.ex", guarded_ok, @guard_fns)

      refute %{file: "lib/g.ex", function: {:removal, 1}} in Enum.map(
               LastAdminPaths.rows(),
               &%{file: &1.site.file, function: &1.guard}
             )
    end
  end

  # ===========================================================================================
  describe "T-LA-18 one interactive-explicit predicate, not a copy" do
    # the functions of the guard module that carry the new guard (all clauses of count/2 included)
    @new_guard_fns [
      :ensure_interactive_admin_remains!,
      :interactive_admin_check,
      :interactive_refusal,
      :count
    ]

    defp guard_offences(source) do
      for {name, _arity, _head, body} <- functions(quoted!(source)), name in @new_guard_fns do
        {name,
         %{
           builds_query: builds_query?(body),
           repo_read: calls?(body, [:all, :one, :one!, :exists?, :aggregate, :query, :query!]),
           schema_alias: schema_alias?(body)
         }}
      end
    end

    defp schema_alias?(ast) do
      {_ast, found?} =
        Macro.prewalk(ast, false, fn
          {:__aliases__, _, parts} = node, acc ->
            {node, acc or List.last(parts) in @schema_aliases}

          node, acc ->
            {node, acc}
        end)

      found?
    end

    test "(i) the new functions of the guard module build no query of their own" do
      offences = guard_offences(File.read!(guard_file()))

      assert length(offences) >= 4

      assert Enum.all?(offences, fn {_name, o} ->
               o == %{builds_query: false, repo_read: false, schema_alias: false}
             end),
             inspect(offences)
    end

    test "(i) the :interactive_explicit count clause goes through Identity.count_interactive_explicit_tenant_wide_admins" do
      source = File.read!(guard_file())

      count_clauses_with_atom =
        for {:count, 2, head, body} <- functions(quoted!(source)),
            mentions_atom?(head, :interactive_explicit),
            do: body

      assert [clause] = count_clauses_with_atom
      assert calls?(clause, [:count_interactive_explicit_tenant_wide_admins])
      # and the guard function itself counts through that seam (count/2), never directly
      assert function_calls?(source, {:interactive_admin_check, 2}, :count)
    end

    test "(ii) exactly ONE function in lib/ builds a query for the :interactive_explicit mode" do
      builders = interactive_query_builders()

      assert builders == [%{file: identity_file(), function: {:tenant_wide_admins_query, 3}}]
    end

    test "seeded offenders: a private query in the guard, and a second query builder, are each detected" do
      offender_guard = """
      defmodule G do
        def interactive_admin_check(prefix, 1) do
          Repo.one(from(u in User, where: u.status == :active, select: count(u.id)), prefix: prefix)
        end

        defp count(prefix, :interactive_explicit), do: from(m in GroupMember, where: true)
      end
      """

      offences = guard_offences(offender_guard)

      assert {:interactive_admin_check,
              %{builds_query: true, repo_read: true, schema_alias: true}} in offences

      assert {:count, %{builds_query: true, repo_read: false, schema_alias: true}} in offences

      second_builder = """
      defmodule I do
        defp first(prefix), do: {:interactive_explicit, from(u in User, where: not u.admin_flagged_service_principal)}
        defp copy(prefix), do: {:interactive_explicit, where(q, [u], not u.admin_flagged_service_principal)}
      end
      """

      assert length(builders_in(second_builder)) == 2
    end

    defp interactive_query_builders do
      for path <- lib_files(), site <- builders_in(File.read!(path), path), do: site
    end

    defp builders_in(source), do: builders_in(source, "seeded.ex")

    defp builders_in(source, path) do
      for {name, arity, head, body} <- functions(quoted!(source)),
          mentions_atom?([head, body], :interactive_explicit),
          calls?(body, [:from, :where]),
          reads_flag_field?(body),
          uniq: true do
        %{file: rel(path), function: {name, arity}}
      end
    end
  end
end
