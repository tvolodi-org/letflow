defmodule Letflow.RecordTriggers.Worker do
  @moduledoc """
  REQ-615 slice T-3 part A (GH #3434, decision 0067 D2/D6) -- the third poller: it claims one due
  `record_trigger_outbox` row at a time per tenant, keeps per-record order by `source_seq`, serves
  tenants fairly and never double-claims. Same shape as `Letflow.Engine.ScriptTaskDispatcher`
  (`run_tick/2`, `claim_next/1`) and its `Poller`: a `GenServer` whose state is the round-robin
  offset, a zero-delay first tick, `Process.send_after` for the next one.

  Child of `Letflow.Supervisor.Pollers`, gated by `:start_record_trigger_worker` (false in
  `config/test.exs`, the same OwnershipError hazard as the other pollers). It does nothing while
  the record-trigger feature flag is off: no tenant is listed and no outbox table is read.

  **Claim.** One transaction: an unlocked candidate read (`pending`, due, and no lower-`source_seq`
  row of the same record that is still `pending` or `running`), then the first candidate still
  `pending` locked `FOR UPDATE SKIP LOCKED` on the outbox row only, then set `running` with
  `attempt + 1`, `claimed_at` and the lease. No record row and no sequence row is touched.

  **Run.** `run_row/2` (REQ-628): `Runner.run/2` builds the input and runs the pinned script,
  `Apply.apply_result/3` writes its lines and sets the row `done` in one transaction, `Apply.finish/3`
  sets a closed failure code (`dead`, or `pending` with a backoff). A test-only hook
  (`:record_trigger_run_fun`, honoured only while the scripts test hooks are on) can swap it.

  **Sweep, cap, backoff (part B).** Each tick first sweeps expired leases per tenant
  (`sweep_expired_leases/2`, bounded by `sweep_limit`): a `running` row whose lease ran out goes back
  to `pending` with `last_code` `lease_expired` and `next_attempt_at = now + backoff_ms/1`, or to
  `dead` with `retries_exhausted` once its `attempt` (the claim count) has reached `max_attempts`.
  Every swept row counts in `swept` and in the `[:letflow, :record_trigger, :lease_expired]`
  telemetry event; `dead` is the subset that ended dead. The sweep and the run both check
  (id, attempt, status = running), so a late run and the sweep have exactly one winner.

  The tenant comes only from the schema list passed in (`Registration`), never from a row column.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Letflow.RecordTriggers
  alias Letflow.RecordTriggers.Apply
  alias Letflow.RecordTriggers.OutboxRow
  alias Letflow.RecordTriggers.Runner
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.Registration

  # Same figures as the script dispatcher (0067 D2 names none).
  @defaults [
    poll_interval_ms: 1_000,
    tick_budget_ms: 10_000,
    max_claims_per_cycle: 16,
    lease_margin_ms: 23_000,
    sweep_limit: 64,
    max_attempts: 10,
    backoff_base_ms: 500,
    backoff_cap_ms: 30_000
  ]
  @platform_max_wall_ms 5_000
  @caller_margin_ms 2_000

  @type tick_summary :: %{
          tenants: non_neg_integer(),
          passes: non_neg_integer(),
          claimed: non_neg_integer(),
          done: non_neg_integer(),
          stale: non_neg_integer(),
          skipped: non_neg_integer(),
          swept: non_neg_integer(),
          dead: non_neg_integer(),
          retried: non_neg_integer(),
          sweep_failed: non_neg_integer(),
          budget_exhausted: boolean()
        }

  # ── process ──────────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)

  @impl true
  def init(offset) do
    Process.send_after(self(), :tick, 0)
    {:ok, offset}
  end

  @impl true
  def handle_info(:tick, offset) do
    next_offset =
      with true <- RecordTriggers.enabled?(),
           {:ok, schemas} <- fetch_tenant_schemas() do
        {_summary, next} = run_tick(schemas, offset)
        next
      else
        _ -> offset
      end

    Process.send_after(self(), :tick, config(:poll_interval_ms))
    {:noreply, next_offset}
  end

  # A fully unreachable database must not crash this GenServer.
  defp fetch_tenant_schemas do
    schemas =
      Registration
      |> where([r], not is_nil(r.migrations_applied_at))
      |> order_by([r], asc: r.schema_name)
      |> select([r], r.schema_name)
      |> Repo.all()

    {:ok, schemas}
  rescue
    _error -> :error
  end

  # ── config ───────────────────────────────────────────────────────────────────

  @doc "One `config :letflow, :record_trigger_worker` value, or its default."
  @spec config(atom()) :: integer()
  def config(key) do
    :letflow
    |> Application.get_env(:record_trigger_worker, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  @doc "The lease set at claim: 5 s wall clock + 2 s caller margin + `lease_margin_ms` (at least 1 s); 30 s by default."
  @spec lease_ms() :: pos_integer()
  def lease_ms,
    do: @platform_max_wall_ms + @caller_margin_ms + max(config(:lease_margin_ms), 1_000)

  # ── tick ─────────────────────────────────────────────────────────────────────

  @doc """
  One tick over `schemas`, starting at `offset rem length(schemas)`: passes serving each tenant at
  most one row per pass (and at most `max_claims_per_cycle` rows per tenant per tick), stopping once
  `tick_budget_ms` has elapsed (checked before each claim). Returns the summary and `offset + 1`.
  With the record-trigger feature flag off it returns at once and reads nothing. Never raises.
  """
  @spec run_tick([String.t()], non_neg_integer()) :: {tick_summary(), non_neg_integer()}
  def run_tick(schemas, offset) when is_list(schemas) and is_integer(offset) and offset >= 0 do
    summary = empty_summary(length(schemas))

    if schemas == [] or not RecordTriggers.enabled?() do
      {summary, offset + 1}
    else
      start = rem(offset, length(schemas))
      rotated = Enum.drop(schemas, start) ++ Enum.take(schemas, start)
      deadline = System.monotonic_time(:millisecond) + config(:tick_budget_ms)
      summary = Enum.reduce(rotated, summary, &sweep_tenant/2)
      {run_passes(rotated, deadline, %{}, MapSet.new(), summary), offset + 1}
    end
  end

  defp empty_summary(tenants) do
    %{
      tenants: tenants,
      passes: 0,
      claimed: 0,
      done: 0,
      stale: 0,
      skipped: 0,
      swept: 0,
      dead: 0,
      retried: 0,
      sweep_failed: 0,
      budget_exhausted: false
    }
  end

  defp run_passes(rotated, deadline, counts, empty, summary) do
    cap = config(:max_claims_per_cycle)

    {claimed_any?, counts, empty, summary} =
      Enum.reduce_while(rotated, {false, counts, empty, summary}, fn prefix,
                                                                     {claimed_any?, counts, empty,
                                                                      summary} ->
        cond do
          MapSet.member?(empty, prefix) or Map.get(counts, prefix, 0) >= cap ->
            {:cont, {claimed_any?, counts, empty, summary}}

          System.monotonic_time(:millisecond) >= deadline ->
            {:halt, {false, counts, empty, %{summary | budget_exhausted: true}}}

          true ->
            case claim_and_run(prefix) do
              :none ->
                {:cont, {claimed_any?, counts, MapSet.put(empty, prefix), summary}}

              {:skipped, :claim} ->
                {:cont,
                 {claimed_any?, counts, MapSet.put(empty, prefix),
                  %{summary | skipped: summary.skipped + 1}}}

              {:claimed, outcome} ->
                {:cont,
                 {true, Map.update(counts, prefix, 1, &(&1 + 1)), empty,
                  count_outcome(summary, outcome)}}
            end
        end
      end)

    summary = %{summary | passes: summary.passes + 1}

    if claimed_any? and not summary.budget_exhausted,
      do: run_passes(rotated, deadline, counts, empty, summary),
      else: summary
  end

  defp claim_and_run(prefix) do
    case safe_claim(prefix) do
      :none ->
        :none

      :error ->
        {:skipped, :claim}

      {:ok, row} ->
        outcome =
          try do
            run_fun().(row, prefix)
          rescue
            _ ->
              log_caught(prefix, "raised")
              :caught
          catch
            kind, _ ->
              log_caught(prefix, class_tag(kind))
              :caught
          end

        {:claimed, outcome}
    end
  end

  defp run_fun do
    if Letflow.Scripts.Runtime.test_hooks?(),
      do: Application.get_env(:letflow, :record_trigger_run_fun, &run_row/2),
      else: &run_row/2
  end

  defp safe_claim(prefix) do
    claim_next(prefix)
  rescue
    _ ->
      log_caught(prefix, "raised")
      :error
  catch
    kind, _ ->
      log_caught(prefix, class_tag(kind))
      :error
  end

  defp count_outcome(summary, outcome) do
    summary = %{summary | claimed: summary.claimed + 1}

    case outcome do
      :done -> %{summary | done: summary.done + 1}
      :stale -> %{summary | stale: summary.stale + 1}
      :dead -> %{summary | dead: summary.dead + 1}
      :retry -> %{summary | retried: summary.retried + 1}
      :caught -> %{summary | skipped: summary.skipped + 1}
    end
  end

  defp class_tag(:throw), do: "thrown"
  defp class_tag(:exit), do: "exited"
  defp class_tag(_error), do: "raised"

  # Only the tenant schema and the class tag are logged, never the error text.
  defp log_caught(prefix, tag) do
    Logger.error("record trigger step caught",
      component: "record_trigger",
      tenant_schema: prefix,
      tag: tag
    )
  end

  # ── claim ────────────────────────────────────────────────────────────────────

  @doc """
  Claims ONE due row of `prefix`: returns `{:ok, row}` with the row set `running` (attempt + 1,
  `claimed_at`, `lease_expires_at`), or `:none`. A row is a candidate only while no row of the same
  `(entity_type, record_id)` with a lower `source_seq` is `pending` or `running`.
  """
  @spec claim_next(String.t()) :: {:ok, OutboxRow.t()} | :none
  def claim_next(prefix) when is_binary(prefix) do
    Repo.transaction(fn ->
      now = now()

      ids =
        from(r in OutboxRow,
          as: :row,
          where:
            r.status == :pending and (is_nil(r.next_attempt_at) or r.next_attempt_at <= ^now),
          where:
            not exists(
              from(o in OutboxRow,
                where:
                  o.entity_type == parent_as(:row).entity_type and
                    o.record_id == parent_as(:row).record_id and
                    o.source_seq < parent_as(:row).source_seq and
                    o.status in [:pending, :running],
                select: 1
              )
            ),
          order_by: [asc: r.next_attempt_at, asc: r.id],
          limit: 8,
          select: r.id
        )
        |> Repo.all(prefix: prefix)

      case ids do
        [] -> :none
        ids -> lock_and_claim(ids, prefix)
      end
    end)
    |> case do
      {:ok, {:ok, row}} -> {:ok, row}
      {:ok, :none} -> :none
      {:error, reason} -> raise "record trigger claim failed: #{inspect(reason)}"
    end
  end

  defp lock_and_claim(ids, prefix) do
    locked =
      from(r in OutboxRow,
        where: r.id in ^ids and r.status == :pending,
        order_by: [asc: r.next_attempt_at, asc: r.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED",
        select: r.id
      )
      |> Repo.one(prefix: prefix)

    case locked do
      nil ->
        :none

      id ->
        now = now()

        {1, [row]} =
          from(r in OutboxRow, where: r.id == ^id and r.status == :pending, select: r)
          |> Repo.update_all(
            [
              set: [
                status: :running,
                claimed_at: now,
                lease_expires_at: DateTime.add(now, lease_ms(), :millisecond)
              ],
              inc: [attempt: 1]
            ],
            prefix: prefix
          )

        {:ok, row}
    end
  end

  # ── sweep, cap, backoff ──────────────────────────────────────────────────────

  @doc """
  The wait after claim number `attempt` expired: `min(backoff_base_ms * 2^(attempt - 1),
  backoff_cap_ms)`, so 500 ms, 1 s, ... 16 s at 6, 30 s from 8 on by default.
  """
  @spec backoff_ms(pos_integer()) :: pos_integer()
  def backoff_ms(attempt) when is_integer(attempt) and attempt >= 1 do
    cap = config(:backoff_cap_ms)
    # Past 2^30 the cap is reached for any sane base; avoids building a huge integer.
    min(config(:backoff_base_ms) * Integer.pow(2, min(attempt - 1, 30)), cap)
  end

  defp sweep_tenant(prefix, summary) do
    %{swept: swept, dead: dead, failed: failed} =
      sweep_expired_leases(prefix, config(:sweep_limit))

    %{
      summary
      | swept: summary.swept + swept,
        dead: summary.dead + dead,
        sweep_failed: summary.sweep_failed + failed
    }
  rescue
    _ ->
      log_caught(prefix, "raised")
      %{summary | sweep_failed: summary.sweep_failed + 1}
  catch
    kind, _ ->
      log_caught(prefix, class_tag(kind))
      %{summary | sweep_failed: summary.sweep_failed + 1}
  end

  @doc """
  Sweeps up to `limit` expired leases of `prefix` (`running`, `lease_expires_at` before now). Each row
  is changed by one compare-and-set on (id, attempt, status = running), so a stub finishing first wins
  and the row is skipped. A row at `max_attempts` claims becomes `dead` (`retries_exhausted`); any
  other goes back to `pending` (`lease_expired`) with a `backoff_ms/1` wait. Returns
  `%{swept: n, dead: n, failed: n}`: `swept` counts every expired lease, `dead` is the subset that
  ended dead, `failed` the rows whose update raised (logged by schema and tag only, never the error).
  """
  @spec sweep_expired_leases(String.t(), pos_integer()) :: %{
          swept: non_neg_integer(),
          dead: non_neg_integer(),
          failed: non_neg_integer()
        }
  def sweep_expired_leases(prefix, limit)
      when is_binary(prefix) and is_integer(limit) and limit > 0 do
    now = now()

    rows =
      from(r in OutboxRow,
        where: r.status == :running and r.lease_expires_at < ^now,
        order_by: [asc: r.lease_expires_at, asc: r.id],
        limit: ^limit,
        select: %{id: r.id, attempt: r.attempt}
      )
      |> Repo.all(prefix: prefix)

    result =
      Enum.reduce(rows, %{swept: 0, dead: 0, failed: 0}, fn row, acc ->
        case sweep_row(row, prefix, now) do
          :pending -> %{acc | swept: acc.swept + 1}
          :dead -> %{acc | swept: acc.swept + 1, dead: acc.dead + 1}
          :stale -> acc
          :error -> %{acc | failed: acc.failed + 1}
        end
      end)

    if result.swept > 0 do
      :telemetry.execute(
        [:letflow, :record_trigger, :lease_expired],
        %{count: result.swept},
        %{tenant_schema: prefix}
      )
    end

    result
  end

  defp sweep_row(%{id: id, attempt: attempt}, prefix, now) do
    {outcome, set} =
      if attempt >= config(:max_attempts) do
        {:dead, [status: :dead, last_code: "retries_exhausted"]}
      else
        {:pending,
         [
           status: :pending,
           last_code: "lease_expired",
           next_attempt_at: DateTime.add(now, backoff_ms(attempt), :millisecond)
         ]}
      end

    {count, _} =
      from(r in OutboxRow, where: r.id == ^id and r.attempt == ^attempt and r.status == :running)
      |> Repo.update_all([set: set], prefix: prefix)

    if count == 1, do: outcome, else: :stale
  rescue
    _ ->
      log_caught(prefix, "raised")
      :error
  catch
    kind, _ ->
      log_caught(prefix, class_tag(kind))
      :error
  end

  # ── run ──────────────────────────────────────────────────────────────────────

  @doc """
  The run of one claimed row (REQ-628): `Runner.run/2`, then `Apply.apply_result/3` for its lines or
  `Apply.finish/3` for a closed failure code. A `:stale` result emits `[:letflow, :record_trigger, :stale]`.
  Returns `:done`, `:retry` (back to `pending`), `:dead`,
  or `:stale` when the row is no longer this claim.
  """
  @spec run_row(OutboxRow.t(), String.t()) :: :done | :retry | :dead | :stale
  def run_row(%OutboxRow{} = row, prefix) when is_binary(prefix) do
    result =
      case Runner.run(row, prefix) do
        {:ok, lines} -> Apply.apply_result(row, lines, prefix)
        failure -> failure
      end

    outcome =
      case result do
        {kind, _code} = failure when kind in [:dead, :retry] -> Apply.finish(row, prefix, failure)
        outcome -> outcome
      end

    # the one stale counter: this claim lost to a sweep or a newer claim and wrote nothing
    if outcome == :stale,
      do:
        :telemetry.execute([:letflow, :record_trigger, :stale], %{count: 1}, %{
          tenant_schema: prefix
        })

    outcome
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
