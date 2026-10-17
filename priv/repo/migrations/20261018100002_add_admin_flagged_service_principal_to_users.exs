# Letflow.Repo.Migrations.AddAdminFlaggedServicePrincipalToUsers
#
# REQ-517 / GH #2535 PR 2a (design lib/letflow/design/req517-scoped-grants-admin-plane.md
# section 3.6.2, 3.12).
#
# `users.admin_flagged_service_principal`: set only by an interactive tenant administrator
# through `Letflow.Identity.ServicePrincipal` (the single writer), read by the token mint
# check. NOT NULL DEFAULT false, so existing rows and raw inserts need no backfill.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# Reversible: `change/0` with a single `alter ... add`.
defmodule Letflow.Repo.Migrations.AddAdminFlaggedServicePrincipalToUsers do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:users, prefix: prefix()) do
        add :admin_flagged_service_principal, :boolean, null: false, default: false
      end
    end
  end
end
