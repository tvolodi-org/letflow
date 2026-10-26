defmodule Letflow.Scripts.Validation do
  @moduledoc """
  GH 2534 PR 7b-1 (decision 0053 D1, D5, D10; advisor Q3): validation of a script version's
  manifest, stored test cases, dry-run input and reason text. Design sections 3, 4, 5, 7.

  GH 2534 PR 7b-2a (`lib/letflow/design/gh2534-7b2a-script-policy.md` sections 3.1 and 4): the
  manifest's `reads` SHAPE is validated here (pure, no DB; a shape error is
  `:invalid_manifest`), and stored test cases and dry-run carry optional `reads` fixtures. The
  tenant checks of a read (flagged type, active definition, known fields) are
  `Letflow.Scripts.Policy.check_reads/2`'s (`:reads_not_allowed`).

  Every function returns `:ok` / `{:ok, value}` or `{:error, code}` with a stable code; no
  submitted value is ever echoed.
  """

  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.Scripts.Hash

  @manifest_keys ~w(input_schema output_schema fail_codes limits reads restricted_inputs writes)
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
  @max_restricted_from 8
  @max_writes 8
  @max_write_fields 32
  @max_write_name 128
  @write_modes ~w(update_self create upsert_by_external_ref)
  @max_schema_depth 8
  @max_schema_bytes 32_768
  @max_cases 32
  @max_case_name 64
  @max_case_input_bytes 16_384
  @max_cases_bytes 262_144
  @max_dry_run_input_bytes 65_536
  @max_reason_codepoints 500
  @reason_forbidden ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u
  @read_keys ~w(name entity_type match fields restricted_fields limit)
  @max_reads 8
  @max_read_fields 64
  @max_read_limit 50
  @max_read_rows 200
  @max_fixture_bytes 16_384
  @value_from_types ~w(string integer number boolean)

  # ── manifest (section 3) ───────────────────────────────────────────────────

  @doc """
  Validates a manifest map, including the SHAPE of `reads` (7b-2a section 3.1; every shape
  violation is `:invalid_manifest`).
  """
  @spec manifest(term()) :: :ok | {:error, atom()}
  def manifest(manifest) when is_map(manifest) do
    keys = Map.keys(manifest)

    cond do
      not Enum.all?(keys, &(&1 in @manifest_keys)) ->
        {:error, :invalid_manifest}

      not Enum.all?(@required_manifest_keys, &Map.has_key?(manifest, &1)) ->
        {:error, :invalid_manifest}

      true ->
        manifest_parts(manifest)
    end
  end

  def manifest(_other), do: {:error, :invalid_manifest}

  defp manifest_parts(manifest) do
    with :ok <- schema(manifest["input_schema"]),
         :ok <- schema(manifest["output_schema"]),
         :ok <- no_reserved_output_names(manifest["output_schema"]),
         :ok <- codes(manifest["fail_codes"], @max_fail_codes),
         :ok <- limits(Map.get(manifest, "limits", %{})),
         :ok <- restricted(Map.get(manifest, "restricted_inputs", []), manifest["input_schema"]),
         :ok <- reads(Map.get(manifest, "reads", []), manifest["input_schema"]),
         :ok <- writes(Map.get(manifest, "writes", [])) do
      :ok
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  # REQ-570 (decision 0067 D5): the write lines an `entity_event` script declares. Shape only; whether
  # the target type exists, is unmanaged and the fields are writable is checked at bind time.
  defp writes(list) when is_list(list) do
    if length(list) <= @max_writes and Enum.all?(list, &write_line?/1), do: :ok, else: :error
  end

  defp writes(_other), do: :error

  defp write_line?(%{"entity_type" => type, "mode" => mode, "fields" => fields} = line)
       when map_size(line) == 3 do
    write_name?(type) and mode in @write_modes and is_list(fields) and fields != [] and
      length(fields) <= @max_write_fields and Enum.uniq(fields) == fields and
      Enum.all?(fields, &write_name?/1)
  end

  defp write_line?(_line), do: false

  defp write_name?(name),
    do: is_binary(name) and name != "" and byte_size(name) <= @max_write_name

  # GH 2534 PR 7c-1 (C11): the top-level output key namespace `$` is reserved for host channels
  # (the designated future channel is `$writes`), so no output property may be named `$...`.
  defp no_reserved_output_names(%{"properties" => props}) when is_map(props) do
    if Enum.any?(Map.keys(props), &match?("$" <> _, &1)), do: :error, else: :ok
  end

  defp no_reserved_output_names(_schema), do: :ok

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

  # Decision 0062 R6 / Q4: each entry is `%{"name" => input property, "from" => [%{"entity_type",
  # "field"}]}`; the former list of bare names is retired.
  defp restricted(list, input_schema) when is_list(list) do
    properties = Map.get(input_schema, "properties", %{})
    names = Enum.map(list, &if(is_map(&1), do: Map.get(&1, "name")))

    if length(list) <= @max_restricted and Enum.uniq(names) == names and
         Enum.all?(list, &restricted_entry?(&1, properties)),
       do: :ok,
       else: :error
  end

  defp restricted(_other, _schema), do: :error

  defp restricted_entry?(%{"name" => name, "from" => from} = entry, properties)
       when map_size(entry) == 2 do
    code?(name) and Map.has_key?(properties, name) and is_list(from) and from != [] and
      length(from) <= @max_restricted_from and Enum.uniq(from) == from and
      Enum.all?(from, &from_pair?/1)
  end

  defp restricted_entry?(_entry, _properties), do: false

  defp from_pair?(%{"entity_type" => type, "field" => field} = pair) when map_size(pair) == 2,
    do: code?(type) and code?(field)

  defp from_pair?(_pair), do: false

  @doc """
  The `restricted_inputs` entries of a stored manifest, normalised to `%{"name", "from"}`
  (`from` a list of `%{"entity_type", "field"}`). A legacy bare-name entry reads as `from: []`
  (never delivered, fail closed); a malformed entry is dropped. Pure.
  """
  @spec restricted_input_entries(term()) :: [%{String.t() => term()}]
  def restricted_input_entries(%{} = manifest) do
    case Map.get(manifest, "restricted_inputs") do
      list when is_list(list) -> Enum.flat_map(list, &normalise_restricted_entry/1)
      _none -> []
    end
  end

  def restricted_input_entries(_manifest), do: []

  defp normalise_restricted_entry(name) when is_binary(name),
    do: [%{"name" => name, "from" => []}]

  defp normalise_restricted_entry(%{"name" => name, "from" => from})
       when is_binary(name) and is_list(from),
       do: [%{"name" => name, "from" => Enum.filter(from, &from_pair?/1)}]

  defp normalise_restricted_entry(_entry), do: []

  # ── reads (7b-2a section 3.1) ──────────────────────────────────────────────

  defp reads([], _input_schema), do: :ok

  defp reads(list, input_schema) when is_list(list) and length(list) <= @max_reads do
    properties = Map.get(input_schema, "properties", %{})

    cond do
      not Enum.all?(list, &read_entry?(&1, properties)) -> :error
      # From here on every entry is a valid map with a "name".
      not unique_names?(list) -> :error
      list |> Enum.map(&row_cap/1) |> Enum.sum() > @max_read_rows -> :error
      # Reserved: read results are delivered under input["reads"][name].
      Map.has_key?(properties, "reads") -> :error
      true -> :ok
    end
  end

  defp reads(_other, _input_schema), do: :error

  defp unique_names?(entries) do
    names = Enum.map(entries, &Map.fetch!(&1, "name"))
    Enum.uniq(names) == names
  end

  defp read_entry?(
         %{"name" => name, "entity_type" => entity_type, "match" => match, "fields" => fields} =
           entry,
         properties
       ) do
    Enum.all?(Map.keys(entry), &(&1 in @read_keys)) and code?(name) and code?(entity_type) and
      field_list?(fields, 1) and
      restricted_fields?(Map.get(entry, "restricted_fields", []), fields) and
      match_and_limit?(match, Map.get(entry, "limit", :absent), properties)
  end

  defp read_entry?(_entry, _properties), do: false

  defp field_list?(list, min) when is_list(list) do
    length(list) >= min and length(list) <= @max_read_fields and Enum.uniq(list) == list and
      Enum.all?(list, &read_field?/1)
  end

  defp field_list?(_other, _min), do: false

  defp restricted_fields?(list, fields),
    do: field_list?(list, 0) and Enum.all?(list, &(&1 in fields))

  # P13: "id" is never a readable field name (every delivered row carries the record id there).
  defp read_field?(name), do: code?(name) and name != "id"

  defp match_and_limit?(%{"id_from" => prop} = match, limit, properties)
       when map_size(match) == 1,
       do: limit in [:absent, 1] and input_prop?(properties, prop, ["string"])

  defp match_and_limit?(%{"field" => field, "value_from" => prop} = match, limit, properties)
       when map_size(match) == 2 do
    read_field?(field) and is_integer(limit) and limit >= 1 and limit <= @max_read_limit and
      input_prop?(properties, prop, @value_from_types)
  end

  defp match_and_limit?(_match, _limit, _properties), do: false

  defp input_prop?(properties, prop, types) do
    code?(prop) and
      case Map.get(properties, prop) do
        %{"type" => type} -> type in types
        _ -> false
      end
  end

  # The row cap of one (valid) read entry: its limit, or 1 for an id match.
  defp row_cap(%{"match" => %{"field" => _}, "limit" => limit}), do: limit
  defp row_cap(_entry), do: 1

  defp code?(value), do: is_binary(value) and Regex.match?(@code_pattern, value)

  @doc "The declared reads of a (valid) manifest; `[]` when it declares none."
  @spec declared_reads(map()) :: [map()]
  def declared_reads(manifest), do: Map.get(manifest, "reads", [])

  @doc """
  `input` as the script sees it: when the manifest declares reads, `input["reads"]` maps every
  declared read name to its fixture rows (`[]` when absent from `fixture`); otherwise `input`
  is returned unchanged (7b-1 behaviour). `fixture` must already be valid (`reads_fixture/2`).
  """
  @spec with_reads(map(), map() | nil, map()) :: map()
  def with_reads(input, fixture, manifest) do
    case declared_reads(manifest) do
      [] ->
        input

      declared ->
        fixture = fixture || %{}
        rows = Map.new(declared, &{&1["name"], Map.get(fixture, &1["name"], [])})
        Map.put(input, "reads", rows)
    end
  end

  @doc """
  A `reads` fixture (stored test case or dry-run, 7b-2a section 4): an object whose keys are
  declared read names, each a list of at most that read's row cap row objects whose keys are a
  subset of `["id" | fields]`; canonical size at most 16 KiB. Refused when the manifest declares
  no reads.
  """
  @spec reads_fixture(term(), map()) :: :ok | :error
  def reads_fixture(fixture, manifest) when is_map(fixture) do
    by_name = Map.new(declared_reads(manifest), &{&1["name"], &1})

    if by_name != %{} and byte_size(Hash.canon(fixture)) <= @max_fixture_bytes and
         Enum.all?(fixture, fn {name, rows} -> fixture_rows?(Map.get(by_name, name), rows) end),
       do: :ok,
       else: :error
  end

  def reads_fixture(_fixture, _manifest), do: :error

  defp fixture_rows?(nil, _rows), do: false

  defp fixture_rows?(read, rows) when is_list(rows) do
    allowed = ["id" | read["fields"]]

    length(rows) <= row_cap(read) and
      Enum.all?(rows, &(is_map(&1) and Enum.all?(Map.keys(&1), fn key -> key in allowed end)))
  end

  defp fixture_rows?(_read, _rows), do: false

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

  # 7b-2a section 4: an optional 4th key `reads` carries the case's read fixtures.
  defp valid_case?(%{"name" => name, "input" => input, "expect" => expect} = case, manifest)
       when map_size(case) in [3, 4] and is_binary(name) and is_map(input) do
    String.length(name) in 1..@max_case_name and
      byte_size(Hash.canon(input)) <= @max_case_input_bytes and
      JsonSchema.validate(input, manifest["input_schema"]) == [] and
      valid_expect?(expect, manifest) and
      (map_size(case) == 3 or
         (Map.has_key?(case, "reads") and reads_fixture(case["reads"], manifest) == :ok))
  end

  defp valid_case?(_case, _manifest), do: false

  defp valid_expect?(%{"output" => output} = expect, manifest)
       when map_size(expect) == 1 and is_map(output),
       do: JsonSchema.validate(output, manifest["output_schema"]) == []

  defp valid_expect?(%{"fail" => code} = expect, manifest) when map_size(expect) == 1,
    do: code in manifest["fail_codes"]

  defp valid_expect?(_expect, _manifest), do: false

  # ── dry-run input, reason, key ─────────────────────────────────────────────

  @doc """
  A dry-run input: a JSON object within the size cap satisfying `input_schema`, plus an optional
  `reads` fixture (`nil` = absent) under the stored-test-case fixture rules (7b-2a section 4).
  """
  @spec dry_run_input(term(), term(), map()) :: :ok | {:error, :invalid_input}
  def dry_run_input(input, reads_fixture, manifest) when is_map(input) do
    if byte_size(Hash.canon(input)) <= @max_dry_run_input_bytes and
         JsonSchema.validate(input, manifest["input_schema"]) == [] and
         (is_nil(reads_fixture) or reads_fixture(reads_fixture, manifest) == :ok),
       do: :ok,
       else: {:error, :invalid_input}
  end

  def dry_run_input(_input, _reads_fixture, _manifest), do: {:error, :invalid_input}

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
