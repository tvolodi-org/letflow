defmodule Letflow.Definitions.PromotionPlan do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Computes a promotion plan — a diff of one process's ACTIVE definition
  between a source tenant and a target tenant, across 5 dimensions. Ported
  from R-Co's `src/definition/promotion_plan.zig` (PRM-01), per
  `lib/letflow/design/promotion_plan.md` §3 (the gate-approved design this
  module implements).

  Read-only — performs zero `Repo` insert/update/delete/update_all calls
  (INV-PRM-1). The two `Repo.get_by/3` reads (source/target ACTIVE
  `process_definitions` rows) are plain reads, no lock.

  ## `permission_checker` has no built-in default (design §9.1; ISS-0993 section 9)

  `opts[:permission_checker]` must be supplied by the caller. If a caller
  omits it, `compute_promotion_plan/5` raises a `KeyError` rather than
  silently allowing every actor through. The allow-all
  default checker that used to live here was DELETED by ISS-0993
  (A2); every HTTP call site now passes
  `Letflow.Definitions.PromotionAccess.checker_for(conn.assigns.auth_context)`,
  which accepts a source tenant only when it is the caller's own tenant or the
  caller holds platform scope. A test that needs an allow-all checker supplies
  its own anonymous function.

  ## Entry ordering is a determinism precondition for `PromotionDigest` (design §2.5)

  `entries` is always returned sorted by `{type_rank(type), id}` — this is
  required for `Letflow.Definitions.PromotionDigest.compute_plan_digest/1`'s
  determinism guarantee to hold in practice, since that module's
  canonicalization sorts JSON object keys but does not reorder JSON arrays.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type change_kind :: :added | :modified | :removed

  @type entry_type ::
          :graph_node | :graph_edge | :variable_schema | :service_binding | :module_ref

  @type plan_entry :: %{
          type: entry_type(),
          id: String.t(),
          change_kind: change_kind(),
          before: map() | String.t() | nil,
          after: map() | String.t() | nil
        }

  @type t :: %{
          source_tenant_id: Ecto.UUID.t(),
          target_tenant_id: Ecto.UUID.t(),
          process_key: String.t(),
          source_definition_id: Ecto.UUID.t() | nil,
          target_definition_id: Ecto.UUID.t() | nil,
          base_version: String.t() | nil,
          entries: [plan_entry()]
        }

  @type promotion_opts :: [
          permission_checker: (Ecto.UUID.t(), Ecto.UUID.t() -> boolean()),
          tenant_classifier: (Ecto.UUID.t() -> :production | :test),
          variable_schema_fetcher: (Ecto.UUID.t(), String.t() -> map() | String.t() | nil)
        ]

  @type compute_error ::
          :forbidden
          | :invalid_promotion_source
          | :empty_plan
          | :invalid_tenant_id

  @type_rank %{
    graph_node: 0,
    graph_edge: 1,
    variable_schema: 2,
    service_binding: 3,
    module_ref: 4
  }

  @doc """
  Diffs `process_key`'s ACTIVE definition between `source_tenant_id` and
  `target_tenant_id`, across 5 dimensions (graph nodes, graph edges,
  variable_schema, service-catalog bindings, module_ref values), producing
  one `plan_entry()` per changed unit.

  Algorithm, in order (each step short-circuits on failure):

    1. `opts[:permission_checker].(actor_id, source_tenant_id)` — `false` ->
       `{:error, :forbidden}`. No DB read has happened yet.
    2. `opts[:tenant_classifier].(source_tenant_id)` (defaults to
       `default_tenant_classifier/1`) — `:production` ->
       `{:error, :invalid_promotion_source}`. Still no `process_definitions`
       read.
    3. Resolve both tenants' schema prefixes via
       `Letflow.TenantProvisioning.schema_name_for_tenant/1` —
       `{:error, :invalid_tenant_id}` on either failure.
    4. Read the source's ACTIVE `process_definitions` row (`nil` allowed).
    5. Read the target's ACTIVE `process_definitions` row (`nil` allowed —
       this is the "target has no existing version" case).
    6. Build the 5 dimensions' raw `{before, after}` pairs.
    7. Diff each dimension by id into `plan_entry()`s, dropping units where
       `before == after`.
    8. Sort all produced entries by `{type_rank(type), id}`.
    9. `entries == []` -> `{:error, :empty_plan}`. Otherwise -> `{:ok, t()}`.

  When the target read (step 5) returns `nil`, every dimension's `before` is
  `nil` — there is no special-case branch for this; every unit present on
  the source side then computes `change_kind: :added` by the ordinary rule,
  with no separate code path needed to make that true (design §3.3).
  """
  @spec compute_promotion_plan(
          actor_id :: Ecto.UUID.t(),
          source_tenant_id :: Ecto.UUID.t(),
          target_tenant_id :: Ecto.UUID.t(),
          process_key :: String.t(),
          opts :: promotion_opts()
        ) :: {:ok, t()} | {:error, compute_error()}
  def compute_promotion_plan(actor_id, source_tenant_id, target_tenant_id, process_key, opts) do
    permission_checker = Keyword.fetch!(opts, :permission_checker)
    tenant_classifier = Keyword.get(opts, :tenant_classifier, &default_tenant_classifier/1)

    variable_schema_fetcher =
      Keyword.get(opts, :variable_schema_fetcher, &default_variable_schema_fetcher/2)

    cond do
      not permission_checker.(actor_id, source_tenant_id) ->
        {:error, :forbidden}

      tenant_classifier.(source_tenant_id) == :production ->
        {:error, :invalid_promotion_source}

      true ->
        with {:ok, source_prefix} <- TenantProvisioning.schema_name_for_tenant(source_tenant_id),
             {:ok, target_prefix} <- TenantProvisioning.schema_name_for_tenant(target_tenant_id) do
          source_row = fetch_active(source_prefix, process_key)
          target_row = fetch_active(target_prefix, process_key)

          entries =
            build_entries(
              source_row,
              target_row,
              source_tenant_id,
              target_tenant_id,
              process_key,
              variable_schema_fetcher
            )

          if entries == [] do
            {:error, :empty_plan}
          else
            {:ok,
             %{
               source_tenant_id: source_tenant_id,
               target_tenant_id: target_tenant_id,
               process_key: process_key,
               source_definition_id: row_id(source_row),
               target_definition_id: row_id(target_row),
               base_version: row_version(target_row),
               entries: entries
             }}
          end
        end
    end
  end

  @doc """
  Default `tenant_classifier` — reads `tenants.tenant_type` (REQ-469): `:production`
  for a tenant set to `production`, `:test` for `test`, an unknown id, a malformed
  id or `nil`. A primary-key lookup on the public `tenants` table that returns only
  the type; a database error is not rescued here.
  """
  @spec default_tenant_classifier(Ecto.UUID.t()) :: :production | :test
  def default_tenant_classifier(tenant_id) do
    with {:ok, id} <- Ecto.UUID.cast(tenant_id),
         "production" <- Repo.one(from(t in Tenant, where: t.id == ^id, select: t.tenant_type)) do
      :production
    else
      _test_unknown_or_malformed -> :test
    end
  end

  # Default `variable_schema_fetcher` — REQ-109 added a tenant-scoped
  # `variable_schemas` table (`Letflow.Engine.VariableSchema`), but this
  # fetcher is deliberately NOT wired to it: REQ-109's scope is the table, the
  # lookup, and the `merge_output_variables` call site only, and wiring this
  # consumer is a later requirement's job (req109-variable-schemas.md §9.2,
  # §9.3). There is still no `variable_schemas` `process_definitions` column
  # (design §9.3). Always returns nil, so the :variable_schema dimension
  # contributes zero entries under the default.
  @spec default_variable_schema_fetcher(Ecto.UUID.t(), String.t()) :: nil
  defp default_variable_schema_fetcher(_tenant_id, _process_key), do: nil

  @spec fetch_active(String.t(), String.t()) :: ProcessDefinition.t() | nil
  defp fetch_active(prefix, process_key) do
    Repo.get_by(ProcessDefinition, [name: process_key, status: :active], prefix: prefix)
  end

  defp row_id(nil), do: nil
  defp row_id(%ProcessDefinition{id: id}), do: id

  defp row_version(nil), do: nil
  defp row_version(%ProcessDefinition{version: version}), do: version

  defp build_entries(
         source_row,
         target_row,
         source_tenant_id,
         target_tenant_id,
         process_key,
         variable_schema_fetcher
       ) do
    source_graph = row_graph(source_row)
    target_graph = row_graph(target_row)

    node_entries = diff_by_id(:graph_node, target_graph["nodes"], source_graph["nodes"])
    edge_entries = diff_by_id(:graph_edge, target_graph["edges"], source_graph["edges"])

    variable_schema_entries =
      diff_scalar(
        :variable_schema,
        "variable_schema",
        variable_schema_fetcher.(target_tenant_id, process_key),
        variable_schema_fetcher.(source_tenant_id, process_key)
      )

    service_binding_entries =
      diff_node_attribute(
        :service_binding,
        "SERVICE_TASK",
        "service_id",
        target_graph["nodes"],
        source_graph["nodes"]
      )

    module_ref_entries =
      diff_node_attribute(
        :module_ref,
        "SUB_PROCESS",
        "module_ref",
        target_graph["nodes"],
        source_graph["nodes"]
      )

    (node_entries ++
       edge_entries ++
       variable_schema_entries ++ service_binding_entries ++ module_ref_entries)
    |> Enum.sort_by(&{@type_rank[&1.type], &1.id})
  end

  defp row_graph(nil), do: %{"nodes" => [], "edges" => []}
  defp row_graph(%ProcessDefinition{graph: graph}), do: graph

  # Diffs two id-keyed lists of raw jsonb maps (graph nodes/edges).
  @spec diff_by_id(entry_type(), [map()], [map()]) :: [plan_entry()]
  defp diff_by_id(type, target_list, source_list) do
    target_by_id = Map.new(target_list || [], &{&1["id"], &1})
    source_by_id = Map.new(source_list || [], &{&1["id"], &1})

    ids = MapSet.union(MapSet.new(Map.keys(target_by_id)), MapSet.new(Map.keys(source_by_id)))

    ids
    |> Enum.flat_map(fn id ->
      before = Map.get(target_by_id, id)
      after_ = Map.get(source_by_id, id)
      entry(type, id, before, after_)
    end)
  end

  # Diffs a raw string-valued attribute on nodes of a given node_type,
  # keyed by owning node id (service_binding / module_ref dimensions).
  @spec diff_node_attribute(entry_type(), String.t(), String.t(), [map()], [map()]) :: [
          plan_entry()
        ]
  defp diff_node_attribute(type, node_type, attribute_key, target_nodes, source_nodes) do
    target_values = attribute_values_by_node_id(target_nodes, node_type, attribute_key)
    source_values = attribute_values_by_node_id(source_nodes, node_type, attribute_key)

    ids =
      MapSet.union(MapSet.new(Map.keys(target_values)), MapSet.new(Map.keys(source_values)))

    ids
    |> Enum.flat_map(fn id ->
      before = Map.get(target_values, id)
      after_ = Map.get(source_values, id)
      entry(type, id, before, after_)
    end)
  end

  defp attribute_values_by_node_id(nodes, node_type, attribute_key) do
    (nodes || [])
    |> Enum.filter(&(&1["node_type"] == node_type))
    |> Map.new(fn node -> {node["id"], get_in(node, ["attributes", attribute_key])} end)
  end

  defp diff_scalar(type, id, before, after_), do: entry(type, id, before, after_)

  # Standard before/after -> change_kind rule shared by every dimension
  # (design §3.4). Returns [] (no entry) when before == after.
  @spec entry(entry_type(), String.t(), term(), term()) :: [plan_entry()]
  defp entry(type, id, before, after_) do
    cond do
      before == after_ ->
        []

      is_nil(before) ->
        [%{type: type, id: id, change_kind: :added, before: before, after: after_}]

      is_nil(after_) ->
        [%{type: type, id: id, change_kind: :removed, before: before, after: after_}]

      true ->
        [%{type: type, id: id, change_kind: :modified, before: before, after: after_}]
    end
  end
end
