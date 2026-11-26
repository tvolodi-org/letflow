defmodule Letflow.Audit.Entry do
  @moduledoc """
  Ecto schema for the `audit_entries` table (REQ-195). Tenant-scoped -- lives
  in each tenant's own Postgres schema, per Decision 0003-B, alongside
  `users`/`groups`/`api_tokens`. See
  `lib/letflow/design/req195-audit-entry-storage.md` §1 for the full column
  rationale (in particular §1.2's `resource_id :: :string` decision) and
  `Letflow.Audit`'s own moduledoc for the canonical hashed form these rows
  participate in.

  A plain schema module -- no public functions beyond `changeset/2`
  (structural cast/validate_required only). Domain rules (hash computation,
  chain-tail resolution, tenant-id derivation) live in `Letflow.Audit`, not
  here, matching this codebase's convention of keeping business logic in the
  context module.

  Every persisted row is immutable at the database level (a `BEFORE
  UPDATE`/`BEFORE DELETE` trigger installed by this table's own migration
  rejects any mutation) -- `changeset/2` is only ever used to build the
  attributes for a single `Repo.insert/2` call, never for an update.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "audit_entries" do
    field(:tenant_id, :binary_id)
    field(:actor_id, :binary_id)
    # T-2588 (pilot gap G2, decision (d)): the KIND of the actor -- "user" (a
    # person) or "system" (module code, a seed task, a job). NULL for the rows
    # written before this column existed. It is NOT part of the chain hash
    # (REQ-195's canonical hashed form names eleven fields and stays as it is);
    # the table's own immutability trigger keeps the value from being edited
    # after the row is written.
    field(:actor_kind, :string)
    field(:action, :string)
    field(:resource_type, :string)
    field(:resource_id, :string)
    field(:timestamp, :utc_datetime_usec)
    field(:before_state, :map)
    field(:after_state, :map)
    field(:trace_id, :string)
    field(:chain_hash, :string)
    field(:prev_chain_hash, :string)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required_fields [
    :id,
    :tenant_id,
    :action,
    :resource_type,
    :resource_id,
    :timestamp,
    :chain_hash
  ]

  @castable_fields [
    :id,
    :tenant_id,
    :actor_id,
    :actor_kind,
    :action,
    :resource_type,
    :resource_id,
    :timestamp,
    :before_state,
    :after_state,
    :trace_id,
    :chain_hash,
    :prev_chain_hash
  ]

  @doc """
  Structural insert changeset -- `Letflow.Audit.insert_entry/3` supplies
  every field itself (including the pre-generated `id`, per the canonical
  hash form's own requirement that `id` be known before hashing, design §5.1)
  and this changeset only casts/validates presence; it does not compute
  `chain_hash`, resolve `tenant_id`, or apply any other domain rule.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = entry, attrs) do
    entry
    |> cast(attrs, @castable_fields)
    |> validate_required(@required_fields)
  end
end
