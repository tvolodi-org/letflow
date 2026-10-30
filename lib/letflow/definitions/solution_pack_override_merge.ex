defmodule Letflow.Definitions.SolutionPackOverrideMerge do
  @moduledoc """
  Pure merge of an installed process-definition graph with a tenant override patch (REQ-610 /
  GH #3419, decision 0069 D8 S3). No I/O, no Repo.

  `merge/3` returns the effective graph, or `{:error, :property_not_overridable}` when any patch
  path is off the closed list (the whole patch is refused), or `{:error, :override_changes_structure}`
  when applying the patch would change what the graph is made of: a node id or type, an edge, a
  graph-level key, or a script, condition or entity-write attribute. The closed list cannot reach
  those today (`SolutionPackOverrides.closed_list/0` is checked again here); the structural guard
  is defence in depth, and `closed_list` is a parameter so a test can widen it.

  `settings.<key>` patch keys are not graph properties: they are skipped, so a stored threshold
  override changes nothing in S3. An empty patch (a retired override) returns the installed graph.
  """

  alias Letflow.Definitions.SolutionPackOverrides

  @structural_attributes ~w(script_key script_version validation_script_key validation_script_version
                            condition expression variables entity_writes module_writes)

  @type error :: :property_not_overridable | :override_changes_structure

  @spec merge(map(), map(), map()) :: {:ok, map()} | {:error, error()}
  def merge(graph, patch, closed_list \\ SolutionPackOverrides.closed_list())
      when is_map(graph) and is_map(patch) and is_map(closed_list) do
    regexes =
      closed_list
      |> Map.get("process_definition", [])
      |> Enum.map(fn {source, _kind} -> Regex.compile!(source) end)

    paths = patch |> Map.keys() |> Enum.sort()

    cond do
      not Enum.all?(paths, fn path ->
        is_binary(path) and Enum.any?(regexes, &Regex.match?(&1, path))
      end) ->
        {:error, :property_not_overridable}

      true ->
        paths
        |> Enum.reject(&String.starts_with?(&1, "settings."))
        |> apply_paths(graph, patch)
        |> guard(graph)
    end
  end

  defp apply_paths(paths, graph, patch) do
    Enum.reduce_while(paths, {:ok, graph}, fn path, {:ok, acc} ->
      case put_value(acc, String.split(path, "."), Map.fetch!(patch, path)) do
        {:ok, next} -> {:cont, {:ok, next}}
        :error -> {:halt, {:error, :override_changes_structure}}
      end
    end)
  end

  defp put_value(%{"nodes" => nodes} = graph, ["nodes", node_id | rest], value)
       when is_list(nodes) and rest != [] do
    case Enum.find_index(nodes, &(is_map(&1) and Map.get(&1, "id") == node_id)) do
      nil ->
        :error

      index ->
        with {:ok, node} <- put_path(Enum.at(nodes, index), rest, value) do
          {:ok, Map.put(graph, "nodes", List.replace_at(nodes, index, node))}
        end
    end
  end

  defp put_value(graph, path, value), do: put_path(graph, path, value)

  defp put_path(map, [key], value) when is_map(map), do: {:ok, Map.put(map, key, value)}

  defp put_path(map, [key | rest], value) when is_map(map) do
    case Map.get(map, key, %{}) do
      child when is_map(child) ->
        with {:ok, updated} <- put_path(child, rest, value), do: {:ok, Map.put(map, key, updated)}

      _list_or_scalar ->
        :error
    end
  end

  defp put_path(_not_a_map, _path, _value), do: :error

  defp guard({:error, _} = error, _installed), do: error

  defp guard({:ok, effective}, installed) do
    if structural_view(installed) == structural_view(effective),
      do: {:ok, effective},
      else: {:error, :override_changes_structure}
  end

  defp structural_view(graph) do
    nodes = List.wrap(Map.get(graph, "nodes"))

    %{
      nodes:
        nodes
        |> Enum.map(fn node ->
          {Map.get(node, "id"), Map.get(node, "node_type"),
           node |> Map.get("attributes", %{}) |> take_structural()}
        end)
        |> Enum.sort(),
      edges: Map.get(graph, "edges"),
      top_level: Map.drop(graph, ["nodes", "edges"])
    }
  end

  defp take_structural(attributes) when is_map(attributes),
    do: Map.take(attributes, @structural_attributes)

  defp take_structural(_other), do: :not_a_map
end
