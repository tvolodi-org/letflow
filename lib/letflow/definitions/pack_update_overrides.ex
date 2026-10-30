defmodule Letflow.Definitions.PackUpdateOverrides do
  @moduledoc """
  Reads a tenant's active solution-pack overrides for the update plan and decides what each one
  means for an incoming pack version (REQ-617 / GH #3443, decision 0069 D4/D5/D8 S4).

    * `read_active/3` -- one tenant-prefixed query; the prefix is derived from the call's tenant id
      with `TenantProvisioning.schema_name_for_tenant/1`, never from request data (INV-1).
      `compute_pack_update_plan/5` receives a tenant id, not a prefix, and several callers pass an
      id with no tenant schema, so the read first asks `to_regclass` and treats a missing schema or
      table as "no overrides" (the sandbox would otherwise abort on the failed statement).
    * `evaluate/5` -- pure. The outcome order is: the artefact is absent from the incoming pack
      (`:orphaned`); a patch path is off the closed list (`:property_gone`); the pack did not change
      the artefact (`:kept`); a patched path resolves differently in base and incoming
      (`:override_conflict`); otherwise `:kept` with the warning `:override_kept_pack_changed`.
    * `override_map/2` -- the value a plan entry carries. It never holds the patch.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias Letflow.Definitions
  alias Letflow.Definitions.SolutionPackOverride
  alias Letflow.Definitions.SolutionPackOverrides
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type outcome :: :kept | :override_conflict | :orphaned | :property_gone

  @type read_row :: %{
          override_id: String.t(),
          override_version: pos_integer(),
          made_against: String.t(),
          artefact_type: String.t(),
          patch: map()
        }

  @type plan_override :: %{
          required(:override_id) => String.t(),
          required(:override_version) => pos_integer(),
          required(:made_against) => String.t(),
          required(:outcome) => outcome(),
          optional(:warning) => :override_kept_pack_changed
        }

  @doc """
  The active override per `{artefact_type, artefact_id}` of `pack_id`, limited to `keys`. A retired
  or orphaned latest row is not active. A tenant without a schema or without the table has none.
  """
  @spec read_active(Ecto.UUID.t(), String.t(), [{String.t(), String.t()}]) ::
          %{{String.t(), String.t()} => read_row()}
  def read_active(tenant_id, pack_id, keys) when is_binary(pack_id) and is_list(keys) do
    with {:ok, schema} <- TenantProvisioning.schema_name_for_tenant(tenant_id),
         true <- table_exists?(schema) do
      keyset = MapSet.new(keys)

      from(o in SolutionPackOverride,
        where: o.pack_id == ^pack_id,
        distinct: o.override_id,
        order_by: [asc: o.override_id, desc: o.override_version]
      )
      |> Repo.all(prefix: schema)
      |> Enum.filter(
        &(&1.status == "active" and MapSet.member?(keyset, {&1.artefact_type, &1.artefact_id}))
      )
      |> Enum.reduce(%{}, fn row, acc ->
        # REQ-596 allows one active override per artefact; the lowest override_id wins otherwise
        Map.put_new(acc, {row.artefact_type, row.artefact_id}, %{
          override_id: row.override_id,
          override_version: row.override_version,
          made_against: row.made_against,
          artefact_type: row.artefact_type,
          patch: row.patch
        })
      end)
    else
      _no_overrides -> %{}
    end
  end

  # The argument is built from the derived schema name and passed as a bound parameter (INV-7).
  defp table_exists?(schema) do
    case SQL.query(Repo, "SELECT to_regclass($1) IS NOT NULL", [
           "\"" <> schema <> "\".solution_pack_overrides"
         ]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  @doc """
  The outcome of one active override against the base and incoming content of its artefact.
  `closed_list` is a parameter so a test can shorten it.
  """
  @spec evaluate(
          read_row(),
          Definitions.classification(),
          String.t() | nil,
          String.t() | nil,
          map()
        ) :: %{outcome: outcome(), warning: nil | :override_kept_pack_changed}
  def evaluate(
        override,
        classification,
        base,
        incoming,
        closed_list \\ SolutionPackOverrides.closed_list()
      )

  def evaluate(_override, _classification, _base, nil, _closed_list),
    do: %{outcome: :orphaned, warning: nil}

  def evaluate(override, classification, base, incoming, closed_list) do
    paths = override.patch |> Map.keys() |> Enum.sort()

    cond do
      Enum.any?(paths, &(not on_closed_list?(closed_list, override.artefact_type, &1))) ->
        %{outcome: :property_gone, warning: nil}

      classification in [:unchanged, :local_only] ->
        %{outcome: :kept, warning: nil}

      touched?(paths, base, incoming) ->
        %{outcome: :override_conflict, warning: nil}

      true ->
        %{outcome: :kept, warning: :override_kept_pack_changed}
    end
  end

  defp on_closed_list?(closed_list, artefact_type, path) do
    is_binary(path) and
      closed_list
      |> Map.get(artefact_type, [])
      |> Enum.any?(fn {source, _kind} -> Regex.match?(Regex.compile!(source), path) end)
  end

  # An unparsable side, or a missing base, cannot prove the patched paths are untouched.
  defp touched?(paths, base, incoming) do
    with true <- is_binary(base),
         {:ok, base_graph} <- Jason.decode(base),
         {:ok, incoming_graph} <- Jason.decode(incoming) do
      Enum.any?(paths, &(get_path(base_graph, &1) != get_path(incoming_graph, &1)))
    else
      _ -> true
    end
  end

  # Mirrors `SolutionPackOverrideMerge`'s walk: `nodes.<id>.<key>...`; anything else is absent.
  defp get_path(%{"nodes" => nodes}, "nodes." <> rest) when is_list(nodes) do
    case String.split(rest, ".") do
      [node_id | [_ | _] = tail] ->
        case Enum.find(nodes, &(is_map(&1) and Map.get(&1, "id") == node_id)) do
          nil -> :absent
          node -> walk(node, tail)
        end

      _ ->
        :absent
    end
  end

  defp get_path(_graph, _path), do: :absent

  defp walk(value, []), do: {:ok, value}

  defp walk(%{} = map, [key | rest]) do
    case Map.fetch(map, key) do
      {:ok, child} -> walk(child, rest)
      :error -> :absent
    end
  end

  defp walk(_scalar, _path), do: :absent

  @doc "The value a plan entry carries: ids, version, outcome and an optional warning. Never the patch."
  @spec override_map(read_row(), %{outcome: outcome(), warning: nil | atom()}) :: plan_override()
  def override_map(row, %{outcome: outcome, warning: warning}) do
    base = %{
      override_id: row.override_id,
      override_version: row.override_version,
      made_against: row.made_against,
      outcome: outcome
    }

    if warning, do: Map.put(base, :warning, warning), else: base
  end
end
