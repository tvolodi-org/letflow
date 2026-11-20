# Letflow.Repo.Migrations.CreateApprovalRuleDefaults
#
# T-2391 (owner D-165, 2026-11-20): the approval rule (four eyes, `distinct_from`) is OFF BY DEFAULT for
# NEW tenants; companies switch it ON where they want it. Existing tenants keep today's behaviour: for
# them "no row in approval_rule_settings" stays ON.
#
# How the default is carried (chosen over writing explicit ON rows for existing tenants): a creation-time
# marker. The table `approval_rule_defaults` holds AT MOST one row (unique index on `((true))`). A row
# means "a step with no explicit `approval_rule_settings` row is OFF"; no row means ON (today's rule).
# This migration inserts the row only into a FRESH schema (no process definition and no approval rule
# setting yet, which is every schema at the moment it is provisioned). A schema that already has either
# gets no row, so nothing about an existing tenant changes, and an upgrade writes no ON rows and no
# data into settings. A step that a tenant has switched explicitly (a row in approval_rule_settings,
# `four_eyes` true or false) always wins over the marker. Why not "write explicit ON rows for every
# existing tenant": rows are keyed by (definition, step), so a step added later (a new process version,
# a module upgrade) would have no row and flip to OFF in a tenant that never chose that; the marker is
# per tenant and cannot drift.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`); no tenant_id column (0006 D2).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateApprovalRuleDefaults do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".approval_rule_defaults (
        id uuid PRIMARY KEY,
        four_eyes_default boolean NOT NULL CHECK (four_eyes_default = false),
        inserted_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX approval_rule_defaults_single_index ON "#{schema}".approval_rule_defaults ((true))|
      )

      execute("""
      INSERT INTO "#{schema}".approval_rule_defaults (id, four_eyes_default, inserted_at)
      SELECT gen_random_uuid(), false, now()
      WHERE NOT EXISTS (SELECT 1 FROM "#{schema}".process_definitions)
        AND NOT EXISTS (SELECT 1 FROM "#{schema}".approval_rule_settings)
      """)
    end
  end

  def down do
    if prefix() do
      execute(~s|DROP TABLE IF EXISTS "#{prefix()}"."approval_rule_defaults"|)
    end
  end
end
