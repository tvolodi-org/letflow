defmodule Letflow.ModuleUpgrade.Writer do
  @moduledoc """
  The internal writer of a module data migration (REQ-683, decision 0055 D3, build step 2b).

  A migration never writes the record projection directly. `migrate_record/5` appends one
  `ENTITY_RECORD_MIGRATED` event through `Letflow.EventStore.append_multi/3` and applies it with
  the same live projection steps the record commands use
  (`Letflow.Entities.Record.LiveProjection`); replay and rebuild follow from the event
  (`Projector.fold_record_events/3`). Nothing in `lib/` calls it yet; the upgrade runner of a
  later slice will.

  ## Reachability and hooks

  The first argument must be a `Letflow.ModuleUpgrade.Capability`, which carries the tenant
  prefix, upgrade id, plan hash and actor. The boundary rule 9 keeps other files from referencing
  this module. The writer builds none of the `Letflow.Entities.Records` command steps, so tenant
  write hooks, the record-trigger outbox, the hook audit row and the managed-type guard do not run
  for a migrated record (the bypass rule of D3). It writes no `x_` key (the tenant extension
  layer is not module-owned data).

  ## Transaction and locks

  One `Repo.transaction/1`, joining the caller's when one is open. Order: the type's synthetic
  instance, the instance sequence lock, the record row `FOR UPDATE`, then the decisions, then the
  append and the projection (decision 0061 item 5: the same order as the `Records` update path).
  The idempotency key needs the locked row's `last_event_global_seq`, so the sequence lock is
  taken before the append; `append_multi/3` takes the same row again inside the same transaction.

  A failed append or projection step returns `{:error, reason}` and, inside a caller's open
  transaction, rolls that transaction back (Ecto behaviour); a caller treats any error as a failed
  batch. The duplicate-idempotency branch cannot be reached under the lock (the key embeds the
  row's `last_event_global_seq`, which the append changes), so it is not mapped specially. The
  writer rescues nothing and logs nothing.
  """

  alias Ecto.Multi
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.Record.LiveProjection
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore
  alias Letflow.ModuleUpgrade.Capability
  alias Letflow.Repo

  @event_type "ENTITY_RECORD_MIGRATED"
  @key_prefix "module_upgrade:"

  @type result ::
          {:ok, :appended | :unchanged | :skipped_deleted}
          | {:error, :x_key_not_writable | :entity_type_not_found | :record_not_found | term()}

  @doc false
  @spec migrate_record(Capability.t(), String.t(), Ecto.UUID.t(), map(), String.t()) :: result()
  def migrate_record(%Capability{} = capability, entity_type, record_id, after_values, step_id)
      when is_binary(entity_type) and is_binary(record_id) and is_map(after_values) and
             is_binary(step_id) do
    if Enum.any?(Map.keys(after_values), &x_key?/1) do
      {:error, :x_key_not_writable}
    else
      transact(fn -> run(capability, entity_type, record_id, after_values, step_id) end)
    end
  end

  defp transact(fun) do
    case Repo.transaction(fn -> unwrap(fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # Inside the transaction an error rolls back so a joined outer transaction is not left half done
  # by a caller that ignores the error; a decision result (`:unchanged` ...) commits as is.
  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: Repo.rollback(reason)

  defp run(capability, entity_type, record_id, after_values, step_id) do
    prefix = capability.prefix

    with {:ok, instance_id} <- fetch_instance(entity_type, prefix),
         {:ok, :locked} <- EventStore.lock_instance_sequence(Repo, instance_id, prefix),
         {:ok, locked} <- fetch_locked(record_id, entity_type, prefix) do
      decide(capability, instance_id, locked, entity_type, after_values, step_id)
    end
  end

  defp fetch_instance(entity_type, prefix) do
    case EntityTypeInstance.fetch_instance_id(entity_type, prefix) do
      {:ok, _instance_id} = ok -> ok
      {:error, :not_found} -> {:error, :entity_type_not_found}
    end
  end

  defp fetch_locked(record_id, entity_type, prefix) do
    case Latest.get_for_update(Repo, record_id, entity_type, prefix) do
      %Latest{} = locked -> {:ok, locked}
      nil -> {:error, :record_not_found}
    end
  end

  defp decide(_capability, _instance_id, %Latest{deleted: true}, _type, _after, _step) do
    {:ok, :skipped_deleted}
  end

  defp decide(capability, instance_id, %Latest{} = locked, entity_type, after_values, step_id) do
    if unchanged?(locked.field_values, after_values) do
      {:ok, :unchanged}
    else
      append(capability, instance_id, locked, entity_type, after_values, step_id)
    end
  end

  # `==` on decoded JSON terms: a numerically equal value (1 and 1.0) is unchanged.
  defp unchanged?(field_values, after_values) do
    Enum.all?(after_values, fn {key, value} ->
      Map.has_key?(field_values, key) and Map.fetch!(field_values, key) == value
    end)
  end

  defp append(capability, instance_id, locked, entity_type, after_values, step_id) do
    before_values = Map.new(Map.keys(after_values), &{&1, Map.get(locked.field_values, &1)})

    payload = %{
      "entity_type" => entity_type,
      "record_id" => locked.record_id,
      "entity_def_version" => Base.encode16(locked.entity_def_version, case: :lower),
      "upgrade_id" => capability.upgrade_id,
      "step_id" => step_id,
      "plan_hash" => capability.plan_hash,
      "before" => before_values,
      "after" => after_values
    }

    attrs = %{
      instance_id: instance_id,
      event_type: @event_type,
      payload: Jason.encode!(payload),
      actor_id: capability.actor_id,
      idempotency_key: idempotency_key(capability, step_id, locked)
    }

    ctx = %{
      kind: :update,
      entity_type: entity_type,
      record_id: locked.record_id,
      field_values: Map.merge(locked.field_values, after_values),
      entity_def_version: locked.entity_def_version,
      existing_record: locked,
      prefix: capability.prefix,
      external_ref: nil
    }

    with {:ok, multi} <- EventStore.append_multi(Multi.new(), attrs, prefix: capability.prefix),
         {:ok, _changes} <- Repo.transaction(project(multi, ctx)) do
      {:ok, :appended}
    else
      {:error, _step, reason, _changes} -> {:error, reason}
      {:error, _reason} = error -> error
    end
  end

  defp project(multi, ctx) do
    multi
    |> Multi.run(:upsert_record_latest, fn repo, changes ->
      LiveProjection.upsert_record_latest(repo, changes, ctx)
    end)
    |> Multi.run(:dual_write_promoted_columns, fn repo, changes ->
      LiveProjection.dual_write_promoted_columns(repo, changes, ctx)
    end)
  end

  defp idempotency_key(capability, step_id, locked) do
    material =
      Enum.join(
        [
          capability.upgrade_id,
          step_id,
          locked.record_id,
          Integer.to_string(locked.last_event_global_seq)
        ],
        ":"
      )

    @key_prefix <> Base.encode16(:crypto.hash(:sha256, material), case: :lower)
  end

  defp x_key?(key) when is_binary(key), do: String.starts_with?(key, "x_")
  defp x_key?(_key), do: false
end
