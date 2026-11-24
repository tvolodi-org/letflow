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
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.PlatformFunctions.Dispatcher
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.PlatformTenant
  alias Letflow.Repo

  @default_limit 64

  # The sweep of an `advanced` row whose instance has not moved looks back this far: a result that
  # is older than a day was settled by a person, not by a crash between two commits.
  @sweep_window_seconds 86_400

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

  defp apply_result(id, prefix, acc) do
    case Engine.apply_platform_step_result(id, prefix) do
      {:ok, outcome} when outcome in [:advanced, :error_set] -> %{acc | applied: acc.applied + 1}
      _other -> acc
    end
  end

  # A crash between the dispatcher's result commit and the engine's apply leaves a row that
  # `advanced` while its instance is still parked on the node. The apply is idempotent (its
  # completion key is the dispatch id), so the sweep only picks rows that have no completion yet.
  defp sweep(prefix, limit, counts) do
    cutoff = DateTime.add(DateTime.utc_now(), -@sweep_window_seconds, :second)

    ids =
      from(d in StepDispatch,
        as: :d,
        join: p in InstanceProjection,
        on: p.instance_id == d.instance_id,
        where: d.status == :advanced and d.dispatched_at > ^cutoff and p.status == :active,
        where:
          not exists(
            from(i in IdempotencyRecord,
              where:
                i.idempotency_key ==
                  fragment("'platform_step_dispatch:' || ?::text", parent_as(:d).id),
              select: 1
            )
          ),
        order_by: [asc: d.dispatched_at],
        limit: ^limit,
        select: d.id
      )
      |> Repo.all(prefix: prefix)

    Enum.reduce(ids, counts, fn id, acc -> apply_result(id, prefix, acc) end)
  rescue
    _exception -> counts
  end
end
