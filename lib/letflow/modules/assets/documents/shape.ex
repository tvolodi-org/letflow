defmodule Letflow.Modules.Assets.Documents.Shape do
  @moduledoc """
  GH #3891 / REQ-751 (assets C10): the pure shape check of an asset document request body (save and
  replace). No database, no clock. Mirrors `Letflow.Modules.Stock.Documents.Shape` for the asset
  kinds. `parse/2` returns the normalised document or the first refusal, in this order:
  `unknown_kind`, `field_not_allowed`, `field_required`, `field_invalid`, `reason_invalid`,
  `reason_required` (write off only), `event_time_invalid`, `lines_count`.

  A refusal is `{:error, {reason, extras}}` with `extras` a map of the fixed keys `"field"` and
  `"line_no"`; a supplied value is never echoed. Server-set keys (`document_id`, `header_id`,
  `line_no`, `number`, `state`, `tenant`, `prefix`, anything else) are `field_not_allowed`. Ids are
  canonical lowercase uuid text. An empty `location_id` or `actual_user_id` is the same as absent
  (the key is dropped). `event_time` is ISO 8601 with an offset and is returned as UTC text without
  fraction, year 2000..2100. A line is `asset_id` and `quantity`; `quantity` is a decimal string
  (no number, no float) with at most 9 decimals, stored with exactly 9 decimals (the form of a strict
  decimal field). The VALUE rule of the quantity (whole, above zero, 1 for fixed and intangible
  assets) is an issue check (`Checks`, `quantity_invalid`). `line_no` is the position 1..n.

  The line keys come from the kind table (`Kinds`, `line_keys` / `line_required`). A change of kind
  (`kind_change`, REQ-759) line has sixteen body keys: ids are canonical uuid text (an empty
  `catalog_lot_id` or `actual_user_id` is absent), `target_kind` is `low_value` or `fixed`,
  `inventory_number` (1..64 bytes) and `asset_name` (1..200 bytes) are NFC trimmed text, and an absent
  `asset_org_unit_id` is the header's org unit. `asset_card_id` is server-set and `field_not_allowed`.
  An opening (G5 part 1) has no `event_time`; its line is `asset_id`, `quantity`, `material_responsible_id`
  and the optional `location_id` and `actual_user_id` (an empty one is absent).
  """

  alias Letflow.Modules.Assets.Documents.Kinds

  @max_lines 100
  @note_max 500
  @line_optional_empty ~w(catalog_lot_id actual_user_id location_id external_ref_system external_ref_id)
  @target_kinds ~w(low_value fixed)
  @inventory_number_max 64
  @asset_name_max 200
  @quantity ~r/\A(0|[1-9][0-9]{0,14})(\.[0-9]{1,9})?\z/
  @ref_keys ~w(external_ref_system external_ref_id)
  @ref_max 128
  @optional_empty ~w(external_ref_system external_ref_id location_id actual_user_id from_location_id to_location_id from_actual_user_id to_actual_user_id)
  @reason_text_max 500
  @reason_codes ~w(disposed lost broken expired other)

  @type refusal :: {:error, {String.t(), map()}}

  @doc "The line cap (equals the ledger policy's line cap)."
  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @doc """
  Parses `body`. `mode` is `:create` (kind required) or `{:replace, kind}` (kind optional, but it must
  equal the document's). Returns `{:ok, %{kind: kind, header: map, lines: [map]}}`.
  """
  @spec parse(term(), :create | {:replace, String.t()}) :: {:ok, map()} | refusal()
  def parse(body, mode) when is_map(body) and not is_struct(body) do
    with {:ok, kind} <- kind(body, mode),
         spec = Kinds.get(kind),
         :ok <- allowed(body, spec),
         :ok <- required(body, spec),
         {:ok, header} <- header(body, spec),
         {:ok, header} <- reason(header, spec),
         :ok <- ref_pair(header, %{"field" => "external_ref_id"}),
         {:ok, header} <- with_event_time(header, body, spec),
         {:ok, raw_lines} <- raw_lines(body["lines"]),
         {:ok, lines} <- lines(raw_lines, spec, header),
         :ok <- distinct_refs(lines) do
      {:ok, %{kind: kind, header: header, lines: lines}}
    end
  end

  def parse(_body, _mode), do: refuse("field_invalid", %{"field" => "body"})

  # -- kind ---------------------------------------------------------------------------------------

  defp kind(body, :create) do
    case Map.fetch(body, "kind") do
      {:ok, kind} when is_binary(kind) -> known_kind(kind)
      {:ok, _other} -> refuse("unknown_kind")
      :error -> refuse("field_required", %{"field" => "kind"})
    end
  end

  defp kind(body, {:replace, current}) do
    case Map.fetch(body, "kind") do
      :error -> {:ok, current}
      {:ok, ^current} -> {:ok, current}
      {:ok, _other} -> refuse("unknown_kind")
    end
  end

  defp known_kind(kind) do
    if Kinds.get(kind), do: {:ok, kind}, else: refuse("unknown_kind")
  end

  defp allowed(body, spec) do
    case body
         |> Map.keys()
         |> Enum.reject(&(&1 in ["kind", "lines" | spec.header_keys]))
         |> Enum.sort() do
      [] -> :ok
      [key | _] -> refuse("field_not_allowed", %{"field" => printable(key)})
    end
  end

  defp required(body, spec) do
    case Enum.find(spec.required ++ ["lines"], &(not Map.has_key?(body, &1))) do
      nil -> :ok
      key -> refuse("field_required", %{"field" => key})
    end
  end

  # -- header -------------------------------------------------------------------------------------

  defp header(body, spec) do
    Enum.reduce_while(spec.header_keys -- ["event_time"], {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(body, key) do
        :error -> {:cont, {:ok, acc}}
        {:ok, value} -> header_value(key, value, acc, spec)
      end
    end)
  end

  defp header_value(key, "", acc, _spec) when key in @optional_empty, do: {:cont, {:ok, acc}}

  defp header_value("reason_code", value, acc, _spec) do
    if value in @reason_codes,
      do: {:cont, {:ok, Map.put(acc, "reason_code", value)}},
      else: {:halt, refuse("reason_invalid", %{"field" => "reason_code"})}
  end

  defp header_value("reason_text", value, acc, _spec) when is_binary(value) do
    text = :unicode.characters_to_nfc_binary(value)

    cond do
      not String.valid?(value) or not is_binary(text) or byte_size(text) > @reason_text_max ->
        {:halt, refuse("field_invalid", %{"field" => "reason_text"})}

      String.trim(text) == "" ->
        {:cont, {:ok, acc}}

      true ->
        {:cont, {:ok, Map.put(acc, "reason_text", text)}}
    end
  end

  defp header_value("note", value, acc, _spec) when is_binary(value) do
    note = :unicode.characters_to_nfc_binary(value)

    if String.valid?(value) and is_binary(note) and byte_size(note) <= @note_max,
      do: {:cont, {:ok, Map.put(acc, "note", note)}},
      else: {:halt, refuse("field_invalid", %{"field" => "note"})}
  end

  defp header_value(key, value, acc, _spec) when key in @ref_keys do
    case ref_text(value) do
      {:ok, text} -> {:cont, {:ok, Map.put(acc, key, text)}}
      :error -> {:halt, refuse("field_invalid", %{"field" => key})}
    end
  end

  defp header_value(key, value, acc, spec) do
    with true <- key in spec.id_keys,
         {:ok, id} <- uuid(value) do
      {:cont, {:ok, Map.put(acc, key, id)}}
    else
      _bad -> {:halt, refuse("field_invalid", %{"field" => key})}
    end
  end

  # Write off only: the reason `other` needs a text.
  defp reason(%{"reason_code" => "other"} = header, _spec) do
    if Map.has_key?(header, "reason_text"),
      do: {:ok, header},
      else: refuse("reason_required", %{"field" => "reason_text"})
  end

  defp reason(header, _spec), do: {:ok, header}

  @doc "Canonical lowercase uuid text of a binary, else `:error`."
  @spec uuid(term()) :: {:ok, String.t()} | :error
  def uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  def uuid(_other), do: :error

  @doc "The UTC time (no fraction) of an ISO 8601 text with an offset, else `:error`."
  @spec parse_event_time(term()) :: {:ok, DateTime.t()} | :error
  def parse_event_time(text) when is_binary(text) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(text),
         true <- at.year in 2000..2100 do
      {:ok, DateTime.truncate(at, :second)}
    else
      _bad -> :error
    end
  end

  def parse_event_time(_other), do: :error

  # The opening header has no `event_time` (decision 0083 D1): with the key absent from the kind's
  # `header_keys` a body carrying it is already `field_not_allowed`.
  defp with_event_time(header, body, spec) do
    if "event_time" in spec.header_keys do
      with {:ok, event_time} <- event_time(body["event_time"]),
           do: {:ok, Map.put(header, "event_time", event_time)}
    else
      {:ok, header}
    end
  end

  defp event_time(text) do
    case parse_event_time(text) do
      {:ok, at} -> {:ok, DateTime.to_iso8601(at)}
      :error -> refuse("field_invalid", %{"field" => "event_time"})
    end
  end

  # -- lines --------------------------------------------------------------------------------------

  defp raw_lines(lines) when is_list(lines) do
    if length(lines) in 1..@max_lines,
      do: {:ok, lines},
      else: refuse("lines_count")
  end

  defp raw_lines(_other), do: refuse("field_invalid", %{"field" => "lines"})

  defp lines(raw, spec, header) do
    raw
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, no}, {:ok, acc} ->
      case line(line, no, spec, header) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp line(line, no, spec, header) when is_map(line) and not is_struct(line) do
    with :ok <- line_allowed(line, no, spec),
         :ok <- line_required(line, no, spec),
         {:ok, values} <- line_values(line, no, spec),
         :ok <- ref_pair(values, %{"field" => "external_ref_id", "line_no" => no}) do
      {:ok, values |> default_asset_unit(header) |> Map.put("line_no", no)}
    end
  end

  defp line(_line, no, _spec, _header),
    do: refuse("field_invalid", %{"field" => "lines", "line_no" => no})

  defp line_allowed(line, no, spec) do
    case line |> Map.keys() |> Enum.reject(&(&1 in spec.line_keys)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> refuse("field_not_allowed", %{"field" => printable(key), "line_no" => no})
    end
  end

  defp line_required(line, no, spec) do
    case Enum.find(spec.line_required, &(not Map.has_key?(line, &1))) do
      nil -> :ok
      key -> refuse("field_required", %{"field" => key, "line_no" => no})
    end
  end

  # Values in `spec.line_keys` order; an optional id given as "" is dropped.
  defp line_values(line, no, spec) do
    Enum.reduce_while(spec.line_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(line, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, ""} when key in @line_optional_empty ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case line_value(key, value) do
            {:ok, parsed} -> {:cont, {:ok, Map.put(acc, key, parsed)}}
            :error -> {:halt, refuse("field_invalid", %{"field" => key, "line_no" => no})}
          end
      end
    end)
  end

  defp line_value("quantity", text) do
    if is_binary(text) and Regex.match?(@quantity, text),
      do: {:ok, text |> Decimal.new() |> Decimal.round(9) |> Decimal.to_string(:normal)},
      else: :error
  end

  defp line_value(key, value) when key in @ref_keys, do: ref_text(value)
  defp line_value("target_kind", value) when value in @target_kinds, do: {:ok, value}
  defp line_value("target_kind", _value), do: :error
  defp line_value("inventory_number", value), do: text(value, @inventory_number_max)
  defp line_value("asset_name", value), do: text(value, @asset_name_max)
  defp line_value(_id_key, value), do: uuid(value)

  # NFC, trimmed, 1..max bytes; the value is stored as trimmed text.
  defp text(value, max) when is_binary(value) do
    nfc = :unicode.characters_to_nfc_binary(value)

    with true <- String.valid?(value) and is_binary(nfc),
         trimmed = String.trim(nfc),
         true <- byte_size(trimmed) in 1..max do
      {:ok, trimmed}
    else
      _bad -> :error
    end
  end

  defp text(_value, _max), do: :error

  # The external reference pair (opening header and line only; other kinds refuse the keys as not
  # allowed): 1..128 characters, NFC, no control character.
  defp ref_text(value) when is_binary(value) do
    text = String.valid?(value) && :unicode.characters_to_nfc_binary(value)

    if is_binary(text) and String.length(text) in 1..@ref_max and
         not String.match?(text, ~r/[\x00-\x1f\x7f]/),
       do: {:ok, text},
       else: :error
  end

  defp ref_text(_other), do: :error

  # Exactly both or neither of the pair.
  defp ref_pair(map, extras) do
    if Map.has_key?(map, "external_ref_system") == Map.has_key?(map, "external_ref_id"),
      do: :ok,
      else: refuse("external_ref_pair", extras)
  end

  # Two lines of one body must not carry the same pair (the import finds a line by its pair).
  defp distinct_refs(lines) do
    lines
    |> Enum.filter(&Map.has_key?(&1, "external_ref_id"))
    |> Enum.reduce_while(MapSet.new(), fn line, seen ->
      pair = {line["external_ref_system"], line["external_ref_id"]}

      if MapSet.member?(seen, pair),
        do:
          {:halt,
           refuse("field_invalid", %{"field" => "external_ref_id", "line_no" => line["line_no"]})},
        else: {:cont, MapSet.put(seen, pair)}
    end)
    |> case do
      {:error, _} = error -> error
      _seen -> :ok
    end
  end

  # A change of kind line without an asset org unit takes the header's.
  defp default_asset_unit(%{"inventory_number" => _} = values, header),
    do: Map.put_new(values, "asset_org_unit_id", header["org_unit_id"])

  defp default_asset_unit(values, _header), do: values

  defp refuse(reason, extras \\ %{}), do: {:error, {reason, extras}}

  # A key name from the body is echoed only when it is short printable text.
  defp printable(key) when is_binary(key) do
    if String.printable?(key) and byte_size(key) <= 64, do: key, else: "?"
  end

  defp printable(_key), do: "?"
end
