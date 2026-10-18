# Letflow.Repo.Migrations.AddExternalRefColumnsToEntityRecordLatest
#
# GH #2659 / REQ-505 PR-1 (design lib/letflow/design/gh2659-external-ref-idempotent-import.md
# sections 2.1 and 12; decision 0057 D1). Migration (a) of two: the nullable master
# `external_ref` pair on `entity_record_latest` and the both-or-neither CHECK. The partial
# unique index is migration (b) (20261019100002), a separate file so each runs in its own DDL
# transaction and the ACCESS EXCLUSIVE window here never overlaps the index build's SHARE lock.
#
#   * `external_system` varchar(64) NULL, `external_id` varchar(255) NULL. Catalog-only
#     `ADD COLUMN` (nullable, no default, no table rewrite). No backfill.
#   * `entity_record_latest_external_ref_pair_chk`:
#     `(external_system IS NULL) = (external_id IS NULL)`. Every existing row is NULL/NULL, so
#     the validation scan passes. Cost: ACCESS EXCLUSIVE on this tenant's table for one scan.
#
# FAIL-FAST: `SET LOCAL lock_timeout = '5s'` is the FIRST statement, so it dies with this
# migration's transaction. A busy tenant fails with `lock_not_available`, the migration rolls
# back whole and records nothing, `replay_migrations/2` reports `{:error, {:migration_failed, _}}`
# for that tenant only, and the next boot replay retries it. No `statement_timeout` (the scan
# is the intended work).
#
# GUARDED DDL: every statement is idempotent (`ADD COLUMN IF NOT EXISTS`, the CHECK added only
# when `pg_constraint` has no such name), so a large tenant can be prepared by hand first with
# the CHECK added `NOT VALID` (see docs/runbooks/gh2659-external-ref-rollout.md) and this
# migration then becomes a no-op for it.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
# The only interpolation is the schema name from `prefix()` (INV-7).
defmodule Letflow.Repo.Migrations.AddExternalRefColumnsToEntityRecordLatest do
  use Ecto.Migration

  @check "entity_record_latest_external_ref_pair_chk"

  @spec up() :: any()
  def up do
    if prefix() do
      schema = prefix()

      execute("SET LOCAL lock_timeout = '5s'")

      execute("""
      ALTER TABLE "#{schema}".entity_record_latest
        ADD COLUMN IF NOT EXISTS external_system varchar(64),
        ADD COLUMN IF NOT EXISTS external_id varchar(255)
      """)

      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint
           WHERE conname = '#{@check}'
             AND conrelid = '"#{schema}".entity_record_latest'::regclass
        ) THEN
          ALTER TABLE "#{schema}".entity_record_latest
            ADD CONSTRAINT #{@check}
            CHECK ((external_system IS NULL) = (external_id IS NULL));
        END IF;
      END
      $$
      """)
    end
  end

  @spec down() :: any()
  def down do
    if prefix() do
      schema = prefix()

      # A replay may find no table (guarded by to_regclass).
      execute("""
      DO $$
      BEGIN
        IF to_regclass('"#{schema}".entity_record_latest') IS NOT NULL THEN
          ALTER TABLE "#{schema}".entity_record_latest
            DROP CONSTRAINT IF EXISTS #{@check},
            DROP COLUMN IF EXISTS external_id,
            DROP COLUMN IF EXISTS external_system;
        END IF;
      END
      $$
      """)
    end
  end
end
