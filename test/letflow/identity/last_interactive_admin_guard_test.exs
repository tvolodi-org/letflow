defmodule Letflow.Identity.LastInteractiveAdminGuardTest do
  @moduledoc """
  GH #2869 part (a) (design `lib/letflow/design/gh2869-last-interactive-admin-guard.md` r4,
  section 5, tests T-LA-P1..P6, T-LA-19 to T-LA-23, T-LA-27, T-LA-28; spec
  `test/specs/GH2869-last-interactive-admin-guard.md`): in a tenant stored `on`, a write that
  takes the number of interactive explicit tenant-wide `TENANT_ADMIN`s from at least one to zero
  is refused with `{:error, :last_interactive_tenant_wide_admin}`.

  The six guarded paths (P1 deactivation, P2 group-member removal, P3 TENANT_ADMIN unbind, P4
  TENANT_ADMIN rebind, P5 revoke of a tenant-wide TENANT_ADMIN grant row, P6 service-principal
  flagging) run against the "last interactive" fixture of
  `Letflow.Support.LastInteractiveAdminFixture`: one interactive explicit admin A1 plus a second
  active user T1 who owns a live `TENANT_ADMIN` token, so the OLD counted guard would let every
  removal through and only the new guard can refuse (a fixture without T1 would make the per-path
  tests vacuous). Each refusal asserts the typed error, that NOTHING changed (a content snapshot
  of users, groups, memberships, bindings, grants and tokens), and exactly one
  `tenant_admin.guard_refused` entry with the six contract keys and the new `reason_code`.

  `async: false`: committed state in real tenant schemas, committed DDL (schema rename for the
  fail-closed table, audit fault trigger), VM-global application env.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Identity
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.ScopedGrants
  alias Letflow.Identity.ServicePrincipal
  alias Letflow.Identity.TenantAdminGuard
  alias Letflow.Identity.User
  alias Letflow.ScopeEnforcement.ModeUnavailableError
  alias Letflow.Support.EnforcedWritersFixture, as: EW
  alias Letflow.Support.LastInteractiveAdminFixture, as: LIA
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: SG

  @new {:error, :last_interactive_tenant_wide_admin}
  @old {:error, :last_tenant_wide_admin}
  @paths [:p1, :p2, :p3, :p4, :p5, :p6]
  @actions %{
    p1: "deactivate_user",
    p2: "remove_tenant_admin_member",
    p3: "unbind_tenant_admin",
    p4: "rebind_tenant_admin",
    p5: "revoke_tenant_admin_grant",
    p6: "flag_service_principal"
  }

  setup do
    LIA.purge_stale!()
    :ok
  end

  # --- the six guarded paths as data -----------------------------------------------------------
  #
  # prepare(path, fx, variant) does the RAW setup a path needs and returns the data its call uses;
  # call(path, fx, data) performs the guarded write against `fx.schema_name` (which the
  # fail-closed test points at a renamed schema); target(path, fx) is the id the refusal names.

  # P4 needs the F3 shape: the admin group holds NO grant row (A1's only basis is his user row),
  # so the rebind moves zero rows (skipped in `on`) and the new group's members hold no row. With
  # a group row the rows would follow the binding and the new group's member would be explicit.
  defp prepare(:p4, fx, :rowless_member) do
    _row_id = LIA.userize_admin_row!(fx)
    {group, _member} = LIA.rowless_group_with_member!(fx)
    %{target_group: group.id}
  end

  defp prepare(:p4, fx, :empty), do: %{target_group: RSG.fresh_group!(fx.schema_name).id}

  defp prepare(:p4, fx, :rows_follow) do
    # the admin group KEEPS its group row, so the row follows the binding to the new group (the
    # rebind first clears the target's own rows, then moves the old group's): the new group's
    # member is an interactive explicit admin and the count never reaches zero
    {group, _member} = LIA.rowless_group_with_member!(fx)
    %{target_group: group.id}
  end

  defp prepare(:p5, fx, _variant), do: %{row_id: LIA.userize_admin_row!(fx)}
  defp prepare(_path, _fx, _variant), do: %{}

  defp target(:p3, fx), do: fx.binding.id
  defp target(:p4, fx), do: fx.binding.id
  defp target(_path, fx), do: fx.admin.id

  defp call(:p1, fx, _data),
    do:
      Identity.update_user_status(
        fx.admin.id,
        :inactive,
        LIA.opts(fx) ++ [login_directory: :skip]
      )

  defp call(:p2, fx, _data),
    do: Identity.remove_group_member(fx.ta_group_id, fx.admin.id, LIA.opts(fx))

  defp call(:p3, fx, _data),
    do:
      RoleRegistry.upsert_role(
        "TENANT_ADMIN",
        :process_routing_role,
        fx.ta_group_id,
        LIA.opts(fx)
      )

  defp call(:p4, fx, %{target_group: group_id}),
    do:
      RoleRegistry.rebind_role(
        fx.binding.id,
        group_id,
        %{actor_id: fx.t1.id, reason: LIA.reason()},
        LIA.opts(fx)
      )

  defp call(:p5, fx, %{row_id: row_id}),
    do: ScopedGrants.delete(row_id, LIA.actor(fx), fx.schema_name)

  defp call(:p6, fx, _data),
    do: ServicePrincipal.set_flag(fx.admin.id, true, LIA.reason(), LIA.actor(fx), fx.schema_name)

  # a successful write of any of the six
  defp succeeded?({:ok, _value}), do: true
  defp succeeded?(:ok), do: true
  defp succeeded?(_other), do: false

  defp refused!(path, fx, variant) do
    data = prepare(path, fx, variant)
    snap = LIA.snapshot(fx)
    ids = LIA.entry_ids(fx)

    assert call(path, fx, data) == @new

    assert LIA.snapshot(fx) == snap, "#{path}: the refused call changed something"

    LIA.assert_only_refusal!(fx, ids, %{
      action: @actions[path],
      target_id: target(path, fx),
      actor: fx.t1.id,
      trace: LIA.trace()
    })
  end

  # ===========================================================================================
  describe "T-LA-P1 deactivation of the last interactive admin" do
    test "update_user_status is refused; A1 stays active, his tokens stay live, one deactivate_user entry" do
      fx = "p1" |> LIA.on_tenant!() |> LIA.assert_last_interactive!("on")
      # A1 owns a live token of another role: a refused deactivation must not revoke it
      _token = F.raw_token!(fx.schema_name, fx.admin.id, ["PROCESS_DESIGNER"], fx.admin.id)

      entry = refused!(:p1, fx, :default)

      assert entry.resource_type == "user"
      assert Repo.get!(User, fx.admin.id, prefix: fx.schema_name).status == :active
      assert LIA.interactive(fx) == 1
    end

    test "P1b: the same refusal through update_user_profile with a status key" do
      fx = LIA.on_tenant!("p1b")
      snap = LIA.snapshot(fx)
      ids = LIA.entry_ids(fx)

      assert Identity.update_user_profile(
               fx.admin.id,
               %{status: :inactive},
               LIA.opts(fx) ++ [login_directory: :skip]
             ) ==
               @new

      assert LIA.snapshot(fx) == snap

      LIA.assert_only_refusal!(fx, ids, %{
        action: "deactivate_user",
        target_id: fx.admin.id,
        actor: fx.t1.id,
        trace: LIA.trace()
      })
    end

    test "control: with a SECOND interactive admin the same deactivation succeeds and revokes A1's tokens" do
      fx = LIA.on_tenant!("p1c")
      token = F.raw_token!(fx.schema_name, fx.admin.id, ["PROCESS_DESIGNER"], fx.admin.id)
      _a2 = LIA.add_admin!(fx)
      assert LIA.interactive(fx) == 2

      assert {:ok, %User{status: :inactive}} = call(:p1, fx, %{})

      assert LIA.interactive(fx) == 1
      assert Repo.get!(Letflow.Identity.ApiToken, token.id, prefix: fx.schema_name).revoked_at
      assert LIA.refusals(fx) == []
    end

    test "control: a profile write without a status key, and a reactivation, are never refused" do
      fx = LIA.on_tenant!("p1d")

      assert {:ok, %User{}} =
               Identity.update_user_profile(
                 fx.admin.id,
                 %{display_name: "Renamed Admin"},
                 LIA.opts(fx) ++ [login_directory: :skip]
               )

      assert {:ok, %User{status: :active}} =
               Identity.update_user_status(
                 fx.admin.id,
                 :active,
                 LIA.opts(fx) ++ [login_directory: :skip]
               )

      assert LIA.interactive(fx) == 1
      assert LIA.refusals(fx) == []
    end
  end

  describe "T-LA-P2 removal of the last interactive admin from the admin group" do
    test "remove_group_member is refused; the membership is still there; one remove_tenant_admin_member entry" do
      fx = "p2" |> LIA.on_tenant!() |> LIA.assert_last_interactive!("on")

      entry = refused!(:p2, fx, :default)

      assert entry.resource_type == "group_member"
      assert LIA.member?(fx, fx.ta_group_id, fx.admin.id)
    end

    test "control: removing T1 from a non-admin group is allowed, and with a second admin the removal succeeds" do
      fx = LIA.on_tenant!("p2b")
      other = RSG.fresh_group!(fx.schema_name)
      _member = RSG.member!(fx.schema_name, other.id, fx.t1)
      assert :ok = Identity.remove_group_member(other.id, fx.t1.id, LIA.opts(fx))

      _a2 = LIA.add_admin!(fx)
      assert :ok = call(:p2, fx, %{})
      refute LIA.member?(fx, fx.ta_group_id, fx.admin.id)
      assert LIA.interactive(fx) == 1
    end
  end

  describe "T-LA-P3 unbinding the TENANT_ADMIN binding" do
    test "a kind change away from platform_role is refused; the binding keeps its kind; one unbind_tenant_admin entry" do
      fx = "p3" |> LIA.on_tenant!() |> LIA.assert_last_interactive!("on")

      entry = refused!(:p3, fx, :default)

      assert entry.resource_type == "tenant_role"
      assert RSG.binding(fx.schema_name, "TENANT_ADMIN").kind == :platform_role
    end

    test "a second admin does not help: an unbind removes every member-admin at once" do
      fx = LIA.on_tenant!("p3b")
      _a2 = LIA.add_admin!(fx)
      assert LIA.interactive(fx) == 2

      assert call(:p3, fx, %{}) == @new
      assert LIA.interactive(fx) == 2
    end
  end

  describe "T-LA-P4 rebinding the TENANT_ADMIN binding" do
    test "premise: the OLD guard would pass (members of the new group, no tenant-wide row); the new guard refuses" do
      fx = LIA.on_tenant!("p4")
      # no token owner: the only admins the OLD counter could find after the move are G2's members
      :ok = LIA.drop_token_owner!(fx)
      data = prepare(:p4, fx, :rowless_member)

      # what the old counted guard measures after the move (rolled back): above zero, while the
      # interactive count (the new guard's) is zero
      {counted, interactive} = counts_after_raw_move(fx, data.target_group)
      assert counted > 0, "premise: the OLD guard would let this rebind through"
      assert interactive == 0

      snap = LIA.snapshot(fx)
      ids = LIA.entry_ids(fx)
      assert call(:p4, fx, data) == @new
      assert LIA.snapshot(fx) == snap
      assert RSG.binding(fx.schema_name, "TENANT_ADMIN").group_id == fx.ta_group_id

      entry =
        LIA.assert_only_refusal!(fx, ids, %{
          action: "rebind_tenant_admin",
          target_id: fx.binding.id,
          actor: fx.t1.id,
          trace: LIA.trace()
        })

      assert entry.resource_type == "tenant_role"
    end

    test "the same rebind in a shadow tenant is allowed, and when the group row follows the binding to a group with a member it is allowed in on" do
      shadow = LIA.tenant_in_mode!("p4s", :shadow)
      data = prepare(:p4, shadow, :rowless_member)
      assert {:ok, _role} = call(:p4, shadow, data)

      fx = LIA.on_tenant!("p4o")
      data = prepare(:p4, fx, :rows_follow)
      assert {:ok, _role} = call(:p4, fx, data)
      assert LIA.interactive(fx) == 1
    end
  end

  describe "T-LA-P5 revoking the tenant-wide TENANT_ADMIN grant row of the last interactive admin" do
    test "the user row of A1 (zero-row admin group) is refused; the row is still there; one revoke_tenant_admin_grant entry" do
      fx = LIA.on_tenant!("p5")
      _row_id = LIA.userize_admin_row!(fx)
      LIA.assert_last_interactive!(fx, "on")
      # the OLD explicit guard would pass too: the live token owner T1 is counted by it
      assert LIA.explicit(fx) >= 2

      snap = LIA.snapshot(fx)
      ids = LIA.entry_ids(fx)
      row_id = LIA.user_row_id!(fx, fx.admin.id)

      assert ScopedGrants.delete(row_id, LIA.actor(fx), fx.schema_name) == @new
      assert LIA.snapshot(fx) == snap

      entry =
        LIA.assert_only_refusal!(fx, ids, %{
          action: "revoke_tenant_admin_grant",
          target_id: fx.admin.id,
          actor: fx.t1.id,
          trace: LIA.trace()
        })

      assert entry.resource_type == "role_scope_grant"
      assert LIA.user_row_id!(fx, fx.admin.id) == row_id
    end

    test "the delete of a group's sole tenant-wide TENANT_ADMIN row still answers last_admin_binding_row (the older rule wins)" do
      fx = LIA.on_tenant!("p5b")
      snap = LIA.snapshot(fx)

      assert ScopedGrants.delete(LIA.group_row_id!(fx), LIA.actor(fx), fx.schema_name) ==
               {:error, :last_admin_binding_row}

      assert LIA.snapshot(fx) == snap
      # the older rule refuses before either guard: no guard_refused entry of any kind
      assert LIA.refusals(fx) == []
    end

    test "control: with a second admin holding his own user row the delete succeeds" do
      fx = LIA.on_tenant!("p5c")
      row_id = LIA.userize_admin_row!(fx)
      a2 = LIA.add_admin!(fx)
      :ok = RSG.raw_user_row!(fx.schema_name, a2.id, "TENANT_ADMIN", nil)
      assert LIA.interactive(fx) == 2

      assert :ok = call(:p5, fx, %{row_id: row_id})
      assert LIA.interactive(fx) == 1
    end
  end

  describe "T-LA-P6 flagging the last interactive admin as a service principal" do
    test "set_flag(A1, true) is refused; the flag stays false; no service_principal.flagged entry; one flag_service_principal entry" do
      fx = "p6" |> LIA.on_tenant!() |> LIA.assert_last_interactive!("on")

      entry = refused!(:p6, fx, :default)

      assert entry.resource_type == "user"
      refute Repo.get!(User, fx.admin.id, prefix: fx.schema_name).admin_flagged_service_principal
      assert RSG.entries(fx.schema_name, "service_principal.flagged") == []
    end

    test "unflagging a principal and flagging a non-admin are allowed; they never lower the interactive count" do
      fx = LIA.on_tenant!("p6b")
      s1 = LIA.add_flagged_member!(fx)
      plain = RSG.user!(fx.schema_name)

      assert {:ok, %{changed: true, flagged: false}} =
               ServicePrincipal.set_flag(
                 s1.id,
                 false,
                 LIA.reason(),
                 LIA.actor(fx),
                 fx.schema_name
               )

      assert {:ok, %{changed: true, flagged: true}} =
               ServicePrincipal.set_flag(
                 plain.id,
                 true,
                 LIA.reason(),
                 LIA.actor(fx),
                 fx.schema_name
               )

      assert LIA.refusals(fx) == []
    end

    test "the reason is validated BEFORE the guard: a missing, blank or invalid reason never reaches it (MU-LA-20)" do
      fx = LIA.on_tenant!("p6c")
      snap = LIA.snapshot(fx)
      ids = LIA.entry_ids(fx)

      flag = fn reason ->
        ServicePrincipal.set_flag(fx.admin.id, true, reason, LIA.actor(fx), fx.schema_name)
      end

      assert flag.(nil) == {:error, :reason_required}
      assert flag.("   ") == {:error, :reason_required}
      assert flag.("") == {:error, :reason_required}
      assert flag.("bad\u0000reason") == {:error, :invalid_reason}
      assert flag.("a\nb") == {:error, :invalid_reason}

      assert LIA.snapshot(fx) == snap
      assert LIA.new_entries(fx, ids) == []

      # and a valid reason then gets the guard's refusal
      assert flag.(LIA.reason()) == @new
      assert [_one] = LIA.refusals(fx)
    end
  end

  # what the old counted guard and the interactive counter measure AFTER the TENANT_ADMIN binding
  # moved to `group_id` (a raw update inside a transaction that is rolled back)
  defp counts_after_raw_move(fx, group_id) do
    import Ecto.Query

    {:error, counts} =
      Repo.transaction(fn ->
        {1, _} =
          Repo.update_all(
            from(t in Letflow.Identity.TenantRole, where: t.id == ^fx.binding.id),
            [set: [group_id: group_id]],
            prefix: fx.schema_name
          )

        Repo.rollback({LIA.counted(fx), LIA.interactive(fx)})
      end)

    counts
  end

  # ===========================================================================================
  describe "T-LA-19 a live token owner, a flagged principal and a zero-row member do not save the removal" do
    test "token owner only (the default fixture): P1 and P2 refuse" do
      fx = LIA.on_tenant!("l19a")
      assert LIA.counted(fx) == 2

      assert call(:p1, fx, %{}) == @new
      assert call(:p2, fx, %{}) == @new
    end

    test "a flagged service principal member only: P1 and P2 refuse" do
      fx = LIA.on_tenant!("l19b")
      :ok = LIA.drop_token_owner!(fx)
      _s1 = LIA.add_flagged_member!(fx)
      assert LIA.counted(fx) == 2
      assert LIA.interactive(fx) == 1

      assert call(:p1, fx, %{}) == @new
      assert call(:p2, fx, %{}) == @new
    end

    test "a zero-row member only (A1 holds a user row, the group none): P1 and P2 refuse" do
      fx = LIA.on_tenant!("l19c")
      :ok = LIA.drop_token_owner!(fx)
      _row_id = LIA.userize_admin_row!(fx)
      _z1 = LIA.add_admin!(fx)
      assert LIA.counted(fx) == 2
      assert LIA.interactive(fx) == 1

      assert call(:p1, fx, %{}) == @new
      assert call(:p2, fx, %{}) == @new
    end
  end

  # ===========================================================================================
  describe "T-LA-20 mode matrix over P1 to P6: stored shadow and off allow the same write" do
    for path <- @paths, mode <- [:shadow, :off] do
      @tag path: path, mode: mode
      test "#{path} in #{mode} succeeds and changes state", %{path: path, mode: mode} do
        fx = LIA.tenant_in_mode!("l20-#{path}-#{mode}", mode)
        assert EW.stored_mode(fx) == Atom.to_string(mode)
        data = prepare(path, fx, :rowless_member)
        snap = LIA.snapshot(fx)

        result = call(path, fx, data)

        assert succeeded?(result), "#{path}/#{mode}: #{inspect(result)}"
        refute LIA.snapshot(fx) == snap
        assert LIA.refusals(fx) == []
      end
    end

    for path <- @paths do
      @tag path: path
      test "#{path} in on is refused (the same call)", %{path: path} do
        fx = LIA.on_tenant!("l20-#{path}-on")
        assert EW.stored_mode(fx) == "on"
        refused!(path, fx, :rowless_member)
      end
    end
  end

  # ===========================================================================================
  describe "T-LA-21 second admin matrix: one removal succeeds, the next is refused" do
    test "P1: A1 deactivated with A2 present, then A2 refused" do
      fx = LIA.on_tenant!("l21-p1")
      a2 = LIA.add_admin!(fx)
      assert {:ok, %User{status: :inactive}} = call(:p1, fx, %{})

      assert Identity.update_user_status(
               a2.id,
               :inactive,
               LIA.opts(fx) ++ [login_directory: :skip]
             ) == @new

      assert LIA.interactive(fx) == 1
    end

    test "P2: A1 removed with A2 present, then A2 refused" do
      fx = LIA.on_tenant!("l21-p2")
      a2 = LIA.add_admin!(fx)
      assert :ok = call(:p2, fx, %{})

      assert Identity.remove_group_member(fx.ta_group_id, a2.id, LIA.opts(fx)) == @new
      assert LIA.interactive(fx) == 1
    end

    test "P3: an unbind is refused even with two admins (it removes both at once)" do
      fx = LIA.on_tenant!("l21-p3")
      _a2 = LIA.add_admin!(fx)
      assert call(:p3, fx, %{}) == @new
    end

    test "P4: a rebind to a group with a member succeeds (the row follows), the next rebind to an empty group is refused" do
      fx = LIA.on_tenant!("l21-p4")
      assert {:ok, _role} = call(:p4, fx, prepare(:p4, fx, :rows_follow))
      assert LIA.interactive(fx) == 1

      # the rows follow the binding now, so the second target must hold NO member to empty the count
      empty = RSG.fresh_group!(fx.schema_name)

      assert RoleRegistry.rebind_role(
               fx.binding.id,
               empty.id,
               %{actor_id: fx.t1.id, reason: LIA.reason()},
               LIA.opts(fx)
             ) == @new
    end

    test "P5: A1's user row deleted with A2's user row present, then A2's refused" do
      fx = LIA.on_tenant!("l21-p5")
      data = prepare(:p5, fx, :default)
      a2 = LIA.add_admin!(fx)
      :ok = RSG.raw_user_row!(fx.schema_name, a2.id, "TENANT_ADMIN", nil)
      assert :ok = call(:p5, fx, data)

      assert ScopedGrants.delete(LIA.user_row_id!(fx, a2.id), LIA.actor(fx), fx.schema_name) ==
               @new
    end

    test "P6: A1 flagged with A2 present, then A2 refused" do
      fx = LIA.on_tenant!("l21-p6")
      a2 = LIA.add_admin!(fx)
      assert {:ok, %{changed: true}} = call(:p6, fx, %{})

      assert ServicePrincipal.set_flag(a2.id, true, LIA.reason(), LIA.actor(fx), fx.schema_name) ==
               @new
    end
  end

  # ===========================================================================================
  describe "T-LA-22 precedence: when both guards hit zero the old one wins" do
    for path <- [:p1, :p2, :p3, :p4, :p5] do
      @tag path: path
      test "#{path} with no token owner and no other counted admin answers last_tenant_wide_admin",
           %{
             path: path
           } do
        fx = LIA.on_tenant!("l22-#{path}")
        :ok = LIA.drop_token_owner!(fx)
        data = prepare(path, fx, :empty)
        snap = LIA.snapshot(fx)
        ids = LIA.entry_ids(fx)

        assert call(path, fx, data) == @old
        assert LIA.snapshot(fx) == snap

        # ONE entry, with the OLD reason code
        assert [entry] = LIA.new_entries(fx, ids)
        assert entry.action == LIA.event()
        assert entry.after_state["reason_code"] == LIA.old_code()
        assert entry.after_state["action"] == @actions[path]
      end
    end
  end

  # ===========================================================================================
  describe "T-LA-23 fail closed: an unreadable mode never allows, never refuses, and changes nothing" do
    for path <- @paths do
      @tag path: path
      test "#{path} returns the detail-free transaction_failed shape", %{path: path} do
        fx = LIA.on_tenant!("l23-#{path}")
        data = prepare(path, fx, :rowless_member)
        snap = LIA.snapshot(fx)
        ids = LIA.entry_ids(fx)

        result = LIA.with_unreadable_mode(fx, fn rfx -> call(path, rfx, data) end)

        assert {:error, {:transaction_failed, %ModeUnavailableError{} = error}} = result
        assert Exception.message(error) == "scope enforcement mode unavailable"
        refute inspect(result) =~ fx.admin.id
        assert LIA.snapshot(fx) == snap
        assert LIA.new_entries(fx, ids) == []
      end
    end

    for path <- [:p1, :p2, :p5, :p6] do
      @tag path: path
      test "#{path}: a removal that leaves a second admin NEVER reads the mode, even for an unreadable tenant",
           %{path: path} do
        fx = LIA.on_tenant!("l23b-#{path}")
        data = prepare(path, fx, :default)
        a2 = LIA.add_admin!(fx)
        :ok = RSG.raw_user_row!(fx.schema_name, a2.id, "TENANT_ADMIN", nil)

        result = LIA.with_unreadable_mode(fx, fn rfx -> call(path, rfx, data) end)

        assert succeeded?(result), "#{path}: #{inspect(result)}"
      end
    end

    test "a write at zero interactive admins (before 0) never reads the mode either" do
      fx = LIA.on_tenant!("l23c")
      stranger = RSG.user!(fx.schema_name)
      LIA.at_zero!(fx)

      result =
        LIA.with_unreadable_mode(fx, fn rfx ->
          Identity.update_user_status(
            stranger.id,
            :inactive,
            LIA.opts(rfx) ++ [login_directory: :skip]
          )
        end)

      assert {:ok, %User{status: :inactive}} = result
    end
  end

  # ===========================================================================================
  describe "T-LA-27 event shape" do
    test "exactly the six keys, the new reason_code, counted_admins 0, actor and trace from the context, no other id" do
      fx = LIA.on_tenant!("l27")
      _a2_token = F.raw_token!(fx.schema_name, fx.admin.id, ["PROCESS_DESIGNER"], fx.admin.id)
      ids = LIA.entry_ids(fx)

      assert call(:p1, fx, %{}) == @new
      assert [entry] = LIA.new_entries(fx, ids)

      assert entry.after_state == %{
               "action" => "deactivate_user",
               "actor" => fx.t1.id,
               "target_id" => fx.admin.id,
               "reason_code" => LIA.new_code(),
               "counted_admins" => 0,
               "trace_id" => LIA.trace()
             }

      assert entry.actor_id == fx.t1.id
      assert entry.trace_id == LIA.trace()
      assert entry.resource_type == "user"
      assert entry.resource_id == fx.admin.id

      # no id of any OTHER principal (T1's token, the group, the binding) is in the entry
      uuids =
        Regex.scan(
          ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/,
          inspect(entry.after_state)
        )

      assert uuids |> List.flatten() |> Enum.uniq() |> Enum.sort() ==
               Enum.sort(Enum.uniq([fx.t1.id, fx.admin.id]))
    end

    test "refuse/3 with an interactive refusal writes the user kind for flag_service_principal and the typed error" do
      fx = LIA.on_tenant!("l27b")
      ids = LIA.entry_ids(fx)
      refusal = TenantAdminGuard.interactive_refusal(:flag_service_principal, fx.admin.id)

      assert TenantAdminGuard.refuse(fx.schema_name, refusal, LIA.ctx(fx)) == @new

      entry =
        LIA.assert_only_refusal!(fx, ids, %{
          action: "flag_service_principal",
          target_id: fx.admin.id,
          actor: fx.t1.id,
          trace: LIA.trace()
        })

      assert entry.resource_type == "user"
    end

    test "the old paths keep the old reason_code and the old error (default refusal)" do
      fx = LIA.on_tenant!("l27c")
      :ok = LIA.drop_token_owner!(fx)
      ids = LIA.entry_ids(fx)

      assert call(:p2, fx, %{}) == @old
      assert [entry] = LIA.new_entries(fx, ids)
      assert entry.after_state["reason_code"] == LIA.old_code()
    end
  end

  # ===========================================================================================
  describe "T-LA-28 the refusal event cannot be written" do
    test "the refusal still stands, ONE constant log line is written, and the guarded change is rolled back" do
      fx = LIA.on_tenant!("l28")
      snap = LIA.snapshot(fx)

      {result, log} =
        with_log_result(fn ->
          SG.with_audit_fault(fx, LIA.event(), fn -> call(:p2, fx, %{}) end)
        end)

      assert result == @new
      assert LIA.snapshot(fx) == snap
      assert LIA.refusals(fx) == []

      # own constant line only: the rest of the log carries SQL with ids
      lines = F.lines_with(log, "audit write failed")
      assert [line] = lines
      assert line =~ "tenant_admin.guard_refused"
      refute F.uuid_in?(line)
    end
  end

  defp with_log_result(fun) do
    parent = self()
    ref = make_ref()

    log =
      capture_log(fn ->
        send(parent, {ref, fun.()})
      end)

    receive do
      {^ref, result} -> {result, log}
    after
      0 -> flunk("the captured function did not return")
    end
  end
end
