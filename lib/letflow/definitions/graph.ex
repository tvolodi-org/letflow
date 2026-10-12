defmodule Letflow.Definitions.Graph do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Graph structural validator — the pure, no-I/O validation core of a process
  definition's `graph` (`{"nodes": [...], "edges": [...]}` shape). Ported from
  `src/definition/graph.zig`'s `validateGraph()` (R-Co,
  `C:\\Users\\tvolo\\dev\\ai-dala\\R-Co\\src\\definition\\graph.zig`, lines ~191-384)
  per `src/design/definition.md`'s "Named validation checks (PD-02)" table and
  `lib/letflow/design/req028-graph-structural-validator.md` (the gate-approved
  design this module implements).

  PROVENANCE (historical, not current decision authority):
  `Letflow.Definitions.Graph` *is* the graph struct being validated
  (`%Letflow.Definitions.Graph{nodes: [...], edges: [...]}`, mirroring
  `graph.zig`'s `DefinitionGraph`) and also hosts `validate_graph/1` plus the 8
  named checks — see the design doc §1 for why the struct and the validator
  share one module name. `Node`, `Edge`, and `Violation` are nested modules in
  this same file (design doc §1): they have no meaning or reuse outside graph
  validation.

  ## Purity (AC5)

  This module and everything in its call graph depend on Elixir/Erlang stdlib
  only (`Enum`, `Map`, `MapSet`, `Kernel`) — no `Letflow.Repo`, no
  `Ecto.Changeset`, no `Logger.*`, no clock read, no HTTP/file call, no
  process-mailbox call. `validate_graph/1` cannot fail in the usual
  `:ok | {:error, _}` sense: a structurally-invalid input graph is a
  legitimate output value (`%{valid: false, violations: [...]}`), not a
  function failure — see design doc §4 for why this diverges from
  `backend_developer_guide.md` §3.5's usual convention.

  ## The 8 named checks (CHK-01..CHK-08, 9 violation codes)

  All 8 checks run unconditionally against the same, unmodified input graph
  and their results are concatenated in a fixed order — no check
  short-circuits on, or depends on, another's outcome (Key invariant 5). See
  design doc §5 for the exact trigger/message table, §6 for the DFS-based
  cycle check (CHK-06), and §7 for the never-short-circuit / check-independence
  proof.

  ## Node-attribute and edge-condition checks (CHK-09..CHK-17, CHK-19, REQ-029, ISS-0056)

  `validate_node_attributes/1` (PD-05) and `validate_edge_conditions/1`
  (PD-06) are separate public functions, not folded into `validate_graph/1`
  — see `lib/letflow/design/req029-node-attribute-edge-condition-validators.md`
  §1 for the full rationale. **Ordering contract, enforced entirely by the
  caller, not by this module:** both functions assume — but do not verify —
  that `validate_graph/1` has already been called and returned
  `valid: true` on the same graph value. Neither function calls
  `validate_graph/1` internally or checks structural validity as a
  precondition; calling either out of order, or against a structurally
  invalid graph, will not crash but may produce misleading or redundant
  violations. Enforcing the actual "run PD-05/PD-06 only after
  `validate_graph/1` succeeds" ordering is the caller's job (intended to be
  `Letflow.Definitions.create/1`, REQ-030, once it exists).

  ## Flow checks (CHK-22..CHK-24, REQ-455)

  `validate_flow/1` is a fourth top-level validator beside `validate_graph/1`,
  `validate_node_attributes/1` and `validate_edge_conditions/1`. It adds
  reachability (CHK-22 `:unreachable_node`: every node reachable from a START
  node; CHK-23 `:no_path_to_end`: from every node some END node is reachable)
  and the default-route rule (CHK-24 `:no_default_route`: an EXCLUSIVE_GATEWAY
  with outgoing edges needs an `is_default` edge; any other non-HUMAN_TASK kind
  must not have every outgoing edge really conditioned; HUMAN_TASK stays with
  CHK-19). Same ordering contract as its siblings: the caller runs
  `validate_graph/1` first; `validate_flow/1` neither calls it nor requires it,
  and is total on dangling edges, duplicate ids and missing START/END.
  `:variable_never_collected` is reported by
  `Letflow.Definitions.SemanticValidation`, not by this module.

  ## SUB_PROCESS interface check (CHK-18, REQ-032)

  CHK-18 (`check_sub_process_interface/1`, REQ-032) delegates to
  `Letflow.Definitions.SubProcessInterface` for the SUB_PROCESS node type's
  optional `interface` attribute — see that module's moduledoc for the full
  SPC-02 contract and the explicit SPC-01-out-of-scope statement.

  ## HUMAN_TASK form_schema x-ui logic check (CHK-20, REQ-291)

  CHK-20 (`check_form_schema_expressions/1`, REQ-291) delegates to
  `Letflow.Definitions.FormSchemaExpressions` for a HUMAN_TASK node's
  optional `form_schema` attribute's `x-ui.visible_when`/`x-ui.computed`/
  `x-ui.cross_field_validation` keys — mirroring CHK-18's own shape exactly
  (filter nodes by type, `flat_map` into the delegate). See that module's
  moduledoc for the full contract; see
  `lib/letflow/design/req291-x-ui-logic-keys.md` for the gate-approved
  design.

  ## CHK-17 grammar tightening (REQ-288)

  `check_cel_syntax/1` routes each edge's non-blank `condition` through
  `Letflow.Engine.Expr.translate_cel_to_expr/1` -> `parse_strict/1` as of
  REQ-288, **not** `valid_cel_syntax?/1`. `valid_cel_syntax?/1` remains
  public (it still carries its own REQ-029 AC4 test obligations, and no
  requirement asks for its removal) but is no longer wired into CHK-17's
  outcome — see `lib/letflow/design/req288-expr-definition-validator.md` §2.

  This is a strictly *tighter* check: `translate_cel_to_expr/1`'s
  `{:error, :unsupported_cel_feature}` / `{:error, :translate_error}` and
  `parse_strict/1`'s `{:error, parse_failure}` all produce an
  `:invalid_cel_syntax` violation (same code as before — no new
  `Violation.code()` variant), with `parse_failure`'s `line`/`column`/
  `token_text`/`message` folded into the existing `Violation.message`
  string rather than added as new struct fields, so `violation_map/1` and
  the HTTP response shape are unchanged by construction.

  **Call-site disposition (REQ-288 §3 — the central decision, stated
  individually per requirement AC6; all three reach this function
  exclusively via `validate_edge_conditions/1`, so a single change here
  applies uniformly and automatically to all three):**

  - `Letflow.Definitions.create/2` (`lib/letflow/definitions.ex:547`) —
    **strict grammar check applies.** A new definition with a
    grammar-invalid (but old-check-valid) condition is rejected at
    creation with `{:error, {:graph_validation_failed, violations}}`.
    Only ever sees new content, so no stored-data reclassification here.
  - `validate_update_graph/1` under `update/2`
    (`lib/letflow/definitions.ex:1631`) — **strict grammar check applies,
    unconditionally, whenever `attrs` carries `:graph`.** This
    RE-CLASSIFIES STORED definitions: a definition whose condition passed
    the old structural check when created but fails the grammar becomes
    un-updatable via any request that includes `:graph`, even one that
    only edits an unrelated node — there is no diff-against-stored-graph
    carve-out and no partial-apply. This is a deliberate consequence,
    not an incidental one (REQ-288 §3, point 4): authoring includes
    editing, and decision record 0020 step 8's goal is that a bad
    expression fails at authoring time, not only at evaluation time.
  - `validate_definition_graph/2` (`lib/letflow/definitions.ex:1238`, the
    read-only `POST /api/v1/definitions/:id/validate` endpoint) —
    **strict grammar check applies.** This also RE-CLASSIFIES STORED
    definitions, immediately on the next validate call. This endpoint's
    own contract requires it to agree with what `create/2`/`update/2`
    would decide on the same graph, which holds automatically here since
    all three share this one function.

  A split disposition (strict at `create/2`/the validate endpoint, lenient
  at `update/2`) was considered and rejected — see design doc §3 point 2
  for why. The diff-based "only re-check edges whose condition text
  changed" alternative was also considered and deliberately deferred as
  out of scope (design doc §3 point 3, §6 OQ-1).

  ## Semantic decision-rule validation codes (REQ-372) — NOT wired into any check here

  `:undeclared_variable_reference` and `:incompatible_comparison_operand_types`
  are added to `Violation.code()`'s closed union for
  `Letflow.Definitions.SemanticValidation.validate/2` — a `@type` edit only,
  zero logic change to this module. `SemanticValidation` is a fourth,
  independent top-level check function (alongside `validate_graph/1`,
  `validate_node_attributes/1`, `validate_edge_conditions/1`), composed
  directly by `Letflow.Definitions`, not folded into
  `validate_node_attributes/1`/`validate_edge_conditions/1` and not called
  from anywhere in this module. See
  `lib/letflow/design/req372-semantic-decision-rule-validation.md` and
  `Letflow.Definitions.SemanticValidation`'s own moduledoc for the full
  field-existence/type-compatibility contract.
  """

  alias Letflow.Engine.Expr

  @type node_type ::
          :START
          | :END
          | :HUMAN_TASK
          | :SERVICE_TASK
          | :EXCLUSIVE_GATEWAY
          | :PARALLEL_GATEWAY
          | :TIMER
          | :SUB_PROCESS

  defmodule Node do
    @moduledoc """
    PROVENANCE (historical, not current decision authority):
    A single node in a `Letflow.Definitions.Graph` (ports `graph.zig`'s
    `GraphNode`). Plain struct, not an `Ecto.Schema` — see design doc §2.1.
    """

    @enforce_keys [:id, :node_type]
    defstruct [:id, :node_type, label: nil, attributes: nil]

    @type t :: %__MODULE__{
            id: String.t(),
            node_type: Letflow.Definitions.Graph.node_type(),
            label: String.t() | nil,
            attributes: map() | nil
          }
  end

  defmodule Edge do
    @moduledoc """
    PROVENANCE (historical, not current decision authority):
    A single directed edge in a `Letflow.Definitions.Graph` (ports
    `graph.zig`'s `GraphEdge`). Plain struct, not an `Ecto.Schema` — see design
    doc §2.2. `condition`/`is_default` are carried on the struct but not read
    by any of REQ-028's 8 checks — consumed starting at REQ-029.
    """

    @enforce_keys [:id, :source, :target]
    defstruct [:id, :source, :target, condition: nil, is_default: false]

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            target: String.t(),
            condition: String.t() | nil,
            is_default: boolean()
          }
  end

  defmodule Violation do
    @moduledoc """
    PROVENANCE (historical, not current decision authority):
    One structural-validation failure returned by `validate_graph/1` (ports
    `graph.zig`'s `Violation`). `code` is a lowercase `snake_case` atom rather
    than `graph.zig`'s SCREAMING_SNAKE_CASE string — see design doc §2.3 for
    the rationale.
    """

    @enforce_keys [:code, :message]
    defstruct [:code, :message]

    @type code ::
            :missing_start_node
            | :multiple_start_nodes
            | :missing_end_node
            | :dangling_edge
            | :isolated_node
            | :duplicate_node_id
            | :cycle_without_gateway
            | :node_limit_exceeded
            | :edge_limit_exceeded
            | :missing_role
            | :missing_endpoint
            | :invalid_timeout
            | :invalid_duration
            | :missing_edge_condition
            | :unexpected_edge_condition
            | :default_with_condition
            | :multiple_default_edges
            | :invalid_cel_syntax
            | :sub_process_interface_not_object
            | :sub_process_interface_inputs_not_array
            | :sub_process_interface_outputs_not_array
            | :sub_process_interface_entry_invalid
            | :sub_process_interface_schema_invalid
            | :sub_process_interface_duplicate_name
            | :human_task_no_fallback_edge
            | :form_schema_x_ui_logic_malformed
            | :form_schema_expression_invalid
            | :form_schema_expression_out_of_scope
            | :form_schema_computed_field_cycle
            | :undeclared_variable_reference
            | :incompatible_comparison_operand_types
            | :invalid_escalation_timer
            | :missing_escalation_role
            | :missing_escalation_timer_duration
            | :unreachable_node
            | :no_path_to_end
            | :no_default_route
            | :variable_never_collected
            | :invalid_required_outputs
            | :required_outputs_on_non_human_task
            | :required_output_without_variable_schema
            | :invalid_distinct_from
            | :distinct_from_on_non_human_task
            | :distinct_from_self_reference
            | :distinct_from_unknown_node
            | :distinct_from_not_human_task
            | :distinct_from_downstream_only

    @type t :: %__MODULE__{
            code: code(),
            message: String.t()
          }
  end

  # The two NodeType variants CHK-06's gateway exemption tests membership
  # against (design doc §3).
  @gateway_types MapSet.new([:EXCLUSIVE_GATEWAY, :PARALLEL_GATEWAY])

  @max_nodes 500
  @max_edges 2000

  defstruct nodes: [], edges: []

  @type t :: %__MODULE__{
          nodes: [Node.t()],
          edges: [Edge.t()]
        }

  @type result :: %{valid: boolean(), violations: [Violation.t()]}

  @doc """
  Converts a plain map (`%{"nodes" => [...], "edges" => [...]}` — a process
  definition's stored `graph` column, or an instance snapshot's captured
  `graph`) into a `%Graph{}` struct. Moved here, as a public function, from
  `Letflow.Definitions`'s own private `graph_struct_from_map/1`
  (`lib/letflow/design/req045-instance-start-engine-shell.md` §8) so
  `Letflow.Engine.create/2` (REQ-045) can perform the identical conversion
  without reaching across a module boundary into a private function — one
  authoritative implementation, not a second private duplicate.
  `Letflow.Definitions.create/2` and `activate/2` are refactored to call this
  function instead of their own former private copy; behavior is unchanged.

  An unrecognized `"node_type"` string maps to `:unknown_node_type` rather
  than failing outright — this function's own structural validator
  (`validate_graph/1`) is what actually rejects a node of that type, not
  this conversion step. A missing/malformed `"nodes"`/`"edges"` list, or a
  node/edge missing a required string field (`"id"`, and `"node_type"` for a
  node or `"source"`/`"target"` for an edge), is `:error`.
  """
  @spec from_map(graph_map :: map()) :: {:ok, t()} | :error
  def from_map(graph_map) when is_map(graph_map) and not is_struct(graph_map) do
    with {:ok, nodes_raw} <- fetch_graph_list(graph_map, "nodes"),
         {:ok, edges_raw} <- fetch_graph_list(graph_map, "edges"),
         {:ok, nodes} <- build_graph_nodes(nodes_raw),
         {:ok, edges} <- build_graph_edges(edges_raw) do
      {:ok, %__MODULE__{nodes: nodes, edges: edges}}
    else
      _ -> :error
    end
  end

  def from_map(_not_a_map), do: :error

  @node_type_map %{
    "START" => :START,
    "END" => :END,
    "HUMAN_TASK" => :HUMAN_TASK,
    "SERVICE_TASK" => :SERVICE_TASK,
    "EXCLUSIVE_GATEWAY" => :EXCLUSIVE_GATEWAY,
    "PARALLEL_GATEWAY" => :PARALLEL_GATEWAY,
    "TIMER" => :TIMER,
    "SUB_PROCESS" => :SUB_PROCESS
  }

  defp fetch_graph_list(map, key) do
    case Map.get(map, key) do
      list when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end

  defp build_graph_nodes(nodes_raw) do
    nodes_raw
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case build_graph_node(node) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> finish_graph_build()
  end

  defp build_graph_node(%{} = node) when not is_struct(node) do
    with id when is_binary(id) <- Map.get(node, "id"),
         node_type_str when is_binary(node_type_str) <- Map.get(node, "node_type") do
      {:ok,
       %Node{
         id: id,
         node_type: Map.get(@node_type_map, node_type_str, :unknown_node_type),
         label: Map.get(node, "label"),
         attributes: Map.get(node, "attributes")
       }}
    else
      _ -> :error
    end
  end

  defp build_graph_node(_not_a_map), do: :error

  defp build_graph_edges(edges_raw) do
    edges_raw
    |> Enum.reduce_while({:ok, []}, fn edge, {:ok, acc} ->
      case build_graph_edge(edge) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> finish_graph_build()
  end

  defp build_graph_edge(%{} = edge) when not is_struct(edge) do
    with id when is_binary(id) <- Map.get(edge, "id"),
         source when is_binary(source) <- Map.get(edge, "source"),
         target when is_binary(target) <- Map.get(edge, "target") do
      {:ok,
       %Edge{
         id: id,
         source: source,
         target: target,
         condition: Map.get(edge, "condition"),
         is_default: Map.get(edge, "is_default", false)
       }}
    else
      _ -> :error
    end
  end

  defp build_graph_edge(_not_a_map), do: :error

  defp finish_graph_build({:ok, reversed_acc}), do: {:ok, Enum.reverse(reversed_acc)}
  defp finish_graph_build(:error), do: :error

  @doc """
  Runs all 8 named structural checks (CHK-01..CHK-08) against `graph` and
  returns every violation found — never short-circuits on the first failure
  (Key invariant 5; design doc §7.1). `result.valid == (result.violations == [])`
  holds by construction.
  """
  @spec validate_graph(t()) :: result()
  def validate_graph(%__MODULE__{} = graph) do
    violations =
      [
        &check_node_limit/1,
        &check_edge_limit/1,
        &check_duplicate_node_ids/1,
        &check_start_node/1,
        &check_end_node/1,
        &check_dangling_edges/1,
        &check_isolated_nodes/1,
        &check_cycles/1
      ]
      |> Enum.flat_map(& &1.(graph))

    %{valid: violations == [], violations: violations}
  end

  @doc """
  Runs the 4 per-node-type attribute checks (CHK-09..CHK-12, PD-05) plus
  CHK-18 (`check_sub_process_interface/1`, REQ-032 — SUB_PROCESS's optional
  `interface` attribute, delegated to `Letflow.Definitions.SubProcessInterface`)
  plus CHK-20 (`check_form_schema_expressions/1`, REQ-291 — HUMAN_TASK's
  optional `form_schema` attribute's `x-ui` logic keys, delegated to
  `Letflow.Definitions.FormSchemaExpressions`)
  plus CHK-21 (`check_human_task_escalation/1`, REQ-396 — HUMAN_TASK's
  optional co-required `escalation_timer_duration`/`escalation_role` pair)
  plus CHK-25 (`check_required_outputs/1`, REQ-461 — the optional
  `required_outputs` attribute is a duplicate-free list of non-empty strings,
  and only on a HUMAN_TASK)
  plus CHK-26 (`check_distinct_from/1`, REQ-464 checks 1 and 2 -- the optional
  `distinct_from` attribute's shape and the existence/type of every listed
  node) and CHK-27 (`check_distinct_from_position/1`, REQ-464 check 3 -- a
  listed node must not be reachable only after the node that lists it)
  against every node in `graph`
  and returns every violation found — never short-circuits, same
  unconditional-concatenation construction as `validate_graph/1`. Does not
  call `validate_graph/1` and does not verify structural validity as a
  precondition — see the moduledoc's "Ordering contract" note.
  """
  @spec validate_node_attributes(t()) :: result()
  def validate_node_attributes(%__MODULE__{} = graph) do
    violations =
      [
        &check_human_task_role/1,
        &check_service_task_endpoint/1,
        &check_service_task_timeout/1,
        &check_timer_duration/1,
        &check_sub_process_interface/1,
        &check_form_schema_expressions/1,
        &check_human_task_escalation/1,
        &check_required_outputs/1,
        &check_distinct_from/1,
        &check_distinct_from_position/1
      ]
      |> Enum.flat_map(& &1.(graph))

    %{valid: violations == [], violations: violations}
  end

  @doc """
  Runs the 6 edge-condition/CEL checks (CHK-13..17 and CHK-19, PD-06) against
  every edge in `graph` and returns every violation found — never
  short-circuits, same unconditional-concatenation construction as
  `validate_graph/1`. Does not call `validate_graph/1` and does not verify
  structural validity as a precondition — see the moduledoc's "Ordering
  contract" note. Total and defensive: an edge whose `source` doesn't resolve
  to any node (a dangling edge) is treated as not sourced from an
  `EXCLUSIVE_GATEWAY` or a `HUMAN_TASK` rather than raising (design doc
  §5.2, `iss-0056-human-task-fallback-edge-validation.md` §3.1).
  """
  @spec validate_edge_conditions(t()) :: result()
  def validate_edge_conditions(%__MODULE__{} = graph) do
    violations =
      [
        &check_gateway_condition_presence/1,
        &check_unpermitted_edge_condition/1,
        &check_default_condition_conflict/1,
        &check_single_default_edge/1,
        &check_cel_syntax/1,
        &check_human_task_fallback_edge/1
      ]
      |> Enum.flat_map(& &1.(graph))

    %{valid: violations == [], violations: violations}
  end

  @doc """
  Runs the 3 flow checks (CHK-22..CHK-24, REQ-455) against `graph` and returns
  every violation found -- never short-circuits, same unconditional
  concatenation as `validate_graph/1`. Pure and total: never raises on a
  dangling edge, a duplicate node id, or a graph with no START/END (those are
  CHK-01..05's to report). See the moduledoc's "Flow checks" section.
  """
  @spec validate_flow(t()) :: result()
  def validate_flow(%__MODULE__{} = graph) do
    violations =
      [
        &check_reachable_from_start/1,
        &check_reaches_end/1,
        &check_default_route/1
      ]
      |> Enum.flat_map(& &1.(graph))

    %{valid: violations == [], violations: violations}
  end

  @doc """
  Minimal *structural* CEL syntax check (design doc §6) — balanced brackets,
  balanced/terminated string literals, and no bare leading/trailing
  operator. Performs no evaluation: it never resolves variable names or
  determines what the expression would evaluate to, only whether it is
  lexically well-formed.
  """
  @spec valid_cel_syntax?(String.t()) :: boolean()
  def valid_cel_syntax?(condition) when is_binary(condition) do
    trimmed = String.trim(condition)

    cond do
      trimmed == "" -> false
      not cel_brackets_and_strings_balanced?(trimmed) -> false
      cel_starts_or_ends_with_bare_operator?(trimmed) -> false
      true -> true
    end
  end

  # CHK-07: node count must not exceed @max_nodes.
  @spec check_node_limit(t()) :: [Violation.t()]
  defp check_node_limit(%__MODULE__{nodes: nodes}) do
    count = length(nodes)

    if count > @max_nodes do
      [
        %Violation{
          code: :node_limit_exceeded,
          message: "Node count #{count} exceeds the maximum of #{@max_nodes}"
        }
      ]
    else
      []
    end
  end

  # CHK-08: edge count must not exceed @max_edges.
  @spec check_edge_limit(t()) :: [Violation.t()]
  defp check_edge_limit(%__MODULE__{edges: edges}) do
    count = length(edges)

    if count > @max_edges do
      [
        %Violation{
          code: :edge_limit_exceeded,
          message: "Edge count #{count} exceeds the maximum of #{@max_edges}"
        }
      ]
    else
      []
    end
  end

  # CHK-05: a node id equal to an earlier (lower-index) node's id is a
  # duplicate. Reported once per repeated occurrence, not once per distinct
  # id (design doc §5's CHK-05 detail).
  @spec check_duplicate_node_ids(t()) :: [Violation.t()]
  defp check_duplicate_node_ids(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, index} ->
      earlier = Enum.take(nodes, index)

      if Enum.any?(earlier, &(&1.id == node.id)) do
        [%Violation{code: :duplicate_node_id, message: "Duplicate node ID '#{node.id}'"}]
      else
        []
      end
    end)
  end

  # CHK-01: exactly one START node is required.
  @spec check_start_node(t()) :: [Violation.t()]
  defp check_start_node(%__MODULE__{nodes: nodes}) do
    count = Enum.count(nodes, &(&1.node_type == :START))

    cond do
      count == 0 ->
        [
          %Violation{
            code: :missing_start_node,
            message: "No START node found in the definition graph"
          }
        ]

      count > 1 ->
        [
          %Violation{
            code: :multiple_start_nodes,
            message: "Found #{count} START nodes; exactly one is required"
          }
        ]

      true ->
        []
    end
  end

  # CHK-02: at least one END node is required.
  @spec check_end_node(t()) :: [Violation.t()]
  defp check_end_node(%__MODULE__{nodes: nodes}) do
    if Enum.any?(nodes, &(&1.node_type == :END)) do
      []
    else
      [%Violation{code: :missing_end_node, message: "No END node found in the definition graph"}]
    end
  end

  # CHK-03: an edge whose source or target references a nonexistent node id.
  # Both endpoints of one edge are checked independently — a doubly-dangling
  # edge produces two violations, not one (design doc §5's CHK-03 detail).
  @spec check_dangling_edges(t()) :: [Violation.t()]
  defp check_dangling_edges(%__MODULE__{nodes: nodes, edges: edges}) do
    node_ids = MapSet.new(nodes, & &1.id)

    Enum.flat_map(edges, fn edge ->
      source_violation =
        if MapSet.member?(node_ids, edge.source) do
          []
        else
          [
            %Violation{
              code: :dangling_edge,
              message:
                "Edge '#{edge.id}' has dangling source reference: node '#{edge.source}' does not exist"
            }
          ]
        end

      target_violation =
        if MapSet.member?(node_ids, edge.target) do
          []
        else
          [
            %Violation{
              code: :dangling_edge,
              message:
                "Edge '#{edge.id}' has dangling target reference: node '#{edge.target}' does not exist"
            }
          ]
        end

      source_violation ++ target_violation
    end)
  end

  # CHK-04: a node with insufficient incoming/outgoing edges for its type.
  # START only needs an outgoing edge, END only needs an incoming edge, every
  # other type needs both (design doc §5's CHK-04 detail). Connectivity is
  # computed only from edges whose source AND target both resolve to a real
  # node id via `build_node_index/1`'s first-occurrence-wins lookup — a
  # dangling edge (CHK-03's concern) contributes no connectivity to either
  # side.
  @spec check_isolated_nodes(t()) :: [Violation.t()]
  defp check_isolated_nodes(%__MODULE__{nodes: nodes, edges: edges}) do
    node_index = build_node_index(nodes)

    {outgoing, incoming} =
      Enum.reduce(edges, {MapSet.new(), MapSet.new()}, fn edge, {outgoing, incoming} ->
        with {:ok, source_idx} <- Map.fetch(node_index, edge.source),
             {:ok, target_idx} <- Map.fetch(node_index, edge.target) do
          {MapSet.put(outgoing, source_idx), MapSet.put(incoming, target_idx)}
        else
          :error -> {outgoing, incoming}
        end
      end)

    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, index} ->
      has_outgoing = MapSet.member?(outgoing, index)
      has_incoming = MapSet.member?(incoming, index)

      isolated? =
        case node.node_type do
          :START -> not has_outgoing
          :END -> not has_incoming
          _other -> not has_outgoing or not has_incoming
        end

      if isolated? do
        [
          %Violation{
            code: :isolated_node,
            message:
              "Node '#{node.id}' is isolated (insufficient incoming or outgoing edges for its type)"
          }
        ]
      else
        []
      end
    end)
  end

  # CHK-22: every node must be reachable from a START node (forward walk over
  # resolved edges). One violation per unreached node id, node-list order,
  # duplicate ids collapsed to the first occurrence. Zero START nodes: [] (CHK-01
  # owns that report).
  @spec check_reachable_from_start(t()) :: [Violation.t()]
  defp check_reachable_from_start(%__MODULE__{nodes: nodes, edges: edges}) do
    sources = for node <- nodes, node.node_type == :START, do: node.id

    if sources == [] do
      []
    else
      reached = walk(sources, flow_adjacency(nodes, edges, :forward))

      nodes
      |> unique_nodes()
      |> Enum.reject(&MapSet.member?(reached, &1.id))
      |> Enum.map(fn node ->
        %Violation{
          code: :unreachable_node,
          message: "Node '#{node.id}' (#{node.node_type}) is not reachable from any START node"
        }
      end)
    end
  end

  # CHK-23: from every node some END node must be reachable (reverse walk over
  # resolved edges). Zero END nodes: [] (CHK-02 owns that report).
  @spec check_reaches_end(t()) :: [Violation.t()]
  defp check_reaches_end(%__MODULE__{nodes: nodes, edges: edges}) do
    sources = for node <- nodes, node.node_type == :END, do: node.id

    if sources == [] do
      []
    else
      reaching = walk(sources, flow_adjacency(nodes, edges, :reverse))

      nodes
      |> unique_nodes()
      |> Enum.reject(&MapSet.member?(reaching, &1.id))
      |> Enum.map(fn node ->
        %Violation{
          code: :no_path_to_end,
          message: "Node '#{node.id}' (#{node.node_type}) has no path to any END node"
        }
      end)
    end
  end

  # CHK-24: default-route rule, one violation per offending node. An
  # EXCLUSIVE_GATEWAY with outgoing edges needs an `is_default == true` edge
  # (mirrors the engine's dispatch partition). HUMAN_TASK is CHK-19's. Any other
  # kind is flagged iff every outgoing edge is really conditioned (compared
  # without trim, as the engine and CHK-19 do).
  @spec check_default_route(t()) :: [Violation.t()]
  defp check_default_route(%__MODULE__{nodes: nodes, edges: edges}) do
    nodes
    |> unique_nodes()
    |> Enum.filter(fn node ->
      outgoing = Enum.filter(edges, &(&1.source == node.id))

      cond do
        outgoing == [] -> false
        node.node_type == :HUMAN_TASK -> false
        node.node_type == :EXCLUSIVE_GATEWAY -> not Enum.any?(outgoing, &(&1.is_default == true))
        true -> Enum.all?(outgoing, &human_task_edge_really_conditioned?/1)
      end
    end)
    |> Enum.map(fn node ->
      %Violation{
        code: :no_default_route,
        message:
          "Node '#{node.id}' (#{node.node_type}) has no default outgoing edge (is_default: true); " <>
            "an instance whose conditions all evaluate false would stop with no matching route"
      }
    end)
  end

  # First occurrence of each node id, node-list order.
  @spec unique_nodes([Node.t()]) :: [Node.t()]
  defp unique_nodes(nodes), do: Enum.uniq_by(nodes, & &1.id)

  # id -> [neighbour ids] over edges whose both endpoints resolve to a node id.
  # :forward follows source -> target, :reverse follows target -> source.
  @spec flow_adjacency([Node.t()], [Edge.t()], :forward | :reverse) :: %{
          String.t() => [String.t()]
        }
  defp flow_adjacency(nodes, edges, direction) do
    ids = MapSet.new(nodes, & &1.id)

    edges
    |> Enum.filter(&(MapSet.member?(ids, &1.source) and MapSet.member?(ids, &1.target)))
    |> Enum.reduce(%{}, fn edge, acc ->
      {from, to} =
        if direction == :forward,
          do: {edge.source, edge.target},
          else: {edge.target, edge.source}

      Map.update(acc, from, [to], &[to | &1])
    end)
  end

  # Closure of `sources` (included) over `adjacency`.
  @spec walk([String.t()], %{String.t() => [String.t()]}) :: MapSet.t(String.t())
  defp walk(sources, adjacency), do: do_walk(sources, adjacency, MapSet.new())

  defp do_walk([], _adjacency, seen), do: seen

  defp do_walk([id | rest], adjacency, seen) do
    if MapSet.member?(seen, id) do
      do_walk(rest, adjacency, seen)
    else
      do_walk(Map.get(adjacency, id, []) ++ rest, adjacency, MapSet.put(seen, id))
    end
  end

  # CHK-06: DFS-based cycle detection. A cycle is permitted iff at least one
  # endpoint of the closing back-edge is a gateway node; otherwise it's a
  # violation. Every node index is visited (not just those reachable from
  # START), so a cycle in a disconnected island is still caught (design doc
  # §6.2).
  @spec check_cycles(t()) :: [Violation.t()]
  defp check_cycles(%__MODULE__{nodes: nodes, edges: edges}) do
    node_index = build_node_index(nodes)
    adjacency = build_adjacency(edges, node_index)
    gateway_set = build_gateway_set(nodes)

    last_index = length(nodes) - 1

    {_visited, violations} =
      Enum.reduce(0..last_index//1, {MapSet.new(), []}, fn i, {visited, violations} ->
        if MapSet.member?(visited, i) do
          {visited, violations}
        else
          {new_visited, new_violations} =
            dfs_visit(i, adjacency, gateway_set, nodes, visited, MapSet.new())

          {new_visited, violations ++ new_violations}
        end
      end)

    violations
  end

  # PROVENANCE (historical, not current decision authority):
  # id -> first-occurrence 0-based index. On a repeated id, the first
  # occurrence wins and later occurrences are silently ignored here (matching
  # `graph.zig`'s `nodeIndex`'s linear-scan-returns-first-match behavior;
  # design doc §6.1 point 1). CHK-05 independently and unconditionally flags
  # the duplicate id itself, so this is never the only signal a caller sees.
  @spec build_node_index([Node.t()]) :: %{String.t() => non_neg_integer()}
  defp build_node_index(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {node, index}, acc -> Map.put_new(acc, node.id, index) end)
  end

  # node index -> list of successor node indices, in edge-declaration order.
  # An edge where either endpoint fails to resolve via `node_index` (a
  # dangling edge) is excluded — it contributes no adjacency (design doc
  # §6.1 point 2). A self-loop (`source == target`) resolves to `u -> u` and
  # is included, not special-cased.
  @spec build_adjacency([Edge.t()], %{String.t() => non_neg_integer()}) ::
          %{non_neg_integer() => [non_neg_integer()]}
  defp build_adjacency(edges, node_index) do
    edges
    |> Enum.reduce(%{}, fn edge, acc ->
      with {:ok, source_idx} <- Map.fetch(node_index, edge.source),
           {:ok, target_idx} <- Map.fetch(node_index, edge.target) do
        Map.update(acc, source_idx, [target_idx], &[target_idx | &1])
      else
        :error -> acc
      end
    end)
    |> Map.new(fn {idx, targets} -> {idx, Enum.reverse(targets)} end)
  end

  # Every node's own list-position index whose node_type is a gateway type
  # (design doc §6.1 point 3) -- built from raw list position, not
  # `node_index`, since CHK-06's outer driver visits every position
  # 0..(length(nodes) - 1) directly (§6.2).
  @spec build_gateway_set([Node.t()]) :: MapSet.t(non_neg_integer())
  defp build_gateway_set(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.filter(fn {node, _index} -> node.node_type in @gateway_types end)
    |> Enum.map(fn {_node, index} -> index end)
    |> MapSet.new()
  end

  # One DFS call rooted at `u`. Returns `{visited, violations}` — `on_stack`
  # never propagates back to the caller: by the time this call returns, every
  # one of `u`'s outgoing edges has been processed and `u`'s presence on the
  # current root-to-leaf path is logically over (design doc §6.3 point 3).
  @spec dfs_visit(
          non_neg_integer(),
          %{non_neg_integer() => [non_neg_integer()]},
          MapSet.t(non_neg_integer()),
          [Node.t()],
          MapSet.t(non_neg_integer()),
          MapSet.t(non_neg_integer())
        ) :: {MapSet.t(non_neg_integer()), [Violation.t()]}
  defp dfs_visit(u, adjacency, gateway_set, nodes, visited, on_stack) do
    visited = MapSet.put(visited, u)
    on_stack = MapSet.put(on_stack, u)
    successors = Map.get(adjacency, u, [])

    Enum.reduce(successors, {visited, []}, fn v, {visited, violations} ->
      cond do
        MapSet.member?(on_stack, v) ->
          # Back-edge: v is an ancestor of u on the current path (or v == u,
          # the self-loop case). Permitted iff either endpoint is a gateway
          # node (design doc §6.3 step 2, §6.4).
          if MapSet.member?(gateway_set, u) or MapSet.member?(gateway_set, v) do
            {visited, violations}
          else
            u_id = Enum.at(nodes, u).id
            v_id = Enum.at(nodes, v).id

            violation = %Violation{
              code: :cycle_without_gateway,
              message:
                "Cycle detected: edge from node '#{u_id}' to node '#{v_id}' creates a cycle not passing through a gateway node"
            }

            {visited, violations ++ [violation]}
          end

        MapSet.member?(visited, v) ->
          # Cross/forward edge -- v already fully explored via another path,
          # not an ancestor relationship. Not a cycle.
          {visited, violations}

        true ->
          {new_visited, new_violations} =
            dfs_visit(v, adjacency, gateway_set, nodes, visited, on_stack)

          {new_visited, violations ++ new_violations}
      end
    end)
  end

  # --- CHK-09..CHK-12: per-node-type attribute checks (PD-05, REQ-029) ------

  # CHK-09: a HUMAN_TASK node must carry a non-empty (after trim) "role"
  # string attribute (design doc §4, §4.1).
  @spec check_human_task_role(t()) :: [Violation.t()]
  defp check_human_task_role(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :HUMAN_TASK))
    |> Enum.filter(&blank_or_missing_string?(&1.attributes, "role"))
    |> Enum.map(fn node ->
      %Violation{
        code: :missing_role,
        message: "Node '#{node.id}' (HUMAN_TASK) is missing a non-empty 'role' attribute"
      }
    end)
  end

  # CHK-10: a SERVICE_TASK node must carry a non-empty (after trim)
  # "endpoint" string attribute, UNLESS a non-empty (after trim) "service_id"
  # attribute is present instead -- mirrors
  # Letflow.Engine.ServiceTask.parse_config_from_node_attributes/1's own
  # {nil, nil} -> :missing_url_and_service_id condition (design doc §4, §4.1;
  # ISS-0104/GH#334).
  @spec check_service_task_endpoint(t()) :: [Violation.t()]
  defp check_service_task_endpoint(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :SERVICE_TASK))
    |> Enum.filter(&blank_or_missing_string?(&1.attributes, "endpoint"))
    |> Enum.filter(&blank_or_missing_string?(&1.attributes, "service_id"))
    |> Enum.map(fn node ->
      %Violation{
        code: :missing_endpoint,
        message:
          "Node '#{node.id}' (SERVICE_TASK) is missing a non-empty 'endpoint' attribute " <>
            "(and no non-empty 'service_id' attribute is present as an alternative)"
      }
    end)
  end

  # CHK-11: a SERVICE_TASK node's "timeout_ms" attribute must be an integer
  # (no numeric-string/float coercion, design doc §2's pinned value-type
  # table) in the inclusive range 1..300_000 (design doc §4.2).
  @spec check_service_task_timeout(t()) :: [Violation.t()]
  defp check_service_task_timeout(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :SERVICE_TASK))
    |> Enum.filter(&invalid_timeout?(&1.attributes))
    |> Enum.map(fn node ->
      value = attribute_value(node.attributes, "timeout_ms")

      %Violation{
        code: :invalid_timeout,
        message:
          "Node '#{node.id}' (SERVICE_TASK) has an invalid 'timeout_ms' attribute " <>
            "(#{inspect(value)}); must be an integer in 1..300000"
      }
    end)
  end

  # CHK-12: a TIMER node's "duration_iso8601" attribute must be a string
  # accepted by the ISO-8601 duration scan-forward parser (design doc §4.3).
  @spec check_timer_duration(t()) :: [Violation.t()]
  defp check_timer_duration(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :TIMER))
    |> Enum.filter(&invalid_duration?(&1.attributes))
    |> Enum.map(fn node ->
      value = attribute_value(node.attributes, "duration_iso8601")

      %Violation{
        code: :invalid_duration,
        message:
          "Node '#{node.id}' (TIMER) has an invalid 'duration_iso8601' attribute (#{inspect(value)})"
      }
    end)
  end

  # CHK-18: a SUB_PROCESS node's optional "interface" attribute, if present,
  # must be a well-formed interface contract (inputs/outputs entry lists,
  # each entry a well-formed {name, json_schema, required} tuple with a
  # well-formed json_schema) -- delegated entirely to
  # `Letflow.Definitions.SubProcessInterface.validate_node_interface/2`
  # (REQ-032 design doc §4). One check function producing up to 6 distinct
  # codes, not 6 separate one-code-per-check functions -- a deliberate
  # divergence from CHK-09..17's "one check, one code" convention, since the
  # 6 codes form a dependency chain within a single parse (design doc §4).
  # No-op on a node of any other type.
  @spec check_sub_process_interface(t()) :: [Violation.t()]
  defp check_sub_process_interface(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :SUB_PROCESS))
    |> Enum.flat_map(fn node ->
      Letflow.Definitions.SubProcessInterface.validate_node_interface(node.id, node.attributes)
    end)
  end

  # CHK-20: a HUMAN_TASK node's optional "form_schema" attribute's
  # x-ui.visible_when/x-ui.computed/x-ui.cross_field_validation keys, if
  # present, must be well-formed, in-scope Letflow.Engine.Expr expressions
  # with no computed-field reference cycle -- delegated entirely to
  # Letflow.Definitions.FormSchemaExpressions (REQ-291). Filtered to
  # HUMAN_TASK nodes only, the only node type
  # Letflow.Engine.TaskActivation ever resolves a form_schema for. No-op on
  # a node of any other type, an absent form_schema, or a form_schema that
  # fails JsonSchemaShape.check/1 (that failure is reported at activation
  # time instead, per REQ-273).
  @spec check_form_schema_expressions(t()) :: [Violation.t()]
  defp check_form_schema_expressions(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :HUMAN_TASK))
    |> Enum.flat_map(fn node ->
      Letflow.Definitions.FormSchemaExpressions.validate_node_form_schema(
        node.id,
        node.attributes
      )
    end)
  end

  # CHK-21: a HUMAN_TASK node's optional escalation attributes are
  # co-required — both escalation_timer_duration and escalation_role must
  # be present or both absent. When present, escalation_timer_duration must
  # be a valid ISO-8601 duration string (same parser as CHK-12). "P0D" is
  # accepted, consistent with CHK-12's own treatment of that edge case
  # (OQ-1 in req396 design doc).
  @spec check_human_task_escalation(t()) :: [Violation.t()]
  defp check_human_task_escalation(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :HUMAN_TASK))
    |> Enum.flat_map(&human_task_escalation_violations(&1, &1.attributes || %{}))
  end

  # `attributes` is documented as `map() | nil` with string keys, but a node
  # built from the wire-contract shape (`attributes: string | null`, e.g. a
  # JSON-encoded string) can reach here un-decoded -- the `is_map/1` guard is
  # a defensive belt-and-suspenders check so this helper stays total (never
  # raises) even when handed something other than a map. A non-map value is
  # treated as "escalation attributes absent," the same disposition as the
  # `cond`'s own `true -> []` branch below for a map with neither field set.
  @spec human_task_escalation_violations(Node.t(), map() | nil | term()) :: [Violation.t()]
  defp human_task_escalation_violations(node, attrs) when is_map(attrs) do
    raw_duration = Map.get(attrs, "escalation_timer_duration")
    raw_role = Map.get(attrs, "escalation_role")
    has_duration = not is_nil(raw_duration)
    has_role = not is_nil(raw_role) and is_binary(raw_role) and String.trim(raw_role) != ""

    cond do
      has_duration and is_binary(raw_duration) and not valid_iso8601_duration?(raw_duration) ->
        [
          %Violation{
            code: :invalid_escalation_timer,
            message:
              "Node '#{node.id}' (HUMAN_TASK) has an invalid 'escalation_timer_duration' attribute (#{inspect(raw_duration)}); must be a valid ISO-8601 duration string"
          }
        ]

      has_duration and not has_role ->
        [
          %Violation{
            code: :missing_escalation_role,
            message:
              "Node '#{node.id}' (HUMAN_TASK) has 'escalation_timer_duration' but is missing a non-empty 'escalation_role' attribute"
          }
        ]

      not has_duration and not is_nil(raw_role) ->
        [
          %Violation{
            code: :missing_escalation_timer_duration,
            message:
              "Node '#{node.id}' (HUMAN_TASK) has 'escalation_role' but is missing 'escalation_timer_duration'"
          }
        ]

      true ->
        []
    end
  end

  defp human_task_escalation_violations(_node, _attrs), do: []

  # CHK-25 (REQ-461 check 1, REQ-459 design section 1.2): the optional
  # "required_outputs" attribute is a list of non-empty strings without
  # duplicates, and is only legal on a HUMAN_TASK. One violation per defect;
  # a `null` value is treated as absent (same as CHK-21). Shape only -- that
  # each key has a variable_schema is SemanticValidation's check 2.
  @spec check_required_outputs(t()) :: [Violation.t()]
  defp check_required_outputs(%__MODULE__{nodes: nodes}) do
    Enum.flat_map(nodes, fn node ->
      raw = if is_map(node.attributes), do: Map.get(node.attributes, "required_outputs")
      required_outputs_violations(node, raw)
    end)
  end

  @spec required_outputs_violations(Node.t(), term()) :: [Violation.t()]
  defp required_outputs_violations(_node, nil), do: []

  defp required_outputs_violations(%Node{node_type: :HUMAN_TASK} = node, raw)
       when is_list(raw) do
    entry_violations =
      raw
      |> Enum.reject(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.map(fn entry ->
        %Violation{
          code: :invalid_required_outputs,
          message:
            "Node '#{node.id}' (HUMAN_TASK) has an invalid 'required_outputs' entry (#{inspect(entry)}); every entry must be a non-empty string"
        }
      end)

    duplicate_violations =
      raw
      |> Enum.filter(&is_binary/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> Enum.map(fn key ->
        %Violation{
          code: :invalid_required_outputs,
          message:
            "Node '#{node.id}' (HUMAN_TASK) lists duplicate 'required_outputs' key '#{key}'"
        }
      end)

    entry_violations ++ duplicate_violations
  end

  defp required_outputs_violations(%Node{node_type: :HUMAN_TASK} = node, raw) do
    [
      %Violation{
        code: :invalid_required_outputs,
        message:
          "Node '#{node.id}' (HUMAN_TASK) has an invalid 'required_outputs' attribute (#{inspect(raw)}); must be a list of non-empty strings"
      }
    ]
  end

  defp required_outputs_violations(%Node{} = node, _raw) do
    [
      %Violation{
        code: :required_outputs_on_non_human_task,
        message:
          "Node '#{node.id}' (#{node.node_type}) has a 'required_outputs' attribute; it is only allowed on a HUMAN_TASK"
      }
    ]
  end

  # CHK-26 (REQ-464 checks 1 and 2, REQ-459 design section 1.2): the optional
  # "distinct_from" attribute. A `null` value is treated as absent (same as
  # CHK-25). On a non-HUMAN_TASK node the key is a violation; on a HUMAN_TASK
  # it must be a list of non-empty strings, no duplicates, never the node's own
  # id, and every entry must name a HUMAN_TASK node of this definition. One
  # violation per defect; an entry flagged for shape/self is not also checked
  # for existence.
  @spec check_distinct_from(t()) :: [Violation.t()]
  defp check_distinct_from(%__MODULE__{nodes: nodes}) do
    by_id = nodes |> unique_nodes() |> Map.new(&{&1.id, &1})

    Enum.flat_map(nodes, fn node ->
      raw = if is_map(node.attributes), do: Map.get(node.attributes, "distinct_from")
      distinct_from_violations(node, raw, by_id)
    end)
  end

  @spec distinct_from_violations(Node.t(), term(), %{String.t() => Node.t()}) :: [Violation.t()]
  defp distinct_from_violations(_node, nil, _by_id), do: []

  defp distinct_from_violations(%Node{node_type: :HUMAN_TASK} = node, raw, by_id)
       when is_list(raw) do
    entry_violations =
      raw
      |> Enum.reject(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.map(fn entry ->
        %Violation{
          code: :invalid_distinct_from,
          message:
            "Node '#{node.id}' (HUMAN_TASK) has an invalid 'distinct_from' entry (#{inspect(entry)}); every entry must be a non-empty string"
        }
      end)

    duplicate_violations =
      raw
      |> Enum.filter(&is_binary/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> Enum.map(fn id ->
        %Violation{
          code: :invalid_distinct_from,
          message: "Node '#{node.id}' (HUMAN_TASK) lists duplicate 'distinct_from' id '#{id}'"
        }
      end)

    listed_violations =
      raw
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()
      |> Enum.flat_map(&distinct_from_target_violations(node, &1, by_id))

    entry_violations ++ duplicate_violations ++ listed_violations
  end

  defp distinct_from_violations(%Node{node_type: :HUMAN_TASK} = node, raw, _by_id) do
    [
      %Violation{
        code: :invalid_distinct_from,
        message:
          "Node '#{node.id}' (HUMAN_TASK) has an invalid 'distinct_from' attribute (#{inspect(raw)}); must be a list of node ids"
      }
    ]
  end

  defp distinct_from_violations(%Node{} = node, _raw, _by_id) do
    [
      %Violation{
        code: :distinct_from_on_non_human_task,
        message:
          "Node '#{node.id}' (#{node.node_type}) has a 'distinct_from' attribute; it is only allowed on a HUMAN_TASK"
      }
    ]
  end

  @spec distinct_from_target_violations(Node.t(), String.t(), %{String.t() => Node.t()}) ::
          [Violation.t()]
  defp distinct_from_target_violations(%Node{id: id}, id, _by_id) do
    [
      %Violation{
        code: :distinct_from_self_reference,
        message: "Node '#{id}' (HUMAN_TASK) lists itself in distinct_from"
      }
    ]
  end

  defp distinct_from_target_violations(node, other, by_id) do
    case Map.fetch(by_id, other) do
      :error ->
        [
          %Violation{
            code: :distinct_from_unknown_node,
            message:
              "Node '#{node.id}' (HUMAN_TASK) lists '#{other}' in distinct_from, but no node '#{other}' exists in this definition"
          }
        ]

      {:ok, %Node{node_type: :HUMAN_TASK}} ->
        []

      {:ok, %Node{node_type: type}} ->
        [
          %Violation{
            code: :distinct_from_not_human_task,
            message:
              "Node '#{node.id}' (HUMAN_TASK) lists '#{other}' in distinct_from, but '#{other}' is a #{type}, not a HUMAN_TASK"
          }
        ]
    end
  end

  # CHK-27 (REQ-464 check 3, REQ-459 design section 1.5 relation table): a
  # listed node L must not be reachable only AFTER the listing node N (path
  # N -> L and no path L -> N). L before N, a rework loop (both ways) and
  # parallel / mutually exclusive branches (neither way) pass. Only well-formed
  # entries that name an existing HUMAN_TASK other than N are examined (the
  # rest are CHK-26's); a node unreachable from START has no path either way
  # and passes (CHK-22 reports it). Reachability is the forward closure over
  # resolved edges (`flow_adjacency/3` + `walk/2`, as CHK-22), computed once per
  # listing node and per distinct listed node.
  @spec check_distinct_from_position(t()) :: [Violation.t()]
  defp check_distinct_from_position(%__MODULE__{nodes: nodes, edges: edges}) do
    by_id = nodes |> unique_nodes() |> Map.new(&{&1.id, &1})

    listings =
      for node <- unique_nodes(nodes),
          node.node_type == :HUMAN_TASK,
          is_map(node.attributes),
          is_list(raw = Map.get(node.attributes, "distinct_from")),
          other <- raw |> Enum.filter(&is_binary/1) |> Enum.uniq(),
          other != node.id,
          match?(%Node{node_type: :HUMAN_TASK}, Map.get(by_id, other)),
          do: {node.id, other}

    if listings == [] do
      []
    else
      adjacency = flow_adjacency(nodes, edges, :forward)

      reach =
        listings
        |> Enum.flat_map(&Tuple.to_list/1)
        |> Enum.uniq()
        |> Map.new(&{&1, walk([&1], adjacency)})

      for {id, other} <- listings,
          MapSet.member?(reach[id], other),
          not MapSet.member?(reach[other], id) do
        %Violation{
          code: :distinct_from_downstream_only,
          message:
            "Node '#{id}' (HUMAN_TASK) lists '#{other}' in distinct_from, but '#{other}' is reachable only after '#{id}'"
        }
      end
    end
  end

  # `attributes` is documented as `map() | nil` with string keys (design doc
  # §2) -- the `is_map/1` guard is a defensive belt-and-suspenders check so
  # these helpers stay total (never raise) even if a caller ever hands in
  # something else, rather than relying solely on the documented contract.
  @spec blank_or_missing_string?(map() | nil, String.t()) :: boolean()
  defp blank_or_missing_string?(attributes, key) when is_map(attributes) do
    case Map.get(attributes, key) do
      value when is_binary(value) -> String.trim(value) == ""
      _other -> true
    end
  end

  defp blank_or_missing_string?(_attributes, _key), do: true

  @spec invalid_timeout?(map() | nil) :: boolean()
  defp invalid_timeout?(attributes) when is_map(attributes) do
    case Map.get(attributes, "timeout_ms") do
      value when is_integer(value) -> value < 1 or value > 300_000
      _other -> true
    end
  end

  defp invalid_timeout?(_attributes), do: true

  @spec invalid_duration?(map() | nil) :: boolean()
  defp invalid_duration?(attributes) when is_map(attributes) do
    case Map.get(attributes, "duration_iso8601") do
      value when is_binary(value) -> not valid_iso8601_duration?(value)
      _other -> true
    end
  end

  defp invalid_duration?(_attributes), do: true

  @spec attribute_value(map() | nil, String.t()) :: term()
  defp attribute_value(attributes, key) when is_map(attributes), do: Map.get(attributes, key)
  defp attribute_value(_attributes, _key), do: nil

  # --- ISO-8601 duration scan-forward parser (design doc §4.3) --------------

  @duration_date_units ["Y", "M", "W", "D"]
  @duration_time_units ["H", "M", "S"]

  # A duration string is valid iff: it contains no fractional ('.'/',')
  # character anywhere; it starts with literal 'P'; the remainder splits on
  # the first 'T' (if any) into a date_part and, only if 'T' was present, a
  # non-empty time_part; date_part scans as zero-or-more ordered
  # <digits><unit> tokens from Y,M,W,D with no leftover characters;
  # time_part (if 'T' was present) scans the same way against H,M,S and must
  # contain at least one token; if no 'T' was present, date_part itself must
  # contain at least one token. `P0D` is explicitly valid (design doc §4.3).
  @spec valid_iso8601_duration?(String.t()) :: boolean()
  defp valid_iso8601_duration?(str) do
    cond do
      String.contains?(str, ".") or String.contains?(str, ",") ->
        false

      not String.starts_with?(str, "P") ->
        false

      true ->
        str
        |> String.slice(1, String.length(str) - 1)
        |> valid_duration_remainder?()
    end
  end

  @spec valid_duration_remainder?(String.t()) :: boolean()
  defp valid_duration_remainder?(remainder) do
    case String.split(remainder, "T", parts: 2) do
      [date_part] ->
        case scan_duration_tokens(date_part, @duration_date_units) do
          :error -> false
          count -> count > 0
        end

      [date_part, time_part] ->
        time_part != "" and valid_duration_date_and_time?(date_part, time_part)
    end
  end

  @spec valid_duration_date_and_time?(String.t(), String.t()) :: boolean()
  defp valid_duration_date_and_time?(date_part, time_part) do
    date_ok? =
      case scan_duration_tokens(date_part, @duration_date_units) do
        :error -> false
        _count -> true
      end

    time_ok? =
      case scan_duration_tokens(time_part, @duration_time_units) do
        :error -> false
        count -> count > 0
      end

    date_ok? and time_ok?
  end

  # --- REQ-187 design doc §2 -- parse_iso8601_duration/1 --------------------

  # Fixed-length calendar approximation (flagged assumption, REQ-187 design
  # doc §2): no real calendar-month/leap-year arithmetic -- Y=365d,
  # M(date part)=30d, W=7d, D=1d, H=3600s, M(time part)=60s, S=1s. Blast
  # radius of getting this wrong is contained entirely to this one function
  # (its @spec and every call site stay identical either way).
  @duration_date_unit_seconds %{
    "Y" => 365 * 86_400,
    "M" => 30 * 86_400,
    "W" => 7 * 86_400,
    "D" => 86_400
  }
  @duration_time_unit_seconds %{"H" => 3600, "M" => 60, "S" => 1}

  @doc """
  Converts a valid ISO-8601 duration string (as already validated by
  `valid_iso8601_duration?/1`'s own grammar, CHK-12) into a total number of
  seconds, using the fixed-length calendar convention documented above.
  Pure -- no clock, no I/O. Returns `:error` for any string
  `valid_iso8601_duration?/1` itself would reject (defensive-only: CHK-12
  already rejects an invalid `duration_iso8601` at definition-approval time,
  so a `:TIMER` node reaching this function with one should be
  unreachable). Only ever called by `Letflow.Engine` (the impure caller),
  never by `Letflow.Engine.Transition` (design doc §2).
  """
  @spec parse_iso8601_duration(String.t()) :: {:ok, seconds :: non_neg_integer()} | :error
  def parse_iso8601_duration(str) when is_binary(str) do
    if valid_iso8601_duration?(str) do
      remainder = String.slice(str, 1, String.length(str) - 1)

      case String.split(remainder, "T", parts: 2) do
        [date_part] ->
          date_part
          |> scan_duration_seconds(@duration_date_units, @duration_date_unit_seconds)
          |> wrap_seconds()

        [date_part, time_part] ->
          with {:ok, date_seconds} <-
                 date_part
                 |> scan_duration_seconds(@duration_date_units, @duration_date_unit_seconds)
                 |> wrap_seconds(),
               {:ok, time_seconds} <-
                 time_part
                 |> scan_duration_seconds(@duration_time_units, @duration_time_unit_seconds)
                 |> wrap_seconds() do
            {:ok, date_seconds + time_seconds}
          end
      end
    else
      :error
    end
  end

  def parse_iso8601_duration(_str), do: :error

  @spec wrap_seconds(non_neg_integer() | :error) :: {:ok, non_neg_integer()} | :error
  defp wrap_seconds(:error), do: :error
  defp wrap_seconds(seconds) when is_integer(seconds), do: {:ok, seconds}

  # Same scan-forward shape as scan_duration_tokens/3 below, accumulating
  # seconds (via unit_seconds) instead of a bare token count -- kept as a
  # parallel pass over the same already-validated grammar rather than
  # threading a second accumulator through scan_duration_tokens/3 itself,
  # so that function's own @spec (a bare token count for validation) stays
  # unchanged for its one existing caller, valid_duration_remainder?/1.
  @spec scan_duration_seconds(String.t(), [String.t()], %{String.t() => non_neg_integer()}) ::
          non_neg_integer() | :error
  defp scan_duration_seconds(str, remaining_units, unit_seconds),
    do: scan_duration_seconds(str, remaining_units, unit_seconds, 0)

  @spec scan_duration_seconds(
          String.t(),
          [String.t()],
          %{String.t() => non_neg_integer()},
          non_neg_integer()
        ) :: non_neg_integer() | :error
  defp scan_duration_seconds("", _remaining_units, _unit_seconds, acc), do: acc

  defp scan_duration_seconds(str, remaining_units, unit_seconds, acc) do
    case Regex.run(~r/^([0-9]+)([A-Za-z])/, str) do
      [match, digits, unit] ->
        case Enum.split_while(remaining_units, &(&1 != unit)) do
          {_before, [^unit | rest_units]} ->
            rest_str =
              String.slice(str, String.length(match), String.length(str) - String.length(match))

            seconds = String.to_integer(digits) * Map.fetch!(unit_seconds, unit)
            scan_duration_seconds(rest_str, rest_units, unit_seconds, acc + seconds)

          {_before, []} ->
            :error
        end

      nil ->
        :error
    end
  end

  # Scans `str` left to right for zero or more <digits><unit> tokens against
  # `remaining_units` (an ordered list of single-character unit strings, e.g.
  # `["Y", "M", "W", "D"]`), where units present must appear in that relative
  # order with no repeats and any not present are simply skipped (they're
  # optional). Returns the number of tokens matched once `str` is fully
  # consumed, or `:error` if `str` contains any leftover/unrecognized
  # characters, an out-of-order unit, or a repeated unit.
  @spec scan_duration_tokens(String.t(), [String.t()]) :: non_neg_integer() | :error
  defp scan_duration_tokens(str, remaining_units),
    do: scan_duration_tokens(str, remaining_units, 0)

  @spec scan_duration_tokens(String.t(), [String.t()], non_neg_integer()) ::
          non_neg_integer() | :error
  defp scan_duration_tokens("", _remaining_units, count), do: count

  defp scan_duration_tokens(str, remaining_units, count) do
    case Regex.run(~r/^([0-9]+)([A-Za-z])/, str) do
      [match, _digits, unit] ->
        case Enum.split_while(remaining_units, &(&1 != unit)) do
          {_before, [^unit | rest_units]} ->
            rest_str =
              String.slice(str, String.length(match), String.length(str) - String.length(match))

            scan_duration_tokens(rest_str, rest_units, count + 1)

          {_before, []} ->
            :error
        end

      nil ->
        :error
    end
  end

  # --- CHK-13..CHK-17: edge-condition/CEL checks (PD-06, REQ-029) -----------

  # CHK-13: a non-default outgoing edge from an EXCLUSIVE_GATEWAY must have a
  # non-empty (after trim) condition (design doc §5.1).
  @spec check_gateway_condition_presence(t()) :: [Violation.t()]
  defp check_gateway_condition_presence(%__MODULE__{nodes: nodes, edges: edges}) do
    node_index = build_node_index(nodes)

    edges
    |> Enum.filter(fn edge ->
      exclusive_gateway_source?(nodes, node_index, edge) and edge.is_default != true and
        blank_condition?(edge.condition)
    end)
    |> Enum.map(fn edge ->
      %Violation{
        code: :missing_edge_condition,
        message:
          "Edge '#{edge.id}' is a non-default outgoing edge from an EXCLUSIVE_GATEWAY and requires a non-empty condition"
      }
    end)
  end

  # CHK-14: every edge whose source is neither a non-default EXCLUSIVE_GATEWAY
  # outgoing edge nor a HUMAN_TASK outgoing edge must have a null condition
  # (design doc §5.1, `iss-0056-human-task-fallback-edge-validation.md` §3.2).
  # Renamed from `check_non_gateway_condition_absence/1` -- that name became
  # misleading once a HUMAN_TASK (non-gateway) source is also permitted to
  # carry a condition.
  @spec check_unpermitted_edge_condition(t()) :: [Violation.t()]
  defp check_unpermitted_edge_condition(%__MODULE__{nodes: nodes, edges: edges}) do
    node_index = build_node_index(nodes)

    edges
    |> Enum.filter(fn edge ->
      not ((exclusive_gateway_source?(nodes, node_index, edge) and edge.is_default != true) or
             human_task_source?(nodes, node_index, edge)) and edge.condition != nil
    end)
    |> Enum.map(fn edge ->
      %Violation{
        code: :unexpected_edge_condition,
        message:
          "Edge '#{edge.id}' is not a non-default EXCLUSIVE_GATEWAY outgoing edge or a " <>
            "HUMAN_TASK outgoing edge and must not have a condition"
      }
    end)
  end

  # CHK-15: is_default and a non-null condition must never coexist, on any
  # edge regardless of source node type -- deliberately unscoped, checked
  # independently of (and able to co-fire with) CHK-14 (design doc §5.1).
  @spec check_default_condition_conflict(t()) :: [Violation.t()]
  defp check_default_condition_conflict(%__MODULE__{edges: edges}) do
    edges
    |> Enum.filter(&(&1.is_default == true and &1.condition != nil))
    |> Enum.map(fn edge ->
      %Violation{
        code: :default_with_condition,
        message: "Edge '#{edge.id}' is marked is_default but also has a non-null condition"
      }
    end)
  end

  # CHK-16: at most one default outgoing edge per EXCLUSIVE_GATEWAY source
  # node -- the first default edge in declaration order is legal, every
  # subsequent one from the same gateway is a violation (mirrors CHK-05's "N
  # occurrences -> N-1 violations" convention, design doc §5.3).
  @spec check_single_default_edge(t()) :: [Violation.t()]
  defp check_single_default_edge(%__MODULE__{nodes: nodes, edges: edges}) do
    node_index = build_node_index(nodes)

    edges
    |> Enum.filter(&exclusive_gateway_source?(nodes, node_index, &1))
    |> Enum.group_by(&Map.fetch!(node_index, &1.source))
    |> Enum.flat_map(fn {gateway_idx, gateway_edges} ->
      gateway_edges
      |> Enum.filter(&(&1.is_default == true))
      |> Enum.drop(1)
      |> Enum.map(fn edge ->
        gateway_id = Enum.at(nodes, gateway_idx).id

        %Violation{
          code: :multiple_default_edges,
          message:
            "Edge '#{edge.id}' is an additional default edge from EXCLUSIVE_GATEWAY node " <>
              "'#{gateway_id}'; only one default edge is permitted per gateway"
        }
      end)
    end)
  end

  # CHK-17: every edge with a present (non-nil, non-blank) condition must be
  # syntactically valid CEL, checked unconditionally regardless of whether
  # the edge was "allowed" to have a condition at all (design doc §5.1).
  #
  # REQ-288: routes through Letflow.Engine.Expr.translate_cel_to_expr/1 ->
  # parse_strict/1 (the real grammar) instead of valid_cel_syntax?/1 (a
  # structural-only check) -- see the moduledoc's "CHK-17 grammar
  # tightening" section for the full disposition and rationale.
  # valid_cel_syntax?/1 is intentionally not called from this path anymore.
  @spec check_cel_syntax(t()) :: [Violation.t()]
  defp check_cel_syntax(%__MODULE__{edges: edges}) do
    edges
    |> Enum.reject(fn edge -> blank_condition?(edge.condition) end)
    |> Enum.flat_map(fn edge ->
      case cel_grammar_error(edge.condition) do
        nil ->
          []

        message ->
          [%Violation{code: :invalid_cel_syntax, message: "Edge '#{edge.id}' #{message}"}]
      end
    end)
  end

  # Runs one edge condition through the real grammar (REQ-288 §2) and
  # returns nil on success, or the tail of the violation message
  # (everything after "Edge '<id>' ") describing why it failed.
  @spec cel_grammar_error(String.t()) :: String.t() | nil
  defp cel_grammar_error(condition) do
    case Expr.translate_cel_to_expr(condition) do
      {:error, :unsupported_cel_feature} ->
        "condition uses a CEL construct this grammar does not support " <>
          "(unsupported call, `in`, or `?`)"

      {:error, :translate_error} ->
        "condition could not be translated to a well-formed expression"

      {:ok, expr_source} ->
        case Expr.parse_strict(expr_source) do
          {:ok, _ast} ->
            nil

          {:error, %{line: line, column: column, token_text: token_text, message: message}} ->
            "condition failed validation at line #{line}, column #{column} " <>
              "(near '#{token_text}'): #{message}"
        end
    end
  end

  # CHK-19: a HUMAN_TASK node with at least one "really conditioned" outgoing
  # edge must also have at least one fallback-candidate outgoing edge to
  # resolve to if every condition evaluates false -- one violation per
  # offending node, not per edge (`iss-0056-human-task-fallback-edge-validation.md`
  # §4.2). Iterates `graph.nodes` filtered to HUMAN_TASK, matching CHK-09's
  # own node-filtering idiom -- not grouped by resolved source index the way
  # CHK-16 groups gateway edges, since this check's unit of concern is one
  # violation per node, not per edge.
  @spec check_human_task_fallback_edge(t()) :: [Violation.t()]
  defp check_human_task_fallback_edge(%__MODULE__{nodes: nodes, edges: edges}) do
    nodes
    |> Enum.filter(&(&1.node_type == :HUMAN_TASK))
    |> Enum.filter(fn node ->
      outgoing = Enum.filter(edges, &(&1.source == node.id))

      Enum.any?(outgoing, &human_task_edge_really_conditioned?/1) and
        not Enum.any?(outgoing, &human_task_edge_fallback_candidate?/1)
    end)
    |> Enum.map(fn node ->
      %Violation{
        code: :human_task_no_fallback_edge,
        message:
          "HUMAN_TASK node '#{node.id}' has at least one really-conditioned outgoing edge " <>
            "but no fallback edge (is_default: true, or a blank/nil condition) to resolve " <>
            "to if every condition evaluates false"
      }
    end)
  end

  # Mirrors `Letflow.Engine.Transition`'s `really_conditioned?/1` predicate
  # literally (copied by value, not imported/aliased/called cross-module --
  # design doc §4.1) so `graph.ex` and `transition.ex` share the same
  # "really conditioned" definition without a cross-module dependency. Does
  # NOT trim whitespace -- deliberately different from `blank_condition?/1`,
  # a disclosed, unreconciled inconsistency (design doc §4.1's open question).
  @spec human_task_edge_really_conditioned?(Edge.t()) :: boolean()
  defp human_task_edge_really_conditioned?(edge) do
    edge.is_default != true and is_binary(edge.condition) and edge.condition != ""
  end

  # The logical complement of `human_task_edge_really_conditioned?/1`, stated
  # separately (not as `not human_task_edge_really_conditioned?/1`) for
  # readability at the CHK-19 call site (design doc §4.1).
  @spec human_task_edge_fallback_candidate?(Edge.t()) :: boolean()
  defp human_task_edge_fallback_candidate?(edge) do
    edge.is_default == true or is_nil(edge.condition) or edge.condition == ""
  end

  @spec blank_condition?(String.t() | nil) :: boolean()
  defp blank_condition?(nil), do: true
  defp blank_condition?(condition) when is_binary(condition), do: String.trim(condition) == ""
  defp blank_condition?(_condition), do: true

  # Resolves `edge.source` via `node_index` (§5.2) and reports whether the
  # resolved node is an EXCLUSIVE_GATEWAY. An unresolvable (dangling) source
  # is defensively treated as "not a gateway" rather than raising -- CHK-03
  # (validate_graph/1) is the function responsible for reporting the dangling
  # reference itself.
  @spec exclusive_gateway_source?(
          [Node.t()],
          %{String.t() => non_neg_integer()},
          Edge.t()
        ) :: boolean()
  defp exclusive_gateway_source?(nodes, node_index, edge) do
    case Map.fetch(node_index, edge.source) do
      {:ok, idx} -> Enum.at(nodes, idx).node_type == :EXCLUSIVE_GATEWAY
      :error -> false
    end
  end

  # Resolves `edge.source` via `node_index` (§5.2) and reports whether the
  # resolved node is a HUMAN_TASK. An unresolvable (dangling) source is
  # defensively treated as "not a HUMAN_TASK" rather than raising -- same
  # convention as `exclusive_gateway_source?/3`; kept as a separate helper
  # rather than a generalization of it so CHK-13/16's existing call sites are
  # untouched by this change (`iss-0056-human-task-fallback-edge-validation.md`
  # §3.1).
  @spec human_task_source?(
          [Node.t()],
          %{String.t() => non_neg_integer()},
          Edge.t()
        ) :: boolean()
  defp human_task_source?(nodes, node_index, edge) do
    case Map.fetch(node_index, edge.source) do
      {:ok, idx} -> Enum.at(nodes, idx).node_type == :HUMAN_TASK
      :error -> false
    end
  end

  # --- valid_cel_syntax?/1 helpers (design doc §6) ---------------------------

  @cel_matching_open %{")" => "(", "]" => "[", "}" => "{"}
  @cel_open_brackets MapSet.new(["(", "[", "{"])
  @cel_close_brackets MapSet.new([")", "]", "}"])
  @cel_quote_chars MapSet.new(["'", "\""])
  @cel_bare_operators MapSet.new([
                        "&&",
                        "||",
                        "==",
                        "!=",
                        "<=",
                        ">=",
                        "<",
                        ">",
                        "+",
                        "-",
                        "*",
                        "/",
                        "."
                      ])

  # Scans `str` (already trimmed) left to right tracking a bracket stack and
  # whether the scan is currently inside a string literal (honoring a `\`
  # escape so `\"` inside a `"`-delimited literal does not close it, design
  # doc §6 step 2). Returns `true` iff every bracket is matched/closed and no
  # string literal is left unterminated at the end of the scan.
  @spec cel_brackets_and_strings_balanced?(String.t()) :: boolean()
  defp cel_brackets_and_strings_balanced?(str) do
    str
    |> String.graphemes()
    |> Enum.reduce_while({[], nil, false}, &cel_scan_char/2)
    |> case do
      {[], nil, false} -> true
      _other -> false
    end
  end

  # Inside a string literal, the char immediately after an unescaped `\` is
  # consumed literally and never closes the literal or is itself treated as
  # a new escape.
  defp cel_scan_char(_ch, {stack, quote, true}) when not is_nil(quote) do
    {:cont, {stack, quote, false}}
  end

  # Inside a string literal (not currently escaped): `\` starts an escape,
  # the matching quote char closes the literal, anything else is literal
  # text -- bracket characters are not pushed/popped/matched while inside a
  # string literal.
  defp cel_scan_char(ch, {stack, quote, false}) when not is_nil(quote) do
    cond do
      ch == "\\" -> {:cont, {stack, quote, true}}
      ch == quote -> {:cont, {stack, nil, false}}
      true -> {:cont, {stack, quote, false}}
    end
  end

  # Outside a string literal: a quote char opens one; an open bracket
  # pushes; a close bracket must match the top of the stack (halting with
  # `:error` on a mismatch or an empty stack); anything else is ordinary
  # text.
  defp cel_scan_char(ch, {stack, nil, false}) do
    cond do
      MapSet.member?(@cel_quote_chars, ch) ->
        {:cont, {stack, ch, false}}

      MapSet.member?(@cel_open_brackets, ch) ->
        {:cont, {[ch | stack], nil, false}}

      MapSet.member?(@cel_close_brackets, ch) ->
        case stack do
          [top | tail] ->
            if @cel_matching_open[ch] == top do
              {:cont, {tail, nil, false}}
            else
              {:halt, :error}
            end

          [] ->
            {:halt, :error}
        end

      true ->
        {:cont, {stack, nil, false}}
    end
  end

  # `str`'s first or last whitespace-/bracket-delimited token is one of the
  # fixed bare operator spellings that requires an operand on the (missing)
  # other side (design doc §6 step 4).
  @spec cel_starts_or_ends_with_bare_operator?(String.t()) :: boolean()
  defp cel_starts_or_ends_with_bare_operator?(str) do
    case cel_tokens(str) do
      [] ->
        false

      tokens ->
        MapSet.member?(@cel_bare_operators, List.first(tokens)) or
          MapSet.member?(@cel_bare_operators, List.last(tokens))
    end
  end

  @spec cel_tokens(String.t()) :: [String.t()]
  defp cel_tokens(str) do
    Regex.split(~r/[\s\(\)\[\]\{\}]+/, str, trim: true)
  end
end
