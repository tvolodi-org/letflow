defmodule Letflow.Entities.EntityTypeInstance do
  @moduledoc """
  `Ecto.Schema` for `entity_type_instances` (REQ-228) — the
  synthetic-instance-per-entity-TYPE mapping. See
  `lib/letflow/design/req228-entity-event-registration-commands.md` §2/§6.2
  for the full design this module implements.

  One row per distinct `entity_type` name ever created in a tenant schema,
  mapping it to the synthetic `instance_projections.instance_id` every event
  for that entity type appends against — never one row per entity
  **record** (§2's resolved open design question).

  ## `get_or_create/2` runs as a plain, eager function — NOT a lazy
  `Ecto.Multi` step (flagged deviation from the design's literal §3.2
  framing)

  §3.2 of the design describes `entity_type_instance_guard` as a
  `Multi.run/3` step `Letflow.Entities.Records` prepends onto the same
  `Ecto.Multi` that `Letflow.EventStore.append_multi/3`'s own steps and
  `:upsert_record_latest` are folded into. That framing is structurally
  incompatible with `append_multi/3`'s own signature: `append_multi/3`
  takes `attrs :: EventStore.append_attrs()`, which requires a **concrete**
  `instance_id` value — the synthetic instance for `entity_type` — at the
  moment `append_multi/3` is *called* (i.e. at `Ecto.Multi` composition
  time, in plain Elixir code, before `Repo.transaction/1` ever runs). A
  lazy `Multi.run/3` step's result is only available inside `changes`, at
  transaction *execution* time — by definition too late to have already
  been used to build the `attrs` map passed into `append_multi/3` earlier
  in the same function.

  This module resolves that gap by making `get_or_create/2` a plain, eager
  function: `Letflow.Entities.Records`'s command functions call it directly
  (using `Letflow.Repo`, not a `Multi`-supplied `repo`) to obtain a concrete
  `instance_id` *before* building any `Ecto.Multi`, then feed that value
  into `append_multi/3`'s `attrs[:instance_id]`. This function's own
  get-or-create protocol (below) is still race-safe under concurrent
  first-creation for the same brand-new `entity_type` — the same
  insert-if-absent-then-re-select idiom `Letflow.EventStore`'s own
  `assign_sequence/3`/`claim_idempotency/3` already use — so no correctness
  guarantee from the design is lost, only the literal "one Multi step"
  framing. AC2's atomicity guarantee (event append + `entity_record_latest`
  update, one transaction, forced-failure-leaves-neither-committed) is
  unaffected: `entity_type_instance_guard`'s own row is not part of the
  transaction boundary AC2 tests. Flagged here explicitly for
  SECURITY-REVIEWER/REVIEWER, per this project's "flag, don't silently
  diverge" convention.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo

  @primary_key {:entity_type, :string, autogenerate: false}
  schema "entity_type_instances" do
    field(:instance_id, Ecto.UUID)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc """
  Structural insert changeset. Does no I/O.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(entity_type_instance, attrs) do
    entity_type_instance
    |> cast(attrs, [:entity_type, :instance_id])
    |> validate_required([:entity_type, :instance_id])
    |> unique_constraint(:entity_type, name: :entity_type_instances_pkey)
  end

  @doc """
  Resolves `entity_type`'s synthetic `instance_id`, minting one (plus its
  matching `instance_projections` row) on first use. Design §6.2's protocol:

    1. Read — if a row already exists for `entity_type`, return its
       `instance_id` with no writes (one joined read also checks the projection; a
       missing projection is healed with the same `on_conflict: :nothing` ensure).
    2. Else, mint a fresh `instance_id`, insert this table's row
       (`on_conflict: :nothing`), re-read the row and take **that** row's
       `instance_id` (whichever concurrent caller's insert actually won the race),
       never the locally-minted one blindly, then insert the matching
       `instance_projections` row for that winning id only (`on_conflict: :nothing`,
       `status: :active`, `definition_id` set to the same `instance_id` — a
       placeholder reuse flagged in the design §8 item 4, since entity-type
       synthetic instances have no real `process_definitions` row to point at and
       `definition_id` carries no FK constraint). GH #2702: ensuring the projection
       only after the re-read means a race loser creates no orphan projection.
  """
  @spec get_or_create(entity_type :: String.t(), prefix :: String.t()) ::
          {:ok, instance_id :: Ecto.UUID.t()} | {:error, term()}
  def get_or_create(entity_type, prefix) when is_binary(entity_type) and is_binary(prefix) do
    case lookup_with_projection(entity_type, prefix) do
      {instance_id, true} ->
        {:ok, instance_id}

      # GH #2702 follow-up: a registry row whose projection is missing (a creator that crashed
      # between the two statements of the pre-atomic code) is healed here, so the append guard
      # never sees a registry row without its projection. Idempotent (`on_conflict: :nothing`).
      {instance_id, false} ->
        with {:ok, _projection} <- ensure_instance_projection(instance_id, prefix) do
          {:ok, instance_id}
        end

      nil ->
        create_and_reselect(entity_type, prefix)
    end
  end

  @doc """
  GH #2587 (design `gh2587-req499-pr-a-prerequisites.md` D-A2.11): READ-ONLY lookup of
  `entity_type`'s synthetic `instance_id`, one primary-key read, never an insert.
  `Letflow.Entities.Records.command_multi/3` uses it so no `entity_type_instances` row is
  created under a completion's instance locks; `{:error, :not_found}` means the caller's
  pre-transaction preparation did not run for this type.
  """
  @spec fetch_instance_id(entity_type :: String.t(), prefix :: String.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, :not_found}
  def fetch_instance_id(entity_type, prefix) when is_binary(entity_type) and is_binary(prefix) do
    case Repo.get(__MODULE__, entity_type, prefix: prefix) do
      %__MODULE__{instance_id: instance_id} -> {:ok, instance_id}
      nil -> {:error, :not_found}
    end
  end

  # One round trip: the registry row plus whether its projection exists (indexed PK joins).
  defp lookup_with_projection(entity_type, prefix) do
    from(e in __MODULE__,
      left_join: p in InstanceProjection,
      on: p.instance_id == e.instance_id,
      where: e.entity_type == ^entity_type,
      select: {e.instance_id, not is_nil(p.instance_id)}
    )
    |> Repo.one(prefix: prefix)
  end

  # GH #2702 (F8) + atomic-create fix: registry insert, re-read the WINNER, and the winner's
  # projection in ONE transaction, so no reader ever sees the registry row without its
  # projection (and a creator crash leaves neither). A race loser blocks on the registry unique
  # key until the winner commits (registry + projection together); its insert then does
  # nothing, and under READ COMMITTED (a fresh snapshot per statement) its re-read sees the
  # winner's committed row, so it ensures an on-conflict-nothing projection for the WINNER's id
  # only: no orphan projection for the loser's minted id. Nests inside a caller's transaction.
  defp create_and_reselect(entity_type, prefix) do
    instance_id = Ecto.UUID.generate()

    changeset =
      insert_changeset(%__MODULE__{}, %{entity_type: entity_type, instance_id: instance_id})

    Repo.transaction(fn ->
      with {:ok, _} <-
             Repo.insert(changeset,
               on_conflict: :nothing,
               conflict_target: :entity_type,
               prefix: prefix
             ),
           {:ok, won_instance_id} <- reread_winner(entity_type, prefix),
           {:ok, _projection} <- ensure_instance_projection(won_instance_id, prefix) do
        won_instance_id
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp reread_winner(entity_type, prefix) do
    case Repo.get(__MODULE__, entity_type, prefix: prefix) do
      %__MODULE__{instance_id: won_instance_id} -> {:ok, won_instance_id}
      nil -> {:error, {:entity_type_instance_lookup_failed, entity_type}}
    end
  end

  defp ensure_instance_projection(instance_id, prefix) do
    changeset =
      InstanceProjection.insert_changeset(%InstanceProjection{}, %{
        instance_id: instance_id,
        status: :active,
        definition_id: instance_id
      })

    Repo.insert(changeset,
      on_conflict: :nothing,
      conflict_target: :instance_id,
      prefix: prefix
    )
  end
end
