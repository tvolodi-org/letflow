defmodule Letflow.Test.RoleScopeGrantsGapMigration do
  @moduledoc """
  Test-only migration for REQ-497 / GH #2533 PR 1a, design
  `lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md` section 6.1 T-M2b
  (`test/letflow/identity/role_scope_grants_migration_test.exs`): proves that a non-zero T9 count
  inside the real migration transaction aborts the WHOLE migration (table, rows and audit entry
  rolled back, version not recorded).

  `up/0` runs the real `CreateRoleScopeGrants` building blocks in the real order (lock A, the DDL,
  then the real `run_backfill!/1`, i.e. insert + assert + audit), then deletes one grant row to
  open a gap, then calls the real `assert_no_gap!/1`, which must raise.

  Version `99_991_015_025_331` (grep-checked unique). It must never be added to
  `Letflow.TenantProvisioning.tenant_scoped_migrations/0` or to `priv/repo/migrations/`. Guarded
  by `if prefix()`, so it is a no-op without a tenant prefix.
  """

  use Ecto.Migration

  @spec up() :: any()
  def up do
    if prefix() do
      schema = prefix()
      # Named dynamically: the migration module is loaded at run time, not compiled in.
      migration = Letflow.Support.RoleScopeGrantsFixture.migration()

      execute(fn -> migration.lock_tenant_admins_in_migration!(schema) end)
      migration.create_objects(schema)

      execute(fn ->
        _counts = migration.run_backfill!(schema)

        Letflow.Repo.query!(
          ~s|DELETE FROM "#{schema}".role_scope_grants | <>
            ~s|WHERE id = (SELECT id FROM "#{schema}".role_scope_grants ORDER BY role LIMIT 1)|
        )

        migration.assert_no_gap!(schema)
      end)
    end
  end

  @spec down() :: any()
  def down, do: :ok
end
