defmodule Letflow.Entities.QueryScopeTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-a, ACs 1 to 5 (decision 0051 D6; design
  `lib/letflow/design/req518-compiler-scope-filter.md` 3.4, 3.8, 3.9; spec
  `test/specs/REQ-518-2c-i-a.md`, T-C1, T-C3, T-C4, T-C5, T-C7, T-C8, T-C9, T-C10, T-D2, T-D5,
  T-D6): the scope argument of `Letflow.Entities.Query.Compiler.compile/3`,
  `compile_aggregate/3` and `run_aggregate/3` against REAL data of the `fixture_scoped` module
  (`ScopeSetFixture`: tree root/a/(a1, a2 retired, a2x live under a2, a3 retired)/b/b1, nine
  `scoped_item` rows with distinct power-of-two amounts, so a sum names exactly which rows
  were counted).

    * `:all` builds EXACTLY the query built before scoping (committed SQL of eight shapes,
      `test/fixtures/scope/compiler_all_pre_change_sql.json`, captured from the pre-change
      compiler source of `main`) and issues no scope statement;
    * the scope is its own outermost WHERE (one more `where` than the `:all` query) before
      group by, aggregate select, cursor resume filter, order and limit, as a bound `text[]`
      parameter; never a literal node id, never a post-filter;
    * every joined hop carries the predicate of its TARGET type in its ON clause: a LEFT join
      keeps the primary row with a NULL target, an INNER join drops it, an out-of-scope
      `through` row NULLs the far hop, an undeclared target is NULL / dropped;
    * `:none`, `{:nodes, []}`, an undeclared type, a type on `:latest` and a declared column
      that is not physically present all give an empty result for a scoped caller (fail
      closed, no JSON fallback), a `:tenant_wide` master stays readable;
    * the argument guard raises `ArgumentError` (constant message, no value, no query).

  `async: false`: real tenants with committed data, DDL (dropped tables / columns).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Scope
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Query.Cursor
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScopeSetFixture, as: F

  @perm :EntitiesQuery
  @pre_change "test/fixtures/scope/compiler_all_pre_change_sql.json"
  @all_keys [:root, :a, :a1, :a2, :a2x, :a3, :b, :b1, :none]
  @in_a [:a, :a1, :a2x]

  setup do
    fx = F.provision!("req518-qscope")
    items = F.seed_items!(fx)
    children = F.seed_children!(fx, items)
    {:ok, fx: fx, items: items, children: children}
  end

  # ---- helpers ------------------------------------------------------------------------------

  defp set!(principal) do
    assert {:ok, set} = Scope.allowed_set(principal, @perm)
    set
  end

  defp compile!(fx, request, scope) do
    assert {:ok, query} = Compiler.compile(request, fx.schema_name, scope)
    query
  end

  defp rows(fx, request, scope),
    do: Repo.all(compile!(fx, request, scope), prefix: fx.schema_name)

  defp names(rows), do: rows |> Enum.map(& &1.field_values["name"]) |> Enum.sort()

  defp item_names(keys), do: keys |> Enum.map(&"item-#{&1}") |> Enum.sort()

  defp aggregate!(fx, request, scope) do
    assert {:ok, rows} = Compiler.run_aggregate(request, fx.schema_name, scope)
    rows
  end

  defp int(nil), do: nil
  defp int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp int(n) when is_integer(n), do: n

  @count %{entity_type: "scoped_item", aggregates: [%{fn: :count}]}
  @count_sum %{
    entity_type: "scoped_item",
    aggregates: [%{fn: :count}, %{fn: :sum, field: "amount"}]
  }
  @grouped %{
    entity_type: "scoped_item",
    aggregates: [%{fn: :count}],
    group_by: [%{field: "scope_node"}]
  }
  @by_amount %{entity_type: "scoped_item", sort: [%{field: "amount", dir: :asc}]}
  @left_join %{
    entity_type: "scoped_item",
    join: [%{entity_type: "scoped_child", fk: "fk_scoped_child_item_id", type: :left}]
  }
  @inner_join %{
    entity_type: "scoped_item",
    join: [%{entity_type: "scoped_child", fk: "fk_scoped_child_item_id", type: :inner}]
  }
  @through_left %{
    entity_type: "scoped_item",
    join: [
      %{
        entity_type: "scoped_item",
        through: "scoped_child",
        fk: "fk_scoped_child_item_id",
        type: :left
      }
    ]
  }

  # The `:latest` shape selects every column of the `Latest` schema; that column list is a
  # property of the schema (it grew with `external_system` / `external_id` on main), not of the
  # scope argument, so it is replaced by a marker on BOTH sides. Everything after FROM (table,
  # WHERE, parameters) is compared exactly.
  defp normalise(%{"sql" => sql} = shape) do
    if sql =~ ~s("entity_record_latest") do
      %{
        shape
        | "sql" => Regex.replace(~r/\ASELECT .*? FROM /, sql, "SELECT <latest columns> FROM ")
      }
    else
      shape
    end
  end

  # the target row of a joined result row (nil when the LEFT join found nothing in scope)
  defp target(row, type) do
    case Map.get(row, type) do
      nil -> nil
      %{record_id: nil} -> nil
      other -> other
    end
  end

  defp primary_name(row), do: row.primary.field_values["name"]

  # ===========================================================================================
  describe "T-C1 arity, and :all builds the pre-change query" do
    test "the three functions exist with the scope argument and no two-argument form remain" do
      Code.ensure_loaded!(Compiler)

      for fun <- [:compile, :compile_aggregate, :run_aggregate] do
        assert function_exported?(Compiler, fun, 3), "#{fun}/3 must exist"
        refute function_exported?(Compiler, fun, 2), "#{fun}/2 must not exist"
      end
    end

    test "the committed SQL of eight request shapes equals the :all compile, text and parameters (MU34)",
         %{fx: fx} do
      expected = @pre_change |> File.read!() |> Jason.decode!()
      # the :latest shape reads the type from the shared table
      F.drop_type_table!(fx, "scoped_master")

      assert Enum.sort(Map.keys(expected)) == Enum.sort(Enum.map(F.sql_shapes(), &elem(&1, 0)))

      for {name, kind, request} <- F.sql_shapes() do
        actual = normalise(F.sql_of(Compiler, kind, request, fx.schema_name, :all))
        wanted = normalise(Map.fetch!(expected, name))

        assert actual == wanted,
               "shape #{name}: the :all query differs from the pre-change query
