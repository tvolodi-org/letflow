defmodule Letflow.Identity.SyncScopeGuardTest do
  @moduledoc """
  REQ-519 slice 2e-b (GH #2535), ACs 2 and 3 (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 3.9, 3.9a and 8.2, tests
  T-S1..T-S17; SEC code gate step-11 merge conditions; REVIEWER step-12 notes F-3b and TS-1;
  spec `test/specs/REQ-519-2e-b.md`): in a tenant whose scope enforcement is `on` the IdP
  role-claims sync (`Identity.sync_role_claims_report/3`, and `sync_role_claims_from_token/3`
  on top of it) never makes a user tenant-wide for a role the user was not tenant-wide for.

  Groups are built RAW (`Letflow.Support.SyncScopeFixture`): in an `on` tenant no writer can
  create a tenant-wide binding any more, so the tenant-wide group of the scenarios is a raw
  binding plus a raw tenant-wide row. Every scenario is a real committed sync against a real
  tenant schema; the audit entries are read back from the table.

  Cases: `grant.sync_suppressed` (the user already holds a scoped row for the role),
  `binding.pending_scope` (none), a user whose only row is a tenant-wide USER row for an unheld
  role (REVIEWER F-3b: still suppressed, `binding.pending_scope`), the TENANT_ADMIN group, a
  multi-role group (withheld whole, audit lists only the widening roles), routing-role bindings
  ignored, exact audit key sets, permanent dedup from the table, marker stamping, a rolled-back
  sync (audit failure, raised mode read), the typed result and the `User.t()` wrapper, the
  C-3 ordering with a REAL held lock A, and the `docs/roles.md` sentence.

  `async: false`: real tenant schemas, committed DDL and writes, VM-global application env.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  import Letflow.Support.EnforcedWritersFixture,
    only: [tenant!: 2, seeded_tenant!: 2, set_mode!: 2]

  import Letflow.Support.RoleScopeGrantsFixture, only: [user!: 1, node!: 1, raw_user_row!: 4]

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.Principal
  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.MembershipScope
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.SyncScopeGuard
  alias Letflow.Identity.User
  alias Letflow.LockOrderHelpers, as: Locks
  alias Letflow.PlatformTenant
  alias Letflow.Support.EnforcedWritersFixture, as: EW
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.SyncScopeFixture, as: S

  @action_scoped "grant.sync_suppressed"
  @action_pending "binding.pending_scope"
  @keys ~w(group role trace_id user)

  defp entries(schema, action), do: RSG.entries(schema, action)

  defp suppression_entries(schema),
    do: entries(schema, @action_scoped) ++ entries(schema, @action_pending)

  defp principal(fx, user_id) do
    platform? = PlatformTenant.platform_tenant?(fx.tenant_id)

    %Principal{
      kind: :user,
      user_id: user_id,
      prefix: fx.schema_name,
      platform_tenant?: platform?,
      roles:
        Authorization.effective_roles(
          Identity.list_effective_role_names(user_id, prefix: fx.schema_name),
          platform?
        ),
      grants: Scope.load_grants(user_id, fx.schema_name)
    }
  end

  # ===========================================================================================
  describe "T-S1 grant.sync_suppressed: a user who holds scoped rows, synced into a tenant-wide group" do
    test "no membership, login succeeds, ONE entry in the sync's transaction with exactly user/group/role/trace_id, scope unchanged" do
      fx = tenant!("req519-s1", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)
      node = node!(s)
      :ok = raw_user_row!(s, user.id, "SYNC_ROLE_A", node)
      rows_before = RoleScopeGrants.applicable_rows_for_user(user.id, s)
      assert rows_before != []

      assert {:suppressed, synced, summary} = S.sync(s, user, ["SYNC_ROLE_A"])

      # login succeeds: a user comes back, the marker is stamped (T-S11)
      assert %User{id: id} = synced
      assert id == user.id
      assert %DateTime{} = synced.role_claims_synced_at

      assert summary == %{
               suppressed: [%{group_id: g.id, role: "SYNC_ROLE_A", kind: :has_scoped_rows}],
               deduped: 0
             }

      assert S.memberships(s, user.id) == []
      assert entries(s, @action_pending) == []
      assert entries(s, "group_member.added") == []
      assert [entry] = entries(s, @action_scoped)

      assert S.after_keys(entry) == @keys

      assert entry.after_state == %{
               "user" => user.id,
               "group" => g.id,
               "role" => "SYNC_ROLE_A",
               "trace_id" => S.trace()
             }

      assert entry.before_state == nil
      assert entry.resource_type == "user_role"
      assert entry.resource_id == "#{user.id}:SYNC_ROLE_A"
      assert entry.actor_id == user.id
      assert entry.trace_id == S.trace()

      # the effective scope is unchanged: same rows, still no role held, same row scope
      assert RoleScopeGrants.applicable_rows_for_user(user.id, s) == rows_before
      assert Identity.list_effective_role_names(user.id, prefix: s) == []
      assert MembershipScope.snapshot(user.id, s) == %{}
      assert MembershipScope.row_scopes(user.id, s) == %{"SYNC_ROLE_A" => {:nodes, [node]}}
    end

    test "the entry is written in the sync's transaction: a later failure of the same sync leaves no suppression entry" do
      fx = tenant!("req519-s1b", :on)
      s = fx.schema_name
      _g1 = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      _g2 = S.platform_group!(s, "SYNC_ROLE_B", [:tenant_wide])
      user = user!(s)
      ids = EW.entry_ids(s)

      # raises on the SECOND pending_scope entry, i.e. after the first one was written
      fault =
        S.create_audit_fault!(
          s,
          "req519_2eb_second",
          ~s|NEW.action = 'binding.pending_scope' AND EXISTS (SELECT 1 FROM "#{s}".audit_entries a | <>
            ~s|WHERE a.action = 'binding.pending_scope')|
        )

      try do
        {result, _log} =
          with_log(fn -> S.sync(s, user, ["SYNC_ROLE_A", "SYNC_ROLE_B"]) end)

        assert {:failed, ^user, _step} = result
        assert EW.new_entries(s, ids) == []
        assert S.marker(s, user.id) == nil
      after
        S.drop_audit_fault!(s, fault)
      end

      # control: with the fault gone both pairs are recorded in one go
      assert {:suppressed, _user, %{suppressed: [_, _], deduped: 0}} =
               S.sync(s, user, ["SYNC_ROLE_A", "SYNC_ROLE_B"])

      assert length(entries(s, @action_pending)) == 2
    end

    test "the existing export returns the same user shape and the same effect (T-S13 link)" do
      fx = tenant!("req519-s1c", :on)
      s = fx.schema_name
      _g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)
      :ok = raw_user_row!(s, user.id, "SYNC_ROLE_A", node!(s))

      synced =
        Identity.sync_role_claims_from_token(user, S.claims(["SYNC_ROLE_A"]),
          prefix: s,
          audit_context: %{trace_id: S.trace()}
        )

      assert %User{} = synced
      assert synced.id == user.id
      assert %DateTime{} = synced.role_claims_synced_at
      assert S.memberships(s, user.id) == []
      assert [_one] = entries(s, @action_scoped)
    end
  end

  # ===========================================================================================
  describe "T-S2 off and shadow: the legacy membership is added (AC 2)" do
    for mode <- [:off, :shadow] do
      @tag mode: mode
      test "#{mode}: the same sync adds the membership, writes no suppression entry and returns {:ok, user}",
           %{mode: mode} do
        fx = tenant!("req519-s2#{mode}", mode)
        s = fx.schema_name
        g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
        user = user!(s)
        :ok = raw_user_row!(s, user.id, "SYNC_ROLE_A", node!(s))

        assert {:ok, synced} = S.sync(s, user, ["SYNC_ROLE_A"])
        assert %DateTime{} = synced.role_claims_synced_at
        assert S.memberships(s, user.id) == [g.id]
        assert suppression_entries(s) == []

        # the membership audit still carries the legacy keys (and the new scope_delta)
        assert [added] = entries(s, "group_member.added")
        assert added.after_state["source"] == "idp_sync"
        assert added.after_state["roles_gained"] == ["SYNC_ROLE_A"]

        assert added.after_state["scope_delta"] == [
                 %{"role" => "SYNC_ROLE_A", "from" => "deny", "to" => "tenant_wide"}
               ]
      end
    end

    test "a stored mode of shadow/off is read per call: flipping the same tenant to on changes the outcome" do
      fx = tenant!("req519-s2flip", :shadow)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      first = user!(s)
      second = user!(s)

      assert {:ok, _} = S.sync(s, first, ["SYNC_ROLE_A"])
      assert S.memberships(s, first.id) == [g.id]

      set_mode!(fx, :on)
      assert {:suppressed, _, _} = S.sync(s, second, ["SYNC_ROLE_A"])
      assert S.memberships(s, second.id) == []
    end
  end

  # ===========================================================================================
  describe "T-S3 a group binding two roles is withheld WHOLE; the audit lists only the widening roles (F4)" do
    test "the claimed role is scoped, the unclaimed role of the same group is tenant-wide: suppressed (MU-12)" do
      fx = tenant!("req519-s3", :on)
      s = fx.schema_name
      node = node!(s)
      g = S.platform_group!(s, "SYNC_ROLE_P", [{:node, node}])
      S.bind_platform!(s, g, "SYNC_ROLE_Q", [:tenant_wide])
      user = user!(s)

      assert {:suppressed, _synced, summary} = S.sync(s, user, ["SYNC_ROLE_P"])

      assert summary == %{
               suppressed: [%{group_id: g.id, role: "SYNC_ROLE_Q", kind: :no_scoped_rows}],
               deduped: 0
             }

      # whole group withheld: the user holds NEITHER role of the group
      assert S.memberships(s, user.id) == []
      assert Identity.list_effective_role_names(user.id, prefix: s) == []

      # the audit lists only the widening role, not the claimed scoped one
      assert [entry] = entries(s, @action_pending)
      assert entry.resource_id == "#{user.id}:SYNC_ROLE_Q"
      assert entry.after_state["role"] == "SYNC_ROLE_Q"
      assert entries(s, @action_scoped) == []
      assert entries(s, "group_member.added") == []
    end

    test "every widening role is listed, sorted by name, each with its own kind and entry" do
      fx = tenant!("req519-s3b", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_P", [:tenant_wide])
      S.bind_platform!(s, g, "SYNC_ROLE_Q", [:tenant_wide])
      user = user!(s)
      :ok = raw_user_row!(s, user.id, "SYNC_ROLE_Q", node!(s))

      assert {:suppressed, _synced, %{suppressed: items, deduped: 0}} =
               S.sync(s, user, ["SYNC_ROLE_Q"])

      assert items == [
               %{group_id: g.id, role: "SYNC_ROLE_P", kind: :no_scoped_rows},
               %{group_id: g.id, role: "SYNC_ROLE_Q", kind: :has_scoped_rows}
             ]

      assert [pending] = entries(s, @action_pending)
      assert pending.resource_id == "#{user.id}:SYNC_ROLE_P"
      assert [scoped] = entries(s, @action_scoped)
      assert scoped.resource_id == "#{user.id}:SYNC_ROLE_Q"
      assert S.memberships(s, user.id) == []
    end
  end

  # ===========================================================================================
  describe "T-S4 a group whose rows are scoped (or absent) is NOT suppressed" do
    test "a scoped group is joined, the user holds exactly that scope, nothing is recorded (MU-13)" do
      fx = tenant!("req519-s4", :on)
      s = fx.schema_name
      node = node!(s)
      g = S.platform_group!(s, "SYNC_ROLE_B", [{:node, node}])
      user = user!(s)

      assert {:ok, synced} = S.sync(s, user, ["SYNC_ROLE_B"])
      assert %DateTime{} = synced.role_claims_synced_at
      assert S.memberships(s, user.id) == [g.id]
      assert suppression_entries(s) == []
      assert MembershipScope.snapshot(user.id, s) == %{"SYNC_ROLE_B" => {:nodes, [node]}}

      assert [added] = entries(s, "group_member.added")

      assert added.after_state["scope_delta"] == [
               %{
                 "role" => "SYNC_ROLE_B",
                 "from" => "deny",
                 "to" => %{"nodes" => [node], "count" => 1}
               }
             ]
    end

    test "a user who already holds a scoped row for the role joins a scoped group too" do
      fx = tenant!("req519-s4b", :on)
      s = fx.schema_name
      group_node = node!(s)
      user_node = node!(s)
      g = S.platform_group!(s, "SYNC_ROLE_B", [{:node, group_node}])
      user = user!(s)
      :ok = raw_user_row!(s, user.id, "SYNC_ROLE_B", user_node)

      assert {:ok, _synced} = S.sync(s, user, ["SYNC_ROLE_B"])
      assert S.memberships(s, user.id) == [g.id]
      assert suppression_entries(s) == []

      assert MembershipScope.snapshot(user.id, s) ==
               %{"SYNC_ROLE_B" => {:nodes, Enum.sort([group_node, user_node])}}
    end

    test "a group bound with NO row for the role grants nothing, so it is joined (a membership alone widens nothing)" do
      fx = tenant!("req519-s4c", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_B", [])
      user = user!(s)

      assert {:ok, _synced} = S.sync(s, user, ["SYNC_ROLE_B"])
      assert S.memberships(s, user.id) == [g.id]
      assert suppression_entries(s) == []
      assert MembershipScope.snapshot(user.id, s) == %{"SYNC_ROLE_B" => :deny}
    end
  end

  # ===========================================================================================
  describe "T-S5 a user who is already in the tenant-wide group is not suppressed" do
    test "the re-sync is a no-op for the membership, writes no entry and returns {:ok, user} (MU-14)" do
      fx = tenant!("req519-s5", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = RSG.member!(s, g.id, user!(s))

      assert MembershipScope.snapshot(user.id, s) == %{"SYNC_ROLE_A" => :tenant_wide}

      assert {:ok, synced} = S.sync(s, user, ["SYNC_ROLE_A"])
      assert %DateTime{} = synced.role_claims_synced_at
      assert S.memberships(s, user.id) == [g.id]
      assert suppression_entries(s) == []
      assert entries(s, "group_member.added") == []
    end

    test "a user already tenant-wide for another role of the claimed scoped group is unaffected" do
      fx = tenant!("req519-s5b", :on)
      s = fx.schema_name
      tw = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      sc = S.platform_group!(s, "SYNC_ROLE_B", [{:node, node!(s)}])
      user = RSG.member!(s, tw.id, user!(s))

      assert {:ok, _synced} = S.sync(s, user, ["SYNC_ROLE_A", "SYNC_ROLE_B"])
      assert S.memberships(s, user.id) == Enum.sort([tw.id, sc.id])
      assert suppression_entries(s) == []
    end
  end

  # ===========================================================================================
  describe "T-S6 binding.pending_scope: a user with NO rows for the role (AC 3, N3)" do
    test "no membership; ONE entry whose key set is EXACTLY user/group/role/trace_id and holds no claim value (MU-15)" do
      fx = tenant!("req519-s6", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)
      ctx = S.claims(["SYNC_ROLE_A"])

      assert {:suppressed, synced, summary} =
               Identity.sync_role_claims_report(user, ctx,
                 prefix: s,
                 audit_context: %{trace_id: S.trace()}
               )

      assert %DateTime{} = synced.role_claims_synced_at

      assert summary == %{
               suppressed: [%{group_id: g.id, role: "SYNC_ROLE_A", kind: :no_scoped_rows}],
               deduped: 0
             }

      assert S.memberships(s, user.id) == []
      assert entries(s, @action_scoped) == []
      assert [entry] = entries(s, @action_pending)

      assert S.after_keys(entry) == @keys

      assert entry.after_state == %{
               "user" => user.id,
               "group" => g.id,
               "role" => "SYNC_ROLE_A",
               "trace_id" => S.trace()
             }

      assert entry.before_state == nil
      assert entry.resource_type == "user_role"
      assert entry.resource_id == "#{user.id}:SYNC_ROLE_A"
      assert entry.actor_id == user.id

      # no IdP claim value, e-mail or group name anywhere in the entry
      dump = Jason.encode!(%{after: entry.after_state, before: entry.before_state})

      for claim <- [
            ctx.external_user_id,
            ctx.email,
            ctx.preferred_username,
            ctx.display_name,
            S.realm()
          ] do
        refute dump =~ claim
      end

      refute dump =~ g.name
    end

    test "F-3b: a user whose ONLY row is a tenant-wide USER-principal row for the unheld role is :no_scoped_rows and STILL suppressed" do
      fx = tenant!("req519-s6b", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)
      :ok = raw_user_row!(s, user.id, "SYNC_ROLE_A", nil)

      # the role is not held, so the row confers nothing until the membership exists
      assert Identity.list_effective_role_names(user.id, prefix: s) == []
      assert MembershipScope.row_scopes(user.id, s) == %{"SYNC_ROLE_A" => :tenant_wide}

      assert {:suppressed, _synced, summary} = S.sync(s, user, ["SYNC_ROLE_A"])

      assert summary == %{
               suppressed: [%{group_id: g.id, role: "SYNC_ROLE_A", kind: :no_scoped_rows}],
               deduped: 0
             }

      assert S.memberships(s, user.id) == []
      assert entries(s, @action_scoped) == []
      assert [_pending] = entries(s, @action_pending)
    end

    test "the TENANT_ADMIN group is withheld: a claimed TENANT_ADMIN cannot make a user a tenant admin in an on tenant" do
      fx = seeded_tenant!("req519-s6c", :on)
      s = fx.schema_name
      ta_group = RSG.group_of!(s, "TENANT_ADMIN")
      user = user!(s)

      assert {:suppressed, synced, summary} = S.sync(s, user, ["TENANT_ADMIN"])
      assert %DateTime{} = synced.role_claims_synced_at

      assert summary == %{
               suppressed: [%{group_id: ta_group, role: "TENANT_ADMIN", kind: :no_scoped_rows}],
               deduped: 0
             }

      assert S.memberships(s, user.id) == []
      assert Identity.list_effective_role_names(user.id, prefix: s) == []
      assert [entry] = entries(s, @action_pending)
      assert entry.after_state["role"] == "TENANT_ADMIN"
      assert entry.after_state["group"] == ta_group
    end

    test "the same TENANT_ADMIN claim in shadow adds the membership (control: the withholding is the on behaviour)" do
      fx = seeded_tenant!("req519-s6d", :shadow)
      s = fx.schema_name
      ta_group = RSG.group_of!(s, "TENANT_ADMIN")
      user = user!(s)

      assert {:ok, _synced} = S.sync(s, user, ["TENANT_ADMIN"])
      assert S.memberships(s, user.id) == [ta_group]
      assert suppression_entries(s) == []
    end

    test "no new log line and no claim value in the captured log of a suppressed sync (INV-4, A-6)" do
      fx = tenant!("req519-s6e", :on)
      s = fx.schema_name
      _g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)
      ctx = S.claims(["SYNC_ROLE_A"])

      log =
        capture_log(fn ->
          assert {:suppressed, _, _} =
                   Identity.sync_role_claims_report(user, ctx,
                     prefix: s,
                     audit_context: %{trace_id: S.trace()}
                   )
        end)

      for claim <- [
            ctx.external_user_id,
            ctx.email,
            ctx.preferred_username,
            ctx.display_name,
            S.realm()
          ] do
        refute log =~ claim
      end

      own = log |> String.split("\n") |> Enum.filter(&(&1 =~ "sync_role_claims"))
      assert own == []
    end
  end

  # ===========================================================================================
  describe "T-S7 a suppressed user does not hold the role" do
    test "list_effective_role_names omits it, the coarse check is 403, allowed?/3 is {:deny, :role_not_held}" do
      fx = tenant!("req519-s7", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "PROCESS_DESIGNER", [:tenant_wide])
      user = user!(s)

      assert {:suppressed, _synced, _summary} = S.sync(s, user, ["PROCESS_DESIGNER"])

      assert Identity.list_effective_role_names(user.id, prefix: s) == []
      p = principal(fx, user.id)
      refute :PROCESS_DESIGNER in p.roles
      refute Authorization.has_permission?(p.roles, :EntitiesDefinitionsWrite)
      assert Scope.allowed?(p, :EntitiesDefinitionsWrite, :tenant_wide) == {:deny, :role_not_held}

      # control: once an admin adds the user to the group, the same check allows
      assert {:ok, _} = Identity.add_group_member(g.id, user.id, prefix: s)
      held = principal(fx, user.id)
      assert :PROCESS_DESIGNER in held.roles
      assert Authorization.has_permission?(held.roles, :EntitiesDefinitionsWrite)
      assert {:allow, _} = Scope.allowed?(held, :EntitiesDefinitionsWrite, :tenant_wide)
    end
  end

  # ===========================================================================================
  describe "T-S8 / T-S9 one event per (user, role, action), derived from stored data (AC 3)" do
    test "T-S8 three syncs yield one entry (deduped counted); a second role yields a second entry; another user its own (MU-16)" do
      fx = tenant!("req519-s8", :on)
      s = fx.schema_name
      ga = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      gb = S.platform_group!(s, "SYNC_ROLE_B", [:tenant_wide])
      user = user!(s)
      other = user!(s)

      assert {:suppressed, _, %{deduped: 0, suppressed: [%{group_id: ga_id}]}} =
               S.sync(s, user, ["SYNC_ROLE_A"])

      assert ga_id == ga.id

      assert {:suppressed, _, %{deduped: 1, suppressed: [_]}} = S.sync(s, user, ["SYNC_ROLE_A"])
      assert {:suppressed, _, %{deduped: 1, suppressed: [_]}} = S.sync(s, user, ["SYNC_ROLE_A"])
      assert [_only] = entries(s, @action_pending)
      assert S.memberships(s, user.id) == []

      # a second role is a second event; the first stays deduped
      assert {:suppressed, _, %{deduped: 1, suppressed: [a, b]}} =
               S.sync(s, user, ["SYNC_ROLE_A", "SYNC_ROLE_B"])

      assert Enum.sort([a.role, b.role]) == ["SYNC_ROLE_A", "SYNC_ROLE_B"]
      assert b.group_id in [ga.id, gb.id]
      assert length(entries(s, @action_pending)) == 2

      ids = entries(s, @action_pending) |> Enum.map(& &1.resource_id) |> Enum.sort()
      assert ids == Enum.sort(["#{user.id}:SYNC_ROLE_A", "#{user.id}:SYNC_ROLE_B"])

      # another user is a different (user, role): its own event
      assert {:suppressed, _, %{deduped: 0}} = S.sync(s, other, ["SYNC_ROLE_A"])
      assert length(entries(s, @action_pending)) == 3
    end

    test "T-S9 the dedup is the table, not memory: an entry written before (any process, any time) suppresses the write" do
      fx = tenant!("req519-s9", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)

      # an entry exactly as an earlier sync (before a restart) would have left it
      attrs = %{
        actor_id: user.id,
        action: @action_pending,
        resource_type: "user_role",
        resource_id: "#{user.id}:SYNC_ROLE_A",
        before_state: nil,
        after_state: %{
          "user" => user.id,
          "group" => g.id,
          "role" => "SYNC_ROLE_A",
          "trace_id" => "before-the-restart"
        },
        trace_id: "before-the-restart"
      }

      assert {:ok, _entry} = Audit.insert_entry(Repo, attrs, s)

      # a brand-new process with an empty process dictionary
      result = Task.async(fn -> S.sync(s, user, ["SYNC_ROLE_A"]) end) |> Task.await(15_000)

      assert {:suppressed, _synced, %{deduped: 1, suppressed: [_]}} = result
      assert [only] = entries(s, @action_pending)
      assert only.trace_id == "before-the-restart"
      # dedup never admits the membership
      assert S.memberships(s, user.id) == []
    end

    test "T-S9 the guard keeps no state of its own: no Agent, ETS, persistent_term, process dictionary or GenServer in its source" do
      source = File.read!("lib/letflow/identity/sync_scope_guard.ex")

      for forbidden <- [
            "Agent.",
            ":ets.",
            ":persistent_term",
            "Process.put",
            "GenServer",
            "Application.put_env"
          ] do
        refute source =~ forbidden, "SyncScopeGuard must not use #{forbidden}"
      end
    end

    test "the dedup is per action: a user who first had no rows and later holds a scoped row gets the other action once" do
      fx = tenant!("req519-s9b", :on)
      s = fx.schema_name
      _g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)

      assert {:suppressed, _, %{suppressed: [%{kind: :no_scoped_rows}]}} =
               S.sync(s, user, ["SYNC_ROLE_A"])

      :ok = raw_user_row!(s, user.id, "SYNC_ROLE_A", node!(s))

      assert {:suppressed, _, %{suppressed: [%{kind: :has_scoped_rows}], deduped: 0}} =
               S.sync(s, user, ["SYNC_ROLE_A"])

      assert {:suppressed, _, %{suppressed: [%{kind: :has_scoped_rows}], deduped: 1}} =
               S.sync(s, user, ["SYNC_ROLE_A"])

      assert [_] = entries(s, @action_pending)
      assert [_] = entries(s, @action_scoped)
    end

    test "dedup is tenant-scoped: another tenant's entry for the same ids and role does not suppress" do
      fx_a = tenant!("req519-s9c1", :on)
      fx_b = tenant!("req519-s9c2", :on)
      for fx <- [fx_a, fx_b], do: S.platform_group!(fx.schema_name, "SYNC_ROLE_A", [:tenant_wide])
      user_a = user!(fx_a.schema_name)

      # tenant B already holds an entry with EXACTLY the resource id tenant A's sync would write
      assert {:ok, _entry} =
               Audit.insert_entry(
                 Repo,
                 %{
                   actor_id: user_a.id,
                   action: @action_pending,
                   resource_type: "user_role",
                   resource_id: "#{user_a.id}:SYNC_ROLE_A",
                   before_state: nil,
                   after_state: %{"foreign" => "tenant-b"},
                   trace_id: "req519-s9c-foreign"
                 },
                 fx_b.schema_name
               )

      assert {:suppressed, _, %{deduped: 0}} = S.sync(fx_a.schema_name, user_a, ["SYNC_ROLE_A"])
      assert [entry_a] = entries(fx_a.schema_name, @action_pending)
      assert entry_a.trace_id == S.trace()
      assert [foreign] = entries(fx_b.schema_name, @action_pending)
      assert foreign.trace_id == "req519-s9c-foreign"
    end
  end

  # ===========================================================================================
  describe "T-S10 remedy: an admin adds the user to a group whose rows for the role are scoped (AC 3)" do
    test "after the admin act the user holds exactly that scope; a later sync is then a no-op" do
      fx = tenant!("req519-s10", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)

      assert {:suppressed, _, _} = S.sync(s, user, ["SYNC_ROLE_A"])
      assert MembershipScope.snapshot(user.id, s) == %{}

      # the admin's remedy: the group's rows for the role become scoped, then the user is added
      node = RSG.make_group_scoped_only!(s, g.id, "SYNC_ROLE_A")

      assert {:ok, %{created: true}} =
               Identity.add_group_member(g.id, user.id,
                 prefix: s,
                 audit_context: %{actor_id: nil, trace_id: "req519-s10-admin", source: "api"}
               )

      assert MembershipScope.snapshot(user.id, s) == %{"SYNC_ROLE_A" => {:nodes, [node]}}

      assert [added] = entries(s, "group_member.added")

      assert added.after_state["scope_delta"] == [
               %{
                 "role" => "SYNC_ROLE_A",
                 "from" => "deny",
                 "to" => %{"nodes" => [node], "count" => 1}
               }
             ]

      # the user is a member now: the next sync neither suppresses nor adds again
      assert {:ok, _} = S.sync(s, user, ["SYNC_ROLE_A"])
      assert length(entries(s, "group_member.added")) == 1
    end
  end

  # ===========================================================================================
  describe "T-S11 the marker (F5)" do
    test "stamped when every candidate was suppressed (MU-17); persisted; the next login need not rerun" do
      fx = tenant!("req519-s11", :on)
      s = fx.schema_name
      _g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)
      assert S.marker(s, user.id) == nil

      assert {:suppressed, synced, _} = S.sync(s, user, ["SYNC_ROLE_A"])
      assert %DateTime{} = synced.role_claims_synced_at
      assert %DateTime{} = S.marker(s, user.id)
    end

    test "stamped when at least one membership is written alongside a suppressed one" do
      fx = tenant!("req519-s11b", :on)
      s = fx.schema_name
      scoped = S.platform_group!(s, "SYNC_ROLE_B", [{:node, node!(s)}])
      _tw = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)

      assert {:suppressed, synced, %{suppressed: [%{role: "SYNC_ROLE_A"}]}} =
               S.sync(s, user, ["SYNC_ROLE_A", "SYNC_ROLE_B"])

      assert %DateTime{} = synced.role_claims_synced_at
      assert S.memberships(s, user.id) == [scoped.id]
      assert [_one] = entries(s, @action_pending)
      assert [_one] = entries(s, "group_member.added")
    end

    test "with no candidate at all (nothing claimed resolves) the marker stays nil, {:ok, user}, nothing read or written" do
      fx = tenant!("req519-s11c", :on)
      s = fx.schema_name
      user = user!(s)
      ids = EW.entry_ids(s)

      {result, _log} = with_log(fn -> S.sync(s, user, ["NO_SUCH_ROLE"]) end)

      assert result == {:ok, user}
      assert S.marker(s, user.id) == nil
      assert EW.new_entries(s, ids) == []
    end
  end

  # ===========================================================================================
  describe "T-S12 a failed sync is rolled back whole and returns the original user" do
    test "an audit failure on the suppression entry: no membership of the same call, no entry, marker nil; the retry works" do
      fx = tenant!("req519-s12", :on)
      s = fx.schema_name
      scoped = S.platform_group!(s, "SYNC_ROLE_B", [{:node, node!(s)}])
      _tw = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)
      ids = EW.entry_ids(s)

      fault =
        S.create_audit_fault!(s, "req519_2eb_pending", "NEW.action = 'binding.pending_scope'")

      try do
        {result, log} =
          with_log(fn -> S.sync(s, user, ["SYNC_ROLE_A", "SYNC_ROLE_B"]) end)

        # TS-1 (REVIEWER): a swallowed failure is its own variant, carrying the original user and
        # the step that failed; it is never {:ok, _}, which means "applied"
        assert {:failed, ^user, step} = result
        assert step in [:memberships, :raised]
        assert S.memberships(s, user.id) == []
        assert S.marker(s, user.id) == nil
        assert EW.new_entries(s, ids) == []

        own = log |> String.split("\n") |> Enum.filter(&(&1 =~ "sync_role_claims_from_token/3"))
        assert own != []
        refute log =~ "injected fault"
      after
        S.drop_audit_fault!(s, fault)
      end

      assert {:suppressed, synced, _} = S.sync(s, user, ["SYNC_ROLE_A", "SYNC_ROLE_B"])
      assert %DateTime{} = synced.role_claims_synced_at
      assert S.memberships(s, user.id) == [scoped.id]
      assert [_] = entries(s, @action_pending)
    end

    test "a mode read that raises: original user, no membership, no entry, marker nil, never proceeds as off (SEC C-2)" do
      fx = tenant!("req519-s12b", :on)
      s = fx.schema_name
      _g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)
      ids = EW.entry_ids(s)

      {result, log} =
        with_log(fn ->
          S.with_lenient_key(:unset, fn ->
            S.with_unregistered_schema(s, fn renamed -> S.sync(renamed, user, ["SYNC_ROLE_A"]) end)
          end)
        end)

      assert {:failed, ^user, :raised} = result
      assert S.memberships(s, user.id) == []
      assert S.marker(s, user.id) == nil
      assert EW.new_entries(s, ids) == []

      own = log |> String.split("\n") |> Enum.filter(&(&1 =~ "sync_role_claims_from_token/3"))
      assert Enum.any?(own, &(&1 =~ "ModeUnavailableError"))
    end

    test "a sync with no candidate group never reads the mode: an unreadable mode does not matter" do
      fx = tenant!("req519-s12c", :on)
      s = fx.schema_name
      user = user!(s)

      {result, log} =
        with_log(fn ->
          S.with_lenient_key(:unset, fn ->
            S.with_unregistered_schema(s, fn renamed ->
              S.sync(renamed, user, ["NO_SUCH_ROLE"])
            end)
          end)
        end)

      assert result == {:ok, user}
      # no candidate: no lock, no mode read, so not even the failure fallback was entered
      refute log =~ "ModeUnavailableError"
      refute log =~ "transaction raised"
    end
  end

  # ===========================================================================================
  describe "T-S13 / T-S14 the typed result and the User.t() wrapper (3.9a)" do
    test "T-S13 sync_role_claims_from_token/3 returns a User in every mode and every outcome; its spec still says User.t() (MU-45)" do
      for mode <- [:off, :shadow, :on] do
        fx = tenant!("req519-s13#{mode}", mode)
        s = fx.schema_name
        _tw = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
        _sc = S.platform_group!(s, "SYNC_ROLE_B", [{:node, node!(s)}])

        for roles <- [["SYNC_ROLE_A"], ["SYNC_ROLE_B"], ["NO_SUCH_ROLE"]] do
          user = user!(s)

          result =
            Identity.sync_role_claims_from_token(user, S.claims(roles),
              prefix: s,
              audit_context: %{trace_id: S.trace()}
            )

          assert %User{} = result, "#{mode} #{inspect(roles)}: #{inspect(result)}"
          assert result.id == user.id
        end
      end

      {:ok, specs} = Code.Typespec.fetch_specs(Identity)

      {_key, [spec | _]} =
        Enum.find(specs, fn {{name, arity}, _} ->
          {name, arity} == {:sync_role_claims_from_token, 3}
        end)

      rendered =
        :sync_role_claims_from_token |> Code.Typespec.spec_to_quoted(spec) |> Macro.to_string()

      assert rendered =~ "User.t()"
      refute rendered =~ ":suppressed"
    end

    test "T-S18 (GH 2858) the typed report's spec names exactly the applied, suppressed and failed outcomes" do
      {:ok, specs} = Code.Typespec.fetch_specs(Identity)

      {_key, [spec | _]} =
        Enum.find(specs, fn {{name, arity}, _} ->
          {name, arity} == {:sync_role_claims_report, 3}
        end)

      rendered =
        :sync_role_claims_report |> Code.Typespec.spec_to_quoted(spec) |> Macro.to_string()

      assert rendered =~ "{:ok, Letflow.Identity.User.t()}"
      assert rendered =~ "{:suppressed, Letflow.Identity.User.t(), suppressed_summary()}"
      assert rendered =~ "{:failed, Letflow.Identity.User.t(), failed_step()}"
    end

    test "T-S14 the typed report is {:suppressed, ...} exactly for the suppressed cases and {:ok, _} otherwise (MU-46)" do
      fx = tenant!("req519-s14", :on)
      s = fx.schema_name
      tw = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      sc = S.platform_group!(s, "SYNC_ROLE_B", [{:node, node!(s)}])

      # nothing suppressed: scoped group, unresolvable claim, already a member
      assert {:ok, %User{}} = S.sync(s, user!(s), ["SYNC_ROLE_B"])
      assert {:ok, %User{}} = S.sync(s, user!(s), ["NO_SUCH_ROLE"])
      member = RSG.member!(s, tw.id, user!(s))
      assert {:ok, %User{}} = S.sync(s, member, ["SYNC_ROLE_A"])

      # suppressed: the tenant-wide group, with and without other memberships written
      assert {:suppressed, %User{}, only} = S.sync(s, user!(s), ["SYNC_ROLE_A"])
      assert only.suppressed == [%{group_id: tw.id, role: "SYNC_ROLE_A", kind: :no_scoped_rows}]

      mixed_user = user!(s)

      assert {:suppressed, %User{} = synced, mixed} =
               S.sync(s, mixed_user, ["SYNC_ROLE_B", "SYNC_ROLE_A"])

      assert mixed.suppressed == [%{group_id: tw.id, role: "SYNC_ROLE_A", kind: :no_scoped_rows}]
      assert S.memberships(s, mixed_user.id) == [sc.id]
      assert %DateTime{} = synced.role_claims_synced_at

      # the summary holds ids and the fixed kind only
      assert Map.keys(mixed) |> Enum.sort() == [:deduped, :suppressed]

      for item <- mixed.suppressed do
        assert Map.keys(item) |> Enum.sort() == [:group_id, :kind, :role]
        assert item.kind in [:has_scoped_rows, :no_scoped_rows]
      end

      ctx = S.claims(["SYNC_ROLE_A"])

      assert {:suppressed, _, summary} =
               Identity.sync_role_claims_report(user!(s), ctx, prefix: s)

      dump = inspect(summary)

      for claim <- [
            ctx.external_user_id,
            ctx.email,
            ctx.preferred_username,
            ctx.display_name,
            S.realm()
          ] do
        refute dump =~ claim
      end
    end
  end

  # ===========================================================================================
  describe "T-S15 / MU-49 the roles a group binds are read AFTER lock A (SEC C-3), proven with a REAL held lock A" do
    setup do
      Locks.attach_error_handler(:req519_2eb_lock)
      :ok
    end

    # A transaction on its own connection that holds lock A until released.
    defp hold_lock_a!(schema) do
      test_pid = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            :ok = Identity.lock_tenant_admins!(schema)
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(test_pid, {:lock_a_held, backend})

            receive do
              :release -> :ok
            after
              15_000 -> :timeout
            end
          end)
        end)

      on_exit(fn -> send(holder.pid, :release) end)
      assert_receive {:lock_a_held, backend}, 10_000
      {holder, backend}
    end

    # Group G binds P (scoped row, harmless); role Q is bound to ANOTHER group H with a
    # tenant-wide row. Moving Q onto G (rebind_role, which moves the rows with it) makes a
    # membership of G widening. The tenant is `on`.
    defp ordering_world do
      fx = tenant!("req519-s15", :off)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_P", [{:node, node!(s)}])
      h = S.platform_group!(s, "SYNC_ROLE_Q", [:tenant_wide])
      q = RSG.binding(s, "SYNC_ROLE_Q")
      assert q.group_id == h.id
      set_mode!(fx, :on)
      {fx, g, q, user!(s)}
    end

    defp rebind_worker(fx, q, g) do
      fn ->
        RoleRegistry.rebind_role_report(
          q.id,
          g.id,
          %{actor_id: nil, reason: "move Q onto the sync group"},
          prefix: fx.schema_name
        )
      end
    end

    defp sync_worker(fx, user), do: fn -> S.sync(fx.schema_name, user, ["SYNC_ROLE_P"]) end

    defp queue_two!(fx, first, second) do
      {holder, barrier_pid} = hold_lock_a!(fx.schema_name)

      {t1, pid1} = Locks.start_worker(first)
      Locks.wait_for_blocked([pid1], 1)
      Locks.await_blocked_by(pid1, [barrier_pid])

      # the second worker is started only when the first is already queued on lock A: its
      # pre-lock resolve of candidate groups therefore happens BEFORE the first one commits
      {t2, pid2} = Locks.start_worker(second)
      Locks.wait_for_blocked([pid1, pid2], 2)
      Locks.await_blocked_by(pid2, [barrier_pid, pid1])

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, Locks.await_ms())
      {r1, _} = Task.await(t1, Locks.await_ms())
      {r2, _} = Task.await(t2, Locks.await_ms())
      refute_receive {:deadlock_detected, _}, 0
      {r1, r2}
    end

    test "the rebind queued FIRST commits before the sync takes lock A: the decision uses the binding read after A (suppressed)" do
      {fx, g, q, user} = ordering_world()
      s = fx.schema_name

      {rebind, sync} = queue_two!(fx, rebind_worker(fx, q, g), sync_worker(fx, user))

      assert {:ok, %{name: "SYNC_ROLE_Q"}, :in_place} = rebind
      # the rows followed the binding, so G is now tenant-wide for Q (the scenario is real)
      assert RSG.rows(s) |> Enum.member?(RSG.tw(g.id, "SYNC_ROLE_Q"))

      assert {:suppressed, _synced, summary} = sync

      assert summary == %{
               suppressed: [%{group_id: g.id, role: "SYNC_ROLE_Q", kind: :no_scoped_rows}],
               deduped: 0
             }

      assert S.memberships(s, user.id) == []
      assert [entry] = entries(s, @action_pending)
      assert entry.resource_id == "#{user.id}:SYNC_ROLE_Q"
    end

    test "control: the sync queued FIRST commits before the rebind, so it correctly joins the group G (fully before)" do
      {fx, g, q, user} = ordering_world()
      s = fx.schema_name

      {sync, rebind} = queue_two!(fx, sync_worker(fx, user), rebind_worker(fx, q, g))

      assert {:ok, %User{role_claims_synced_at: %DateTime{}}} = sync
      assert {:ok, %{name: "SYNC_ROLE_Q"}, :in_place} = rebind
      assert S.memberships(s, user.id) == [g.id]
      assert suppression_entries(s) == []
    end

    test "T-S15c the MODE is read after lock A too: a flip to on queued first is seen by the sync queued behind it" do
      fx = tenant!("req519-s15c", :shadow)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_A", [:tenant_wide])
      user = user!(s)

      # the flip's core, as in T-L2/T-L3 of the writers: lock A, then the stored mode
      flip = fn ->
        Repo.transaction(fn ->
          :ok = Identity.lock_tenant_admins!(s)
          :ok = set_mode!(fx, :on)
        end)
      end

      sync = fn -> S.sync(s, user, ["SYNC_ROLE_A"]) end

      {flipped, synced} = queue_two!(fx, flip, sync)

      assert flipped == {:ok, :ok}

      assert {:suppressed, _user, %{suppressed: [%{group_id: group_id, role: "SYNC_ROLE_A"}]}} =
               synced

      assert group_id == g.id
      assert S.memberships(s, user.id) == []
      assert [_one] = entries(s, @action_pending)
    end
  end

  # ===========================================================================================
  describe "T-S16a routing-role binding never widens (MU-50)" do
    test "a group with a scoped platform role and a TENANT-WIDE routing role is joined" do
      fx = tenant!("req519-s16", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_P", [{:node, node!(s)}])
      S.bind_routing!(s, g, "SYNC_ROUTE_R", [:tenant_wide])
      user = user!(s)

      assert {:ok, synced} = S.sync(s, user, ["SYNC_ROLE_P"])
      assert %DateTime{} = synced.role_claims_synced_at
      assert S.memberships(s, user.id) == [g.id]
      assert suppression_entries(s) == []

      # the routing role is not a platform role: it never appears in the user's roles or scope
      assert Identity.list_effective_role_names(user.id, prefix: s) == ["SYNC_ROLE_P"]
      assert Map.keys(MembershipScope.snapshot(user.id, s)) == ["SYNC_ROLE_P"]
    end

    test "claiming only a routing-role name resolves no group at all: nothing happens, the marker stays nil" do
      fx = tenant!("req519-s16b", :on)
      s = fx.schema_name
      g = RSG.fresh_group!(s)
      S.bind_routing!(s, g, "SYNC_ROUTE_R", [:tenant_wide])
      user = user!(s)

      {result, _log} = with_log(fn -> S.sync(s, user, ["SYNC_ROUTE_R"]) end)

      assert result == {:ok, user}
      assert S.memberships(s, user.id) == []
      assert S.marker(s, user.id) == nil
      assert suppression_entries(s) == []
    end

    test "SyncScopeGuard.bound_platform_roles/2 lists platform bindings only, per group, inside the tenant" do
      fx = tenant!("req519-s16c", :on)
      other = tenant!("req519-s16c2", :on)
      s = fx.schema_name
      g = S.platform_group!(s, "SYNC_ROLE_P", [])
      S.bind_platform!(s, g, "SYNC_ROLE_Q", [])
      S.bind_routing!(s, g, "SYNC_ROUTE_R", [])
      routing_only = RSG.fresh_group!(s)
      S.bind_routing!(s, routing_only, "SYNC_ROUTE_S", [])

      result = SyncScopeGuard.bound_platform_roles([g.id, routing_only.id], s)
      assert Map.keys(result) == [g.id]
      assert Enum.sort(result[g.id]) == ["SYNC_ROLE_P", "SYNC_ROLE_Q"]

      assert SyncScopeGuard.bound_platform_roles([], s) == %{}
      # the same ids read through another tenant's schema find nothing
      assert SyncScopeGuard.bound_platform_roles([g.id], other.schema_name) == %{}
    end
  end

  # ===========================================================================================
  describe "T-S17 docs/roles.md states that the whole group is withheld (A-7)" do
    test "the section names the whole-group rule, the two actions, the key set and the remedy" do
      text = "docs/roles.md" |> File.read!() |> String.replace(~r/\s+/, " ")

      assert text =~ "IdP role-claims sync while scope enforcement is on"

      assert text =~
               "The WHOLE group is withheld when ANY platform role it binds would widen the user"

      assert text =~ "grant.sync_suppressed"
      assert text =~ "binding.pending_scope"
      assert text =~ "the keys `user`, `group`, `role`, `trace_id` only"
      assert text =~ "no IdP claim value"

      assert text =~
               "Remedy: an admin adds the user to a group whose grants for the role are scoped"

      assert text =~ "A group bound only as a process-routing role is never withheld"
    end
  end
end
