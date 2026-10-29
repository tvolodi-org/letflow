# Letflow.Repo.Migrations.CreateSolutionPackOverrides
#
# REQ-596 / GH #3353 part A (decision 0069 D2/D3) -- the tenant's named, versioned, append-only
# deviations from an installed solution pack: one row per (override_id, override_version), the
# patch, its hash, the pack version it was made against and the mandatory reason.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`). NO `tenant_id` column: the tenant is
# the schema (decision 0006 D2). The table starts empty: no existing row is altered.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateSolutionPackOverrides do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".solution_pack_overrides (
        id uuid PRIMARY KEY,
        override_id uuid NOT NULL,
        override_version integer NOT NULL CHECK (override_version >= 1),
        pack_id text NOT NULL,
        artefact_type text NOT NULL CHECK (artefact_type IN ('process_definition', 'variable_schema')),
        artefact_id text NOT NULL,
        made_against text NOT NULL,
        patch jsonb NOT NULL,
        patch_hash text NOT NULL,
        status text NOT NULL CHECK (status IN ('active', 'retired')),
        reason text NOT NULL CHECK (btrim(reason) <> ''),
        created_by uuid NOT NULL,
        inserted_at timestamptz NOT NULL,
        CONSTRAINT uq_solution_pack_override_version UNIQUE (override_id, override_version)
      )
      """)

      execute(
        ~s|CREATE INDEX solution_pack_overrides_artefact_index ON "#{schema}".solution_pack_overrides (pack_id, artefact_type, artefact_id)|
      )
    end
  end

  def down do
    if prefix() do
      execute(~s|DROP TABLE IF EXISTS "#{prefix()}"."solution_pack_overrides"|)
    end
  end
end
