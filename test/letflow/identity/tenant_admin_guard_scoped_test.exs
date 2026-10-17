defmodule Letflow.Identity.TenantAdminGuardScopedTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2a, AC 8 at FUNCTION level (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` sections 3.9; spec
  `test/specs/REQ-517-2a.md`, T-Z2, T-Z4, T-Z6, T-Z7): the two new `TenantAdminGuard` actions
  `scope_tenant_admin` and `revoke_tenant_admin_grant` and the counter option.

  `scope_tenant_admin` is unreachable over HTTP (the create route refuses a scoped row while a
  tenant-wide row exists, step 8, before the guard), so it is exercised here the way the route
  would: inside a transaction under lock A, count BEFORE with the explicit counter, write, then
  `ensure_admins_remain!/5` with `:explicit`, and `refuse/3` after the rollback (coordinator
  amendment: the explicit count, not the design 3.9 counted default).

  `async: false`: committed writes.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.TenantAdminGuard
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @admin_role "TENANT_ADMIN"
  @event "tenant_admin.guard_refused"

  defp ctx(fx), do: %{actor_id: fx.admin.id, trace_id: S.trace()}

  defp assert_refusal_event!(fx, action, target_id) do
    assert [entry] = S.entries(fx, @event)
    assert entry.resource_type == "role_scope_grant"
    assert entry.resource_id == target_id
    assert entry.actor_id == fx.admin.id
    assert entry.trace_id == S.trace()

    assert entry.after_state |> Map.keys() |> Enum.sort() ==
             ~w(action actor counted_admins reason_code target_id trace_id)

    assert entry.after_state == %{
             "action" => action,
             "actor" => fx.admin.id,
             "target_id" => target_id,
             "reason_code" => "last_tenant_wide_admin",
             "counted_admins" => 0,
             "trace_id" => S.trace()
           }

    assert {:ok, :valid} = Audit.verify_chain(fx.schema_name)
  end

  # Runs the guard exactly as the route would, with `write` standing in for the guarded write.
  defp guarded(fx, action, target_id, counter, write) do
    s = fx.schema_name

    Repo.transaction(
      fn ->
        Identity.lock_tenant_admins!(s)
        before_count = TenantAdminGuard.count_before!(s, counter)
        write.()
        TenantAdminGuard.ensure_admins_remain!(s, action, target_id, before_count, counter)
      end,
      prefix: s
    )
  end

  test "T-Z2 scope_tenant_admin: a write that leaves no explicit administrator rolls back with the refusal; refuse/3 records the event (resource_type role_scope_grant)" do
    fx = S.tenant!("r517-zg-scope")
    s = fx.schema_name
    ga = RSG.group_of!(s, @admin_role)
    [row] = for r <- RSG.group_structs(s, ga), r.role == @admin_role, do: r
    before = RSG.rows(s)

    assert {:error, {:tenant_admin_guard, refusal}} =
             guarded(fx, :scope_tenant_admin, ga, :explicit, fn ->
               :ok = RoleScopeGrants.delete_row!(row.id, s)
             end)

    assert refusal == %{action: :scope_tenant_admin, target_id: ga, counted_admins: 0}
    assert RSG.rows(s) == before

    assert {:error, :last_tenant_wide_admin} = TenantAdminGuard.refuse(s, refusal, ctx(fx))
    assert_refusal_event!(fx, "scope_tenant_admin", ga)
  end

  test "T-Z2 scope_tenant_admin counts EXPLICIT administrators: from a zero-row binding (before = 0) the transition is not refused" do
    fx = S.tenant!("r517-zg-scope-zero")
    s = fx.schema_name
    ga = RSG.group_of!(s, @admin_role)
    _ = RSG.raw_delete_rows!(s, ga, @admin_role)
    assert Identity.count_explicit_tenant_wide_admins(s) == 0

    assert {:ok, :ok} =
             guarded(fx, :scope_tenant_admin, ga, :explicit, fn ->
               :ok = RSG.raw_scoped_row!(s, ga, @admin_role, RSG.node!(s))
             end)

    assert S.entries(fx, @event) == []
  end

  test "T-Z4 revoke_tenant_admin_grant: refuse/3 records resource_type role_scope_grant and the event is in the verified chain" do
    fx = S.tenant!("r517-zg-revoke")
    target = Ecto.UUID.generate()

    refusal = %{action: :revoke_tenant_admin_grant, target_id: target, counted_admins: 0}

    assert {:error, :last_tenant_wide_admin} =
             TenantAdminGuard.refuse(fx.schema_name, refusal, ctx(fx))

    assert_refusal_event!(fx, "revoke_tenant_admin_grant", target)
  end

  test "both new actions are accepted by ensure_admins_remain!/5 and the existing arities still delegate with :counted" do
    fx = S.tenant!("r517-zg-arity")
    s = fx.schema_name

    assert {:ok, :ok} =
             Repo.transaction(
               fn ->
                 assert TenantAdminGuard.count_before!(s) ==
                          TenantAdminGuard.count_before!(s, :counted)

                 assert TenantAdminGuard.count_before!(s) == 1

                 for action <- [:scope_tenant_admin, :revoke_tenant_admin_grant] do
                   assert :ok =
                            TenantAdminGuard.ensure_admins_remain!(s, action, "t", 1, :explicit)

                   assert :ok = TenantAdminGuard.ensure_admins_remain!(s, action, "t", 1)

                   assert :ok =
                            TenantAdminGuard.ensure_admins_remain!(s, action, "t", 0, :explicit)
                 end

                 :ok
               end,
               prefix: s
             )
  end

  test "the counter functions raise ArgumentError outside a transaction" do
    fx = S.tenant!("r517-zg-outside")
    s = fx.schema_name

    assert_raise ArgumentError, fn -> TenantAdminGuard.count_before!(s, :explicit) end

    assert_raise ArgumentError, fn ->
      TenantAdminGuard.ensure_admins_remain!(s, :scope_tenant_admin, "t", 1, :explicit)
    end
  end

  test "T-Z6 the counters differ exactly on a zero-row binding and agree otherwise (T-Z7)" do
    fx = S.tenant!("r517-zg-counts")
    s = fx.schema_name
    ga = RSG.group_of!(s, @admin_role)

    agree? = fn ->
      Identity.count_tenant_wide_admins(s) == Identity.count_explicit_tenant_wide_admins(s)
    end

    assert agree?.()

    # a scoped-only group: both drop the member
    _ = RSG.raw_delete_rows!(s, ga, @admin_role)
    :ok = RSG.raw_scoped_row!(s, ga, @admin_role, RSG.node!(s))
    assert agree?.()
    assert Identity.count_explicit_tenant_wide_admins(s) == 0

    # a zero-row binding: only the counted definition still counts the member
    _ = RSG.raw_delete_rows!(s, ga, @admin_role)
    assert Identity.count_tenant_wide_admins(s) == 1
    assert Identity.count_explicit_tenant_wide_admins(s) == 0
    refute agree?.()

    # a tenant-wide USER row for a member makes them explicit again
    member = RSG.member!(s, ga, RSG.user!(s))
    :ok = RSG.raw_user_row!(s, member.id, @admin_role, nil)
    assert Identity.count_explicit_tenant_wide_admins(s) == 1
  end
end
