defmodule Letflow.Engine.NotifyStepRunner do
  @moduledoc """
  The runtime of a NOTIFICATION STEP (T-2810): a SERVICE_TASK node that carries a `notify`
  attribute (a registered template, a recipient variable or the file channel).

  Before this module the declaration was parsed and activated but nothing ran it: entering such
  a node fell to the HTTP branch of `Letflow.Engine.ServiceTask` and ended the instance in ERROR.

  ## One interpreter, no new movement code

  The step is armed and advanced by the machinery of the platform step (T-2703), with the same
  durable row (`platform_step_dispatches`, `function_name` = `function_name/0`):

    1. the engine ARMS the row inside its own transaction when a token enters the node
       (`Letflow.Engine`, `arm_notify_step/5`) and parks the instance on the node;
    2. `run_due/2` (a poller, any tenant schema) CLAIMS the row (the lease is `next_attempt_at`;
       a run killed after the claim is taken over when the lease expired, up to `@max_attempts`)
       and calls `Letflow.NotificationSteps.Dispatcher.retry/3` OUTSIDE every transaction;
    3. a delivered step (`sent`, or `already_done`) stores no output and is handed to
       `Letflow.Engine.apply_platform_step_result/3`, the SAME apply the platform step uses: the
       token moves along the definition's edges (`persist_service_task_advance`);
    4. a step that did not deliver puts the instance in ERROR with an EXECUTION_ERROR and a DLQ
       entry of type `Letflow.Instances.StepRetry.notify_step_entry_type/0`
       (`Letflow.Engine.fail_platform_step/2`), which the retry of gap G7 re-runs.

  ## Replay

  The send is never repeated by a replay: `Dispatcher.retry/3` asks the delivery log whether the
  template was already sent (or the file written) for this instance BEFORE it sends, so a worker
  that died after the send and before its result is recorded finds the work done and sends
  nothing the second time (the delivery row is keyed by template + instance; the arm key is
  instance + node + visit).

  ## What it stores and logs

  The row carries no input (`inputs` is empty) and a failure kind that is an atom code
  (`notify_*`), never an address, a name or a body (INV-4). The recipient and the values are read
  from the instance's own variables at run time and never copied.
  """

  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Instances.StepRetry
  alias Letflow.NotificationSteps.Dispatcher, as: NotifyDispatcher
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @function "notify.send"
  @lease_ms 300_000
  @max_attempts 5
  @default_limit 64
  @max_kind_bytes 255

  @doc "The `function_name` marker of a notification step's row."
  @spec function_name() :: String.t()
  def function_name, do: @function

  # ── arming (inside the engine's transaction) ────────────────────────────────

  @doc false
  # Writes the row of one VISIT of the node; a second arm of the same visit meets the unique
  # `call_key` and returns the existing row (a replay never makes a second row).
  @spec arm(module(), map(), String.t(), Ecto.UUID.t(), String.t(), non_neg_integer()) ::
          {:ok, StepDispatch.t()} | {:error, term()}
  def arm(repo, declaration, node_id, definition_id, prefix, visit)
      when is_map(declaration) and is_binary(node_id) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      instance_id = Map.fetch!(declaration, :instance_id)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      id = Ecto.UUID.generate()
      node_digest = digest(node_id)
      call_key = "notify:#{instance_id}:#{node_digest}:#{visit}"

      changeset =
        StepDispatch.arm_changeset(%StepDispatch{id: id}, %{
          id: id,
          tenant_id: tenant_id,
          instance_id: instance_id,
          definition_id: definition_id,
          node_id: node_id,
          function_name: @function,
          call_key: call_key,
          input_fingerprint: digest(node_id <> ":" <> to_string(visit)),
          inputs: %{},
          status: :pending,
          attempt_index: 0,
          next_attempt_at: now,
          created_at: now
        })

      case repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: :call_key,
             prefix: prefix
           ) do
        {:ok, _} ->
          case repo.get_by(StepDispatch, [call_key: call_key], prefix: prefix) do
            %StepDispatch{} = row -> {:ok, row}
            nil -> {:error, :notify_step_arm_failed}
          end

        {:error, _changeset} ->
          {:error, :notify_step_arm_failed}
      end
    end
  end

  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  # ── running (outside every transaction) ─────────────────────────────────────

  @doc """
  One cycle over every tenant schema: runs the due notification rows. Never raises.
  """
  @spec run_tick(pos_integer()) :: map()
  def run_tick(limit \\ @default_limit) do
    schemas =
      try do
        Registration
        |> where([r], not is_nil(r.migrations_applied_at))
        |> select([r], r.schema_name)
        |> Repo.all()
      rescue
        _exception -> []
      end

    Enum.reduce(schemas, %{claimed: 0, advanced: 0, failed: 0}, fn prefix, acc ->
      case run_due(prefix, limit) do
        %{} = counts -> Map.merge(acc, counts, fn _k, a, b -> a + b end)
        _error -> acc
      end
    end)
  end

  @doc """
  One cycle in `prefix`: claims and runs every due notification row. Returns the counts, or
  `{:error, code}`.
  """
  @spec run_due(String.t(), pos_integer()) :: map() | {:error, atom()}
  def run_due(prefix, limit \\ @default_limit) when is_binary(prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ids =
      from(d in StepDispatch,
        where:
          d.function_name == ^@function and d.status in [:pending, :running] and
            d.next_attempt_at <= ^now,
        order_by: [asc: d.next_attempt_at],
        limit: ^limit,
        select: d.id
      )
      |> Repo.all(prefix: prefix)

    counts =
      Enum.reduce(ids, %{claimed: 0, advanced: 0, failed: 0}, fn id, acc ->
        run_one(id, prefix, :automatic, %{acc | claimed: acc.claimed + 1})
      end)

    sweep(prefix, limit, counts)
  rescue
    _exception -> {:error, :notify_step_raised}
  end

  # A row whose result commit and engine apply were split by a death: `advanced` with the
  # instance still parked, or `given_up` with the instance still active on the node.
  defp sweep(prefix, limit, counts) do
    rows =
      from(d in StepDispatch,
        join: p in Letflow.EventStore.InstanceProjection,
        on: p.instance_id == d.instance_id,
        where:
          d.function_name == ^@function and d.status in [:advanced, :given_up] and
            p.status == :active,
        order_by: [asc: d.created_at],
        limit: ^limit,
        select: {d.id, d.status}
      )
      |> Repo.all(prefix: prefix)

    Enum.reduce(rows, counts, fn
      {id, :advanced}, acc -> apply_result(id, prefix, acc)
      {id, :given_up}, acc -> fail(id, prefix, acc)
    end)
  end

  defp run_one(id, prefix, mode, acc) do
    case claim(id, prefix, mode) do
      {:ok, {:claimed, row}} ->
        case execute(row, prefix) do
          :ok ->
            case finish(row, :advanced, nil, prefix) do
              :ok -> apply_result(id, prefix, %{acc | advanced: acc.advanced + 1})
              :dropped -> acc
            end

          {:error, code} ->
            case finish(row, :given_up, code, prefix) do
              :ok -> fail(id, prefix, acc)
              :dropped -> acc
            end
        end

      {:ok, {:already_final, _row}} ->
        apply_result(id, prefix, acc)

      {:ok, {:given_up, _row}} ->
        fail(id, prefix, acc)

      _in_flight_or_cancelled ->
        acc
    end
  rescue
    _exception -> acc
  end

  defp apply_result(id, prefix, acc) do
    case Engine.apply_platform_step_result(id, prefix) do
      {:ok, :advanced} ->
        acc

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

  defp fail(id, prefix, acc) do
    case Engine.fail_platform_step(id, prefix) do
      {:ok, :error_set} -> %{acc | failed: acc.failed + 1}
      _other -> acc
    end
  end

  # The step itself: the declaration comes from the instance's OWN definition snapshot, the
  # variables and labels from the instance's event log. The delivery log is asked first.
  defp execute(row, prefix) do
    with {:ok, raw} <- StepRetry.notify_declaration(row.instance_id, row.node_id, prefix),
         {:ok, %{instance_state: state}} <-
           Reconstruction.reconstruct_instance(row.instance_id, prefix: prefix) do
      case NotifyDispatcher.retry(raw, state.variables,
             prefix: prefix,
             trigger_ref: row.instance_id,
             labels: state.variable_labels
           ) do
        {:ok, %{status: status}} when status in ["sent", "already_done"] -> :ok
        {:ok, %{status: "skipped"}} -> {:error, "notify_skipped"}
        {:ok, %{status: _failed}} -> {:error, "notify_failed"}
        {:error, code} -> {:error, kind(code)}
      end
    else
      {:error, code} -> {:error, kind(code)}
      _other -> {:error, "notify_step_failed"}
    end
  rescue
    _exception -> {:error, "notify_step_failed"}
  end

  # The failure kind is the name of an atom code, bounded; anything else is the generic code.
  defp kind(code) when is_atom(code) do
    name = Atom.to_string(code)
    if byte_size(name) <= @max_kind_bytes, do: name, else: "notify_step_failed"
  end

  defp kind(_other), do: "notify_step_failed"

  defp claim(id, prefix, mode) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      row =
        StepDispatch
        |> where([d], d.id == ^id and d.function_name == ^@function)
        |> lock("FOR UPDATE")
        |> Repo.one(prefix: prefix)

      case row do
        nil -> Repo.rollback(:notify_step_not_found)
        %StepDispatch{status: :advanced} = r -> {:already_final, r}
        %StepDispatch{status: :given_up} = r -> {:given_up, r}
        %StepDispatch{} = r -> claim_live(r, now, prefix, mode)
      end
    end)
  end

  defp claim_live(row, now, prefix, mode) do
    ended? =
      Letflow.EventStore.InstanceProjection
      |> where([p], p.instance_id == ^row.instance_id and p.status in [:cancelled, :completed])
      |> Repo.exists?(prefix: prefix)

    cond do
      ended? ->
        {:ok, updated} =
          row
          |> StepDispatch.terminal_changeset(%{
            status: :given_up,
            last_failure_kind: "notify_step_instance_ended",
            dispatched_at: now
          })
          |> Repo.update(prefix: prefix)

        {:cancelled, updated}

      row.status == :running and DateTime.compare(row.next_attempt_at, now) == :gt ->
        Repo.rollback(:notify_step_in_flight)

      mode == :automatic and row.attempt_index >= @max_attempts ->
        {:ok, updated} =
          row
          |> StepDispatch.terminal_changeset(%{
            status: :given_up,
            last_failure_kind: "notify_step_max_attempts",
            dispatched_at: now
          })
          |> Repo.update(prefix: prefix)

        {:given_up, updated}

      true ->
        {:ok, updated} =
          row
          |> StepDispatch.claim_changeset(%{
            status: :running,
            attempt_index: row.attempt_index + 1,
            next_attempt_at: DateTime.add(now, @lease_ms, :millisecond)
          })
          |> Repo.update(prefix: prefix)

        {:claimed, updated}
    end
  end

  # The result is written only while the row still carries THIS attempt's claim token.
  defp finish(row, status, kind, prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {count, _} =
      from(d in StepDispatch,
        where: d.id == ^row.id and d.status == :running and d.attempt_index == ^row.attempt_index
      )
      |> Repo.update_all(
        [set: [status: status, outputs: %{}, last_failure_kind: kind, dispatched_at: now]],
        prefix: prefix
      )

    if count == 1, do: :ok, else: :dropped
  end

  # ── the manual retry (gap G7) ───────────────────────────────────────────────

  @doc """
  The row of a notification step of `instance_id` at `node_id` (the most recent visit), or `nil`.
  """
  @spec fetch_row(Ecto.UUID.t(), String.t(), String.t()) :: StepDispatch.t() | nil
  def fetch_row(instance_id, node_id, prefix) do
    from(d in StepDispatch,
      where:
        d.instance_id == ^instance_id and d.node_id == ^node_id and d.function_name == ^@function,
      order_by: [desc: d.created_at, desc: d.id],
      limit: 1
    )
    |> Repo.one(prefix: prefix)
  rescue
    _exception -> nil
  end

  @doc """
  Runs a failed step ONCE more, on an operator's request, and resumes the instance. A step that
  already delivered is not sent again (`already_done`). A row in flight is refused.
  """
  @spec retry(StepDispatch.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def retry(%StepDispatch{} = row, prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    cond do
      row.status == :advanced ->
        resume(row, "already_done", prefix)

      row.status == :running and DateTime.compare(row.next_attempt_at, now) == :gt ->
        {:error, :notify_step_in_flight}

      true ->
        {:ok, _} =
          row
          |> StepDispatch.retry_changeset(%{
            status: :pending,
            attempt_index: row.attempt_index,
            next_attempt_at: now
          })
          |> Repo.update(prefix: prefix)

        _ = run_one(row.id, prefix, :manual, %{claimed: 0, advanced: 0, failed: 0})

        case Repo.get(StepDispatch, row.id, prefix: prefix) do
          %StepDispatch{status: :advanced} = done ->
            resume(done, "sent", prefix)

          %StepDispatch{last_failure_kind: kind} ->
            {:error, failure_code(kind)}

          nil ->
            {:error, :step_not_found}
        end
    end
  end

  # The retry's apply is the resume: it lifts the ERROR and moves the token (idempotent: the
  # completion key is the row id).
  defp resume(row, status, prefix) do
    case Engine.apply_platform_step_result(row.id, prefix, resume: true) do
      {:ok, _outcome} -> {:ok, %{status: status, reason: nil}}
      {:error, :instance_not_found} -> {:ok, %{status: status, reason: nil}}
      {:error, _reason} -> {:error, :notify_step_resume_failed}
    end
  end

  # A closed code: a known `notify_*` name, or the generic one.
  defp failure_code("notify_skipped"), do: :notify_skipped
  defp failure_code("notify_failed"), do: :notify_failed

  defp failure_code("notify_" <> _ = kind) do
    String.to_existing_atom(kind)
  rescue
    ArgumentError -> :notify_step_failed
  end

  defp failure_code(_other), do: :notify_step_failed
end
