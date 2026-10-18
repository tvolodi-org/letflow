defmodule Letflow.ScopeNodePathsAllowedIdsTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-a, AC 2 (design
  `lib/letflow/design/req518-compiler-scope-filter.md` 3.4; spec
  `test/specs/REQ-518-2c-i-a.md`, T-C6, T-C4 set half, T-C14 node half):
  `Letflow.ScopeNodePaths.allowed_node_ids/2`, the single tree access of the scoped data path.

    * the expansion is the roots plus their LIVE descendants, deduplicated and sorted; a retired
      node is absent but its live descendants stay (the retired INTERMEDIATE `a2` of the fixture
      tree keeps `a2x`); unknown roots are ignored, `[]` is `{:ok, []}`;
    * `%`, `_` and `\\` in a node id are matched LITERALLY (an unescaped `_` would pull the
      subtree of a sibling root into the set: that mutant leaks another subtree's data); a
      hostile id is a bound value;
    * errors are values: `:invalid_node_id`, `:invalid_schema_name`, `:too_many_ids` (the cap, read
      from application env per call);
    * cost: two statements for up to 500 roots, two more per further chunk of 500; no input size
      is rejected.

  `async: false`: real tenants, the VM-global cap application env.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.ScopeNodePaths.Node
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @cap_key :scope_allowed_ids_cap

  defp ids(keys), do: keys |> Enum.map(&Map.fetch!(F.nodes(), &1)) |> Enum.sort()

  defp put_cap!(value) do
    original = Application.fetch_env(:letflow, @cap_key)

    on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:letflow, @cap_key, v)
        :error -> Application.delete_env(:letflow, @cap_key)
      end
    end)

    Application.put_env(:letflow, @cap_key, value)
  end

  defp insert!(schema, id, parent) do
    assert {:ok, %Node{}} = ScopeNodePaths.write({:insert, id, parent}, schema)
    id
  end

  # ===========================================================================================
  describe "the expansion (fixture tree: a2 retired with live child a2x, a3 retired leaf)" do
    setup do
      {:ok, fx: F.provision!("req518-nodeids")}
    end

    test "a root expands to itself and its LIVE descendants; the retired a2 and a3 are absent, a2x is present (C-2, MU4)",
         %{fx: fx} do
      assert ScopeNodePaths.allowed_node_ids([F.nodes().a], fx.schema_name) ==
               {:ok, ids([:a, :a1, :a2x])}

      assert ScopeNodePaths.allowed_node_ids([F.nodes().root], fx.schema_name) ==
               {:ok, ids([:root, :a, :a1, :a2x, :b, :b1])}
    end

    test "a RETIRED root contributes its live descendants only; a retired leaf contributes nothing",
         %{fx: fx} do
      assert ScopeNodePaths.allowed_node_ids([F.nodes().a2], fx.schema_name) ==
               {:ok, ids([:a2x])}

      assert ScopeNodePaths.allowed_node_ids([F.nodes().a3], fx.schema_name) == {:ok, []}
    end

    test "the result is deduplicated and sorted whatever the order and overlap of the roots", %{
      fx: fx
    } do
      expected = ids([:a, :a1, :a2x, :b1])

      for roots <- [
            [F.nodes().a, F.nodes().b1],
            [F.nodes().b1, F.nodes().a],
            [F.nodes().a, F.nodes().a1, F.nodes().a, F.nodes().b1, F.nodes().a2x]
          ] do
        assert {:ok, ^expected} = ScopeNodePaths.allowed_node_ids(roots, fx.schema_name)
      end

      assert expected == Enum.sort(expected)
    end

    test "[] is {:ok, []}; an unknown root is ignored (not an error, not a wider set)", %{fx: fx} do
      assert ScopeNodePaths.allowed_node_ids([], fx.schema_name) == {:ok, []}
      assert ScopeNodePaths.allowed_node_ids(["sf-ghost"], fx.schema_name) == {:ok, []}

      assert ScopeNodePaths.allowed_node_ids(["sf-ghost", F.nodes().b1], fx.schema_name) ==
               {:ok, ids([:b1])}
    end

    test "up to 500 roots cost exactly two statements, both on scope_node_paths", %{fx: fx} do
      {result, queries} =
        Fixture.capture_repo_queries(fn ->
          ScopeNodePaths.allowed_node_ids([F.nodes().a, F.nodes().b], fx.schema_name)
        end)

      assert {:ok, _ids} = result
      assert length(queries) == 2
      assert Enum.all?(queries, &(&1.query =~ "scope_node_paths"))
    end
  end

  # ===========================================================================================
  describe "T-C6 LIKE metacharacters in a node id are literal" do
    setup do
      {:ok, fx: S.tenant!("req518-nodeids-like")}
    end

    test "an underscore does not match another character: the subtree of `xzy` stays out (MU: unescaped _)",
         %{fx: fx} do
      s = fx.schema_name

      for {id, parent} <- [{"x_y", nil}, {"x_y-kid", "x_y"}, {"xzy", nil}, {"xzy-kid", "xzy"}],
          do: insert!(s, id, parent)

      assert ScopeNodePaths.allowed_node_ids(["x_y"], s) == {:ok, ["x_y", "x_y-kid"]}
      assert ScopeNodePaths.allowed_node_ids(["xzy"], s) == {:ok, ["xzy", "xzy-kid"]}
    end

    test "a percent sign does not match a run of characters", %{fx: fx} do
      s = fx.schema_name

      for {id, parent} <- [
            {"p%q", nil},
            {"p%q-kid", "p%q"},
            {"pzzq", nil},
            {"pzzq-kid", "pzzq"},
            {"pq", nil},
            {"pq-kid", "pq"}
          ],
          do: insert!(s, id, parent)

      assert ScopeNodePaths.allowed_node_ids(["p%q"], s) == {:ok, ["p%q", "p%q-kid"]}
    end

    test "a backslash is literal, not an escape of the next character", %{fx: fx} do
      s = fx.schema_name

      for {id, parent} <- [
            {~S(b\c), nil},
            {~S(b\c-kid), ~S(b\c)},
            {"bc", nil},
            {"bc-kid", "bc"}
          ],
          do: insert!(s, id, parent)

      assert ScopeNodePaths.allowed_node_ids([~S(b\c)], s) == {:ok, [~S(b\c), ~S(b\c-kid)]}
      assert ScopeNodePaths.allowed_node_ids(["bc"], s) == {:ok, ["bc", "bc-kid"]}
    end

    test "a hostile id is a bound value: it expands to itself, nothing is executed, no statement contains it",
         %{fx: fx} do
      s = fx.schema_name
      hostile = ~S{x'); DROP TABLE scope_node_paths; --}
      insert!(s, hostile, nil)
      insert!(s, "innocent", nil)

      {result, queries} =
        Fixture.capture_repo_queries(fn -> ScopeNodePaths.allowed_node_ids([hostile], s) end)

      assert result == {:ok, [hostile]}
      refute Enum.any?(queries, &(&1.query =~ "DROP TABLE"))
      refute Enum.any?(queries, &(&1.query =~ hostile))
      # the table is still there and still answers
      assert ScopeNodePaths.allowed_node_ids(["innocent"], s) == {:ok, ["innocent"]}
    end
  end

  # ===========================================================================================
  describe "errors are values" do
    setup do
      {:ok, fx: F.provision!("req518-nodeids-err")}
    end

    test "an id that is not a valid node id is :invalid_node_id, before any query", %{fx: fx} do
      for bad <- ["a/b", "", "a\nb", "a\u0000b", nil, 123, :atom, <<255, 254>>] do
        {result, queries} =
          Fixture.capture_repo_queries(fn ->
            ScopeNodePaths.allowed_node_ids([F.nodes().a, bad], fx.schema_name)
          end)

        assert result == {:error, :invalid_node_id}, inspect(bad)
        assert queries == [], "#{inspect(bad)}: refused before any read"
      end
    end

    test "a prefix that is not a tenant schema name is :invalid_schema_name", %{fx: _fx} do
      for prefix <- ["public", "tenant_xyz", "", ~s(tenant_"; DROP SCHEMA public; --)] do
        assert ScopeNodePaths.allowed_node_ids([F.nodes().a], prefix) ==
                 {:error, :invalid_schema_name},
               inspect(prefix)
      end
    end

    test "a non-list is a programmer error (FunctionClauseError), not a silent empty set", %{
      fx: fx
    } do
      for not_a_list <- [F.nodes().a, nil, :a, %{}] do
        assert_raise FunctionClauseError, fn ->
          apply(ScopeNodePaths, :allowed_node_ids, [not_a_list, fx.schema_name])
        end
      end
    end
  end

  # ===========================================================================================
  describe "T-C14 the cap (node half)" do
    setup do
      {:ok, fx: F.provision!("req518-nodeids-cap")}
    end

    test "a set larger than the cap is {:error, :too_many_ids}, a set equal to the cap is returned whole",
         %{fx: fx} do
      roots = [F.nodes().a, F.nodes().b1]

      put_cap!(3)
      assert ScopeNodePaths.allowed_node_ids(roots, fx.schema_name) == {:error, :too_many_ids}

      put_cap!(4)

      assert ScopeNodePaths.allowed_node_ids(roots, fx.schema_name) ==
               {:ok, ids([:a, :a1, :a2x, :b1])}

      put_cap!(1)
      assert ScopeNodePaths.allowed_node_ids([F.nodes().b1], fx.schema_name) == {:ok, ids([:b1])}

      assert ScopeNodePaths.allowed_node_ids([F.nodes().b], fx.schema_name) ==
               {:error, :too_many_ids}
    end

    test "the default cap is not hit by a normal grant (key unset)", %{fx: fx} do
      Application.delete_env(:letflow, @cap_key)

      assert {:ok, set} = ScopeNodePaths.allowed_node_ids([F.nodes().root], fx.schema_name)
      assert length(set) == 6
    end
  end

  # ===========================================================================================
  describe "chunking: no input size is rejected" do
    setup do
      {:ok, fx: S.tenant!("req518-nodeids-chunk")}
    end

    # root nodes inserted RAW with the shape the sole writer produced for one of them
    defp insert_roots_raw!(schema, count) do
      template = insert!(schema, "chunk-template", nil)
      node = Repo.get!(Node, template, prefix: schema)
      now = DateTime.utc_now()

      rows =
        for n <- 1..count do
          id = "chunk-#{String.pad_leading(Integer.to_string(n), 4, "0")}"

          %{
            node_id: id,
            path: String.replace(node.path, template, id),
            depth: node.depth,
            retired_at: nil,
            inserted_at: now,
            updated_at: now
          }
        end

      {^count, _} = Repo.insert_all(Node, rows, prefix: schema)
      Enum.map(rows, & &1.node_id)
    end

    test "500 roots are one chunk (two statements), 501 are two chunks (four): every id is returned",
         %{fx: fx} do
      roots = insert_roots_raw!(fx.schema_name, 501)
      {first_500, _} = Enum.split(roots, 500)

      {result, queries} =
        Fixture.capture_repo_queries(fn ->
          ScopeNodePaths.allowed_node_ids(first_500, fx.schema_name)
        end)

      assert {:ok, set} = result
      assert set == Enum.sort(first_500)
      assert length(queries) == 2

      {result, queries} =
        Fixture.capture_repo_queries(fn ->
          ScopeNodePaths.allowed_node_ids(roots, fx.schema_name)
        end)

      assert {:ok, set} = result
      assert set == Enum.sort(roots)
      assert length(set) == 501
      assert length(queries) == 4
    end

    test "the cap applies across chunks: 501 live roots with a cap of 500 fail closed", %{fx: fx} do
      roots = insert_roots_raw!(fx.schema_name, 501)
      put_cap!(500)

      assert ScopeNodePaths.allowed_node_ids(roots, fx.schema_name) == {:error, :too_many_ids}
    end
  end
end
