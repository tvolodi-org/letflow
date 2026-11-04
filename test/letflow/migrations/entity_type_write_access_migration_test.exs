defmodule Letflow.Migrations.EntityTypeWriteAccessMigrationTest do
  @moduledoc "REQ-577 / GH #3261 (W11): the two write-access tables, their registration and indexes."

  use Letflow.DataCase, async: false

  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    :ok
  end

  test "the migration is in the tenant manifest and the tables in the expected list" do
    assert Enum.any?(Letflow.TenantProvisioning.tenant_scoped_migrations(), fn {version, mod} ->
             version == 20_261_105_100_001 and
               mod == Letflow.Repo.Migrations.CreateEntityTypeWriteAccessTables
           end)

    tables = TenantFixture.expected_tenant_tables()
    assert "entity_type_write_restrictions" in tables
    assert "user_entity_type_write_grants" in tables
  end

  test "unique indexes reject duplicates and the user FK is enforced" do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req577-mig")
    schema = tenant.schema_name
    now = NaiveDateTime.utc_now()

    row = fn ->
      %{id: Ecto.UUID.bingenerate(), entity_type: "t", inserted_at: now, updated_at: now}
    end

    Repo.insert_all("entity_type_write_restrictions", [row.()], prefix: schema)

    assert_raise Postgrex.Error, ~r/unique|duplicate/i, fn ->
      Repo.insert_all("entity_type_write_restrictions", [row.()], prefix: schema)
    end

    grant = %{
      id: Ecto.UUID.bingenerate(),
      user_id: Ecto.UUID.bingenerate(),
      entity_type: "t",
      inserted_at: now
    }

    assert_raise Postgrex.Error, ~r/foreign key/i, fn ->
      Repo.insert_all("user_entity_type_write_grants", [grant], prefix: schema)
    end
  end
end
