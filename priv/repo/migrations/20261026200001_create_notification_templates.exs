# Letflow.Repo.Migrations.CreateNotificationTemplates
#
# REQ-563 / GH #3199 -- tenant notification templates: the subject and body of one registered
# template key for one locale. Templates are stored wording with allow-listed placeholders only;
# they never hold a secret value or a `sec://` reference.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), with `tenant_id uuid NOT NULL` in the
# row as well. The table starts empty: no existing row is altered.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateNotificationTemplates do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".notification_templates (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        template_key text NOT NULL,
        locale text NOT NULL,
        subject text NOT NULL CHECK (char_length(subject) BETWEEN 1 AND 200),
        body text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 5000),
        updated_by uuid,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX notification_templates_template_key_locale_index ON "#{schema}".notification_templates (template_key, locale)|
      )
    end
  end

  def down do
    if prefix() do
      execute(~s|DROP TABLE IF EXISTS "#{prefix()}"."notification_templates"|)
    end
  end
end
