defmodule Letflow.Ledger.Storage do
  @moduledoc """
  REQ-710 (decision 0073 A5, A6, A8): the partitions of one ledger id.

  `ledger_entry`, `ledger_leg` and `ledger_balance` are partitioned by LIST on `ledger_id`
  (CreateLedgerPartitionedTables). `ensure/2` creates the three partitions of one ledger id in the
  caller's open transaction: `CREATE TABLE ... (LIKE parent INCLUDING ALL)`, `ATTACH PARTITION ...
  FOR VALUES IN (id)`, then every index of the partition is renamed to `<parent index>_<h>` (and
  with it its backing constraint), and a `BEFORE TRUNCATE` trigger (`ENABLE ALWAYS`) is added to
  the partition, because PostgreSQL does not clone a statement trigger. It is never called from a
  posting: `post/1` only checks (`missing/2`) and refuses with `:ledger_storage_missing`.

  `h` is the first 16 hex characters of SHA-256 of the ledger id, so a partition name is
  deterministic, at most 31 characters, and carries no raw ledger id.

  DEVIATION from decision 0073's order (rename, then attach): the rename is done after ATTACH,
  because after attach `pg_inherits` links each partition index to its parent index, which gives the
  exact parent name; the end state is the same.

  Safety: the prefix and the ledger id are validated before any statement (INV-1, INV-7); every
  statement is built by PostgreSQL `format()` from bound parameters, no value is concatenated in
  Elixir. Concurrent creators of one ledger id are serialised by a transaction advisory lock.
  Locks: ATTACH takes SHARE UPDATE EXCLUSIVE on the parent. The two foreign keys are declared on
  the partitions before ATTACH, pointing at the entry partition of the same ledger id, because a
  parent-level key makes ATTACH take SHARE ROW EXCLUSIVE on the parents (measured by REQ-711), which
  would block the postings of every other ledger id. `Letflow.Modules.Installs.install/3` and
  `reactivate/3` are the only callers (REQ-711).
  """

  alias Letflow.Ledger.Storage.Ddl
  alias Letflow.Repo

  @prefix_form ~r/\Atenant_[0-9a-f]{32}\z/
  @ledger_id_form ~r/\A[a-z0-9_]{1,32}(:[a-z0-9-]{1,32})?\z/
  @parents ~w(ledger_entry ledger_leg ledger_balance)

  @type refusal ::
          {:ledger_contract, :invalid_prefix | :invalid_ledger_id | :ledger_storage_inconsistent}

  @doc """
  The three partition names of `ledger_id`, keyed by parent table name.
  """
  @spec partition_names(String.t()) :: %{String.t() => String.t()}
  def partition_names(ledger_id) when is_binary(ledger_id) do
    h = hash(ledger_id)
    Map.new(@parents, fn parent -> {parent, parent <> "_p" <> h} end)
  end

  @doc """
  Creates the partitions of `ledger_id` in `prefix` if none exists; `:ok` without DDL when all
  three are attached; `:ledger_storage_inconsistent` (nothing created) for anything in between.
  Raises `ArgumentError` outside a transaction.
  """
  @spec ensure(String.t(), String.t()) :: :ok | {:error, refusal()}
  def ensure(prefix, ledger_id) do
    cond do
      not Repo.in_transaction?() ->
        raise ArgumentError, "Letflow.Ledger.Storage.ensure/2 requires an open transaction"

      not valid_prefix?(prefix) ->
        {:error, {:ledger_contract, :invalid_prefix}}

      not valid_ledger_id?(ledger_id) ->
        {:error, {:ledger_contract, :invalid_ledger_id}}

      true ->
        lock(prefix, ledger_id)
        create_if_absent(prefix, ledger_id)
    end
  end

  @doc """
  The ledger ids of `ledger_ids` that lack an attached partition set in `prefix` (one catalog
  read, no lock, no DDL).
  """
  @spec missing(String.t(), [String.t()]) :: [String.t()]
  def missing(prefix, ledger_ids) when is_binary(prefix) and is_list(ledger_ids) do
    Enum.reject(Enum.uniq(ledger_ids), fn id -> state(prefix, id) == :attached end)
  end

  # -- internals -------------------------------------------------------------------------------

  defp lock(prefix, ledger_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      prefix <> ":ledger_partitions:" <> ledger_id
    ])
  end

  defp create_if_absent(prefix, ledger_id) do
    case state(prefix, ledger_id) do
      :attached ->
        :ok

      :absent ->
        names = partition_names(ledger_id)
        h = hash(ledger_id)

        Enum.each(@parents, fn parent ->
          Ddl.create_partition(prefix, parent, names[parent], ledger_id, h, names["ledger_entry"])
        end)

        :ok

      :inconsistent ->
        {:error, {:ledger_contract, :ledger_storage_inconsistent}}
    end
  end

  # :attached (all three attached for exactly this ledger id), :absent (none of the three names
  # exists), :inconsistent (anything else).
  defp state(prefix, ledger_id) do
    if valid_prefix?(prefix) and valid_ledger_id?(ledger_id) do
      names = partition_names(ledger_id)

      %{rows: rows} =
        Repo.query!(
          """
          SELECT c.relname, p.relname,
                 pg_get_expr(c.relpartbound, c.oid) = format('FOR VALUES IN (%L)', $3::text),
                 EXISTS (SELECT 1 FROM pg_constraint k
                          WHERE k.conrelid = c.oid AND k.contype = 'f' AND k.conparentid = 0
                            AND k.conname = ANY($4::text[]))
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
            LEFT JOIN pg_class p ON p.oid = i.inhparent
           WHERE n.nspname = $1 AND c.relname = ANY($2::text[])
          """,
          [prefix, Map.values(names), ledger_id, key_names(hash(ledger_id))]
        )

      attached =
        Enum.count(rows, fn [name, parent, bound_ok, has_key] ->
          bound_ok == true and Map.get(names, parent) == name and
            (has_key == true or parent == "ledger_balance")
        end)

      cond do
        rows == [] -> :absent
        attached == 3 and length(rows) == 3 -> :attached
        true -> :inconsistent
      end
    else
      :invalid
    end
  end

  # REQ-711: the per-partition foreign keys a ledger_entry / ledger_leg partition must carry.
  defp key_names(h),
    do: ["ledger_entry_reverses_entry_id_fkey_" <> h, "ledger_leg_entry_fk_" <> h]

  defp valid_prefix?(prefix), do: is_binary(prefix) and Regex.match?(@prefix_form, prefix)

  defp valid_ledger_id?(id),
    do: is_binary(id) and byte_size(id) <= 64 and Regex.match?(@ledger_id_form, id)

  defp hash(ledger_id) do
    :sha256 |> :crypto.hash(ledger_id) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end
end
