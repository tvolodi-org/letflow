defmodule Letflow.ModuleUpgrade.StepExec do
  @moduledoc """
  REQ-773 (decision 0055 D3, decision 0080 Q5): executes declarative data steps in bounded batches.

  `run_batch/5` is the unit: it takes a cursor (the last `record_id` examined, `nil` at the start)
  and a batch size, migrates the candidates of ONE step after the cursor, and answers the next
  cursor (or `:done`). `run_all/3` loops it for every step, in the CALLER's transaction: the
  one-transaction apply of `Letflow.ModuleUpgrade.Apply`. A later runner slice repeats
  `run_batch/5` batch by batch.

  Every record write goes through `Letflow.ModuleUpgrade.Writer.migrate_record/5` (one
  `ENTITY_RECORD_MIGRATED` event with the upgrade and step id, the live projection after it);
  tenant write hooks, the record-trigger outbox and per-record audit rows do not run for a
  migrated record. The prefix and tenant come from the `Capability` only (INV-1).

  ## Lock order

  Per batch: the type's instance sequence lock FIRST, then the candidate rows `FOR UPDATE`.
  `Writer.run/5` and the `Records` update path take the sequence lock before the row lock
  (decision 0061 item 5); selecting rows first would invert that order and deadlock against a
  concurrent record writer. The values a `copy_field` step reads are therefore read under the
  row lock. The lock is held to the end of the caller's transaction, so writers of the one type
  wait (bounded by the one-transaction record cap).

  ## Errors

  Closed set `:step_error | :step_raised` (decision 0080 Q5). A step that names a type the module
  does not manage in this tenant, a type with no instance, a failed transform, or a failed write
  is `:step_error`; a raise, exit or throw is `:step_raised`. No exception text and no record
  value is ever kept (INV-4, INV-8). Writing nothing but through the writer, a failure inside
  the caller's transaction rolls that whole transaction back (Ecto behaviour).
  """

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.EventStore
  alias Letflow.ModuleUpgrade.Capability
  alias Letflow.ModuleUpgrade.Writer
  alias Letflow.Modules.StepRecords
  alias Letflow.Modules.StepSpec
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @batch_size 500

  @type step :: %{id: String.t(), spec: map()}
  @type error :: :step_error | :step_raised

  @doc "The default batch size (records examined per statement)."
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch_size

  @doc """
  Runs `steps` in order for `module_id` in the caller's transaction, for the tenant that owns the
  schema `prefix` (the tenant is looked up from the registry, never taken from a request; a
  prefix with no registration is `:step_error`). Returns the per-step result
  `[%{"id", "op", "type", "records"}]` (`records` is the number of records the step wrote) or the
  error code.
  """
  @spec run_all(String.t(), String.t(), String.t(), String.t(), String.t(), [step()]) ::
          {:ok, [map()]} | {:error, error()}
  def run_all(prefix, upgrade_id, plan_hash, actor_id, module_id, steps) when is_list(steps) do
    guarded(fn ->
      with {:ok, tenant} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
           {:ok, capability} <- Capability.new(tenant, upgrade_id, plan_hash, actor_id) do
        run_steps(capability, module_id, steps)
      else
        _error -> {:error, :step_error}
      end
    end)
  end

  defp run_steps(capability, module_id, steps) do
    steps
    |> Enum.reduce_while({:ok, []}, fn step, {:ok, acc} ->
      case run_step(capability, module_id, step) do
        {:ok, migrated} -> {:cont, {:ok, [result(step, migrated) | acc]}}
        {:error, _code} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _code} = error -> error
    end
  end

  @doc """
  Migrates one batch of `step` after `cursor`. Answers `{:ok, %{processed, migrated, cursor}}`;
  `cursor` is `:done` when no candidate remains after this batch.
  """
  @spec run_batch(Capability.t(), String.t(), step(), String.t() | nil, pos_integer()) ::
          {:ok, %{processed: non_neg_integer(), migrated: non_neg_integer(), cursor: term()}}
          | {:error, error()}
  def run_batch(capability, module_id, %{spec: spec} = step, cursor, batch_size)
      when is_integer(batch_size) and batch_size > 0 do
    guarded(fn ->
      with {:ok, _instance_id} <- prepare(capability, module_id, spec) do
        batch(capability, step, cursor, batch_size)
      end
    end)
  end

  # ── one step ──────────────────────────────────────────────────────────────────────────────

  defp run_step(capability, module_id, %{spec: spec} = step) do
    if spec.op in StepSpec.executable_ops() do
      with {:ok, _instance_id} <- prepare(capability, module_id, spec) do
        loop(capability, step, nil, 0)
      end
    else
      {:error, :step_error}
    end
  end

  defp loop(capability, step, cursor, migrated) do
    case batch(capability, step, cursor, @batch_size) do
      {:ok, %{cursor: :done, migrated: n}} -> {:ok, migrated + n}
      {:ok, %{cursor: next, migrated: n}} -> loop(capability, step, next, migrated + n)
      {:error, _code} = error -> error
    end
  end

  # Guard + the instance sequence lock, BEFORE any row lock.
  defp prepare(capability, module_id, %{type: type}) do
    prefix = capability.prefix

    with :ok <- managed_by?(type, module_id, prefix),
         {:ok, instance_id} <- instance(type, prefix),
         {:ok, :locked} <- EventStore.lock_instance_sequence(Repo, instance_id, prefix) do
      {:ok, instance_id}
    else
      _error -> {:error, :step_error}
    end
  end

  # A step cannot touch a type this module does not manage in this tenant (the runtime twin of the
  # static manifest check).
  defp managed_by?(type, module_id, prefix) do
    case Definitions.get_active_definition_by_name(type, prefix) do
      {:ok, %{managed_by: ^module_id}} -> :ok
      _other -> :error
    end
  end

  defp instance(type, prefix) do
    case EntityTypeInstance.fetch_instance_id(type, prefix) do
      {:ok, _id} = ok -> ok
      {:error, :not_found} -> :error
    end
  end

  defp batch(capability, %{id: step_id, spec: spec}, cursor, size) do
    rows =
      cursor
      |> then(&StepRecords.candidates_query(spec, &1, size, true))
      |> Repo.all(prefix: capability.prefix)

    Enum.reduce_while(rows, {:ok, 0}, fn row, {:ok, migrated} ->
      case write(capability, step_id, spec, row) do
        {:ok, :appended} -> {:cont, {:ok, migrated + 1}}
        {:ok, _unchanged_or_deleted} -> {:cont, {:ok, migrated}}
        {:error, _code} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, migrated} ->
        next = if length(rows) < size, do: :done, else: List.last(rows).record_id
        {:ok, %{processed: length(rows), migrated: migrated, cursor: next}}

      {:error, _code} = error ->
        error
    end
  end

  defp write(capability, step_id, spec, row) do
    with {:ok, after_values} <- after_values(spec, row.field_values),
         {:ok, _result} = ok <-
           Writer.migrate_record(capability, spec.type, row.record_id, after_values, step_id) do
      ok
    else
      _error -> {:error, :step_error}
    end
  end

  defp after_values(%{op: op, field: field, value: value}, _values)
       when op in [:set_default, :backfill_from_constant],
       do: {:ok, %{field => value}}

  defp after_values(%{op: :copy_field, from: from, to: to, transform: transform}, values) do
    case StepSpec.transform(transform, Map.get(values, from)) do
      {:ok, value} -> {:ok, %{to => value}}
      :error -> :error
    end
  end

  defp after_values(_spec, _values), do: :error

  defp result(%{id: id, spec: spec}, migrated) do
    %{"id" => id, "op" => Atom.to_string(spec.op), "type" => spec.type, "records" => migrated}
  end

  # A raise, exit or throw is `:step_raised`; nothing of it is kept.
  defp guarded(fun) do
    fun.()
  rescue
    _exception -> {:error, :step_raised}
  catch
    _kind, _reason -> {:error, :step_raised}
  end
end
