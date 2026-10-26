# Letflow.Repo.Migrations.CreateTenantLifecycles
#
# REQ-572 / GH #3252 (decision 0072 D4, slice 1) -- one row per tenant made by the provisioner
# credential (`Letflow.TenantProvisioner`): its lifecycle (active, suspended, expired, deleted), tier,
# language, expiry and the two columns the DELETE/purge slice will write (`deletion_requested_at`,
# `purged_at`; this slice never writes them, so that slice needs no migration).
#
# PLACEMENT: GLOBAL (the public schema, like `tenants`). Not in the tenant-scoped manifest. A tenant
# without a row is invisible to `/admin/v1` (decision 0072 P6). No e-mail column (decision 0048).
# `purged_at`: null until a purge has run; set once, never cleared; a purged tenant keeps its row.
defmodule Letflow.Repo.Migrations.CreateTenantLifecycles do
  use Ecto.Migration

  def change do
    create table(:tenant_lifecycles, primary_key: false) do
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :restrict),
        primary_key: true

      add :lifecycle, :text, null: false
      add :tier, :text, null: false
      add :language, :text, null: false
      add :expires_at, :utc_datetime_usec
      add :deletion_requested_at, :utc_datetime_usec
      add :purged_at, :utc_datetime_usec
      add :owner_grant_stored, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:tenant_lifecycles, :tenant_lifecycles_lifecycle_chk,
             check: "lifecycle IN ('active', 'suspended', 'expired', 'deleted')"
           )

    create constraint(:tenant_lifecycles, :tenant_lifecycles_tier_chk,
             check: "tier IN ('demo', 'production')"
           )

    create constraint(:tenant_lifecycles, :tenant_lifecycles_language_chk,
             check: "language IN ('ru', 'kk', 'en')"
           )
  end
end
