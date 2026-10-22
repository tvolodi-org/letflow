defmodule Letflow.Identity.BindingWritersMembershipRowsTest do
  @moduledoc """
  REQ-519 slice 2e-b (GH #2535), AC 1 (f) membership rows and the SEC code gate (step-11) merge
  condition "registry `membership_rows/0` existence check (M-a..M-f incl. `copy_members/3`) with
  T-C2 style reachability" (design `lib/letflow/design/req519-enforced-writers-and-flag-on.md`
  section 3.4 M-rows; spec `test/specs/REQ-519-2e-b.md`).

  `Letflow.Identity.BindingWriters.membership_rows/0` classifies the writers that put a user into
  (or take a user out of) a group. They write no grant row, so the AST completeness scan of the
  binding writers does not apply; this file is their machine check:

    * the registry is exactly the six rows M-a..M-f, with the AC's / design's states;
    * every row names a function that EXISTS in its file (a rename cannot orphan a row);
    * every row still REACHES the thing that makes it the classified writer, by an AST walk over
      the file's own local calls plus the remote calls found on the way (so an `:delta_audited`
      row that stops calling the audit writer, or the sync that stops calling the guard, fails);
    * COMPLETENESS: every function under `lib/` that references `GroupMember` and calls a
      `Repo` write is one of the rows' functions or is reachable from one (a new membership
      writer cannot be added unclassified); the scanner is proven live on seeded sources.

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Identity.BindingWriters

  @identity "lib/letflow/identity.ex"
  @pending_admin_grants "lib/letflow/identity/pending_admin_grants.ex"
  @tam "lib/letflow/identity/tenant_admin_migration.ex"
  @group_member "Letflow.Identity.GroupMember"
  @repo "Letflow.Repo"
  @def_kinds [:def, :defp]
  @repo_writes [:insert, :insert!, :insert_all, :delete, :delete!, :delete_all, :update_all]
  @states [:delta_audited, :suppressed_in_on, :unchanged]

  # What each row MUST still reach (local functions and remote calls, transitively).
  @reach %{
    m_a: [
      {:local, :insert_or_fetch_group_member, 3},
      {:local, :insert_membership_audit, 6},
      {:local, :lock_tenant_admins!, 1}
    ],
    m_b: [{:local, :insert_membership_audit, 6}, {:local, :lock_tenant_admins!, 1}],
    m_c: [
      {:local, :insert_synced_membership, 5},
      {:local, :insert_membership_audit, 6},
      {:local, :lock_tenant_admins!, 1},
      {:remote, "Letflow.ScopeEnforcement", :mode_under_lock!, 1},
      {:remote, "Letflow.Identity.SyncScopeGuard", :bound_platform_roles, 2},
      {:remote, "Letflow.Identity.SyncScopeGuard", :evaluate, 5},
      {:remote, "Letflow.Identity.SyncScopeGuard", :record, 5}
    ],
    m_d: [{:remote, "Letflow.Identity", :add_group_member, 3}],
    m_e: [{:local, :lock_tenant_admins!, 1}, {:remote, @repo, :delete_all, 2}],
    m_f: [{:remote, @repo, :insert_all, 3}]
  }

  # ---- a small AST toolkit (the same idea as T-C2 of binding_writers_scan_test) ---------------

  defp aliases(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), parts)}

        {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [short]}]]} = node, acc ->
          {node, Map.put(acc, short, parts)}

        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, subs}]} = node, acc ->
          added = for {:__aliases__, _, sub} <- subs, into: %{}, do: {List.last(sub), base ++ sub}
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

  # %{ {name, arity} => %{calls: [...], refs: MapSet of module strings} } for one source text
  defp graph(source) do
    ast = Code.string_to_quoted!(source)
    al = aliases(ast)

    {_ast, acc} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head | rest]} = node, acc when kind in @def_kinds ->
          entry = %{calls: calls_in(rest, al), refs: refs_in(rest, al)}

          {node,
           Map.update(acc, label(head), entry, fn old ->
             %{calls: old.calls ++ entry.calls, refs: MapSet.union(old.refs, entry.refs)}
           end)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp file_graph(file), do: file |> File.read!() |> graph()

  defp calls_in(ast, al) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [mod, fun]}, _, args} = node, acc when is_atom(fun) and is_list(args) ->
          {node, [{:remote, resolve(mod, al), fun, length(args)} | acc]}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          # a piped call has one argument fewer than its arity, so both are recorded
          {node, [{:local, name, length(args)}, {:local, name, length(args) + 1} | acc]}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp refs_in(ast, al) do
    {_ast, refs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:__aliases__, _, [first | _]} = node, acc when is_atom(first) ->
          {node, MapSet.put(acc, resolve(node, al))}

        node, acc ->
          {node, acc}
      end)

    refs
  end

  # Every function reachable from `start` through local calls (start included), and the set of
  # all calls made by those functions.
  defp closure(graph, start) do
    walk(graph, [start], MapSet.new(), [])
  end

  defp walk(_graph, [], seen, calls), do: {seen, calls}

  defp walk(graph, [fun | rest], seen, calls) do
    cond do
      MapSet.member?(seen, fun) ->
        walk(graph, rest, seen, calls)

      not Map.has_key?(graph, fun) ->
        walk(graph, rest, seen, calls)

      true ->
        own = graph[fun].calls
        locals = for {:local, name, arity} <- own, do: {name, arity}
        walk(graph, locals ++ rest, MapSet.put(seen, fun), own ++ calls)
    end
  end

  # does the closure of `start` make this call? ({:local, n, a} means the function n/a is in it)
  defp reaches?(graph, start, {:local, name, arity}) do
    {seen, _calls} = closure(graph, start)
    MapSet.member?(seen, {name, arity})
  end

  defp reaches?(graph, start, {:remote, _mod, _fun, _arity} = call) do
    {_seen, calls} = closure(graph, start)
    call in calls
  end

  # functions that reference GroupMember AND make a Repo write call: [{name, arity}]
  defp membership_writers(graph) do
    for {key, %{calls: calls, refs: refs}} <- graph,
        MapSet.member?(refs, @group_member),
        Enum.any?(calls, &match?({:remote, @repo, fun, _} when fun in @repo_writes, &1)),
        do: key
  end

  defp rows, do: BindingWriters.membership_rows()
  defp row(id), do: Enum.find(rows(), &(&1.id == id))

  # ===========================================================================================
  describe "the registry (AC 1 (f), design M-a..M-f)" do
    test "exactly the six rows M-a..M-f, in order, with unique ids and a reason each" do
      assert Enum.map(rows(), & &1.id) == [:m_a, :m_b, :m_c, :m_d, :m_e, :m_f]
      assert Enum.all?(rows(), &(&1.state in @states))
      assert Enum.all?(rows(), &(is_binary(&1.why) and byte_size(&1.why) > 10))

      assert Enum.map(rows(), &{&1.site.file, &1.site.function}) == [
               {@identity, {:add_group_member, 3}},
               {@identity, {:remove_group_member, 3}},
               {@identity, {:sync_role_claims_report, 3}},
               {@pending_admin_grants, {:bind_on_login, 5}},
               {@identity, {:delete_group, 2}},
               {@tam, {:copy_members, 3}}
             ]
    end

    test "the states are the design's: audited deltas, the sync suppressed in on, the rest unchanged" do
      assert Map.new(rows(), &{&1.id, &1.state}) == %{
               m_a: :delta_audited,
               m_b: :delta_audited,
               m_c: :suppressed_in_on,
               m_d: :unchanged,
               m_e: :unchanged,
               m_f: :unchanged
             }
    end

    test "the membership rows are not binding rows: no id is shared with binding_rows/0 (delete_group may be both)" do
      binding_ids = Enum.map(BindingWriters.binding_rows(), & &1.id)
      refute Enum.any?(rows(), &(&1.id in binding_ids))
    end
  end

  # ===========================================================================================
  describe "every row names a function that exists in its file (M-a..M-f incl. copy_members/3)" do
    for id <- [:m_a, :m_b, :m_c, :m_d, :m_e, :m_f] do
      @tag row: id
      test "#{id}: the file exists and defines the function", %{row: id} do
        r = row(id)
        assert File.regular?(r.site.file), "#{id}: #{r.site.file} does not exist"
        graph = file_graph(r.site.file)

        assert Map.has_key?(graph, r.site.function),
               "#{id}: #{inspect(r.site.function)} is not defined in #{r.site.file}"
      end
    end

    test "copy_members/3 (M-f) is the TAM's private three-argument function, not a look-alike" do
      graph = file_graph(@tam)
      assert Map.has_key?(graph, {:copy_members, 3})
      assert MapSet.member?(graph[{:copy_members, 3}].refs, @group_member)
    end
  end

  # ===========================================================================================
  describe "every row still reaches what classifies it (T-C2 style reachability)" do
    for id <- [:m_a, :m_b, :m_c, :m_d, :m_e, :m_f] do
      @tag row: id
      test "#{id}: the function still reaches its writer / audit / guard calls", %{row: id} do
        r = row(id)
        graph = file_graph(r.site.file)

        for needle <- Map.fetch!(@reach, id) do
          assert reaches?(graph, r.site.function, needle),
                 "#{id}: #{inspect(r.site.function)} in #{r.site.file} no longer reaches #{inspect(needle)}"
        end
      end
    end

    test "the sync (M-c) reaches the guard ONLY inside the transaction it locks: the guard calls are not in the pre-lock resolve" do
      graph = file_graph(@identity)

      for guard_call <- [
            {:remote, "Letflow.Identity.SyncScopeGuard", :bound_platform_roles, 2},
            {:remote, "Letflow.ScopeEnforcement", :mode_under_lock!, 1}
          ] do
        # the pre-lock resolution of candidate groups reads group ids only (SEC C-3)
        refute reaches?(graph, {:resolve_group_ids_for_role_names, 2}, guard_call),
               "#{inspect(guard_call)} must not be reachable from the pre-lock resolve"
      end
    end

    test "the walk is live: a function that stopped calling its writer / audit does not reach it" do
      source = """
      defmodule Letflow.Seeded.M do
        alias Letflow.Repo
        def writer(a), do: helper(a)
        defp helper(a), do: audit(a)
        defp audit(a), do: Repo.insert_all(a, [], [])
        def orphan(a), do: String.upcase(a)
        def cyclic(a), do: cyclic(a)
      end
      """

      graph = graph(source)
      assert reaches?(graph, {:writer, 1}, {:local, :audit, 1})
      assert reaches?(graph, {:writer, 1}, {:remote, @repo, :insert_all, 3})
      refute reaches?(graph, {:orphan, 1}, {:local, :audit, 1})
      refute reaches?(graph, {:cyclic, 1}, {:remote, @repo, :insert_all, 3})
      refute reaches?(graph, {:missing, 1}, {:local, :audit, 1})
    end
  end

  # ===========================================================================================
  describe "completeness: every membership writer under lib/ is a row or reachable from one" do
    defp lib_graphs do
      for file <- Path.wildcard("lib/**/*.ex") |> Enum.sort(),
          into: %{},
          do: {file, file_graph(file)}
    end

    defp covered(graphs) do
      rows()
      |> Enum.flat_map(fn r ->
        {seen, _calls} = closure(Map.fetch!(graphs, r.site.file), r.site.function)
        Enum.map(seen, &{r.site.file, &1})
      end)
      |> MapSet.new()
    end

    test "the scan finds the known writers and every one is covered" do
      graphs = lib_graphs()
      covered = covered(graphs)

      found =
        for {file, graph} <- graphs, fun <- membership_writers(graph), do: {file, fun}

      # the primitives the six rows are built on
      assert {@identity, {:insert_or_fetch_group_member, 3}} in found
      assert {@tam, {:copy_members, 3}} in found
      assert {@identity, {:delete_group, 2}} in found

      uncovered = Enum.reject(found, &MapSet.member?(covered, &1))

      assert uncovered == [],
             "membership writers not covered by a membership_rows/0 row: #{inspect(uncovered)}"
    end

    test "the scanner is live: a seeded unregistered writer is found, read-only look-alikes are not" do
      source = """
      defmodule Letflow.Seeded.W do
        alias Letflow.Identity.GroupMember
        alias Letflow.Repo
        def sneaky(g, u), do: Repo.insert(%GroupMember{group_id: g, user_id: u})
        def reader(g), do: Repo.all(GroupMember, g)
        def other(a), do: Repo.insert(a)
      end
      """

      assert membership_writers(graph(source)) == [{:sneaky, 2}]
    end
  end
end
