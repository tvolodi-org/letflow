# Letflow.Repo.Migrations.CreateErrorGroups
#
# T-1951 -- maintenance slice 3 (docs/design/platform-maintenance.md section 2.5): grouped error signatures.
# Table `error_groups`, one row per signature (type + top frame + route), with counters, the affected companies
# (distinct ids, at most 100) and the last 5 trace ids.
#
# PLACEMENT: per-tenant (schema-per-tenant via `prefix()`), so the table exists in EVERY company schema, but code
# writes it ONLY in the platform company's schema (`Letflow.PlatformTenant.platform_prefix/0`), exactly as
# `problem_reports`. `tenant_id` is the owner of the row (the platform tenant). No foreign keys: tenants are
# public-schema rows. No exception message, no user text, no ids of users are stored.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered in
# `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7). The table starts empty; nothing to backfill.
defmodule Letflow.Repo.Migrations.CreateErrorGroups do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:error_groups, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :seq, :bigserial, null: false
        add :tenant_id, :binary_id, null: false
        add :signature, :string, size: 64, null: false
        add :source, :string, size: 8, null: false
        add :kind, :string, size: 16, null: false
        add :method, :string, size: 8, null: false
        add :route, :string, size: 200, null: false
        add :error_type, :string, size: 200, null: false
        add :top_frame, :string, size: 200, null: false
        add :status, :integer, null: false
        add :message, :string, size: 200
        add :count, :bigint, null: false, default: 0
        add :hour_bucket, :utc_datetime_usec, null: false
        add :hour_count, :bigint, null: false, default: 0
        add :tenant_ids, {:array, :binary_id}, null: false, default: []
        add :last_trace_ids, {:array, :string}, null: false, default: []
        add :first_seen_at, :utc_datetime_usec, null: false
        add :last_seen_at, :utc_datetime_usec, null: false
        add :alerted_new_at, :utc_datetime_usec
        add :growth_alerted_hour, :utc_datetime_usec

        timestamps(type: :utc_datetime_usec)
      end

      create unique_index(:error_groups, [:seq], prefix: schema)
      create unique_index(:error_groups, [:signature], prefix: schema)
      create index(:error_groups, [:last_seen_at], prefix: schema)

      create constraint(:error_groups, :error_groups_source_check,
               check: "source IN ('server','web')",
               prefix: schema
             )

      create constraint(:error_groups, :error_groups_kind_check,
               check: "kind IN ('exception','http_status','web_error')",
               prefix: schema
             )
    end
  end
end
