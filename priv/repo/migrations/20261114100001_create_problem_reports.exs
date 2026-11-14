# Letflow.Repo.Migrations.CreateProblemReports
#
# T-1948 -- maintenance slice 1 (docs/design/platform-maintenance.md): the "Report a problem" store.
# Table `problem_reports`, one row per report a user chose to send to the platform company.
#
# PLACEMENT: per-tenant (schema-per-tenant via `prefix()`), so the table exists in EVERY company schema,
# but code writes it ONLY in the platform company's schema (`Letflow.PlatformTenant.platform_prefix/0`).
# Customer text therefore stays behind a schema prefix (INV-1); the tables of other companies stay empty.
# `tenant_id` is the owner of the row (the platform tenant); `reporter_tenant_id` is the reporting company.
# No foreign keys: users and tenants are public-schema rows (same reason as `user_notifications`).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered in
# `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7). `context` has NO CHECK on its keys:
# the closed list lives in `Letflow.ProblemReports.Capture`. The table starts empty; nothing to backfill.
defmodule Letflow.Repo.Migrations.CreateProblemReports do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:problem_reports, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :seq, :bigserial, null: false
        add :tenant_id, :binary_id, null: false
        add :reporter_tenant_id, :binary_id, null: false
        add :reporter_tenant_name, :string, size: 200
        add :reporter_user_id, :binary_id, null: false
        add :reporter_name, :string, size: 200
        add :reporter_roles, {:array, :string}, null: false, default: []
        add :reporter_permissions, {:array, :string}, null: false, default: []
        add :text, :text, null: false
        add :context, :map, null: false, default: %{}
        add :server_version, :string, size: 64
        add :trace_id, :string, size: 64
        add :consented_at, :utc_datetime_usec, null: false

        timestamps(type: :utc_datetime_usec, updated_at: false)
      end

      create unique_index(:problem_reports, [:seq], prefix: schema)

      create index(:problem_reports, [:reporter_user_id, :inserted_at], prefix: schema)

      create constraint(:problem_reports, :problem_reports_text_len,
               check: "char_length(text) BETWEEN 1 AND 4000",
               prefix: schema
             )
    end
  end
end
