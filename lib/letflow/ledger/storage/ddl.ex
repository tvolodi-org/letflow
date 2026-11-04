defmodule Letflow.Ledger.Storage.Ddl do
  @moduledoc """
  REQ-710: the DDL of one partition, run by `Letflow.Ledger.Storage.ensure/2` only.

  Every statement is produced by PostgreSQL `format()` with `%I` / `%L` from bound parameters
  (no value is concatenated in Elixir) and then run, so this is the one place in the ledger
  sources where `Repo.query!/1` takes a non-literal text. It lives in its own directory so the
  posting-path scans of `lib/letflow/ledger/*.ex` (literal SQL only, no interpolation) keep
  their meaning; the table names are passed in by `Storage`, so this file names none.
  The caller has validated the prefix and the ledger id.
  """

  alias Letflow.Repo

  @doc false
  @spec create_partition(String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok
  def create_partition(prefix, parent, part, ledger_id, h, entry_part) do
    Repo.query!(
      "SELECT format('CREATE TABLE %I.%I (LIKE %I.%I INCLUDING ALL)', $1::text, $2::text, $1::text, $3::text)",
      [prefix, part, parent]
    )
    |> run_text()

    add_partition_key(prefix, parent, part, h, entry_part)

    Repo.query!(
      "SELECT format('ALTER TABLE %I.%I ATTACH PARTITION %I.%I FOR VALUES IN (%L)', $1::text, $2::text, $1::text, $3::text, $4::text)",
      [prefix, parent, part, ledger_id]
    )
    |> run_text()

    rename_indexes(prefix, part, h)

    Repo.query!(
      "SELECT format('CREATE TRIGGER %I BEFORE TRUNCATE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION %I.ledger_refuse()', $3::text || '_guard_truncate', $1::text, $2::text, $1::text)",
      [prefix, part, parent]
    )
    |> run_text()

    Repo.query!(
      "SELECT format('ALTER TABLE %I.%I ENABLE ALWAYS TRIGGER %I', $1::text, $2::text, $3::text || '_guard_truncate')",
      [prefix, part, parent]
    )
    |> run_text()

    :ok
  end

  # REQ-711: the two ledger foreign keys live on the partitions, not on the parents, and are added
  # BEFORE ATTACH. A parent-level key is cloned by ATTACH and makes it take SHARE ROW EXCLUSIVE on the
  # parents, which would block every posting of the tenant. Each key points at the entry partition of
  # the same ledger id (a LIST partition holds one id), so the database still refuses a leg or a
  # reversal across ledger ids (decision 0073 A5). The balance partition has no such key.
  defp add_partition_key(prefix, "ledger_entry", part, h, _entry_part) do
    Repo.query!(
      "SELECT format('ALTER TABLE %I.%I ADD CONSTRAINT %I FOREIGN KEY (reverses_entry_id, ledger_id) REFERENCES %I.%I (id, ledger_id)', $1::text, $2::text, 'ledger_entry_reverses_entry_id_fkey_' || $3::text, $1::text, $2::text)",
      [prefix, part, h]
    )
    |> run_text()
  end

  defp add_partition_key(prefix, "ledger_leg", part, h, entry_part) do
    Repo.query!(
      "SELECT format('ALTER TABLE %I.%I ADD CONSTRAINT %I FOREIGN KEY (entry_id, ledger_id, posting_seq, event_time) REFERENCES %I.%I (id, ledger_id, posting_seq, event_time)', $1::text, $2::text, 'ledger_leg_entry_fk_' || $3::text, $1::text, $4::text)",
      [prefix, part, h, entry_part]
    )
    |> run_text()
  end

  defp add_partition_key(_prefix, _parent, _part, _h, _entry_part), do: :ok

  # After ATTACH every index of the partition has a parent index in pg_inherits.
  defp rename_indexes(prefix, part, h) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT ci.relname, cp.relname
          FROM pg_index x
          JOIN pg_class ci ON ci.oid = x.indexrelid
          JOIN pg_inherits ih ON ih.inhrelid = ci.oid
          JOIN pg_class cp ON cp.oid = ih.inhparent
         WHERE x.indrelid = format('%I.%I', $1::text, $2::text)::regclass
         ORDER BY ci.relname
        """,
        [prefix, part]
      )

    Enum.each(rows, fn [old, parent_index] ->
      Repo.query!(
        "SELECT format('ALTER INDEX %I.%I RENAME TO %I', $1::text, $2::text, $3::text || '_' || $4::text)",
        [prefix, old, parent_index, h]
      )
      |> run_text()
    end)
  end

  # The statement text was produced by format() from bound values; run it.
  defp run_text(%{rows: [[sql]]}), do: Repo.query!(sql)
end
