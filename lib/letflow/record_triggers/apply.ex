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

  Any refused line rolls the whole transaction back and emits `[:letflow, :record_trigger, :write_refused]`
  with the decision 0067 D7 reason (`last_code` stays `trigger_write_refused`; the row's DLQ entry carries
  that same closed code, REQ-638). `finish/3` is the second, terminal
  transaction: `dead`, or back to `pending` with `Worker.backoff_ms/1`, or `dead`
  (`retries_exhausted`) once the retry would pass `max_attempts` (`claim_next/1` does not filter on
  `attempt`, so the cap is enforced here as well as in the sweep). Only closed codes are stored.
  """

  import Ecto.Query

  require Logger

  alias Letflow.Audit
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.Obs.Alerts
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
        apply_lines(row, lines, prefix)
        mark_done(row, prefix)
      end)

    case result do
      {:ok, :done} ->
        :done

      {:error, :stale} ->
        :stale

      {:error, {:line, reason}} ->
        emit_refused(reason)
        line_failure_class(reason)

      {:error, _other} ->
        {:dead, "trigger_write_refused"}
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

  @retriable_reasons [
    :record_version_conflict,
    :external_ref_contention,
    :entity_write_contention
  ]

  @doc false
  @spec line_failure_class(term()) :: {:dead, String.t()} | {:retry, String.t()}
  def line_failure_class(reason) when reason in @retriable_reasons,
    do: {:retry, "entity_write_contention"}

  def line_failure_class(_reason), do: {:dead, "trigger_write_refused"}

  # The reason of a refused line (decision 0067 D7). `last_code` stays `trigger_write_refused`: the
  # row has one code column, so the reason is a telemetry counter (the DLQ entry carries `last_code`).
  defp emit_refused(reason) when reason in @retriable_reasons, do: :ok

  defp emit_refused(reason) do
    :telemetry.execute([:letflow, :record_trigger, :write_refused], %{count: 1}, %{
      reason: refusal_reason(reason)
    })
  end

  @doc false
  @spec refusal_reason(term()) :: String.t()
  def refusal_reason(:entity_type_managed), do: "entity_type_managed"
  def refusal_reason(:idempotency_key_reuse), do: "idempotency_conflict"
  def refusal_reason({:record_payload_invalid, _}), do: "validation"
  def refusal_reason({:record_size_exceeded, _}), do: "validation"
  def refusal_reason(:record_not_encodable), do: "validation"
  def refusal_reason(_other), do: "write_not_permitted"

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

  @doc false
  @spec apply_lines(OutboxRow.t(), [map()], String.t()) :: [map()]
  def apply_lines(%OutboxRow{} = row, lines, prefix),
    do: Enum.map(lines, &apply_line(&1, row, prefix))

  defp apply_line(line, row, prefix) do
    key = "record_trigger:" <> row.id <> ":" <> Integer.to_string(line.index)
    lineage = %{depth: row.depth, chain: row.chain ++ [row.binding_id]}
    base = %{entity_type: line.entity_type, actor_id: row.actor_id, idempotency_key: key}

    case write(line, base, row, prefix, lineage) do
      {:ok, result} -> result
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

  **Dead rows are visible (REQ-638, decision 0067 D2/D7/D8).** The compare-and-set to `dead` and one
  `record_trigger` DLQ entry (type, `reference_id` = the row id, `reason` = the closed code, nothing
  else) are ONE transaction: a lost compare-and-set (`:stale`) enqueues nothing, and a failed DLQ insert
  rolls the status back, so the row stays `running`, `finish/4` returns `:retry` and the lease sweep
  returns it later. After the commit one metadata-only audit record (`record_trigger_dead`) is appended
  and the edge-triggered `record_trigger_dead` alert fires; neither can raise or undo the dead row.
  `facts` is the run metadata of `Runner.run_with_facts/2` (hmac, duration, stats) for the audit.
  """
  @spec finish(OutboxRow.t(), String.t(), {:dead | :retry, String.t()}, map()) ::
          :dead | :retry | :stale
  def finish(row, prefix, failure, facts \\ %{})

  def finish(%OutboxRow{} = row, prefix, {:dead, code}, facts) when is_binary(code),
    do: dead_outcome(finish_dead(row, prefix, code, facts))

  def finish(%OutboxRow{} = row, prefix, {:retry, code}, facts) when is_binary(code) do
    if row.attempt >= Worker.config(:max_attempts) do
      dead_outcome(finish_dead(row, prefix, "retries_exhausted", facts))
    else
      wait = DateTime.add(now(), Worker.backoff_ms(row.attempt), :millisecond)
      cas(row, prefix, :retry, status: :pending, last_code: code, next_attempt_at: wait)
    end
  end

  # A failed DLQ insert leaves the row running; the sweep returns it.
  defp dead_outcome(:dlq_failed), do: :retry
  defp dead_outcome(outcome), do: outcome

  # The dead transaction shared by `finish/4` and the lease sweep: compare-and-set to `dead` plus the
  # DLQ entry, then (after commit) audit and alert. `row` needs `id` and `attempt`; the audit also uses
  # `script_key`, `script_version`, `script_sha256` and `actor_id` when present. Returns `:dead`,
  # `:stale` or `:dlq_failed`.
  @doc false
  @spec finish_dead(map(), String.t(), String.t(), map()) :: :dead | :stale | :dlq_failed
  def finish_dead(row, prefix, code, facts \\ %{}) when is_binary(code) do
    result =
      Repo.transaction(fn ->
        {count, _} =
          from(r in OutboxRow,
            where: r.id == ^row.id and r.attempt == ^row.attempt and r.status == :running
          )
          |> Repo.update_all([set: [status: :dead, last_code: code]], prefix: prefix)

        if count != 1, do: Repo.rollback(:stale)

        case dlq_enqueue_fun().(dlq_attrs(row, code), prefix: prefix) do
          {:ok, _entry} -> :dead
          _failed -> Repo.rollback(:dlq_failed)
        end
      end)

    case result do
      {:ok, :dead} ->
        after_dead(row, prefix, code, facts)
        :dead

      {:error, :stale} ->
        :stale

      {:error, :dlq_failed} ->
        log_dlq_failed(prefix, "failed")
        :dlq_failed
    end
  rescue
    _ ->
      log_dlq_failed(prefix, "raised")
      :dlq_failed
  catch
    kind, _ ->
      log_dlq_failed(prefix, if(kind == :throw, do: "thrown", else: "exited"))
      :dlq_failed
  end

  # No record value, no field name, no error text (0067 D8): ids and the closed code only.
  defp dlq_attrs(row, code),
    do: %{entry_type: "record_trigger", instance_id: nil, reference_id: row.id, reason: code}

  # Test seam, honoured only under the scripts test hooks (same guard as `Runner.runner/0`).
  defp dlq_enqueue_fun do
    if Letflow.Scripts.Runtime.test_hooks?(),
      do: Application.get_env(:letflow, :record_trigger_dlq_enqueue, &Letflow.Dlq.enqueue/2),
      else: &Letflow.Dlq.enqueue/2
  end

  defp log_dlq_failed(prefix, tag) do
    Logger.error("record trigger dead-letter entry failed",
      component: "record_trigger",
      tenant_schema: prefix,
      tag: tag
    )
  end

  # Audit then alert, after the dead transaction committed. Never raises, never undoes the row.
  defp after_dead(row, prefix, code, facts) do
    audit_dead(row, prefix, code, facts)
    Alerts.notify_record_trigger_dead(prefix)
    :ok
  rescue
    _ -> log_audit_failed(prefix, "raised")
  catch
    kind, _ -> log_audit_failed(prefix, if(kind == :throw, do: "thrown", else: "exited"))
  end

  defp audit_dead(row, prefix, code, facts) do
    base = %{
      "last_code" => code,
      "outcome" => code,
      "attempt" => row.attempt,
      "outbox_id" => row.id
    }

    payload =
      [:script_key, :script_version, :script_sha256]
      |> Enum.reduce(base, fn key, acc ->
        put_present(acc, Atom.to_string(key), Map.get(row, key))
      end)
      |> put_present("principal", Map.get(row, :actor_id))
      |> put_present("hmac", Map.get(facts, :hmac))
      |> put_present("duration_us", Map.get(facts, :duration_us))
      |> put_present("instructions", Map.get(facts, :instructions_used))
      |> put_present("heap_words", Map.get(facts, :heap_words))

    case Audit.insert_entry(
           Repo,
           %{
             actor_id: nil,
             action: "record_trigger_dead",
             resource_type: "record_trigger_outbox",
             resource_id: row.id,
             before_state: nil,
             after_state: payload
           },
           prefix
         ) do
      {:ok, _entry} -> :ok
      _failed -> log_audit_failed(prefix, "failed")
    end
  rescue
    _ -> log_audit_failed(prefix, "raised")
  catch
    kind, _ -> log_audit_failed(prefix, if(kind == :throw, do: "thrown", else: "exited"))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp log_audit_failed(prefix, tag) do
    Logger.error("record trigger audit failed",
      component: "record_trigger",
      tenant_schema: prefix,
      tag: tag
    )
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
