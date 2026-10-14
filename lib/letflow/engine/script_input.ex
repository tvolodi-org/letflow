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

  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.Repository.Canonicaliser

  @doc """
  `{:ok, input}` with only the declared variables (plus `"reads"` when `reads_result` is a
  map), or `{:error, :input_invalid}` when the declared variables do not satisfy
  `input_schema`.
  """
  @spec build(map(), map(), %{optional(String.t()) => [map()]} | nil) ::
          {:ok, map()} | {:error, :input_invalid}
  def build(variables, manifest, reads_result) when is_map(variables) and is_map(manifest) do
    input_schema = Map.get(manifest, "input_schema", %{})

    declared =
      case input_schema do
        %{"properties" => %{} = props} -> Map.keys(props)
        _ -> []
      end

    input = Map.take(variables, declared)

    cond do
      not (is_map(input_schema) and JsonSchema.validate(input, input_schema) == []) ->
        {:error, :input_invalid}

      is_map(reads_result) ->
        {:ok, Map.put(input, "reads", reads_result)}

      true ->
        {:ok, input}
    end
  end

  def build(_variables, _manifest, _reads_result), do: {:error, :input_invalid}

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
