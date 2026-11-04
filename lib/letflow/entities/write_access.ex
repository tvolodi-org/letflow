defmodule Letflow.Entities.WriteAccess do
  @moduledoc """
  Per-`(user, entity_type)` WRITE restriction -- REQ-577 / GH #3261, decision 0070 D2 (slice A,
  Q2 option 1: a second table pair, Q3: managed with the existing `EntitiesRestrictionsManage`).

  A sibling of `Letflow.Entities.TypeAccess` in the same schemaless-table style. A type with a row
  in `entity_type_write_restrictions` is closed to WRITING for every user without a
  `user_entity_type_write_grants` row for it; a type with no such row behaves exactly as before
  (default-allow, so a tenant that never inserts a row sees no change).

  ## What this is not

  - Not a read control. A write grant never implies read: `TypeAccess` still decides visibility,
    and `Letflow.Entities.RecordAccess` answers a TypeAccess-denied type as absent before this
    module's result matters.
  - Not an existence oracle: like `TypeAccess.authorized?/3`, the type name is never checked
    against `entity_definitions`.
  - Not applied to module-managed types: the import refuses a write restriction for them, and
    the managed lock in `RecordAccess` is absolute.

  ## `lost_writers/3` is type level

  The import report lists users who passed `TypeAccess` and have no write grant on a newly
  write-restricted type. Whether a user's ROLE holds `EntitiesRecordsWrite` is not consulted, so
  the report can name users who could not write for a role reason already.
  """

  import Ecto.Query

  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @typedoc "The outcome of a per-`(user, entity_type)` write check."
  @type decision :: :allowed | :denied

  @lost_cap 1000

  @doc """
  `{:ok, :denied}` when `entity_type` has a write-restriction row and `user_id` holds no matching
  write grant, else `{:ok, :allowed}`. Scoped to the tenant schema `prefix`.
  """
  @spec authorized?(user_id :: String.t(), entity_type :: String.t(), prefix :: String.t()) ::
          {:ok, decision()} | {:error, :invalid_schema_name}
  def authorized?(user_id, entity_type, prefix)
      when is_binary(user_id) and is_binary(entity_type) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query =
        from(r in "entity_type_write_restrictions",
          left_join: g in "user_entity_type_write_grants",
          on:
            g.entity_type == r.entity_type and
              g.user_id == type(^user_id, Ecto.UUID),
          where: is_nil(g.id) and r.entity_type == ^entity_type,
          select: r.id
        )

      if Repo.exists?(query, prefix: prefix), do: {:ok, :denied}, else: {:ok, :allowed}
    end
  end

  @doc """
  The `(user_id, entity_type)` pairs that lose write ability through the write restrictions on
  `entity_types`: active users that pass `TypeAccess` for the type (no type restriction, or a type
  grant) and hold no write grant. Ordered by `(entity_type, user_id)`; at most #{@lost_cap} pairs
  are returned and `truncated?` is true when more exist. `[]` does no I/O. Names are bound as a
  typed array parameter (INV-7).
  """
  @spec lost_writers(entity_types :: [String.t()], prefix :: String.t()) ::
          {:ok, [{String.t(), String.t()}], truncated? :: boolean()}
  def lost_writers([], _prefix), do: {:ok, [], false}

  def lost_writers(entity_types, prefix) when is_list(entity_types) and is_binary(prefix) do
    names = Enum.uniq(entity_types)

    type_denied =
      from(t in "entity_type_restrictions",
        left_join: tg in "user_entity_type_grants",
        on: tg.entity_type == t.entity_type and tg.user_id == parent_as(:user).id,
        where: t.entity_type == parent_as(:restriction).entity_type and is_nil(tg.id),
        select: 1
      )

    write_granted =
      from(g in "user_entity_type_write_grants",
        where:
          g.entity_type == parent_as(:restriction).entity_type and
            g.user_id == parent_as(:user).id,
        select: 1
      )

    query =
      from(r in "entity_type_write_restrictions",
        as: :restriction,
        cross_join: u in User,
        as: :user,
        where: r.entity_type in type(^names, {:array, :string}),
        where: u.status == :active,
        where: not exists(type_denied),
        where: not exists(write_granted),
        order_by: [asc: r.entity_type, asc: u.id],
        limit: ^(@lost_cap + 1),
        select: {u.id, r.entity_type}
      )

    rows = Repo.all(query, prefix: prefix)
    {:ok, Enum.take(rows, @lost_cap), length(rows) > @lost_cap}
  end
end
