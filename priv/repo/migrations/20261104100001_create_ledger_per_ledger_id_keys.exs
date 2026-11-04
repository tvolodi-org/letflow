# REQ-692 / GH #3725 (slice L2a rework, decision 0073 A5): the four entry keys gain `ledger_id` as
# their first column, names kept, so the idempotency, origin, device-sequence and reversal
# uniqueness is per ledger id and one document may post to two ledger ids.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered in
# `Letflow.TenantProvisioning.tenant_scoped_migrations/0`. The only interpolated piece of SQL is the
# trusted `prefix()` schema name, quoted as an identifier (INV-7); no value is interpolated.
#
# Existing rows: a key with `ledger_id` prepended is implied by the old narrower key, so the new
# keys hold on any row set and no refuse-if-rows rule is needed. The primary key, the other
# constraints and the self foreign key (which targets the primary key) are untouched.
#
# The drops are IF EXISTS so a replay on a tenant that lacks a key restores it.
#
# down/0 restores the old column lists and, like CreateLedgerTables.down/0, refuses to run unless
# `:allow_ledger_migration_down` is true (config/dev.exs and config/test.exs only).
defmodule Letflow.Repo.Migrations.CreateLedgerPerLedgerIdKeys do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()
      for sql <- up_sql(schema), do: execute(sql)
    end
  end

  def down do
    unless Application.get_env(:letflow, :allow_ledger_migration_down, false) == true do
      raise "ledger tables are append-only: CreateLedgerPerLedgerIdKeys.down refused " <>
              "(set :allow_ledger_migration_down for dev/test only)"
    end

    if prefix() do
      schema = prefix()
      for sql <- down_sql(schema), do: execute(sql)
    end
  end

  defp up_sql(schema), do: swap_sql(schema, new_columns())
  defp down_sql(schema), do: swap_sql(schema, old_columns())

  defp swap_sql(schema, cols) do
    t = ~s|"#{schema}".ledger_entry|

    [
      ~s|ALTER TABLE #{t} DROP CONSTRAINT IF EXISTS ledger_entry_subject_op_key|,
      ~s|ALTER TABLE #{t} ADD CONSTRAINT ledger_entry_subject_op_key UNIQUE (#{cols.subject_op})|,
      ~s|ALTER TABLE #{t} DROP CONSTRAINT IF EXISTS ledger_entry_origin_key_key|,
      ~s|ALTER TABLE #{t} ADD CONSTRAINT ledger_entry_origin_key_key UNIQUE (#{cols.origin})|,
      ~s|DROP INDEX IF EXISTS "#{schema}".ledger_entry_device_seq_unique_index|,
      ~s|CREATE UNIQUE INDEX ledger_entry_device_seq_unique_index ON #{t} (#{cols.device_seq}) | <>
        "WHERE device_id IS NOT NULL",
      ~s|DROP INDEX IF EXISTS "#{schema}".ledger_entry_reverses_unique_index|,
      ~s|CREATE UNIQUE INDEX ledger_entry_reverses_unique_index ON #{t} (#{cols.reverses}) | <>
        "WHERE reverses_entry_id IS NOT NULL"
    ]
  end

  defp new_columns do
    %{
      subject_op: "ledger_id, subject_id, client_op_id",
      origin: "ledger_id, origin_key",
      device_seq: "ledger_id, subject_id, device_id, client_seq",
      reverses: "ledger_id, reverses_entry_id"
    }
  end

  defp old_columns do
    %{
      subject_op: "subject_id, client_op_id",
      origin: "origin_key",
      device_seq: "subject_id, device_id, client_seq",
      reverses: "reverses_entry_id"
    }
  end
end
