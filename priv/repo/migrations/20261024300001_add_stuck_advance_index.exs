# Letflow.Repo.Migrations.AddStuckAdvanceIndex
#
# GH #2688 / REQ-513 build B2 (design `lib/letflow/design/gh2688-req513-stuck-advance-sweeper.md`
# D11): a partial index on `service_task_dispatches (dispatched_at, id) WHERE status = 'advanced'`
# for the stuck-advance sweep's keyset walk. `advanced` rows are never removed, so without it each
# page would scan a table that grows with every successful HTTP dispatch. The only other index on
# the table is the partial `pending` one of `20260902010001`.
#
# EXISTING ROWS (QA is deployed from `main` by auto-CD): additive and data-free. Every existing
# `advanced` row, in every tenant schema, is indexed by the build; no row is changed and no column
# is added. The sweep itself stays `:off` by default, so nothing lands until an operator sets
# `stuck_advance_mode`. A plain (non-concurrent) build, like its predecessor: the migration runs in
# a transaction and the table is small per tenant.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this file's
# registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`. No new table,
# so `@expected_tenant_tables` is unchanged.
defmodule Letflow.Repo.Migrations.AddStuckAdvanceIndex do
  use Ecto.Migration

  def change do
    if prefix() do
      create index(:service_task_dispatches, [:dispatched_at, :id],
               name: :idx_service_task_dispatches_advanced_dispatched_at,
               where: "status = 'advanced'",
               prefix: prefix()
             )
    end
  end
end
