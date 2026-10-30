defmodule Letflow.RecordTriggers.Apply do
  @moduledoc """
  REQ-628 slice T-4 part A (GH #3507, decision 0067 D2/D3/D7) -- the result transaction of one
  claimed `record_trigger_outbox` row, and its terminal compare-and-set.

  `apply_result/3` is ONE `Repo.transaction/1` (not `Records.command_multi/3`):

    1. the outbox row is locked `FOR UPDATE` on (id, attempt, status = running): no row means a
       sweep or a newer claim won, nothing is written (`:stale`);
    2. the sequence rows of the target types are locked in ascending byte order of the type name
       (the row `EventStore` locks later, so that lock is a re-lock by the same transaction);
    3. each line runs through `Records.create_record/4`, `update_record/4` or
       `upsert_record_by_external_ref/4` with authority `:tenant`, the key
       `record_trigger:<row id>:<line index>` and the `:trigger_lineage` option (depth of the row,
       chain = the row's chain plus its own binding id, so a binding writing its own type is
       suppressed);
    4. the row is set `done`, again checked on (id, attempt, status = running).

  Any refused line rolls the whole transaction back. `finish/3` is the second, terminal
  transaction: `dead`, or back to `pending` with `Worker.backoff_ms/1`, or `dead`
  (`retries_exhausted`) once the retry would pass `max_attempts` (`claim_next/1` does not filter on
  `attempt`, so the cap is enforced here as well as in the sweep). Only closed codes are stored.
  """

  import Ecto.Query

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.RecordTriggers.OutboxRow
  alias Letflow.RecordTriggers.Worker
  alias Letflow.Repo

  @doc """
  Applies `lines` (`Runner.run/2` output) for the claimed `row`. Returns `:done`, `:stale`, or
  `{:dead, code}` / `{:retry, code}` for the caller to pass to `finish/3`.
  """
  @spec apply_result(OutboxRow.t(), [map()], String.t()) ::
          :done | :stale | {:dead, String.t()} | {:retry, String.t()}
  def apply_result(%OutboxRow{} = row, lines, prefix) when is_list(lines) and is_binary(prefix) do
    result =
      Repo.transaction(fn ->
        lock_row(row, prefix)
        lock_sequences(lines, prefix)
        Enum.each(lines, &apply_line(&1, row, prefix))
        mark_done(row, prefix)
      end)

    case result do
      {:ok, :done} -> :done
      {:error, :stale} -> :stale
      {:error, {:line, reason}} -> line_failure(reason)
      {:error, _other} -> {:dead, "trigger_write_refused"}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      # A failed inner Records transaction leaves the outer one rolling back; closed code only.
      {:retry, "entity_write_contention"}

    error in RuntimeError ->
      if error.message =~ "rolling back",
        do: {:retry, "entity_write_contention"},
        else: reraise(error, __STACKTRACE__)
  end

  defp line_failure(reason) when reason in [:record_version_conflict, :external_ref_contention],
    do: {:retry, "entity_write_contention"}

  defp line_failure(_reason), do: {:dead, "trigger_write_refused"}

  defp lock_row(row, prefix) do
    locked =
      from(r in OutboxRow,
        where: r.id == ^row.id and r.attempt == ^row.attempt and r.status == :running,
        lock: "FOR UPDATE",
        select: r.id
      )
      |> Repo.one(prefix: prefix)

    if is_nil(locked), do: Repo.rollback(:stale)
    :ok
  end

  defp lock_sequences(lines, prefix) do
    lines
    |> Enum.map(& &1.entity_type)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn type ->
      with {:ok, instance_id} <- EntityTypeInstance.fetch_instance_id(type, prefix) do
        from(s in InstanceSequence, where: s.instance_id == ^instance_id, lock: "FOR UPDATE")
        |> Repo.one(prefix: prefix)
      end
    end)
  end

  defp apply_line(line, row, prefix) do
    key = "record_trigger:" <> row.id <> ":" <> Integer.to_string(line.index)
    lineage = %{depth: row.depth, chain: row.chain ++ [row.binding_id]}
    base = %{entity_type: line.entity_type, actor_id: row.actor_id, idempotency_key: key}

    case write(line, base, row, prefix, lineage) do
      {:ok, _result} -> :ok
      {:error, reason} -> Repo.rollback({:line, reason})
    end
  end

  defp write(%{mode: "create"} = line, base, _row, prefix, lineage),
    # scope-all: record-trigger system write, no HTTP user (tenant authority)
    do:
      Records.create_record(Map.put(base, :field_values, line.fields), prefix, :tenant,
        trigger_lineage: lineage
      )

  defp write(%{mode: "upsert_by_external_ref"} = line, base, _row, prefix, lineage),
    # scope-all: record-trigger system write, no HTTP user (tenant authority)
    do:
      Records.upsert_record_by_external_ref(
        base |> Map.put(:field_values, line.fields) |> Map.put(:external_ref, line.external_ref),
        prefix,
        :tenant,
        trigger_lineage: lineage
      )

  defp write(%{mode: "update_self"} = line, base, row, prefix, lineage) do
    case Repo.get_by(Latest, [entity_type: row.entity_type, record_id: row.record_id],
           prefix: prefix
         ) do
      %Latest{deleted: false} = latest ->
        # `update_record` replaces the whole document: keep every stored key the line does not set.
        preserve =
          latest.field_values |> Map.keys() |> Kernel.--(Map.keys(line.fields)) |> MapSet.new()

        base
        |> Map.merge(%{
          record_id: row.record_id,
          field_values: line.fields,
          preserve_keys: preserve,
          expected_last_event_global_seq: latest.last_event_global_seq
        })
        # scope-all: record-trigger system write, no HTTP user (tenant authority)
        |> Records.update_record(prefix, :tenant, trigger_lineage: lineage)

      _missing_or_deleted ->
        {:error, :source_record_missing}
    end
  end

  defp mark_done(row, prefix) do
    {count, _} =
      from(r in OutboxRow,
        where: r.id == ^row.id and r.attempt == ^row.attempt and r.status == :running
      )
      |> Repo.update_all([set: [status: :done, done_at: now()]], prefix: prefix)

    if count == 1, do: :done, else: Repo.rollback(:stale)
  end

  @doc """
  The terminal compare-and-set on (id, attempt, status = running). `{:dead, code}` makes the row
  `dead`; `{:retry, code}` returns it to `pending` after `Worker.backoff_ms/1`, or makes it `dead`
  with `retries_exhausted` when its `attempt` has reached `max_attempts`. Returns `:dead`, `:retry`
  or `:stale` (no longer this claim).
  """
  @spec finish(OutboxRow.t(), String.t(), {:dead | :retry, String.t()}) ::
          :dead | :retry | :stale
  def finish(%OutboxRow{} = row, prefix, {:dead, code}) when is_binary(code),
    do: cas(row, prefix, :dead, status: :dead, last_code: code)

  def finish(%OutboxRow{} = row, prefix, {:retry, code}) when is_binary(code) do
    if row.attempt >= Worker.config(:max_attempts) do
      cas(row, prefix, :dead, status: :dead, last_code: "retries_exhausted")
    else
      wait = DateTime.add(now(), Worker.backoff_ms(row.attempt), :millisecond)
      cas(row, prefix, :retry, status: :pending, last_code: code, next_attempt_at: wait)
    end
  end

  defp cas(row, prefix, outcome, set) do
    {count, _} =
      from(r in OutboxRow,
        where: r.id == ^row.id and r.attempt == ^row.attempt and r.status == :running
      )
      |> Repo.update_all([set: set], prefix: prefix)

    if count == 1, do: outcome, else: :stale
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
