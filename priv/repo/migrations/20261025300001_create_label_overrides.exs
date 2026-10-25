# Letflow.Repo.Migrations.CreateLabelOverrides
#
# REQ-551 / GH #3180 -- tenant label overrides: the replacement text of one overridable message
# id for one locale. Override values are public UI wording, not secrets.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), with `tenant_id uuid NOT NULL` in the
# row as well. The table starts empty: no existing row is altered.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateLabelOverrides do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".label_overrides (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        message_id text NOT NULL,
        locale text NOT NULL CHECK (locale IN ('en', 'ru', 'kk')),
        text text NOT NULL CHECK (char_length(text) BETWEEN 1 AND 500),
        updated_by uuid,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX label_overrides_message_id_locale_index ON "#{schema}".label_overrides (message_id, locale)|
      )
    end
  end

  def down do
    if prefix() do
      execute(~s|DROP TABLE IF EXISTS "#{prefix()}"."label_overrides"|)
    end
  end
end
