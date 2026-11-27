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

  `refused_keys/4`: of the keys of a task completion's output, every key that ANY node of the
  instance's PINNED graph reads as a `module_writes` `var` argument is refused, and so is every
  key a `platform_call` step (T-2588) or a NOTIFICATION step (T-2592) reads: the recipient's
  variable and the variables of a notification's values are decided by the person who started
  the process, never by the person who completes a task in it. The exception is a key the
  node being completed declares as a person's input: a name in its `completer_inputs` attribute (a
  list of strings) or a property of its own `form_schema` (the form the person fills at that node;
  the maintenance `work_done` text). A pack states that explicitly per node; the scan test
  `write_target_sources_scan_test.exs` lists every such pair. The engine answers a refusal as a
  retryable 422 `output_refused` and writes nothing, like the `_sys` refusal. Every other write
  input is supplied at instance start (`Engine.create/2` from module code).

  ## The children count with the graph (T-3094, pilot gap G-SUB-2)

  A SUB_PROCESS child inherits the parent's variables, so a key the CHILD reads as a write target
  is the parent's to protect as well: without this, the completer of a human task in a tenant-made
  parent forges the key the child reads (`document_id`, `posting`, ...) and the child's own
  binding (`check_instance`) compares it with the forged map it was started with. The refused set
  of a graph therefore includes the write-read keys of its TRANSITIVE children; the exception
  above stays the node's own declared list (`completer_inputs`, `form_schema` properties).

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
  alias Letflow.Definitions.NotifyCalls
  alias Letflow.Definitions.PlatformCalls

  @doc """
  The variable names any node of `graph` reads through a `module_writes` `var` argument,
  plus the ones a `platform_call` step reads (T-2588, pilot gap G2): a catalogue call reads
  its arguments from the start variables or from an earlier platform step's output, never
  from a person, so its keys are refused in a completion body exactly like a module
  handler's write targets.

  The keys a NOTIFICATION step reads (T-2592, pilot gap G4) are refused there too: the
  recipient's variable and the variables of the values are decided by the person who
  started the process, never by the person who completes a task in it (the address of a
  message and its text are the definition's business, not the completer's).
  """
  @spec write_read_keys(Graph.t() | term()) :: MapSet.t(String.t())
  def write_read_keys(%Graph{nodes: nodes}) when is_list(nodes) do
    nodes
    |> Enum.flat_map(&node_read_keys/1)
    |> Kernel.++(PlatformCalls.read_keys(nodes))
    |> Kernel.++(NotifyCalls.read_keys(nodes))
    |> MapSet.new()
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

  `child_graphs` are the graphs of the SUB_PROCESS children the pinned graph starts,
  transitively (T-3094, pilot gap G-SUB-2): their write-read keys are refused here too, because
  a child inherits the parent's variables. The `node_id` and its `completer_inputs` are read
  from `graph` alone -- a child's node of the same id never lifts a refusal here.
  """
  @spec refused_keys(Graph.t() | term(), String.t() | nil, map(), [Graph.t() | term()]) :: [
          String.t()
        ]
  def refused_keys(graph, node_id, output_variables, child_graphs \\ [])

  def refused_keys(%Graph{nodes: nodes} = graph, node_id, output_variables, child_graphs)
      when is_list(nodes) and is_map(output_variables) and is_list(child_graphs) do
    read = read_keys(graph, child_graphs)

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

  def refused_keys(_graph, _node_id, _output_variables, _child_graphs), do: []

  # The write-read keys of the graph and of its children (T-3094, pilot gap G-SUB-2).
  defp read_keys(graph, child_graphs) do
    Enum.reduce(child_graphs, write_read_keys(graph), fn child_graph, read ->
      MapSet.union(read, write_read_keys(child_graph))
    end)
  end

  defp node_read_keys(%Node{attributes: %{"module_writes" => writes}}) when is_list(writes) do
    for %{"args" => args} <- writes,
        is_map(args),
        %{"var" => var} <- Map.values(args),
        is_binary(var),
        do: var
  end

  defp node_read_keys(_node), do: []
end
