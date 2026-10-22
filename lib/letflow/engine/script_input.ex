defmodule Letflow.Engine.ScriptInput do
  @moduledoc """
  GH 2534 PR 7c-1 (decision 0053 D5, D9): assembles a tenant script's input host-side, before
  the run, and its canonical HMAC document. Design
  `lib/letflow/design/gh2534-7c-script-handler.md` section 5.3 steps 5-6, C9, C14. Pure.

  Field-minimal: only the instance variables whose keys are declared in
  `manifest["input_schema"]["properties"]` enter the input (no undeclared variable is ever
  handed to a script). The declared variables must satisfy `input_schema`. When the manifest
  declares reads (7c-2), their pre-fetched rows go under `input["reads"]` AFTER that check: the
  manifest validation reserves `"reads"` (an `input_schema` may not declare it), exactly as
  stored test cases and dry-run add their read fixtures after validating the input (7b-2a
  section 4), so a closed `input_schema` keeps its meaning.
  """

  alias Letflow.Engine.VariableLabels
  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.Repository.Canonicaliser
  alias Letflow.Scripts.Validation

  @doc """
  `{:ok, input, taint}` with only the declared variables, or `{:error, :input_invalid}` when
  the declared variables do not satisfy `input_schema`. Reads are added later with
  `put_reads/2`.

  Decision 0062 R4/R6: a declared variable that carries labels (`variable_labels[key]`) enters
  the input only when a `restricted_inputs` entry names it and every one of its labels is in
  that entry's `from`; otherwise it is OMITTED (so a required one fails `input_schema`).
  `taint` is the sorted unique union of the labels of the variables that entered.
  """
  @spec build(map(), map(), map(), nil) ::
          {:ok, map(), [String.t()]} | {:error, :input_invalid}
  def build(variables, variable_labels, manifest, nil)
      when is_map(variables) and is_map(manifest) do
    input_schema = Map.get(manifest, "input_schema", %{})

    declared =
      case input_schema do
        %{"properties" => %{} = props} -> Map.keys(props)
        _ -> []
      end

    entries = Map.new(Validation.restricted_input_entries(manifest), &{&1["name"], &1["from"]})
    labels = VariableLabels.sanitize(variable_labels)

    {kept, taint} =
      Enum.reduce(declared, {[], []}, fn key, {kept, taint} ->
        case Map.get(labels, key, []) do
          [] ->
            {[key | kept], taint}

          ls ->
            allowed = entries |> Map.get(key, []) |> Enum.map(&label_of/1)

            if Enum.all?(ls, &(&1 in allowed)),
              do: {[key | kept], ls ++ taint},
              else: {kept, taint}
        end
      end)

    input = Map.take(variables, kept)

    if is_map(input_schema) and JsonSchema.validate(input, input_schema) == [],
      do: {:ok, input, taint |> Enum.uniq() |> Enum.sort()},
      else: {:error, :input_invalid}
  end

  def build(_variables, _labels, _manifest, _reads_result), do: {:error, :input_invalid}

  @doc """
  The taint of a manifest's declared reads (decision 0062 R4): every declared
  `restricted_fields` pair, as `"entity_type.field"`. Counted whether or not the field is
  restricted now or the row matched (over-tainting only refuses more writes). Pure.
  """
  @spec read_taint([map()]) :: [String.t()]
  def read_taint(reads) when is_list(reads) do
    reads
    |> Enum.flat_map(fn
      %{"entity_type" => type, "restricted_fields" => fields}
      when is_binary(type) and is_list(fields) ->
        for f <- fields, is_binary(f), do: type <> "." <> f

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def read_taint(_reads), do: []

  defp label_of(%{"entity_type" => type, "field" => field}), do: type <> "." <> field

  @doc """
  Puts the pre-fetched rows under `input["reads"]` (`nil` = no reads: `input` unchanged). No
  validation: `input` is a `build/4` result, already checked, and `"reads"` is reserved (an
  `input_schema` cannot declare it). The dispatcher builds once, pre-fetches with the validated
  variables, then calls this, so the input is validated exactly once. Pure.
  """
  @spec put_reads(map(), %{optional(String.t()) => [map()]} | nil) :: map()
  def put_reads(input, %{} = reads_result) when is_map(input),
    do: Map.put(input, "reads", reads_result)

  def put_reads(input, nil) when is_map(input), do: input

  @doc """
  The canonical bytes the per-run HMAC covers (C14): the canonical JSON form
  (`Letflow.Repository.Canonicaliser`) of `{"ctx": ctx, "input": input}`, where `ctx` is
  `%{"instance_id", "node_id", "token_id", "now"}` (`now` ISO-8601 of the arm-time event time).
  """
  @spec canonical(map(), map()) :: binary()
  def canonical(input, ctx) when is_map(input) and is_map(ctx) do
    {:ok, canonical} =
      Canonicaliser.canonicalize_content(
        "application/json",
        Jason.encode!(%{"ctx" => ctx, "input" => input})
      )

    canonical
  end
end
