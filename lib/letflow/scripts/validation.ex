defmodule Letflow.Scripts.Validation do
  @moduledoc """
  GH 2534 PR 7b-1 (decision 0053 D1, D5, D10; advisor Q3): validation of a script version's
  manifest, stored test cases, dry-run input and reason text. Design sections 3, 4, 5, 7.

  Every function returns `:ok` / `{:ok, value}` or `{:error, code}` with a stable code; no
  submitted value is ever echoed.
  """

  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.Scripts.Hash

  @manifest_keys ~w(input_schema output_schema fail_codes limits reads restricted_inputs)
  @required_manifest_keys ~w(input_schema output_schema fail_codes)
  @limit_keys %{
    "instructions" => :max_instructions,
    "timeout_ms" => :max_timeout_ms,
    "heap_words" => :max_heap_words
  }
  @schema_types ~w(object array string integer number boolean null)
  @code_pattern ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @max_fail_codes 32
  @max_restricted 32
  @max_schema_depth 8
  @max_schema_bytes 32_768
  @max_cases 32
  @max_case_name 64
  @max_case_input_bytes 16_384
  @max_cases_bytes 262_144
  @max_dry_run_input_bytes 65_536
  @max_reason_codepoints 500
  @reason_forbidden ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u

  # ── manifest (section 3) ───────────────────────────────────────────────────

  @doc "Validates a manifest map. Q3: `reads` must be empty in 7b-1."
  @spec manifest(term()) :: :ok | {:error, atom()}
  def manifest(manifest) when is_map(manifest) do
    keys = Map.keys(manifest)

    cond do
      not Enum.all?(keys, &(&1 in @manifest_keys)) ->
        {:error, :invalid_manifest}

      not Enum.all?(@required_manifest_keys, &Map.has_key?(manifest, &1)) ->
        {:error, :invalid_manifest}

      not reads_empty?(Map.get(manifest, "reads", [])) ->
        {:error, :reads_not_allowed}

      true ->
        manifest_parts(manifest)
    end
  end

  def manifest(_other), do: {:error, :invalid_manifest}

  defp reads_empty?([]), do: true
  defp reads_empty?(_), do: false

  defp manifest_parts(manifest) do
    with :ok <- schema(manifest["input_schema"]),
         :ok <- schema(manifest["output_schema"]),
         :ok <- codes(manifest["fail_codes"], @max_fail_codes),
         :ok <- limits(Map.get(manifest, "limits", %{})),
         :ok <- restricted(Map.get(manifest, "restricted_inputs", []), manifest["input_schema"]) do
      :ok
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  defp codes(list, max) when is_list(list) do
    if length(list) <= max and Enum.uniq(list) == list and
         Enum.all?(list, &(is_binary(&1) and Regex.match?(@code_pattern, &1))),
       do: :ok,
       else: :error
  end

  defp codes(_other, _max), do: :error

  defp limits(limits) when is_map(limits) do
    maxima = ScriptRunner.limits()

    if Enum.all?(limits, fn {key, value} ->
         case Map.fetch(@limit_keys, key) do
           {:ok, max_key} ->
             is_integer(value) and value > 0 and value <= Map.fetch!(maxima, max_key)

           :error ->
             false
         end
       end),
       do: :ok,
       else: :error
  end

  defp limits(_other), do: :error

  defp restricted(list, input_schema) when is_list(list) do
    properties = Map.get(input_schema, "properties", %{})

    if length(list) <= @max_restricted and Enum.uniq(list) == list and
         Enum.all?(
           list,
           &(is_binary(&1) and Regex.match?(@code_pattern, &1) and Map.has_key?(properties, &1))
         ),
       do: :ok,
       else: :error
  end

  defp restricted(_other, _schema), do: :error

  # A schema is well-formed when it uses only the keywords JsonSchema implements (plus
  # title/description), is an object at the top level, and stays within depth and size.
  defp schema(schema) when is_map(schema) do
    with true <- Map.get(schema, "type") == "object",
         true <- byte_size(Hash.canon(schema)) <= @max_schema_bytes,
         true <- well_formed?(schema, 1) do
      :ok
    else
      _ -> :error
    end
  end

  defp schema(_other), do: :error

  defp well_formed?(schema, depth) when is_map(schema) and depth <= @max_schema_depth do
    Enum.all?(schema, fn
      {"type", type} ->
        type in @schema_types

      {"properties", props} ->
        is_map(props) and
          Enum.all?(props, fn {k, v} -> is_binary(k) and well_formed?(v, depth + 1) end)

      {"items", items} ->
        well_formed?(items, depth + 1)

      {"required", req} ->
        is_list(req) and Enum.all?(req, &is_binary/1)

      {"additionalProperties", value} ->
        value == false

      {"enum", values} ->
        is_list(values)

      {key, value} when key in ["minimum", "maximum"] ->
        is_number(value)

      {key, value} when key in ["minLength", "maxLength"] ->
        is_integer(value) and value >= 0

      {key, value} when key in ["title", "description"] ->
        is_binary(value)

      {_unsupported_keyword, _value} ->
        false
    end)
  end

  defp well_formed?(_schema, _depth), do: false

  # ── test cases (section 4) ─────────────────────────────────────────────────

  @doc "Validates the stored test cases against a (valid) manifest."
  @spec test_cases(term(), map()) :: :ok | {:error, atom()}
  def test_cases(cases, manifest) when is_list(cases) do
    cond do
      cases == [] or length(cases) > @max_cases -> {:error, :invalid_test_case}
      byte_size(Hash.canon(cases)) > @max_cases_bytes -> {:error, :invalid_test_case}
      Enum.all?(cases, &valid_case?(&1, manifest)) -> :ok
      true -> {:error, :invalid_test_case}
    end
  end

  def test_cases(_cases, _manifest), do: {:error, :invalid_test_case}

  defp valid_case?(%{"name" => name, "input" => input, "expect" => expect} = case, manifest)
       when map_size(case) == 3 and is_binary(name) and is_map(input) do
    String.length(name) in 1..@max_case_name and
      byte_size(Hash.canon(input)) <= @max_case_input_bytes and
      JsonSchema.validate(input, manifest["input_schema"]) == [] and
      valid_expect?(expect, manifest)
  end

  defp valid_case?(_case, _manifest), do: false

  defp valid_expect?(%{"output" => output} = expect, manifest)
       when map_size(expect) == 1 and is_map(output),
       do: JsonSchema.validate(output, manifest["output_schema"]) == []

  defp valid_expect?(%{"fail" => code} = expect, manifest) when map_size(expect) == 1,
    do: code in manifest["fail_codes"]

  defp valid_expect?(_expect, _manifest), do: false

  # ── dry-run input, reason, key ─────────────────────────────────────────────

  @doc "A dry-run input: a JSON object within the size cap satisfying `input_schema`."
  @spec dry_run_input(term(), map()) :: :ok | {:error, :invalid_input}
  def dry_run_input(input, manifest) when is_map(input) do
    if byte_size(Hash.canon(input)) <= @max_dry_run_input_bytes and
         JsonSchema.validate(input, manifest["input_schema"]) == [],
       do: :ok,
       else: {:error, :invalid_input}
  end

  def dry_run_input(_input, _manifest), do: {:error, :invalid_input}

  @doc "Retire/revoke reason: trimmed 1..500 codepoints, no Cc/Cf/Zl/Zp character."
  @spec reason(term()) :: {:ok, String.t()} | {:error, :invalid_reason}
  def reason(reason) when is_binary(reason) do
    trimmed = String.trim(reason)

    if String.valid?(trimmed) and length(String.codepoints(trimmed)) in 1..@max_reason_codepoints and
         not String.match?(trimmed, @reason_forbidden),
       do: {:ok, trimmed},
       else: {:error, :invalid_reason}
  end

  def reason(_reason), do: {:error, :invalid_reason}

  @doc "A script key: `^[a-z][a-z0-9_]{0,63}$`."
  @spec key?(term()) :: boolean()
  def key?(key), do: is_binary(key) and Regex.match?(@code_pattern, key)
end
