defmodule Letflow.Engine.PlatformStepRunner do
  @moduledoc """
  The worker of a PLATFORM STEP (T-2703, pilot gap G1 remainder -- the engine half of the
  "Register a tenant" pilot).

  The engine ARMS a `platform_step_dispatches` row when a token enters a SERVICE_TASK node that
  carries a `platform_call` (`Letflow.Engine`, inside its own transaction) and parks the instance
  on the node. This module is what happens next, outside every transaction:

    1. `Letflow.PlatformFunctions.Dispatcher.attempt_dispatch/2` claims the row (lease and claim
       token), re-checks the authority of the call (decision 0094: platform tenant only, the
       activator's permission, the signed `activated_by` document -- at EVERY attempt) and runs the
       catalogue function. The body may run DDL, so no transaction is open while it runs;
    2. a row that ADVANCED is handed back to the engine
       (`Letflow.Engine.apply_platform_step_result/3`): the declared outputs are merged into the
       instance variables and the instance continues;
    3. a row that GAVE UP (the body refused, the authority fence refused, the attempt cap was
       reached after crashes) puts the instance in ERROR with an EXECUTION_ERROR event and a DLQ
       entry of type `Letflow.Instances.StepRetry.platform_step_entry_type/0`
       (`Letflow.Engine.fail_platform_step/2`), which the retry of gap G7 re-dispatches.

  ## Retries

  The dispatcher gives a call up on its first refusal: the platform functions are idempotent but
  not blindly repeatable, and a refusal is a decision (a slug that is taken, a permission that was
  lost). What it retries by itself is the CRASH: a row left `running` whose lease expired is taken
  over by the next claim, up to the attempt cap. Every other retry is the operator's, through the
  DLQ (`Letflow.Instances.StepRetry`), and that retry resumes the instance exactly once.

  ## What it never does

  It runs only in the platform tenant's schema (`Letflow.PlatformTenant.platform_prefix/0`): a
  dispatch row of any other tenant is never run here (INV-10). It never raises: every failure is
  counted, and the next tick tries again (the apply and the landing are idempotent).
  """

  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.PlatformFunctions.Dispatcher
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.PlatformTenant
  alias Letflow.Repo

  @default_limit 64

  # The keyset pages one sweep reads per cycle (each of the cycle's `limit` rows).
  @sweep_pages 8

  @type counts :: %{
          claimed: non_neg_integer(),
          advanced: non_neg_integer(),
          failed: non_neg_integer(),
          applied: non_neg_integer()
        }

  @doc """
  One cycle of the platform tenant: runs every due row and applies the results.

  `{:error, :platform_tenant_not_configured}` when no platform tenant is pinned. Otherwise the
  counts of `run_due/2`.
  """
  @spec run_tick(pos_integer()) :: counts() | {:error, term()}
  def run_tick(limit \\ @default_limit) when is_integer(limit) and limit > 0 do
    case PlatformTenant.platform_prefix() do
      {:ok, prefix} -> run_due(prefix, limit)
      :error -> {:error, :platform_tenant_not_configured}
    end
  end

  @doc """
  One cycle in `prefix`. The prefix must be the platform tenant's: any other schema is refused
  (INV-10), whatever it holds.
  """
  @spec run_due(String.t(), pos_integer()) :: counts() | {:error, term()}
  def run_due(prefix, limit \\ @default_limit)
      when is_binary(prefix) and is_integer(limit) and limit > 0 do
    if PlatformTenant.platform_prefix?(prefix) do
      do_run_due(prefix, limit)
    else
      {:error, :not_platform_tenant}
    end
  end

  defp do_run_due(prefix, limit) do
    case Dispatcher.due_dispatch_ids(prefix, limit) do
      {:error, reason} ->
        {:error, reason}

      due_ids ->
        counts =
          Enum.reduce(due_ids, %{claimed: 0, advanced: 0, failed: 0, applied: 0}, fn id, acc ->
            run_one(id, prefix, acc)
          end)

        sweep(prefix, limit, counts)
    end
  rescue
    _exception -> {:error, :platform_step_raised}
  end

  defp run_one(id, prefix, acc) do
    acc = %{acc | claimed: acc.claimed + 1}

    case Dispatcher.attempt_dispatch(id, prefix) do
      {:ok, {:advanced, _outputs}} ->
        apply_result(id, prefix, %{acc | advanced: acc.advanced + 1})

      {:ok, {:already_final, _outputs}} ->
        apply_result(id, prefix, acc)

      # Another run holds the row, or took it over: its result stands, this one is dropped.
      {:error, reason} when reason in [:platform_step_in_flight, :platform_step_lease_lost] ->
        acc

      {:error, _reason} ->
        case Engine.fail_platform_step(id, prefix) do
          {:ok, :error_set} -> %{acc | failed: acc.failed + 1}
          _other -> acc
        end
    end
  rescue
    _exception -> acc
  end

  # A refusal of the apply (the same answer on every try) is LANDED as a failure: ERROR +
  # EXECUTION_ERROR + a DLQ entry, never a parked instance. A fault (a raise, a lock) is not: the
  # next cycle tries again.
  defp apply_result(id, prefix, acc) do
    case Engine.apply_platform_step_result(id, prefix) do
      {:ok, :advanced} ->
        %{acc | applied: acc.applied + 1}

      # The platform route lands every apply refusal itself (below); an `:error_set` answer is
      # counted as the failure it is, never as an applied result.
      {:ok, :error_set} ->
        %{acc | failed: acc.failed + 1}

      {:ok, _outcome} ->
        acc

      {:error, reason} ->
        case Engine.fail_platform_step_apply(id, prefix, reason) do
          {:ok, :error_set} -> %{acc | failed: acc.failed + 1}
          _other -> acc
        end
    end
  end

  # ── the sweeps ──────────────────────────────────────────────────────────────────────────
  #
  # The dispatcher's result commit and the engine's apply (or landing) are two commits. A death
  # between them leaves an OUTSTANDING row: `advanced` with no completion key, or `given_up`,
  # while its instance is still ACTIVE and still holds a token on the node. Nothing else reads
  # such a row, so the sweeps recover it WHATEVER ITS AGE (no time window: the persisted state
  # alone says what is outstanding). They read keyset pages of `limit` rows, oldest first, at most
  # `@sweep_pages` pages per cycle, so a row whose recovery keeps failing cannot hold back the
  # rows behind it. Both recoveries are idempotent.

  defp sweep(prefix, limit, counts) do
    counts = sweep_pages(prefix, limit, :advanced, nil, @sweep_pages, counts)
    sweep_pages(prefix, limit, :given_up, nil, @sweep_pages, counts)
  end

  defp sweep_pages(_prefix, _limit, _status, _cursor, 0, counts), do: counts

  defp sweep_pages(prefix, limit, status, cursor, pages_left, counts) do
    case outstanding_page(prefix, limit, status, cursor) do
      {:ok, []} ->
        counts

      {:ok, rows} ->
        counts =
          Enum.reduce(rows, counts, fn {id, _at}, acc -> recover(status, id, prefix, acc) end)

        if length(rows) < limit,
          do: counts,
          else: sweep_pages(prefix, limit, status, List.last(rows), pages_left - 1, counts)

      :error ->
        counts
    end
  end

  defp recover(:advanced, id, prefix, acc), do: apply_result(id, prefix, acc)

  defp recover(:given_up, id, prefix, acc) do
    case Engine.fail_platform_step(id, prefix) do
      {:ok, :error_set} -> %{acc | failed: acc.failed + 1}
      _other -> acc
    end
  end

  @doc false
  # The outstanding rows of one status, as `{id, dispatched_at}` in keyset order after `cursor`.
  @spec outstanding_page(String.t(), pos_integer(), :advanced | :given_up, nil | {term(), term()}) ::
          {:ok, [{Ecto.UUID.t(), DateTime.t()}]} | :error
  def outstanding_page(prefix, limit, status, cursor) do
    query =
      from(d in StepDispatch,
        as: :d,
        join: p in InstanceProjection,
        on: p.instance_id == d.instance_id,
        where: d.status == ^status and p.status == :active,
        where:
          exists(
            from(t in TokenRecord,
              where:
                t.instance_id == parent_as(:d).instance_id and
                  t.node_id == parent_as(:d).node_id and t.status == :active,
              select: 1
            )
          ),
        order_by: [asc: d.dispatched_at, asc: d.id],
        limit: ^limit,
        select: {d.id, d.dispatched_at}
      )

    query = if status == :advanced, do: not_completed(query), else: query

    query =
      case cursor do
        nil ->
          query

        {cursor_id, cursor_at} ->
          where(
            query,
            [d],
            d.dispatched_at > ^cursor_at or (d.dispatched_at == ^cursor_at and d.id > ^cursor_id)
          )
      end

    {:ok, Repo.all(query, prefix: prefix)}
  rescue
    _exception -> :error
  end

  # An `advanced` row is outstanding only while its completion key (the dispatch id) is absent.
  defp not_completed(query) do
    where(
      query,
      [d],
      not exists(
        from(i in IdempotencyRecord,
          where:
            i.idempotency_key ==
              fragment("'platform_step_dispatch:' || ?::text", parent_as(:d).id),
          select: 1
        )
      )
    )
  end
end
