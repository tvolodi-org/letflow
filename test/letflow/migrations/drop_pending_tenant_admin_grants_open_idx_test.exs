defmodule Letflow.Migrations.DropPendingTenantAdminGrantsOpenIdxTest do
  @moduledoc """
  GH #2502: the tenant-scoped migration `20261021000001_drop_pending_tenant_admin_grants_open_idx.exs`
  drops the partial index `pending_tenant_admin_grants_open_idx`, redundant with the unique
  `pending_tenant_admin_grants_email_key_idx` (the state CHECK makes every non-NULL `email_key` an
  open row).

    * a CLONED and a REPLAYED tenant have the unique index and no partial index;
    * the manifest holds the migration (in order, once), with one file on disk and the
      mandatory `if prefix() do` guard;
    * `down` recreates the exact partial index; a replay after `down` drops it again and a
      replay of a migrated tenant is a no-op;
    * the login-path lookup still plans an index scan on the unique index.

  Real Postgres, dedicated tenant schemas, raw DDL: `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_021_000_001
  @file_name "20261021000001_drop_pending_tenant_admin_grants_open_idx.exs"
  @open_idx "pending_tenant_admin_grants_open_idx"
  @unique_idx "pending_tenant_admin_grants_email_key_idx"

  defp migration, do: Module.concat(Letflow.Repo.Migrations, DropPendingTenantAdminGrantsOpenIdx)

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2502-mig")
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  defp migrate(schema, direction) do
    Ecto.Migrator.run(Repo, [{@version, migration()}], direction,
      all: true,
      prefix: schema,
      log: false
    )
  end

  defp index_def(schema, name) do
    case Repo.query!("SELECT indexdef FROM pg_indexes WHERE schemaname = $1 AND indexname = $2", [
           schema,
           name
         ]) do
      %{rows: [[definition]]} -> definition
      %{rows: []} -> nil
    end
  end

  defp assert_dropped(schema) do
    assert index_def(schema, @open_idx) == nil
    assert index_def(schema, @unique_idx) =~ "CREATE UNIQUE INDEX #{@unique_idx}"
  end

  describe "shape" do
    test "a CLONED tenant has the unique index and no partial index", %{schema: schema} do
      assert_dropped(schema)
    end

    test "a REPLAYED tenant (no clone) has the unique index and no partial index" do
      replayed = TenantFixture.provisioned_tenant!(slug_prefix: "gh2502-rep", template: :replay)
      assert_dropped(replayed.schema_name)
    end

    test "the migration is registered in order, once, and the file carries the prefix guard" do
      migrations = TenantProvisioning.tenant_scoped_migrations()
      assert {@version, migration()} in migrations

      versions = Enum.map(migrations, &elem(&1, 0))
      assert versions == Enum.sort(versions)
      assert versions == Enum.uniq(versions)

      on_disk =
        "priv/repo/migrations"
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "20261021000001"))

      assert on_disk == [@file_name]
      assert File.read!(Path.join("priv/repo/migrations", @file_name)) =~ "if prefix() do"
    end
  end

  describe "down and replay" do
    test "down recreates the exact partial index; a replay drops it again; a second replay is a no-op",
         %{schema: schema, tenant_id: tenant_id} do
      assert [@version] == migrate(schema, :down)

      definition = index_def(schema, @open_idx)
      assert definition =~ "CREATE INDEX #{@open_idx}"
      assert definition =~ "(email_key)"
      assert definition =~ "consumed_at IS NULL"
      assert definition =~ "revoked_at IS NULL"

      assert {:ok, [@version]} = TenantProvisioning.replay_migrations(tenant_id)
      assert_dropped(schema)

      assert {:ok, []} = TenantProvisioning.replay_migrations(tenant_id)
      assert_dropped(schema)
    end

    test "up is a no-op when the index is already gone, and down is repeatable", %{schema: schema} do
      assert [@version] == migrate(schema, :down)
      assert [@version] == migrate(schema, :up)
      assert_dropped(schema)

      assert [@version] == migrate(schema, :down)
      Repo.query!(~s|DELETE FROM "#{schema}".schema_migrations WHERE version = $1|, [@version])
      assert [@version] == migrate(schema, :up)
      assert_dropped(schema)
    end
  end

  describe "login-path lookup" do
    test "still plans an index scan on the unique index", %{schema: schema} do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL enable_seqscan = off")

        %{rows: rows} =
          Repo.query!(
            ~s|EXPLAIN SELECT id FROM "#{schema}".pending_tenant_admin_grants | <>
              "WHERE email_key = 'a@b.c' AND consumed_at IS NULL AND revoked_at IS NULL"
          )

        plan = rows |> List.flatten() |> Enum.join("\n")
        assert plan =~ @unique_idx
        refute plan =~ @open_idx
      end)
    end
  end
end
