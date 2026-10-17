defmodule Letflow.Api.ScopeRetiredNodeTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 19 (decision 0051 T6; design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.4; spec
  `test/specs/REQ-517-2b.md`, T-G7): `Letflow.Api.Scope.allowed?/3` and a RETIRED resource node,
  plus the new `Letflow.ScopeNodePaths.resolve/2` the rule is built on.

    * a scoped principal asking about a resource node that is itself retired is
      `{:deny, :unresolvable}` (N4: a mutant that allows it fails), where the same node while live
      was `{:allow, :subtree}`;
    * a tenant-wide principal is allowed with NO tree read, so a retired node is still allowed for
      it (zero queries);
    * only the resource node's OWN `retired_at` counts: a retired ANCESTOR does not deny a live
      descendant (a grant can never name a retired node after 2a, so an ancestor holding a grant
      cannot be retired);
    * `resolve/2` returns the node and its ancestors (root first, retired ones included) with the
      same two reads as `ancestors/2`, and the same errors;
    * the moduledoc sentence "Retired nodes are not considered in stage 1" is gone.

  `async: false`: committed writes (real tenants), VM-global platform pin.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Scope
  alias Letflow.ScopeNodePaths
  alias Letflow.ScopeNodePaths.Node
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TokenMintFixture

  @scope_source "lib/letflow/api/scope.ex"

  defp node_id, do: "rsg-node-#{System.unique_integer([:positive])}"

  defp insert!(schema, id, parent) do
    {:ok, %Node{}} = ScopeNodePaths.write({:insert, id, parent}, schema)
    id
  end

  # root -> child -> grandchild, plus an unrelated root.
  defp tree!(schema) do
    root = insert!(schema, node_id(), nil)
    child = insert!(schema, node_id(), root)
    grandchild = insert!(schema, node_id(), child)
    other = insert!(schema, node_id(), nil)
    %{root: root, child: child, grandchild: grandchild, other: other}
  end

  # A TASK_WORKER whose group holds the role ONLY at `node` (the group's rows replaced).
  defp scoped_worker!(fx, node) do
    s = fx.schema_name
    worker = TokenMintFixture.role_holder!(s, ["TASK_WORKER"])
    group = RSG.group_of!(s, "TASK_WORKER")
    assert RSG.raw_delete_rows!(s, group, "TASK_WORKER") >= 1
    :ok = RSG.raw_scoped_row!(s, group, "TASK_WORKER", node)
    worker
  end

  defp retired?(schema, id), do: not is_nil(Repo.get!(Node, id, prefix: schema).retired_at)

  # ===========================================================================================
  describe "T-G7 allowed?/3 and a retired resource node" do
    test "a live descendant is allowed :subtree; once the resource node itself is retired a scoped principal is denied :unresolvable (N4)" do
      fx = S.tenant!("r517-g7-scoped")
      s = fx.schema_name
      %{root: root, child: child, other: other} = tree!(s)
      worker = scoped_worker!(fx, root)
      principal = S.principal(fx, worker.id)

      # control: while live
      assert Scope.allowed?(principal, :TasksRead, {:node, child}) == {:allow, :subtree}
      assert Scope.allowed?(principal, :TasksRead, {:node, other}) == {:deny, :out_of_scope}

      assert {:ok, %Node{retired_at: %DateTime{}}} = ScopeNodePaths.write({:retire, child}, s)
      assert retired?(s, child)

      assert Scope.allowed?(principal, :TasksRead, {:node, child}) == {:deny, :unresolvable}
      # the unrelated, out-of-scope node keeps answering out_of_scope (not unresolvable)
      assert Scope.allowed?(principal, :TasksRead, {:node, other}) == {:deny, :out_of_scope}
      # the granted node itself is untouched
      assert Scope.allowed?(principal, :TasksRead, {:node, root}) == {:allow, :subtree}
    end

    test "a tenant-wide principal is allowed on a retired node with ZERO queries" do
      fx = S.tenant!("r517-g7-tw")
      s = fx.schema_name
      %{child: child} = tree!(s)
      holder = TokenMintFixture.role_holder!(s, ["TASK_WORKER"])
      principal = S.principal(fx, holder.id)

      assert {:ok, _node} = ScopeNodePaths.write({:retire, child}, s)

      {decision, queries} =
        Fixture.capture_repo_queries(fn ->
          Scope.allowed?(principal, :TasksRead, {:node, child})
        end)

      assert decision == {:allow, :tenant_wide}
      assert queries == []
    end

    test "only the resource node's own retired_at counts: a retired ANCESTOR does not deny a live descendant" do
      fx = S.tenant!("r517-g7-anc")
      s = fx.schema_name
      %{root: root, child: child, grandchild: grandchild} = tree!(s)
      worker = scoped_worker!(fx, root)
      principal = S.principal(fx, worker.id)

      # the unreferenced middle node can be retired (only `root` is named by a grant)
      assert {:ok, _node} = ScopeNodePaths.write({:retire, child}, s)

      assert Scope.allowed?(principal, :TasksRead, {:node, grandchild}) == {:allow, :subtree}
      assert Scope.allowed?(principal, :TasksRead, {:node, child}) == {:deny, :unresolvable}
    end

    test "a missing and a malformed node stay :unresolvable (unchanged)" do
      fx = S.tenant!("r517-g7-missing")
      %{root: root} = tree!(fx.schema_name)
      principal = S.principal(fx, scoped_worker!(fx, root).id)

      assert Scope.allowed?(principal, :TasksRead, {:node, "rsg-node-does-not-exist"}) ==
               {:deny, :unresolvable}

      assert Scope.allowed?(principal, :TasksRead, {:node, "bad node id!"}) ==
               {:deny, :unresolvable}

      assert Scope.allowed?(principal, :TasksRead, :unresolvable) == {:deny, :unresolvable}
    end

    test "a retired node costs the scoped decision the same two reads as a live one (no extra read)" do
      fx = S.tenant!("r517-g7-cost")
      s = fx.schema_name
      %{root: root, child: child, grandchild: grandchild} = tree!(s)
      principal = S.principal(fx, scoped_worker!(fx, root).id)
      assert {:ok, _node} = ScopeNodePaths.write({:retire, child}, s)

      {live, live_queries} =
        Fixture.capture_repo_queries(fn ->
          Scope.allowed?(principal, :TasksRead, {:node, grandchild})
        end)

      {retired, retired_queries} =
        Fixture.capture_repo_queries(fn ->
          Scope.allowed?(principal, :TasksRead, {:node, child})
        end)

      assert live == {:allow, :subtree}
      assert retired == {:deny, :unresolvable}
      assert length(live_queries) == 2
      assert length(retired_queries) == 2
    end
  end

  # ===========================================================================================
  describe "ScopeNodePaths.resolve/2" do
    test "returns the node and its ancestors root first, retired ones included, with the same two reads as ancestors/2" do
      fx = S.tenant!("r517-g7-resolve")
      s = fx.schema_name
      %{root: root, child: child, grandchild: grandchild} = tree!(s)
      assert {:ok, _node} = ScopeNodePaths.write({:retire, child}, s)

      {{:ok, resolved}, queries} =
        Fixture.capture_repo_queries(fn -> ScopeNodePaths.resolve(grandchild, s) end)

      assert resolved.node.node_id == grandchild
      assert Enum.map(resolved.ancestors, & &1.node_id) == [root, child]
      assert [%Node{retired_at: nil}, %Node{retired_at: %DateTime{}}] = resolved.ancestors
      assert length(queries) == 2

      assert {:ok, ancestors} = ScopeNodePaths.ancestors(grandchild, s)
      assert ancestors == resolved.ancestors
    end

    test "resolves a RETIRED node itself (the rule needs its retired_at) and a root with no ancestors" do
      fx = S.tenant!("r517-g7-resolve2")
      s = fx.schema_name
      %{root: root, child: child} = tree!(s)
      assert {:ok, _node} = ScopeNodePaths.write({:retire, child}, s)

      assert {:ok, %{node: %Node{node_id: ^child, retired_at: %DateTime{}}}} =
               ScopeNodePaths.resolve(child, s)

      assert {:ok, %{node: %Node{node_id: ^root}, ancestors: []}} =
               ScopeNodePaths.resolve(root, s)
    end

    test "has the same errors as ancestors/2" do
      fx = S.tenant!("r517-g7-resolve3")
      s = fx.schema_name

      for {id, prefix} <- [
            {"rsg-node-does-not-exist", s},
            {"bad node id!", s},
            {"rsg-node-1", "not_a_tenant_schema"}
          ] do
        assert ScopeNodePaths.resolve(id, prefix) == ScopeNodePaths.ancestors(id, prefix),
               inspect({id, prefix})

        assert {:error, reason} = ScopeNodePaths.resolve(id, prefix)
        assert reason in [:node_not_found, :invalid_node_id, :invalid_schema_name]
      end
    end
  end

  # ===========================================================================================
  test "the moduledoc no longer says retired nodes are not considered, and states the T6 rule" do
    source = File.read!(@scope_source)

    refute source =~ "Retired nodes are not considered in stage 1"
    assert source =~ "RETIRED"
    assert source =~ "{:deny, :unresolvable}"
  end
end
