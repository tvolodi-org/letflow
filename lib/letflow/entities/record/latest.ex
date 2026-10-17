defmodule Letflow.Entities.Record.Latest do
  @moduledoc """
  `Ecto.Schema` for `entity_record_latest` (REQ-228) — the JSONB
  current-state projection table for entity records. See
  `lib/letflow/design/req228-entity-event-registration-commands.md` §5.3/§6.1
  for the full design this module implements.

  Sits under `Letflow.Entities.Record.*` alongside
  `Letflow.Entities.Record.Validator` (REQ-227) — both describe the "one
  entity record" concern, one for inbound payload validation, one for the
  persisted current-state row (design §3).

  This module is a plain write/read target for `Letflow.Entities.Records`'s
  command functions — no replay, no fold over prior events, no consultation
  of `instance_sequence`. Rebuild/replay from the event log is REQ-229's own
  scope (design §5.3).
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "entity_record_latest" do
    field(:entity_type, :string)
    field(:record_id, Ecto.UUID)
    field(:field_values, :map, default: %{})
    field(:deleted, :boolean, default: false)
    field(:entity_def_version, :binary)
    field(:last_event_global_seq, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @insert_fields [
    :entity_type,
    :record_id,
    :field_values,
    :entity_def_version,
    :last_event_global_seq
  ]

  @update_fields [:field_values, :deleted, :entity_def_version, :last_event_global_seq]

  @doc """
  Structural insert changeset — `create_record/2`'s own `:upsert_record_latest`
  step (design §5.1 step 4). `:entity_type`/`:record_id`/`:field_values`/
  `:entity_def_version`/`:last_event_global_seq` are required; `:deleted`
  defaults `false`, never cast on insert (design §6.1).
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(record, attrs) do
    record
    |> cast(attrs, @insert_fields)
    |> validate_required(@insert_fields)
    |> unique_constraint([:entity_type, :record_id],
      name: :entity_record_latest_entity_type_record_id_idx
    )
  end

  @doc """
  Structural update changeset — `update_record/2`/`delete_record/2`'s own
  `:upsert_record_latest` step (design §5.2). `:entity_type`/`:record_id` are
  structurally immutable after insert, matching
  `Letflow.EventStore.InstanceProjection.update_changeset/2`'s own
  immutable-identity-fields precedent — neither is castable here.
  """
  @spec update_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def update_changeset(record, attrs) do
    record
    |> cast(attrs, @update_fields)
    |> validate_required(@update_fields)
  end

  @doc """
  Fetches the current-state row for `(entity_type, record_id)`, scoped to
  the tenant schema named by `prefix`. Never raises — `nil` becomes
  `{:error, :not_found}`.

  Returns soft-deleted rows too (`deleted: true`); callers that must not see
  them use `get_live/3`.
  """
  @spec get(record_id :: Ecto.UUID.t(), entity_type :: String.t(), prefix :: String.t()) ::
          {:ok, t()} | {:error, :not_found} | {:error, :invalid_schema_name}
  def get(record_id, entity_type, prefix)
      when is_binary(entity_type) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query =
        from(r in __MODULE__, where: r.entity_type == ^entity_type and r.record_id == ^record_id)

      case Repo.one(query, prefix: prefix) do
        nil -> {:error, :not_found}
        %__MODULE__{} = record -> {:ok, record}
      end
    end
  end

  @doc """
  Like `get/3`, but a soft-deleted row is `{:error, :not_found}`, byte-identical
  to an absent row (GH #2734). The `deleted == false` condition is part of the
  SQL predicate, so a deleted row is never loaded. Same prefix validation as
  `get/3`; `record_id` must already be a valid UUID.
  """
  @spec get_live(record_id :: Ecto.UUID.t(), entity_type :: String.t(), prefix :: String.t()) ::
          {:ok, t()} | {:error, :not_found} | {:error, :invalid_schema_name}
  def get_live(record_id, entity_type, prefix)
      when is_binary(entity_type) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query =
        from(r in __MODULE__,
          where:
            r.entity_type == ^entity_type and r.record_id == ^record_id and r.deleted == false
        )

      case Repo.one(query, prefix: prefix) do
        nil -> {:error, :not_found}
        %__MODULE__{} = record -> {:ok, record}
      end
    end
  end

  @doc """
  Re-reads the current-state row for `(entity_type, record_id)` with a row
  lock (`SELECT ... FOR UPDATE`), inside the caller's transaction (GH #2528,
  `lib/letflow/design/gh2528-record-version-conflict.md` §4). Returns `nil`
  when the row is absent.

  Does not re-validate `prefix` via `tenant_id_for_schema_name/1`: the only
  caller (`Letflow.Entities.Records`' `:check_record_version` step) passes the
  same `prefix` that `get/3` already validated in the same command call,
  before the transaction. Scoping comes from `prefix` plus the
  `entity_type`+`record_id` predicate on the unique index
  `entity_record_latest_entity_type_record_id_idx` (INV-6); the lock is
  Ecto query composition, no SQL string (INV-7).
  """
  @spec get_for_update(
          repo :: Ecto.Repo.t(),
          record_id :: Ecto.UUID.t(),
          entity_type :: String.t(),
          prefix :: String.t()
        ) :: t() | nil
  def get_for_update(repo, record_id, entity_type, prefix)
      when is_binary(entity_type) and is_binary(prefix) do
    query =
      from(r in __MODULE__,
        where: r.entity_type == ^entity_type and r.record_id == ^record_id,
        lock: "FOR UPDATE"
      )

    repo.one(query, prefix: prefix)
  end
end
