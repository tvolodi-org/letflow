# Letflow.Repo.Migrations.CreatePurgeRequestsAndDeleteGuards
#
# REQ-603 part A / GH #3389 -- decision 0074 P2 (table shape) and P6 (database guards).
# The database layer of the document purge only: no module, route, permission or event yet.
#
# PLACEMENT: per-tenant (schema-per-tenant via `prefix()`). TENANT-SCOPED MIGRATION -- the
# `if prefix() do` guard is MANDATORY, and this file is registered in
# `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# What it does:
#   * creates `purge_requests` (no foreign key: the row outlives the purged version) with four
#     named CHECKs (two-person rule, approval pair, consumed only after approval, expiry);
#   * guard triggers on it: insert refuses a pre-approved row, update allows only the set-once
#     approval and consumption, delete and truncate are always refused;
#   * replaces `repository_artifacts_immutable()` and adds `document_versions_guard_delete()`:
#     a DELETE is allowed only when the transaction-local setting `letflow.purge_request_id`
#     names an approved, unexpired, unconsumed request that matches the row exactly. Without
#     the setting every delete is refused, exactly as before;
#   * every trigger is `ENABLE ALWAYS` (also the two existing `repository_artifacts` triggers,
#     which were ENABLE ORIGIN: `session_replication_role = replica` bypassed them).
#
# DEVIATION from 0074 P6(c): `repository_artifacts.content_hash` is bytea, while the request's
# `artefact_hash` is hex text (like `document_versions.artefact_hash`), so the trigger compares
# `decode(artefact_hash, 'hex') = OLD.content_hash`. A status guard is added to the
# `document_versions` exception: only superseded and cancelled rows (0063 S6) may be deleted.
#
# ORDERING CONTRACT for part B: the module sets `consumed_at` LAST, after the deletes, because
# the predicate requires `consumed_at IS NULL`.
#
# INV-7: the only dynamic SQL is `format('... %I ...', TG_TABLE_SCHEMA)` with bound `$n`
# parameters. The sibling table is read through TG_TABLE_SCHEMA, never a literal schema name,
# so a request of tenant A cannot authorize a delete in tenant B (INV-1).
#
# Existing tenants: the manifest replays this into every provisioned schema; the table is new
# and empty, nothing is backfilled.
defmodule Letflow.Repo.Migrations.CreatePurgeRequestsAndDeleteGuards do
  use Ecto.Migration

  @uuid_re "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

  def up do
    if prefix() do
      schema = prefix()

      create table(:purge_requests, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :document_id, :binary_id, null: false
        add :version_id, :binary_id, null: false
        add :version_no, :integer, null: false
        add :content_hash, :text, null: false
        add :artefact_hash, :text
        add :reason_code, :text, null: false
        add :requested_by, :binary_id, null: false
        add :requested_at, :utc_datetime_usec, null: false, default: fragment("now()")
        add :expires_at, :utc_datetime_usec, null: false
        add :approved_by, :binary_id
        add :approved_at, :utc_datetime_usec
        add :consumed_at, :utc_datetime_usec
      end

      create constraint(:purge_requests, :purge_requests_content_hash_chk,
               prefix: schema,
               check: "content_hash ~ '^[0-9a-f]{64}$'"
             )

      create constraint(:purge_requests, :purge_requests_artefact_hash_chk,
               prefix: schema,
               check: "artefact_hash IS NULL OR artefact_hash ~ '^[0-9a-f]{64}$'"
             )

      create constraint(:purge_requests, :purge_requests_reason_code_chk,
               prefix: schema,
               check: "reason_code ~ '^[a-z][a-z0-9_]{0,63}$'"
             )

      create constraint(:purge_requests, :purge_requests_two_person_chk,
               prefix: schema,
               check: "approved_by IS NULL OR approved_by <> requested_by"
             )

      create constraint(:purge_requests, :purge_requests_approval_pair_chk,
               prefix: schema,
               check: "(approved_by IS NULL) = (approved_at IS NULL)"
             )

      create constraint(:purge_requests, :purge_requests_consumed_chk,
               prefix: schema,
               check: "consumed_at IS NULL OR approved_at IS NOT NULL"
             )

      create constraint(:purge_requests, :purge_requests_expiry_chk,
               prefix: schema,
               check: "expires_at > requested_at"
             )

      create index(:purge_requests, [:document_id, :version_id],
               name: :purge_requests_target_idx,
               prefix: schema
             )

      execute(purge_requests_guard_insert(schema))
      execute(purge_requests_guard_update(schema))
      execute(purge_requests_refuse(schema))
      execute(document_versions_guard_delete(schema))
      execute(repository_artifacts_immutable(schema, true))

      for {table, name, timing, level, fun} <- trigger_specs() do
        execute(~s(DROP TRIGGER IF EXISTS #{name} ON "#{schema}"."#{table}"))

        execute("""
        CREATE TRIGGER #{name}
          #{timing} ON "#{schema}"."#{table}"
          FOR EACH #{level} EXECUTE FUNCTION "#{schema}"."#{fun}"()
        """)

        execute(~s(ALTER TABLE "#{schema}"."#{table}" ENABLE ALWAYS TRIGGER #{name}))
      end

      for name <- ~w(repository_artifacts_no_update repository_artifacts_no_delete) do
        execute(~s(ALTER TABLE "#{schema}".repository_artifacts ENABLE ALWAYS TRIGGER #{name}))
      end
    end
  end

  # The ENABLE ALWAYS hardening of the two repository_artifacts triggers stays on: no weaker
  # state is restored.
  def down do
    if prefix() do
      schema = prefix()

      execute(
        ~s(DROP TRIGGER IF EXISTS document_versions_guard_delete ON "#{schema}".document_versions)
      )

      execute("""
      CREATE TRIGGER document_versions_guard_delete
        BEFORE DELETE ON "#{schema}".document_versions
        FOR EACH ROW EXECUTE FUNCTION "#{schema}".document_refuse()
      """)

      execute(
        ~s(ALTER TABLE "#{schema}".document_versions ENABLE ALWAYS TRIGGER document_versions_guard_delete)
      )

      execute(repository_artifacts_immutable(schema, false))

      drop table(:purge_requests, prefix: schema)

      for fun <-
            ~w(purge_requests_guard_insert purge_requests_guard_update purge_requests_refuse document_versions_guard_delete) do
        execute(~s|DROP FUNCTION IF EXISTS "#{schema}"."#{fun}"()|)
      end
    end
  end

  defp trigger_specs do
    [
      {"purge_requests", "purge_requests_guard_insert", "BEFORE INSERT", "ROW",
       "purge_requests_guard_insert"},
      {"purge_requests", "purge_requests_guard_update", "BEFORE UPDATE", "ROW",
       "purge_requests_guard_update"},
      {"purge_requests", "purge_requests_guard_delete", "BEFORE DELETE", "ROW",
       "purge_requests_refuse"},
      {"purge_requests", "purge_requests_guard_truncate", "BEFORE TRUNCATE", "STATEMENT",
       "purge_requests_refuse"},
      {"document_versions", "document_versions_guard_delete", "BEFORE DELETE", "ROW",
       "document_versions_guard_delete"}
    ]
  end

  defp purge_requests_guard_insert(schema) do
    """
    CREATE OR REPLACE FUNCTION "#{schema}".purge_requests_guard_insert() RETURNS trigger AS $$
    BEGIN
      IF NEW.approved_by IS NOT NULL OR NEW.approved_at IS NOT NULL OR NEW.consumed_at IS NOT NULL THEN
        RAISE EXCEPTION 'purge request must be inserted unapproved and unconsumed'
          USING ERRCODE = 'restrict_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """
  end

  defp purge_requests_guard_update(schema) do
    """
    CREATE OR REPLACE FUNCTION "#{schema}".purge_requests_guard_update() RETURNS trigger AS $$
    DECLARE
      allowed text[] := ARRAY[]::text[];
    BEGIN
      IF OLD.approved_at IS NULL THEN
        allowed := allowed || ARRAY['approved_by', 'approved_at'];
      END IF;
      IF OLD.consumed_at IS NULL THEN
        allowed := allowed || ARRAY['consumed_at'];
      END IF;

      IF (to_jsonb(OLD) - allowed) IS DISTINCT FROM (to_jsonb(NEW) - allowed) THEN
        RAISE EXCEPTION 'purge request field is immutable'
          USING ERRCODE = 'restrict_violation';
      END IF;

      -- A value, once set, never goes back to NULL.
      IF (OLD.approved_at IS NOT NULL AND NEW.approved_at IS NULL)
         OR (OLD.approved_by IS NOT NULL AND NEW.approved_by IS NULL)
         OR (OLD.consumed_at IS NOT NULL AND NEW.consumed_at IS NULL) THEN
        RAISE EXCEPTION 'purge request field is immutable'
          USING ERRCODE = 'restrict_violation';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """
  end

  defp purge_requests_refuse(schema) do
    """
    CREATE OR REPLACE FUNCTION "#{schema}".purge_requests_refuse() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'purge request rows are never deleted: this statement is refused'
        USING ERRCODE = 'restrict_violation';
    END;
    $$ LANGUAGE plpgsql
    """
  end

  defp document_versions_guard_delete(schema) do
    """
    CREATE OR REPLACE FUNCTION "#{schema}".document_versions_guard_delete() RETURNS trigger AS $$
    DECLARE
      raw text;
      hit boolean := false;
    BEGIN
      raw := current_setting('letflow.purge_request_id', true);
      -- A regex, not a cast, so a malformed value cannot raise.
      IF raw IS NOT NULL AND raw ~ '#{@uuid_re}' AND OLD.status IN ('superseded', 'cancelled') THEN
        EXECUTE format(
          'SELECT EXISTS (SELECT 1 FROM %I.purge_requests r WHERE r.id = $1::uuid
             AND r.approved_at IS NOT NULL AND r.consumed_at IS NULL AND r.expires_at > now()
             AND r.version_id = $2 AND r.document_id = $3 AND r.content_hash = $4)',
          TG_TABLE_SCHEMA)
        INTO hit USING raw, OLD.id, OLD.document_id, OLD.content_hash;
      END IF;

      IF hit THEN
        RETURN OLD;
      END IF;

      RAISE EXCEPTION 'document data is immutable: this statement is refused'
        USING ERRCODE = 'restrict_violation';
    END;
    $$ LANGUAGE plpgsql
    """
  end

  defp repository_artifacts_immutable(schema, with_exception?) do
    exception =
      if with_exception? do
        """
          IF TG_OP = 'DELETE' THEN
            raw := current_setting('letflow.purge_request_id', true);
            IF raw IS NOT NULL AND raw ~ '#{@uuid_re}' THEN
              EXECUTE format(
                'SELECT EXISTS (SELECT 1 FROM %I.purge_requests r WHERE r.id = $1::uuid
                   AND r.approved_at IS NOT NULL AND r.consumed_at IS NULL AND r.expires_at > now()
                   AND r.artefact_hash IS NOT NULL AND decode(r.artefact_hash, ''hex'') = $2)',
                TG_TABLE_SCHEMA)
              INTO hit USING raw, OLD.content_hash;
              IF hit THEN
                RETURN OLD;
              END IF;
            END IF;
          END IF;
        """
      else
        ""
      end

    """
    CREATE OR REPLACE FUNCTION "#{schema}".repository_artifacts_immutable() RETURNS trigger AS $$
    DECLARE
      raw text;
      hit boolean := false;
    BEGIN
    #{exception}
      RAISE EXCEPTION 'repository_artifacts is immutable';
    END;
    $$ LANGUAGE plpgsql
    """
  end
end
