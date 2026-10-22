defmodule Letflow.Engine.SubProcess do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  SPC-01 sub-process runtime half (REQ-062) — internal support module, not
  part of any public HTTP-facing contract. Ports `instance.zig`'s
  `createWithParentInheritance()` (internal-only child creation), the
  `sub_process_start` pending event's own I/O-capable half, input-filter-on-
  activation, output-merge-on-completion, and the four SPC-01 failure modes
  routed through `Letflow.Engine.ExecutionError`. See
  `lib/letflow/design/req062-sub-process-runtime.md` for the full design this
  module implements.

  ## Internal-only child creation (AC6)

  Nothing in this module is reachable from `Letflow.Engine.create/2`'s public
  `create_attrs()` shape — `prepare_child_activation/4` is only ever called
  by `Letflow.Engine`'s own `:sub_process_start` pending-event consumers
  (this run's own `activate/3` and `dispatch_task_completion_hop_chain/5`
  call sites), never by anything reachable from an external caller's own
  input. There is no second `create/N`-shaped public entry point here.

  ## Zero `Repo` calls of its own, where possible (INV-EE47-7-adjacent)

  Every *write* this module performs happens inside the caller's own already
  -open `Ecto.Multi`/transaction (`append_start_multi/7`), matching
  `Letflow.Engine.TaskActivation`'s own composable shape. `prepare_child_activation/4`
  and `append_completion_multi/6` are the two documented exceptions (design
  §3.3/§3.4): both need *read* access before any Multi step is appended (a
  failed resolution/filter must write nothing at all), and both are only
  ever invoked from a point in `Letflow.Engine`'s own call graph that is
  already inside an open transaction (or, for `prepare_child_activation/4`
  at `create/2`'s own top-level call site, in the same "pre-Multi phase does
  its own I/O" position `create_snapshot/3` already occupies) — so a direct
  `Letflow.Repo` read here is a reentrant query against the same connection,
  not a second, independent transaction.

  ## OQ-1 — SUB_PROCESS node definition reference — RESOLVED against R-Co by
  ## REQ-111 (divergent_doc_only, doc-only, no engine-behaviour change)

  PROVENANCE (historical, not current decision authority):
  `resolve_child_definition/2` reads `node.attributes["definition_name"]` and
  resolves it via `Letflow.Definitions.get_active_by_name/2` — confirmed
  against `lib/letflow/definitions/graph.ex`'s own node-attribute validators
  (CHK-09..19): no validator names or checks any "which definition does this
  child run" attribute, so there is no existing convention this design could
  contradict. `Letflow.Engine.create/2`'s own `attrs[:definition_name]` /
  `Definitions.get_active_by_name/2` path is the one definition-resolution
  convention already established anywhere in this codebase, so it is reused
  here for internal consistency. This was originally flagged as an unverified
  guess; REQ-111 has since read `R-Co/src/engine/transition.zig:1903-1904` and
  `instance.zig:4681,4707-4712` directly and found R-Co keys the child on a
  different, mandatory attribute instead: `child_definition_id` (a UUID,
  early-bound at design time), not a name (late-bound here via
  `get_active_by_name/2`). Shipped Letflow behaviour is internally consistent
  and not incorrect against any Letflow spec, so this is recorded as a design
  difference (`lib/letflow/design/req062-sub-process-runtime.md` §3.3) rather
  than a bug — see that design doc for the full disposition and the semantic
  consequence (early- vs. late-binding of the child definition version).

  ## OQ-3 — nested (child-of-child) SUB_PROCESS activation not wired here

  `prepare_child_activation/4` runs the child's own `advance_until_stable/4`
  from `:START`; if that child's own graph contains a `:SUB_PROCESS` node,
  the resulting `{:sub_process_start, ...}` pending event is surfaced in the
  child's own final `InstanceState` but is **not** recursively consumed by
  this function. A grandchild is therefore not activated by this pass — the
  same, already-named OQ-3 gap the design doc flags (unbounded
  cross-definition recursion depth is explicitly out of this requirement's
  scope). This is a real, honestly-flagged limitation, not a silent gap.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.SnapshotStore
  alias Letflow.Definitions.SubProcessInterface
  alias Letflow.Engine.ExecutionError
  alias Letflow.Engine.IdempotentReplay
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.PinResolver
  alias Letflow.Engine.Task
  alias Letflow.Engine.TaskActivation
  alias Letflow.Engine.SnapshotWriter
  alias Letflow.Engine.Token
  alias Letflow.Engine.TokenRecord
  alias Letflow.Engine.Transition
  alias Letflow.Engine.VariableMerge
  alias Letflow.Engine.VariableSchema
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.EventStore.Registry.ValidationFailure
  alias Letflow.Repo
  alias Letflow.ServiceCatalog.PinLookup
  alias Letflow.TenantProvisioning

  @typedoc "The two activation-time (input-filter) SPC-01 failure modes, plus the defensive 5th."
  @type activation_failure ::
          {:missing_required_input, entry_name :: String.t()}
          | {:input_schema_violation, entry_name :: String.t(),
             failures :: [ValidationFailure.t()]}
          | {:definition_not_found, term()}
          | {:pin_resolution_failed, term()}

  @typedoc "The two completion-time (output-filter) SPC-01 failure modes."
  @type completion_failure ::
          {:missing_required_output, entry_name :: String.t()}
          | {:output_schema_violation, entry_name :: String.t(),
             failures :: [ValidationFailure.t()]}

  # ---------------------------------------------------------------------
  # ISS-0071 -- derived idempotency-key suffixes (see
  # lib/letflow/design/iss071-idempotency-key-helper.md). Must stay
  # pairwise-distinct from each other and from any caller-supplied base
  # idempotency_key, since event_idempotency.idempotency_key is a
  # schema-wide-unique index, not per-instance.
  # ---------------------------------------------------------------------
  @sub_process_start_suffix "sub_process_start"
  @sub_process_completion_error_suffix "sub_process_completion_error"
  @sub_process_completed_suffix "sub_process_completed"

  # ---------------------------------------------------------------------
  # §3.2.1 / §3.2.2 -- pure input/output filtering.
  # ---------------------------------------------------------------------

  @doc """
  Builds a sub-process child's initial variable map from its own optional,
  already-parsed `interface` (§3.2.1). `interface == nil` copies the full
  `parent_variables` map unchanged (EXT-05); an interface with `inputs: []`
  produces `%{}` — zero declared inputs means zero copied, never a fallback
  to EXT-05.

  GH #2587 (decision 0054 D1a.4, design D-A1.6): the result never carries a
  reserved engine key (`Letflow.Engine.VariableMerge.drop_reserved/1`) on
  either clause: engine-written values belong only to the instance that wrote
  them, so a parent holding them can still start children.
  """
  @spec build_child_initial_variables(SubProcessInterface.parsed_interface() | nil, map()) ::
          {:ok, map()} | {:error, activation_failure()}
  def build_child_initial_variables(nil, parent_variables),
    do: {:ok, VariableMerge.drop_reserved(parent_variables)}

  def build_child_initial_variables(%{inputs: inputs}, parent_variables) do
    case filter_entries(inputs, parent_variables) do
      {:ok, result} ->
        {:ok, VariableMerge.drop_reserved(result)}

      {:error, {:missing_required, name}} ->
        {:error, {:missing_required_input, name}}

      {:error, {:schema_violation, name, failures}} ->
        {:error, {:input_schema_violation, name, failures}}
    end
  end

  @doc """
  Builds the map to merge into the parent's variables from a completed
  child's own final variables, per the parent SUB_PROCESS node's optional,
  already-parsed `interface` (§3.2.2). `interface == nil` merges the full
  `child_variables` map (EXT-05); a child variable not named in `outputs` is
  structurally absent from the returned map, never filtered post-merge.

  GH #2587 (design D-A1.5): with no interface the child's own reserved engine
  keys are dropped (`Letflow.Engine.VariableMerge.drop_reserved/1`), so they
  never reach the parent and never fail its merge. An explicit `outputs`
  entry naming a reserved key is NOT dropped: the parent's merge refuses it
  into instance ERROR (`:reserved_variable_key`), a definition error.
  """
  @spec build_parent_merge_variables(SubProcessInterface.parsed_interface() | nil, map()) ::
          {:ok, map()} | {:error, completion_failure()}
  def build_parent_merge_variables(nil, child_variables),
    do: {:ok, VariableMerge.drop_reserved(child_variables)}

  def build_parent_merge_variables(%{outputs: outputs}, child_variables) do
    case filter_entries(outputs, child_variables) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:missing_required, name}} ->
        {:error, {:missing_required_output, name}}

      {:error, {:schema_violation, name, failures}} ->
        {:error, {:output_schema_violation, name, failures}}
    end
  end

  # Shared filter algorithm (§3.2.1/§3.2.2 -- symmetric by design): for each
  # declared entry (declared order), an absent required entry is the first
  # deterministic failure; an absent optional entry is silently omitted; a
  # present entry is validated against its own json_schema, wrapped as a
  # one-field object schema since JsonSchema.validate/2 requires both
  # arguments to be maps.
  @spec filter_entries([SubProcessInterface.entry()], map()) ::
          {:ok, map()}
          | {:error, {:missing_required, String.t()}}
          | {:error, {:schema_violation, String.t(), [ValidationFailure.t()]}}
  defp filter_entries(entries, source_variables) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      case Map.fetch(source_variables, entry.name) do
        :error when entry.required ->
          {:halt, {:error, {:missing_required, entry.name}}}

        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          wrapped_schema = %{
            "type" => "object",
            "properties" => %{entry.name => entry.json_schema},
            "required" => [entry.name]
          }

          case JsonSchema.validate(%{entry.name => value}, wrapped_schema) do
            [] -> {:cont, {:ok, Map.put(acc, entry.name, value)}}
            failures -> {:halt, {:error, {:schema_violation, entry.name, failures}}}
          end
      end
    end)
  end

  # ---------------------------------------------------------------------
  # §3.2.3 -- failure -> ExecutionError.error_args() mapping.
  # ---------------------------------------------------------------------

  @doc """
  Maps one of the 4 SPC-01 failure shapes (plus the defensive
  `:definition_not_found` 5th case) onto `Letflow.Engine.ExecutionError.error_args()`
  — every row shares `error_type: :subprocess_interface_violation`, with the
  4+1 R-Co-named codes distinguished only via `details.code` (§3.2.3).
  """
  @spec to_error_args(
          activation_failure() | completion_failure(),
          instance_id :: Ecto.UUID.t(),
          node_id :: String.t(),
          variables :: map(),
          actor_id :: Ecto.UUID.t() | nil,
          idempotency_key :: String.t()
        ) :: ExecutionError.error_args()
  def to_error_args(failure, instance_id, node_id, variables, actor_id, idempotency_key) do
    {code, field_name, failures} = failure_detail(failure)

    %{
      instance_id: instance_id,
      error_type: :subprocess_interface_violation,
      affected: {:field, field_name},
      reason: "sub-process interface violation at node '#{node_id}': #{code}",
      variables: variables,
      details: %{code: code, failures: failures},
      actor_id: actor_id,
      idempotency_key: idempotency_key
    }
  end

  defp failure_detail({:missing_required_input, name}),
    do: {"SUB_PROCESS_MISSING_REQUIRED_INPUT", name, []}

  defp failure_detail({:input_schema_violation, name, failures}),
    do: {"SUB_PROCESS_INPUT_SCHEMA_VIOLATION", name, failures}

  defp failure_detail({:missing_required_output, name}),
    do: {"SUB_PROCESS_MISSING_REQUIRED_OUTPUT", name, []}

  defp failure_detail({:output_schema_violation, name, failures}),
    do: {"SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION", name, failures}

  defp failure_detail({:definition_not_found, _reason}),
    do: {"SUB_PROCESS_DEFINITION_NOT_FOUND", "definition_name", []}

  # GH #2694: the child definition's own pins (script / catalog / module / variable schema)
  # could not be resolved; the child is not started.
  defp failure_detail({:pin_resolution_failed, _reason}),
    do: {"SUB_PROCESS_PIN_UNRESOLVED", "definition_name", []}

  # ISS-0071: shared derivation for the three sub_process idempotency-key
  # suffixes above, so the three call sites can't drift out of sync with
  # each other. See lib/letflow/design/iss071-idempotency-key-helper.md.
  @spec derive_idempotency_key(
          base :: String.t() | nil,
          suffix :: String.t(),
          ids :: [String.t()]
        ) :: String.t()
  defp derive_idempotency_key(base, suffix, ids) do
    Enum.join([base, suffix | ids], "::")
  end

  # ---------------------------------------------------------------------
  # §3.3 -- prepare_child_activation/4 (activation-time, pre-Multi).
  # ---------------------------------------------------------------------

  @doc """
  Resolves the child's definition (OQ-1), builds its graph, parses the
  SUB_PROCESS node's own optional `interface` attribute, filters the
  parent's variables down to the child's initial variable map, mints a
  fresh `child_instance_id`, snapshots the child's definition
  (`Letflow.Definitions.SnapshotStore.create/3`, its own transaction), and
  runs the child's own activation loop from `:START`. Runs entirely before
  any Multi step for this child is appended — a failed resolution or a
  failed input filter writes nothing (AC "ZERO child instances created" is
  structural: `append_start_multi/7` is simply never called on this path).
  """
  @spec prepare_child_activation(
          parent_instance_id :: Ecto.UUID.t() | nil,
          parent_variables :: map(),
          node :: Graph.Node.t(),
          opts :: [prefix: String.t()]
        ) ::
          {:ok,
           %{
             child_instance_id: Ecto.UUID.t(),
             definition: term(),
             graph: Graph.t(),
             interface: SubProcessInterface.parsed_interface() | nil,
             child_initial_state: InstanceState.t(),
             pins: [Letflow.Engine.PinResolver.pinned_version()],
             node_id: String.t()
           }}
          | {:error,
             activation_failure()
             | {:graph_structure_invalid, term()}
             | {:activation_failed, term()}}
  def prepare_child_activation(_parent_instance_id, parent_variables, %Graph.Node{} = node, opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, definition} <- resolve_child_definition(node, prefix),
         {:ok, graph} <- Letflow.Engine.build_graph(definition.graph),
         {parsed_interface, _violations} <-
           SubProcessInterface.parse_interface(
             node.id,
             get_in(node.attributes || %{}, ["interface"])
           ),
         {:ok, initial_variables} <-
           build_child_initial_variables(parsed_interface, parent_variables),
         {:ok, start_node} <- Letflow.Engine.find_start_node(graph),
         {:ok, pins} <- resolve_child_pins(graph, definition, prefix) do
      child_instance_id = Ecto.UUID.generate()

      with {:ok, _snapshot} <- create_child_snapshot(child_instance_id, definition, prefix) do
        token_id = Ecto.UUID.generate()

        root_token = %Token{
          token_id: token_id,
          node_id: start_node.id,
          branch_id: child_instance_id
        }

        child_seed_state = %InstanceState{
          instance_id: child_instance_id,
          status: :active,
          tokens: [root_token],
          variables: initial_variables,
          pending_task_nodes: []
        }

        hop_limit = length(graph.nodes) * 4 + 10

        case Letflow.Engine.advance_until_stable(graph, child_seed_state, [token_id], hop_limit) do
          {:ok, child_final_state, _pending_events} ->
            {:ok,
             %{
               child_instance_id: child_instance_id,
               definition: definition,
               graph: graph,
               interface: parsed_interface,
               child_initial_state: child_final_state,
               pins: pins,
               node_id: node.id
             }}

          {:error, reason} ->
            {:error, {:activation_failed, reason}}
        end
      end
    end
  end

  # GH #2694 -- the child's own pins, resolved FRESH for the child's definition with the same
  # lookup create/2 uses (catalog scoped to the tenant derived from the schema prefix, script
  # registry of that prefix), never inherited from the parent. Read-only; takes no lock.
  defp resolve_child_pins(graph, definition, prefix) do
    with {:ok, tenant_id} <- child_tenant_id(prefix),
         lookup = PinLookup.build(tenant_id, prefix),
         {:ok, pins, _variable_json_schema} <- PinResolver.resolve(graph, definition, lookup, []) do
      {:ok, pins}
    else
      {:error, reason} -> {:error, {:pin_resolution_failed, reason}}
    end
  end

  defp child_tenant_id(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, tenant_id} -> {:ok, tenant_id}
      {:error, _} -> {:error, :tenant_unresolved}
    end
  end

  defp resolve_child_definition(%Graph.Node{attributes: attributes, id: node_id}, prefix) do
    case get_in(attributes || %{}, ["definition_name"]) do
      name when is_binary(name) and name != "" ->
        case Definitions.get_active_by_name(name, prefix: prefix) do
          {:ok, definition} -> {:ok, definition}
          {:error, reason} -> {:error, {:definition_not_found, reason}}
        end

      _other ->
        {:error, {:definition_not_found, {:missing_definition_name_attribute, node_id}}}
    end
  end

  defp create_child_snapshot(child_instance_id, definition, prefix) do
    case SnapshotStore.create(child_instance_id, definition.id, prefix: prefix) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, {:activation_failed, {:snapshot_failed, reason}}}
    end
  end

  # ---------------------------------------------------------------------
  # §3.3 -- append_start_multi/7 (Multi-composable, appended onto the
  # caller's own already-open Multi.t()).
  # ---------------------------------------------------------------------

  @doc """
  Appends the child-creation write steps onto `multi`: the child's own
  `instance_projections` row (carrying `parent_instance_id`/`parent_token_id`,
  design §6.1), its root token row(s), any freshly-`:HUMAN_TASK`-pending
  task row(s), one `INSTANCE_STARTED` event on the child's own stream, and
  the parent token's own `%{status: :waiting, waiting_child_instance_id:
  child_instance_id}` update. If the child's own graph completed
  synchronously (`prepared.child_initial_state.status == :completed`), chains
  `append_completion_multi/6` for the same pair inside this same Multi
  before returning (design §3.3 step 6) — deviates from the design's own
  literal 6-arg signature by taking `parent_token_record_id`/`parent_node_id`
  as two separate arguments (rather than a combined `parent_token_id`) since
  the caller already has both resolved separately; flagged for REVIEWER as a
  deliberate, non-behavioral signature adjustment.
  """
  @spec append_start_multi(
          Multi.t(),
          parent_instance_id :: Ecto.UUID.t(),
          parent_token_record_id :: Ecto.UUID.t(),
          parent_node_id :: String.t(),
          prepared :: map(),
          attrs :: %{actor_id: Ecto.UUID.t() | nil, idempotency_key: String.t()},
          opts :: [prefix: String.t()]
        ) :: Multi.t()
  def append_start_multi(
        %Multi{} = multi,
        parent_instance_id,
        parent_token_record_id,
        parent_node_id,
        prepared,
        attrs,
        opts
      ) do
    prefix = Keyword.get(opts, :prefix)

    %{
      child_instance_id: child_instance_id,
      definition: definition,
      graph: graph,
      child_initial_state: child_initial_state
    } = prepared

    current_node_ids = Enum.map(child_initial_state.tokens, & &1.node_id)
    projection_key = {:sub_process_child_projection, child_instance_id}
    tokens_key = {:sub_process_child_tokens, child_instance_id}
    tasks_key = {:sub_process_child_tasks, child_instance_id}
    event_key = {:sub_process_child_event, child_instance_id}
    parent_token_key = {:sub_process_parent_token, child_instance_id}

    multi
    |> Multi.run(projection_key, fn repo, _changes ->
      insert_child_instance_projection(
        repo,
        child_instance_id,
        definition,
        current_node_ids,
        child_initial_state.variables,
        parent_instance_id,
        parent_token_record_id,
        prefix
      )
    end)
    |> Multi.run(tokens_key, fn repo, _changes ->
      insert_child_token_records(repo, child_instance_id, child_initial_state.tokens, prefix)
    end)
    |> Multi.run(tasks_key, fn repo, changes ->
      token_records = Map.fetch!(changes, tokens_key)

      insert_child_task_records(
        repo,
        child_instance_id,
        graph,
        child_initial_state,
        token_records,
        prefix
      )
    end)
    |> Multi.run(event_key, fn _repo, _changes ->
      append_instance_started_event_for_child(
        child_instance_id,
        definition,
        child_initial_state.variables,
        prepared.pins,
        parent_instance_id,
        parent_token_record_id,
        parent_node_id,
        attrs,
        prefix
      )
    end)
    |> Multi.run(parent_token_key, fn repo, _changes ->
      update_parent_token_waiting(
        repo,
        parent_token_record_id,
        parent_node_id,
        child_instance_id,
        prefix
      )
    end)
    |> maybe_chain_synchronous_completion(
      child_instance_id,
      prepared,
      parent_token_key,
      attrs,
      prefix
    )
  end

  defp maybe_chain_synchronous_completion(
         %Multi{} = multi,
         child_instance_id,
         %{child_initial_state: %InstanceState{status: :completed} = child_final_state},
         parent_token_key,
         attrs,
         prefix
       ) do
    Multi.merge(multi, fn changes ->
      parent_token = Map.fetch!(changes, parent_token_key)

      case append_completion_multi(
             Multi.new(),
             child_instance_id,
             child_final_state.variables,
             parent_token,
             prefix: prefix,
             actor_id: Map.get(attrs, :actor_id),
             idempotency_key: Map.get(attrs, :idempotency_key)
           ) do
        {:ok, completion_multi} ->
          completion_multi

        {:error, error_args} ->
          Multi.new() |> ExecutionError.append_multi(error_args, prefix: prefix)
      end
    end)
  end

  defp maybe_chain_synchronous_completion(
         %Multi{} = multi,
         _child_instance_id,
         _prepared,
         _parent_token_key,
         _attrs,
         _prefix
       ),
       do: multi

  defp insert_child_instance_projection(
         repo,
         child_instance_id,
         definition,
         current_node_ids,
         variables,
         parent_instance_id,
         parent_token_record_id,
         prefix
       ) do
    attrs = %{
      instance_id: child_instance_id,
      status: :active,
      definition_id: definition.id,
      correlation_key: nil,
      current_nodes: current_node_ids,
      variables: variables,
      parent_instance_id: parent_instance_id,
      parent_token_id: parent_token_record_id
    }

    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(attrs)
    |> repo.insert(prefix: prefix)
  end

  defp insert_child_token_records(_repo, _child_instance_id, [], _prefix), do: {:ok, []}

  defp insert_child_token_records(repo, child_instance_id, [%Token{} | _] = tokens, prefix) do
    tokens
    |> Enum.reduce_while({:ok, []}, fn %Token{} = token, {:ok, acc} ->
      attrs = %{
        instance_id: child_instance_id,
        node_id: token.node_id,
        branch_id: token.branch_id,
        status: :active
      }

      %TokenRecord{}
      |> TokenRecord.insert_changeset(attrs)
      |> repo.insert(prefix: prefix)
      |> case do
        {:ok, %TokenRecord{} = record} -> {:cont, {:ok, [record | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_child_task_records(
         repo,
         child_instance_id,
         graph,
         child_initial_state,
         token_records,
         prefix
       ) do
    id_map = TaskActivation.token_id_to_record_id(child_initial_state.tokens, token_records)

    child_initial_state.pending_task_nodes
    |> Enum.reduce_while({:ok, []}, fn %Token{} = token, {:ok, acc} ->
      with %Graph.Node{} = node <-
             Enum.find(graph.nodes, &(&1.id == token.node_id)) || :unknown_node,
           {:ok, token_record_id} <- Map.fetch(id_map, token.token_id),
           {:ok, attrs} <-
             TaskActivation.insert_attrs(child_instance_id, token_record_id, token, node),
           {:ok, task} <- insert_task(repo, attrs, prefix) do
        {:cont, {:ok, [task | acc]}}
      else
        :unknown_node -> {:halt, {:error, {:unknown_node_id, token.node_id}}}
        :error -> {:halt, {:error, {:missing_token_record, token.token_id}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_task(repo, attrs, prefix) do
    %Task{}
    |> Task.insert_changeset(attrs)
    |> repo.insert(prefix: prefix)
  end

  defp append_instance_started_event_for_child(
         child_instance_id,
         definition,
         initial_variables,
         pins,
         parent_instance_id,
         parent_token_record_id,
         parent_node_id,
         attrs,
         prefix
       ) do
    payload =
      Jason.encode!(%{
        definition_id: definition.id,
        correlation_key: nil,
        initial_variables: initial_variables,
        pinned_versions: pins,
        pin_conflicts: [],
        parent_instance_id: parent_instance_id,
        parent_token_id: parent_token_record_id,
        parent_node_id: parent_node_id
      })

    event_attrs = %{
      instance_id: child_instance_id,
      event_type: "INSTANCE_STARTED",
      payload: payload,
      actor_id: Map.get(attrs, :actor_id),
      # Derived, not the caller's own `idempotency_key` verbatim -- the
      # `event_idempotency` unique index (20260816120006_create_event_idempotency.exs)
      # is keyed on `idempotency_key` alone, schema-wide, not per-instance. Reusing
      # the parent create/2 (or complete_task/3) call's own idempotency_key unchanged
      # for the child's own INSTANCE_STARTED event collides with that SAME key's use
      # for the parent-stream event appended later in the same transaction, which
      # EventStore.append/2 (itself opening its own nested Repo.transaction/1) then
      # surfaces as a claim_idempotency :error step -- fatal here because Ecto.Multi's
      # own internal rollback for that nested transaction is not bubbled cleanly
      # through the outer Multi (Ecto raises "operation :rollback is rolling back
      # unexpectedly" instead of a typed error tuple). `child_instance_id` is a
      # freshly minted UUID (prepare_child_activation/4), so suffixing it here is
      # sufficient on its own to guarantee no collision with any other event this
      # same request appends, while keeping the value traceable back to the
      # originating request's own idempotency_key.
      idempotency_key:
        derive_idempotency_key(
          Map.get(attrs, :idempotency_key),
          @sub_process_start_suffix,
          [child_instance_id]
        )
    }

    # GH #2577 (D-2): a key claimed by another request is reuse; the Multi fails before the
    # parent projection is reconciled, so no write follows the aborted connection.
    case EventStore.append(event_attrs, prefix: prefix) |> IdempotentReplay.fresh() do
      {:ok, result} -> {:ok, result}
      {:error, {:idempotent_replay, _original}} -> {:error, :idempotency_key_reuse}
      {:error, reason} -> {:error, {:event_append_failed, reason}}
    end
  end

  defp update_parent_token_waiting(
         repo,
         parent_token_record_id,
         parent_node_id,
         child_instance_id,
         prefix
       ) do
    case repo.get(TokenRecord, parent_token_record_id, prefix: prefix) do
      nil ->
        {:error, {:missing_token_record, parent_token_record_id}}

      %TokenRecord{} = record ->
        record
        |> TokenRecord.advance_changeset(%{
          node_id: parent_node_id,
          status: :waiting,
          waiting_child_instance_id: child_instance_id
        })
        |> repo.update(prefix: prefix)
    end
  end

  # ---------------------------------------------------------------------
  # §3.4 -- child-completion consumers.
  # ---------------------------------------------------------------------

  @doc """
  Row-locks and returns the parent's own `:waiting` token whose
  `waiting_child_instance_id` matches `child_instance_id`, or `nil` if none
  (the child is not, or no longer, a sub-process child anyone is waiting
  on). Locked so a concurrent second completion attempt on the same child
  can't double-fire the parent cascade.

  Lock order (GH #2695): `P_parent`, then the token. Thin delegate to
  `lock_waiting_parent/3`.
  """
  @spec find_waiting_parent_token(Ecto.Repo.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, TokenRecord.t() | nil}
  def find_waiting_parent_token(repo, child_instance_id, prefix) do
    lock_waiting_parent(repo, child_instance_id, prefix)
  end

  # GH #2695: the parent side of the sub-process cascade locks the parent
  # projection FIRST, then the waiting token -- the order cancel_instance,
  # complete_task, Scheduler.fire_timer and ExecutionError already use.
  # (1) unlocked read of the waiting token to learn the parent instance;
  # (2) FOR UPDATE on that parent's projection row (a missing projection
  # skips the lock; load_parent_context reports it as before); (3) re-select
  # the token FOR UPDATE with the same predicate -- the re-check decides the
  # result, so a token cancelled/advanced meanwhile yields nil. The projection
  # lock stays held when (3) yields nil (released at commit).
  #
  # `mode` is `:update` (FOR UPDATE: the cascade and a completing child) or `:key_share`
  # (FOR KEY SHARE: a CONTINUING child, which only has to be queued ahead of a parent cancel's
  # FOR UPDATE in the same P-then-T order; key-share is compatible between siblings, so
  # continuing siblings do not serialise on the parent).
  @doc false
  @spec lock_waiting_parent(
          Ecto.Repo.t(),
          Ecto.UUID.t(),
          String.t() | nil,
          :update | :key_share
        ) :: {:ok, TokenRecord.t() | nil}
  def lock_waiting_parent(repo, child_instance_id, prefix, mode \\ :update)
      when mode in [:update, :key_share] do
    waiting =
      where(
        TokenRecord,
        [t],
        t.waiting_child_instance_id == ^child_instance_id and t.status == :waiting
      )

    case repo.one(select(waiting, [t], t.instance_id), prefix: prefix) do
      nil ->
        {:ok, nil}

      parent_instance_id ->
        projection =
          InstanceProjection
          |> where([p], p.instance_id == ^parent_instance_id)
          |> select([p], p.instance_id)

        _ = projection |> lock_rows(mode) |> repo.one(prefix: prefix)
        {:ok, waiting |> lock_rows(mode) |> repo.one(prefix: prefix)}
    end
  end

  defp lock_rows(query, :update), do: lock(query, "FOR UPDATE")
  defp lock_rows(query, :key_share), do: lock(query, "FOR KEY SHARE")

  # GH #2695: locks the whole ancestor group (P_p, T_p, P_g, T_g, ...) of a
  # completing sub-process child, nearest first. Speculative above the
  # immediate parent (the parent may not complete): over-locks, never
  # under-locks. Idempotent with the later cascade lookup.
  @doc false
  @spec lock_waiting_parent_chain(Ecto.Repo.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, [TokenRecord.t()]}
  def lock_waiting_parent_chain(repo, child_instance_id, prefix) do
    {:ok, collect_waiting_parents(repo, child_instance_id, prefix, [], MapSet.new())}
  end

  # `seen` ends the walk on a repeated instance (a corrupt cycle of waiting tokens).
  defp collect_waiting_parents(repo, instance_id, prefix, acc, seen) do
    with false <- MapSet.member?(seen, instance_id),
         {:ok, %TokenRecord{instance_id: parent_id} = token} <-
           lock_waiting_parent(repo, instance_id, prefix) do
      collect_waiting_parents(
        repo,
        parent_id,
        prefix,
        [token | acc],
        MapSet.put(seen, instance_id)
      )
    else
      _stop -> Enum.reverse(acc)
    end
  end

  @doc """
  Builds and returns the Multi steps that clear the parent token's wait,
  merge the child's filtered output into the parent's variables, advance the
  parent past its SUB_PROCESS node, and reconcile the parent's own
  projection/task/token rows — or `{:error, error_args}` if the interface's
  own output filter rejects the child's final variables (§3.2.2), in which
  case **no Multi step from this function has been appended at all** (the
  merge is not applied, not partially applied — AC's own "no partial merge"
  wording is structural here, not a rollback).

  Performs its own read-only `Letflow.Repo` calls to gather the parent's
  snapshot/graph/live-token/pending-task state before computing anything —
  see this module's moduledoc for why that is safe here (always invoked from
  a point already inside an open transaction). Recurses grandparent-ward
  when the parent instance itself completes as a result and has its own
  waiting parent token (design §3.4 point 3).
  """
  @spec append_completion_multi(
          Multi.t(),
          child_instance_id :: Ecto.UUID.t(),
          child_final_variables :: map(),
          parent_token :: TokenRecord.t(),
          opts :: [prefix: String.t(), actor_id: Ecto.UUID.t() | nil, idempotency_key: String.t()]
        ) :: {:ok, Multi.t()} | {:error, ExecutionError.error_args()}
  def append_completion_multi(
        %Multi{} = multi,
        child_instance_id,
        child_final_variables,
        %TokenRecord{} = parent_token,
        opts
      ) do
    prefix = Keyword.get(opts, :prefix)
    actor_id = Keyword.get(opts, :actor_id)
    idempotency_key = Keyword.get(opts, :idempotency_key)

    # Derived, not the caller's own `idempotency_key` verbatim -- same
    # collision reason as append_instance_started_event_for_child/8's and
    # append_sub_process_completed_event/8's own comments: the caller's
    # idempotency_key is also used, in the same transaction, for the
    # completing task's own TASK_COMPLETED event. Reusing it unchanged for
    # this cascade's own ExecutionError event would collide against the
    # schema-wide-unique event_idempotency.idempotency_key index. Distinct
    # from both ::sub_process_start:: and ::sub_process_completed:: so it
    # can never collide with either.
    error_idempotency_key =
      derive_idempotency_key(
        idempotency_key,
        @sub_process_completion_error_suffix,
        [parent_token.instance_id, child_instance_id]
      )

    case load_parent_context(parent_token, prefix) do
      {:error, reason} ->
        {:error,
         to_error_args(
           {:definition_not_found, reason},
           parent_token.instance_id,
           parent_token.node_id,
           %{},
           actor_id,
           error_idempotency_key
         )}

      {:ok, graph, node, seed_state, token_records, definition_id} ->
        interface =
          node &&
            SubProcessInterface.parse_interface(
              node.id,
              get_in(node.attributes || %{}, ["interface"])
            )
            |> elem(0)

        case build_parent_merge_variables(interface, child_final_variables) do
          {:error, failure} ->
            {:error,
             to_error_args(
               failure,
               parent_token.instance_id,
               parent_token.node_id,
               seed_state.variables,
               actor_id,
               error_idempotency_key
             )}

          {:ok, merge_variables} ->
            build_completion_multi_from_merge(
              multi,
              child_instance_id,
              merge_variables,
              graph,
              parent_token,
              seed_state,
              token_records,
              definition_id,
              actor_id,
              idempotency_key,
              error_idempotency_key,
              prefix
            )
        end
    end
  end

  # PROVENANCE (historical, not current decision authority):
  # OQ-2 (req062-sub-process-runtime.md §9, GH#329): verified against R-Co
  # (`R-Co/src/engine/instance.zig`'s `mergeVariables`, called at line 4956
  # for the sub-process completion path with the exact same `variable_schemas`
  # lookup as every other merge call, keyed only on `definition_id` -- never
  # skipped for a sub-process output merge). The parent's own registered
  # variable-type schemas DO apply here, the same way they already apply to a
  # completed task's output merge (`Letflow.Engine.merge_output_variables/7`,
  # REQ-109) -- reuses that same `VariableSchema.variable_validations/5`
  # lookup rather than the previous literal `nil`.
  defp build_completion_multi_from_merge(
         multi,
         child_instance_id,
         merge_variables,
         graph,
         parent_token,
         %InstanceState{} = seed_state,
         token_records,
         definition_id,
         actor_id,
         idempotency_key,
         error_idempotency_key,
         prefix
       ) do
    with {:ok, variable_validations} <-
           VariableSchema.variable_validations(
             Repo,
             definition_id,
             seed_state.variables,
             merge_variables,
             prefix: prefix
           ),
         {:ok, new_variables, merge_events} <-
           VariableMerge.merge(seed_state.variables, merge_variables, variable_validations) do
      state_with_merged = %InstanceState{seed_state | variables: new_variables}
      parent_token_id_string = to_string(parent_token.id)

      case Transition.transition(
             graph,
             state_with_merged,
             {:sub_process_completed, parent_token_id_string}
           ) do
        {:error, reason} ->
          {:error,
           to_error_args(
             {:definition_not_found, {:transition_failed, reason}},
             parent_token.instance_id,
             parent_token.node_id,
             state_with_merged.variables,
             actor_id,
             error_idempotency_key
           )}

        {:ok, new_instance_state, transition_pending_events} ->
          newly_pending =
            Letflow.Engine.tokens_needing_dispatch(
              state_with_merged.tokens,
              new_instance_state.tokens,
              parent_token_id_string
            )

          hop_limit = length(graph.nodes) * 4 + 10

          case Letflow.Engine.advance_until_stable(
                 graph,
                 new_instance_state,
                 newly_pending,
                 hop_limit
               ) do
            {:error, reason} ->
              {:error,
               to_error_args(
                 {:definition_not_found, {:activation_failed, reason}},
                 parent_token.instance_id,
                 parent_token.node_id,
                 state_with_merged.variables,
                 actor_id,
                 error_idempotency_key
               )}

            {:ok, final_instance_state, hop_pending_events} ->
              # ISS-0929: keep the hop chain's pending events (timer / escalation /
              # service-task-dispatch requests) instead of discarding them, so a node
              # reached right after the sub-process gets its timers / dispatch rows.
              # Deduplicated by identity: duplicate Multi step names would raise.
              completion_pending_events =
                Enum.uniq(transition_pending_events ++ hop_pending_events)

              case build_completion_write_steps(
                     multi,
                     child_instance_id,
                     parent_token,
                     graph,
                     seed_state,
                     token_records,
                     final_instance_state,
                     completion_pending_events,
                     merge_variables,
                     merge_events,
                     actor_id,
                     idempotency_key,
                     prefix
                   ) do
                {:ok, multi_with_steps} ->
                  {:ok, multi_with_steps}

                {:error, reason} ->
                  {:error,
                   to_error_args(
                     {:definition_not_found, {:activation_failed, reason}},
                     parent_token.instance_id,
                     parent_token.node_id,
                     state_with_merged.variables,
                     actor_id,
                     error_idempotency_key
                   )}
              end
          end
      end
    else
      {:rejected, _unchanged_variables,
       [{:execution_error, key, rejected_value, :variable_schema_rejected, failures}]} ->
        {:error,
         %{
           instance_id: parent_token.instance_id,
           error_type: :variable_schema_rejected,
           affected: {:field, key},
           reason: "variable '#{key}' failed schema validation",
           variables: seed_state.variables,
           details: %{rejected_value: rejected_value, failures: failures},
           actor_id: actor_id,
           idempotency_key: error_idempotency_key
         }}

      # GH #2587 (D-A1.5): reached only through an explicit interface `outputs` entry
      # naming a reserved key (a no-interface merge map has its reserved keys dropped
      # in build_parent_merge_variables/2). The value is never carried.
      {:rejected, _unchanged_variables,
       [{:execution_error, key, _rejected_value, :reserved_variable_key, _failures}]} ->
        {:error,
         %{
           instance_id: parent_token.instance_id,
           error_type: :reserved_variable_key,
           affected: {:field, key},
           reason: "variable '#{key}' is reserved",
           variables: seed_state.variables,
           details: %{},
           actor_id: actor_id,
           idempotency_key: error_idempotency_key
         }}

      {:error, reason} when reason in [:missing_prefix, :invalid_definition_id] ->
        # Defensive only -- `prefix` and `definition_id` were already used
        # successfully by load_parent_context/2's own reads a moment earlier
        # in this same call, so neither failure is expected to be reachable
        # in practice at this point.
        {:error,
         %{
           instance_id: parent_token.instance_id,
           error_type: :variable_schema_lookup_failed,
           affected: {:node, parent_token.node_id},
           reason:
             "sub-process output merge could not look up registered variable schemas: #{inspect(reason)}",
           variables: seed_state.variables,
           details: %{reason: reason},
           actor_id: actor_id,
           idempotency_key: error_idempotency_key
         }}
    end
  end

  defp build_completion_write_steps(
         multi,
         child_instance_id,
         parent_token,
         graph,
         seed_state,
         token_records,
         final_instance_state,
         completion_pending_events,
         merge_variables,
         merge_events,
         actor_id,
         idempotency_key,
         prefix
       ) do
    completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    parent_instance_id = parent_token.instance_id
    reconciliation_key = {:sub_process_parent_token_reconciliation, parent_token.id}
    event_key = {:sub_process_completed_event, parent_token.id}
    projection_key = {:sub_process_parent_projection, parent_token.id}
    cascade_lookup_key = {:sub_process_grandparent_lookup, parent_instance_id}

    # ISS-0975 fix (design doc §1.2): a PARALLEL_GATEWAY join firing within
    # the child's own last hop chain (the completion that got us here) can
    # mint a token_id that is not yet a real, persisted TokenRecord id --
    # reconcile_parent_tokens/5's own guard would otherwise reject it
    # outright. Port ISS-0408's insert-before-reconcile treatment here: a
    # leading Multi.merge/2 inserts real TokenRecord rows for any such
    # hop-chain-local-new token first, rewrites final_instance_state to
    # reference the real ids, and only then runs task activation and
    # reconciliation against the rewritten state and a widened "already
    # known" token set. Keyed by {parent_instance_id, parent_token.id} (a
    # 3-tuple with the leading atom) rather than {parent_instance_id} alone,
    # since this function can run once per sibling SUB_PROCESS child of the
    # same parent within one Multi (same reason
    # TaskActivation.append_multi_from_existing_records/6's own
    # key_disambiguator parameter exists).
    hop_chain_key = {:sub_process_hop_chain_token_records, parent_instance_id, parent_token.id}

    reconciled_multi =
      multi
      |> Multi.merge(fn _changes ->
        Multi.new()
        |> Multi.run(hop_chain_key, fn repo, _changes ->
          Letflow.Engine.insert_hop_chain_new_token_records(
            repo,
            parent_instance_id,
            token_records,
            final_instance_state.tokens,
            prefix
          )
        end)
        |> Multi.merge(fn changes ->
          {id_map, hop_chain_new_records} = Map.fetch!(changes, hop_chain_key)

          resolved_final_instance_state =
            Letflow.Engine.rewrite_token_ids(final_instance_state, id_map)

          Multi.new()
          |> TaskActivation.append_multi_from_existing_records(
            parent_instance_id,
            graph,
            seed_state.pending_task_nodes,
            resolved_final_instance_state,
            prefix,
            parent_token.id
          )
          |> Multi.run(reconciliation_key, fn repo, _changes ->
            reconcile_parent_tokens(
              repo,
              hop_chain_new_records ++ token_records,
              resolved_final_instance_state.tokens,
              completed_at,
              prefix
            )
          end)
        end)
      end)

    # ISS-0929: timer / escalation / service-task-dispatch rows for the pending
    # events the post-sub-process hop chain produced. Placed after the token
    # reconciliation step (real TokenRecord ids exist) and resolved eagerly so a
    # failure surfaces as an error the caller maps to activation_failed.
    with {:ok, armed_multi} <-
           Letflow.Engine.append_pending_event_arms_multi(
             reconciled_multi,
             completion_pending_events,
             graph,
             parent_instance_id,
             final_instance_state.variables,
             completed_at,
             prefix,
             hop_chain_key
           ) do
      {:ok,
       armed_multi
       |> append_completion_tail_steps(
         event_key,
         projection_key,
         cascade_lookup_key,
         child_instance_id,
         parent_instance_id,
         final_instance_state,
         merge_variables,
         merge_events,
         actor_id,
         idempotency_key,
         completed_at,
         prefix
       )}
    end
  end

  defp append_completion_tail_steps(
         multi,
         event_key,
         projection_key,
         cascade_lookup_key,
         child_instance_id,
         parent_instance_id,
         final_instance_state,
         merge_variables,
         merge_events,
         actor_id,
         idempotency_key,
         completed_at,
         prefix
       ) do
    multi
    |> Multi.run(event_key, fn _repo, _changes ->
      append_sub_process_completed_event(
        parent_instance_id,
        child_instance_id,
        merge_variables,
        merge_events,
        final_instance_state,
        actor_id,
        idempotency_key,
        prefix
      )
    end)
    |> Multi.run(projection_key, fn repo, _changes ->
      reconcile_parent_projection(
        repo,
        parent_instance_id,
        final_instance_state,
        completed_at,
        prefix
      )
    end)
    |> maybe_cascade_to_grandparent(
      cascade_lookup_key,
      parent_instance_id,
      final_instance_state,
      actor_id,
      idempotency_key,
      prefix
    )
  end

  defp maybe_cascade_to_grandparent(
         multi,
         cascade_lookup_key,
         parent_instance_id,
         %InstanceState{status: :completed} = final_instance_state,
         actor_id,
         idempotency_key,
         prefix
       ) do
    multi
    |> Multi.run(cascade_lookup_key, fn repo, _changes ->
      find_waiting_parent_token(repo, parent_instance_id, prefix)
    end)
    |> Multi.merge(fn changes ->
      # Multi.run/3 stores the unwrapped ok-value in `changes`, not the
      # {:ok, _} tuple find_waiting_parent_token/3 itself returns -- match
      # the raw value here, not the tuple.
      case Map.fetch!(changes, cascade_lookup_key) do
        nil ->
          Multi.new()

        %TokenRecord{} = grandparent_token ->
          case append_completion_multi(
                 Multi.new(),
                 parent_instance_id,
                 final_instance_state.variables,
                 grandparent_token,
                 prefix: prefix,
                 actor_id: actor_id,
                 idempotency_key: idempotency_key
               ) do
            {:ok, cascade_multi} ->
              cascade_multi

            {:error, error_args} ->
              Multi.new() |> ExecutionError.append_multi(error_args, prefix: prefix)
          end
      end
    end)
  end

  defp maybe_cascade_to_grandparent(
         multi,
         _key,
         _parent_instance_id,
         _final_instance_state,
         _actor_id,
         _idempotency_key,
         _prefix
       ),
       do: multi

  # Reads the parent's own snapshot/graph, its currently-locked-or-live
  # token set, its pending PENDING tasks, and its own instance_projections
  # row -- the narrowest reconstruction sufficient for one
  # sub-process-completion dispatch, same shape as
  # Letflow.Engine.complete_task/3's own build_snapshot_and_state/4.
  defp load_parent_context(%TokenRecord{} = parent_token, prefix) do
    with {:ok, snapshot} <-
           SnapshotStore.get_by_instance_id(parent_token.instance_id, prefix: prefix),
         {:ok, graph} <- Letflow.Engine.build_graph(snapshot.graph) do
      case Repo.get(InstanceProjection, parent_token.instance_id, prefix: prefix) do
        nil ->
          {:error, :parent_projection_not_found}

        %InstanceProjection{} = projection ->
          token_records =
            TokenRecord
            |> where(
              [t],
              t.instance_id == ^parent_token.instance_id and t.status in [:active, :waiting]
            )
            |> Repo.all(prefix: prefix)

          active_tokens = Enum.map(token_records, &to_pure_token/1)

          pending_task_tokens =
            Task
            |> where([t], t.instance_id == ^parent_token.instance_id and t.status == :pending)
            |> Repo.all(prefix: prefix)
            |> Enum.map(
              &%Token{token_id: to_string(&1.token_id), node_id: &1.node_id, branch_id: nil}
            )

          # Bugfix discovered while implementing ISS-0396 (see
          # lib/letflow/design/iss0396-task-records-multi-sibling-fix.md's
          # own test scenario, §5, which is the first test in the codebase to
          # exercise a real PARALLEL_GATEWAY join reached via THIS function's
          # own seed_state, rather than via Letflow.Engine's
          # build_instance_state/3): join_counters was hardcoded to `%{}`
          # here, unlike build_instance_state/3's own
          # `SnapshotWriter.deserialize_join_counters(projection.join_counters)`
          # (the ISS-0397 fix, lib/letflow/design/iss0397-join-counters-fix.md
          # §2.5) -- ISS-0397's fix only touched Letflow.Engine's own
          # build_instance_state/3, not this function's separate,
          # sub-process-completion-cascade-specific copy of the same
          # seed-state-building logic. With join_counters always empty here,
          # any SUB_PROCESS child whose parent token completes directly onto
          # a PARALLEL_GATEWAY join (Transition.dispatch_parallel_join/4)
          # always fails with {:unknown_branch_id, ...} (Map.get returns nil),
          # surfaced to callers as a misleading
          # SUB_PROCESS_DEFINITION_NOT_FOUND execution error via this
          # module's own to_error_args/6 {:definition_not_found, reason}
          # catch-all mapping. Restoring the real persisted counters here,
          # exactly as build_instance_state/3 already does, is required for
          # ISS-0396's own regression test (a root split into two sibling
          # SUB_PROCESS children rejoined by a PARALLEL_GATEWAY) to run at
          # all, and is flagged here for REVIEWER: out of
          # iss0396-task-records-multi-sibling-fix.md's own stated
          # file-touch list (§6), but a minimal, targeted correctness fix
          # with no scope beyond restoring the exact behavior
          # build_instance_state/3 already has.
          seed_state = %InstanceState{
            instance_id: projection.instance_id,
            status: :active,
            tokens: active_tokens,
            variables: projection.variables,
            pending_task_nodes: pending_task_tokens,
            join_counters: SnapshotWriter.deserialize_join_counters(projection.join_counters)
          }

          node = Enum.find(graph.nodes, &(&1.id == parent_token.node_id))

          {:ok, graph, node, seed_state, token_records, projection.definition_id}
      end
    end
  end

  defp to_pure_token(%TokenRecord{} = record) do
    %Token{
      token_id: to_string(record.id),
      node_id: record.node_id,
      branch_id: record.branch_id,
      waiting_child_instance_id: record.waiting_child_instance_id
    }
  end

  # Reconciles the parent's own pre-existing token rows against
  # final_instance_state.tokens -- same algorithm as
  # Letflow.Engine's own do_reconcile_token_records/5 (kept as a local,
  # uniquely-keyed copy here rather than reused directly, since this
  # function's own caller can itself recurse grandparent-ward within one
  # open Multi, and Letflow.Engine's own version hardcodes a single,
  # non-unique :token_reconciliation Multi step name that would collide
  # across cascade levels).
  defp reconcile_parent_tokens(repo, original_tokens, final_tokens, completed_at, prefix) do
    original_ids = MapSet.new(original_tokens, &to_string(&1.id))

    case Enum.find(final_tokens, &(not MapSet.member?(original_ids, &1.token_id))) do
      %Token{token_id: token_id} ->
        {:error, {:new_token_during_resume_not_supported, token_id}}

      nil ->
        final_by_id = Map.new(final_tokens, &{&1.token_id, &1})

        original_tokens
        |> Enum.reduce_while({:ok, []}, fn %TokenRecord{} = record, {:ok, acc} ->
          case reconcile_one_parent_token(repo, record, final_by_id, completed_at, prefix) do
            {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, records} -> {:ok, Enum.reverse(records)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp reconcile_one_parent_token(
         repo,
         %TokenRecord{} = record,
         final_by_id,
         completed_at,
         prefix
       ) do
    case Map.fetch(final_by_id, to_string(record.id)) do
      {:ok, %Token{node_id: node_id, waiting_child_instance_id: waiting_child_instance_id}}
      when node_id != record.node_id or
             waiting_child_instance_id != record.waiting_child_instance_id ->
        record
        |> TokenRecord.advance_changeset(%{
          node_id: node_id,
          status: :active,
          waiting_child_instance_id: waiting_child_instance_id
        })
        |> repo.update(prefix: prefix)

      {:ok, _unchanged} ->
        {:ok, record}

      :error ->
        record
        |> TokenRecord.advance_changeset(%{status: :completed, completed_at: completed_at})
        |> repo.update(prefix: prefix)
    end
  end

  defp append_sub_process_completed_event(
         parent_instance_id,
         child_instance_id,
         merge_variables,
         merge_events,
         final_instance_state,
         actor_id,
         idempotency_key,
         prefix
       ) do
    payload =
      Jason.encode!(%{
        child_instance_id: child_instance_id,
        output_variables: merge_variables,
        merged_variable_events: encode_merge_events(merge_events),
        activated_nodes: Enum.map(final_instance_state.tokens, & &1.node_id)
      })

    event_attrs = %{
      instance_id: parent_instance_id,
      event_type: "SUB_PROCESS_COMPLETED",
      payload: payload,
      actor_id: actor_id,
      # Derived, not the caller's own `idempotency_key` verbatim -- same
      # collision reason as append_instance_started_event_for_child/8's own
      # comment above: the caller's `idempotency_key` (create/2's or
      # complete_task/3's own) is also used, in the same transaction, for
      # that call's own primary event on a DIFFERENT stream (the parent's
      # INSTANCE_STARTED, or the completing task's own TASK_COMPLETED).
      # Reusing it unchanged here would collide against the
      # schema-wide-unique `event_idempotency.idempotency_key` index.
      idempotency_key:
        derive_idempotency_key(
          idempotency_key,
          @sub_process_completed_suffix,
          [parent_instance_id, child_instance_id]
        )
    }

    # GH #2577 (D-2): a key claimed by another request is reuse; the Multi fails before the
    # parent projection is reconciled, so no write follows the aborted connection.
    case EventStore.append(event_attrs, prefix: prefix) |> IdempotentReplay.fresh() do
      {:ok, result} -> {:ok, result}
      {:error, {:idempotent_replay, _original}} -> {:error, :idempotency_key_reuse}
      {:error, reason} -> {:error, {:event_append_failed, reason}}
    end
  end

  defp encode_merge_events(merge_events) do
    Enum.map(merge_events, fn {:variable_overwritten, key, old_value, new_value} ->
      %{event: "variable_overwritten", key: key, old_value: old_value, new_value: new_value}
    end)
  end

  defp reconcile_parent_projection(
         repo,
         parent_instance_id,
         %InstanceState{} = final_instance_state,
         completed_at,
         prefix
       ) do
    case Repo.get(InstanceProjection, parent_instance_id, prefix: prefix) do
      nil ->
        {:error, {:instance_not_found, parent_instance_id}}

      %InstanceProjection{} = projection ->
        # Bugfix companion to load_parent_context/2's own join_counters fix
        # above (discovered the same way, while implementing ISS-0396):
        # join_counters was never written back here at all, unlike
        # Letflow.Engine's own reconcile_projection/5 (the ISS-0397 fix,
        # lib/letflow/design/iss0397-join-counters-fix.md §2.4, "persisted
        # unconditionally on every call"). Without this, a sibling
        # SUB_PROCESS completion's own updated join cohort (e.g. sibling 1
        # recording its own branch as received, still :wait) is computed in
        # memory by Transition.dispatch_parallel_join/4 but never survives
        # past this Multi step -- sibling 2's own later load_parent_context/2
        # call re-reads the stale, pre-sibling-1 cohort from the DB and the
        # join never fires. Same fix shape as reconcile_projection/5:
        # persisted unconditionally, not just when a gateway was touched.
        attrs = %{
          status: final_instance_state.status,
          current_nodes: Enum.map(final_instance_state.tokens, & &1.node_id),
          variables: final_instance_state.variables,
          join_counters:
            SnapshotWriter.serialize_join_counters(final_instance_state.join_counters)
        }

        attrs =
          if final_instance_state.status == :completed do
            Map.put(attrs, :completed_at, completed_at)
          else
            attrs
          end

        projection
        |> InstanceProjection.update_changeset(attrs)
        |> repo.update(prefix: prefix)
    end
  end
end
