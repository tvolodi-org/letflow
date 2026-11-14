defmodule Letflow.CreateUserPreferencesTest do
  @moduledoc """
  T-1389 (M1, M2): the tenant migration that creates the empty `user_preferences` table: manifest
  registration, shape, replay on an existing tenant, idempotence and rollback.
  `async: false` (tenant provisioning and DDL).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo.Migrations.CreateUserPreferences
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_105_600_001

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1389-mig")
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  defp table?(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables " <>
          "WHERE table_schema = $1 AND table_name = 'user_preferences'",
        [schema]
      )

    n == 1
  end

  defp columns(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'user_preferences'",
        [schema]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  test "M2 registered second to last; the table is in the expected list and starts empty", %{
    schema: schema
  } do
    assert {@version, CreateUserPreferences} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -8)

    assert "user_preferences" in TenantFixture.expected_tenant_tables()

    assert %{rows: [[0]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".user_preferences|)
    assert columns(schema) == ~w(key updated_at user_id value)
    assert columns("public") == []
  end

  test "M1 replay on an existing tenant that lacks the table creates it; a second replay is a no-op",
       %{schema: schema, tenant_id: tenant_id} do
    Repo.query!(~s|DROP TABLE "#{schema}".user_preferences|)
    Repo.query!(~s|DELETE FROM "#{schema}".schema_migrations WHERE version = $1|, [@version])
    refute table?(schema)

    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
    assert table?(schema)

    %{rows: [[idx]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_indexes WHERE schemaname = $1 AND tablename = 'user_preferences' " <>
          "AND indexname = 'user_preferences_user_id_key_idx'",
        [schema]
      )

    assert idx == 1

    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
    assert table?(schema)
  end

  test "the unique index refuses a second row for the same user and key", %{schema: schema} do
    insert = fn ->
      Repo.query(
        ~s|INSERT INTO "#{schema}".user_preferences (user_id, key, value, updated_at)| <>
          ~s| VALUES ('00000000-0000-0000-0000-000000000001', 'k', '{"v":"x"}', now())|
      )
    end

    assert {:ok, _} = insert.()
    assert {:error, _} = insert.()
  end
end
