defmodule Letflow.Definitions.TestCases do
  @moduledoc """
  The DECLARED TEST CASES of a definition version, and the runner that executes
  them before the version may be activated.

  T-2604 -- the "Register a tenant" pilot, gap G16 (owner decision D-176's
  "automatic test run before activation" guardrail, listed in D-179 (c) and in
  the spike's gap list: "Today activation runs only static validation").

  ## What a declared case is

  A case is a JSON object the definition's author writes next to the graph:

      {
        "name": "the applicant is approved",
        "start_variables": {"applicant": "Acme"},
        "complete_tasks": [{"node_id": "review", "outputs": {"approved": true}}],
        "step_outputs": {"notify": {"sent": true}},
        "expect": {
          "status": "completed",
          "variables": {"approved": true},
          "visited_nodes": ["start", "review", "end"]
        }
      }

  * `name` -- required, a short label of the case. It is echoed back in the
    refusal, so it is the author's own text and never a tenant's data.
  * `start_variables` -- optional, the variables the run starts with.
  * `complete_tasks` -- optional, the human tasks the runner completes by
    itself, with the outputs each completion writes.
  * `step_outputs` -- optional, the FAKED result of a step (a service task:
    a platform call, a notification, a script, an HTTP call), keyed by node
    id. The step's real side effect never happens in a declared case -- the
    runner has no connection, no dispatcher and no mail adapter.
  * `expect` -- required. `status` is `"completed"` (the default) or
    `"waiting"` (the run stopped at a human task or a timer);
    `variables` names the variables whose value must hold at the end;
    `visited_nodes` names the nodes the run must have reached.

  ## What the runner does

  The runner walks the graph on the ENGINE'S OWN transition kernel
  (`Letflow.Engine.Transition`), in memory, with no database connection, no
  dispatcher, no queue and no clock:

  * a gateway is evaluated by the kernel's own condition evaluator;
  * a human task is completed by the kernel's own completion transition when
    the case declares one, and the run WAITS when it does not;
  * a service task is FAKED: the declared outputs are merged into the
    variables and the token is moved on by the kernel's own
    `advance_off_completed_node/4` -- the same function the live dispatcher
    uses after a successful call;
  * a timer waits (the run cannot wait for a clock in a test run);
  * a sub-process is REFUSED with `:sub_process_not_supported` -- a declared
    case runs the graph, never a child instance.

  The runner writes nothing: it is a dry run of the graph, not an instance.
  That is what makes it safe to call inside the activation transaction.

  ## The refusal

  `run/2` answers `:ok` when every declared case holds, and
  `{:error, {:definition_test_cases_failed, failures}}` when one does not.
  A failure names the case and a CLOSED reason code -- never a variable
  value, never a stack trace, never a secret the case carried (INV-4).

  ## Purity

  This module performs no I/O of any kind: no `Repo`, no `Logger`, no clock,
  no randomness. Its only inputs are the graph map and the declared cases.
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Engine
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.Token
  alias Letflow.Engine.Transition
  alias Letflow.Engine.VariableMerge

  # The bounds of one declaration. They are here, not in a config, because a
  # declared case is DATA the activation path reads and runs: an unbounded
  # list of cases would make activation unbounded work.
  @max_cases 20
  @max_name_bytes 200
  @max_node_id_bytes 200
  @max_variables 50

  @type failure :: %{name: String.t(), reason: atom(), key: String.t() | nil}

  @doc """
  Parses the declared cases of a definition version.

  `nil` and `[]` are "no declared cases" -- a version that declares none
  activates exactly as it did before this guardrail existed.

  Returns `{:ok, cases}` with the NORMALIZED cases (atom keys), or
  `{:error, {:invalid_test_cases, reason}}` with a closed reason code.
  """
  @spec parse(term()) :: {:ok, [map()]} | {:error, {:invalid_test_cases, atom()}}
  def parse(nil), do: {:ok, []}
  def parse([]), do: {:ok, []}

  def parse(cases) when is_list(cases) do
    if length(cases) > @max_cases do
      {:error, {:invalid_test_cases, :too_many_cases}}
    else
      parse_each(cases, [])
    end
  end

  def parse(_other), do: {:error, {:invalid_test_cases, :not_a_list}}

  @doc """
  Runs the declared cases against `graph_map`.

  Answers `:ok` when every case holds, `{:error, {:definition_test_cases_failed,
  failures}}` when one does not, and `{:error, {:definition_test_cases_invalid,
  reason}}` when the graph itself cannot be read.
  """
  @spec run(map(), [map()]) ::
          :ok
          | {:error, {:definition_test_cases_failed, [failure()]}}
          | {:error, {:definition_test_cases_invalid, atom()}}
  def run(graph_map, cases) when is_map(graph_map) and is_list(cases) do
    case Graph.from_map(graph_map) do
      {:ok, graph} ->
        failures = Enum.flat_map(cases, &run_case(graph, &1))

        if failures == [] do
          :ok
        else
          {:error, {:definition_test_cases_failed, failures}}
        end

      :error ->
        {:error, {:definition_test_cases_invalid, :graph_structure_invalid}}
    end
  end

  # ---------------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------------

  defp parse_each([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_each([case | rest], acc) do
    case parse_case(case) do
      {:ok, parsed} -> parse_each(rest, [parsed | acc])
      {:error, reason} -> {:error, {:invalid_test_cases, reason}}
    end
  end

  defp parse_case(case) when is_map(case) do
    with {:ok, name} <- fetch_name(case),
         {:ok, start_variables} <- fetch_start_variables(case),
         {:ok, complete_tasks} <- fetch_complete_tasks(case),
         {:ok, step_outputs} <- fetch_step_outputs(case),
         {:ok, expect} <- fetch_expect(case) do
      {:ok,
       %{
         name: name,
         start_variables: start_variables,
         complete_tasks: complete_tasks,
         step_outputs: step_outputs,
         expect: expect
       }}
    end
  end

  defp parse_case(_other), do: {:error, :not_an_object}

  defp fetch_name(case) do
    case Map.get(case, "name") do
      name when is_binary(name) and name != "" and byte_size(name) <= @max_name_bytes ->
        {:ok, name}

      nil ->
        {:error, :name_required}

      _other ->
        {:error, :invalid_name}
    end
  end

  defp fetch_start_variables(case) do
    case Map.get(case, "start_variables") do
      nil ->
        {:ok, %{}}

      variables when is_map(variables) ->
        if map_size(variables) > @max_variables do
          {:error, :too_many_start_variables}
        else
          validate_scalars(variables, :invalid_start_variable)
        end

      _other ->
        {:error, :invalid_start_variables}
    end
  end

  defp fetch_complete_tasks(case) do
    case Map.get(case, "complete_tasks") do
      nil ->
        {:ok, []}

      tasks when is_list(tasks) ->
        if length(tasks) > @max_variables do
          {:error, :too_many_complete_tasks}
        else
          parse_complete_tasks(tasks, [])
        end

      _other ->
        {:error, :invalid_complete_tasks}
    end
  end

  defp parse_complete_tasks([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_complete_tasks([task | rest], acc) when is_map(task) do
    with {:ok, node_id} <- fetch_node_id(task),
         {:ok, outputs} <- fetch_outputs(task, "outputs") do
      parse_complete_tasks(rest, [%{node_id: node_id, outputs: outputs} | acc])
    end
  end

  defp parse_complete_tasks([_other | _rest], _acc), do: {:error, :invalid_complete_task}

  defp fetch_node_id(task) do
    case Map.get(task, "node_id") do
      node_id
      when is_binary(node_id) and node_id != "" and byte_size(node_id) <= @max_node_id_bytes ->
        {:ok, node_id}

      nil ->
        {:error, :node_id_required}

      _other ->
        {:error, :invalid_node_id}
    end
  end

  defp fetch_outputs(task, key) do
    case Map.get(task, key) do
      nil ->
        {:ok, %{}}

      outputs when is_map(outputs) ->
        if map_size(outputs) > @max_variables do
          {:error, :too_many_outputs}
        else
          validate_scalars(outputs, :invalid_output)
        end

      _other ->
        {:error, :invalid_outputs}
    end
  end

  defp fetch_step_outputs(case) do
    case Map.get(case, "step_outputs") do
      nil ->
        {:ok, %{}}

      outputs when is_map(outputs) ->
        if map_size(outputs) > @max_variables do
          {:error, :too_many_step_outputs}
        else
          Enum.reduce_while(outputs, {:ok, %{}}, fn {node_id, values}, {:ok, acc} ->
            with {:ok, id} <- fetch_node_id(%{"node_id" => node_id}),
                 {:ok, parsed} <- fetch_outputs(%{"outputs" => values}, "outputs") do
              {:cont, {:ok, Map.put(acc, id, parsed)}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end

      _other ->
        {:error, :invalid_step_outputs}
    end
  end

  defp fetch_expect(case) do
    case Map.get(case, "expect") do
      expect when is_map(expect) ->
        with {:ok, status} <- fetch_status(expect),
             {:ok, variables} <- fetch_expected_variables(expect),
             {:ok, visited} <- fetch_visited_nodes(expect) do
          {:ok, %{status: status, variables: variables, visited_nodes: visited}}
        end

      nil ->
        {:error, :expect_required}

      _other ->
        {:error, :invalid_expect}
    end
  end

  defp fetch_status(expect) do
    case Map.get(expect, "status", "completed") do
      "completed" ->
        {:ok, :completed}

      "waiting" ->
        {:ok, :waiting}

      _other ->
        {:error, :invalid_expected_status}
    end
  end

  defp fetch_expected_variables(expect) do
    case Map.get(expect, "variables") do
      nil ->
        {:ok, %{}}

      variables when is_map(variables) ->
        if map_size(variables) > @max_variables do
          {:error, :too_many_expected_variables}
        else
          validate_scalars(variables, :invalid_expected_variable)
        end

      _other ->
        {:error, :invalid_expected_variables}
    end
  end

  defp fetch_visited_nodes(expect) do
    case Map.get(expect, "visited_nodes") do
      nil ->
        {:ok, []}

      nodes when is_list(nodes) ->
        if length(nodes) > @max_variables do
          {:error, :too_many_visited_nodes}
        else
          Enum.reduce_while(nodes, {:ok, []}, fn node_id, {:ok, acc} ->
            case fetch_node_id(%{"node_id" => node_id}) do
              {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end

      _other ->
        {:error, :invalid_visited_nodes}
    end
  end

  # A declared case carries SCALARS only. A nested structure has no defined
  # merge semantics here, and a case is data the activation path runs: the
  # bound keeps the work of one case predictable.
  defp validate_scalars(map, reason) do
    if Enum.all?(map, fn {_key, value} -> scalar?(value) end) do
      {:ok, map}
    else
      {:error, reason}
    end
  end

  defp scalar?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  # ---------------------------------------------------------------------------------
  # The run
  # ---------------------------------------------------------------------------------

  defp run_case(graph, test_case) do
    case start_state(graph, test_case) do
      {:ok, state} ->
        worklist = Enum.map(state.tokens, & &1.token_id)

        case walk(graph, state, test_case, hop_limit(graph), worklist, MapSet.new()) do
          {:ok, final_state, visited} -> check_expectation(test_case, final_state, visited)
          {:error, reason} -> [%{name: test_case.name, reason: reason, key: nil}]
        end

      {:error, reason} ->
        [%{name: test_case.name, reason: reason, key: nil}]
    end
  end

  # The hop budget: the same shape the engine's own activation uses (a small
  # multiple of the node count), plus room for the faked steps and the
  # declared completions. A declared case can never run forever.
  defp hop_limit(graph) do
    length(graph.nodes) * 4 + 10 + length(graph.nodes) * 2
  end

  defp start_state(graph, test_case) do
    case Enum.find(graph.nodes, &(&1.node_type == :START)) do
      nil ->
        {:error, :no_start_node}

      start_node ->
        token_id = "test-case-token"
        instance_id = "test-case-instance"

        token = %Token{token_id: token_id, node_id: start_node.id, branch_id: instance_id}

        state = %InstanceState{
          instance_id: instance_id,
          status: :active,
          tokens: [token],
          variables: test_case.start_variables
        }

        {:ok, state}
    end
  end

  # The walk: one hop per call. The worklist holds the tokens that still need
  # a dispatch; a token that parked (a human task, a timer) is handled by
  # `handle_parked/4` and either completed, faked or waited for.
  defp walk(graph, state, test_case, hops_left, worklist, visited) do
    case worklist do
      [] ->
        {:ok, state, visited}

      [token_id | rest] ->
        if hops_left <= 0 do
          {:error, :hop_limit_exceeded}
        else
          hop(graph, state, test_case, hops_left, rest, token_id, visited)
        end
    end
  end

  defp hop(graph, state, test_case, hops_left, rest, token_id, visited) do
    previous_tokens = state.tokens

    case Transition.transition(graph, state, {:advance_token, token_id}) do
      {:ok, new_state, _events} ->
        new_visited = visit(visited, previous_tokens, token_id)

        case handle_parked(graph, new_state, previous_tokens, token_id, test_case) do
          {:moved, moved_state} ->
            pending =
              rest ++
                Engine.tokens_needing_dispatch(previous_tokens, moved_state.tokens, token_id)

            walk(graph, moved_state, test_case, hops_left - 1, pending, new_visited)

          {:waiting, waiting_state} ->
            {:ok, waiting_state, new_visited}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, transition_reason(reason)}
    end
  end

  # The node the dispatched token stood on before the hop.
  defp visit(visited, previous_tokens, token_id) do
    case Enum.find(previous_tokens, &(&1.token_id == token_id)) do
      nil -> visited
      token -> MapSet.put(visited, token.node_id)
    end
  end

  # What to do with a token that did NOT move: the node it stands on decides.
  defp handle_parked(graph, state, previous_tokens, token_id, test_case) do
    token = Enum.find(state.tokens, &(&1.token_id == token_id))
    previous = Enum.find(previous_tokens, &(&1.token_id == token_id))

    cond do
      is_nil(token) ->
        # The token was consumed (an END node): nothing is parked.
        {:moved, state}

      is_nil(previous) or token.node_id != previous.node_id ->
        # The token moved on: it is not parked.
        {:moved, state}

      true ->
        park(graph, state, token, test_case)
    end
  end

  defp park(graph, state, token, test_case) do
    case node_by_id(graph, token.node_id) do
      nil ->
        {:error, :unknown_node_id}

      node ->
        case node.node_type do
          :HUMAN_TASK -> park_human_task(graph, state, token, node, test_case)
          :SERVICE_TASK -> fake_service_task(graph, state, token, node, test_case)
          :TIMER -> {:waiting, state}
          :SUB_PROCESS -> {:error, :sub_process_not_supported}
          _other -> {:error, :node_type_not_supported}
        end
    end
  end

  # A human task: completed by the case when the case declares a completion
  # for this node, waited for otherwise.
  defp park_human_task(graph, state, token, node, test_case) do
    case Enum.find(test_case.complete_tasks, &(&1.node_id == node.id)) do
      nil ->
        {:waiting, state}

      completion ->
        with {:ok, state} <- apply_outputs(state, completion.outputs),
             {:ok, new_state, _events} <-
               Transition.transition(graph, state, {:complete_task, token.token_id}) do
          {:moved, forget_pending_task(new_state, token.token_id)}
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # The kernel keeps the completed token in the pending list until the caller
  # rebuilds the state from its own rows; a dry run has no rows, so it drops
  # the entry itself.
  defp forget_pending_task(%InstanceState{} = state, token_id) do
    %InstanceState{
      state
      | pending_task_nodes: Enum.reject(state.pending_task_nodes, &(&1.token_id == token_id))
    }
  end

  # A service task: FAKED. The declared outputs are merged into the variables
  # and the token is moved on by the kernel's own `advance_off_completed_node/4`
  # -- the same function the live dispatcher calls after a successful call.
  defp fake_service_task(graph, state, token, node, test_case) do
    outputs = Map.get(test_case.step_outputs, node.id, %{})

    with {:ok, state} <- apply_outputs(state, outputs) do
      outgoing = Enum.filter(graph.edges, &(&1.source == node.id))

      case Transition.advance_off_completed_node(graph, state, token, outgoing) do
        {:ok, new_state, _events} ->
          {:moved, new_state}

        {:error, reason} ->
          {:error, transition_reason(reason)}
      end
    end
  end

  defp node_by_id(graph, node_id) do
    Enum.find(graph.nodes, &(&1.id == node_id))
  end

  # The merge is the engine's own variable merge: the reserved namespace is
  # refused exactly as it is at run time.
  defp apply_outputs(%InstanceState{} = state, outputs) when outputs == %{}, do: {:ok, state}

  defp apply_outputs(%InstanceState{} = state, outputs) do
    case VariableMerge.merge(state.variables, state.variable_labels, outputs, %{}, nil) do
      {:ok, variables, labels, _events} ->
        {:ok, %InstanceState{state | variables: variables, variable_labels: labels}}

      {:rejected, _variables, _events} ->
        {:error, :reserved_variable_key}
    end
  end

  defp transition_reason({:no_matching_edge, _node_id, _evaluated}), do: :no_matching_edge

  defp transition_reason({:node_type_not_yet_implemented, _type, _id}),
    do: :node_type_not_supported

  defp transition_reason(_other), do: :transition_failed

  # ---------------------------------------------------------------------------------
  # The expectation
  # ---------------------------------------------------------------------------------

  defp check_expectation(test_case, state, visited) do
    status_failure = check_status(test_case, state)
    variable_failures = check_variables(test_case, state)
    visited_failures = check_visited(test_case, visited)

    status_failure ++ variable_failures ++ visited_failures
  end

  defp check_status(%{expect: %{status: :completed}, name: name}, state) do
    if state.status == :completed do
      []
    else
      [%{name: name, reason: :status_mismatch, key: nil}]
    end
  end

  defp check_status(%{expect: %{status: :waiting}, name: name}, state) do
    if state.status == :active do
      []
    else
      [%{name: name, reason: :status_mismatch, key: nil}]
    end
  end

  defp check_variables(%{expect: %{variables: expected}, name: name}, state) do
    Enum.map(expected, fn {key, value} ->
      case Map.fetch(state.variables, key) do
        {:ok, ^value} ->
          nil

        {:ok, _other} ->
          %{name: name, reason: :variable_mismatch, key: key}

        :error ->
          %{name: name, reason: :variable_missing, key: key}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp check_visited(%{expect: %{visited_nodes: nodes}, name: name}, visited) do
    Enum.map(nodes, fn node_id ->
      if MapSet.member?(visited, node_id) do
        nil
      else
        %{name: name, reason: :node_not_visited, key: node_id}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
