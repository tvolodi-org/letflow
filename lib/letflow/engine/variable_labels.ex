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
end
