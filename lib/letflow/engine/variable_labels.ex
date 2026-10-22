defmodule Letflow.Engine.VariableLabels do
  @moduledoc """
  The one code path that writes the label fields of event payloads and applies a merged label
  map to an `Letflow.Engine.InstanceState` (decision 0062 R7a, R8h, GH #2616 part 1).

  A label is `"entity_type.field_name"`; a variable's labels are a sorted, unique list and an
  absent key means unlabelled. Labels hold names only, never values. Pure: no `Repo`, no clock.

  Label fields are OMITTED when empty (`put_label_field/3`, `encode_merge_events/1`). Part 1
  can produce no non-empty label from a production path, so every part-1 payload stays
  byte-identical to the unlabelled one and replay reads a missing field as "no labels"
  (R8h-4). Switching to always-write is a change of `put_label_field/3` alone.
  """

  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.VariableMerge

  @typedoc "Per-variable labels: variable name to a sorted list of `entity.field` labels."
  @type labels :: %{optional(String.t()) => [String.t()]}

  @doc """
  Normalises a label map: keys must be binaries, each value a sorted unique list of binaries,
  entries with no label are dropped. Anything that is not a map is `%{}`.
  """
  @spec sanitize(term()) :: labels()
  def sanitize(labels) when is_map(labels) do
    Enum.reduce(labels, %{}, fn
      {key, value}, acc when is_binary(key) ->
        case VariableMerge.sanitize_labels(value) do
          [] -> acc
          list -> Map.put(acc, key, list)
        end

      _other, acc ->
        acc
    end)
  end

  def sanitize(_labels), do: %{}

  @doc "The state with `variables` and `variable_labels` replaced together."
  @spec put_merged(InstanceState.t(), map(), labels()) :: InstanceState.t()
  def put_merged(%InstanceState{} = state, variables, labels) do
    %{state | variables: variables, variable_labels: sanitize(labels)}
  end

  @doc """
  Writes `field` into the payload map unless `labels` is empty (`%{}` or `[]`).
  """
  @spec put_label_field(map(), atom() | String.t(), map() | list() | nil) :: map()
  def put_label_field(payload, _field, labels) when labels in [nil, %{}, []], do: payload
  def put_label_field(payload, field, labels), do: Map.put(payload, field, labels)

  @doc """
  The labels of `keys` only (labels travel exactly with the copied keys).
  """
  @spec take(labels(), [String.t()] | map()) :: labels()
  def take(labels, vars) when is_map(vars), do: take(labels, Map.keys(vars))
  def take(labels, keys) when is_list(keys), do: Map.take(sanitize(labels), keys)

  @doc """
  Encodes merge events for the `merged_variable_events` payload field. `variable_overwritten`
  accepts the 4-tuple (no labels) and the 6-tuple of `VariableMerge.merge/5`; the two form
  re-evaluation events accept an optional trailing label list.
  """
  @spec encode_merge_events([tuple()]) :: [map()]
  def encode_merge_events(merge_events) do
    Enum.map(merge_events, &encode_event/1)
  end

  defp encode_event({:variable_overwritten, key, old_value, new_value}),
    do: encode_event({:variable_overwritten, key, old_value, new_value, [], []})

  defp encode_event({:variable_overwritten, key, old_value, new_value, old_labels, new_labels}) do
    %{event: "variable_overwritten", key: key, old_value: old_value, new_value: new_value}
    |> put_label_field(:old_labels, old_labels)
    |> put_label_field(:new_labels, new_labels)
  end

  defp encode_event({:computed_field_disagreement, field, submitted_value, server_value}),
    do: encode_event({:computed_field_disagreement, field, submitted_value, server_value, [], []})

  defp encode_event(
         {:computed_field_disagreement, field, submitted_value, server_value, server_labels,
          submitted_labels}
       ) do
    %{
      event: "computed_field_disagreement",
      field: field,
      submitted_value: submitted_value,
      server_value: server_value
    }
    |> put_label_field(:server_labels, server_labels)
    |> put_label_field(:submitted_labels, submitted_labels)
  end

  defp encode_event({:visible_when_false_value_discarded, field, discarded_value}),
    do: encode_event({:visible_when_false_value_discarded, field, discarded_value, []})

  defp encode_event({:visible_when_false_value_discarded, field, discarded_value, labels}) do
    %{event: "visible_when_false_value_discarded", field: field, discarded_value: discarded_value}
    |> put_label_field(:discarded_labels, labels)
  end

  # ── Read-time redaction (decision 0062 R8, R8h, R12; GH #2616 part 2) ──
  #
  # `hidden` is the set of `entity.field` labels the caller may NOT read, resolved from the
  # caller's grants by the grant loader (`FieldGrants`, in the entities layer) (the loaders do the I/O; these
  # functions do none). `nil` means the set is unknown: every labelled value is then hidden.

  # The same atom as `FieldGrants.redacted_sentinel/0` (the entities layer). The engine may not call
  # the entities layer (boundary lint), so the value is repeated here; a test pins the two together.
  @representation :__field_redacted__

  @variable_fields [
    {"variables", "labels"},
    {"output_variables", "output_labels"},
    {"initial_variables", "initial_labels"}
  ]

  @doc """
  The client-visible stand-in for a redacted value: the `FieldGrants` sentinel, which JSON
  encodes as `"__field_redacted__"`. Lua and WASM use the string form, since they have no atom.
  """
  @spec representation() :: :__field_redacted__
  def representation, do: @representation

  @doc """
  Whether `key` is hidden from a caller whose hidden label set is `hidden`. A key is hidden when
  one of its labels is in `hidden`. An unlabelled key (absent, `nil` or `[]`) is never hidden.
  `hidden` of `nil` hides every labelled key (fail closed, R8).
  """
  @spec hidden?(labels() | term(), String.t(), MapSet.t() | nil) :: boolean()
  def hidden?(labels, key, hidden) when is_map(labels) do
    case Map.get(labels, key) do
      key_labels when is_list(key_labels) -> labels_hidden?(key_labels, hidden)
      _other -> false
    end
  end

  def hidden?(_labels, _key, _hidden), do: false

  defp labels_hidden?([], _hidden), do: false
  defp labels_hidden?(_labels, nil), do: true

  defp labels_hidden?(labels, %MapSet{} = hidden),
    do: Enum.any?(labels, &MapSet.member?(hidden, &1))

  @doc """
  Replaces every hidden value of `variables` with `representation/0`. Reserved keys are dropped
  first (`VariableMerge.drop_reserved/1`); a key name is never redacted, only its value.
  """
  @spec redact_variables(term(), labels() | term(), MapSet.t() | nil) :: map()
  def redact_variables(variables, labels, hidden) when is_map(variables) do
    variables
    |> VariableMerge.drop_reserved()
    |> redact_map(labels, hidden)
  end

  def redact_variables(_variables, _labels, _hidden), do: %{}

  @doc """
  The client-visible form of one stored event payload, with the labels read from the payload
  itself (R8h): the value maps `variables`, `output_variables`, `initial_variables` (labels in
  `labels`, `output_labels`, `initial_labels`), `output` (`output_labels`) and the entries of
  `merged_variable_events`. A missing label field means unlabelled (R8h-4). The caller handles
  the `_sys` and applied-entity event types, which carry no variable values.
  """
  @spec redact_event_payload(term(), MapSet.t() | nil) :: term()
  def redact_event_payload(payload, hidden) when is_map(payload) do
    payload
    |> redact_variable_fields(hidden)
    |> redact_output_field(hidden)
    |> redact_merge_events(hidden)
  end

  def redact_event_payload(payload, _hidden), do: payload

  defp redact_variable_fields(payload, hidden) do
    Enum.reduce(@variable_fields, payload, fn {vars_key, labels_key}, acc ->
      case acc do
        %{^vars_key => vars} when is_map(vars) ->
          labels = sanitize(Map.get(acc, labels_key))
          Map.put(acc, vars_key, redact_variables(vars, labels, hidden))

        _other ->
          acc
      end
    end)
  end

  defp redact_output_field(%{"output" => output} = payload, hidden) when is_map(output) do
    labels = sanitize(Map.get(payload, "output_labels"))
    %{payload | "output" => redact_map(output, labels, hidden)}
  end

  defp redact_output_field(payload, _hidden), do: payload

  defp redact_merge_events(%{"merged_variable_events" => events} = payload, hidden)
       when is_list(events) do
    %{payload | "merged_variable_events" => Enum.map(events, &redact_merge_event(&1, hidden))}
  end

  defp redact_merge_events(payload, _hidden), do: payload

  defp redact_merge_event(%{"event" => "variable_overwritten"} = event, hidden) do
    event
    |> redact_pair("old_value", "old_labels", hidden)
    |> redact_pair("new_value", "new_labels", hidden)
  end

  defp redact_merge_event(%{"event" => "computed_field_disagreement"} = event, hidden) do
    event
    |> redact_pair("server_value", "server_labels", hidden)
    |> redact_pair("submitted_value", "submitted_labels", hidden)
  end

  defp redact_merge_event(%{"event" => "visible_when_false_value_discarded"} = event, hidden),
    do: redact_pair(event, "discarded_value", "discarded_labels", hidden)

  defp redact_merge_event(event, _hidden), do: event

  defp redact_pair(event, value_key, labels_key, hidden) do
    if Map.has_key?(event, value_key) and
         labels_hidden?(VariableMerge.sanitize_labels(Map.get(event, labels_key)), hidden) do
      Map.put(event, value_key, representation())
    else
      event
    end
  end

  @doc """
  Replaces every hidden value of `values` (no reserved-key drop: the caller decides what is shown)
  with `representation/0`. Used where a map is already the caller's own visible set.
  """
  @spec redact_map(map(), labels() | term(), MapSet.t() | nil) :: map()
  def redact_map(values, labels, hidden) when is_map(values) do
    Map.new(values, fn {key, value} ->
      if hidden?(labels, key, hidden), do: {key, representation()}, else: {key, value}
    end)
  end
end
