# Letflow.Repo.Migrations.AddExternalRefIndexToEntityRecordLatest
#
# GH #2659 / REQ-505 PR-1 (design lib/letflow/design/gh2659-external-ref-idempotent-import.md
# sections 2.1 and 12). Migration (b) of two: the partial unique index
# `entity_record_latest_external_ref_idx` on (entity_type, external_system, external_id)
# WHERE external_id IS NOT NULL -- the race arbiter of the idempotent upsert-by-external-ref
# import. Own file, own DDL transaction, own lock_timeout (migration (a) holds ACCESS
# EXCLUSIVE for the CHECK scan; the two windows never overlap).
#
# Plain `CREATE UNIQUE INDEX` (not CONCURRENTLY, which cannot run in the manifest's
# transaction): SHARE lock (blocks writes, not reads) for one scan of an index that holds zero
# rows. `IF NOT EXISTS` makes this a no-op for a large tenant whose index an operator built
# first with `CREATE UNIQUE INDEX CONCURRENTLY` under the SAME name (see
# docs/runbooks/gh2659-external-ref-rollout.md). No `deleted` predicate: a ref stays bound to
# its record after soft delete.
#
# `SET LOCAL lock_timeout = '5s'` is the FIRST statement (dies with the transaction); on
# timeout the migration rolls back whole and the next boot replay retries it. An existing but
# INVALID index of this name (a failed concurrent build) aborts the migration instead of being
# accepted by `IF NOT EXISTS`.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
# The only interpolation is the schema name from `prefix()` (INV-7).
defmodule Letflow.Repo.Migrations.AddExternalRefIndexToEntityRecordLatest do
  use Ecto.Migration

  @index "entity_record_latest_external_ref_idx"

  @spec up() :: any()
  def up do
    if prefix() do
      schema = prefix()

      execute("SET LOCAL lock_timeout = '5s'")

      # A failed `CREATE UNIQUE INDEX CONCURRENTLY` (the runbook's manual route) leaves an
      # INVALID index under this name; `IF NOT EXISTS` below would then silently accept it and
      # the uniqueness guarantee would not hold. Refuse, with the index name only.
      execute("""
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_index
           WHERE indexrelid = to_regclass('"#{schema}".#{@index}') AND NOT indisvalid
        ) THEN
          RAISE EXCEPTION 'GH #2659: index #{@index} exists but is INVALID; drop it and recreate it (see docs/runbooks/gh2659-external-ref-rollout.md)';
        END IF;
      END
      $$
      """)

      execute("""
      CREATE UNIQUE INDEX IF NOT EXISTS #{@index}
        ON "#{schema}".entity_record_latest (entity_type, external_system, external_id)
        WHERE external_id IS NOT NULL
      """)
    end
  end

  @spec down() :: any()
  def down do
    if prefix() do
      schema = prefix()

      execute("""
      DO $$
      BEGIN
        IF to_regclass('"#{schema}".entity_record_latest') IS NOT NULL THEN
          DROP INDEX IF EXISTS "#{schema}".#{@index};
        END IF;
      END
      $$
      """)
    end
  end
end
