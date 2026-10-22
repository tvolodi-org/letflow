defmodule Letflow.ScopeNodePaths.WriteTest do
  @moduledoc """
  REQ-496 / GH #2530 AC5, design `lib/letflow/design/req496-managed-by-and-scope-node-paths.md`
  §6.1-§6.2 and §9 T-21..T-26 (spec `test/specs/REQ-496.md`): `Letflow.ScopeNodePaths.write/2`,
  the ONE writer of the `scope_node_paths` security index, and `lock!/1`.

    * T-21: insert/retire happy paths; inside a caller transaction an `org_unit` record write plus
      a projection insert both vanish on `Repo.rollback/1` (no divergence); outside a transaction
      `write/2` commits on its own.
    * T-22: a move re-parents the whole subtree in one step.
    * T-23: a direct and a transitive cycle are refused, table unchanged.
    * T-24: depth 12 is the bound for inserts and for moved subtrees.
    * T-25: every typed refusal; a refusal inside a caller transaction leaves it usable.
    * T-26: the `SHARE ROW EXCLUSIVE` table lock is held by the caller's transaction after
      `write/2` and after `lock!/1`; `lock!/1` is re-entrant and raises outside a transaction;
      the documented org insert sequence (`lock!` -> `create_record` -> `write`) commits, and a
      refused `write` followed by `Repo.rollback/1` leaves neither record nor projection row.

  No test here holds a lock across two connections, so nothing waits. `async: false`: tenant
  provisioning switches the sandbox to `:auto`, and the transaction assertions need real
  transactions.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.ScopeNodePaths
  alias Letflow.ScopeNodePaths.Node
  alias Letflow.TenantFixture

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req496-snp-write")
    {:ok, schema: tenant.schema_name}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp insert!(schema, id, parent) do
    {:ok, node} = ScopeNodePaths.write({:insert, id, parent}, schema)
    node
  end

  defp chain!(schema, ids) do
    Enum.reduce(ids, nil, fn id, parent ->
      insert!(schema, id, parent)
      id
    end)
  end

  defp node(schema, id), do: Repo.get(Node, id, prefix: schema)

  defp snapshot(schema) do
    Repo.all(from(n in Node, select: {n.node_id, n.path, n.depth, n.retired_at}), prefix: schema)
    |> Enum.sort()
  end

  # An active `org_unit` entity type, created as an ordinary tenant type (the node id of an org
  # insert is the record id `Records.create_record/2` mints).
  defp org_unit_type!(schema) do
    {:ok, _seeded} = EventTypes.seed!(schema)
    actor = Ecto.UUID.generate()

    _ =
      Letflow.ManagedTypesSupport.plant_legacy_definition!(schema, %{
        name: "org_unit",
        display_name: "Org Unit",
        fields: [%{name: "name", type: :string, required: true}]
      })

    {:ok, _active} = Definitions.activate_definition("org_unit", actor, "REQ-496 test", schema)
    :ok
  end

  defp create_org_unit!(schema) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: "org_unit",
          field_values: %{"name" => "unit"},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        schema
      )

    record.record_id
  end

  defp org_unit_records(schema) do
    Repo.aggregate(from(l in Latest, where: l.entity_type == "org_unit"), :count, prefix: schema)
  end

  defp table_lock_held?(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_locks
        WHERE locktype = 'relation' AND mode = 'ShareRowExclusiveLock' AND granted
          AND pid = pg_backend_pid() AND relation = to_regclass($1)::oid
        """,
        [~s|"#{schema}".scope_node_paths|]
      )

    n == 1
  end

  # ── T-21 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-21: insert, retire, and the caller's transaction" do
    test "insert a root and a child, retire the child (idempotently)", %{schema: schema} do
      root = insert!(schema, "r", nil)
      assert %Node{node_id: "r", path: "/r/", depth: 1, retired_at: nil} = root

      child = insert!(schema, "c", "r")
      assert %Node{node_id: "c", path: "/r/c/", depth: 2, retired_at: nil} = child

      assert {:ok, %Node{retired_at: %DateTime{} = retired_at}} =
               ScopeNodePaths.write({:retire, "c"}, schema)

      # Idempotent: the second retire returns the stored row unchanged.
      assert {:ok, %Node{retired_at: ^retired_at}} = ScopeNodePaths.write({:retire, "c"}, schema)

      # Descendants and the parent are untouched by a retire.
      assert node(schema, "r").retired_at == nil
      assert node(schema, "c").path == "/r/c/"
    end

    test "rolling back the caller removes a move and a retire as well", %{schema: schema} do
      chain!(schema, ["r", "a", "b"])
      insert!(schema, "x", "r")
      before = snapshot(schema)

      assert {:error, :undo} =
               Repo.transaction(fn ->
                 assert {:ok, %Node{path: "/r/x/a/"}} =
                          ScopeNodePaths.write({:move, "a", "x"}, schema)

                 assert {:ok, %Node{retired_at: %DateTime{}}} =
                          ScopeNodePaths.write({:retire, "b"}, schema)

                 assert node(schema, "a").path == "/r/x/a/"
                 assert node(schema, "b").path == "/r/x/a/b/"
                 assert node(schema, "b").retired_at != nil
                 Repo.rollback(:undo)
               end)

      assert snapshot(schema) == before
    end

    test "outside a transaction write/2 commits on its own", %{schema: schema} do
      refute Repo.in_transaction?()
      insert!(schema, "standalone", nil)

      %{rows: [[n]]} =
        Repo.query!(
          ~s|SELECT count(*) FROM "#{schema}".scope_node_paths WHERE node_id = 'standalone'|
        )

      assert n == 1
    end

    test "Repo.rollback after an org_unit record write and a projection insert leaves neither",
         %{schema: schema} do
      :ok = org_unit_type!(schema)
      before = org_unit_records(schema)

      assert {:error, :undo} =
               Repo.transaction(fn ->
                 record_id = create_org_unit!(schema)

                 assert {:ok, %Node{path: path}} =
                          ScopeNodePaths.write({:insert, record_id, nil}, schema)

                 assert path == "/" <> record_id <> "/"
                 assert org_unit_records(schema) == before + 1
                 Process.put(:req496_rolled_back_id, record_id)
                 Repo.rollback(:undo)
               end)

      record_id = Process.get(:req496_rolled_back_id)
      assert org_unit_records(schema) == before
      assert Latest.get(record_id, "org_unit", schema) == {:error, :not_found}
      assert node(schema, record_id) == nil
    end
  end

  # ── T-22 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-22: a transitive move" do
    test "moving a under x rewrites a, b and c; siblings and the root are untouched",
         %{schema: schema} do
      chain!(schema, ["r", "a", "b", "c"])
      insert!(schema, "x", "r")
      insert!(schema, "y", "r")

      assert {:ok, %Node{node_id: "a", path: "/r/x/a/", depth: 3}} =
               ScopeNodePaths.write({:move, "a", "x"}, schema)

      assert {node(schema, "a").path, node(schema, "a").depth} == {"/r/x/a/", 3}
      assert {node(schema, "b").path, node(schema, "b").depth} == {"/r/x/a/b/", 4}
      assert {node(schema, "c").path, node(schema, "c").depth} == {"/r/x/a/b/c/", 5}
      assert {node(schema, "x").path, node(schema, "x").depth} == {"/r/x/", 2}
      assert {node(schema, "y").path, node(schema, "y").depth} == {"/r/y/", 2}
      assert {node(schema, "r").path, node(schema, "r").depth} == {"/r/", 1}
    end

    test "moving to nil makes a root; an unchanged parent writes nothing", %{schema: schema} do
      chain!(schema, ["r", "a", "b"])

      before = snapshot(schema)
      assert {:ok, %Node{node_id: "a"}} = ScopeNodePaths.write({:move, "a", "r"}, schema)
      assert snapshot(schema) == before

      assert {:ok, %Node{path: "/a/", depth: 1}} = ScopeNodePaths.write({:move, "a", nil}, schema)
      assert {node(schema, "b").path, node(schema, "b").depth} == {"/a/b/", 2}
    end
  end

  # ── T-23 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-23: cycles" do
    test "a direct and a transitive cycle are each refused, table unchanged", %{schema: schema} do
      chain!(schema, ["r", "a", "b", "c"])
      before = snapshot(schema)

      assert ScopeNodePaths.write({:move, "a", "a"}, schema) == {:error, :cycle}
      assert ScopeNodePaths.write({:move, "a", "c"}, schema) == {:error, :cycle}
      assert ScopeNodePaths.write({:move, "a", "b"}, schema) == {:error, :cycle}

      assert snapshot(schema) == before
    end
  end

  # ── T-24 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-24: depth bound 12" do
    test "a 12-deep chain is allowed, the 13th level is refused", %{schema: schema} do
      ids = for i <- 1..12, do: "n#{i}"
      chain!(schema, ids)

      assert node(schema, "n12").depth == 12
      assert ScopeNodePaths.write({:insert, "n13", "n12"}, schema) == {:error, :depth_exceeded}
      assert node(schema, "n13") == nil
    end

    test "a move that pushes the deepest descendant past 12 is refused; exactly 12 is allowed",
         %{schema: schema} do
      chain!(schema, for(i <- 1..11, do: "n#{i}"))
      chain!(schema, ["s", "s2"])
      before = snapshot(schema)

      # s under n11 -> s at 12, s2 at 13.
      assert ScopeNodePaths.write({:move, "s", "n11"}, schema) == {:error, :depth_exceeded}
      assert snapshot(schema) == before

      # s under n10 -> s at 11, s2 at 12: the bound itself is allowed.
      assert {:ok, %Node{depth: 11}} = ScopeNodePaths.write({:move, "s", "n10"}, schema)
      assert node(schema, "s2").depth == 12
    end
  end

  # ── T-25 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-25: typed refusals" do
    test "parent_not_found, parent_retired, node_exists, node_not_found, node_retired", %{
      schema: schema
    } do
      chain!(schema, ["r", "a"])
      insert!(schema, "gone", "r")
      {:ok, _} = ScopeNodePaths.write({:retire, "gone"}, schema)

      assert ScopeNodePaths.write({:insert, "x", "ghost"}, schema) == {:error, :parent_not_found}
      assert ScopeNodePaths.write({:insert, "x", "gone"}, schema) == {:error, :parent_retired}
      assert ScopeNodePaths.write({:insert, "a", "r"}, schema) == {:error, :node_exists}
      assert ScopeNodePaths.write({:insert, "r", nil}, schema) == {:error, :node_exists}
      assert ScopeNodePaths.write({:move, "ghost", "r"}, schema) == {:error, :node_not_found}
      assert ScopeNodePaths.write({:retire, "ghost"}, schema) == {:error, :node_not_found}
      assert ScopeNodePaths.write({:move, "gone", "a"}, schema) == {:error, :node_retired}
      assert ScopeNodePaths.write({:move, "a", "ghost"}, schema) == {:error, :parent_not_found}
      assert ScopeNodePaths.write({:move, "a", "gone"}, schema) == {:error, :parent_retired}
      assert node(schema, "x") == nil
    end

    test "invalid node ids are refused before anything else", %{schema: schema} do
      insert!(schema, "r", nil)

      for bad <- ["", "a/b", String.duplicate("a", 65), "a\nb", <<0xFF>>, 123] do
        assert ScopeNodePaths.write({:insert, bad, nil}, schema) == {:error, :invalid_node_id},
               inspect(bad)

        assert ScopeNodePaths.write({:insert, "ok", bad}, schema) == {:error, :invalid_node_id},
               inspect(bad)
      end

      # A nil node id is invalid (a nil PARENT means "root").
      assert ScopeNodePaths.write({:insert, nil, nil}, schema) == {:error, :invalid_node_id}

      assert ScopeNodePaths.write({:move, "r", "a/b"}, schema) == {:error, :invalid_node_id}
      assert ScopeNodePaths.write({:retire, ""}, schema) == {:error, :invalid_node_id}
      assert ScopeNodePaths.write({:unknown_op, "r"}, schema) == {:error, :invalid_node_id}

      # 64 bytes is the inclusive bound.
      max = String.duplicate("b", 64)
      assert {:ok, %Node{node_id: ^max}} = ScopeNodePaths.write({:insert, max, "r"}, schema)
      assert node(schema, "ok") == nil
    end

    test "an invalid prefix is refused", %{schema: _schema} do
      assert ScopeNodePaths.write({:insert, "r", nil}, "public") ==
               {:error, :invalid_schema_name}
    end

    test "a refusal inside a caller transaction leaves it usable", %{schema: schema} do
      insert!(schema, "r", nil)

      assert {:ok, :committed} =
               Repo.transaction(fn ->
                 assert ScopeNodePaths.write({:insert, "x", "ghost"}, schema) ==
                          {:error, :parent_not_found}

                 assert ScopeNodePaths.write({:move, "r", "r"}, schema) == {:error, :cycle}
                 assert {:ok, %Node{}} = ScopeNodePaths.write({:insert, "y", "r"}, schema)
                 :committed
               end)

      assert node(schema, "y").path == "/r/y/"
      assert node(schema, "x") == nil
    end
  end

  # ── T-26 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-26: the table lock and lock!/1" do
    test "write/2 inside a caller transaction holds SHARE ROW EXCLUSIVE until it ends", %{
      schema: schema
    } do
      assert {:ok, :checked} =
               Repo.transaction(fn ->
                 refute table_lock_held?(schema)
                 insert!(schema, "r", nil)
                 assert table_lock_held?(schema)
                 :checked
               end)

      refute table_lock_held?(schema)
    end

    test "lock!/1 takes the same lock, is re-entrant, and raises outside a transaction", %{
      schema: schema
    } do
      assert {:ok, :checked} =
               Repo.transaction(fn ->
                 assert ScopeNodePaths.lock!(schema) == :ok
                 assert table_lock_held?(schema)
                 assert ScopeNodePaths.lock!(schema) == :ok

                 assert {:ok, %Node{path: "/r/"}} =
                          ScopeNodePaths.write({:insert, "r", nil}, schema)

                 :checked
               end)

      assert node(schema, "r").depth == 1

      assert_raise ArgumentError, fn -> ScopeNodePaths.lock!(schema) end

      assert {:error, :raised} =
               Repo.transaction(fn ->
                 try do
                   ScopeNodePaths.lock!("public")
                 rescue
                   ArgumentError -> Repo.rollback(:raised)
                 end
               end)
    end

    test "the documented org insert sequence commits; a refused write rolled back leaves nothing",
         %{schema: schema} do
      :ok = org_unit_type!(schema)

      assert {:ok, committed_id} =
               Repo.transaction(fn ->
                 :ok = ScopeNodePaths.lock!(schema)
                 record_id = create_org_unit!(schema)
                 {:ok, %Node{}} = ScopeNodePaths.write({:insert, record_id, nil}, schema)
                 record_id
               end)

      assert {:ok, _record} = Latest.get(committed_id, "org_unit", schema)
      assert node(schema, committed_id).path == "/" <> committed_id <> "/"
      before = org_unit_records(schema)

      assert {:error, :parent_not_found} =
               Repo.transaction(fn ->
                 :ok = ScopeNodePaths.lock!(schema)
                 record_id = create_org_unit!(schema)
                 Process.put(:req496_refused_id, record_id)

                 case ScopeNodePaths.write({:insert, record_id, "ghost-parent"}, schema) do
                   {:ok, _node} -> :unexpected
                   {:error, reason} -> Repo.rollback(reason)
                 end
               end)

      refused_id = Process.get(:req496_refused_id)
      assert org_unit_records(schema) == before
      assert Latest.get(refused_id, "org_unit", schema) == {:error, :not_found}
      assert node(schema, refused_id) == nil
    end
  end
end
