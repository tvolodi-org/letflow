defmodule Letflow.Engine.WriteTargets do
  @moduledoc """
  T-2430 (audit T-2429): a `module_writes` target must come from engine-owned data, never from a
  variable the completer of a human task can overwrite.

  `POST /tasks/:id/complete` hands the whole request body to the engine as the task's output, and
  a `module_writes` argument `%{"var" => name}` is read from the MERGED variables, so a completer
  who sends `name` in the body decides what the handler writes (another document, another posting,
  another entry to reverse; the four-eyes pair of one instance is then bypassed with the values of
  another). This module is the one place that names those keys.

  ## Rule

  `refused_keys/3`: of the keys of a task completion's output, every key that ANY node of the
  instance's PINNED graph reads as a `module_writes` `var` argument is refused, except a key the
  node being completed declares as a person's input: a name in its `completer_inputs` attribute (a
  list of strings) or a property of its own `form_schema` (the form the person fills at that node;
  the maintenance `work_done` text). A pack states that explicitly per node; the scan test
  `write_target_sources_scan_test.exs` lists every such pair. The engine answers a refusal as a
  retryable 422 `output_refused` and writes nothing, like the `_sys` refusal. Every other write
  input is supplied at instance start (`Engine.create/2` from module code).

  ## Start rule (T-2444, T-2443 review of T-2430)

  The same hole is open at instance START: `POST /instances` takes `initial_variables` from the
  caller, and the first node of a module definition reads the write targets from them. A definition
  any node of which carries `module_writes` is therefore started only by module code
  (`Engine.create/2` with `module_start: true`, variables built server-side from issued documents).
  `module_writes?/1` is the one test of that. A caller that is not module code (the public route, a
  scheduled job, a SUB_PROCESS node of a tenant parent) is answered as for an unknown definition
  (INV-5): this refuses every write-target key at once, so no per-key list is needed on the start side.
  No shipped pack declares a start-node input over a write key, so no exception exists.

  Pure and total (INV-8): a malformed attribute is read as "none declared" on the declaring side
  (so more is refused, never less) and as "reads nothing" on the reading side.
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Node

  @doc """
  The variable names any node of `graph` reads through a `module_writes` `var` argument.
  """
  @spec write_read_keys(Graph.t() | term()) :: MapSet.t(String.t())
  def write_read_keys(%Graph{nodes: nodes}) when is_list(nodes) do
    nodes |> Enum.flat_map(&node_read_keys/1) |> MapSet.new()
  end

  def write_read_keys(_other), do: MapSet.new()

  @doc """
  True when any node of `graph` carries a non-empty `module_writes` list: a definition only its
  module may start (T-2444). A graph that is not a `%Graph{}` is `false` (the caller's own graph
  check refuses it).
  """
  @spec module_writes?(Graph.t() | term()) :: boolean()
  def module_writes?(%Graph{nodes: nodes}) when is_list(nodes) do
    Enum.any?(nodes, fn
      %Node{attributes: %{"module_writes" => [_ | _]}} -> true
      _other -> false
    end)
  end

  def module_writes?(_other), do: false

  @doc """
  The names the node declares as a person's input: its `completer_inputs` list and the properties
  of its `form_schema` (`[]` when absent or malformed).
  """
  @spec completer_inputs(Node.t() | term()) :: [String.t()]
  def completer_inputs(%Node{attributes: attributes}) when is_map(attributes) do
    listed =
      case Map.get(attributes, "completer_inputs") do
        list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
        _other -> []
      end

    form =
      case Map.get(attributes, "form_schema") do
        %{"properties" => props} when is_map(props) -> Map.keys(props)
        _other -> []
      end

    Enum.uniq(listed ++ form)
  end

  def completer_inputs(_node), do: []

  @doc """
  The keys of `output_variables` that `node_id`'s completion may not set, sorted.
  """
  @spec refused_keys(Graph.t() | term(), String.t() | nil, map()) :: [String.t()]
  def refused_keys(%Graph{nodes: nodes} = graph, node_id, output_variables)
      when is_list(nodes) and is_map(output_variables) do
    read = write_read_keys(graph)

    if MapSet.size(read) == 0 do
      []
    else
      allowed = nodes |> Enum.find(&(&1.id == node_id)) |> completer_inputs()

      output_variables
      |> Map.keys()
      |> Enum.filter(&is_binary/1)
      |> Enum.filter(&(MapSet.member?(read, &1) and &1 not in allowed))
      |> Enum.sort()
    end
  end

  def refused_keys(_graph, _node_id, _output_variables), do: []

  defp node_read_keys(%Node{attributes: %{"module_writes" => writes}}) when is_list(writes) do
    for %{"args" => args} <- writes,
        is_map(args),
        %{"var" => var} <- Map.values(args),
        is_binary(var),
        do: var
  end

  defp node_read_keys(_node), do: []
end
