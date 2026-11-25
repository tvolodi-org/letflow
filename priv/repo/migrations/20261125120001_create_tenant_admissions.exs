# Letflow.Repo.Migrations.CreateTenantAdmissions
#
# T-2727 (pilot gap G17c; docs/platform-register-tenant-v2.md section 5) -- the ADMISSION row of a
# provisioner/signup create that runs through the `platform.register_tenant` definition: the demo cap and
# the two daily budgets are reserved here, in front of the definition, and `tenant.record_lifecycle` turns
# the reservation into the `tenant_lifecycles` row once the tenant row exists.
#
# PLACEMENT: GLOBAL (the public schema, next to `tenant_lifecycles`). Not in the tenant-scoped manifest.
# No foreign key: the tenant does not exist yet when the row is written. No raw e-mail, no raw source value,
# no realm, no name: digests only, as in `tenant_lifecycles`.
defmodule Letflow.Repo.Migrations.CreateTenantAdmissions do
  use Ecto.Migration

  def change do
    create table(:tenant_admissions, primary_key: false) do
      add :tenant_id, :binary_id, primary_key: true
      add :tier, :text, null: false
      add :language, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :source_ip_key, :binary
      add :email_domain_key, :binary, null: false
      add :request_fingerprint, :binary, null: false
      add :instance_id, :binary_id

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:tenant_admissions, :tenant_admissions_tier_chk,
             check: "tier IN ('demo', 'production')"
           )

    create constraint(:tenant_admissions, :tenant_admissions_language_chk,
             check: "language IN ('ru', 'kk', 'en')"
           )
  end
end
