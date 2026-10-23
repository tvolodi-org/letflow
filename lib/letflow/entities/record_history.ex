defmodule Letflow.Entities.RecordHistory do
  @moduledoc """
  Visibility and event paging for a record's history (REQ-516 S2, GH #2701).

  A record's create, update and delete events sit on its entity type's synthetic instance
  (`entity_type_instances`), which the Instances routes hide (GH #2702). This context reads
  those events for ONE record. It decides visibility first, so the router answers a hidden
  record and an absent one with the same 404 (INV-5), and it is the only module of the history
  route that calls `Repo` (the router handlers must not, see `req317_record_attachments_routes_test`).

  Visibility, in order, with the same refusal for every step:

    * the caller holds the type (`TypeAccess`);
    * scope `:all` sees any existing record, deleted rows included, as `Latest.get/3` does;
    * scope `:none` sees nothing, with no statement;
    * a scoped caller on a `{:column, _}` type sees what `ScopedLookup.fetch_in_scope/5` allows;
    * a scoped caller on a `:tenant_wide` type sees an existing record, as `all_in_scope?/4`
      does for the 0051 read filter (a read, not the write refusal of R-6);
    * an `:undeclared` type is not visible.

  Payloads leave this module resolved: an oversized payload stored as `{"$ref": event_id}` is
  read from `event_payload_store` in the same statement (COALESCE), so no pointer escapes and
  restricted values inside it are redacted like the others (the caller redacts with
  `Letflow.Entities.FieldPolicy`).
  """

  import Ecto.Query

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Entities.ScopedLookup
  alias Letflow.Entities.TypeAccess
  alias Letflow.Repo

  @typedoc "One event of a record's history, its payload resolved (`$ref` read through)."
  @type event_row :: %{
          event_id: Ecto.UUID.t(),
          event_type: String.t(),
          sequence_number: non_neg_integer(),
          created_at: DateTime.t(),
          actor_id: Ecto.UUID.t() | nil,
          payload: map()
        }

  @telemetry {:entity_record_history, :by_id}

  @doc """
  Whether the caller may read the history of `record_id` of `entity_type` (see the moduledoc).
  `:not_found` is the one refusal for a denied type, an invisible record, an absent record and
  an unknown type name.
  """
  @spec visible?(
          user_id :: String.t(),
          entity_type :: String.t(),
          record_id :: Ecto.UUID.t(),
          scope :: Types.scope_set(),
          prefix :: String.t()
        ) :: :ok | :not_found
  def visible?(user_id, entity_type, record_id, scope, prefix) do
    case TypeAccess.authorized?(user_id, entity_type, prefix) do
      {:ok, :allowed} -> visible_in_scope(scope, entity_type, record_id, prefix)
      _denied_or_invalid -> :not_found
    end
  end

  defp visible_in_scope(:all, entity_type, record_id, prefix),
    do: latest_exists(entity_type, record_id, prefix)

  defp visible_in_scope(:none, _entity_type, _record_id, _prefix), do: :not_found

  defp visible_in_scope({:nodes, _ids} = scope, entity_type, record_id, prefix) do
    case ScopeDeclaration.for_type(entity_type, prefix) do
      {:column, _column} ->
        case ScopedLookup.fetch_in_scope(entity_type, record_id, scope, prefix, @telemetry) do
          {:ok, _declaration} -> :ok
          :not_found -> :not_found
        end

      :tenant_wide ->
        case latest_exists(entity_type, record_id, prefix) do
          :ok ->
            :ok

          :not_found ->
            ScopedLookup.emit_not_found(:entity_record_history, :by_id)
            :not_found
        end

      :undeclared ->
        :not_found
    end
  end

  # `Latest.get/3` answers `{:error, :invalid_schema_name}` as well; every non-`{:ok, _}` is absent.
  defp latest_exists(entity_type, record_id, prefix) do
    case Latest.get(record_id, entity_type, prefix) do
      {:ok, _record} -> :ok
      _not_found_or_invalid -> :not_found
    end
  end

  @doc """
  One page of the record's events on its entity type's synthetic instance, oldest first: at most
  `limit` rows whose `sequence_number` is above `after_seq` (all rows when `nil`). The caller
  asks for `page_size + 1` rows to learn whether a next page exists. Does not check visibility;
  call `visible?/5` first.
  """
  @spec events_page(
          prefix :: String.t(),
          entity_type :: String.t(),
          record_id :: Ecto.UUID.t(),
          after_seq :: non_neg_integer() | nil,
          limit :: pos_integer()
        ) :: {:ok, [event_row()]} | {:error, :not_found}
  def events_page(prefix, entity_type, record_id, after_seq, limit) do
    case EntityTypeInstance.fetch_instance_id(entity_type, prefix) do
      {:ok, instance_id} ->
        rows =
          instance_id
          |> page_query(record_id, limit)
          |> after_seq_filter(after_seq)
          |> Repo.all(prefix: prefix)

        {:ok, rows}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # The `events` and `event_payload_store` tables have no schema here, so the uuid columns and
  # parameters carry their types explicitly (a string parameter for a uuid column is rejected,
  # and an untyped uuid selects as 16 raw bytes).
  defp page_query(instance_id, record_id, limit) do
    from(e in "events",
      left_join: sp in "event_payload_store",
      on: sp.event_id == e.event_id and sp.event_created_at == e.created_at,
      where: e.instance_id == type(^instance_id, Ecto.UUID),
      where: e.event_type in ^EventTypes.record_event_names(),
      where: fragment("(COALESCE(?, ?)) ->> 'record_id'", sp.payload, e.payload) == ^record_id,
      order_by: [asc: e.sequence_number],
      limit: ^limit,
      select: %{
        event_id: type(e.event_id, Ecto.UUID),
        event_type: e.event_type,
        sequence_number: e.sequence_number,
        created_at: type(e.created_at, :utc_datetime_usec),
        actor_id: type(e.actor_id, Ecto.UUID),
        payload: fragment("COALESCE(?, ?)", sp.payload, e.payload)
      }
    )
  end

  defp after_seq_filter(query, nil), do: query

  defp after_seq_filter(query, after_seq),
    do: where(query, [e], e.sequence_number > ^after_seq)
end
