defmodule Letflow.ScopeNodePaths.ReadTest do
  @moduledoc """
  REQ-496 / GH #2530 AC8, design `lib/letflow/design/req496-managed-by-and-scope-node-paths.md`
  §6.3 and §9 T-30 (spec `test/specs/REQ-496.md`): `ancestors/2` and `descendants_of/2` return the
  right node sets, and an id containing `%` or `_` matches LITERALLY in the subtree query, never as
  a LIKE wildcard (INV-7). `like_prefix_pattern/1` is the single escaping helper.

  The wildcard pairs are built so an unescaped pattern WOULD over-match: `/a%/%` also matches
  `/ab/...`, and `/a_/%` also matches `/ax/...`.

  `async: false`: tenant provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.ScopeNodePaths
  alias Letflow.TenantFixture

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req496-snp-read")
    schema = tenant.schema_name

    # r -> a -> a1, r -> b (b retired); wildcard pairs a% / ab and a_ / ax, each with a child.
    for {id, parent} <- [
          {"r", nil},
          {"a", "r"},
          {"a1", "a"},
          {"b", "r"},
          {"a%", nil},
          {"k1", "a%"},
          {"ab", nil},
          {"k2", "ab"},
          {"a_", nil},
          {"k3", "a_"},
          {"ax", nil},
          {"k4", "ax"}
        ] do
      {:ok, _node} = ScopeNodePaths.write({:insert, id, parent}, schema)
    end

    {:ok, _retired} = ScopeNodePaths.write({:retire, "b"}, schema)
    {:ok, schema: schema}
  end

  defp ids({:ok, nodes}), do: Enum.map(nodes, & &1.node_id)

  describe "ancestors/2" do
    test "root first, the node itself excluded", %{schema: schema} do
      assert ids(ScopeNodePaths.ancestors("a1", schema)) == ["r", "a"]
      assert ids(ScopeNodePaths.ancestors("a", schema)) == ["r"]
      assert ids(ScopeNodePaths.ancestors("r", schema)) == []
      assert ids(ScopeNodePaths.ancestors("k1", schema)) == ["a%"]
    end

    test "typed errors", %{schema: schema} do
      assert ScopeNodePaths.ancestors("ghost", schema) == {:error, :node_not_found}
      assert ScopeNodePaths.ancestors("a/b", schema) == {:error, :invalid_node_id}
      assert ScopeNodePaths.ancestors("r", "public") == {:error, :invalid_schema_name}
    end
  end

  describe "descendants_of/2" do
    test "includes the given nodes, unions subtrees, keeps retired nodes, ordered by path", %{
      schema: schema
    } do
      assert ids(ScopeNodePaths.descendants_of(["a"], schema)) == ["a", "a1"]

      assert ids(ScopeNodePaths.descendants_of(["r"], schema)) == ["r", "a", "a1", "b"]

      assert {:ok, union} = ScopeNodePaths.descendants_of(["a", "b"], schema)
      assert Enum.map(union, & &1.node_id) == ["a", "a1", "b"]
      assert Enum.find(union, &(&1.node_id == "b")).retired_at != nil
    end

    test "unknown ids are ignored, duplicates collapse, [] is []", %{schema: schema} do
      assert ids(ScopeNodePaths.descendants_of(["a", "ghost"], schema)) == ["a", "a1"]
      assert ids(ScopeNodePaths.descendants_of(["a", "a"], schema)) == ["a", "a1"]
      assert ScopeNodePaths.descendants_of(["ghost"], schema) == {:ok, []}
      assert ScopeNodePaths.descendants_of([], schema) == {:ok, []}
    end

    test "more than 500 distinct ids is :too_many_nodes; 500 is accepted", %{schema: schema} do
      too_many = for i <- 1..501, do: "n#{i}"
      assert ScopeNodePaths.descendants_of(too_many, schema) == {:error, :too_many_nodes}

      at_bound = for i <- 1..500, do: "n#{i}"
      assert ScopeNodePaths.descendants_of(at_bound, schema) == {:ok, []}

      # 501 entries that dedupe to 500 are accepted.
      assert {:ok, _} = ScopeNodePaths.descendants_of(["n1" | at_bound], schema)
      assert ScopeNodePaths.descendants_of(["ok", "a/b"], schema) == {:error, :invalid_node_id}
    end

    test "% and _ in an id match literally, not as wildcards (INV-7)", %{schema: schema} do
      assert ids(ScopeNodePaths.descendants_of(["a%"], schema)) == ["a%", "k1"]
      assert ids(ScopeNodePaths.descendants_of(["a_"], schema)) == ["a_", "k3"]
      assert ids(ScopeNodePaths.descendants_of(["ab"], schema)) == ["ab", "k2"]
      assert ids(ScopeNodePaths.descendants_of(["ax"], schema)) == ["ax", "k4"]
    end
  end

  describe "like_prefix_pattern/1" do
    test "escapes backslash, percent and underscore, then appends %" do
      assert ScopeNodePaths.like_prefix_pattern("/r/a/") == "/r/a/%"
      assert ScopeNodePaths.like_prefix_pattern("/a%/") == "/a\\%/%"
      assert ScopeNodePaths.like_prefix_pattern("/a_/") == "/a\\_/%"
      assert ScopeNodePaths.like_prefix_pattern("/a\\b/") == "/a\\\\b/%"
      # Backslash first, so an escaped % is not double-escaped.
      assert ScopeNodePaths.like_prefix_pattern("/\\%_/") == "/\\\\\\%\\_/%"
    end
  end
end
