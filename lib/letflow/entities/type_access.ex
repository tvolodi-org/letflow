defmodule Letflow.Entities.TypeAccess do
  @moduledoc """
  Per-`(user, entity_type)` authorization -- REQ-394. See
  `lib/letflow/design/req394-per-entity-type-authorization.md` §1 for the
  full design this module implements.

  ## Not a `FieldGrants` extension -- a new, sibling layer (design §0/§1)

  `Letflow.Entities.Query.FieldGrants` (REQ-231) redacts individual
  `field_values` keys within a record the caller can already see. It has no
  concept of denying an entire entity *type*. This module closes that gap,
  one level up, and is consumed by both the query path
  (`Letflow.Routers.Entities.run_query/4`) and the definitions-read path
  (`Letflow.Routers.Entities.render_get_definition/3`) alike -- not the
  query engine alone -- which is why it lives at `lib/letflow/entities/`,
  a sibling of `Letflow.Entities.Definitions`, rather than nested under
  `query/` the way `FieldGrants` is.

  ## Grant model -- default-allow, explicit restriction, per-user override (design §1.1)

  An entity type with no `entity_type_restrictions` row is visible to
  every user who holds the relevant coarse route-level permission
  (`:EntitiesQuery`/`:EntitiesDefinitionsRead`) -- a tenant that never
  inserts a single `entity_type_restrictions` row observes zero behavior
  change from this module's existence.

  A restricted entity type (a row exists in `entity_type_restrictions`
  naming it) is hidden from every user **except** one holding a matching
  `user_entity_type_grants` row for `(user_id, entity_type)`. Absence of
  that grant row is exactly that user's denial -- the same
  "restriction's absence from a given user's override rows is exactly
  that user's denial set" shape `FieldGrants` already uses, one level up.

  ## `authorized?/3` is not an existence oracle (design §1.3)

  `entity_type` here is always a caller-supplied or definition-resolved
  string, never validated against `entity_definitions` by this function --
  it answers "is this user denied *if* this type is restricted," not "does
  this type exist." Existence is resolved by the caller, exactly once, at
  the call site that already needs to know it for its own reasons
  (`Letflow.Entities.Query.Compiler.compile/2`'s `entity_type_not_found`,
  or the definitions getters' own `{:error, :not_found}`).

  ## New tables, no `Ecto.Schema` module (design §1.2)

  `entity_type_restrictions` (no FK to `entity_definitions` -- queried by
  string name, same convention `Letflow.Entities.Query.Allowlist.load/2`
  already uses) and `user_entity_type_grants` (`user_id` FK to `users`).
  Neither has a schema module -- same deliberate choice `FieldGrants` made
  for its own two tables: this module's own scope is the read-side
  loader/checker only; a future write-path requirement owns authoring
  these rows.
  """

  import Ecto.Query

  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @typedoc "The outcome of a per-`(user, entity_type)` authorization check (design §1.3)."
  @type decision :: :allowed | :denied

  @doc """
  Whether `user_id` may access `entity_type` under this module's grant
  model (design §1.1): `{:ok, :allowed}` when `entity_type` has no
  `entity_type_restrictions` row at all, or when it does and `user_id`
  holds a matching `user_entity_type_grants` row; `{:ok, :denied}`
  otherwise. Scoped to the tenant schema named by `prefix`, resolved the
  same way `Letflow.Entities.Query.FieldGrants.load_restrictions/3` does.
  """
  @spec authorized?(user_id :: String.t(), entity_type :: String.t(), prefix :: String.t()) ::
          {:ok, decision()} | {:error, :invalid_schema_name}
  def authorized?(user_id, entity_type, prefix)
      when is_binary(user_id) and is_binary(entity_type) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query =
        from(r in denial_query(user_id),
          where: r.entity_type == ^entity_type,
          select: r.id
        )

      if Repo.exists?(query, prefix: prefix) do
        {:ok, :denied}
      else
        {:ok, :allowed}
      end
    end
  end

  @doc """
  The subset of `entity_types` that `user_id` is denied (GH #2700), by the
  same rule as `authorized?/3`: restricted (a row in
  `entity_type_restrictions`) and no matching `user_entity_type_grants` row
  for this user. ONE tenant lookup and ONE query for the whole list; the names
  are de-duplicated and bound as a typed array parameter (never interpolated,
  INV-7). `[]` returns an empty set with NO I/O. A type with no restriction
  row (including a nonexistent one) is never in the result -- like
  `authorized?/3`, this is not an existence oracle.
  """
  @spec denied_types(
          user_id :: String.t(),
          entity_types :: [String.t()],
          prefix :: String.t()
        ) :: {:ok, MapSet.t(String.t())} | {:error, :invalid_schema_name}
  def denied_types(_user_id, [], prefix) when is_binary(prefix), do: {:ok, MapSet.new()}

  def denied_types(user_id, entity_types, prefix)
      when is_binary(user_id) and is_list(entity_types) and is_binary(prefix) do
    names = Enum.uniq(entity_types)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query =
        from(r in denial_query(user_id),
          where: r.entity_type in type(^names, {:array, :string}),
          select: r.entity_type
        )

      {:ok, query |> Repo.all(prefix: prefix) |> MapSet.new()}
    end
  end

  @doc """
  A boolean `Ecto.Query.dynamic/2` meaning "NOT denied" for the entity type named
  by the `name` column of the parent query's named binding `name_binding`
  (GH #2739): `NOT EXISTS (denial_query ... r.entity_type = parent_as(binding).name)`.
  Built from the same `denial_query/1` as `authorized?/3` and `denied_types/3`, so
  the three cannot diverge. Pure query construction: no I/O, no tenant lookup, the
  tenant prefix comes from the `Repo` call that executes the enclosing query.
  There is deliberately no `nil`-user or zero-argument form (fail closed): any
  other input is a `FunctionClauseError` at the call site, never "allow all".
  """
  @spec visible_to(user_id :: String.t(), name_binding :: atom()) :: Ecto.Query.dynamic_expr()
  def visible_to(user_id, name_binding) when is_binary(user_id) and is_atom(name_binding) do
    denial =
      from(r in denial_query(user_id),
        where: r.entity_type == parent_as(^name_binding).name,
        select: 1
      )

    dynamic([], not exists(denial))
  end

  # The ONE denial rule (GH #2739, SECURITY R2): a row in
  # `entity_type_restrictions` with no `user_entity_type_grants` row for this
  # user and type. Callers add their own `where`/`select`.
  defp denial_query(user_id) do
    from(r in "entity_type_restrictions",
      left_join: g in "user_entity_type_grants",
      on:
        g.entity_type == r.entity_type and
          g.user_id == type(^user_id, Ecto.UUID),
      where: is_nil(g.id)
    )
  end
end
