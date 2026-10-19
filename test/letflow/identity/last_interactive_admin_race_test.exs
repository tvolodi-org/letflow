defmodule Letflow.Identity.LastInteractiveAdminRaceTest do
  @moduledoc """
  GH #2869 part (a) (design `lib/letflow/design/gh2869-last-interactive-admin-guard.md` r4,
  sections 3.5 and 3.9, tests T-LA-24, T-LA-25, T-LA-26; spec
  `test/specs/GH2869-last-interactive-admin-guard.md`): the guard under concurrency, on
  COMMITTED state with real separate connections.

  No `pg_locks` queue flakiness: `BreakGlassFixture.queue_two!/3` holds lock A on a barrier
  connection, starts the FIRST worker, waits until it is blocked behind the barrier, starts the
  SECOND, waits until both are blocked, then releases the barrier. Postgres grants waiters of one
  advisory lock in arrival order, so the interleaving is fixed by construction and every
  assertion is on the serialised outcome (who committed, who was refused, the final stored mode
  and count), never on timing.

    * T-LA-24 two interactive admins removed concurrently: exactly one commits, the other is
      refused (deactivation vs deactivation, removal vs removal, mixed), no deadlock;
    * T-LA-25 the guard against the `shadow -> on` and `on -> shadow` flips: in every order no
      interleaving leaves a tenant stored `on` with zero interactive admins;
    * T-LA-26 the break-glass: after `flip_out_of_band(on -> shadow)` the same removal succeeds,
      the break-glass on the last-interactive fixture succeeds and writes no admin row, and a
      removal racing a break-glass serialises on lock A.

  `async: false`: committed state, advisory locks, VM-global platform pin.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.LockOrderHelpers, as: Locks
  alias Letflow.ScopeEnforcement
  alias Letflow.Support.BreakGlassFixture, as: BG
  alias Letflow.Support.EnforcedWritersFixture, as: EW
  alias Letflow.Support.LastInteractiveAdminFixture, as: LIA
  alias Letflow.Support.OnGateFixture, as: F

  @new {:error, :last_interactive_tenant_wide_admin}
  @op "ops.handle-2869"
  @breakglass_reason "GH2869: identity provider outage drill"

  setup do
    LIA.purge_stale!()
    Locks.attach_error_handler(:gh2869_lock)
    :ok
  end

  # workers (zero-arity, run on their own pinned connection)
  defp deactivate(fx, user),
    do: fn ->
      Identity.update_user_status(user.id, :inactive, LIA.opts(fx) ++ [login_directory: :skip])
    end

  defp remove(fx, user),
    do: fn -> Identity.remove_group_member(fx.ta_group_id, user.id, LIA.opts(fx)) end

  defp flip(fx, target),
    do: fn ->
      ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, target, F.attrs(fx, "gh2869 race"))
    end

  defp break_glass(fx, target),
    do: fn ->
      ScopeEnforcement.flip_out_of_band(fx.tenant_id, target, %{
        operator: @op,
        reason: @breakglass_reason
      })
    end

  defp no_deadlock!, do: refute_receive({:deadlock_detected, _error}, 0)

  # ===========================================================================================
  describe "T-LA-24 two admins removed concurrently: exactly one commits, the other is refused" do
    test "deactivation of A1 queued first, deactivation of A2 second" do
      fx = LIA.on_tenant!("l24a")
      a2 = LIA.add_admin!(fx)
      ids = LIA.entry_ids(fx)

      {first, second} =
        BG.queue_two!(fx.schema_name, deactivate(fx, fx.admin), deactivate(fx, a2))

      assert {:ok, %User{status: :inactive}} = first
      assert second == @new
      assert LIA.interactive(fx) == 1
      assert Repo.get!(User, a2.id, prefix: fx.schema_name).status == :active
      assert [_one] = Enum.filter(LIA.new_entries(fx, ids), &(&1.action == LIA.event()))
      no_deadlock!()
    end

    test "removal of A1 queued first, removal of A2 second" do
      fx = LIA.on_tenant!("l24b")
      a2 = LIA.add_admin!(fx)

      {first, second} = BG.queue_two!(fx.schema_name, remove(fx, fx.admin), remove(fx, a2))

      assert first == :ok
      assert second == @new
      assert LIA.interactive(fx) == 1
      assert LIA.member?(fx, fx.ta_group_id, a2.id)
      no_deadlock!()
    end

    test "mixed and reversed: removal of A2 first, then deactivation of A1" do
      fx = LIA.on_tenant!("l24c")
      a2 = LIA.add_admin!(fx)

      {first, second} = BG.queue_two!(fx.schema_name, remove(fx, a2), deactivate(fx, fx.admin))

      assert first == :ok
      assert second == @new
      assert LIA.interactive(fx) == 1
      assert Repo.get!(User, fx.admin.id, prefix: fx.schema_name).status == :active
      no_deadlock!()
    end
  end

  # ===========================================================================================
  # The race tenants have NO live token owner (the gate refuses a token that exceeds its owner)
  # and one flagged service principal in the admin group: the OLD counted guard still sees the
  # principal after A1 is gone, so only the new guard can refuse.
  defp race_tenant!(suffix, mode) do
    fx = LIA.tenant_in_mode!(suffix, mode)
    :ok = LIA.drop_token_owner!(fx)
    _s1 = LIA.add_flagged_member!(fx)
    if mode == :shadow, do: F.backdate_shadow!(fx), else: fx
  end

  describe "T-LA-25 the guard against the flip: no interleaving leaves on with zero interactive admins" do
    test "shadow, removal queued first: the removal commits, the flip then sees zero admins and is refused" do
      fx = race_tenant!("l25a", :shadow)
      assert LIA.interactive(fx) == 1

      {removal, flip} = BG.queue_two!(fx.schema_name, remove(fx, fx.admin), flip(fx, :on))

      assert removal == :ok
      assert {:error, _gate_refusal} = flip
      assert EW.stored_mode(fx) == "shadow"
      assert LIA.interactive(fx) == 0
      no_deadlock!()
    end

    test "shadow, flip queued first: the flip commits on, the removal then sees on and is refused" do
      fx = race_tenant!("l25b", :shadow)

      {flip, removal} = BG.queue_two!(fx.schema_name, flip(fx, :on), remove(fx, fx.admin))

      assert {:ok, %{mode: :on}} = flip
      assert removal == @new
      assert EW.stored_mode(fx) == "on"
      assert LIA.interactive(fx) == 1
      no_deadlock!()
    end

    test "on, removal queued first: refused; the down-flip then commits shadow" do
      fx = race_tenant!("l25c", :on)

      {removal, flip} = BG.queue_two!(fx.schema_name, remove(fx, fx.admin), flip(fx, :shadow))

      assert removal == @new
      assert {:ok, %{mode: :shadow}} = flip
      assert LIA.interactive(fx) == 1
      no_deadlock!()
    end

    test "on, down-flip queued first: it commits shadow, the removal then sees shadow and is allowed" do
      fx = race_tenant!("l25d", :on)

      {flip, removal} = BG.queue_two!(fx.schema_name, flip(fx, :shadow), remove(fx, fx.admin))

      assert {:ok, %{mode: :shadow}} = flip
      assert removal == :ok
      assert EW.stored_mode(fx) == "shadow"
      assert LIA.interactive(fx) == 0
      no_deadlock!()
    end
  end

  # ===========================================================================================
  describe "T-LA-26 the break-glass is neither special-cased nor blocked by the guard" do
    test "after flip_out_of_band(on -> shadow) the same removal succeeds" do
      fx = LIA.on_tenant!("l26a")
      assert LIA.assert_last_interactive!(fx, "on")
      assert Identity.remove_group_member(fx.ta_group_id, fx.admin.id, LIA.opts(fx)) == @new

      assert {:ok, %{mode: :shadow}} = break_glass(fx, :shadow).()

      assert Identity.remove_group_member(fx.ta_group_id, fx.admin.id, LIA.opts(fx)) == :ok
      assert LIA.interactive(fx) == 0
    end

    test "the break-glass on the last-interactive fixture succeeds and writes no admin row" do
      fx = LIA.on_tenant!("l26b")
      before = LIA.snapshot(fx)

      assert {:ok, %{mode: :off}} = break_glass(fx, :off).()

      assert BG.mode(fx) == "off"
      assert LIA.snapshot(fx) == before
      assert LIA.interactive(fx) == 1
    end

    test "a removal racing a break-glass serialises on lock A: break-glass first allows it, removal first is refused" do
      fx = LIA.on_tenant!("l26c")

      {glass, removal} =
        BG.queue_two!(fx.schema_name, break_glass(fx, :shadow), remove(fx, fx.admin))

      assert {:ok, %{mode: :shadow}} = glass
      assert removal == :ok
      no_deadlock!()

      fx2 = LIA.on_tenant!("l26d")

      {removal2, glass2} =
        BG.queue_two!(fx2.schema_name, remove(fx2, fx2.admin), break_glass(fx2, :shadow))

      assert removal2 == @new
      assert {:ok, %{mode: :shadow}} = glass2
      assert LIA.interactive(fx2) == 1
      no_deadlock!()
    end
  end
end
