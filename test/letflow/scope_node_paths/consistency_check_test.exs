defmodule Letflow.ScopeNodePaths.ConsistencyCheckTest do
  @moduledoc """
  REQ-496 / GH #2530 AC7, design `lib/letflow/design/req496-managed-by-and-scope-node-paths.md`
  §6.4, D12 and §9 T-28 (spec `test/specs/REQ-496.md`): the consistency "mix check test". It runs in
  the ExUnit suite that `mix letflow.check` runs (`letflow.check.test`), against seeded rows,
  calling the same `Letflow.ScopeNodePaths.Consistency.check/1` the admin endpoint calls.

  Defective rows cannot be produced through `write/2` (that is the point of the one writer), so
  they are seeded with a raw `insert_all` into the tenant's table: an orphan, an A/B cycle and a
  consistent 13-deep chain are each reported; a tree built through `write/2` reports `:ok`. The
  pure `analyse/1` covers `malformed`, `stale_paths`, a repeated-segment cycle and the list cap.

  `async: false`: tenant provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.ScopeNodePaths
  alias Letflow.ScopeNodePaths.Consistency
  alias Letflow.ScopeNodePaths.Node
  alias Letflow.TenantFixture

  @zero %{orphans: 0, cycles: 0, depth_exceeded: 0, malformed: 0, stale_paths: 0}

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req496-snp-check")
    {:ok, schema: tenant.schema_name}
  end

  defp seed!(schema, rows) do
    now = NaiveDateTime.utc_now()

    entries =
      for {node_id, path, depth} <- rows do
        %{node_id: node_id, path: path, depth: depth, inserted_at: now, updated_at: now}
      end

    {count, _} = Repo.insert_all("scope_node_paths", entries, prefix: schema)
    assert count == length(rows)
  end

  defp chain_rows(prefix, n) do
    for k <- 1..n do
      segments = for i <- 1..k, do: "#{prefix}#{i}"
      {"#{prefix}#{k}", "/" <> Enum.join(segments, "/") <> "/", k}
    end
  end

  defp node(node_id, path, depth), do: %Node{node_id: node_id, path: path, depth: depth}

  describe "check/1 over a tenant's table" do
    test "a tree built through write/2 is consistent", %{schema: schema} do
      for {id, parent} <- [{"r", nil}, {"a", "r"}, {"b", "a"}, {"x", "r"}] do
        {:ok, _} = ScopeNodePaths.write({:insert, id, parent}, schema)
      end

      {:ok, _} = ScopeNodePaths.write({:move, "a", "x"}, schema)
      {:ok, _} = ScopeNodePaths.write({:retire, "b"}, schema)

      assert {:ok, report} = Consistency.check(schema)
      assert report.status == :ok
      assert report.checked_nodes == 4
      assert report.max_depth == 12
      assert report.counts == @zero
      assert report.truncated == false

      for key <- [:orphans, :cycles, :depth_exceeded, :malformed, :stale_paths] do
        assert Map.fetch!(report, key) == [], "#{key}"
      end
    end

    test "an empty table is consistent", %{schema: schema} do
      assert {:ok, %{status: :ok, checked_nodes: 0, counts: @zero}} = Consistency.check(schema)
    end

    test "a seeded orphan is reported", %{schema: schema} do
      seed!(schema, [{"r", "/r/", 1}, {"o", "/ghost/o/", 2}])

      assert {:ok, report} = Consistency.check(schema)
      assert report.status == :inconsistent
      assert report.orphans == ["o"]
      assert report.counts == %{@zero | orphans: 1}
    end

    test "a seeded A/B cycle reports both nodes (and neither as an orphan)", %{schema: schema} do
      seed!(schema, [{"A", "/B/A/", 2}, {"B", "/A/B/", 2}])

      assert {:ok, report} = Consistency.check(schema)
      assert report.status == :inconsistent
      assert report.cycles == ["A", "B"]
      assert report.orphans == []
      assert report.counts == %{@zero | cycles: 2}
    end

    test "a consistent 13-deep chain reports only its deepest node as depth_exceeded", %{
      schema: schema
    } do
      seed!(schema, chain_rows("d", 13))

      assert {:ok, report} = Consistency.check(schema)
      assert report.status == :inconsistent
      assert report.depth_exceeded == ["d13"]
      assert report.counts == %{@zero | depth_exceeded: 1}
      assert report.checked_nodes == 13
    end

    test "the check is read-only", %{schema: schema} do
      seed!(schema, [{"o", "/ghost/o/", 2}])
      before = Repo.all(Node, prefix: schema)
      assert {:ok, _report} = Consistency.check(schema)
      assert Repo.all(Node, prefix: schema) == before
    end

    test "an invalid prefix is refused" do
      assert Consistency.check("public") == {:error, :invalid_schema_name}
    end
  end

  describe "check/2 row cap" do
    test "a table over the cap is read up to the cap, truncated, and not :ok", %{schema: schema} do
      seed!(schema, chain_rows("c", 5))

      assert {:ok, report} = Consistency.check(schema, 3)
      assert report.truncated == true
      assert report.status == :inconsistent
      assert report.checked_nodes == 3

      # Stable: the same first rows (by node_id) every time.
      assert {:ok, ^report} = Consistency.check(schema, 3)
    end

    test "a table exactly at the cap is complete and not truncated", %{schema: schema} do
      seed!(schema, chain_rows("c", 3))

      assert {:ok, report} = Consistency.check(schema, 3)
      assert report.truncated == false
      assert report.status == :ok
      assert report.checked_nodes == 3
    end

    test "the default cap is bounded" do
      assert Consistency.row_cap() == 50_000
    end
  end

  describe "analyse/1 (pure)" do
    test "malformed: bad path shape, last segment not the id, depth not the segment count" do
      report =
        Consistency.analyse([
          node("m1", "no-slashes", 1),
          node("m2", "/x/y/", 2),
          node("m3", "/m3/", 2),
          node("m4", "//m4/", 1),
          node("ok", "/ok/", 1)
        ])

      assert report.malformed == ["m1", "m2", "m3", "m4"]
      assert report.counts.malformed == 4
      assert report.status == :inconsistent
      # Malformed rows are excluded from the orphan/cycle/stale rules.
      assert report.orphans == []
      assert report.stale_paths == []
    end

    test "stale_paths: the parent row exists but its path does not prefix the child's" do
      report =
        Consistency.analyse([
          node("p", "/p/", 1),
          node("c", "/q/p/c/", 3),
          node("fine", "/p/fine/", 2)
        ])

      assert report.stale_paths == ["c"]
      assert report.orphans == []
      assert report.counts == %{@zero | stale_paths: 1}
    end

    test "a path with a repeated segment is a cycle" do
      report =
        Consistency.analyse([node("x", "/x/y/x/", 3), node("y", "/x/y/", 2), node("r", "/x/", 1)])

      assert "x" in report.cycles
    end

    test "lists are sorted and capped at 1000; counts stay exact; truncated flags the cap" do
      orphans = for i <- 1..1001, do: node("o#{i}", "/ghost/o#{i}/", 2)
      report = Consistency.analyse(orphans)

      assert report.counts.orphans == 1001
      assert length(report.orphans) == 1000
      assert report.orphans == Enum.sort(report.orphans)
      assert report.truncated == true
    end
  end
end
