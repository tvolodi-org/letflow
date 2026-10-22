defmodule Letflow.Identity.EnforcedAuditActionsTest do
  @moduledoc """
  REQ-519 slice 2e-a (GH #2535), AC 7 for the action introduced in 2e-a, `binding.refused`
  (decision 0051 D8 amendment rule 3; design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` section 8.1, tests T-A1 and T-A2;
  spec `test/specs/REQ-519-2e-a.md`):

    * T-A1: `Letflow.Audit.list_entries/1` returns each 2e-a entry without error through its
      `resource_type` / `resource_id` filters (the function has no action filter, design
      finding F7, so the action is asserted on the returned items);
    * T-A2: no token value, token hash, IdP claim value, e-mail or user name appears in any entry
      the 2e-a code writes (`binding.refused`, and the `role_binding.created` entry of a seeded
      NO-ROW binding, which gains the fixed key `rows`).

  2e-b part (spec `test/specs/REQ-519-2e-b.md`):

    * T-A3: `grant.sync_suppressed`, `binding.pending_scope`, `group_member.added` and
      `group_member.removed` (with `scope_delta`) are returned by `Audit.list_entries/1`
      through the resource filters without error;
    * T-A4: exact key sets of those entries, and no claim value (realm, e-mail, preferred
      name, display name), user e-mail or user name, or group name in any payload.

  `async: false`: committed writes in a real tenant schema.
  """

  use Letflow.DataCase, async: false

  import Letflow.Support.EnforcedWritersFixture
  import Letflow.Support.RoleScopeGrantsFixture

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Support.SyncScopeFixture, as: S

  @actor "7c1d5f22-9a40-4e7b-b3a8-0d3f6f1e5b10"

  defp list(s, resource_type, resource_id) do
    Audit.list_entries(%{
      prefix: s,
      page_size: 50,
      resource_type: resource_type,
      resource_id: resource_id
    })
  end

  describe "T-A1 binding.refused is listed without error" do
    test "through the resource_type and resource_id filters, with the action on the returned item" do
      fx = tenant!("req519-a1", :on)
      s = fx.schema_name
      g = group!(fx)

      assert {:error, :scope_required} =
               RoleRegistry.upsert_role_report("PROCESS_DESIGNER", :platform_role, g.id,
                 prefix: s,
                 audit_context: %{actor_id: @actor, trace_id: "req519-a1-trace", source: "api"}
               )

      assert {:ok, %{items: [item], has_more: false}} = list(s, "tenant_role", "PROCESS_DESIGNER")
      assert item.action == "binding.refused"
      assert item.actor_id == @actor
      assert item.trace_id == "req519-a1-trace"

      # No match for another role name: the filter is real, not a pass-through.
      assert {:ok, %{items: []}} = list(s, "tenant_role", "TASK_WORKER")

      # The chain still verifies after the entry written outside the rolled-back transaction.
      assert {:ok, :valid} = Audit.verify_chain(s)
    end
  end

  describe "T-A2 no secret in any entry written by 2e-a" do
    test "binding.refused and the NO-ROW role_binding.created hold ids and fixed strings only" do
      fx = tenant!("req519-a2", :off)
      s = fx.schema_name

      # A member with identifying data and a real token whose plaintext and hash exist.
      group = group!(s, "TASK_WORKER")
      user = member!(s, group.id, user!(s)) |> Map.take([:id, :username, :email])

      {:ok, %{token: token, plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: nil}, prefix: s)

      set_mode!(fx, :on)
      ids = entry_ids(s)
      other = group!(fx)

      assert {:error, :scope_required} =
               RoleRegistry.upsert_role_report("PROCESS_DESIGNER", :platform_role, other.id,
                 prefix: s,
                 audit_context: %{actor_id: @actor, trace_id: "req519-a2-trace", source: "api"}
               )

      assert {:ok, %{skipped_enforced: [_ | _]}} =
               RoleRegistry.seed_default_platform_role_groups_report(prefix: s)

      written = new_entries(s, ids)
      actions = written |> Enum.map(& &1.action) |> Enum.uniq() |> Enum.sort()
      assert actions == ["binding.refused", "role_binding.created"]

      dump = Jason.encode!(Enum.map(written, &%{before: &1.before_state, after: &1.after_state}))

      for secret <- [plaintext, token.token_hash, user.username, user.email] do
        assert is_binary(secret) and secret != ""
        refute dump =~ secret
      end

      refute dump =~ "lf_tok_"
      refute dump =~ ~r/password/i

      # Key sets: nothing beyond ids and fixed strings.
      refused = Enum.find(written, &(&1.action == "binding.refused"))

      assert refused.after_state |> Map.keys() |> Enum.sort() ==
               ~w(actor case group role trace_id)

      created = Enum.find(written, &(&1.action == "role_binding.created"))
      assert created.after_state["rows"] == "skipped_enforced"
      assert created.after_state["granted_user_ids"] == [user.id]
    end
  end

  # ===========================================================================================
  # 2e-b part (REQ-519 slice 2e-b): the actions first emitted by the IdP sync guard and the
  # membership writers, T-A3 (listed without error) and T-A4 (key sets, no claim value).
  # ===========================================================================================

  defp world_2eb(slug) do
    fx = tenant!(slug, :on)
    s = fx.schema_name
    tw = S.platform_group!(s, "AUD_ROLE_A", [:tenant_wide])
    sc = S.platform_group!(s, "AUD_ROLE_B", [{:node, node!(s)}])
    pending_user = user!(s)
    scoped_user = user!(s)
    :ok = raw_user_row!(s, scoped_user.id, "AUD_ROLE_A", node!(s))

    # suppression entries (both kinds), a sync-written membership, an admin-written removal
    assert {:suppressed, _, _} = S.sync(s, pending_user, ["AUD_ROLE_A"])
    assert {:suppressed, _, _} = S.sync(s, scoped_user, ["AUD_ROLE_A"])
    assert {:ok, _} = S.sync(s, pending_user, ["AUD_ROLE_B"])

    assert :ok =
             Identity.remove_group_member(sc.id, pending_user.id,
               prefix: s,
               audit_context: %{actor_id: @actor, trace_id: "req519-2eb-a-trace", source: "api"}
             )

    %{fx: fx, s: s, tw: tw, sc: sc, pending_user: pending_user, scoped_user: scoped_user}
  end

  describe "T-A3 (2e-b) grant.sync_suppressed, binding.pending_scope and group_member.* are listed without error" do
    test "through the resource_type and resource_id filters, with the action on the returned item" do
      %{s: s, pending_user: pending_user, scoped_user: scoped_user} = world_2eb("req519-a3")

      assert {:ok, %{items: [pending], has_more: false}} =
               list(s, "user_role", "#{pending_user.id}:AUD_ROLE_A")

      assert pending.action == Letflow.Identity.SyncScopeGuard.action_for(:no_scoped_rows)
      assert pending.actor_id == pending_user.id
      assert pending.trace_id == S.trace()

      assert {:ok, %{items: [scoped], has_more: false}} =
               list(s, "user_role", "#{scoped_user.id}:AUD_ROLE_A")

      assert scoped.action == Letflow.Identity.SyncScopeGuard.action_for(:has_scoped_rows)

      # the resource_type filter alone returns both suppression kinds
      assert {:ok, %{items: both}} = list(s, "user_role", nil)

      assert both |> Enum.map(& &1.action) |> Enum.sort() ==
               Letflow.Identity.SyncScopeGuard.kinds()
               |> Enum.map(&Letflow.Identity.SyncScopeGuard.action_for/1)
               |> Enum.sort()

      # group_member.*: added by the sync, removed by an admin, both under the user id
      assert {:ok, %{items: members}} = list(s, "group_member", pending_user.id)

      assert members |> Enum.map(& &1.action) |> Enum.sort() ==
               ["group_member.added", "group_member.removed"]

      # the filter is real: another resource id matches nothing
      assert {:ok, %{items: []}} = list(s, "user_role", "#{pending_user.id}:NO_SUCH_ROLE")

      assert {:ok, :valid} = Audit.verify_chain(s)
    end
  end

  describe "T-A4 (2e-b) key sets, and no claim value, e-mail, user name or group name in any 2e-b payload" do
    test "exact key sets; the dump of every 2e-b entry holds none of the claim values" do
      %{s: s, tw: tw, sc: sc, pending_user: pending_user, scoped_user: scoped_user} =
        world_2eb("req519-a4")

      pending = the_one(s, "binding.pending_scope")
      scoped = the_one(s, "grant.sync_suppressed")
      [added] = entries(s, "group_member.added")
      [removed] = entries(s, "group_member.removed")

      for entry <- [pending, scoped] do
        assert S.after_keys(entry) == ~w(group role trace_id user)
        assert entry.before_state == nil
      end

      base = ~w(group_id group_roles member scope_delta source user_id user_platform_roles)
      assert S.after_keys(added) == Enum.sort(["roles_gained" | base])
      assert S.after_keys(removed) == Enum.sort(["roles_lost" | base])

      dump =
        [pending, scoped, added, removed]
        |> Enum.map(&%{before: &1.before_state, after: &1.after_state})
        |> Jason.encode!()

      secrets = [
        S.realm(),
        "@claims.example.com",
        "claimed-sub-req519",
        "Claimed Display",
        pending_user.email,
        pending_user.username,
        scoped_user.email,
        scoped_user.username,
        tw.name,
        sc.name
      ]

      for secret <- secrets do
        assert is_binary(secret) and secret != ""
        refute dump =~ secret, "#{secret} leaked into a 2e-b audit payload"
      end

      refute dump =~ ~r/password|lf_tok_/i
    end
  end

  defp the_one(schema, action) do
    assert [entry] = entries(schema, action)
    entry
  end
end
