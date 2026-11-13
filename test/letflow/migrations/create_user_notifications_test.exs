defmodule Letflow.CreateUserNotificationsTest do
  @moduledoc """
  T-1561 (M1, M2): the tenant migration that creates the empty `user_notifications` table: manifest
  registration, shape, replay on an existing tenant, idempotence and rollback.
  `async: false` (tenant provisioning and DDL).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo.Migrations.CreateUserNotifications
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_107_100_001

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1561-mig")
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  defp table?(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables " <>
          "WHERE table_schema = $1 AND table_name = 'user_notifications'",
        [schema]
      )

    n == 1
  end

  defp columns(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'user_notifications'",
        [schema]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  test "M2 registered; the table is in the expected list and starts empty", %{
    schema: schema
  } do
    assert {@version, CreateUserNotifications} =
             List.keyfind(TenantProvisioning.tenant_scoped_migrations(), @version, 0)

    assert "user_notifications" in TenantFixture.expected_tenant_tables()

    assert %{rows: [[0]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".user_notifications|)

    assert columns(schema) ==
             ~w(id inserted_at kind read_at ref_id tenant_id title user_id)

    assert columns("public") == []
  end

  test "M1 replay on an existing tenant that lacks the table creates it; a second replay is a no-op",
       %{schema: schema, tenant_id: tenant_id} do
    Repo.query!(~s|DROP TABLE "#{schema}".user_notifications|)
    Repo.query!(~s|DELETE FROM "#{schema}".schema_migrations WHERE version = $1|, [@version])
    refute table?(schema)

    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
    assert table?(schema)

    %{rows: [[idx]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_indexes WHERE schemaname = $1 AND tablename = 'user_notifications' " <>
          "AND indexname = 'user_notifications_user_inserted_idx'",
        [schema]
      )

    assert idx == 1

    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
    assert table?(schema)
  end

  test "the title CHECK refuses 201 characters and kind has no CHECK", %{schema: schema} do
    insert = fn kind, title ->
      Repo.query(
        ~s|INSERT INTO "#{schema}".user_notifications (id, tenant_id, user_id, kind, title, inserted_at)| <>
          ~s| VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), $1, $2, now())|,
        [kind, title]
      )
    end

    assert {:ok, _} = insert.("some_future_kind", String.duplicate("x", 200))
    assert {:error, _} = insert.("task_assigned", String.duplicate("x", 201))
  end
end
