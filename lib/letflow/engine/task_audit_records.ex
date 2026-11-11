defmodule Letflow.Engine.TaskAuditRecords do
  @moduledoc """
  Best-effort, log-and-swallow audit writers for task lifecycle refusals, split
  out of `Letflow.Engine` (B4#10 slice 4, code health; code moved verbatim,
  no behaviour change). `Letflow.Engine` keeps the three public functions as
  `defdelegate`s with the same names, arities and specs, so no caller changed.

  All three functions:
  - open their own `Repo.transaction/1` (never nested inside a larger Multi);
  - never raise (function-level `rescue`, log and swallow);
  - always return `:ok`;
  - store ids, hashes and atom tags only — never submitted values, names or
    email addresses (INV-4 / INV-5).
  """

  require Logger

  alias Letflow.Audit
  alias Letflow.Repo

  # ISS-0784 (`lib/letflow/design/iss0784-task-activation-rollback-audit-signal.md`)
  # -- records that a task-activation attempt was rejected by
  # `TaskActivation.resolve_form_schema/1`'s `{:invalid_form_schema, node_id,
  # reason}` check and the enclosing transaction was rolled back per INV-8.
  #
  # Called from the failure branch of each of the four
  # `{:error, _failed_step, reason, _changes} -> {:error, reason}` unwrap
  # points (design §2/§3) -- NEVER as a step folded into the Multi that just
  # failed, because `Ecto.Multi`'s all-or-nothing semantics would roll this
  # write back right along with the failed attempt it's meant to record
  # (design §3). This function opens its own, independent
  # `Repo.transaction/1`, run and awaited synchronously, and must only ever
  # be invoked once the DB-level transaction that produced the rejection has
  # genuinely closed (committed or rolled back) -- not merely "returned
  # `{:error, ...}` from an inner `Ecto.Multi`" if that inner call itself
  # runs nested inside a still-open outer transaction.
  #
  # ISS-0784 follow-up fix -- sites 1/2 (`interpret_create_result/8`,
  # `interpret_complete_result/3`, both above, in this module) call this
  # directly from their own inline clause, because `create/2`/
  # `complete_task/3` open the *only* transaction on those call paths, so
  # `repo.transaction(multi)` returning `{:error, ...}` there really does
  # mean the DB-level transaction has closed. Sites 3/4
  # (`persist_timer_fired_advance/7`, `do_persist_service_task_advance/10`,
  # both above) do NOT call this directly any more -- TEST-DESIGNER proved
  # against real Postgres that both are reached from inside a further-out
  # caller's own already-open transaction
  # (`Letflow.Scheduler.fire_timer/2`, `Letflow.Engine.advance_after_service_task_outcome/4`
  # respectively), so calling this function from inside those two inline
  # clauses would only ever write into that same still-open outer
  # transaction and be rolled back with it. This function is `@doc false def`
  # (not `defp`) specifically so `Letflow.Scheduler.attempt_fire/2` and
  # `Letflow.Engine.ServiceTaskDispatcher.call_advance_after_service_task_outcome/3`
  # can call it themselves, strictly after their own respective outer
  # transaction has fully returned.
  #
  # Best-effort per design §6, matching `snapshot_instance/4`'s own
  # established "log and swallow" convention (~line 1465): a failure writing
  # this audit entry is logged via `Logger.warning/1` and never propagated --
  # it must never turn the original `{:invalid_form_schema, ...}` rollback
  # into a different error, and must never raise.
  @doc false
  @spec record_task_activation_rejection_audit(
          instance_id :: Ecto.UUID.t(),
          node_id :: String.t(),
          reason :: {:not_well_formed, path :: [String.t()]} | :too_deep,
          actor_id :: Ecto.UUID.t() | nil,
          prefix :: String.t()
        ) :: :ok
  def record_task_activation_rejection_audit(instance_id, node_id, reason, actor_id, prefix) do
    attrs = %{
      actor_id: actor_id,
      action: "task_activation.rejected",
      resource_type: "instance",
      resource_id: instance_id,
      before_state: nil,
      after_state: %{
        "node_id" => node_id,
        "reason" => encode_form_schema_rejection_reason(reason)
      },
      trace_id: nil
    }

    case Repo.transaction(fn -> Audit.insert_entry(Repo, attrs, prefix) end) do
      {:ok, {:ok, _entry}} ->
        :ok

      {:ok, {:error, insert_reason}} ->
        Logger.warning(
          "Letflow.Audit.insert_entry/3 failed recording task_activation.rejected for " <>
            "instance #{instance_id} (node #{node_id}): #{inspect(insert_reason)}"
        )

        :ok

      {:error, rollback_reason} ->
        Logger.warning(
          "Repo.transaction/1 failed recording task_activation.rejected for instance " <>
            "#{instance_id} (node #{node_id}): #{inspect(rollback_reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Repo.transaction/1 raised recording task_activation.rejected for instance " <>
          "#{instance_id} (node #{node_id}): #{inspect(exception)}"
      )

      :ok
  end

  # REQ-460 (design req459 §2.4, §5) -- one `task.completion_refused` audit record
  # for a refused HUMAN_TASK completion. Same shape and rules as
  # record_task_activation_rejection_audit/5 above: its own synchronous
  # Repo.transaction/1, direct Audit.insert_entry/3 (never append_multi/4, which hides
  # the same call), opened only after the refused transaction has returned, function-
  # level rescue, log-and-swallow, always :ok. Guarantee: AT MOST ONE record per
  # refused request, exactly one when the audit store is healthy. Carries ids and
  # key NAMES only -- never a submitted value, name or email. Must not be called
  # inside an enclosing transaction (it would roll back with it); the one caller is
  # interpret_complete_result/3.
  @doc false
  @spec record_completion_refusal_audit(
          instance_id :: Ecto.UUID.t(),
          task_id :: Ecto.UUID.t(),
          node_id :: String.t(),
          actor_id :: Ecto.UUID.t() | nil,
          refusal ::
            {:separation_of_duties, blocking_node_ids :: [String.t()]}
            | {:output_refused, missing_keys :: [String.t()], rejected_keys :: [String.t()]}
            | :entity_writes_not_planned,
          prefix :: String.t()
        ) :: :ok
  def record_completion_refusal_audit(instance_id, task_id, node_id, actor_id, refusal, prefix) do
    attrs = %{
      actor_id: actor_id,
      action: "task.completion_refused",
      resource_type: "task",
      resource_id: task_id,
      before_state: nil,
      after_state: completion_refusal_after_state(refusal, instance_id, node_id),
      trace_id: nil
    }

    case Repo.transaction(fn -> Audit.insert_entry(Repo, attrs, prefix) end) do
      {:ok, {:ok, _entry}} ->
        :ok

      {:ok, {:error, insert_reason}} ->
        Logger.warning(
          "Letflow.Audit.insert_entry/3 failed recording task.completion_refused for task " <>
            "#{task_id}: #{inspect(insert_reason)}"
        )

        :ok

      {:error, rollback_reason} ->
        Logger.warning(
          "Repo.transaction/1 failed recording task.completion_refused for task " <>
            "#{task_id}: #{inspect(rollback_reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Repo.transaction/1 raised recording task.completion_refused for task " <>
          "#{task_id}: #{inspect(exception)}"
      )

      :ok
  end

  # Rule A (REQ-463) records the sorted blocking node ids (the earlier completer is
  # the actor, so no other user id is repeated); rule C records key names only.
  defp completion_refusal_after_state(
         {:separation_of_duties, blocking_node_ids},
         instance_id,
         node_id
       ) do
    %{
      "rule" => "separation_of_duties",
      "instance_id" => instance_id,
      "node_id" => node_id,
      "blocking_node_ids" => Enum.sort(blocking_node_ids)
    }
  end

  defp completion_refusal_after_state(
         {:output_refused, missing_keys, rejected_keys},
         instance_id,
         node_id
       ) do
    %{
      "rule" => "output_refused",
      "instance_id" => instance_id,
      "node_id" => node_id,
      "missing_keys" => missing_keys,
      "rejected_keys" => rejected_keys
    }
  end

  # ISS-0928 -- best-effort audit for a SERVICE_TASK re-entry failure that is
  # NOT routed to an ExecutionError (hop limit, unknown token, variable-merge
  # rejection, DB failure ...). Called by
  # `ServiceTaskDispatcher.call_advance_after_service_task_outcome/3` strictly
  # after `advance_after_service_task_outcome/4` has returned, same
  # post-return rule and log-and-swallow, never-raise contract as
  # `record_task_activation_rejection_audit/5`. Stores/logs only ids and an
  # atom tag, never the failure reason (it can hold variables / response body).
  @doc false
  @spec record_service_task_advance_failure_audit(
          instance_id :: Ecto.UUID.t(),
          node_id :: String.t() | nil,
          reason_tag :: atom(),
          actor_id :: Ecto.UUID.t() | nil,
          prefix :: String.t()
        ) :: :ok
  def record_service_task_advance_failure_audit(
        instance_id,
        node_id,
        reason_tag,
        actor_id,
        prefix
      ) do
    attrs = %{
      actor_id: actor_id,
      action: "service_task.advance_failed",
      resource_type: "instance",
      resource_id: instance_id,
      before_state: nil,
      after_state: %{"node_id" => node_id, "reason" => Atom.to_string(reason_tag)},
      trace_id: nil
    }

    case Repo.transaction(fn -> Audit.insert_entry(Repo, attrs, prefix) end) do
      {:ok, {:ok, _entry}} ->
        :ok

      {:ok, {:error, _insert_reason}} ->
        Logger.warning(
          "Letflow.Audit.insert_entry/3 failed recording service_task.advance_failed for " <>
            "instance #{instance_id} (node #{node_id}, reason #{reason_tag})"
        )

        :ok

      {:error, _rollback_reason} ->
        Logger.warning(
          "Repo.transaction/1 failed recording service_task.advance_failed for instance " <>
            "#{instance_id} (node #{node_id}, reason #{reason_tag})"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Repo.transaction/1 raised recording service_task.advance_failed for instance " <>
          "#{instance_id} (node #{node_id}, reason #{reason_tag}): #{inspect(exception)}"
      )

      :ok
  end

  # ISS-0784 design §4.2 -- exhaustive encoder over
  # `Letflow.Definitions.JsonSchemaShape.check/1`'s own two-member error
  # union (minus the outer `:error` tag), for a JSON-safe `after_state`.
  # Deliberately has no catch-all clause: if that union ever grows a third
  # member, this fails to compile until updated (design §4.2/§10 OQ-2), which
  # is the intended signal rather than a silently masked new rejection shape.
  @spec encode_form_schema_rejection_reason({:not_well_formed, path :: [String.t()]} | :too_deep) ::
          map()
  defp encode_form_schema_rejection_reason({:not_well_formed, path}) do
    %{"code" => "not_well_formed", "path" => path}
  end

  defp encode_form_schema_rejection_reason(:too_deep) do
    %{"code" => "too_deep", "path" => nil}
  end
end
