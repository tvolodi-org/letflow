defmodule Letflow.EventStore.InstanceVisibility do
  @moduledoc """
  GH #2702: single definition of "is this `instance_projections` row a synthetic
  entity-type instance". Synthetic instances (one per entity type, minted by
  `Letflow.Entities.EntityTypeInstance.get_or_create/2`) carry the full
  `field_values` of record create/update events, so no client-facing Instances
  route may list, fetch, cancel, rebind or reconstruct one.

  A projection row is synthetic exactly when its `instance_id` is registered in
  `entity_type_instances`. That table is referenced by its SOURCE STRING (schemaless
  source), not by the `Letflow.Entities.EntityTypeInstance` schema, so the engine
  layer can use this module without crossing the `mix letflow.check_boundaries`
  Rule 6 boundary (`Engine.*` must not reference `Letflow.Entities.*`). The table-name
  string must equal `EntityTypeInstance.__schema__(:source)` (drift guard, covered by its unit test).

  The tenant prefix is applied EXPLICITLY to the inner source through the Ecto
  query-level prefix (INV-1), never through a fragment or string concatenation
  (INV-7). A bad argument is a `FunctionClauseError` (programmer error); nothing is
  rescued and no error is folded into `true`/`false`.
  """

  import Ecto.Query

  alias Letflow.Repo

  @registry_source "entity_type_instances"

  @doc """
  Adds `NOT EXISTS (SELECT 1 FROM <prefix>.entity_type_instances e WHERE
  e.instance_id = p.instance_id)` to `query`. Precondition: the query's first
  source is `Letflow.EventStore.InstanceProjection` and its first binding carries
  no other alias. The anti-join is a WHERE clause, so `LIMIT` and keyset cursors
  stay exact.
  """
  @spec exclude_synthetic(Ecto.Queryable.t(), prefix :: String.t()) :: Ecto.Query.t()
  def exclude_synthetic(query, prefix) when is_binary(prefix) do
    from(p in query,
      as: :instance_projection_visibility,
      where:
        not exists(
          from(e in @registry_source,
            prefix: ^prefix,
            where: e.instance_id == parent_as(:instance_projection_visibility).instance_id,
            select: 1
          )
        )
    )
  end

  @doc """
  True when `instance_id` is registered in `entity_type_instances` of `prefix`.
  One `EXISTS` read; a DB error propagates as the normal Repo raise.
  """
  @spec synthetic?(instance_id :: Ecto.UUID.t(), prefix :: String.t()) :: boolean()
  def synthetic?(instance_id, prefix)
      when is_binary(instance_id) and byte_size(instance_id) == 36 and is_binary(prefix) do
    query =
      from(e in @registry_source,
        prefix: ^prefix,
        where: e.instance_id == type(^instance_id, Ecto.UUID),
        select: 1
      )

    Repo.exists?(query)
  end
end
