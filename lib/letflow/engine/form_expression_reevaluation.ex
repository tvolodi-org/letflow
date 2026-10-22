defmodule Letflow.Engine.FormExpressionReevaluation do
  @moduledoc """
  Server-side re-evaluation, at task completion, of the three `x-ui`
  form-field logic keys REQ-291 established at definition time —
  `visible_when`, `computed`, and `cross_field_validation` — against the
  task's own **PINNED** `form_schema` (`task.form_schema`, set once at
  `Letflow.Engine.TaskActivation.insert_attrs/4` and immutable from that
  moment on — REQ-126, REQ-273; a later definition update can never
  retroactively change what an already-inserted task row's `form_schema`
  column holds).

  See `lib/letflow/design/req292-server-side-form-expression-reevaluation.md`
  (the gate-approved design this module implements) for the full derivation.
  Called from `Letflow.Engine`'s `run_complete_task/6`, inside its existing
  `Ecto.Multi`'s `:form_expression_reevaluation` step, between
  `:snapshot_and_state` and `:merge` — no new transaction, no router change.

  ## Purity

  Same discipline as `Letflow.Definitions.FormSchemaExpressions` (REQ-291),
  its definition-time counterpart: depends on Elixir/Erlang stdlib,
  `Letflow.Engine.Expr`, and `Letflow.Definitions.FormSchemaExpressions`
  only — no `Letflow.Repo`, no `Ecto.Changeset`, no `Logger.*`, no clock
  read, no HTTP/file/process-mailbox call anywhere.

  ## Failure vs. false

  An `Expr.eval/2` failure (`{:error, {:eval_error, _}}`) on a
  `visible_when` or `cross_field_validation` expression is never treated as
  `false`. It aborts task completion with `:form_expression_evaluation_failed`,
  distinguishable from a legitimate `{:ok, false}` result by construction —
  the two are different clauses of the same `case`, never collapsed the way
  `Letflow.Engine.Expr.evaluate_condition/2` collapses every failure to
  `false`. That function is never called anywhere in this module — every
  evaluation instead goes through the diagnosable
  `Expr.translate_cel_to_expr/1` -> `Expr.parse_strict/1` -> `Expr.eval/2`
  path, the same one `FormSchemaExpressions` already uses at definition
  time. A `computed` field's evaluation failure is the one documented
  exception: REQ-291 §4.3 already pins that specific case to `nil` (via
  `FormSchemaExpressions.computed_field_absent_or_null_input_result/0`), not
  to a completion-aborting error — a `computed` expression can legitimately
  see an absent or `null` input on every submission, so that case is
  expected, not exceptional, and is handled distinctly from a genuine
  translate/parse failure (defensive only — should be unreachable against a
  schema that already passed REQ-291's definition-time gate).

  ## Computed-field disagreement: the server's value wins, logged, not an error

  Per decision 0020 D1a's own text ("Constraints on the shared grammar,"
  point 3): *"When the server's re-evaluation disagrees with the value a
  client submitted, the server's value is used and the disagreement is
  recorded — it is not an error returned to the user, and not a silent
  overwrite."* This module never lets a client-submitted `computed` value
  win: Pass 1 (`eval_computed_fields/4`) unconditionally overwrites the
  working value with the server's own recomputation before anything is
  persisted. When the submission disagreed, a
  `{:computed_field_disagreement, field, submitted_value, server_value}`
  event is emitted (embedded into the same `TASK_COMPLETED` event's
  `merged_variable_events` payload key `:variable_overwritten` events
  already ride in — no new table). Task completion proceeds normally; this
  is never routed through `Letflow.Engine.ExecutionError.append_multi/3`.

  ## `visible_when: false` on a submitted field: dropped, logged, not an error

  By direct analogy to the computed-field disposition above (same benign
  causes — a stale client-cached schema, or a variable that changed after
  the form was rendered): a field hidden by its own (or another field's)
  `visible_when` evaluating to `false` server-side has its submitted value
  **dropped** from what gets persisted — this call contributes nothing for
  that key, leaving whatever `current_variables` already held untouched.
  Not an error, and not a silent drop: a `{:visible_when_false_value_discarded,
  field, discarded_value}` event is emitted, same delivery mechanism as the
  computed-field disagreement above.

  ## The `variable_schemas` boundary

  This module evaluates **expressions only** — `x-ui.visible_when`,
  `x-ui.computed`, and `x-ui.cross_field_validation`. It never validates a
  submitted value's type or constraints against `form_schema`'s own
  JSON-Schema keywords (`"type"`, `"required"`, `"minimum"`, etc.) — that
  remains `Letflow.Engine.VariableSchema.variable_validations/5`'s sole
  authority, unmodified and unconsulted by anything in this module. The two
  are deliberately different concerns: this module decides what a field's
  value *should be* (computed) or *whether it is visible* (visible_when) and
  *whether the form as a whole is internally consistent*
  (cross_field_validation); `variable_schemas` decides whether a value's
  *shape* is acceptable at all.

  ## Precedence when a field is both `computed` and hidden

  Compute first, then apply visibility (Pass 1 always recomputes; Pass 2
  independently decides whether that recomputed value is persisted this
  call). A computed field's freshly recomputed value remains available to
  any other field's expression evaluated in the same pass regardless of
  whether it ends up dropped — dropping only changes what gets **persisted**,
  never what gets **evaluated**.
  """

  alias Letflow.Definitions.FormSchemaExpressions
  alias Letflow.Engine.Expr

  @typedoc "A field name — a top-level key of form_schema's \"properties\" map."
  @type field_name :: String.t()

  @typedoc """
  Informational outcome of re-evaluation, embedded into the same
  `TASK_COMPLETED` event payload `merge_events` already ride in (never
  persisted as its own DB row — INV-EE48-5). Not an error: completion
  proceeds.
  """
  @type reevaluation_event ::
          {:computed_field_disagreement, field_name(), submitted_value :: term(),
           server_value :: term(), server_labels :: [String.t()],
           submitted_labels :: [String.t()]}
          | {:visible_when_false_value_discarded, field_name(), discarded_value :: term(),
             discarded_labels :: [String.t()]}

  @typedoc """
  A genuine failure of re-evaluation: either a real cross-field-validation
  business rejection, or an expression that could not be EVALUATED at all
  (distinct from evaluating to `false` — see moduledoc "Failure vs. false").
  """
  @type reevaluation_error_type ::
          :form_cross_field_validation_failed | :form_expression_evaluation_failed

  @type reevaluation_error :: %{
          error_type: reevaluation_error_type(),
          field: field_name(),
          reason: String.t(),
          details: map()
        }

  # REQ-291 §4.3's pinned disposition, read through the shared accessor
  # rather than re-decided here — a computed field's own evaluation failure
  # (absent/null input, etc.) evaluates to `nil`.
  @computed_field_absent_or_null_result (case FormSchemaExpressions.computed_field_absent_or_null_input_result() do
                                           :nil_value -> nil
                                         end)

  @doc """
  Re-evaluates every `visible_when`, `computed` and `cross_field_validation`
  expression on `form_schema` (the task's PINNED schema — `task.form_schema`,
  REQ-126) against `current_variables` (the instance's authoritative
  variables before this call) merged with `output_variables` (this call's
  literal, untrusted submission). Returns a corrected `output_variables` map
  (computed fields forcibly overwritten with the server's own recomputation;
  a submitted value for a `visible_when: false` field dropped) plus a list
  of informational `reevaluation_event()`s — or a `reevaluation_error()`
  naming the first (sorted field-name order) rejection found.

  `form_schema == nil`, or a `form_schema` with no `"properties"` map, or a
  `form_schema` whose fields carry none of the three `x-ui` logic keys, is a
  no-op: `{:ok, %{output_variables: output_variables, events: []}}` —
  unchanged from today's behaviour for tasks with no form-field logic.
  """
  @spec reevaluate(
          form_schema :: map() | nil,
          current_variables :: map(),
          current_labels :: map(),
          output_variables :: map()
        ) ::
          {:ok,
           %{
             output_variables: map(),
             output_labels: %{String.t() => [String.t()]},
             events: [reevaluation_event()]
           }}
          | {:error, reevaluation_error()}
  def reevaluate(form_schema, current_variables, current_labels, output_variables) do
    properties = extract_properties(form_schema)

    if map_size(properties) == 0 or not has_logic_keys?(properties) do
      {:ok, %{output_variables: output_variables, output_labels: %{}, events: []}}
    else
      working = build_working_variables(current_variables, output_variables)
      # R9: a key this submission overwrites is an unlabelled value; every other key keeps its
      # stored label. Computed fields are then labelled in topological order (R14).
      working_labels = Map.drop(current_labels, Map.keys(output_variables))
      graph = FormSchemaExpressions.build_computed_dependency_graph(properties)

      case resolve_topological_order(graph) do
        {:error, reevaluation_error} ->
          {:error, reevaluation_error}

        {:ok, topo_order} ->
          with {:ok, working_after_computed, labels_after_computed, computed_events} <-
                 eval_computed_fields(
                   properties,
                   topo_order,
                   working,
                   working_labels,
                   output_variables
                 ),
               {:ok, drop_fields, visible_events} <-
                 eval_visible_when_fields(
                   properties,
                   working_after_computed,
                   output_variables,
                   current_labels
                 ),
               :ok <- eval_cross_field_validations(properties, working_after_computed) do
            corrected_output_variables =
              build_corrected_output_variables(
                properties,
                output_variables,
                working_after_computed,
                drop_fields
              )

            output_labels =
              computed_output_labels(properties, drop_fields, labels_after_computed)

            events = Enum.sort_by(computed_events ++ visible_events, &event_field/1)

            {:ok,
             %{
               output_variables: corrected_output_variables,
               output_labels: output_labels,
               events: events
             }}
          end
      end
    end
  end

  # --- form_schema extraction -------------------------------------------

  @spec extract_properties(map() | nil) :: map()
  defp extract_properties(form_schema) when is_map(form_schema) do
    case Map.get(form_schema, "properties") do
      properties when is_map(properties) -> properties
      _not_a_map -> %{}
    end
  end

  defp extract_properties(_form_schema), do: %{}

  @spec has_logic_keys?(map()) :: boolean()
  defp has_logic_keys?(properties) do
    Enum.any?(properties, fn {_field, schema} ->
      computed_expr(schema) != nil or visible_when_expr(schema) != nil or
        cross_field_validation(schema) != nil
    end)
  end

  # --- Working evaluation context ----------------------------------------

  # Working evaluation context: current, overridden by incoming -- the same
  # shape Letflow.Engine.VariableMerge.merge/3 itself uses -- built once,
  # then threaded through the three passes below, each pass updating it with
  # server-recomputed computed-field values before the next pass reads it.
  @spec build_working_variables(current_variables :: map(), output_variables :: map()) :: map()
  defp build_working_variables(current_variables, output_variables) do
    Map.merge(current_variables, output_variables)
  end

  # --- Topological order over the computed-field dependency graph --------

  @spec resolve_topological_order(graph :: %{optional(field_name()) => [field_name()]}) ::
          {:ok, [field_name()]} | {:error, reevaluation_error()}
  defp resolve_topological_order(graph) do
    case topological_order(graph) do
      {:ok, order} ->
        {:ok, order}

      {:error, :cycle_detected} ->
        # Re-checked defensively here via FormSchemaExpressions.find_cycle/1
        # -- a cycle found at this point is impossible for a form_schema
        # that actually passed REQ-291's definition-time validation, and is
        # treated as :form_expression_evaluation_failed, never as a silent
        # no-op or an infinite loop, on the belt-and-suspenders principle.
        cycle = FormSchemaExpressions.find_cycle(graph) || []

        {:error,
         %{
           error_type: :form_expression_evaluation_failed,
           field: List.first(cycle) || "__computed_dependency_graph__",
           reason:
             "computed-field dependency cycle detected during task completion " <>
               "(should be unreachable for a form_schema that already passed " <>
               "definition-time validation): " <> Enum.join(cycle, " -> "),
           details: %{cycle: cycle}
         }}
    end
  end

  @spec topological_order(graph :: %{optional(field_name()) => [field_name()]}) ::
          {:ok, [field_name()]} | {:error, :cycle_detected}
  defp topological_order(graph) do
    case FormSchemaExpressions.find_cycle(graph) do
      nil -> {:ok, kahn_topological_sort(graph)}
      _cycle -> {:error, :cycle_detected}
    end
  end

  # Kahn's algorithm. `graph`'s own edges (A -> B, "A depends on B") point
  # from a dependent field to its dependency, so the adjacency list built
  # here is the reverse ("B enables A") -- a node is ready once every field
  # it depends on has already been placed in the order. Ties broken by
  # sorted field name for determinism (REQ-291's own open question 2 -- any
  # one valid topological order satisfies every acceptance criterion here).
  @spec kahn_topological_sort(%{optional(field_name()) => [field_name()]}) :: [field_name()]
  defp kahn_topological_sort(graph) do
    nodes = Map.keys(graph)

    adjacency =
      Enum.reduce(graph, Map.new(nodes, &{&1, []}), fn {from, deps}, acc ->
        Enum.reduce(deps, acc, fn dep, acc2 ->
          Map.update(acc2, dep, [from], &(&1 ++ [from]))
        end)
      end)

    in_degree = Map.new(nodes, fn n -> {n, length(Map.get(graph, n, []))} end)
    ready = in_degree |> Enum.filter(fn {_n, degree} -> degree == 0 end) |> Enum.map(&elem(&1, 0))

    do_kahn(adjacency, in_degree, Enum.sort(ready), [])
  end

  defp do_kahn(_adjacency, _in_degree, [], acc), do: Enum.reverse(acc)

  defp do_kahn(adjacency, in_degree, [node | rest], acc) do
    {newly_ready, updated_in_degree} =
      Enum.reduce(Map.get(adjacency, node, []), {[], in_degree}, fn neighbor, {ready_acc, deg} ->
        updated_deg = Map.update!(deg, neighbor, &(&1 - 1))

        if updated_deg[neighbor] == 0 do
          {[neighbor | ready_acc], updated_deg}
        else
          {ready_acc, updated_deg}
        end
      end)

    next_queue = Enum.sort(rest ++ newly_ready)
    do_kahn(adjacency, updated_in_degree, next_queue, [node | acc])
  end

  # --- Pass 1: computed fields --------------------------------------------

  @spec eval_computed_fields(
          properties :: map(),
          topo_order :: [field_name()],
          working :: map(),
          working_labels :: map(),
          output_variables :: map()
        ) ::
          {:ok, working :: map(), working_labels :: map(), [reevaluation_event()]}
          | {:error, reevaluation_error()}
  defp eval_computed_fields(properties, topo_order, working, working_labels, output_variables) do
    topo_order
    |> Enum.reduce_while({:ok, working, working_labels, []}, fn field,
                                                                {:ok, acc_working, acc_labels,
                                                                 events} ->
      schema = Map.fetch!(properties, field)
      expr_string = computed_expr(schema)

      case evaluate_computed_field(expr_string, acc_working, field) do
        {:ok, server_value} ->
          new_working = Map.put(acc_working, field, server_value)

          # R14: the server value carries the union of its inputs' labels. Inputs are read from
          # the working labels, so a computed input inherits its own labels first (topological order).
          server_labels = inherited_labels(expr_string, acc_labels)
          new_labels = Map.put(acc_labels, field, server_labels)

          new_events =
            case Map.fetch(output_variables, field) do
              {:ok, submitted} when submitted != server_value ->
                # R9: the submitted value is an unlabelled human input.
                events ++
                  [
                    {:computed_field_disagreement, field, submitted, server_value, server_labels,
                     []}
                  ]

              _absent_or_agreeing ->
                events
            end

          {:cont, {:ok, new_working, new_labels, new_events}}

        {:error, reevaluation_error} ->
          {:halt, {:error, reevaluation_error}}
      end
    end)
  end

  # The sorted union of the labels of every top-level variable the expression reads.
  defp inherited_labels(expr_string, labels) do
    expr_string
    |> input_keys()
    |> Enum.flat_map(&Map.get(labels, &1, []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp input_keys(expr_string) do
    with {:ok, expr_source} <- Expr.translate_cel_to_expr(expr_string),
         {:ok, ast} <- Expr.parse_strict(expr_source) do
      ast
      |> FormSchemaExpressions.collect_var_paths()
      |> Enum.map(&List.first/1)
      |> Enum.uniq()
    else
      _other -> []
    end
  end

  # The label list written for each computed field the form keeps (R14). `[]` removes a label.
  defp computed_output_labels(properties, drop_fields, labels) do
    properties
    |> Enum.filter(fn {field, schema} ->
      computed_expr(schema) != nil and not MapSet.member?(drop_fields, field)
    end)
    |> Map.new(fn {field, _schema} -> {field, Map.get(labels, field, [])} end)
  end

  defp evaluate_computed_field(expr_string, working, field) do
    with {:ok, expr_source} <- Expr.translate_cel_to_expr(expr_string),
         {:ok, ast} <- Expr.parse_strict(expr_source) do
      case Expr.eval(ast, working) do
        {:ok, value} ->
          {:ok, value}

        {:error, {:eval_error, _reason}} ->
          {:ok, @computed_field_absent_or_null_result}
      end
    else
      {:error, reason} ->
        {:error,
         %{
           error_type: :form_expression_evaluation_failed,
           field: field,
           reason:
             "x-ui.computed expression on field '#{field}' could not be parsed " <>
               "(should be unreachable for a pinned, definition-time-validated schema): " <>
               inspect(reason),
           details: %{expression: expr_string, key: "computed", reason: inspect(reason)}
         }}
    end
  end

  # --- Pass 2: visible_when ------------------------------------------------

  @spec eval_visible_when_fields(
          properties :: map(),
          working :: map(),
          output_variables :: map(),
          current_labels :: map()
        ) ::
          {:ok, drop_fields :: MapSet.t(field_name()), [reevaluation_event()]}
          | {:error, reevaluation_error()}
  defp eval_visible_when_fields(properties, working, output_variables, current_labels) do
    properties
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn {field, schema},
                                                     {:ok, drop_acc, events_acc} ->
      case visible_when_expr(schema) do
        nil ->
          {:cont, {:ok, drop_acc, events_acc}}

        expr_string ->
          case evaluate_boolean_expression(expr_string, working, field, "visible_when") do
            {:ok, true} ->
              {:cont, {:ok, drop_acc, events_acc}}

            {:ok, false} ->
              new_events =
                case Map.fetch(output_variables, field) do
                  {:ok, discarded} ->
                    # The discarded value is a submitted one, so its labels are the field's stored labels (fail closed).
                    discarded_labels = Map.get(current_labels, field, [])

                    events_acc ++
                      [{:visible_when_false_value_discarded, field, discarded, discarded_labels}]

                  :error ->
                    events_acc
                end

              {:cont, {:ok, MapSet.put(drop_acc, field), new_events}}

            {:error, reevaluation_error} ->
              {:halt, {:error, reevaluation_error}}
          end
      end
    end)
  end

  # --- Pass 3: cross_field_validation --------------------------------------

  @spec eval_cross_field_validations(properties :: map(), working :: map()) ::
          :ok | {:error, reevaluation_error()}
  defp eval_cross_field_validations(properties, working) do
    properties
    |> Enum.filter(fn {_field, schema} -> cross_field_validation(schema) != nil end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {field, schema}, :ok ->
      %{"expression" => expr_string, "message" => message} = cross_field_validation(schema)

      case evaluate_boolean_expression(expr_string, working, field, "cross_field_validation") do
        {:ok, true} ->
          {:cont, :ok}

        {:ok, false} ->
          {:halt,
           {:error,
            %{
              error_type: :form_cross_field_validation_failed,
              field: field,
              reason: message,
              details: %{expression: expr_string}
            }}}

        {:error, reevaluation_error} ->
          {:halt, {:error, reevaluation_error}}
      end
    end)
  end

  # Shared by Pass 2 and Pass 3 -- both evaluate a boolean-valued expression
  # via the diagnosable translate/parse/eval path and must never collapse a
  # genuine failure into `false` (moduledoc "Failure vs. false").
  defp evaluate_boolean_expression(expr_string, working, field, key) do
    with {:ok, expr_source} <- Expr.translate_cel_to_expr(expr_string),
         {:ok, ast} <- Expr.parse_strict(expr_source) do
      case Expr.eval(ast, working) do
        {:ok, bool} when is_boolean(bool) ->
          {:ok, bool}

        {:ok, non_boolean} ->
          {:error,
           build_eval_failure(field, key, expr_string, {:non_boolean_result, non_boolean})}

        {:error, {:eval_error, reason}} ->
          {:error, build_eval_failure(field, key, expr_string, reason)}
      end
    else
      {:error, reason} -> {:error, build_eval_failure(field, key, expr_string, reason)}
    end
  end

  defp build_eval_failure(field, key, expr_string, reason) do
    %{
      error_type: :form_expression_evaluation_failed,
      field: field,
      reason:
        "x-ui.#{key} expression on field '#{field}' could not be evaluated " <>
          "(and is therefore never treated as false): " <> inspect(reason),
      details: %{expression: expr_string, key: key, reason: inspect(reason)}
    }
  end

  # --- Corrected output_variables -----------------------------------------

  @spec build_corrected_output_variables(
          properties :: map(),
          output_variables :: map(),
          working :: map(),
          drop_fields :: MapSet.t(field_name())
        ) :: map()
  defp build_corrected_output_variables(properties, output_variables, working, drop_fields) do
    computed_fields =
      properties
      |> Enum.filter(fn {_field, schema} -> computed_expr(schema) != nil end)
      |> Enum.map(&elem(&1, 0))

    base = Map.drop(output_variables, MapSet.to_list(drop_fields))

    Enum.reduce(computed_fields, base, fn field, acc ->
      if MapSet.member?(drop_fields, field) do
        acc
      else
        Map.put(acc, field, Map.get(working, field))
      end
    end)
  end

  # --- x-ui accessors -------------------------------------------------------

  defp computed_expr(schema) when is_map(schema) do
    case Map.get(schema, "x-ui") do
      x_ui when is_map(x_ui) ->
        case Map.get(x_ui, "computed") do
          value when is_binary(value) -> value
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp computed_expr(_schema), do: nil

  defp visible_when_expr(schema) when is_map(schema) do
    case Map.get(schema, "x-ui") do
      x_ui when is_map(x_ui) ->
        case Map.get(x_ui, "visible_when") do
          value when is_binary(value) -> value
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp visible_when_expr(_schema), do: nil

  defp cross_field_validation(schema) when is_map(schema) do
    case Map.get(schema, "x-ui") do
      x_ui when is_map(x_ui) ->
        case Map.get(x_ui, "cross_field_validation") do
          %{"expression" => expression, "message" => message} = value
          when is_binary(expression) and is_binary(message) ->
            value

          _other ->
            nil
        end

      _other ->
        nil
    end
  end

  defp cross_field_validation(_schema), do: nil

  defp event_field({:computed_field_disagreement, field, _submitted, _server, _sl, _subl}),
    do: field

  defp event_field({:visible_when_false_value_discarded, field, _discarded, _labels}), do: field
end
