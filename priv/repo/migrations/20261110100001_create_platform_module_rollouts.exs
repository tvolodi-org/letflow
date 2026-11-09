# Letflow.Repo.Migrations.CreatePlatformModuleRollouts
#
# RU-S6 (T-1594, decision 0055 fact 10): the fleet driver's global rollout record and its
# per-tenant outcomes.
#
# PLACEMENT: GLOBAL, same rule as 20260921000003_create_platform_migration_rollouts.exs: no
# `prefix()` guard, NOT in @tenant_scoped_migration_manifest, NOT in @expected_tenant_tables.
# No tenant data is stored (ids and codes only). Plain DSL, no SQL interpolation (INV-7).
defmodule Letflow.Repo.Migrations.CreatePlatformModuleRollouts do
  use Ecto.Migration

  def change do
    create table(:platform_module_rollouts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :module_id, :string, size: 255, null: false
      add :to_version, :string, size: 64, null: false
      add :status, :string, size: 16, null: false, default: "running"
      add :halt_after, :integer, null: false
      add :consecutive_failures, :integer, null: false, default: 0
      add :started_by, :binary_id, null: false
      add :started_at, :naive_datetime, null: false
      add :completed_at, :naive_datetime
      add :halted_at, :naive_datetime
    end

    create unique_index(:platform_module_rollouts, [:module_id, :to_version],
             name: :platform_module_rollouts_module_id_to_version_idx
           )

    create table(:platform_module_rollout_outcomes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :rollout_id,
          references(:platform_module_rollouts, type: :binary_id, on_delete: :nothing),
          null: false

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
      add :status, :string, size: 16, null: false, default: "pending"
      add :error_code, :string, size: 64
      add :plan_hash, :string, size: 64
      add :attempted_at, :naive_datetime
      add :completed_at, :naive_datetime
    end

    create unique_index(:platform_module_rollout_outcomes, [:rollout_id, :tenant_id],
             name: :platform_module_rollout_outcomes_rollout_id_tenant_id_idx
           )

    create index(:platform_module_rollout_outcomes, [:rollout_id])
  end
end
