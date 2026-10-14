# Letflow.Repo.Migrations.CreateScriptRules
#
# GH 2534 PR 7b-1 (decision 0053 D1, D6) -- see
# lib/letflow/design/gh2534-7b1-script-registry.md section 1 for the design.
#
# One row per version of a tenant script. A version is never deleted and its number is never
# reused (discarded drafts keep their contributors for separation of duties). A published,
# retired or revoked version is immutable: the guard trigger below enforces the status machine
# and raises SQLSTATE 'LF001' on any violation (the context maps `pg_code == "LF001"` to 409).
#
# PLACEMENT: per-tenant (0006 D2: no tenant_id column).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
# Existing tenants receive the table through the boot-time replay; it starts empty.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7); the only
# interpolation is the schema name from `prefix()`.
defmodule Letflow.Repo.Migrations.CreateScriptRules do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:script_rules, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :key, :text, null: false
        add :version, :integer, null: false
        add :hook_kind, :text, null: false
        add :status, :text, null: false
        add :source, :text, null: false
        add :manifest, :map, null: false
        add :test_cases, :map, null: false
        add :sha256, :text, null: false
        add :contributors, {:array, :binary_id}, null: false
        add :publisher_id, :binary_id
        add :published_at, :utc_datetime_usec
        add :retired_at, :utc_datetime_usec
        add :revoked_at, :utc_datetime_usec
        add :discarded_at, :utc_datetime_usec
        add :self_published, :boolean, null: false, default: false

        timestamps(type: :utc_datetime_usec)
      end

      create unique_index(:script_rules, [:key, :version],
               name: :script_rules_key_version_index,
               prefix: schema
             )

      create index(:script_rules, [:key, :status], prefix: schema)

      create constraint(:script_rules, :script_rules_key_format,
               check: "key ~ '^[a-z][a-z0-9_]{0,63}$'",
               prefix: schema
             )

      create constraint(:script_rules, :script_rules_version_positive,
               check: "version >= 1",
               prefix: schema
             )

      create constraint(:script_rules, :script_rules_hook_kind,
               check: "hook_kind = 'service_task'",
               prefix: schema
             )

      create constraint(:script_rules, :script_rules_status,
               check: "status IN ('draft', 'discarded', 'published', 'retired', 'revoked')",
               prefix: schema
             )

      create constraint(:script_rules, :script_rules_source_size,
               check: "octet_length(source) <= 65536",
               prefix: schema
             )

      # A NULL contributor would make the trigger's `publisher_id = ANY(contributors)` NULL,
      # silently passing the separation-of-duties check.
      create constraint(:script_rules, :script_rules_contributors_no_null,
               check: "array_position(contributors, NULL) IS NULL",
               prefix: schema
             )

      execute(
        """
        CREATE OR REPLACE FUNCTION "#{schema}".script_rules_guard() RETURNS trigger AS $$
        DECLARE
          content_changed boolean;
        BEGIN
          IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'script_rules: versions are never deleted' USING ERRCODE = 'LF001';
          END IF;

          IF NEW.id IS DISTINCT FROM OLD.id
             OR NEW.key IS DISTINCT FROM OLD.key
             OR NEW.version IS DISTINCT FROM OLD.version
             OR NEW.hook_kind IS DISTINCT FROM OLD.hook_kind
             OR NEW.inserted_at IS DISTINCT FROM OLD.inserted_at
             OR NEW.self_published IS DISTINCT FROM OLD.self_published THEN
            RAISE EXCEPTION 'script_rules: identity columns are immutable' USING ERRCODE = 'LF001';
          END IF;

          content_changed :=
            NEW.source IS DISTINCT FROM OLD.source
            OR NEW.manifest IS DISTINCT FROM OLD.manifest
            OR NEW.test_cases IS DISTINCT FROM OLD.test_cases
            OR NEW.sha256 IS DISTINCT FROM OLD.sha256;

          IF OLD.status = 'draft' THEN
            IF NEW.status = 'draft' THEN
              IF NOT (OLD.contributors <@ NEW.contributors)
                 OR NEW.publisher_id IS NOT NULL OR NEW.published_at IS NOT NULL
                 OR NEW.retired_at IS NOT NULL OR NEW.revoked_at IS NOT NULL
                 OR NEW.discarded_at IS NOT NULL THEN
                RAISE EXCEPTION 'script_rules: invalid draft update' USING ERRCODE = 'LF001';
              END IF;
              RETURN NEW;
            ELSIF NEW.status = 'published' THEN
              IF content_changed
                 OR NEW.contributors IS DISTINCT FROM OLD.contributors
                 OR NEW.publisher_id IS NULL OR NEW.published_at IS NULL
                 OR NEW.publisher_id = ANY(NEW.contributors)
                 OR NEW.retired_at IS NOT NULL OR NEW.revoked_at IS NOT NULL
                 OR NEW.discarded_at IS NOT NULL THEN
                RAISE EXCEPTION 'script_rules: invalid publish' USING ERRCODE = 'LF001';
              END IF;
              RETURN NEW;
            ELSIF NEW.status = 'discarded' THEN
              IF content_changed
                 OR NEW.contributors IS DISTINCT FROM OLD.contributors
                 OR NEW.discarded_at IS NULL
                 OR NEW.publisher_id IS NOT NULL OR NEW.published_at IS NOT NULL
                 OR NEW.retired_at IS NOT NULL OR NEW.revoked_at IS NOT NULL THEN
                RAISE EXCEPTION 'script_rules: invalid discard' USING ERRCODE = 'LF001';
              END IF;
              RETURN NEW;
            END IF;

            RAISE EXCEPTION 'script_rules: invalid transition from draft' USING ERRCODE = 'LF001';
          END IF;

          IF OLD.status IN ('published', 'retired') THEN
            IF content_changed
               OR NEW.contributors IS DISTINCT FROM OLD.contributors
               OR NEW.publisher_id IS DISTINCT FROM OLD.publisher_id
               OR NEW.published_at IS DISTINCT FROM OLD.published_at
               OR NEW.discarded_at IS DISTINCT FROM OLD.discarded_at THEN
              RAISE EXCEPTION 'script_rules: published content is immutable' USING ERRCODE = 'LF001';
            END IF;

            IF OLD.status = 'published' AND NEW.status = 'retired'
               AND OLD.retired_at IS NULL AND NEW.retired_at IS NOT NULL
               AND NEW.revoked_at IS NOT DISTINCT FROM OLD.revoked_at THEN
              RETURN NEW;
            END IF;

            IF NEW.status = 'revoked'
               AND OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
               AND NEW.retired_at IS NOT DISTINCT FROM OLD.retired_at THEN
              RETURN NEW;
            END IF;
          END IF;

          RAISE EXCEPTION 'script_rules: invalid transition' USING ERRCODE = 'LF001';
        END;
        $$ LANGUAGE plpgsql
        """,
        """
        DROP FUNCTION IF EXISTS "#{schema}".script_rules_guard()
        """
      )

      execute(
        """
        CREATE TRIGGER script_rules_guard
          BEFORE UPDATE OR DELETE ON "#{schema}".script_rules
          FOR EACH ROW EXECUTE FUNCTION "#{schema}".script_rules_guard()
        """,
        """
        DROP TRIGGER IF EXISTS script_rules_guard ON "#{schema}".script_rules
        """
      )
    end
  end
end
