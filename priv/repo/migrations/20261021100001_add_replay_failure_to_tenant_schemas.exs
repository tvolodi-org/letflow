defmodule Letflow.Repo.Migrations.AddReplayFailureToTenantSchemas do
  @moduledoc """
  GH #2727: a queryable signal for a failed boot-time tenant migration replay.
  Global (public) table, so this migration is NOT in `tenant_scoped_migrations/0`.
  Both columns nil = the tenant's last replay succeeded. Column order matters:
  test/letflow/identity_migration_test.exs mirrors this table positionally.
  """
  use Ecto.Migration

  def change do
    alter table(:tenant_schemas) do
      add :migration_replay_failed_at, :naive_datetime, null: true
      add :migration_replay_failure_code, :string, null: true
    end
  end
end
