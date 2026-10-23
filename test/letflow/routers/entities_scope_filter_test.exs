defmodule Letflow.Routers.EntitiesScopeFilterTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-b, AC 18 and AC 2/3 over HTTP (design
  `lib/letflow/design/req518-compiler-scope-filter.md` 3.5, 7.1, 10.1 T-C11; spec
  `test/specs/REQ-518-2c-i-b.md`): the three `:filter` routes `POST /entities/query`,
  `POST /entities/query/aggregate` and `POST /entities/records/:entity_type/export` dispatched
  into `Letflow.Routers.Entities` with a hand-assigned `auth_context` carrying the per-request
  enforcement mode (the REQ-517 2b style), over the REAL data of the `fixture_scoped` module
  (`ScopeSetFixture`: nine `scoped_item` rows with distinct power-of-two amounts, three
  `scoped_child` rows; the subtree `a` is `item-a`, `item-a1` and `item-a2x`).

    * `on`: a caller scoped to `a` gets 200 with EXACTLY the in-scope rows from each route (not
      the 2b 403), the pages reached through `next_cursor` stay in scope, a cursor minted by a
      tenant-wide caller does not widen a scoped caller, a joined query / aggregate / export
      carries the scope of every hop, a zero-row caller gets an empty 200, a tenant-wide caller
      is unchanged;
    * `off` and `shadow`: the same scoped caller gets the full result, byte-identical to each
      other and to the tenant-wide caller's `on` result, and the node set is never read;
    * the 200-empty type-hidden envelope (returned before the compiler) still carries the gate
      marker, so the before-send backstop does not turn it into a 500; non-2xx answers
      (400/404/422) are unchanged under `on`.

  `async: false`: real tenants with committed data.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopeSetFixture, as: F

  @router Letflow.Routers.Entities
  @role "TENANT_ADMIN"
  @in_a [:a, :a1, :a2x]
  @count_sum %{
    "entity_type" => "scoped_item",
    "aggregates" => [%{"fn" => "count"}, %{"fn" => "sum", "field" => "amount"}]
  }
  @all_keys [:root, :a, :a1, :a2, :a2x, :a3, :b, :b1, :none]
  @by_amount [%{"field" => "amount", "dir" => "asc"}]

  setup do
    fx = F.provision!("r518-flt")
    items = F.seed_items!(fx)
    children = F.seed_children!(fx, items)

    {:ok,
     fx: fx,
     items: items,
     children: children,
     scoped_a: F.holder!(fx, @role, {:nodes, [:a]}),
     scoped_ab: F.holder!(fx, @role, {:nodes, [:a, :b1]}),
     wide: F.holder!(fx, @role, :tenant_wide),
     zero: F.holder!(fx, @role, :zero_rows)}
  end

  # ---- helpers ------------------------------------------------------------------------------

  defp post(fx, user, mode, path, body),
    do: On.call(@router, :post, path, fx, user.id, [@role], mode, body)

  defp query(fx, user, mode, body), do: post(fx, user, mode, "/query", body)
  defp aggregate(fx, user, mode, body), do: post(fx, user, mode, "/query/aggregate", body)

  defp export(fx, user, mode, body),
    do: post(fx, user, mode, "/records/scoped_item/export", body)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp stable(conn), do: conn |> json() |> Map.delete("exported_at")

  defp names(items),
    do: items |> Enum.map(&get_in(&1, ["field_values", "name"])) |> Enum.sort()

  defp item_names(keys), do: keys |> Enum.map(&"item-#{&1}") |> Enum.sort()

  defp item_body(extra), do: Map.merge(%{"entity_type" => "scoped_item"}, extra)

  # every page reached through `next_cursor`, as `[{status, items}]`
  defp pages(fun, body, key) do
    Stream.unfold({:start, body}, fn
      :done ->
        nil

      {:start, body} ->
        conn = fun.(body)
        decoded = json(conn)
        next = decoded["next_cursor"]

        {{conn.status, decoded[key]},
         if(is_binary(next), do: {:start, Map.put(body, "cursor", next)}, else: :done)}
    end)
    |> Enum.to_list()
  end

  # ===========================================================================================
  describe "T-C11 POST /entities/query under on" do
    test "a scoped caller gets 200 with exactly the in-scope rows; a tenant-wide caller sees all; a two-root scope sees both subtrees; a zero-row caller gets an empty 200",
         %{fx: fx, scoped_a: scoped_a, scoped_ab: scoped_ab, wide: wide, zero: zero} do
      conn = query(fx, scoped_a, :on, item_body(%{}))
      assert conn.status == 200
      assert names(json(conn)["items"]) == item_names(@in_a)

      assert fx
             |> query(scoped_ab, :on, item_body(%{}))
             |> json()
             |> Map.fetch!("items")
             |> names() ==
               item_names(@in_a ++ [:b1])

      assert fx |> query(wide, :on, item_body(%{})) |> json() |> Map.fetch!("items") |> names() ==
               item_names(@all_keys)

      zero_conn = query(fx, zero, :on, item_body(%{}))
      assert zero_conn.status == 200
      assert json(zero_conn) == %{"items" => [], "next_cursor" => nil}
    end

    test "a filter does not escape the scope: asking for an out-of-scope row by name returns nothing",
         %{fx: fx, scoped_a: scoped_a} do
      body =
        item_body(%{
          "filters" => [%{"field" => "name", "op" => "eq", "value" => "item-b"}]
        })

      conn = query(fx, scoped_a, :on, body)
      assert conn.status == 200
      assert json(conn)["items"] == []
    end

    test "the second page reached through next_cursor stays in scope, no row is repeated or skipped",
         %{fx: fx, scoped_a: scoped_a} do
      pages =
        pages(
          &query(fx, scoped_a, :on, &1),
          item_body(%{"page_size" => 2, "sort" => @by_amount}),
          "items"
        )

      assert length(pages) == 2
      assert Enum.all?(pages, fn {status, _items} -> status == 200 end)
      assert pages |> Enum.map(fn {_s, items} -> length(items) end) == [2, 1]

      ordered = pages |> Enum.flat_map(fn {_s, items} -> items end)

      assert Enum.map(ordered, &get_in(&1, ["field_values", "name"])) == [
               "item-a",
               "item-a1",
               "item-a2x"
             ]
    end

    test "a cursor minted by a tenant-wide caller does not widen a scoped caller (GH #2698: the cursor is bound to its user, so the replay is refused; the scoped caller's own cursor resumes within scope)",
         %{fx: fx, scoped_a: scoped_a, wide: wide} do
      body = item_body(%{"page_size" => 2, "sort" => @by_amount})
      first = query(fx, wide, :on, body)
      assert first.status == 200
      assert names(json(first)["items"]) == ["item-a", "item-a1"]
      cursor = json(first)["next_cursor"]
      assert is_binary(cursor)

      replay = query(fx, scoped_a, :on, Map.put(body, "cursor", cursor))
      assert replay.status == 400

      own_first = query(fx, scoped_a, :on, body)
      assert own_first.status == 200
      own_cursor = json(own_first)["next_cursor"]
      assert is_binary(own_cursor)

      own_replay = query(fx, scoped_a, :on, Map.put(body, "cursor", own_cursor))
      assert own_replay.status == 200
      assert names(json(own_replay)["items"]) == ["item-a2x"]
    end

    test "a joined query (inner on the wire; LEFT is proven in query_scope_test) applies the scope of the joined hop",
         %{fx: fx, scoped_a: scoped_a, wide: wide} do
      inner = item_body(%{"join" => [join()], "sort" => @by_amount})

      scoped_rows = fx |> query(scoped_a, :on, inner) |> json() |> Map.fetch!("items")
      # item-a1 has only child-cb (scope b, out of scope for a subtree-a caller): it is dropped,
      # and so is item-b (its primary is out of scope as well)
      assert Enum.map(scoped_rows, &primary_name/1) == ["item-a"]
      assert child_name(row(scoped_rows, "item-a")) == "child-ca"

      wide_rows = fx |> query(wide, :on, inner) |> json() |> Map.fetch!("items")
      assert Enum.map(wide_rows, &primary_name/1) == ["item-a", "item-a1", "item-b"]
      assert child_name(row(wide_rows, "item-a1")) == "child-cb"
    end

    test "the type-hidden 200-empty envelope (returned before the compiler) still carries the gate marker: it is NOT turned into a 500",
         %{fx: fx, scoped_a: scoped_a} do
      conn = query(fx, scoped_a, :on, %{"entity_type" => "no_such_type_518"})
      assert conn.status == 200
      assert json(conn) == %{"items" => [], "next_cursor" => nil}
    end

    test "non-2xx answers are unchanged under on (400 invalid cursor, 422 field not queryable)",
         %{fx: fx, scoped_a: scoped_a} do
      bad_cursor = query(fx, scoped_a, :on, item_body(%{"cursor" => "not-a-cursor"}))
      assert bad_cursor.status == 400

      assert bad_cursor.resp_body ==
               query(fx, scoped_a, :off, item_body(%{"cursor" => "not-a-cursor"})).resp_body

      bad_body =
        item_body(%{"filters" => [%{"field" => "no_such_field", "op" => "eq", "value" => "x"}]})

      bad_field = query(fx, scoped_a, :on, bad_body)
      assert bad_field.status == 422
      assert bad_field.resp_body == query(fx, scoped_a, :off, bad_body).resp_body
    end
  end

  # ===========================================================================================
  describe "T-C11 POST /entities/query/aggregate under on" do
    test "count and sum cover exactly the in-scope rows; the tenant-wide caller sees all; zero rows count nothing",
         %{fx: fx, scoped_a: scoped_a, wide: wide, zero: zero} do
      scoped = aggregate(fx, scoped_a, :on, @count_sum)
      assert scoped.status == 200
      assert [%{"values" => values}] = json(scoped)["results"]
      assert values["count_none"] == 3
      assert sum_of(values) == F.sum(@in_a)

      assert [%{"values" => all}] =
               fx |> aggregate(wide, :on, @count_sum) |> json() |> Map.fetch!("results")

      assert all["count_none"] == 9
      assert sum_of(all) == F.sum(@all_keys)

      zero_conn = aggregate(fx, zero, :on, @count_sum)
      assert zero_conn.status == 200
      assert zero_count(json(zero_conn)) == 0
    end

    test "group_by buckets contain only in-scope groups",
         %{fx: fx, scoped_a: scoped_a} do
      body = %{
        "entity_type" => "scoped_item",
        "aggregates" => [%{"fn" => "count"}],
        "group_by" => [%{"field" => "scope_node"}]
      }

      conn = aggregate(fx, scoped_a, :on, body)
      assert conn.status == 200

      groups =
        json(conn)["results"]
        |> Enum.map(fn %{"group" => group} -> group |> Map.values() |> hd() end)
        |> Enum.sort()

      assert groups == Enum.sort([F.nodes().a, F.nodes().a1, F.nodes().a2x])
    end

    test "a nonexistent type is the unchanged 404 under on (the backstop leaves non-2xx alone)",
         %{fx: fx, scoped_a: scoped_a} do
      body = %{"entity_type" => "no_such_type_518", "aggregates" => [%{"fn" => "count"}]}
      assert aggregate(fx, scoped_a, :on, body).status == 404
      assert aggregate(fx, scoped_a, :off, body).status == 404
    end
  end

  # ===========================================================================================
  describe "T-C11 POST /entities/records/:entity_type/export under on" do
    test "a scoped caller exports exactly the in-scope records; the tenant-wide caller exports all",
         %{fx: fx, scoped_a: scoped_a, wide: wide} do
      conn = export(fx, scoped_a, :on, item_body(%{}))
      assert conn.status == 200
      assert names(json(conn)["records"]) == item_names(@in_a)

      assert fx |> export(wide, :on, item_body(%{})) |> json() |> Map.fetch!("records") |> names() ==
               item_names(@all_keys)
    end

    test "export pages reached through next_cursor stay in scope",
         %{fx: fx, scoped_a: scoped_a} do
      pages =
        pages(
          &export(fx, scoped_a, :on, &1),
          item_body(%{"page_size" => 2, "sort" => @by_amount}),
          "records"
        )

      assert pages |> Enum.map(fn {_s, records} -> length(records) end) == [2, 1]

      assert pages
             |> Enum.flat_map(fn {_s, records} -> records end)
             |> Enum.map(&get_in(&1, ["field_values", "name"])) ==
               ["item-a", "item-a1", "item-a2x"]
    end

    test "a joined export keeps the scope of every hop",
         %{fx: fx, scoped_a: scoped_a} do
      conn =
        export(fx, scoped_a, :on, item_body(%{"join" => [join()], "sort" => @by_amount}))

      assert conn.status == 200

      records = json(conn)["records"]

      # a joined export drops the rows whose target is out of scope (inner join): item-a only
      assert records |> Enum.map(&get_in(&1, ["field_values", "name"])) == ["item-a"]
    end

    test "a body entity_type that differs from the path is the unchanged 422 under on",
         %{fx: fx, scoped_a: scoped_a} do
      conn = export(fx, scoped_a, :on, %{"entity_type" => "scoped_child"})
      assert conn.status == 422
    end
  end

  # ===========================================================================================
  describe "off and shadow: the full result, no node-set read, byte-identical to each other" do
    test "the same scoped caller gets every row from all three routes under off and under shadow; off == shadow == the tenant-wide caller under on, raw body and headers",
         %{fx: fx, scoped_a: scoped_a, wide: wide} do
      requests = [
        {:query, item_body(%{"sort" => @by_amount})},
        {:aggregate, @count_sum},
        {:export, item_body(%{"sort" => @by_amount})}
      ]

      for {route, body} <- requests do
        run = fn user, mode -> dispatch_route(fx, route, user, mode, body) end
        off = run.(scoped_a, :off)
        shadow = run.(scoped_a, :shadow)
        reference = run.(wide, :on)

        assert off.status == 200, inspect(route)

        # the export envelope carries `exported_at` (wall clock), the only field allowed to differ
        assert stable(shadow) == stable(off), inspect(route)

        assert shadow.resp_headers == off.resp_headers, inspect(route)

        assert stable(off) == stable(reference), inspect(route)
      end

      off_names =
        fx |> query(scoped_a, :off, item_body(%{})) |> json() |> Map.fetch!("items") |> names()

      assert off_names == item_names(@all_keys)
    end

    test "not on: the allowed node set is never read (no scope_node_paths statement), under off nor shadow",
         %{fx: fx, scoped_a: scoped_a} do
      for mode <- [:off, :shadow], route <- [:query, :aggregate, :export] do
        body =
          if route == :aggregate, do: @count_sum, else: item_body(%{})

        {conn, queries} =
          Fixture.capture_repo_queries(fn -> dispatch_route(fx, route, scoped_a, mode, body) end)

        assert conn.status == 200, "#{route} under #{mode}"
        refute Enum.any?(queries, &(&1.query =~ "scope_node_paths")), "#{route} under #{mode}"
      end
    end

    test "under on the node set IS read, once per request, for each route",
         %{fx: fx, scoped_a: scoped_a} do
      for route <- [:query, :aggregate, :export] do
        body = if route == :aggregate, do: @count_sum, else: item_body(%{})

        {conn, queries} =
          Fixture.capture_repo_queries(fn -> dispatch_route(fx, route, scoped_a, :on, body) end)

        assert conn.status == 200, "#{route}"
        reads = Enum.count(queries, &(&1.query =~ "scope_node_paths"))
        assert reads >= 1, "#{route}: no node read under on"

        # the same request again costs the same number of node reads (no cross-request memo)
        {_conn, again} =
          Fixture.capture_repo_queries(fn -> dispatch_route(fx, route, scoped_a, :on, body) end)

        assert Enum.count(again, &(&1.query =~ "scope_node_paths")) == reads, "#{route}"
      end
    end
  end

  defp dispatch_route(fx, :query, user, mode, body), do: query(fx, user, mode, body)
  defp dispatch_route(fx, :aggregate, user, mode, body), do: aggregate(fx, user, mode, body)
  defp dispatch_route(fx, :export, user, mode, body), do: export(fx, user, mode, body)

  # ---- response readers ----------------------------------------------------------------------

  defp join, do: %{"entity_type" => "scoped_child", "fk" => "fk_scoped_child_item_id"}

  defp row(items, primary_name), do: Enum.find(items, &(primary_name(&1) == primary_name))

  defp primary_name(item), do: get_in(item, ["primary", "field_values", "name"])

  defp child_name(item), do: get_in(item, ["scoped_child", "field_values", "name"])

  defp sum_of(values),
    do: values |> Enum.find_value(fn {k, v} -> if k =~ "sum", do: v end) |> to_int()

  defp zero_count(decoded) do
    case decoded["results"] do
      [] -> 0
      [%{"values" => %{"count_none" => count}}] -> count
    end
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: n |> Decimal.new() |> Decimal.to_integer()
end
