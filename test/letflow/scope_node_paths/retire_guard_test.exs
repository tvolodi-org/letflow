defmodule Letflow.ScopeNodePaths.RetireGuardTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2a, AC 5 (design `lib/letflow/design/req517-scoped-grants-admin-plane.md`
  section 3.7 and finding F2; spec `test/specs/REQ-517-2a.md`, T-R1..T-R5): a node a grant row
  names cannot be retired.

    * `{:retire, n}` of a LIVE node locks the node row `FOR NO KEY UPDATE` FIRST, THEN reads
      `RoleScopeGrants.references_node?/2`; `{:error, :node_has_grants}` leaves `retired_at` NULL;
    * a `:move` of a referenced node is allowed; an already-retired node is idempotent and does not
      consult the grants;
    * the two interleavings with a held lock in a second connection (READ COMMITTED asserted):
      (i) a create holds the node share lock and has not committed: the retire waits, then refuses;
      (ii) a retire holds the node row and commits: the create waiting on the share lock re-reads
      `retired_at`, answers `invalid_scope_node` and writes nothing.

  `async: false`: committed writes and cross-connection locks.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.ScopedGrants
  alias Letflow.ScopeNodePaths
  alias Letflow.ScopeNodePaths.Node
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @worker "TASK_WORKER"

  defp retired_at(schema, node_id), do: Repo.get!(Node, node_id, prefix: schema).retired_at

  defp actor(fx), do: %{user_id: fx.admin.id, trace_id: nil, credential: "oidc"}

  # ===========================================================================================
  describe "T-R1 the retire guard" do
    test "references_node?/2 is true only for a node a row names; the retire is refused with :node_has_grants and retired_at stays NULL; after the last row is deleted it succeeds" do
      fx = S.tenant!("r517-r1")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)
      unreferenced = RSG.node!(s)
      row = S.create_body(:group, gid, @worker, node)
      conn = S.as_admin(Letflow.Routers.TenantRoleScopeGrants, :post, "/", fx, row)
      assert conn.status == 201
      row_id = S.body(conn)["id"]

      assert RoleScopeGrants.references_node?(node, s)
      refute RoleScopeGrants.references_node?(unreferenced, s)

      assert {:error, :node_has_grants} = ScopeNodePaths.write({:retire, node}, s)
      assert retired_at(s, node) == nil

      # the unreferenced node still retires
      assert {:ok, %Node{retired_at: %DateTime{}}} =
               ScopeNodePaths.write({:retire, unreferenced}, s)

      # another row on the same node, then delete both: the retire only passes when none is left
      other_gid = S.rowless_group!(fx, "PROCESS_DESIGNER")

      S.as_admin(
        Letflow.Routers.TenantRoleScopeGrants,
        :post,
        "/",
        fx,
        S.create_body(:group, other_gid, "PROCESS_DESIGNER", node)
      )

      other_node = RSG.node!(s)

      S.as_admin(
        Letflow.Routers.TenantRoleScopeGrants,
        :post,
        "/",
        fx,
        S.create_body(:group, gid, @worker, other_node)
      )

      assert S.as_admin(Letflow.Routers.TenantRoleScopeGrants, :delete, "/#{row_id}", fx, nil).status ==
               204

      assert {:error, :node_has_grants} = ScopeNodePaths.write({:retire, node}, s)

      # delete the other group's row too (raw: it is that group's only scoped row)
      _ = RSG.raw_delete_rows!(s, other_gid, "PROCESS_DESIGNER")
      assert {:ok, %Node{retired_at: %DateTime{}}} = ScopeNodePaths.write({:retire, node}, s)
    end

    test "only the node itself is checked: a grant on a child does not block retiring the parent" do
      fx = S.tenant!("r517-r1-child")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      parent = RSG.node!(s)
      child = "r517-child-#{System.unique_integer([:positive])}"
      {:ok, _node} = ScopeNodePaths.write({:insert, child, parent}, s)
      :ok = RSG.raw_scoped_row!(s, gid, @worker, child)

      assert {:ok, %Node{retired_at: %DateTime{}}} = ScopeNodePaths.write({:retire, parent}, s)
      assert {:error, :node_has_grants} = ScopeNodePaths.write({:retire, child}, s)
    end

    test "a refused retire writes nothing: retired_at and updated_at are unchanged" do
      fx = S.tenant!("r517-r1-nowrite")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)
      :ok = RSG.raw_scoped_row!(s, gid, @worker, node)
      before = Repo.get!(Node, node, prefix: s)

      assert {:error, :node_has_grants} = ScopeNodePaths.write({:retire, node}, s)

      assert Repo.get!(Node, node, prefix: s) == before
    end
  end

  # ===========================================================================================
  describe "T-R2 / T-R5" do
    test "T-R2 a move of a referenced node is allowed and the grant keeps referencing it" do
      fx = S.tenant!("r517-r2")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)
      new_parent = RSG.node!(s)
      :ok = RSG.raw_scoped_row!(s, gid, @worker, node)

      assert {:ok, %Node{}} = ScopeNodePaths.write({:move, node, new_parent}, s)

      assert RSG.scoped(gid, @worker, node) in RSG.rows(s)
      assert RoleScopeGrants.references_node?(node, s)
    end

    test "T-R5 retiring an already-retired node is idempotent {:ok, node} and does not consult the grants" do
      fx = S.tenant!("r517-r5")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)
      assert {:ok, %Node{retired_at: first}} = ScopeNodePaths.write({:retire, node}, s)
      # RAW: the FK allows a row to name a retired node; the routes would refuse to create one
      :ok = RSG.raw_scoped_row!(s, gid, @worker, node)
      assert RoleScopeGrants.references_node?(node, s)

      assert {:ok, %Node{retired_at: again}} = ScopeNodePaths.write({:retire, node}, s)
      assert again == first
    end

    test "an unknown node is still :node_not_found" do
      fx = S.tenant!("r517-r2-unknown")

      assert {:error, :node_not_found} =
               ScopeNodePaths.write({:retire, "no-such-node"}, fx.schema_name)
    end
  end

  # ===========================================================================================
  describe "lock_active_node_for_share!/2" do
    test "returns the live node; unknown, retired and malformed ids are tagged errors; it raises outside a transaction" do
      fx = S.tenant!("r517-r-share")
      s = fx.schema_name
      live = RSG.node!(s)
      retired = RSG.node!(s)
      {:ok, _} = ScopeNodePaths.write({:retire, retired}, s)

      assert_raise ArgumentError, fn -> ScopeNodePaths.lock_active_node_for_share!(live, s) end

      assert {:ok, {:ok, %Node{node_id: ^live}}} =
               Repo.transaction(fn -> ScopeNodePaths.lock_active_node_for_share!(live, s) end)

      assert {:ok, results} =
               Repo.transaction(fn ->
                 for id <- ["nope", retired, "a/b", "", 5, nil],
                     do: ScopeNodePaths.lock_active_node_for_share!(id, s)
               end)

      assert results == [
               {:error, :node_not_found},
               {:error, :node_retired},
               {:error, :invalid_node_id},
               {:error, :invalid_node_id},
               {:error, :invalid_node_id},
               {:error, :invalid_node_id}
             ]
    end
  end

  # ===========================================================================================
  describe "T-R3 / T-R4 the two interleavings (held locks in a second connection)" do
    test "T-R3 (i) a create holds the node share lock, uncommitted: the retire waits, then sees the committed grant and refuses" do
      fx = S.tenant!("r517-r3")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)
      parent = self()
      assert S.isolation() == "read committed"

      creator =
        Task.async(fn ->
          Repo.transaction(fn ->
            level = S.isolation()
            {:ok, _node} = ScopeNodePaths.lock_active_node_for_share!(node, s)
            send(parent, {:node_share_held, level})

            receive do
              :release -> :ok
            after
              10_000 -> :timeout
            end

            {:ok, _row} = RoleScopeGrants.insert_scoped(:group, gid, @worker, node, s)
            level
          end)
        end)

      assert_receive {:node_share_held, "read committed"}, 5_000
      retirer = Task.async(fn -> ScopeNodePaths.write({:retire, node}, s) end)

      try do
        assert S.lock_waiter?("FOR NO KEY UPDATE"), "the retire never queued on the node row"
        assert Task.yield(retirer, 300) == nil
        assert retired_at(s, node) == nil

        send(creator.pid, :release)
        assert {:ok, {:ok, "read committed"}} = Task.yield(creator, 5_000)
        assert {:ok, {:error, :node_has_grants}} = Task.yield(retirer, 5_000)
        assert retired_at(s, node) == nil
        assert RSG.scoped(gid, @worker, node) in RSG.rows(s)
      after
        S.stop_task(retirer)
        S.stop_task(creator)
      end
    end

    test "T-R4 (ii) a retire holds the node row and commits: the create waiting on the share lock re-reads retired_at, answers invalid_scope_node and writes nothing" do
      fx = S.tenant!("r517-r4")
      s = fx.schema_name
      gid = S.rowless_group!(fx, @worker)
      node = RSG.node!(s)
      parent = self()
      assert S.isolation() == "read committed"
      before = RSG.rows(s)

      retirer =
        Task.async(fn ->
          Repo.transaction(fn ->
            level = S.isolation()
            {:ok, %Node{retired_at: %DateTime{}}} = ScopeNodePaths.write({:retire, node}, s)
            send(parent, {:retire_held, level})

            receive do
              :release -> :ok
            after
              10_000 -> :timeout
            end

            level
          end)
        end)

      assert_receive {:retire_held, "read committed"}, 5_000

      attrs = %{principal_type: :group, principal_id: gid, role: @worker, scope_node_id: node}
      creator = Task.async(fn -> ScopedGrants.create(attrs, actor(fx), s) end)

      try do
        assert S.lock_waiter?("FOR SHARE"), "the create never queued on the node row"
        assert Task.yield(creator, 300) == nil

        send(retirer.pid, :release)
        assert {:ok, {:ok, "read committed"}} = Task.yield(retirer, 5_000)
        assert {:ok, {:error, :invalid_scope_node}} = Task.yield(creator, 5_000)
        assert RSG.rows(s) == before
        assert S.entries(fx, "grant.created") == []
        assert %DateTime{} = retired_at(s, node)
      after
        S.stop_task(creator)
        S.stop_task(retirer)
      end
    end
  end
end
