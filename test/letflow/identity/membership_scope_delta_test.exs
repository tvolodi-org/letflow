defmodule Letflow.Identity.MembershipScopeDeltaTest do
  @moduledoc """
  REQ-519 slice 2e-b (GH #2535), AC 4 (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 3.8 and 8.2, tests
  T-D1..T-D5; spec `test/specs/REQ-519-2e-b.md`): `group_member.added` and
  `group_member.removed` carry the resulting effective-scope delta (`scope_delta`, a list of
  role / from / to) in EVERY mode, computed in the same transaction as the membership change,
  with the pre-existing keys unchanged, org-unit ids capped at 50 plus a count, and only the
  tenant's own ids.

  Also here: the pure and read-only functions of `Letflow.Identity.MembershipScope`
  (`delta/2`, `would_widen?/2`, `render/1`, `snapshot/2`, `row_scopes/2`, `snapshot_if_added/4`)
  that the sync guard builds its decision on.

  `async: false`: real tenant schemas, committed writes.
  """

  use Letflow.DataCase, async: false

  import Letflow.Support.EnforcedWritersFixture, only: [tenant!: 2]
  import Letflow.Support.RoleScopeGrantsFixture, only: [user!: 1, node!: 1, raw_user_row!: 4]

  alias Letflow.Identity
  alias Letflow.Identity.MembershipScope
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.SyncScopeFixture, as: S

  @ctx %{actor_id: nil, trace_id: "req519-2eb-d-trace", source: "api"}
  @legacy_keys ~w(group_id group_roles member roles_gained source user_id user_platform_roles)

  defp add!(schema, group_id, user_id) do
    assert {:ok, %{created: true}} =
             Identity.add_group_member(group_id, user_id, prefix: schema, audit_context: @ctx)
  end

  defp remove!(schema, group_id, user_id) do
    assert :ok =
             Identity.remove_group_member(group_id, user_id, prefix: schema, audit_context: @ctx)
  end

  defp the_entry(schema, action) do
    assert [entry] = RSG.entries(schema, action)
    entry
  end

  # ===========================================================================================
  describe "T-D1 .. T-D4 the delta on add and remove, in off, shadow and on" do
    for mode <- [:off, :shadow, :on] do
      @tag mode: mode
      test "#{mode}: add to a tenant-wide group is deny -> tenant_wide, remove is tenant_wide -> deny",
           %{mode: mode} do
        fx = tenant!("req519-d1#{mode}", mode)
        s = fx.schema_name
        g = S.platform_group!(s, "DELTA_ROLE_A", [:tenant_wide])
        user = user!(s)

        add!(s, g.id, user.id)
        added = the_entry(s, "group_member.added")

        assert added.after_state["scope_delta"] == [
                 %{"role" => "DELTA_ROLE_A", "from" => "deny", "to" => "tenant_wide"}
               ]

        remove!(s, g.id, user.id)
        removed = the_entry(s, "group_member.removed")

        assert removed.after_state["scope_delta"] == [
                 %{"role" => "DELTA_ROLE_A", "from" => "tenant_wide", "to" => "deny"}
               ]
      end

      @tag mode: mode
      test "#{mode}: add to a scoped group is deny -> {nodes, count} and remove is back to deny (T-D2, T-D3)",
           %{mode: mode} do
        fx = tenant!("req519-d2#{mode}", mode)
        s = fx.schema_name
        node = node!(s)
        g = S.platform_group!(s, "DELTA_ROLE_B", [{:node, node}])
        user = user!(s)

        add!(s, g.id, user.id)

        assert the_entry(s, "group_member.added").after_state["scope_delta"] == [
                 %{
                   "role" => "DELTA_ROLE_B",
                   "from" => "deny",
                   "to" => %{"nodes" => [node], "count" => 1}
                 }
               ]

        remove!(s, g.id, user.id)

        assert the_entry(s, "group_member.removed").after_state["scope_delta"] == [
                 %{
                   "role" => "DELTA_ROLE_B",
                   "from" => %{"nodes" => [node], "count" => 1},
                   "to" => "deny"
                 }
               ]
      end
    end

    test "the delta lists only the roles whose scope changed" do
      fx = tenant!("req519-d1x", :on)
      s = fx.schema_name
      a = S.platform_group!(s, "DELTA_ROLE_A", [:tenant_wide])
      b = S.platform_group!(s, "DELTA_ROLE_B", [{:node, node!(s)}])
      user = user!(s)

      add!(s, a.id, user.id)
      add!(s, b.id, user.id)

      [first, second] = RSG.entries(s, "group_member.added")
      assert [%{"role" => "DELTA_ROLE_A"}] = first.after_state["scope_delta"]
      assert [%{"role" => "DELTA_ROLE_B"}] = second.after_state["scope_delta"]
    end

    test "a group that grants nothing (no row) changes no scope: the delta is the empty list, the entry still carries it" do
      fx = tenant!("req519-d1y", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "DELTA_ROLE_A", [])
      user = user!(s)

      add!(s, g.id, user.id)
      assert the_entry(s, "group_member.added").after_state["scope_delta"] == []
    end

    test "an idempotent re-add writes no second entry" do
      fx = tenant!("req519-d1z", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "DELTA_ROLE_A", [:tenant_wide])
      user = user!(s)

      add!(s, g.id, user.id)

      assert {:ok, %{created: false}} =
               Identity.add_group_member(g.id, user.id, prefix: s, audit_context: @ctx)

      assert [_one] = RSG.entries(s, "group_member.added")
    end
  end

  # ===========================================================================================
  describe "T-D5 the pre-existing payload keys are unchanged (MU-19)" do
    test "added and removed keep every legacy key and gain exactly scope_delta" do
      fx = tenant!("req519-d5", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "DELTA_ROLE_A", [:tenant_wide])
      user = user!(s)

      add!(s, g.id, user.id)
      added = the_entry(s, "group_member.added")

      assert Map.keys(added.after_state) |> Enum.sort() ==
               Enum.sort(["scope_delta" | @legacy_keys])

      assert added.after_state["roles_gained"] == ["DELTA_ROLE_A"]

      assert added.after_state["group_roles"] == [
               %{"kind" => "platform_role", "name" => "DELTA_ROLE_A"}
             ]

      assert added.after_state["user_platform_roles"] == ["DELTA_ROLE_A"]
      assert added.after_state["member"] == true
      assert added.after_state["group_id"] == g.id
      assert added.after_state["source"] == "api"

      remove!(s, g.id, user.id)
      removed = the_entry(s, "group_member.removed")
      assert "roles_lost" in Map.keys(removed.after_state)
      assert "scope_delta" in Map.keys(removed.after_state)
      assert removed.after_state["roles_lost"] == ["DELTA_ROLE_A"]
      assert removed.after_state["user_platform_roles"] == []
    end

    test "the delta entry is written in the membership's transaction: a failing audit rolls the membership back" do
      fx = tenant!("req519-d5b", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "DELTA_ROLE_A", [:tenant_wide])
      user = user!(s)
      fault = S.create_audit_fault!(s, "req519_2eb_added", "NEW.action = 'group_member.added'")

      try do
        assert {:error, {:transaction_failed, _}} =
                 Identity.add_group_member(g.id, user.id, prefix: s, audit_context: @ctx)

        assert S.memberships(s, user.id) == []
      after
        S.drop_audit_fault!(s, fault)
      end
    end
  end

  # ===========================================================================================
  describe "T-D5 node ids: capped at 50 with a count, sorted, only this tenant's ids" do
    test "55 nodes: 50 sorted ids and count 55, on add and on remove; another tenant's ids never appear" do
      fx = tenant!("req519-d5c", :on)
      other = tenant!("req519-d5c2", :on)
      s = fx.schema_name
      nodes = for _ <- 1..55, do: node!(s)
      g = S.platform_group!(s, "DELTA_ROLE_A", Enum.map(nodes, &{:node, &1}))
      user = user!(s)

      # the other tenant: same role name, its own nodes and group, same shape
      other_nodes = for _ <- 1..3, do: node!(other.schema_name)

      _og =
        S.platform_group!(other.schema_name, "DELTA_ROLE_A", Enum.map(other_nodes, &{:node, &1}))

      add!(s, g.id, user.id)

      [%{"role" => "DELTA_ROLE_A", "from" => "deny", "to" => to}] =
        the_entry(s, "group_member.added").after_state["scope_delta"]

      sorted = Enum.sort(nodes)
      assert to["count"] == 55
      assert length(to["nodes"]) == 50
      assert to["nodes"] == Enum.take(sorted, 50)
      assert to["nodes"] == Enum.sort(to["nodes"])
      assert MapSet.subset?(MapSet.new(to["nodes"]), MapSet.new(nodes))
      assert MapSet.disjoint?(MapSet.new(to["nodes"]), MapSet.new(other_nodes))

      remove!(s, g.id, user.id)

      [%{"role" => "DELTA_ROLE_A", "to" => "deny", "from" => from}] =
        the_entry(s, "group_member.removed").after_state["scope_delta"]

      assert from == to
    end

    test "exactly 50 nodes are not truncated (boundary)" do
      fx = tenant!("req519-d5d", :on)
      s = fx.schema_name
      nodes = for _ <- 1..50, do: node!(s)
      g = S.platform_group!(s, "DELTA_ROLE_A", Enum.map(nodes, &{:node, &1}))
      user = user!(s)

      add!(s, g.id, user.id)

      assert [%{"to" => %{"nodes" => ids, "count" => 50}}] =
               the_entry(s, "group_member.added").after_state["scope_delta"]

      assert ids == Enum.sort(nodes)
    end
  end

  # ===========================================================================================
  describe "MembershipScope: the pure functions" do
    test "would_widen?/2 is true exactly when the result is tenant-wide and the start was not" do
      assert MembershipScope.would_widen?(:deny, :tenant_wide)
      assert MembershipScope.would_widen?({:nodes, ["n"]}, :tenant_wide)
      refute MembershipScope.would_widen?(:tenant_wide, :tenant_wide)
      refute MembershipScope.would_widen?(:deny, {:nodes, ["n"]})
      refute MembershipScope.would_widen?({:nodes, ["n"]}, {:nodes, ["n", "m"]})
      refute MembershipScope.would_widen?(:tenant_wide, :deny)
      refute MembershipScope.would_widen?(:tenant_wide, {:nodes, ["n"]})
      refute MembershipScope.would_widen?(:deny, :deny)
    end

    test "render/1 is a fixed string or a capped, sorted id map" do
      assert MembershipScope.render(:deny) == "deny"
      assert MembershipScope.render(:tenant_wide) == "tenant_wide"

      assert MembershipScope.render({:nodes, ["b", "a"]}) == %{
               "nodes" => ["a", "b"],
               "count" => 2
             }

      many = for i <- 1..60, do: "n#{String.pad_leading(Integer.to_string(i), 3, "0")}"
      rendered = MembershipScope.render({:nodes, Enum.reverse(many)})
      assert rendered["count"] == 60
      assert rendered["nodes"] == Enum.take(many, 50)
    end

    test "delta/2 lists only changed roles, sorted by name; an absent role reads as deny" do
      before_snapshot = %{"B" => :deny, "C" => :tenant_wide, "D" => {:nodes, ["n"]}}
      after_snapshot = %{"A" => :tenant_wide, "B" => :deny, "C" => :deny, "D" => {:nodes, ["n"]}}

      assert MembershipScope.delta(before_snapshot, after_snapshot) == [
               %{"role" => "A", "from" => "deny", "to" => "tenant_wide"},
               %{"role" => "C", "from" => "tenant_wide", "to" => "deny"}
             ]

      assert MembershipScope.delta(%{}, %{}) == []
    end
  end

  # ===========================================================================================
  describe "MembershipScope: the reads" do
    test "snapshot/2 covers the roles held THROUGH a group only; row_scopes/2 covers every row regardless of held-ness" do
      fx = tenant!("req519-d6", :on)
      s = fx.schema_name
      node = node!(s)
      g = S.platform_group!(s, "DELTA_ROLE_A", [{:node, node}])
      _other = S.platform_group!(s, "DELTA_ROLE_B", [:tenant_wide])
      user = RSG.member!(s, g.id, user!(s))
      :ok = raw_user_row!(s, user.id, "DELTA_ROLE_B", nil)

      assert MembershipScope.snapshot(user.id, s) == %{"DELTA_ROLE_A" => {:nodes, [node]}}

      assert MembershipScope.row_scopes(user.id, s) ==
               %{"DELTA_ROLE_A" => {:nodes, [node]}, "DELTA_ROLE_B" => :tenant_wide}
    end

    test "snapshot_if_added/4 adds the group's rows and the bound roles in memory and writes nothing" do
      fx = tenant!("req519-d6b", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "DELTA_ROLE_A", [:tenant_wide])
      user = user!(s)

      assert MembershipScope.snapshot_if_added(user.id, g.id, ["DELTA_ROLE_A"], s) ==
               %{"DELTA_ROLE_A" => :tenant_wide}

      assert S.memberships(s, user.id) == []
      assert MembershipScope.snapshot(user.id, s) == %{}
    end

    test "a snapshot of one tenant never reads another tenant's rows" do
      fx = tenant!("req519-d6c", :on)
      other = tenant!("req519-d6c2", :on)
      g = S.platform_group!(fx.schema_name, "DELTA_ROLE_A", [:tenant_wide])
      user = RSG.member!(fx.schema_name, g.id, user!(fx.schema_name))

      assert MembershipScope.snapshot(user.id, fx.schema_name) == %{
               "DELTA_ROLE_A" => :tenant_wide
             }

      assert MembershipScope.snapshot(user.id, other.schema_name) == %{}
    end
  end
end
