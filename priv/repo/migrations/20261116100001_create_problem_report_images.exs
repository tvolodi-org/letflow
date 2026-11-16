# Letflow.Repo.Migrations.CreateProblemReportImages
#
# T-2015: screenshot upload for "Report a problem". Table `problem_report_images`,
# one row per image attached to a user-submitted problem report.
#
# PLACEMENT: per-tenant (schema-per-tenant via `prefix()`), created empty in every schema;
# written ONLY in the platform company's schema. Customer images stay behind a schema prefix (INV-1).
# No foreign keys to public-schema tables. `report_id` references `problem_reports(id)` in the same schema.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, registered in
# `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
defmodule Letflow.Repo.Migrations.CreateProblemReportImages do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:problem_report_images, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true

        add :report_id, references(:problem_reports, type: :binary_id, on_delete: :delete_all),
          null: false

        add :position, :smallint, null: false
        add :content_type, :string, size: 32, null: false
        add :bytes, :binary, null: false
        add :size, :integer, null: false
        add :inserted_at, :utc_datetime_usec, null: false
      end

      create unique_index(:problem_report_images, [:report_id, :position], prefix: schema)

      create constraint(:problem_report_images, :problem_report_images_content_type,
               check: "content_type IN ('image/png', 'image/jpeg')",
               prefix: schema
             )

      create constraint(:problem_report_images, :problem_report_images_size,
               check: "size BETWEEN 1 AND 5242880",
               prefix: schema
             )
    end
  end
end
