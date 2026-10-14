defmodule Letflow.Identity.TenantWideAdminsTest do
  @moduledoc """
  GH 2547 AC3 (design `lib/letflow/design/gh2547-tenant-admin-audit-and-count.md` section 6 and
  the "Contract for #2533 / 7b-2b"): `Identity.count_tenant_wide_admins/1`,
  `Identity.tenant_wide_admin_user_ids/1`, `Identity.tenant_admin_lock_key/1` and
  `Identity.lock_tenant_admins!/1`. Spec: `test/specs/GH-2547.md`, tests T-20..T-28, T-32..T-35.
  REQ-497 PR 1b replaced T-34 with T-X1..T-X5 (spec `test/specs/REQ-497-1b.md`, AC13).

  Real Postgres, real provisioned tenant schemas with the platform roles seeded. Holders are
  written RAW (group_members / api_tokens rows) so the helper is measured against the stored
  state alone, not against any write path it could share code with.

  The lock tests (T-33) use real, separate connections: `TenantFixture.provisioned_tenant!/1`
  leaves the sandbox in `:auto` mode, so every `Task` checks out its own connection. Every wait
  is bounded (`Task.yield/2` with a timeout, a bounded `pg_stat_activity` poll); every task is
  shut down in an `after` block.

  `async: false`: real committed state, cross-connection advisory locks.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.TenantFixture

  # --- fixtures --------------------------------------------------------------------------------

  defp tenant!(slug_prefix) do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: fx.schema_name)
    fx
  end

  defp group_of!(fx, role_name) do
    Repo.one!(
      from(t in TenantRole, where: t.name == ^role_name, select: t.group_id),
      prefix: fx.schema_name
    )
  end

  defp user!(fx, status) do
    n = System.unique_integer([:positive])

    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2547-twa-#{n}",
      display_name: "GH2547 Holder #{n}",
      email: "gh2547-twa-#{n}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: status,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: fx.schema_name)
  end

  defp member!(fx, group_id, %User{} = user) do
    Repo.insert!(%GroupMember{group_id: group_id, user_id: user.id}, prefix: fx.schema_name)
    user
  end

  defp ta_member!(fx, status), do: member!(fx, group_of!(fx, "TENANT_ADMIN"), user!(fx, status))

  # `fields` sets `expires_at` / `revoked_at`; both whole seconds (`:utc_datetime`).
  defp token!(fx, %User{} = user, roles, fields) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        ApiToken,
        Map.merge(
          %{
            user_id: user.id,
            name: "gh2547-token-#{n}",
            token_hash: "gh2547-hash-#{n}-" <> Ecto.UUID.generate(),
            roles: roles,
            expires_at: nil,
            revoked_at: nil
          },
          fields
        )
      ),
      prefix: fx.schema_name
    )

    user
  end

  defp seconds_from_now(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  defp ids(fx), do: Identity.tenant_wide_admin_user_ids(fx.schema_name)
  defp count(fx), do: Identity.count_tenant_wide_admins(fx.schema_name)

  # --- shared: lock-key pins and cross-connection lock helpers --------------------------------

  # Pinned values: SHA-256("letflow:tenant_admin_lock:v1:" <> prefix), first 8 bytes as a
  # signed big-endian int64 (computed outside Elixir when this test was written). A change
  # here means every running node and every new release disagree on the lock: stability
  # across releases is the property being pinned.
  @pinned [
    {"tenant_00000000000000000000000000002547", 8_629_547_307_364_018_795},
    {"tenant_0123456789abcdef0123456789abcdef", 8_120_641_676_504_885_006}
  ]

  @int32_min -2_147_483_648
  @int32_limit 2_147_483_648
  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  # A process that holds `prefix`'s tenant admin lock in an open transaction until told to
  # release it (bounded: it gives up after 10 s on its own).
  defp hold_admin_lock(prefix, parent) do
    Task.async(fn ->
      Repo.transaction(fn ->
        :ok = Identity.lock_tenant_admins!(prefix)
        send(parent, {:admin_lock_held, prefix})

        receive do
          :release -> :ok
        after
          10_000 -> :ok
        end

        Repo.rollback(:released)
      end)
    end)
  end

  # Bounded poll (at most ~5 s): true once a backend waits on a lock while running a
  # statement matching `pattern`.
  defp lock_waiter?(pattern) do
    Enum.reduce_while(1..500, false, fn _attempt, _acc ->
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() " <>
            "AND wait_event_type = 'Lock' AND query ILIKE $1",
          ["%" <> pattern <> "%"]
        )

      if n >= 1 do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end

  # Kills a task only if it is still running (a task already yielded is left alone).
  defp stop_task(%Task{pid: pid} = task) do
    if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  # --- T-20 ------------------------------------------------------------------------------------

  test "T-20 two TENANT_ADMIN members are counted as two distinct users" do
    fx = tenant!("gh2547-t20")
    a = ta_member!(fx, :active)
    b = ta_member!(fx, :active)

    assert count(fx) == 2
    assert ids(fx) == Enum.sort([a.id, b.id])
  end

  # --- T-21 ------------------------------------------------------------------------------------

  test "T-21 an inactive TA member and the inactive owner of a valid TA token are not counted" do
    fx = tenant!("gh2547-t21")
    active = ta_member!(fx, :active)
    _inactive_member = ta_member!(fx, :inactive)
    _inactive_owner = token!(fx, user!(fx, :inactive), ["TENANT_ADMIN"], %{})

    assert count(fx) == 1
    assert ids(fx) == [active.id]
  end

  # --- T-22 ------------------------------------------------------------------------------------

  test "T-22 a revoked or expired TA token does not count; a future or nil expiry does" do
    fx = tenant!("gh2547-t22")

    _revoked =
      token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{revoked_at: seconds_from_now(-60)})

    _expired =
      token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{expires_at: seconds_from_now(-60)})

    future =
      token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{expires_at: seconds_from_now(3_600)})

    never = token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{expires_at: nil})

    assert count(fx) == 2
    assert ids(fx) == Enum.sort([future.id, never.id])
  end

  # --- T-23 ------------------------------------------------------------------------------------

  test "T-23 a token-only admin (no TENANT_ADMIN membership) is counted" do
    fx = tenant!("gh2547-t23")
    holder = token!(fx, user!(fx, :active), ["PROCESS_DESIGNER", "TENANT_ADMIN"], %{})

    assert Repo.all(from(m in GroupMember, where: m.user_id == ^holder.id),
             prefix: fx.schema_name
           ) ==
             []

    assert count(fx) == 1
    assert ids(fx) == [holder.id]
  end

  # --- T-24 ------------------------------------------------------------------------------------

  test "T-24 a user who is a TA member AND owns two live TA tokens is counted once" do
    fx = tenant!("gh2547-t24")
    both = ta_member!(fx, :active)
    token!(fx, both, ["TENANT_ADMIN"], %{})
    token!(fx, both, ["TENANT_ADMIN"], %{expires_at: seconds_from_now(3_600)})

    assert count(fx) == 1
    assert ids(fx) == [both.id]
  end

  # --- T-25 ------------------------------------------------------------------------------------

  describe "T-25 transaction behaviour" do
    test "inside a transaction after lock_tenant_admins!/1 it sees an uncommitted add_group_member" do
      fx = tenant!("gh2547-t25a")
      existing = ta_member!(fx, :active)
      newcomer = user!(fx, :active)
      ta_group = group_of!(fx, "TENANT_ADMIN")

      assert {:error, :probe_done} =
               Repo.transaction(fn ->
                 :ok = Identity.lock_tenant_admins!(fx.schema_name)

                 {:ok, %{created: true}} =
                   Identity.add_group_member(ta_group, newcomer.id, prefix: fx.schema_name)

                 send(self(), {:inside, count(fx), ids(fx)})
                 Repo.rollback(:probe_done)
               end)

      assert_received {:inside, 2, inside_ids}
      assert inside_ids == Enum.sort([existing.id, newcomer.id])

      # Rolled back: the committed state is back to one admin.
      assert count(fx) == 1
      assert ids(fx) == [existing.id]
    end

    test "works after SELECT ... FOR UPDATE on the TENANT_ADMIN tenant_role row in the same transaction" do
      fx = tenant!("gh2547-t25b")
      admin = ta_member!(fx, :active)

      assert {:ok, {1, [id]}} =
               Repo.transaction(fn ->
                 %TenantRole{} =
                   Repo.one!(
                     from(t in TenantRole, where: t.name == "TENANT_ADMIN", lock: "FOR UPDATE"),
                     prefix: fx.schema_name
                   )

                 {count(fx), ids(fx)}
               end)

      assert id == admin.id
    end

    test "outside any transaction it works, opens none, and leaves no advisory lock on its connection" do
      fx = tenant!("gh2547-t25c")
      admin = ta_member!(fx, :active)

      advisory_locks = fn ->
        %{rows: [[n]]} =
          Repo.query!(
            "SELECT count(*) FROM pg_locks WHERE pid = pg_backend_pid() AND locktype = 'advisory'"
          )

        n
      end

      refute Repo.in_transaction?()

      # One pinned connection for the bare call and the probe.
      assert {1, [id], 0} =
               Repo.checkout(fn ->
                 c = count(fx)
                 i = ids(fx)
                 {c, i, advisory_locks.()}
               end)

      assert id == admin.id

      # Control: the same probe DOES see the tenant admin lock when it is held.
      assert {:ok, held} =
               Repo.transaction(fn ->
                 :ok = Identity.lock_tenant_admins!(fx.schema_name)
                 advisory_locks.()
               end)

      assert held >= 1
    end
  end

  # --- T-26 ------------------------------------------------------------------------------------

  test "T-26 non-TA tokens, members of other platform-role groups, a PLATFORM_ADMIN token and a TENANT_ADMIN binding of routing kind are not counted" do
    fx = tenant!("gh2547-t26")

    _designer_token = token!(fx, user!(fx, :active), ["PROCESS_DESIGNER", "TASK_WORKER"], %{})
    _designer_member = member!(fx, group_of!(fx, "PROCESS_DESIGNER"), user!(fx, :active))
    _auditor_member = member!(fx, group_of!(fx, "TENANT_AUDITOR"), user!(fx, :active))
    _platform_admin_token = token!(fx, user!(fx, :active), ["PLATFORM_ADMIN"], %{})

    assert count(fx) == 0
    assert ids(fx) == []

    # A TA member counts while the binding is a platform role, and not once it is a routing role.
    ta_member = ta_member!(fx, :active)
    assert ids(fx) == [ta_member.id]

    {1, _} =
      Repo.update_all(
        from(t in TenantRole, where: t.name == "TENANT_ADMIN"),
        [set: [kind: :process_routing_role]],
        prefix: fx.schema_name
      )

    assert count(fx) == 0
    assert ids(fx) == []
  end

  # --- T-27 ------------------------------------------------------------------------------------

  test "T-27 tenant isolation: B's membership-only and token-only admins never reach A's result" do
    a = tenant!("gh2547-t27a")
    b = tenant!("gh2547-t27b")

    a_admin = ta_member!(a, :active)
    b_member_admin = ta_member!(b, :active)
    b_token_admin = token!(b, user!(b, :active), ["TENANT_ADMIN"], %{})

    assert count(a) == 1
    assert ids(a) == [a_admin.id]
    refute b_member_admin.id in ids(a)
    refute b_token_admin.id in ids(a)

    assert count(b) == 2
    assert ids(b) == Enum.sort([b_member_admin.id, b_token_admin.id])
    refute a_admin.id in ids(b)
  end

  # --- T-28 ------------------------------------------------------------------------------------

  test "T-28 tenant_wide_admin_user_ids/1 is sorted ascending and is exactly the set behind the count" do
    fx = tenant!("gh2547-t28")

    expected =
      [
        ta_member!(fx, :active),
        ta_member!(fx, :active),
        token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{}),
        token!(fx, ta_member!(fx, :active), ["TENANT_ADMIN"], %{}),
        token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{expires_at: seconds_from_now(600)})
      ]
      |> Enum.map(& &1.id)

    result = ids(fx)

    assert result == Enum.sort(result)
    assert result == Enum.uniq(result)
    assert MapSet.new(result) == MapSet.new(expected)
    assert count(fx) == length(result)
    assert count(fx) == 5
  end

  # --- T-32 ------------------------------------------------------------------------------------

  describe "T-32 tenant_admin_lock_key/1" do
    test "is stable across calls and equals the pinned value" do
      for {prefix, expected} <- @pinned do
        keys = for _ <- 1..3, do: Identity.tenant_admin_lock_key(prefix)
        assert keys == [expected, expected, expected], prefix
      end
    end

    test "differs for two tenant schemas" do
      [{p1, _}, {p2, _}] = @pinned
      refute Identity.tenant_admin_lock_key(p1) == Identity.tenant_admin_lock_key(p2)
    end

    test "for 1,000 generated tenant schema names every key is a distinct int64 outside [-2^31, 2^31)" do
      keys =
        for i <- 1..1_000 do
          hex = :crypto.hash(:md5, "gh2547-lock-key-#{i}") |> Base.encode16(case: :lower)
          Identity.tenant_admin_lock_key("tenant_" <> hex)
        end

      assert Enum.all?(keys, &is_integer/1)
      assert Enum.all?(keys, &(&1 >= @int64_min and &1 <= @int64_max))
      assert Enum.all?(keys, &(&1 < @int32_min or &1 >= @int32_limit))
      assert length(Enum.uniq(keys)) == 1_000
    end
  end

  # --- T-33 ------------------------------------------------------------------------------------

  describe "T-33 lock_tenant_admins!/1" do
    test "a held lock blocks add_group_member/3 to the TA group until it is released" do
      fx = tenant!("gh2547-t33a")
      user = user!(fx, :active)
      ta_group = group_of!(fx, "TENANT_ADMIN")

      holder = hold_admin_lock(fx.schema_name, self())
      assert_receive {:admin_lock_held, _prefix}, 5_000

      adder =
        Task.async(fn -> Identity.add_group_member(ta_group, user.id, prefix: fx.schema_name) end)

      try do
        assert lock_waiter?("pg_advisory_xact_lock"),
               "add_group_member/3 never queued on the lock"

        assert Task.yield(adder, 300) == nil

        send(holder.pid, :release)
        assert {:ok, {:error, :released}} = Task.yield(holder, 5_000)

        assert {:ok, {:ok, %{created: true}}} = Task.yield(adder, 5_000)
        assert user.id in ids(fx)
      after
        stop_task(adder)
        stop_task(holder)
      end
    end

    test "control: the lock of ANOTHER tenant does not block add_group_member/3" do
      fx = tenant!("gh2547-t33b")
      other = tenant!("gh2547-t33c")
      user = user!(fx, :active)
      ta_group = group_of!(fx, "TENANT_ADMIN")

      holder = hold_admin_lock(other.schema_name, self())
      assert_receive {:admin_lock_held, _prefix}, 5_000

      adder =
        Task.async(fn -> Identity.add_group_member(ta_group, user.id, prefix: fx.schema_name) end)

      try do
        # Returns while the other tenant's lock is still held.
        assert {:ok, {:ok, %{created: true}}} = Task.yield(adder, 5_000)
        assert Process.alive?(holder.pid)
      after
        send(holder.pid, :release)
        stop_task(adder)
        _ = Task.yield(holder, 5_000)
        stop_task(holder)
      end
    end

    test "raises ArgumentError outside a transaction; is re-entrant inside one" do
      fx = tenant!("gh2547-t33d")

      refute Repo.in_transaction?()

      assert_raise ArgumentError, "lock_tenant_admins!/1 must run inside a transaction", fn ->
        Identity.lock_tenant_admins!(fx.schema_name)
      end

      started = System.monotonic_time(:millisecond)

      assert {:ok, [:ok, :ok]} =
               Repo.transaction(fn ->
                 [
                   Identity.lock_tenant_admins!(fx.schema_name),
                   Identity.lock_tenant_admins!(fx.schema_name)
                 ]
               end)

      assert System.monotonic_time(:millisecond) - started < 5_000
    end
  end

  # --- T-X1..T-X5 (REQ-497 PR 1b, AC13; replace the 1a T-34 tripwire) ------------------------
  #
  # `exclude_scoped_holders/2` is filled in (design req497-1b 5.1): a TA group member whose
  # TENANT_ADMIN rows (user or group) are ALL scoped is no longer counted; a TA token owner is
  # never dropped; a binding with zero rows is still counted in stage 1 (OQ-4). Scoped and user
  # rows are inserted RAW (no route writes one in stage 1).

  describe "T-X exclude_scoped_holders/2 and exclude_scoped_role_names/3" do
    test "T-X1 a TA member whose TA group holds only a scoped row is not counted" do
      fx = tenant!("req497-tx1")
      ta_group = group_of!(fx, "TENANT_ADMIN")
      other = ta_member!(fx, :active)
      scoped_only = ta_member!(fx, :active)

      # Control: both counted while the TA group has its tenant-wide row.
      assert ids(fx) == Enum.sort([other.id, scoped_only.id])

      _node = RSG.make_group_scoped_only!(fx.schema_name, ta_group, "TENANT_ADMIN")

      # Same group, so both members drop: the rule is per (user, group) source.
      assert count(fx) == 0
      assert ids(fx) == []
    end

    test "T-X2 the same scoped-only member who also owns a live TA token is counted" do
      fx = tenant!("req497-tx2")
      ta_group = group_of!(fx, "TENANT_ADMIN")
      member_only = ta_member!(fx, :active)
      token_owner = token!(fx, ta_member!(fx, :active), ["TENANT_ADMIN"], %{})

      _node = RSG.make_group_scoped_only!(fx.schema_name, ta_group, "TENANT_ADMIN")

      assert ids(fx) == [token_owner.id]
      assert count(fx) == 1
      refute member_only.id in ids(fx)
    end

    test "T-X3 a tenant-wide USER row for TENANT_ADMIN keeps a member whose group row is scoped" do
      fx = tenant!("req497-tx3")
      ta_group = group_of!(fx, "TENANT_ADMIN")
      with_user_row = ta_member!(fx, :active)
      without = ta_member!(fx, :active)

      _node = RSG.make_group_scoped_only!(fx.schema_name, ta_group, "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(fx.schema_name, with_user_row.id, "TENANT_ADMIN", nil)

      assert ids(fx) == [with_user_row.id]
      assert count(fx) == 1
      refute without.id in ids(fx)

      # A SCOPED user row on top of the scoped group row changes nothing for `without`.
      :ok =
        RSG.raw_user_row!(fx.schema_name, without.id, "TENANT_ADMIN", RSG.node!(fx.schema_name))

      assert ids(fx) == [with_user_row.id]
    end

    test "T-X4 with only tenant-wide rows the result equals the oracle; a TA binding with zero rows is still counted" do
      fx = tenant!("req497-tx4")
      ta_group = group_of!(fx, "TENANT_ADMIN")

      # {user, active?, TA member?, owns a live TA token?} -- the T-35 oracle shape.
      holders = [
        {member!(fx, ta_group, user!(fx, :active)), true, true, false},
        {token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{}), true, false, true},
        {member!(fx, ta_group, user!(fx, :inactive)), false, true, false}
      ]

      oracle =
        for {user, active?, member?, live_token?} <- holders,
            active? and (member? or live_token?),
            do: user.id

      %{rows: [[scoped]]} =
        Repo.query!(
          "SELECT count(*) FROM \"#{fx.schema_name}\".role_scope_grants WHERE NOT tenant_wide",
          []
        )

      assert scoped == 0
      assert RSG.rows(fx.schema_name) |> Enum.member?(RSG.tw(ta_group, "TENANT_ADMIN"))
      assert length(oracle) == 2
      assert ids(fx) == Enum.sort(oracle)
      assert count(fx) == length(oracle)

      # Zero rows for the TA binding (a T9 gap): stage 1 still counts the member (OQ-4).
      assert RSG.raw_delete_rows!(fx.schema_name, ta_group, "TENANT_ADMIN") == 1
      assert ids(fx) == Enum.sort(oracle)
      assert count(fx) == length(oracle)
    end

    test "T-X5 tenant_wide_role_names/2 drops a role held only through a scoped row and keeps it with a tenant-wide row" do
      fx = tenant!("req497-tx5")
      designer_group = group_of!(fx, "PROCESS_DESIGNER")
      user = member!(fx, designer_group, user!(fx, :active))

      assert "PROCESS_DESIGNER" in Identity.tenant_wide_role_names(user.id, prefix: fx.schema_name)

      _node = RSG.make_group_scoped_only!(fx.schema_name, designer_group, "PROCESS_DESIGNER")

      refute "PROCESS_DESIGNER" in Identity.tenant_wide_role_names(user.id,
               prefix: fx.schema_name
             )

      # A tenant-wide row (here a user row) brings it back.
      :ok = RSG.raw_user_row!(fx.schema_name, user.id, "PROCESS_DESIGNER", nil)
      assert "PROCESS_DESIGNER" in Identity.tenant_wide_role_names(user.id, prefix: fx.schema_name)

      # Per role: another held role with its tenant-wide group row is unaffected.
      _ = member!(fx, group_of!(fx, "TENANT_ADMIN"), user)
      names = Identity.tenant_wide_role_names(user.id, prefix: fx.schema_name)
      assert MapSet.subset?(MapSet.new(["PROCESS_DESIGNER", "TENANT_ADMIN"]), names)
    end
  end

  # --- T-35 ------------------------------------------------------------------------------------

  test "T-35 with one holder of every kind the result equals an oracle computed from the fixture's own definition" do
    fx = tenant!("gh2547-t35")
    ta_group = group_of!(fx, "TENANT_ADMIN")
    designer_group = group_of!(fx, "PROCESS_DESIGNER")

    # {user, active?, TA member?, owns a live TA token?} -- written down as the fixture is built.
    holders = [
      {member!(fx, ta_group, user!(fx, :active)), true, true, false},
      {token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{}), true, false, true},
      {token!(fx, member!(fx, ta_group, user!(fx, :active)), ["TENANT_ADMIN"], %{}), true, true,
       true},
      {member!(fx, ta_group, user!(fx, :inactive)), false, true, false},
      {token!(fx, user!(fx, :inactive), ["TENANT_ADMIN"], %{}), false, false, true},
      {token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{revoked_at: seconds_from_now(-5)}),
       true, false, false},
      {token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{expires_at: seconds_from_now(-5)}),
       true, false, false},
      {member!(fx, designer_group, user!(fx, :active)), true, false, false},
      {token!(fx, user!(fx, :active), ["PLATFORM_ADMIN"], %{}), true, false, false}
    ]

    oracle =
      for {user, active?, member?, live_token?} <- holders,
          active? and (member? or live_token?),
          do: user.id

    assert length(oracle) == 3
    assert ids(fx) == Enum.sort(oracle)
    assert count(fx) == length(oracle)
  end
end
