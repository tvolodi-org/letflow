defmodule Letflow.Engine.ServiceTaskDispatcher.StuckSweep do
  @moduledoc """
  GH #2688 / REQ-513 build B2 (design `lib/letflow/design/gh2688-req513-stuck-advance-sweeper.md`):
  finds HTTP SERVICE_TASK dispatch rows stuck `"advanced"` (the process crashed after the
  `advanced` commit, or the D-C.8 landing exhausted its budget) and lands each in-class one through
  `Letflow.Engine.land_stuck_service_dispatch/2`, which re-locks and re-checks everything.

  A plain module, no process: `Letflow.Engine.ServiceTaskDispatcher.Poller` calls `run_all/4` from
  its tick once per `stuck_advance_sweep_interval_ms`.

  ## Walk (design D1)

  A keyset cursor over `(dispatched_at, id)` ascending. The entity-write class cannot be a SQL
  predicate (the graph lives in the snapshot), so out-of-class rows must not fill the batch: every
  old row is scanned once per cycle, `stuck_advance_scan_limit` rows per tenant per sweep, and the
  walk stops after `stuck_advance_batch_size` in-class attempts. At the end of the candidate list
  the cursor resets to `nil`. The cursor lives in the Poller state; a restart resets it, which is
  harmless (landed rows carry the completion key and are no longer candidates).

  ## Modes (design D10)

  `:off` runs no query. `:shadow` walks and logs candidates and writes nothing. `:on` lands.

  ## Bounds (design D8)

  Per tenant: scan limit and batch size. Per sweep across tenants: a wall-clock budget, checked
  before each page and each landing. Every query carries the tenant `prefix:` (INV-1); logs hold the
  dispatch id, the tenant schema and a classified atom only.
  """

  import Ecto.Query

  require Logger

  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo

  @type cursor :: {DateTime.t(), Ecto.UUID.t()} | nil
  @type summary :: %{
          tenant_schema: String.t(),
          scanned: non_neg_integer(),
          candidates: non_neg_integer(),
          landed: non_neg_integer(),
          already_final: non_neg_integer(),
          skipped: non_neg_integer(),
          reason_counts: %{atom() => non_neg_integer()}
        }

  @doc """
  Sweeps every schema of `tenant_schemas` within one wall-clock budget. Returns the updated
  per-tenant cursor map; a tenant not reached (budget spent) or failing keeps its cursor. A failing
  tenant does not stop the others (design D7).
  """
  @spec run_all([String.t()], %{String.t() => cursor()}, DateTime.t(), :off | :shadow | :on) ::
          %{String.t() => cursor()}
  def run_all(_schemas, cursors, _now, :off), do: cursors

  def run_all(tenant_schemas, cursors, now, mode) do
    deadline = deadline_from_budget()

    Enum.reduce(tenant_schemas, cursors, fn schema, acc ->
      if budget_spent?(deadline) do
        acc
      else
        try do
          {_summary, next_cursor} =
            run(schema, now, Map.get(acc, schema), mode, deadline: deadline)

          Map.put(acc, schema, next_cursor)
        rescue
          error ->
            Logger.error(
              "stuck_advance sweep failed: tenant=#{schema} reason=#{inspect(error.__struct__)}"
            )

            acc
        end
      end
    end)
  end

  @doc """
  Sweeps one tenant schema from `cursor`. `:off` returns `:skipped` before any query. `opts[:deadline]`
  is a monotonic millisecond deadline shared across tenants (default: now plus the sweep budget).
  """
  @spec run(String.t(), DateTime.t(), cursor(), :off | :shadow | :on, keyword()) ::
          {summary(), cursor()} | :skipped
  def run(tenant_schema, now, cursor, mode, opts \\ [])

  def run(_tenant_schema, _now, _cursor, :off, _opts), do: :skipped

  def run(tenant_schema, now, cursor, mode, opts)
      when is_binary(tenant_schema) and mode in [:shadow, :on] do
    deadline = Keyword.get_lazy(opts, :deadline, &deadline_from_budget/0)

    cutoff =
      DateTime.add(now, -ServiceTaskDispatcher.stuck_advance_min_age_seconds(), :second)

    state = %{
      schema: tenant_schema,
      mode: mode,
      cutoff: cutoff,
      deadline: deadline,
      scan_limit: ServiceTaskDispatcher.stuck_advance_scan_limit(),
      page_size: ServiceTaskDispatcher.stuck_advance_scan_page_size(),
      batch_size: ServiceTaskDispatcher.stuck_advance_batch_size(),
      attempts: 0,
      summary: %{
        tenant_schema: tenant_schema,
        scanned: 0,
        candidates: 0,
        landed: 0,
        already_final: 0,
        skipped: 0,
        reason_counts: %{}
      }
    }

    {state, next_cursor} = walk(state, cursor)
    {state.summary, next_cursor}
  end

  defp walk(state, cursor) do
    remaining = state.scan_limit - state.summary.scanned

    cond do
      budget_spent?(state.deadline) or remaining <= 0 or state.attempts >= state.batch_size ->
        {state, cursor}

      true ->
        page_limit = min(state.page_size, remaining)
        rows = fetch_page(state.schema, state.cutoff, cursor, page_limit)

        case process_rows(state, rows, cursor) do
          {:halt, state, last_cursor} ->
            {state, last_cursor}

          {:cont, state, last_cursor} ->
            # A short page is the end of the candidate list: reset, never re-scan in this sweep.
            if length(rows) < page_limit, do: {state, nil}, else: walk(state, last_cursor)
        end
    end
  end

  defp process_rows(state, [], cursor), do: {:cont, state, cursor}

  defp process_rows(state, [row | rest], cursor) do
    if budget_spent?(state.deadline) or state.attempts >= state.batch_size do
      {:halt, state, cursor}
    else
      state = visit(state, row)
      process_rows(state, rest, {row.dispatched_at, row.id})
    end
  end

  defp visit(state, row) do
    state = update_in(state.summary.scanned, &(&1 + 1))

    case Engine.stuck_entity_write_class?(row.instance_id, row.node_id, state.schema) do
      :in_class ->
        state = %{state | attempts: state.attempts + 1}
        state = update_in(state.summary.candidates, &(&1 + 1))
        in_class(state, row)

      other ->
        Logger.info(
          "stuck_advance skipped: dispatch_id=#{row.id} tenant=#{state.schema} " <>
            "reason=#{other}"
        )

        skip(state, other)
    end
  end

  defp in_class(%{mode: :shadow} = state, row) do
    Logger.info("stuck_advance candidate: dispatch_id=#{row.id} tenant=#{state.schema}")
    state
  end

  defp in_class(%{mode: :on} = state, row) do
    case Engine.land_stuck_service_dispatch(row.id, state.schema) do
      {:ok, :landed} -> update_in(state.summary.landed, &(&1 + 1))
      {:ok, :already_final} -> update_in(state.summary.already_final, &(&1 + 1))
      {:ok, reason} -> skip(state, reason)
      {:error, reason} -> skip(state, reason)
    end
  end

  defp skip(state, reason) do
    state = update_in(state.summary.skipped, &(&1 + 1))
    update_in(state.summary.reason_counts, &Map.update(&1, reason, 1, fn n -> n + 1 end))
  end

  # The selection of design D1; the class filter runs in Elixir on the pinned snapshot. Served by
  # the partial `(dispatched_at, id) WHERE status = 'advanced'` index of the D11 migration.
  defp fetch_page(schema, cutoff, cursor, limit) do
    ServiceTaskDispatch
    |> from(as: :d)
    |> join(:inner, [d], p in InstanceProjection, on: p.instance_id == d.instance_id)
    |> where(
      [d, p],
      d.status == :advanced and not is_nil(d.dispatched_at) and d.dispatched_at <= ^cutoff and
        p.status == :active
    )
    |> where(
      [d],
      not exists(
        from(i in IdempotencyRecord,
          where:
            i.idempotency_key == fragment("'service_task_dispatch:' || ?::text", parent_as(:d).id),
          select: 1
        )
      )
    )
    |> after_cursor(cursor)
    |> order_by([d], asc: d.dispatched_at, asc: d.id)
    |> limit(^limit)
    |> select([d], %{
      id: d.id,
      instance_id: d.instance_id,
      node_id: d.node_id,
      dispatched_at: d.dispatched_at
    })
    |> Repo.all(prefix: schema)
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {at, id}) do
    where(query, [d], d.dispatched_at > ^at or (d.dispatched_at == ^at and d.id > ^id))
  end

  defp deadline_from_budget do
    System.monotonic_time(:millisecond) + ServiceTaskDispatcher.stuck_advance_sweep_budget_ms()
  end

  defp budget_spent?(deadline), do: System.monotonic_time(:millisecond) >= deadline
end
