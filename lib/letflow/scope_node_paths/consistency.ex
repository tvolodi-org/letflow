defmodule Letflow.ScopeNodePaths.Consistency do
  @moduledoc """
  Read-only consistency check of a tenant's `scope_node_paths` table (REQ-496,
  decision 0050 D8; design
  `lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §6.4). The one
  shared function behind both the admin endpoint
  (`GET /api/v1/tenant/scope-node-paths/consistency`) and the consistency test
  `mix letflow.check` runs.

  `check/1` loads at most `row_cap/0` rows of the tenant's table (ordered by
  `node_id`), so the endpoint's work is bounded (INV-8). When the table holds
  more, the report is built from the first `row_cap/0` rows, `truncated: true`,
  and `status` is `:inconsistent`: a partial table cannot prove consistency (the
  parents of loaded rows may be missing), so the gates fail safe. The id lists
  in the report are also capped (1000 each, `truncated: true` when any cap is
  hit; `counts` stay exact). No write, no lock.

  Rules (segments = `path` split on `/`, empty ends dropped; parent = the
  second-last segment):

    1. `malformed` -- path not of the form `/seg/(seg/)*`, or its last segment
       is not `node_id`, or `depth` is not the segment count. Excluded from 2-4.
    2. `cycles` -- a path with a repeated segment, or a node on a loop when
       following parent links through existing non-malformed rows.
    3. `orphans` -- not in `cycles`, non-root, and the parent segment has no row.
    4. `stale_paths` -- not in 1-3, the parent row exists, but
       `parent.path <> node_id <> "/"` is not `path`.
    5. `depth_exceeded` -- `depth > 12` or more than 12 segments (any row).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.ScopeNodePaths.Node
  alias Letflow.TenantProvisioning

  @list_cap 1000
  @row_cap 50_000
  @path_format ~r{^/([^/]+/)+$}

  @type report :: %{
          status: :ok | :inconsistent,
          checked_nodes: non_neg_integer(),
          max_depth: 12,
          counts: %{
            orphans: non_neg_integer(),
            cycles: non_neg_integer(),
            depth_exceeded: non_neg_integer(),
            malformed: non_neg_integer(),
            stale_paths: non_neg_integer()
          },
          orphans: [ScopeNodePaths.node_id()],
          cycles: [ScopeNodePaths.node_id()],
          depth_exceeded: [ScopeNodePaths.node_id()],
          malformed: [ScopeNodePaths.node_id()],
          stale_paths: [ScopeNodePaths.node_id()],
          truncated: boolean()
        }

  @doc "The most rows `check/1` loads; a larger table yields `truncated: true`."
  @spec row_cap() :: pos_integer()
  def row_cap, do: @row_cap

  @doc "Loads up to `row_cap/0` `scope_node_paths` rows of the tenant schema `prefix` and analyses them."
  @spec check(prefix :: String.t()) :: {:ok, report()} | {:error, :invalid_schema_name}
  def check(prefix) when is_binary(prefix), do: check(prefix, @row_cap)

  @doc false
  @spec check(String.t(), pos_integer()) :: {:ok, report()} | {:error, :invalid_schema_name}
  def check(prefix, row_cap) when is_binary(prefix) and is_integer(row_cap) and row_cap > 0 do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query = from(n in Node, order_by: n.node_id, limit: ^(row_cap + 1))

      case Repo.all(query, prefix: prefix) do
        rows when length(rows) > row_cap ->
          report = analyse(Enum.take(rows, row_cap))
          {:ok, %{report | status: :inconsistent, truncated: true}}

        rows ->
          {:ok, analyse(rows)}
      end
    end
  end

  @doc "The pure analysis behind `check/1` (rules in the moduledoc)."
  @spec analyse([Node.t()]) :: report()
  def analyse(nodes) when is_list(nodes) do
    max_depth = ScopeNodePaths.max_depth()
    segments = Map.new(nodes, &{&1.node_id, path_segments(&1.path)})
    rows = Map.new(nodes, &{&1.node_id, &1})

    malformed =
      nodes
      |> Enum.filter(&malformed?(&1, segments[&1.node_id]))
      |> MapSet.new(& &1.node_id)

    well_formed = Enum.reject(nodes, &MapSet.member?(malformed, &1.node_id))

    cycles =
      MapSet.union(repeated_segment_ids(well_formed, segments), loop_ids(well_formed, segments))

    # Rules 3-4 classify each remaining non-root node by its parent row.
    classified =
      well_formed
      |> Enum.reject(&MapSet.member?(cycles, &1.node_id))
      |> Enum.map(&{&1, parent_id(segments[&1.node_id])})
      |> Enum.reject(fn {_node, parent} -> parent == nil end)
      |> Enum.map(fn {node, parent} -> {node, Map.get(rows, parent)} end)

    orphans = for {node, nil} <- classified, do: node.node_id

    stale_paths =
      for {node, %Node{} = parent_row} <- classified,
          parent_row.path <> node.node_id <> "/" != node.path,
          do: node.node_id

    depth_exceeded =
      nodes
      |> Enum.filter(&(&1.depth > max_depth or length(segments[&1.node_id]) > max_depth))
      |> Enum.map(& &1.node_id)

    lists = %{
      orphans: orphans,
      cycles: MapSet.to_list(cycles),
      depth_exceeded: depth_exceeded,
      malformed: MapSet.to_list(malformed),
      stale_paths: stale_paths
    }

    counts = Map.new(lists, fn {key, ids} -> {key, length(ids)} end)

    capped =
      Map.new(lists, fn {key, ids} -> {key, ids |> Enum.sort() |> Enum.take(@list_cap)} end)

    Map.merge(capped, %{
      status: if(Enum.all?(Map.values(counts), &(&1 == 0)), do: :ok, else: :inconsistent),
      checked_nodes: length(nodes),
      max_depth: max_depth,
      counts: counts,
      truncated: Enum.any?(Map.values(counts), &(&1 > @list_cap))
    })
  end

  defp malformed?(node, segments) do
    not is_binary(node.path) or not Regex.match?(@path_format, node.path) or
      List.last(segments) != node.node_id or node.depth != length(segments)
  end

  defp repeated_segment_ids(nodes, segments) do
    nodes
    |> Enum.filter(fn node ->
      segs = segments[node.node_id]
      length(Enum.uniq(segs)) != length(segs)
    end)
    |> MapSet.new(& &1.node_id)
  end

  # Nodes lying on a loop of parent links among `nodes` (each node has at most
  # one parent, so this is a functional graph). Linear: every node is walked
  # once; a walk that reaches a node already on its own stack has found a loop.
  defp loop_ids(nodes, segments) do
    parent_of =
      Map.new(nodes, fn node -> {node.node_id, parent_id(segments[node.node_id])} end)

    {_done, on_loop} =
      Enum.reduce(Map.keys(parent_of), {MapSet.new(), MapSet.new()}, fn start, {done, on_loop} ->
        walk(start, parent_of, done, on_loop, [], %{})
      end)

    on_loop
  end

  defp walk(node_id, parent_of, done, on_loop, stack, stack_index) do
    cond do
      node_id == nil or not Map.has_key?(parent_of, node_id) or MapSet.member?(done, node_id) ->
        {MapSet.union(done, MapSet.new(stack)), on_loop}

      Map.has_key?(stack_index, node_id) ->
        # `stack` is newest-first; the loop is every entry pushed since `node_id`.
        loop = Enum.take(stack, map_size(stack_index) - Map.fetch!(stack_index, node_id))
        {MapSet.union(done, MapSet.new(stack)), MapSet.union(on_loop, MapSet.new(loop))}

      true ->
        walk(
          Map.fetch!(parent_of, node_id),
          parent_of,
          done,
          on_loop,
          [node_id | stack],
          Map.put(stack_index, node_id, map_size(stack_index))
        )
    end
  end

  defp parent_id(segments) do
    case Enum.reverse(segments) do
      [_self, parent | _rest] -> parent
      _root_or_empty -> nil
    end
  end

  defp path_segments(path) when is_binary(path), do: String.split(path, "/", trim: true)
  defp path_segments(_not_a_binary), do: []
end
