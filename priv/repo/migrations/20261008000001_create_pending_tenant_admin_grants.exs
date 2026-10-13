# Letflow.Repo.Migrations.CreatePendingTenantAdminGrants
#
# ISS-1030 / Q-1012 / GH #2312, PR 2 -- see
# lib/letflow/design/iss1030-onboarding-administrator.md section 4 for the
# full design this migration implements.
#
# One row per pending administrator grant: the e-mail address of the person the
# platform operator named at onboarding time, waiting to be bound to
# `TENANT_ADMIN` on that person's first verified login through the tenant's own
# realm (Letflow.Identity.PendingAdminGrants.bind_on_login/5).
#
# PLACEMENT: per-tenant. `users` is tenant-scoped, so the `consumed_by_user_id`
# FK below resolves within the same per-tenant schema.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and
# this file's registration in `Letflow.TenantProvisioning`'s
# `@tenant_scoped_migration_manifest` (both halves are mandatory). Existing
# tenants receive the table through the boot-time replay
# (Letflow.TenantProvisioning.MigrationReplayBoot); the table starts empty.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7); the
# only interpolation is the schema name from `prefix()`.
#
# The grant is TENANT_ADMIN only, enforced by the database: `role_name` and
# `created_via` are pinned by CHECK constraints, not just by code. The e-mail
# is held only while the grant is open and is scrubbed to NULL when the grant is
# bound or revoked (data minimisation); the creator's identity is NOT stored here
# (it lives in the platform tenant's audit chain).
defmodule Letflow.Repo.Migrations.CreatePendingTenantAdminGrants do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:pending_tenant_admin_grants, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :email_key, :text
        add :role_name, :text, null: false, default: "TENANT_ADMIN"
        add :created_via, :text, null: false, default: "onboarding"
        add :inserted_at, :utc_datetime_usec, null: false
        add :consumed_at, :utc_datetime_usec

        # on_delete: :nilify_all -- a hard delete of the bound user (an
        # operational erasure) nulls this column instead of being blocked.
        add :consumed_by_user_id,
            references(:users, type: :binary_id, on_delete: :nilify_all)

        add :revoked_at, :utc_datetime_usec
      end

      create unique_index(:pending_tenant_admin_grants, [:email_key],
               name: :pending_tenant_admin_grants_email_key_idx,
               prefix: schema
             )

      # The login-path lookup: an index probe on a tiny table.
      create index(:pending_tenant_admin_grants, [:email_key],
               name: :pending_tenant_admin_grants_open_idx,
               where: "consumed_at IS NULL AND revoked_at IS NULL",
               prefix: schema
             )

      create constraint(:pending_tenant_admin_grants, :pending_tenant_admin_grants_role_name_chk,
               check: "role_name = 'TENANT_ADMIN'",
               prefix: schema
             )

      create constraint(
               :pending_tenant_admin_grants,
               :pending_tenant_admin_grants_created_via_chk,
               check: "created_via = 'onboarding'",
               prefix: schema
             )

      # Row lifecycle: open (consumed_at and revoked_at NULL, e-mail present) ->
      # bound (consumed, e-mail scrubbed) or revoked (e-mail scrubbed); never back.
      create constraint(:pending_tenant_admin_grants, :pending_tenant_admin_grants_state_chk,
               check: """
               NOT (consumed_at IS NOT NULL AND revoked_at IS NOT NULL)
               AND ((consumed_at IS NULL AND revoked_at IS NULL) = (email_key IS NOT NULL))
               AND (consumed_at IS NOT NULL OR consumed_by_user_id IS NULL)
               AND (email_key IS NULL OR (
                 char_length(email_key) BETWEEN 3 AND 254
                 AND email_key = btrim(email_key)
                 AND email_key !~ '[^\\x01-\\x7F]'))
               """,
               prefix: schema
             )
    end
  end
end