" <>
                 "expected: #{inspect(wanted)}
actual:   #{inspect(actual)}"
      end
    end

    test ":all issues no scope statement: no tenant_modules read and no extra introspection (MU34)",
         %{fx: fx} do
      {_, all_queries} =
        Fixture.capture_repo_queries(fn -> compile!(fx, @left_join, :all) end)

      refute Enum.any?(all_queries, &(&1.query =~ "tenant_modules"))

      # control: the same request under a scoped set DOES read the installed modules
      {_, scoped_queries} =
        Fixture.capture_repo_queries(fn ->
          compile!(fx, @left_join, {:nodes, [F.nodes().a]})
        end)

      assert Enum.any?(scoped_queries, &(&1.query =~ "tenant_modules"))
    end
  end

  # ===========================================================================================
  describe "T-C3 the scope argument guard" do
    @bad_scopes [
      nil,
      :foo,
      "all",
      [],
      {:nodes, :x},
      {:nodes, "sf-a"},
      {:nodes, [1]},
      {:nodes, ["sf-a", 1]},
      {:nodes, [nil]},
      {:nodes, [:a]},
      {:node, ["sf-a"]},
      {:nodes, ["sf-a"], :extra}
    ]

    test "compile, compile_aggregate and run_aggregate raise ArgumentError for every bad scope, before any query",
         %{fx: fx} do
      for bad <- @bad_scopes do
        {_, queries} =
          Fixture.capture_repo_queries(fn ->
            assert_raise ArgumentError, fn ->
              Compiler.compile(@by_amount, fx.schema_name, bad)
            end

            assert_raise ArgumentError, fn ->
              Compiler.compile_aggregate(@count, fx.schema_name, bad)
            end

            assert_raise ArgumentError, fn ->
              Compiler.run_aggregate(@count, fx.schema_name, bad)
            end
          end)

        assert queries == [], "scope #{inspect(bad)} must be refused before any read"
      end
    end

    test "the message is constant: it names no value of the bad scope", %{fx: fx} do
      error =
        assert_raise ArgumentError, fn ->
          Compiler.compile(@by_amount, fx.schema_name, {:nodes, ["secret-node-id-xyz", 1]})
        end

      refute error.message =~ "secret-node-id-xyz"
      assert error.message =~ ":all"

      other =
        assert_raise ArgumentError, fn ->
          Compiler.compile(@by_amount, fx.schema_name, :secret_atom_xyz)
        end

      assert other.message == error.message
    end

    test "{:nodes, []} is :none: the same SQL and no row", %{fx: fx} do
      none = Repo.to_sql(:all, compile!(fx, @by_amount, :none))
      empty = Repo.to_sql(:all, compile!(fx, @by_amount, {:nodes, []}))

      assert none == empty
      assert rows(fx, @by_amount, {:nodes, []}) == []
      assert rows(fx, @by_amount, :none) == []
    end
  end

  # ===========================================================================================
  describe "T-C4 rows, aggregates, buckets and cursor pages only see in-scope data" do
    test "a scoped TASK_WORKER on subtree a sees a, a1 and a2x: not the retired a2 / a3, not b, root or NULL (MU3, MU4)",
         %{fx: fx} do
      set = fx |> F.principal({:nodes, [:a]}) |> set!()

      assert set == {:nodes, Enum.sort([F.nodes().a, F.nodes().a1, F.nodes().a2x])}
      assert names(rows(fx, %{entity_type: "scoped_item"}, set)) == item_names(@in_a)
    end

    test "two grants (a and b1) see the union of both subtrees", %{fx: fx} do
      set = fx |> F.principal({:nodes, [:a, :b1]}) |> set!()

      assert names(rows(fx, %{entity_type: "scoped_item"}, set)) == item_names(@in_a ++ [:b1])
    end

    test "tenant-wide, token and platform-admin callers see all nine rows, NULL scope included",
         %{fx: fx} do
      for principal <- [
            F.principal(fx, :tenant_wide),
            F.token_principal(fx),
            F.platform_admin_principal(fx)
          ] do
        assert set!(principal) == :all
        assert names(rows(fx, %{entity_type: "scoped_item"}, :all)) == item_names(@all_keys)
      end
    end

    test "a caller with a role but no grant row, :none and {:nodes, []} see nothing (fail closed)",
         %{fx: fx} do
      assert fx |> F.principal(:zero_rows) |> set!() == :none

      for scope <- [:none, {:nodes, []}] do
        assert rows(fx, %{entity_type: "scoped_item"}, scope) == []
      end
    end

    test "aggregate count and sum count only in-scope rows (the sum names the rows)", %{fx: fx} do
      set = fx |> F.principal({:nodes, [:a]}) |> set!()

      assert [%{"agg__count_none" => 3, "agg__sum_amount" => sum}] =
               aggregate!(fx, @count_sum, set)

      assert int(sum) == F.sum(@in_a)

      assert [%{"agg__count_none" => 9, "agg__sum_amount" => all_sum}] =
               aggregate!(fx, @count_sum, :all)

      assert int(all_sum) == F.sum(@all_keys)

      assert [%{"agg__count_none" => 0, "agg__sum_amount" => nil}] =
               aggregate!(fx, @count_sum, :none)
    end

    test "group_by buckets hold only in-scope groups; no bucket for NULL or out-of-scope nodes",
         %{fx: fx} do
      set = fx |> F.principal({:nodes, [:a]}) |> set!()

      buckets =
        fx
        |> aggregate!(@grouped, set)
        |> Map.new(&{&1["group__scope_node"], &1["agg__count_none"]})

      assert buckets == %{F.nodes().a => 1, F.nodes().a1 => 1, F.nodes().a2x => 1}

      all_buckets =
        fx
        |> aggregate!(@grouped, :all)
        |> Map.new(&{&1["group__scope_node"], &1["agg__count_none"]})

      assert map_size(all_buckets) == 9
      assert Map.fetch!(all_buckets, nil) == 1

      assert aggregate!(fx, @grouped, :none) == []
    end

    test "an out-of-scope row never enters a count even when the caller filters for it", %{fx: fx} do
      set = fx |> F.principal({:nodes, [:a]}) |> set!()

      for {field, op, value} <- [
            {"name", :eq, "item-b"},
            {"name", :in, ["item-b", "item-a2", "item-none"]},
            {"scope_node", :eq, F.nodes().b},
            {"scope_node", :is_null, nil}
          ] do
        filter =
          if value == nil,
            do: %{field: field, op: op},
            else: %{field: field, op: op, value: value}

        assert [%{"agg__count_none" => 0}] =
                 aggregate!(fx, Map.put(@count, :filters, [filter]), set),
               "filter #{field} #{op} must not reach out-of-scope rows"

        assert rows(fx, %{entity_type: "scoped_item", filters: [filter]}, set) == []
      end
    end

    test "the user filter cannot widen the scope: an IN over in-scope and out-of-scope names returns the in-scope one",
         %{fx: fx} do
      set = fx |> F.principal({:nodes, [:a]}) |> set!()

      request = %{
        entity_type: "scoped_item",
        filters: [%{field: "name", op: :in, value: ["item-a", "item-b", "item-a3"]}]
      }

      assert names(rows(fx, request, set)) == ["item-a"]
    end

    test "cursor page 1 and page 2 return in-scope rows only, each exactly once", %{fx: fx} do
      set = fx |> F.principal({:nodes, [:a, :b1]}) |> set!()
      assert {:ok, allowlist} = Allowlist.load("scoped_item", fx.schema_name)

      page = fn cursor ->
        query = compile!(fx, @by_amount, set)
        opts = %{page_size: 2, cursor: cursor}
        assert {:ok, page} = Cursor.paginate(@by_amount, query, allowlist, opts, fx.schema_name)
        page
      end

      page1 = page.(nil)
      assert Enum.map(page1.items, & &1.field_values["name"]) == ["item-a", "item-a1"]
      assert is_binary(page1.next_cursor)

      page2 = page.(page1.next_cursor)
      assert Enum.map(page2.items, & &1.field_values["name"]) == ["item-a2x", "item-b1"]
      assert page2.next_cursor == nil
    end

    test "page 2 is compiled with the CURRENT set: a row of a revoked subtree leaves the next page",
         %{fx: fx} do
      wide = fx |> F.principal({:nodes, [:a, :b1]}) |> set!()
      narrow = fx |> F.principal({:nodes, [:a]}) |> set!()
      assert {:ok, allowlist} = Allowlist.load("scoped_item", fx.schema_name)

      paginate = fn scope, cursor ->
        query = compile!(fx, @by_amount, scope)
        opts = %{page_size: 3, cursor: cursor}
        assert {:ok, page} = Cursor.paginate(@by_amount, query, allowlist, opts, fx.schema_name)
        page
      end

      page1 = paginate.(wide, nil)
      assert Enum.map(page1.items, & &1.field_values["name"]) == ["item-a", "item-a1", "item-a2x"]
      assert is_binary(page1.next_cursor)

      # b1 was in the set when page 1 was cut; it is not in the set that cuts page 2
      page2 = paginate.(narrow, page1.next_cursor)
      assert page2.items == []
    end
  end

  # ===========================================================================================
  describe "T-C5 the predicate is a bound parameter in the outermost WHERE of every statement" do
    @any ~r/"scope_node" = ANY\(\$\d+(::varchar\[\])?\)/

    defp scoped_set(fx), do: fx |> F.principal({:nodes, [:a]}) |> set!()

    defp statements_on(queries, table),
      do:
        Enum.filter(
          queries,
          &(&1.query =~ ~s("#{table}") and String.starts_with?(&1.query, "SELECT"))
        )

    test "each compiled query has exactly one more WHERE than its :all twin (not inside the user filter, MU2)",
         %{fx: fx} do
      set = scoped_set(fx)

      filtered = %{
        entity_type: "scoped_item",
        filters: [%{field: "name", op: :eq, value: "item-a"}]
      }

      for request <- [filtered, @by_amount, @left_join, @inner_join, @through_left] do
        all = compile!(fx, request, :all)
        scoped = compile!(fx, request, set)
        none = compile!(fx, request, :none)

        assert length(scoped.wheres) == length(all.wheres) + 1, inspect(request)
        assert length(none.wheres) == length(all.wheres) + 1, inspect(request)
      end

      for request <- [@count, @grouped, Map.put(@count, :join, @inner_join.join)] do
        assert {:ok, all} = Compiler.compile_aggregate(request, fx.schema_name, :all)
        assert {:ok, scoped} = Compiler.compile_aggregate(request, fx.schema_name, set)
        assert length(scoped.wheres) == length(all.wheres) + 1, inspect(request)
      end
    end

    test "the data, cursor, grouped aggregate and joined statements carry the predicate with the ids as ONE bound array and no literal id",
         %{fx: fx} do
      set = scoped_set(fx)
      {:nodes, ids} = set
      assert {:ok, allowlist} = Allowlist.load("scoped_item", fx.schema_name)
      schema = fx.schema_name

      {_, data} = Fixture.capture_repo_queries(fn -> rows(fx, @by_amount, set) end)

      {_, page} =
        Fixture.capture_repo_queries(fn ->
          query = compile!(fx, @by_amount, set)
          Cursor.paginate(@by_amount, query, allowlist, %{page_size: 2}, schema)
        end)

      {_, aggregate} = Fixture.capture_repo_queries(fn -> aggregate!(fx, @grouped, set) end)
      {_, joined} = Fixture.capture_repo_queries(fn -> rows(fx, @left_join, set) end)

      for {label, queries} <- [data: data, page: page, aggregate: aggregate, joined: joined] do
        assert [statement] =
                 Enum.filter(
                   queries,
                   &(&1.query =~ ~s("entity_scoped_item") and
                       String.starts_with?(&1.query, "SELECT"))
                 ),
               "#{label}: exactly one data statement"

        assert statement.query =~ @any, "#{label}: no scope predicate in #{statement.query}"
        assert ids in statement.params, "#{label}: ids are not one bound array"
        refute statement.query =~ "sf-", "#{label}: a node id was inlined"
      end

      # position: before GROUP BY, ORDER BY and LIMIT
      [aggregate_sql] = aggregate |> statements_on("entity_scoped_item") |> Enum.map(& &1.query)
      assert Regex.match?(@any, hd(String.split(aggregate_sql, "GROUP BY")))

      [page_sql] = page |> statements_on("entity_scoped_item") |> Enum.map(& &1.query)
      assert Regex.match?(@any, hd(String.split(page_sql, "ORDER BY")))
      assert page_sql =~ "LIMIT"
    end

    test "hostile ids are values: a node id with SQL text is bound, never inlined", %{fx: fx} do
      hostile = ~S{x'); DROP TABLE entity_scoped_item; --}

      {_, queries} =
        Fixture.capture_repo_queries(fn ->
          rows(fx, %{entity_type: "scoped_item"}, {:nodes, [hostile, "sf-a"]})
        end)

      data = Enum.find(queries, &(&1.query =~ ~s("entity_scoped_item") and &1.query =~ "SELECT"))
      refute data.query =~ "DROP TABLE"
      assert [hostile, "sf-a"] in data.params
      assert names(rows(fx, %{entity_type: "scoped_item"}, {:nodes, [hostile]})) == []
    end
  end

  # ===========================================================================================
  describe "T-C7 joins: the target's predicate is in the ON clause of every hop" do
    defp join_sql(fx, request, scope) do
      {sql, _params} = Repo.to_sql(:all, compile!(fx, request, scope))
      [_select, rest] = String.split(sql, " FROM ", parts: 2)
      [_from | joins] = String.split(rest, ~r/ (?:LEFT OUTER|INNER) JOIN /)
      {last, init} = List.pop_at(joins, -1)
      {last_on, where} = split_where(last)
      %{ons: init ++ [last_on], where: where}
    end

    defp split_where(segment) do
      case String.split(segment, " WHERE ", parts: 2) do
        [on] -> {on, ""}
        [on, where] -> {on, where}
      end
    end

    test "LEFT join: the primary row is kept with a NULL target when the target is out of scope (MU5)",
         %{fx: fx, items: items, children: children} do
      set = scoped_set(fx)
      result = rows(fx, @left_join, set)

      by_name = Map.new(result, &{primary_name(&1), &1})
      assert Map.keys(by_name) |> Enum.sort() == item_names(@in_a)

      # item-a: child ca (scope a) is in scope
      assert target(by_name["item-a"], "scoped_child").record_id == children.ca.record_id
      # item-a1: its only child cb is in scope b: the row stays, the target is NULL
      assert by_name["item-a1"].primary.record_id == items.a1.record_id
      assert target(by_name["item-a1"], "scoped_child") == nil
      # item-a2x has no child at all
      assert target(by_name["item-a2x"], "scoped_child") == nil

      # control: the tenant-wide caller sees the child of item-a1
      all_by_name = Map.new(rows(fx, @left_join, :all), &{primary_name(&1), &1})
      assert target(all_by_name["item-a1"], "scoped_child").record_id == children.cb.record_id
    end

    test "INNER join: a primary row whose target is out of scope is dropped", %{
      fx: fx,
      children: children
    } do
      set = scoped_set(fx)

      assert [row] = rows(fx, @inner_join, set)
      assert primary_name(row) == "item-a"
      assert row["scoped_child"].record_id == children.ca.record_id

      # control: the tenant-wide caller sees all three item/child pairs
      assert :all |> then(&rows(fx, @inner_join, &1)) |> length() == 3
    end

    test "the predicate sits in the ON clause of the hop, the primary one in the WHERE (SQL shape, MU5)",
         %{fx: fx} do
      set = scoped_set(fx)

      for request <- [@left_join, @inner_join] do
        %{ons: [on], where: where} = join_sql(fx, request, set)

        assert on =~ ~r/e1\."scope_node" = ANY\(\$\d+(::varchar\[\])?\)/,
               "target predicate not in ON: #{on}"

        assert where =~ ~r/"scope_node" = ANY\(\$\d+(::varchar\[\])?\)/
        refute where =~ ~r/e1\."scope_node"/, "target predicate leaked into WHERE: #{where}"
      end
    end

    test "two-hop through: an out-of-scope through row NULLs the far hop; each hop has its own ON predicate (MU6)",
         %{fx: fx, items: items} do
      set = scoped_set(fx)

      result = Map.new(rows(fx, @through_left, set), &{primary_name(&1), &1})
      assert Map.keys(result) |> Enum.sort() == item_names(@in_a)

      # item-a -> child ca (scope a, in scope) -> far item-a
      assert target(result["item-a"], "scoped_item").record_id == items.a.record_id

      # item-a1 -> child cb (scope b, OUT of scope): the through row is NULL, so the far hop is NULL
      assert target(result["item-a1"], "scoped_item") == nil

      # control: unscoped, the far hop of item-a1 resolves through cb
      all = Map.new(rows(fx, @through_left, :all), &{primary_name(&1), &1})
      assert target(all["item-a1"], "scoped_item").record_id == items.a1.record_id

      %{ons: ons} = join_sql(fx, @through_left, set)
      assert [near, far] = ons
      assert near =~ ~r/e1\."scope_node" = ANY\(\$\d+(::varchar\[\])?\)/
      assert far =~ ~r/e2\."scope_node" = ANY\(\$\d+(::varchar\[\])?\)/
    end

    test ":none: a LEFT join returns no primary row at all; the ON predicate is constant false",
         %{fx: fx} do
      assert rows(fx, @left_join, :none) == []
      assert rows(fx, @inner_join, :none) == []
      assert rows(fx, @through_left, :none) == []
    end

    test "aggregate over a join counts only pairs whose target is in scope", %{fx: fx} do
      request = Map.put(@count, :join, @inner_join.join)
      set = scoped_set(fx)

      assert [%{"agg__count_none" => 1}] = aggregate!(fx, request, set)
      assert [%{"agg__count_none" => 3}] = aggregate!(fx, request, :all)
      assert [%{"agg__count_none" => 0}] = aggregate!(fx, request, :none)
    end
  end

  # ===========================================================================================
  describe "T-C8 / T-D2 undeclared types return no data for a scoped caller" do
    setup %{fx: fx, items: items} do
      F.create_plain_undeclared!(fx, items)
      :ok
    end

    test "an undeclared type: empty rows, zero count, no bucket, for query, aggregate and the export compile (MU7)",
         %{fx: fx} do
      set = scoped_set(fx)
      plain = %{entity_type: "plain_undeclared"}

      count = Map.put(plain, :aggregates, [%{fn: :count}])

      assert rows(fx, plain, set) == []
      assert [%{"agg__count_none" => 0}] = aggregate!(fx, count, set)

      assert aggregate!(
               fx,
               %{
                 entity_type: "plain_undeclared",
                 aggregates: [%{fn: :count}],
                 group_by: [%{field: "name"}]
               },
               set
             ) == []

      # the tenant-wide caller reads the same type in full (one row per pack row)
      assert [_one] = rows(fx, plain, :all)
      assert [%{"agg__count_none" => 1}] = aggregate!(fx, count, :all)
    end

    test "an undeclared joined TARGET: LEFT keeps the primary with a NULL target, INNER drops the row, tenant-wide sees it",
         %{fx: fx} do
      set = scoped_set(fx)

      left = %{
        entity_type: "scoped_item",
        join: [%{entity_type: "plain_undeclared", fk: "fk_plain_item", type: :left}]
      }

      inner = put_in(left, [:join, Access.at(0), :type], :inner)

      by_name = Map.new(rows(fx, left, set), &{primary_name(&1), &1})
      assert Map.keys(by_name) |> Enum.sort() == item_names(@in_a)
      assert target(by_name["item-a"], "plain_undeclared") == nil

      assert rows(fx, inner, set) == []

      assert [row] = rows(fx, inner, :all)
      assert target(row, "plain_undeclared") != nil
    end
  end

  # ===========================================================================================
  describe "T-D5 a :tenant_wide master" do
    setup %{fx: fx} do
      F.create!(fx.schema_name, "scoped_master", %{"name" => "m1"})
      F.create!(fx.schema_name, "scoped_master", %{"name" => "m2"})
      :ok
    end

    test "is readable by a scoped caller and by a caller of another subtree", %{fx: fx} do
      for spec <- [{:nodes, [:a]}, {:nodes, [:b1]}] do
        set = fx |> F.principal(spec) |> set!()
        assert names(rows(fx, %{entity_type: "scoped_master"}, set)) == ["m1", "m2"]

        assert [%{"agg__count_none" => 2}] =
                 aggregate!(fx, %{entity_type: "scoped_master", aggregates: [%{fn: :count}]}, set)
      end
    end

    test "a caller with no live node sees nothing, not even masters (MU10)", %{fx: fx} do
      for scope <- [:none, {:nodes, []}, fx |> F.principal(:zero_rows) |> set!()] do
        assert rows(fx, %{entity_type: "scoped_master"}, scope) == []

        assert [%{"agg__count_none" => 0}] =
                 aggregate!(
                   fx,
                   %{entity_type: "scoped_master", aggregates: [%{fn: :count}]},
                   scope
                 )
      end
    end
  end

  # ===========================================================================================
  describe "T-D6 declared column not promoted / type on :latest: fail closed, no JSON fallback" do
    test "a declared type read from :latest returns nothing to a scoped caller, everything to :all (MU8)",
         %{fx: fx} do
      set = scoped_set(fx)
      F.drop_type_table!(fx, "scoped_item")

      assert {:ok, :latest} = Compiler.resolve_binding_source("scoped_item", fx.schema_name)
      assert rows(fx, %{entity_type: "scoped_item"}, set) == []

      assert [%{"agg__count_none" => 0}] = aggregate!(fx, @count, set)
      assert [%{"agg__count_none" => 9}] = aggregate!(fx, @count, :all)
      assert length(rows(fx, %{entity_type: "scoped_item"}, :all)) == 9
    end

    test "a declared column that is not physically present returns nothing to a scoped caller", %{
      fx: fx
    } do
      set = scoped_set(fx)
      F.drop_scope_column!(fx, "scoped_item")

      assert {:ok, {:per_type_table, _}} =
               Compiler.resolve_binding_source("scoped_item", fx.schema_name)

      assert rows(fx, %{entity_type: "scoped_item"}, set) == []
      assert [%{"agg__count_none" => 0}] = aggregate!(fx, @count, set)
      assert length(rows(fx, %{entity_type: "scoped_item"}, :all)) == 9
    end

    test "a joined target whose column is missing is NULL for a LEFT join and drops an INNER row",
         %{fx: fx} do
      set = scoped_set(fx)
      F.drop_scope_column!(fx, "scoped_child")

      by_name = Map.new(rows(fx, @left_join, set), &{primary_name(&1), &1})
      assert Map.keys(by_name) |> Enum.sort() == item_names(@in_a)
      assert target(by_name["item-a"], "scoped_child") == nil

      assert rows(fx, @inner_join, set) == []
    end
  end

  # ===========================================================================================
  describe "T-C9 / T-C10 cost: the scope work is per request, not per row" do
    test "a scoped plain compile adds exactly the declaration reads: one installed-modules read, the owner read and the column check",
         %{fx: fx} do
      {_, all} = Fixture.capture_repo_queries(fn -> compile!(fx, @by_amount, :all) end)

      {_, scoped} =
        Fixture.capture_repo_queries(fn -> compile!(fx, @by_amount, {:nodes, [F.nodes().a]}) end)

      assert length(scoped) - length(all) == 3
      assert Enum.count(scoped, &(&1.query =~ "tenant_modules")) == 1
    end

    test "a joined compile reads the installed modules ONCE for all bindings (one read per for_types call)",
         %{fx: fx} do
      {_, queries} =
        Fixture.capture_repo_queries(fn ->
          compile!(fx, @through_left, {:nodes, [F.nodes().a]})
        end)

      assert Enum.count(queries, &(&1.query =~ "tenant_modules")) == 1
    end

    test "executing a page costs one statement whatever the page size: the set is not recomputed per row (MU11)",
         %{fx: fx} do
      set = scoped_set(fx)
      assert {:ok, allowlist} = Allowlist.load("scoped_item", fx.schema_name)
      query = compile!(fx, @by_amount, set)

      counts =
        for page_size <- [1, 2, 3] do
          {_, queries} =
            Fixture.capture_repo_queries(fn ->
              Cursor.paginate(
                @by_amount,
                query,
                allowlist,
                %{page_size: page_size},
                fx.schema_name
              )
            end)

          refute Enum.any?(queries, &(&1.query =~ "scope_node_paths"))
          refute Enum.any?(queries, &(&1.query =~ "tenant_modules"))
          length(queries)
        end

      assert counts == [1, 1, 1]
    end
  end
end
