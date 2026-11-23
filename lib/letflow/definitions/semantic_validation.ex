defmodule Letflow.Definitions.SemanticValidation do
  @moduledoc """
  Semantic validation of `EXCLUSIVE_GATEWAY` edge conditions against a
  process definition's own declared `variable_schemas` (REQ-372,
  `lib/letflow/design/req372-semantic-decision-rule-validation.md` — the
  gate-approved design this module implements). Two independent violation
  classes, collected together in a single pass, never short-circuiting on
  the first one found:

    1. **Field-existence** — an edge condition references a variable root
       segment (`{:var, path}`, checked at `hd(path)` only — see "Nested
       variable references" below) not present among the definition's
       declared `variable_schemas` keys.
    2. **Type-compatibility** — an edge condition compares (`{:cmp, op,
       left, right}`, all six `Letflow.Engine.Expr.cmp_op/0` values treated
       identically) two operands whose declared/literal type families are
       not comparable — see "The comparable/non-comparable type-pair table"
       below for the full table stated in prose, as this moduledoc is
       required to do explicitly rather than leave to test coverage.

  Sibling to `Letflow.Definitions.SubProcessInterface` and
  `Letflow.Definitions.FormSchemaExpressions`: a pure function taking a
  `Letflow.Definitions.Graph.t()` (plus this module's one extra input, the
  declared fields) and returning `Letflow.Definitions.Graph.result()`,
  consumed by `Letflow.Definitions` rather than by `Graph` itself.

  ## Purity

  Depends on Elixir/Erlang stdlib and `Letflow.Engine.Expr` only — no
  `Letflow.Repo`, no `Ecto.Changeset`, no `Logger.*`, no clock read, no
  HTTP/file/process-mailbox call anywhere, matching `Graph`'s own zero-I/O
  contract. Reading `variable_schemas` fresh (so this pass genuinely
  re-runs in full on every call, never against a cached prior result) is
  entirely the caller's job — see `Letflow.Engine.VariableSchema.fetch_schemas/3`,
  already public, already a plain uncached `Repo.all/2`, called fresh by
  `Letflow.Definitions.activate/2` and `Letflow.Definitions.validate_definition_graph/2`
  on every invocation.

  ## Ordering contract

  This module assumes, but does not verify, that `Graph.validate_graph/1`
  **and** `Graph.validate_edge_conditions/1` have already been run against
  the same `graph` value and both returned `valid: true`. It does not call
  either. `Graph.validate_edge_conditions/1`'s CHK-17
  (`check_cel_syntax/1`) is what guarantees every non-blank edge
  `condition` is syntactically valid CEL — `translate_cel_to_expr/1` +
  `parse_strict/1` are guaranteed to succeed only under that precondition.
  Calling `validate/2` against a graph with a grammar-invalid condition will
  not crash: an edge whose condition fails to translate/parse is
  defensively skipped, contributing zero violations for that edge from this
  pass — the CEL-syntax violation is CHK-17's to report, not this module's
  job to duplicate or paper over. Enforcing "run `validate_graph/1` ->
  `validate_edge_conditions/1` -> `SemanticValidation.validate/2`, in that
  order" is entirely the caller's job.

  ## The comparable/non-comparable type-pair table

  Every declared `variable_schemas` field and every literal operand
  resolves to one `type_family()`: `:numeric` (JSON Schema `"number"` or
  `"integer"` — **there is no distinct "money" type in this codebase**; a
  money-valued field is declared as `{"type": "number"}` with, by
  convention, an inert `"format"` annotation, so "money" is simply the
  `:numeric` family for this check's purposes), `:string` (`"string"`),
  `:boolean` (`"boolean"`), `:array` (`"array"`), or `:object`
  (`"object"`). A comparison is exempted from the table entirely (no
  violation, regardless of family) when either operand is a `null` literal
  (a `field == null` / `field != null` guard is always legitimate), an
  unresolved variable reference (already independently reported by the
  field-existence check against the same edge — no redundant second
  violation for the same root cause), or otherwise resolves to `:unknown`
  (an arithmetic expression, a builtin function call, a declared field with
  no recognized or a polymorphic multi-value `"type"`). For every other
  comparison, both operands are one of `:numeric | :string | :boolean |
  :array | :object`, and the full table is:

  | vs.      | numeric   | string    | boolean   | array     | object    |
  |----------|-----------|-----------|-----------|-----------|-----------|
  | numeric  | OK        | VIOLATION | VIOLATION | VIOLATION | VIOLATION |
  | string   | VIOLATION | OK        | VIOLATION | VIOLATION | VIOLATION |
  | boolean  | VIOLATION | VIOLATION | OK        | VIOLATION | VIOLATION |
  | array    | VIOLATION | VIOLATION | VIOLATION | VIOLATION | VIOLATION |
  | object   | VIOLATION | VIOLATION | VIOLATION | VIOLATION | VIOLATION |

  In words: each of the three primitive families (`:numeric`, `:string`,
  `:boolean`) is comparable only with itself; `:array` and `:object` are
  never comparable with anything, including themselves, in this grammar
  (REQ-197's `eval/2` has no defined structural-equality semantic for a CEL
  condition, and an `array`/`object` operand can only ever have reached a
  gateway condition through a declaration mistake). At minimum, this
  records numeric/money vs. text/string as non-comparable, satisfying this
  requirement's own explicit floor.

  ## Data-flow class (REQ-455, `:variable_never_collected`)

  A third violation class, computed in the same pass (and silenced by the same
  empty-`declared_fields` exemption). For a HUMAN_TASK-sourced edge with a
  non-blank condition, a variable root that is not a declared field is reported
  only when it is *certain* no path can set it: no node in the ancestor-or-self
  set of the edge's source may write it. SERVICE_TASK always may write (opaque
  response); a HUMAN_TASK may write iff its `form_schema` has no `properties`
  map or lists the root; a SUB_PROCESS may write iff it has no parseable
  `interface` or its `interface.outputs` names the root. Declared fields are
  treated as possible start inputs. Where some path may set it, the judgment is
  PROCESS-AUDITOR's (REQ-456), not this pass's.

  ## HUMAN_TASK routing/assignment-by-field: OUT OF SCOPE for the first two classes (explicit, not a silent omission)

  The field-existence and type-compatibility classes only cover HUMAN_TASK edge
  conditions via the data-flow class above.

  This module's checks walk **only** `EXCLUSIVE_GATEWAY` edge conditions.
  No HUMAN_TASK attribute is walked, and no HUMAN_TASK-routing-by-field (or
  assignment-by-field) mechanism is designed or implemented here. This is
  a deliberate, grep-verified decision, not an oversight: no such
  mechanism exists anywhere in `lib/letflow/` today.
  `check_human_task_role/1` (`Letflow.Definitions.Graph`'s CHK-09) requires
  a HUMAN_TASK node's `attributes["role"]` to be a non-blank **plain
  string constant**, never an `Letflow.Engine.Expr` expression, and no
  HUMAN_TASK attribute is ever routed through `Letflow.Engine.Expr` at
  activation, task-creation, or anywhere else in the engine. There is
  therefore no existing "authored rule expression" on a HUMAN_TASK node for
  this pass to validate against `variable_schemas` at all — inventing one
  would require a separate, prerequisite requirement (a new node-attribute
  shape, a new consumption point in the engine, its own grammar/scope
  decisions) before any validation of it could even be designed. This gap
  is filed separately and is not solved here.

  ## Empty-declared_fields exemption (REQ-372 §2.5 amendment)

  When `declared_fields == %{}` (the definition has zero `variable_schemas` rows —
  `VariableSchema.fetch_schemas/3` returned an empty map), `validate/2` skips both
  violation classes entirely and returns `%{valid: true, violations: []}`
  unconditionally, without walking any node or edge. `VariableSchema` registration is
  optional; a process that never registered a schema has no schema to validate
  references or comparisons against, so treating "zero fields declared" as "every
  reference is a typo" would invert this requirement's own intent and would block
  activation for every pre-existing, unregistered process definition. This guard lives
  inside `validate/2` itself, checked before any edge is walked, so both call sites
  (`Letflow.Definitions.activate/2` and `Letflow.Definitions.validate_definition_graph/2`)
  get it uniformly with no per-caller special-casing. For any `declared_fields` with at
  least one entry, behavior is exactly as specified above, unchanged.

  **Exception (REQ-461, REQ-459 design section 1.3):** the required-output check
  (`required_output_schema_violations/2`, `:required_output_without_variable_schema`)
  still runs when `declared_fields == %{}`; a definition that declares
  `required_outputs` and registers no `variable_schemas` at all is exactly the defect
  it reports. It is the only class the empty-schema clause can return.

  ## Required-output classes (REQ-461)

  `required_output_schema_violations/2` (a violation, see above) and
  `decision_key_warnings/2` (a permanent WARNING string prefixed
  `decision_key_not_required:`, never a violation: a conditional edge of an
  EXCLUSIVE_GATEWAY or HUMAN_TASK reads a key some upstream HUMAN_TASK's form collects
  while no upstream HUMAN_TASK lists it in `required_outputs`). The warnings are
  aggregated by `Letflow.Definitions.ValidationWarnings`, not returned by `validate/2`.

  ## Nested variable references

  `VariableSchema.variable_key` is a single flat string with no
  nested-path concept — `fetch_schemas/3` selects one row per
  `(definition_id, variable_key)` pair, not per JSON-pointer path into a
  schema's `"properties"`. A multi-segment reference
  (`variables.customer.name`, `path == ["customer", "name"]`) is therefore
  checked only at its root segment (`"customer"`); whether `"customer"`'s
  own declared `json_schema["properties"]` also declares `"name"` is never
  checked by this pass. That would be a materially different check
  (validating against a nested schema, not "is this top-level field
  declared") and is left to a distinct follow-up requirement.
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Violation
  alias Letflow.Engine.Expr

  @typedoc "The comparability family a resolved operand belongs to."
  @type type_family :: :numeric | :string | :boolean | :array | :object | :unknown

  @typedoc """
  `variable_key -> its stored json_schema map`, exactly
  `Letflow.Engine.VariableSchema.fetch_schemas/3`'s `{:ok, schema_map}`
  payload.
  """
  @type declared_fields :: Letflow.Engine.VariableSchema.schema_map()

  # Sentinel families used only internally by operand_family/2 to mark an
  # operand that must be exempted from the comparability table entirely
  # (never surfaced as a real type_family() value).
  @typep operand_family :: type_family() | :null_literal | :unresolvable

  @doc """
  The single entry point. Walks every `EXCLUSIVE_GATEWAY`-sourced edge with
  a non-blank `condition`, and for each one collects every field-existence
  violation and every type-compatibility violation across the whole graph
  in one pass — never short-circuits, mirroring every existing `Graph`
  check's "never short-circuits" convention.

  Amendment (REQ-372 §2.5): if `declared_fields == %{}`, returns
  `%{valid: true, violations: []}` immediately — no node/edge is walked, and
  neither `field_existence_violations/3` nor `type_compatibility_violations/3`
  is invoked at all for this call. See the moduledoc's "Empty-declared_fields
  exemption" section.
  """
  @spec validate(graph :: Graph.t(), declared_fields :: declared_fields()) :: Graph.result()
  def validate(%Graph{} = graph, declared_fields) when declared_fields == %{} do
    # Check 2 (REQ-461) is the one class the empty-declared_fields exemption
    # must NOT hide: a definition with required_outputs and no variable_schemas
    # at all is exactly the defect it reports.
    violations = required_output_schema_violations(graph, declared_fields)
    %{valid: violations == [], violations: violations}
  end

  def validate(%Graph{nodes: nodes, edges: edges} = graph, declared_fields)
      when is_map(declared_fields) do
    node_index = build_node_index(nodes)

    violations =
      edges
      |> Enum.filter(&qualifying_edge?(nodes, node_index, &1))
      |> Enum.flat_map(&edge_violations(&1, declared_fields))

    violations =
      violations ++
        data_flow_violations(nodes, edges, node_index, declared_fields) ++
        required_output_schema_violations(graph, declared_fields)

    %{valid: violations == [], violations: violations}
  end

  # ---------------------------------------------------------------------------------
  # Required-output classes (REQ-461, REQ-459 design sections 1.2-1.4)
  # ---------------------------------------------------------------------------------

  @doc """
  Check 2 (REQ-461): one `:required_output_without_variable_schema` violation per
  (HUMAN_TASK node, `required_outputs` key) whose key is not a key of
  `declared_fields`. Runs in both clauses of `validate/2`, so the
  empty-`declared_fields` exemption does not hide it. Reads `required_outputs`
  totally: a non-list value or a non-string entry (CHK-25's to report) is
  ignored here. Nodes in graph order, keys in declared order.
  """
  @spec required_output_schema_violations(Graph.t(), declared_fields()) :: [Violation.t()]
  def required_output_schema_violations(%Graph{nodes: nodes}, declared_fields)
      when is_map(declared_fields) do
    Enum.flat_map(nodes, fn %Graph.Node{} = node ->
      node
      |> required_outputs()
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(declared_fields, &1))
      |> Enum.map(fn key ->
        %Violation{
          code: :required_output_without_variable_schema,
          message:
            "Node '#{node.id}' (HUMAN_TASK) has required_outputs key '#{key}' with no variable_schema"
        }
      end)
    end)
  end

  @doc """
  Check 3 (REQ-461), a permanent WARNING (design section 1.4): for every
  conditional outgoing edge of an EXCLUSIVE_GATEWAY or HUMAN_TASK, each variable
  root the condition reads that some HUMAN_TASK in `ancestors_or_self(source)`
  collects in its `form_schema.properties` but no such HUMAN_TASK lists in
  `required_outputs` yields one `decision_key_not_required: ...` string. A key no
  HUMAN_TASK produces yields none. Pure; edges in graph order, keys in order of
  first appearance in the condition, producer ids sorted.
  """
  @spec decision_key_warnings(Graph.t(), definition_name :: String.t()) :: [String.t()]
  def decision_key_warnings(%Graph{nodes: nodes, edges: edges}, definition_name)
      when is_binary(definition_name) do
    node_index = build_node_index(nodes)

    Enum.flat_map(edges, fn %Graph.Edge{} = edge ->
      with {:ok, index} <- Map.fetch(node_index, edge.source),
           %Graph.Node{node_type: type} when type in [:EXCLUSIVE_GATEWAY, :HUMAN_TASK] <-
             Enum.at(nodes, index),
           false <- blank_condition?(edge.condition),
           {:ok, ast} <- parse_condition(edge.condition) do
        keys = ast |> collect_var_paths() |> Enum.map(&hd/1) |> Enum.uniq()
        upstream = ancestors_or_self(edge.source, nodes, edges, node_index)

        Enum.flat_map(keys, &decision_key_warning(&1, edge, upstream, definition_name))
      else
        _ -> []
      end
    end)
  end

  @spec decision_key_warning(String.t(), Graph.Edge.t(), [Graph.Node.t()], String.t()) ::
          [String.t()]
  defp decision_key_warning(key, %Graph.Edge{} = edge, upstream, definition_name) do
    human_tasks = Enum.filter(upstream, &(&1.node_type == :HUMAN_TASK))
    producers = Enum.filter(human_tasks, &form_collects?(&1, key))
    declared? = Enum.any?(human_tasks, &(key in required_outputs(&1)))

    if producers != [] and not declared? do
      ids = producers |> Enum.map(& &1.id) |> Enum.sort() |> Enum.join(", ")

      [
        "decision_key_not_required: #{key} (definition '#{definition_name}', edge '#{edge.id}' " <>
          "from node '#{edge.source}' reads it; produced by: #{ids})"
      ]
    else
      []
    end
  end

  @spec form_collects?(Graph.Node.t(), String.t()) :: boolean()
  defp form_collects?(%Graph.Node{attributes: attributes}, key) when is_map(attributes) do
    case Map.get(attributes, "form_schema") do
      %{"properties" => properties} when is_map(properties) -> Map.has_key?(properties, key)
      _ -> false
    end
  end

  defp form_collects?(%Graph.Node{}, _key), do: false

  # Total read of a HUMAN_TASK's `required_outputs`: only string entries of a
  # list; anything else (absent, null, malformed, other node type) reads as [].
  @spec required_outputs(Graph.Node.t()) :: [String.t()]
  defp required_outputs(%Graph.Node{node_type: :HUMAN_TASK, attributes: attributes})
       when is_map(attributes) do
    case Map.get(attributes, "required_outputs") do
      list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and String.trim(&1) != ""))
      _ -> []
    end
  end

  defp required_outputs(%Graph.Node{}), do: []

  # ---------------------------------------------------------------------------------
  # Data-flow class (REQ-455, `:variable_never_collected`)
  # ---------------------------------------------------------------------------------

  @spec data_flow_violations(
          [Graph.Node.t()],
          [Graph.Edge.t()],
          %{String.t() => non_neg_integer()},
          declared_fields()
        ) :: [Violation.t()]
  defp data_flow_violations(nodes, edges, node_index, declared_fields) do
    edges
    |> Enum.flat_map(fn %Graph.Edge{} = edge ->
      with {:ok, index} <- Map.fetch(node_index, edge.source),
           %Graph.Node{node_type: :HUMAN_TASK} <- Enum.at(nodes, index),
           false <- blank_condition?(edge.condition),
           {:ok, ast} <- parse_condition(edge.condition) do
        roots =
          ast
          |> collect_var_paths()
          |> Enum.map(&hd/1)
          |> Enum.reject(&Map.has_key?(declared_fields, &1))

        if roots == [] do
          []
        else
          upstream = ancestors_or_self(edge.source, nodes, edges, node_index)

          roots
          |> Enum.reject(fn root -> Enum.any?(upstream, &may_write?(&1, root)) end)
          |> Enum.map(&never_collected_violation(edge, &1))
        end
      else
        _ -> []
      end
    end)
  end

  @spec never_collected_violation(Graph.Edge.t(), String.t()) :: Violation.t()
  defp never_collected_violation(%Graph.Edge{} = edge, root) do
    %Violation{
      code: :variable_never_collected,
      message:
        "Edge '#{edge.id}' (from HUMAN_TASK node '#{edge.source}') condition reads variable " <>
          "'#{root}' that no declared field, form, service step or sub-process output on any " <>
          "path from START can set; rule as authored: \"#{edge.condition}\""
    }
  end

  # Every node from which `source_id` is reachable by following edges forward,
  # plus the source itself (i.e. every node on any path START -> source).
  @spec ancestors_or_self(
          String.t(),
          [Graph.Node.t()],
          [Graph.Edge.t()],
          %{String.t() => non_neg_integer()}
        ) :: [Graph.Node.t()]
  defp ancestors_or_self(source_id, nodes, edges, node_index) do
    predecessors =
      Enum.reduce(edges, %{}, fn edge, acc ->
        if Map.has_key?(node_index, edge.source) and Map.has_key?(node_index, edge.target) do
          Map.update(acc, edge.target, [edge.source], &[edge.source | &1])
        else
          acc
        end
      end)

    source_id
    |> collect_ancestors([source_id], predecessors, MapSet.new())
    |> Enum.map(&Enum.at(nodes, Map.fetch!(node_index, &1)))
  end

  defp collect_ancestors(_id, [], _predecessors, seen), do: MapSet.to_list(seen)

  defp collect_ancestors(id, [current | rest], predecessors, seen) do
    if MapSet.member?(seen, current) do
      collect_ancestors(id, rest, predecessors, seen)
    else
      collect_ancestors(
        id,
        Map.get(predecessors, current, []) ++ rest,
        predecessors,
        MapSet.put(seen, current)
      )
    end
  end

  # Whether `node` may set variable `root` (design section 4). Opaque or
  # undeclared writers are treated as able to set anything, so only a certain
  # "no path sets it" is reported.
  @spec may_write?(Graph.Node.t(), String.t()) :: boolean()
  defp may_write?(%Graph.Node{node_type: :SERVICE_TASK}, _root), do: true

  defp may_write?(%Graph.Node{node_type: :HUMAN_TASK, attributes: attributes}, root) do
    case is_map(attributes) && Map.get(attributes, "form_schema") do
      %{"properties" => properties} when is_map(properties) -> Map.has_key?(properties, root)
      _open -> true
    end
  end

  defp may_write?(%Graph.Node{node_type: :SUB_PROCESS, id: id, attributes: attributes}, root) do
    interface = if is_map(attributes), do: Map.get(attributes, "interface"), else: nil

    case Letflow.Definitions.SubProcessInterface.parse_interface(id, interface) do
      {%{outputs: outputs}, []} -> Enum.any?(outputs, &(&1.name == root))
      _open -> true
    end
  end

  defp may_write?(%Graph.Node{}, _root), do: false

  @doc """
  Classic Wagner-Fischer dynamic-programming edit distance, over
  `String.graphemes/1` (not byte-based — a multi-byte grapheme counts as
  one edit unit). Case-sensitive: `"Customer_Name"` and `"customer_name"`
  are one substitution apart, not identical — declared field names and
  authored references are both raw strings as typed, and case-folding
  would let a real typo go unreported as "close enough" while still
  failing the existence check.
  """
  @spec levenshtein_distance(a :: String.t(), b :: String.t()) :: non_neg_integer()
  def levenshtein_distance(a, b) when is_binary(a) and is_binary(b) do
    a_graphemes = String.graphemes(a)
    b_graphemes = String.graphemes(b)

    b_len = length(b_graphemes)
    first_row = Enum.to_list(0..b_len//1)

    a_graphemes
    |> Enum.with_index(1)
    |> Enum.reduce(first_row, fn {a_char, i}, prev_row ->
      {final_row, _last_diag} =
        b_graphemes
        |> Enum.with_index(1)
        |> Enum.reduce({[i], Enum.at(prev_row, 0)}, fn {b_char, j}, {row_acc, diag} ->
          above = Enum.at(prev_row, j)
          left = hd(row_acc)

          cost = if a_char == b_char, do: 0, else: 1

          value = Enum.min([above + 1, left + 1, diag + cost])

          {[value | row_acc], above}
        end)

      Enum.reverse(final_row)
    end)
    |> List.last()
  end

  @doc """
  Returns the element of `declared_field_names` with the minimum
  `levenshtein_distance/2` against `typed_name`; `nil` iff
  `declared_field_names == []`. Tie-break: the alphabetically-first
  (`String.<`) candidate among those sharing the minimum distance —
  deterministic regardless of map/list iteration order. No maximum-distance
  cutoff — a suggestion is always produced whenever at least one field is
  declared.
  """
  @spec nearest_declared_field(typed_name :: String.t(), declared_field_names :: [String.t()]) ::
          String.t() | nil
  def nearest_declared_field(_typed_name, []), do: nil

  def nearest_declared_field(typed_name, declared_field_names)
      when is_binary(typed_name) and is_list(declared_field_names) do
    declared_field_names
    |> Enum.map(fn name -> {levenshtein_distance(typed_name, name), name} end)
    |> Enum.sort(fn {dist_a, name_a}, {dist_b, name_b} ->
      {dist_a, name_a} <= {dist_b, name_b}
    end)
    |> List.first()
    |> elem(1)
  end

  # ---------------------------------------------------------------------------------
  # Edge selection (§2.1) -- the same "EXCLUSIVE_GATEWAY-sourced, non-blank
  # condition" set Graph's own CHK-13/CHK-17 already treat as "an
  # EXCLUSIVE_GATEWAY's own condition". HUMAN_TASK-sourced conditions are
  # not walked by this requirement (see moduledoc).
  # ---------------------------------------------------------------------------------

  @spec build_node_index([Graph.Node.t()]) :: %{String.t() => non_neg_integer()}
  defp build_node_index(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {node, index}, acc -> Map.put_new(acc, node.id, index) end)
  end

  @spec qualifying_edge?([Graph.Node.t()], %{String.t() => non_neg_integer()}, Graph.Edge.t()) ::
          boolean()
  defp qualifying_edge?(nodes, node_index, %Graph.Edge{} = edge) do
    exclusive_gateway_source?(nodes, node_index, edge) and not blank_condition?(edge.condition)
  end

  @spec exclusive_gateway_source?(
          [Graph.Node.t()],
          %{String.t() => non_neg_integer()},
          Graph.Edge.t()
        ) :: boolean()
  defp exclusive_gateway_source?(nodes, node_index, %Graph.Edge{source: source}) do
    with {:ok, index} <- Map.fetch(node_index, source),
         %Graph.Node{node_type: :EXCLUSIVE_GATEWAY} <- Enum.at(nodes, index) do
      true
    else
      _ -> false
    end
  end

  @spec blank_condition?(String.t() | nil) :: boolean()
  defp blank_condition?(nil), do: true
  defp blank_condition?(condition) when is_binary(condition), do: String.trim(condition) == ""

  # ---------------------------------------------------------------------------------
  # Per-edge violations: parse once (defensive-skip on translate/parse
  # failure -- CHK-17's job, not this module's), then run both checks
  # against the same parsed ast().
  # ---------------------------------------------------------------------------------

  @spec edge_violations(Graph.Edge.t(), declared_fields()) :: [Violation.t()]
  defp edge_violations(%Graph.Edge{} = edge, declared_fields) do
    case parse_condition(edge.condition) do
      {:ok, ast} ->
        field_existence_violations(edge, ast, declared_fields) ++
          type_compatibility_violations(edge, ast, declared_fields)

      :error ->
        []
    end
  end

  @spec parse_condition(String.t()) :: {:ok, Expr.ast()} | :error
  defp parse_condition(condition) do
    with {:ok, expr_source} <- Expr.translate_cel_to_expr(condition),
         {:ok, ast} <- Expr.parse_strict(expr_source) do
      {:ok, ast}
    else
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------------
  # Field-existence check (§2.2, AC1/AC2)
  # ---------------------------------------------------------------------------------

  @spec field_existence_violations(Graph.Edge.t(), Expr.ast(), declared_fields()) ::
          [Violation.t()]
  defp field_existence_violations(%Graph.Edge{} = edge, ast, declared_fields) do
    declared_names = Map.keys(declared_fields)

    ast
    |> collect_var_paths()
    |> Enum.filter(fn path -> not Map.has_key?(declared_fields, hd(path)) end)
    |> Enum.map(fn path -> undeclared_variable_violation(edge, hd(path), declared_names) end)
  end

  @spec undeclared_variable_violation(Graph.Edge.t(), String.t(), [String.t()]) :: Violation.t()
  defp undeclared_variable_violation(%Graph.Edge{} = edge, typed_root_segment, declared_names) do
    suggestion_clause =
      case nearest_declared_field(typed_root_segment, declared_names) do
        nil -> ""
        nearest -> "; nearest declared field: '#{nearest}'"
      end

    %Violation{
      code: :undeclared_variable_reference,
      message:
        "Edge '#{edge.id}' (from EXCLUSIVE_GATEWAY node '#{edge.source}') condition " <>
          "references undeclared variable '#{typed_root_segment}'" <>
          suggestion_clause <>
          "; rule as authored: \"#{edge.condition}\""
    }
  end

  # Walks ast() collecting every {:var, path} node's path, in traversal
  # order, not deduplicated (matching CHK-05/CHK-16's "N occurrences -> N
  # violations" convention).
  @spec collect_var_paths(Expr.ast()) :: [[String.t()]]
  defp collect_var_paths({:var, path}), do: [path]
  defp collect_var_paths({:lit, _value}), do: []
  defp collect_var_paths({:not, inner}), do: collect_var_paths(inner)
  defp collect_var_paths({:neg, inner}), do: collect_var_paths(inner)

  defp collect_var_paths({:and, left, right}),
    do: collect_var_paths(left) ++ collect_var_paths(right)

  defp collect_var_paths({:or, left, right}),
    do: collect_var_paths(left) ++ collect_var_paths(right)

  defp collect_var_paths({:cmp, _op, left, right}),
    do: collect_var_paths(left) ++ collect_var_paths(right)

  defp collect_var_paths({:arith, _op, left, right}),
    do: collect_var_paths(left) ++ collect_var_paths(right)

  defp collect_var_paths({:call, _name, args}), do: Enum.flat_map(args, &collect_var_paths/1)

  # ---------------------------------------------------------------------------------
  # Type-compatibility check (§2.3, AC3)
  # ---------------------------------------------------------------------------------

  @spec type_compatibility_violations(Graph.Edge.t(), Expr.ast(), declared_fields()) ::
          [Violation.t()]
  defp type_compatibility_violations(%Graph.Edge{} = edge, ast, declared_fields) do
    ast
    |> collect_cmp_nodes()
    |> Enum.flat_map(fn {op, left, right} ->
      comparison_violation(edge, op, left, right, declared_fields)
    end)
  end

  # Walks ast() collecting every {:cmp, op, left, right} node encountered,
  # including ones nested under and/or/not -- all six cmp_op() values
  # treated identically (this check does not narrow to only the four
  # ordering operators; see moduledoc).
  @spec collect_cmp_nodes(Expr.ast()) :: [{Expr.cmp_op(), Expr.ast(), Expr.ast()}]
  defp collect_cmp_nodes({:cmp, op, left, right}) do
    [{op, left, right}] ++ collect_cmp_nodes(left) ++ collect_cmp_nodes(right)
  end

  defp collect_cmp_nodes({:lit, _value}), do: []
  defp collect_cmp_nodes({:var, _path}), do: []
  defp collect_cmp_nodes({:not, inner}), do: collect_cmp_nodes(inner)
  defp collect_cmp_nodes({:neg, inner}), do: collect_cmp_nodes(inner)

  defp collect_cmp_nodes({:and, left, right}),
    do: collect_cmp_nodes(left) ++ collect_cmp_nodes(right)

  defp collect_cmp_nodes({:or, left, right}),
    do: collect_cmp_nodes(left) ++ collect_cmp_nodes(right)

  defp collect_cmp_nodes({:arith, _op, left, right}),
    do: collect_cmp_nodes(left) ++ collect_cmp_nodes(right)

  defp collect_cmp_nodes({:call, _name, args}), do: Enum.flat_map(args, &collect_cmp_nodes/1)

  @spec comparison_violation(
          Graph.Edge.t(),
          Expr.cmp_op(),
          Expr.ast(),
          Expr.ast(),
          declared_fields()
        ) :: [Violation.t()]
  defp comparison_violation(%Graph.Edge{} = edge, op, left, right, declared_fields) do
    left_family = operand_family(left, declared_fields)
    right_family = operand_family(right, declared_fields)

    if exempt?(left_family) or exempt?(right_family) or comparable?(left_family, right_family) do
      []
    else
      [
        %Violation{
          code: :incompatible_comparison_operand_types,
          message:
            "Edge '#{edge.id}' (from EXCLUSIVE_GATEWAY node '#{edge.source}') condition " <>
              "compares incompatible types: '#{operand_repr(left)}' (#{left_family}) " <>
              "#{cmp_op_cel(op)} '#{operand_repr(right)}' (#{right_family}); " <>
              "rule as authored: \"#{edge.condition}\""
        }
      ]
    end
  end

  @spec exempt?(operand_family()) :: boolean()
  defp exempt?(:null_literal), do: true
  defp exempt?(:unresolvable), do: true
  defp exempt?(:unknown), do: true
  defp exempt?(_), do: false

  # Both operands are one of :numeric | :string | :boolean | :array | :object
  # by the time this is called (exempt?/1 already filtered the rest). :array
  # and :object are never comparable, including with themselves; the three
  # primitive families are pairwise incompatible and each is only
  # compatible with itself.
  @spec comparable?(type_family(), type_family()) :: boolean()
  defp comparable?(:array, _), do: false
  defp comparable?(_, :array), do: false
  defp comparable?(:object, _), do: false
  defp comparable?(_, :object), do: false
  defp comparable?(family, family), do: true
  defp comparable?(_left, _right), do: false

  @spec operand_family(Expr.ast(), declared_fields()) :: operand_family()
  defp operand_family({:lit, nil}, _declared_fields), do: :null_literal
  defp operand_family({:lit, v}, _declared_fields) when is_number(v), do: :numeric

  defp operand_family({:lit, marker}, _declared_fields)
       when marker in [:infinity, :neg_infinity, :nan],
       do: :numeric

  defp operand_family({:lit, v}, _declared_fields) when is_binary(v), do: :string
  defp operand_family({:lit, v}, _declared_fields) when is_boolean(v), do: :boolean

  defp operand_family({:var, path}, declared_fields) do
    case Map.fetch(declared_fields, hd(path)) do
      {:ok, json_schema} -> declared_type_family(json_schema)
      :error -> :unresolvable
    end
  end

  defp operand_family(_other, _declared_fields), do: :unknown

  @spec operand_repr(Expr.ast()) :: String.t()
  defp operand_repr({:var, path}), do: "variables." <> Enum.join(path, ".")
  defp operand_repr({:lit, value}), do: inspect(value)
  defp operand_repr(other), do: inspect(other)

  @spec cmp_op_cel(Expr.cmp_op()) :: String.t()
  defp cmp_op_cel(:eq), do: "=="
  defp cmp_op_cel(:neq), do: "!="
  defp cmp_op_cel(:lt), do: "<"
  defp cmp_op_cel(:lte), do: "<="
  defp cmp_op_cel(:gt), do: ">"
  defp cmp_op_cel(:gte), do: ">="

  # ---------------------------------------------------------------------------------
  # §2.3.1 -- resolving a stored json_schema's family
  # ---------------------------------------------------------------------------------

  @spec declared_type_family(json_schema :: map()) :: type_family()
  defp declared_type_family(json_schema) when is_map(json_schema) do
    case Map.get(json_schema, "type") do
      type when is_binary(type) ->
        family_of_type_name(type)

      types when is_list(types) ->
        families =
          types
          |> Enum.reject(&(&1 == "null"))
          |> Enum.map(&family_of_type_name/1)
          |> MapSet.new()

        case MapSet.to_list(families) do
          [single_family] -> single_family
          _ -> :unknown
        end

      _other ->
        :unknown
    end
  end

  @spec family_of_type_name(String.t()) :: type_family()
  defp family_of_type_name("string"), do: :string
  defp family_of_type_name("number"), do: :numeric
  defp family_of_type_name("integer"), do: :numeric
  defp family_of_type_name("boolean"), do: :boolean
  defp family_of_type_name("object"), do: :object
  defp family_of_type_name("array"), do: :array
  defp family_of_type_name(_other), do: :unknown

  @doc """
  The type family of a JSON-Schema TYPE NAME: `"string"` -> `:string`,
  `"number"` and `"integer"` -> `:numeric`, `"boolean"` -> `:boolean`,
  `"object"` -> `:object`, `"array"` -> `:array`, and anything else ->
  `:unknown`.

  The public face of this module's own type rule, so another module that has
  to agree with it about a type -- the typed step mapping
  (`Letflow.Definitions.StepMapping`, pilot gap G13) -- reuses THIS table
  instead of writing a second one that could drift away from it.

  `:unknown` means "this module says nothing about that type": a comparison
  against an `:unknown` family is exempt (see `exempt?/1`), and so is a type
  check against it.
  """
  @spec type_family(String.t()) :: type_family()
  def type_family(type_name) when is_binary(type_name), do: family_of_type_name(type_name)
  def type_family(_other), do: :unknown
end
