defmodule Letflow.Entities.Record.Projector do
  @moduledoc """
  REQ-229 (ISS-0438 entity-subsystem port, slice 5 -- ports
  `src/entities/projector.zig`). See
  `lib/letflow/design/req229-entity-record-projection-replay.md` for the
  full design this module implements.

  Sits under `Letflow.Entities.Record.*` as a third sibling alongside
  `Letflow.Entities.Record.Validator` (REQ-227, inbound payload validation)
  and `Letflow.Entities.Record.Latest` (REQ-228, the persisted current-state
  schema, design §2). This module defines no `Ecto.Schema` of its own --
  every write it issues (`rebuild_projection/2` only; `replay_record/3` is
  entirely read-only) goes through `Letflow.Entities.Record.Latest`'s own
  existing changesets, never a second insert/update path.

  ## Deleted-record representation (AC2, stated here verbatim per the design
  doc §3.4/§8)

  A deleted record's snapshot is a `deleted: true` flag on the same
  row/snapshot -- no tombstone row, no removal from `entity_record_latest`,
  no separate table. Two fields, two DIFFERENT rules on delete, mirroring
  `Letflow.Entities.Records.upsert_record_latest/3`'s own already-shipped
  `:delete` clause exactly:

    * `field_values` is retained **unchanged** at its last pre-delete value
      -- genuinely carried forward, never recomputed from the `DELETED`
      event.
    * `entity_def_version` is **re-decoded from the `DELETED` event's own
      payload**, exactly like the `UPDATED` clause -- **never** carried
      forward from whatever it was before the delete. A record's active
      entity-type definition can advance between its last update and its
      deletion; `delete_record/2`'s own `base_payload/1` call (unconditional
      for all three event kinds) already bakes the definition version active
      *at delete time* into the `DELETED` event's payload, so replay must
      re-decode it there, not reuse the pre-delete value.

  Matching REQ-228's existing behavior field-by-field is not a stylistic
  preference -- it is the only choice under which "replay matches the live
  projection" (AC1/AC3) is a coherent statement at all.

  ## Flagged discrepancy -- `TenantProvisioning.tenant_id_for_schema_name/1`
  never actually returns `{:error, :tenant_not_provisioned}`

  The design doc's `replay_error()`/`rebuild_error()` types (and its step 1
  prose) list `{:error, :tenant_not_provisioned}` alongside
  `{:error, :invalid_schema_name}` for the tenant-schema guard. Reading
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` directly: every
  failure branch (malformed prefix, non-hex suffix, bad UUID cast) falls
  through to a single `{:error, :invalid_schema_name}` -- there is no
  `:tenant_not_provisioned` variant anywhere in that function's actual
  implementation, matching `Letflow.Entities.Record.Latest.get/3`'s own
  `@spec`, which lists only `{:error, :invalid_schema_name}` for the same
  guard call. `:tenant_not_provisioned` is kept in this module's error types
  below (matching the design doc verbatim, in case a future
  `TenantProvisioning` change adds a real distinction) but is dead as of
  this implementation -- flagged for REVIEWER rather than silently dropped
  from the type or silently invented as a real, reachable branch here.

  ## REQ-297 §9 -- `rebuild_projection/2` is the backfill mechanism for
  ## column promotion

  Per `docs/migration/decisions/0024-entity-promotion-ddl-execution.md` §3
  and `lib/letflow/design/req297-entity-promotion-executor.md` §9,
  `Letflow.TenantProvisioning.backfill_column_promotion/1` calls this
  module's `rebuild_projection/2` to populate a tenant's per-entity-type
  table. This module's own public `@spec` for `rebuild_projection/2` is
  **unchanged** -- no new opt was added -- so every existing caller is
  unaffected; what changed is `write_snapshots/3`'s *internal* behavior,
  via a new private `maybe_write_entity_table_snapshots/3` step that is a
  no-op whenever the entity type in question has no per-entity-type table
  yet (the ordinary case for every entity type that has never had a column
  promoted).
  """

  import Ecto.Query

  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @created_event "ENTITY_RECORD_CREATED"
  @updated_event "ENTITY_RECORD_UPDATED"
  @deleted_event "ENTITY_RECORD_DELETED"

  @type snapshot :: %{
          entity_type: String.t(),
          record_id: Ecto.UUID.t(),
          field_values: map(),
          deleted: boolean(),
          entity_def_version: binary(),
          external_system: String.t() | nil,
          external_id: String.t() | nil,
          last_event_global_seq: pos_integer(),
          last_event_sequence_number: pos_integer(),
          last_event_type: String.t()
        }

  @type replay_error ::
          {:error, :invalid_schema_name}
          | {:error, :tenant_not_provisioned}
          | {:error, :entity_type_not_found}
          | {:error, :record_not_found}
          | {:error, {:corrupt_event_stream, reason :: term()}}
          | {:error, term()}

  @typep merged_event :: %{
           event_type: String.t(),
           payload: map(),
           sequence_number: pos_integer(),
           global_seq: pos_integer(),
           event_id: Ecto.UUID.t()
         }

  # ---------------------------------------------------------------------
  # replay_record/3 (design doc §3, scope item 2)
  # ---------------------------------------------------------------------

  @doc """
  Replays one entity record's full event stream into a `snapshot()`,
  independent of whatever `entity_record_latest` currently holds. Read-only
  -- issues zero writes to any table. See the moduledoc for the exact
  deleted-record representation (AC2) and design doc §3.3 for the full
  per-event-type fold table this delegates to via `fold_record_events/3`.
  """
  @spec replay_record(entity_type :: String.t(), record_id :: Ecto.UUID.t(), prefix :: String.t()) ::
          {:ok, snapshot()} | replay_error()
  def replay_record(entity_type, record_id, prefix)
      when is_binary(entity_type) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, instance_id} <- fetch_synthetic_instance(entity_type, prefix),
         {:ok, events} <- EventStore.read(instance_id, prefix: prefix) do
      record_id_str = to_string(record_id)

      filtered =
        events
        |> Enum.filter(&(&1.payload["record_id"] == record_id_str))
        |> Enum.map(&to_merged_event/1)

      case filtered do
        [] -> {:error, :record_not_found}
        _ -> fold_record_events(entity_type, record_id, filtered)
      end
    end
  end

  defp fetch_synthetic_instance(entity_type, prefix) do
    case Repo.get(EntityTypeInstance, entity_type, prefix: prefix) do
      %EntityTypeInstance{instance_id: instance_id} -> {:ok, instance_id}
      nil -> {:error, :entity_type_not_found}
    end
  end

  defp to_merged_event(%Event{} = event) do
    %{
      event_type: event.event_type,
      payload: event.payload,
      sequence_number: event.sequence_number,
      global_seq: event.global_seq,
      event_id: event.event_id
    }
  end

  # ---------------------------------------------------------------------
  # rebuild_projection/2 (design doc §4, scope item 3)
  # ---------------------------------------------------------------------

  @type rebuild_opts :: [prefix: String.t(), entity_type: String.t() | nil]

  @type rebuild_result :: %{
          entity_types_rebuilt: [String.t()],
          records_rebuilt: non_neg_integer()
        }

  @type rebuild_error ::
          {:error, :invalid_schema_name}
          | {:error, :tenant_not_provisioned}
          | {:error, :entity_type_not_found}
          | {:error, {:corrupt_event_stream, reason :: term()}}
          | {:error, term()}

  @doc """
  Full re-projection of `entity_record_latest`, tenant- or (via
  `opts[:entity_type]`) entity-type-scoped, discarding and rewriting rows
  from the event log alone. One `Repo.transaction/1` call PER entity type
  (design doc §4.3) -- not one giant transaction spanning the whole tenant
  -- so a corrupt stream for one entity type aborts only that type's
  rebuild; every other type's already-committed rebuild stays committed.

  `opts[:entity_type]` absent/`nil` rebuilds every entity type this tenant
  schema has ever created a record for; a given `String.t()` rebuilds only
  that one entity type.
  """
  @spec rebuild_projection(prefix :: String.t(), opts :: rebuild_opts()) ::
          {:ok, rebuild_result()} | rebuild_error()
  def rebuild_projection(prefix, opts) when is_binary(prefix) and is_list(opts) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, entity_types} <- resolve_entity_types(Keyword.get(opts, :entity_type), prefix) do
      rebuild_each_entity_type(entity_types, prefix)
    end
  end

  defp resolve_entity_types(nil, prefix) do
    entity_types =
      EntityTypeInstance
      |> Repo.all(prefix: prefix)
      |> Enum.map(&{&1.entity_type, &1.instance_id})

    {:ok, entity_types}
  end

  defp resolve_entity_types(entity_type, prefix) when is_binary(entity_type) do
    case Repo.get(EntityTypeInstance, entity_type, prefix: prefix) do
      %EntityTypeInstance{instance_id: instance_id} -> {:ok, [{entity_type, instance_id}]}
      nil -> {:error, :entity_type_not_found}
    end
  end

  defp rebuild_each_entity_type(entity_types, prefix) do
    Enum.reduce_while(entity_types, {:ok, %{entity_types_rebuilt: [], records_rebuilt: 0}}, fn
      {entity_type, instance_id}, {:ok, acc} ->
        case rebuild_one_entity_type(entity_type, instance_id, prefix) do
          {:ok, count} ->
            {:cont,
             {:ok,
              %{
                entity_types_rebuilt: acc.entity_types_rebuilt ++ [entity_type],
                records_rebuilt: acc.records_rebuilt + count
              }}}

          {:error, _reason} = error ->
            {:halt, error}
        end
    end)
  end

  defp rebuild_one_entity_type(entity_type, instance_id, prefix) do
    with {:ok, events} <- EventStore.read(instance_id, prefix: prefix) do
      merged_events = Enum.map(events, &to_merged_event/1)

      grouped =
        merged_events
        |> Enum.group_by(& &1.payload["record_id"])

      case fold_all_records(entity_type, grouped) do
        {:ok, snapshots} ->
          write_snapshots(entity_type, snapshots, prefix)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp fold_all_records(entity_type, grouped) do
    Enum.reduce_while(grouped, {:ok, []}, fn {record_id_str, record_events}, {:ok, acc} ->
      case fold_record_events(entity_type, record_id_str, record_events) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      {:error, _reason} = error -> error
    end
  end

  defp write_snapshots(entity_type, snapshots, prefix) do
    Repo.transaction(fn ->
      {_count, _} =
        Repo.delete_all(from(r in Latest, where: r.entity_type == ^entity_type), prefix: prefix)

      Enum.each(snapshots, fn snapshot ->
        %Latest{}
        |> Latest.insert_changeset(%{
          entity_type: snapshot.entity_type,
          record_id: snapshot.record_id,
          field_values: snapshot.field_values,
          entity_def_version: snapshot.entity_def_version,
          last_event_global_seq: snapshot.last_event_global_seq,
          external_system: snapshot.external_system,
          external_id: snapshot.external_id
        })
        |> maybe_mark_deleted(snapshot.deleted)
        |> Repo.insert!(prefix: prefix)
      end)

      case maybe_write_entity_table_snapshots(entity_type, snapshots, prefix) do
        :ok -> length(snapshots)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # ---------------------------------------------------------------------
  # REQ-297 §9 -- backfill's write side. New private step, called from
  # write_snapshots/3 immediately after its existing Latest
  # delete+reinsert, inside the SAME Repo.transaction/1. Public @spec of
  # rebuild_projection/2 above is UNCHANGED -- no new opt, every existing
  # caller is unaffected. A rebuild for an entity type with no
  # per-entity-type table yet (the ordinary case for every entity type that
  # has never had a column promoted) does nothing extra, preserving
  # today's behavior exactly.
  # ---------------------------------------------------------------------

  defp maybe_write_entity_table_snapshots(entity_type, snapshots, prefix) do
    with {:ok, table_name} <- TenantProvisioning.table_name_for_entity_type(entity_type) do
      if TenantProvisioning.entity_table_exists?(prefix, table_name) do
        write_entity_table_snapshots(entity_type, table_name, snapshots, prefix)
      else
        :ok
      end
    end
  end

  # Writes structural columns plus every column DDL.promoted_columns/1
  # reports for the entity type's CURRENT definition (not only the one
  # attribute the in-progress promotion targets) -- so a rebuild started
  # for promotion N also correctly repopulates any promotion 1..N-1 columns
  # that already reached "active" for this tenant. Row-count parity with
  # the Latest reinsert above is guaranteed by construction: the same
  # `snapshots` list drives both writes, in the same transaction.
  defp write_entity_table_snapshots(entity_type, table_name, snapshots, prefix) do
    with {:ok, definition} <- Definitions.get_active_definition_by_name(entity_type, prefix) do
      document = TenantProvisioning.document_from_persisted(definition)
      promoted = DDL.promoted_columns(document)

      unless DDL.valid_identifier?(table_name) do
        raise ArgumentError, "invalid per-entity-type table_name: #{inspect(table_name)}"
      end

      Repo.query!(~s(DELETE FROM "#{prefix}"."#{table_name}"))

      Enum.each(snapshots, fn snapshot ->
        insert_entity_table_row(prefix, table_name, promoted, snapshot)
      end)

      :ok
    end
  end

  defp insert_entity_table_row(prefix, table_name, promoted, snapshot) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    promoted_pairs =
      Enum.map(promoted, fn %{name: name, pg_type: pg_type} ->
        unless DDL.valid_identifier?(name) do
          raise ArgumentError, "invalid promoted column_name: #{inspect(name)}"
        end

        raw_value = Map.get(snapshot.field_values, name)
        {name, TenantProvisioning.cast_promoted_value(raw_value, pg_type)}
      end)

    structural_columns = [
      "id",
      "record_id",
      "field_values",
      "deleted",
      "entity_def_version",
      "last_event_global_seq",
      "inserted_at",
      "updated_at"
    ]

    structural_values = [
      Ecto.UUID.generate(),
      snapshot.record_id,
      Jason.encode!(snapshot.field_values),
      snapshot.deleted,
      snapshot.entity_def_version,
      snapshot.last_event_global_seq,
      now,
      now
    ]

    all_columns = structural_columns ++ Enum.map(promoted_pairs, &elem(&1, 0))
    all_values = structural_values ++ Enum.map(promoted_pairs, &elem(&1, 1))

    uuid_columns =
      promoted
      |> Enum.filter(&(&1.pg_type == "uuid"))
      |> Enum.map(& &1.name)
      |> MapSet.new()

    # `($n::text)::uuid`/`($n::text)::jsonb`, not a bare `$n::uuid`/`$n::jsonb`
    # -- mirrors `Letflow.Entities.Records.placeholder_list/1`'s own comment
    # for the full rationale. `uuid_columns` (REQ-298) generalizes the same
    # cast to any promoted column whose pg_type is "uuid" (an FK-promoted
    # column), not just the hardcoded structural "id"/"record_id".
    placeholders =
      all_columns
      |> Enum.with_index(1)
      |> Enum.map(fn
        {"id", i} -> "($#{i}::text)::uuid"
        {"record_id", i} -> "($#{i}::text)::uuid"
        {"field_values", i} -> "($#{i}::text)::jsonb"
        {col, i} -> if MapSet.member?(uuid_columns, col), do: "($#{i}::text)::uuid", else: "$#{i}"
      end)

    column_list = Enum.map_join(all_columns, ", ", &~s("#{&1}"))

    sql =
      "INSERT INTO \"#{prefix}\".\"#{table_name}\" (#{column_list}) VALUES (#{Enum.join(placeholders, ", ")})"

    Repo.query!(sql, all_values)
  end

  # `Latest.insert_changeset/2`'s `@insert_fields` never casts `:deleted`
  # (design doc §6.1, `Latest` moduledoc) -- a rebuilt row for a deleted
  # record must still land with `deleted: true`, so this puts the field
  # directly onto the changeset's `changes` after `insert_changeset/2` has
  # already validated everything else, exactly mirroring how a struct
  # literal's default would be overridden, without inventing a second
  # insert-time changeset function on `Latest` itself.
  defp maybe_mark_deleted(changeset, false), do: changeset

  defp maybe_mark_deleted(changeset, true),
    do: Ecto.Changeset.put_change(changeset, :deleted, true)

  # ---------------------------------------------------------------------
  # Shared fold helper (design doc §5) -- @doc false, not public API.
  # Single implementation of the §3.3 step 6 fold table, called once per
  # record by replay_record/3 and once per distinct record_id group by
  # rebuild_projection/2.
  # ---------------------------------------------------------------------

  @doc false
  @spec fold_record_events(
          entity_type :: String.t(),
          record_id :: Ecto.UUID.t() | String.t(),
          events :: [merged_event()]
        ) :: {:ok, snapshot()} | {:error, {:corrupt_event_stream, term()}}
  def fold_record_events(entity_type, record_id, events) do
    Enum.reduce_while(events, {:ok, nil}, fn event, {:ok, acc} ->
      case apply_event(acc, event, record_id) do
        {:ok, new_acc} -> {:cont, {:ok, new_acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, nil} ->
        {:error, {:corrupt_event_stream, {:missing_created_event, record_id}}}

      {:ok, acc} ->
        {:ok, Map.put(acc, :entity_type, entity_type)}

      {:error, _reason} = error ->
        error
    end
  end

  # First event must be CREATED.
  defp apply_event(nil, %{event_type: @created_event} = event, record_id) do
    {:ok,
     %{
       record_id: record_id,
       field_values: Map.get(event.payload, "field_values", %{}),
       deleted: false,
       entity_def_version: decode_entity_def_version(event.payload),
       external_system: external_ref_part(event.payload, "system"),
       external_id: external_ref_part(event.payload, "id"),
       last_event_global_seq: event.global_seq,
       last_event_sequence_number: event.sequence_number,
       last_event_type: event.event_type
     }}
  end

  defp apply_event(nil, %{event_type: event_type}, record_id)
       when event_type in [@updated_event, @deleted_event] do
    {:error, {:corrupt_event_stream, {:missing_created_event, record_id}}}
  end

  # A second CREATED (not yet deleted).
  defp apply_event(%{deleted: false}, %{event_type: @created_event}, record_id) do
    {:error, {:corrupt_event_stream, {:duplicate_created_event, record_id}}}
  end

  # UPDATED while not deleted: field_values replaced wholesale,
  # entity_def_version re-decoded from this event's own payload.
  defp apply_event(%{deleted: false} = acc, %{event_type: @updated_event} = event, _record_id) do
    {:ok,
     %{
       acc
       | field_values: Map.get(event.payload, "field_values", %{}),
         entity_def_version: decode_entity_def_version(event.payload),
         last_event_global_seq: event.global_seq,
         last_event_sequence_number: event.sequence_number,
         last_event_type: event.event_type
     }}
  end

  # DELETED while not deleted: field_values left UNCHANGED at its pre-delete
  # value; entity_def_version re-decoded from THIS event's own payload
  # (identical rule to the UPDATED clause above -- never carried forward).
  defp apply_event(%{deleted: false} = acc, %{event_type: @deleted_event} = event, _record_id) do
    {:ok,
     %{
       acc
       | deleted: true,
         entity_def_version: decode_entity_def_version(event.payload),
         last_event_global_seq: event.global_seq,
         last_event_sequence_number: event.sequence_number,
         last_event_type: event.event_type
     }}
  end

  # Any event after a DELETED (already-deleted accumulator).
  defp apply_event(%{deleted: true}, %{event_type: event_type, event_id: event_id}, record_id) do
    {:error, {:corrupt_event_stream, {:event_after_delete, record_id, event_type, event_id}}}
  end

  # Unrecognized event_type, at any fold state.
  defp apply_event(_acc, %{event_type: event_type, event_id: event_id}, _record_id) do
    {:error, {:corrupt_event_stream, {:unrecognized_event_type, event_type, event_id}}}
  end

  # GH #2659: the master external_ref is set only by CREATED (optional payload object); UPDATED
  # and DELETED carry the accumulator's pair forward unchanged (the `%{acc | ...}` clauses above
  # never touch it) and never clear it.
  defp external_ref_part(payload, key) do
    case Map.get(payload, "external_ref") do
      %{^key => value} when is_binary(value) -> value
      _ -> nil
    end
  end

  # Mirrors `Letflow.Entities.Records`'s own `duplicate_result/1`/`hex_version/1`
  # decode of `payload["entity_def_version"]` (hex string -> binary via
  # `Base.decode16!/2`) -- one decode convention, not a second independently
  # drifting copy (design doc §3.3 step 6, §7 item 2).
  defp decode_entity_def_version(payload) do
    payload
    |> Map.fetch!("entity_def_version")
    |> Base.decode16!(case: :lower)
  end
end
