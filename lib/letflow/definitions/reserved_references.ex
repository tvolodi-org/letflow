defmodule Letflow.Definitions.ReservedReferences do
  @moduledoc """
  GH #2587 / REQ-499 PR A1b (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  section 2A, decision 0054; supervisor ruling of 2026-10-15): finds every place a process
  definition's graph NAMES a variable whose first segment is the reserved engine namespace
  (`Letflow.Engine.VariableMerge.reserved_key?/1`). The engine writes that namespace for its
  own bookkeeping; no expression or variable binding a process author writes may read it.

  Detection parses; it never runs a regex over the source text:

    * L1 edge `condition`: `Expr.translate_cel_to_expr/1` then `Expr.parse/1` (the evaluator's
      own call graph, `Expr.evaluate_condition/2`); referenced paths from
      `FormSchemaExpressions.collect_var_paths/1`. A path is a reference iff its HEAD segment is
      reserved (`reserved_path?/1`), so a string literal, a nested `a.<reserved>` key and a name
      that merely starts with the same letters are not references.
    * L2-L4 HUMAN_TASK `form_schema.properties.<f>.x-ui` `visible_when`, `computed`,
      `cross_field_validation.expression`: the same, with `Expr.parse_strict/1` (the parser
      `FormExpressionReevaluation` uses).
    * L5-L6 SERVICE_TASK `endpoint` and `body_template`: the renderer's own placeholder grammar,
      `Letflow.Engine.ServiceTask.template_variable_keys/1`.
    * L7-L8 SUB_PROCESS `interface` `inputs` / `outputs` entry names, from
      `SubProcessInterface.parse_interface/2`; the WHOLE name is checked with `reserved_key?/1`.

  L9 (a bound script's `manifest.input_schema.properties` keys) needs the script row, so it is
  checked in `Letflow.Scripts.Runtime.check_bindings/2`, which builds the same `reserved_reference()`.

  Callers: `Graph`'s CHK-29 (`node_references/1`) and CHK-30 (`edge_references/1`) at save, and
  `Letflow.Definitions.check_reserved_references/1` at every activation path (activate, version
  rollback, promotion apply).

  Invariant I-13 (design 2A.7): any FUTURE location that reads variables by a
  definition-authored name adds itself here in the same PR. Two known run-time readers are not
  wired to node dispatch today and must use this module (or `reserved_key?/1`) when they are:
  Lua `read_variable` (`lib/letflow/engine/lua/platform.ex`) and the WASM host
  `read_variable` (`Letflow.Engine.Wasm.HostApi.do_read_variable/6`, an exact `Map.fetch`).

  ## Purity and totality

  Pure: no `Letflow.Repo`, no clock, no I/O. Total (INV-8): malformed attributes, a non-binary
  condition or template, and unparseable text yield no reference; they never raise. An
  unparseable expression reads no variable at run time, and CHK-17/CHK-20 report it at save.
  """

  alias Letflow.Definitions.FormSchemaExpressions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Violation
  alias Letflow.Definitions.SubProcessInterface
  alias Letflow.Engine.Expr
  alias Letflow.Engine.ServiceTask
  alias Letflow.Engine.VariableMerge

  @type location ::
          :edge_condition
          | :form_visible_when
          | :form_computed
          | :form_cross_field_validation
          | :service_task_endpoint
          | :service_task_body_template
          | :sub_process_input
          | :sub_process_output
          | :script_input

  @type reserved_reference :: %{
          element: :node | :edge,
          id: String.t(),
          location: location(),
          field: String.t() | nil,
          name: String.t()
        }

  @doc """
  Every reserved-name reference in `graph`: `node_references/1 ++ edge_references/1`.
  Deterministic: nodes then edges, each in graph order.
  """
  @spec find(Graph.t()) :: [reserved_reference()]
  def find(%Graph{} = graph), do: node_references(graph) ++ edge_references(graph)

  @doc """
  L2-L8, nodes in graph order. Within a node: SERVICE_TASK endpoint then body_template;
  SUB_PROCESS interface inputs then outputs, entries in list order; HUMAN_TASK form fields
  sorted by name, each field's visible_when, computed, cross_field_validation. A name named
  twice by the same expression or template is reported once.
  """
  @spec node_references(Graph.t()) :: [reserved_reference()]
  def node_references(%Graph{nodes: nodes}) do
    Enum.flat_map(nodes, fn %Graph.Node{} = node ->
      node_refs(node.node_type, node.id, attributes(node.attributes))
    end)
  end

  @doc "L1, edges in graph order; blank and non-binary conditions are skipped."
  @spec edge_references(Graph.t()) :: [reserved_reference()]
  def edge_references(%Graph{edges: edges}) do
    Enum.flat_map(edges, fn %Graph.Edge{id: id, condition: condition} ->
      condition
      |> condition_names()
      |> Enum.map(&reference(:edge, id, :edge_condition, nil, &1))
    end)
  end

  @doc """
  One `%Violation{code: :expression_references_reserved_variable}` per reference; the message
  names the element, the location, the field (when there is one) and the referenced name, all
  from the author's own graph (or, for L9, the property name of a script the tenant published).
  """
  @spec violations([reserved_reference()]) :: [Violation.t()]
  def violations(references) when is_list(references) do
    Enum.map(references, fn reference ->
      %Violation{code: :expression_references_reserved_variable, message: message(reference)}
    end)
  end

  @doc "`true` iff `path` is non-empty and its head segment is reserved."
  @spec reserved_path?([String.t()]) :: boolean()
  def reserved_path?([head | _rest]), do: VariableMerge.reserved_key?(head)
  def reserved_path?(_empty_or_other), do: false

  # ── per node type ─────────────────────────────────────────────────────────

  @spec node_refs(atom(), String.t(), map()) :: [reserved_reference()]
  defp node_refs(:SERVICE_TASK, id, attrs) do
    template_refs(id, :service_task_endpoint, Map.get(attrs, "endpoint")) ++
      template_refs(id, :service_task_body_template, Map.get(attrs, "body_template"))
  end

  defp node_refs(:SUB_PROCESS, id, attrs) do
    case SubProcessInterface.parse_interface(id, Map.get(attrs, "interface")) do
      {%{inputs: inputs, outputs: outputs}, _violations} ->
        interface_refs(id, :sub_process_input, inputs) ++
          interface_refs(id, :sub_process_output, outputs)

      {nil, _violations} ->
        []
    end
  end

  defp node_refs(:HUMAN_TASK, id, attrs) do
    attrs
    |> form_properties()
    |> Enum.sort_by(fn {field, _schema} -> field end)
    |> Enum.flat_map(fn {field, schema} -> form_field_refs(id, field, x_ui(schema)) end)
  end

  defp node_refs(_other_type, _id, _attrs), do: []

  # ── L5-L6 templates ───────────────────────────────────────────────────────

  defp template_refs(id, location, template) when is_binary(template) do
    template
    |> ServiceTask.template_variable_keys()
    |> Enum.filter(&VariableMerge.reserved_key?/1)
    |> Enum.uniq()
    |> Enum.map(&reference(:node, id, location, nil, &1))
  end

  defp template_refs(_id, _location, _not_a_template), do: []

  # ── L7-L8 interface ───────────────────────────────────────────────────────

  defp interface_refs(id, location, entries) do
    entries
    |> Enum.map(& &1.name)
    |> Enum.filter(&VariableMerge.reserved_key?/1)
    |> Enum.map(&reference(:node, id, location, &1, &1))
  end

  # ── L2-L4 form x-ui ───────────────────────────────────────────────────────

  defp form_properties(attrs) do
    with %{} = form_schema <- Map.get(attrs, "form_schema"),
         %{} = properties <- Map.get(form_schema, "properties") do
      Enum.filter(properties, fn {field, _schema} -> is_binary(field) end)
    else
      _absent_or_malformed -> []
    end
  end

  defp x_ui(%{"x-ui" => %{} = x_ui}), do: x_ui
  defp x_ui(_schema), do: %{}

  defp form_field_refs(id, field, x_ui) do
    cross_field_expression =
      case Map.get(x_ui, "cross_field_validation") do
        %{"expression" => expression} -> expression
        _absent_or_malformed -> nil
      end

    [
      {:form_visible_when, Map.get(x_ui, "visible_when")},
      {:form_computed, Map.get(x_ui, "computed")},
      {:form_cross_field_validation, cross_field_expression}
    ]
    |> Enum.flat_map(fn {location, expression} ->
      expression
      |> strict_expression_names()
      |> Enum.map(&reference(:node, id, location, field, &1))
    end)
  end

  # ── Expr parsing ──────────────────────────────────────────────────────────

  # L1: exactly evaluate_condition/2's pipeline (translate, then the lenient parse/1).
  defp condition_names(condition) when is_binary(condition) do
    with false <- String.trim(condition) == "",
         {:ok, source} <- Expr.translate_cel_to_expr(condition),
         {:ok, ast} <- Expr.parse(source) do
      reserved_names(ast)
    else
      _blank_or_unparseable -> []
    end
  end

  defp condition_names(_nil_or_not_a_string), do: []

  # L2-L4: FormExpressionReevaluation's pipeline (translate, then parse_strict/1).
  defp strict_expression_names(expression) when is_binary(expression) do
    with {:ok, source} <- Expr.translate_cel_to_expr(expression),
         {:ok, ast} <- Expr.parse_strict(source) do
      reserved_names(ast)
    else
      _unparseable -> []
    end
  end

  defp strict_expression_names(_absent_or_not_a_string), do: []

  defp reserved_names(ast) do
    ast
    |> FormSchemaExpressions.collect_var_paths()
    |> Enum.filter(&reserved_path?/1)
    |> Enum.map(&Enum.join(&1, "."))
    |> Enum.uniq()
  end

  # ── building ──────────────────────────────────────────────────────────────

  defp attributes(%{} = attributes), do: attributes
  defp attributes(_nil_or_malformed), do: %{}

  defp reference(element, id, location, field, name),
    do: %{element: element, id: id, location: location, field: field, name: name}

  defp message(%{element: element, id: id, location: location, field: field, name: name}) do
    field_text = if is_binary(field), do: " field '#{field}'", else: ""

    "#{element_text(element)} '#{id}' #{location_text(location)}#{field_text} " <>
      "references the reserved variable '#{name}'"
  end

  defp element_text(:edge), do: "Edge"
  defp element_text(:node), do: "Node"

  defp location_text(:edge_condition), do: "condition"
  defp location_text(:form_visible_when), do: "form x-ui.visible_when"
  defp location_text(:form_computed), do: "form x-ui.computed"
  defp location_text(:form_cross_field_validation), do: "form x-ui.cross_field_validation"
  defp location_text(:service_task_endpoint), do: "service task endpoint"
  defp location_text(:service_task_body_template), do: "service task body_template"
  defp location_text(:sub_process_input), do: "sub-process interface input"
  defp location_text(:sub_process_output), do: "sub-process interface output"
  defp location_text(:script_input), do: "bound script input"
end
