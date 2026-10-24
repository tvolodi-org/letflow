defmodule Letflow.Engine.ReactivationHumanTest do
  @moduledoc """
  GH #2692 / REQ-515, HUMAN path (RA-H1..H3): a definition flagged `needs_reactivation`
  refuses the entity-write completion (task stays pending), and an in-place `reactivate` heals
  the SAME pending task. Real activation, real engine, real Postgres.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Identity
  alias Letflow.Repo

  defp case! do
    ctx = Fx.case!("gh2692-h", [Fx.line("stock_move", %{"label" => %{"var" => "label"}})])
    :ok = Letflow.SodSupport.grant_role!(ctx.schema, "REVIEWER", [ctx.user.id])
    ctx
  end

  defp deactivate!(ctx) do
    assert {:ok, _} =
             Identity.update_user_status(ctx.user.id, :inactive,
               prefix: ctx.schema,
               tenant_id: ctx.tenant.tenant_id,
               login_directory: :skip
             )
  end

  defp reactivate(ctx) do
    admin = Fx.user!(ctx.schema, "new-activator")

    activator =
      Activator.from_auth_context(%{user_id: admin.id, roles: ["TENANT_ADMIN"]}, false)

    {admin, Definitions.reactivate(ctx.definition.id, prefix: ctx.schema, activator: activator)}
  end

  test "RA-H1: deactivating the activator marks the definition and keeps the task pending" do
    ctx = case!()
    deactivate!(ctx)

    row = Repo.get!(ProcessDefinition, ctx.definition.id, prefix: ctx.schema)
    assert row.needs_reactivation_reason == "activator_deactivated"
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
  end

  test "RA-H2: completing on a flagged definition is refused, task pending, no record" do
    ctx = case!()
    deactivate!(ctx)

    assert {:error, :entity_write_needs_reactivation} = Fx.complete(ctx, %{"label" => "L1"})
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
    assert Fx.all_records(ctx.schema) == []
  end

  test "RA-H3: reactivate by a current activator heals the SAME pending task" do
    ctx = case!()
    deactivate!(ctx)
    assert {:error, :entity_write_needs_reactivation} = Fx.complete(ctx, %{"label" => "L1"})

    {admin, {:ok, row}} = reactivate(ctx)
    assert row.needs_reactivation_at == nil
    assert row.needs_reactivation_reason == nil
    assert row.activated_by["user_id"] == admin.id

    assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
    assert Fx.task!(ctx.schema, ctx.task.id).status == :completed
    assert [_record] = Fx.all_records(ctx.schema)
    assert [_] = Fx.audit_rows(ctx.schema, "definition.reactivate")
  end

  test "RA-H3: reactivate is refused for an unflagged row and for a caller without the permission" do
    ctx = case!()
    admin = Fx.user!(ctx.schema, "new-activator")
    ok = Activator.from_auth_context(%{user_id: admin.id, roles: ["TENANT_ADMIN"]}, false)

    assert {:error, :not_needs_reactivation} =
             Definitions.reactivate(ctx.definition.id, prefix: ctx.schema, activator: ok)

    deactivate!(ctx)
    no_write = Activator.from_auth_context(%{user_id: admin.id, roles: ["TENANT_AUDITOR"]}, false)

    assert {:error, {:entity_writes_invalid, _}} =
             Definitions.reactivate(ctx.definition.id, prefix: ctx.schema, activator: no_write)

    assert {:error, {:entity_writes_invalid, _}} =
             Definitions.reactivate(ctx.definition.id, prefix: ctx.schema, activator: nil)

    assert {:error, :not_found} =
             Definitions.reactivate(Ecto.UUID.generate(), prefix: ctx.schema, activator: ok)
  end
end
