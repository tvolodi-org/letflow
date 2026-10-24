defmodule Letflow.Definitions.ReactivationTest do
  @moduledoc """
  GH #2692 / REQ-515: the triggers that flag an ACTIVE definition `needs_reactivation`
  (RA-T1..T7, RA-A1, RA-M1). Real Postgres, real writers.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.Reactivation
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Repo

  defp case! do
    ctx = Fx.case!("gh2692-t", [Fx.line("stock_move", %{"label" => %{"var" => "label"}})])
    Map.put(ctx, :definition, reload!(ctx.schema, ctx.definition))
  end

  defp reload!(schema, definition),
    do: Repo.get!(ProcessDefinition, definition.id, prefix: schema)

  defp group!(schema, label) do
    %Group{}
    |> Ecto.Changeset.change(%{name: Fx.unique(label), display_name: label})
    |> Repo.insert!(prefix: schema)
  end

  defp member!(schema, group, user) do
    %GroupMember{}
    |> Ecto.Changeset.change(%{group_id: group.id, user_id: user.id})
    |> Repo.insert!(prefix: schema)
  end

  # A TENANT_ADMIN platform binding with `users` as members.
  defp bind_admin!(schema, users) do
    group = group!(schema, "ra-group")

    role =
      %TenantRole{}
      |> Ecto.Changeset.change(%{name: "TENANT_ADMIN", kind: :platform_role, group_id: group.id})
      |> Repo.insert!(prefix: schema)

    Enum.each(users, &member!(schema, group, &1))
    {group, role}
  end

  defp opts(ctx),
    do: [prefix: ctx.schema, tenant_id: ctx.tenant.tenant_id, login_directory: :skip]

  defp delete_user!(ctx),
    do: Repo.delete_all(from(u in User, where: u.id == ^ctx.user.id), prefix: ctx.schema)

  test "RA-M1: the marker columns exist and the CHECK rejects exactly one NULL" do
    ctx = case!()
    assert ctx.definition.needs_reactivation_at == nil

    assert_raise Postgrex.Error, ~r/needs_reactivation_both_or_none/, fn ->
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^ctx.definition.id),
        [set: [needs_reactivation_reason: "activator_absent"]],
        prefix: ctx.schema
      )
    end
  end

  test "RA-T1: deactivating the activator marks the definition" do
    ctx = case!()

    assert {:ok, _} = Identity.update_user_status(ctx.user.id, :inactive, opts(ctx))

    row = reload!(ctx.schema, ctx.definition)
    assert %DateTime{} = row.needs_reactivation_at
    assert row.needs_reactivation_reason == "activator_deactivated"
    assert row.status == :active
    assert row.sequence_number > ctx.definition.sequence_number
  end

  test "RA-T1: an absent activator is marked by reconcile_user/2; the run-time check still refuses" do
    ctx = case!()
    delete_user!(ctx)

    assert {:ok, [id]} = Reactivation.reconcile_user(ctx.user.id, ctx.schema)
    assert id == ctx.definition.id
    assert reload!(ctx.schema, ctx.definition).needs_reactivation_reason == "activator_absent"

    other = Fx.user!(ctx.schema, "other")

    assert {:error, :entity_write_needs_reactivation} =
             Fx.complete(%{ctx | user: other}, %{"label" => "L"})
  end

  test "RA-T2: removing the activator from the admin group marks lost EntitiesRecordsWrite" do
    ctx = case!()
    second = Fx.user!(ctx.schema, "second-admin")
    {group, _role} = bind_admin!(ctx.schema, [ctx.user, second])

    assert {:ok, []} = Reactivation.reconcile_user(ctx.user.id, ctx.schema)
    assert :ok = Identity.remove_group_member(group.id, ctx.user.id, opts(ctx))

    assert reload!(ctx.schema, ctx.definition).needs_reactivation_reason ==
             "activator_lost_entities_records_write"
  end

  test "RA-T2: rebinding the platform role to another group marks the old members' definitions" do
    ctx = case!()
    second = Fx.user!(ctx.schema, "second-admin")
    {_old_group, role} = bind_admin!(ctx.schema, [ctx.user])
    new_group = group!(ctx.schema, "ra-new")
    member!(ctx.schema, new_group, second)

    assert {:ok, _} =
             Identity.RoleRegistry.rebind_role(
               role.id,
               new_group.id,
               %{actor_id: second.id, reason: "ra-test move"},
               opts(ctx)
             )

    assert reload!(ctx.schema, ctx.definition).needs_reactivation_reason ==
             "activator_lost_entities_records_write"
  end

  test "RA-T3: no mark when the user still holds the permission" do
    ctx = case!()
    second = Fx.user!(ctx.schema, "second-admin")
    {_group, _role} = bind_admin!(ctx.schema, [ctx.user, second])

    assert {:ok, []} = Reactivation.reconcile_user(ctx.user.id, ctx.schema)
    assert reload!(ctx.schema, ctx.definition).needs_reactivation_at == nil
  end

  test "RA-T4: idempotent, the first reason is kept" do
    ctx = case!()
    assert {:ok, _} = Identity.update_user_status(ctx.user.id, :inactive, opts(ctx))
    first = reload!(ctx.schema, ctx.definition)

    delete_user!(ctx)
    assert {:ok, []} = Reactivation.reconcile_user(ctx.user.id, ctx.schema)

    again = reload!(ctx.schema, ctx.definition)
    assert again.needs_reactivation_reason == "activator_deactivated"
    assert again.needs_reactivation_at == first.needs_reactivation_at
    assert again.sequence_number == first.sequence_number
  end

  test "RA-T5: another tenant's definitions are untouched" do
    ctx = case!()
    other = Fx.case!("gh2692-t5", [Fx.line("stock_move", %{"label" => %{"var" => "label"}})])

    # The other tenant's activator id means nothing in this tenant's schema.
    assert {:ok, []} = Reactivation.reconcile_user(other.user.id, ctx.schema)

    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^ctx.user.id),
        [set: [status: :inactive]],
        prefix: ctx.schema
      )

    assert {:ok, [_]} = Reactivation.reconcile_user(ctx.user.id, ctx.schema)
    assert reload!(other.schema, other.definition).needs_reactivation_at == nil
    assert reload!(ctx.schema, ctx.definition).needs_reactivation_at != nil
  end

  test "RA-T7: the mark and its cause are one transaction" do
    ctx = case!()

    result =
      Repo.transaction(fn ->
        {:ok, _} = Identity.update_user_status(ctx.user.id, :inactive, opts(ctx))
        Repo.rollback(:writer_failed)
      end)

    assert result == {:error, :writer_failed}
    assert reload!(ctx.schema, ctx.definition).needs_reactivation_at == nil
  end

  test "RA-A1: marking writes a definition.mark_needs_reactivation audit row with the reason" do
    ctx = case!()
    assert {:ok, _} = Identity.update_user_status(ctx.user.id, :inactive, opts(ctx))

    assert [entry] = Fx.audit_rows(ctx.schema, "definition.mark_needs_reactivation")
    assert entry.resource_id == ctx.definition.id
    assert entry.before_state["needs_reactivation_reason"] == nil
    assert entry.after_state["needs_reactivation_reason"] == "activator_deactivated"
  end

  test "RA-T6: every authority-removing writer calls Reactivation, exempt ones are named" do
    registered = [
      {"lib/letflow/identity.ex", "Reactivation.reconcile_user(updated.id, prefix)"},
      {"lib/letflow/identity.ex", "Reactivation.reconcile_user(user_id, prefix)"},
      {"lib/letflow/identity/role_registry.ex", "Reactivation.reconcile_group(group_id, prefix)"},
      {"lib/letflow/identity/role_registry.ex", "reconcile_group_members!(bound, prefix)"},
      {"lib/letflow/identity/role_registry.ex", "reconcile_group_members!(role.group_id, prefix)"}
    ]

    for {file, call} <- registered do
      assert File.read!(file) =~ call, "#{file} no longer contains #{call}"
    end

    # Writers that cannot remove a member's platform role carry no call: delete_group (memberless
    # group only), IdP sync (adds memberships only), the tenant admin migration (members are
    # copied to TENANT_ADMIN before the legacy binding goes).
  end
end
