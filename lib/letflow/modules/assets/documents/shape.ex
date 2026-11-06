defmodule Letflow.Modules.Assets.Documents.Shape do
  @moduledoc """
  GH #3891 / REQ-751 (assets C10): the pure shape check of an asset document request body (save and
  replace). No database, no clock. Mirrors `Letflow.Modules.Stock.Documents.Shape` for the asset
  kinds. `parse/2` returns the normalised document or the first refusal, in this order:
  `unknown_kind`, `field_not_allowed`, `field_required`, `field_invalid`, `event_time_invalid`,
  `lines_count`.

  A refusal is `{:error, {reason, extras}}` with `extras` a map of the fixed keys `"field"` and
  `"line_no"`; a supplied value is never echoed. Server-set keys (`document_id`, `header_id`,
  `line_no`, `number`, `state`, `tenant`, `prefix`, anything else) are `field_not_allowed`. Ids are
  canonical lowercase uuid text. An empty `location_id` or `actual_user_id` is the same as absent
  (the key is dropped). `event_time` is ISO 8601 with an offset and is returned as UTC text without
  fraction, year 2000..2100. A line is `asset_id` and `quantity`; `quantity` is a decimal string
  (no number, no float) with at most 9 decimals, stored with exactly 9 decimals (the form of a strict
  decimal field). The VALUE rule of the quantity (whole, above zero, 1 for fixed and intangible
  assets) is an issue check (`Checks`, `quantity_invalid`). `line_no` is the position 1..n.
  """

  alias Letflow.Modules.Assets.Documents.Kinds

  @max_lines 100
  @note_max 500
  @line_keys ~w(asset_id quantity)
  @quantity ~r/\A(0|[1-9][0-9]{0,14})(\.[0-9]{1,9})?\z/
  @optional_empty ~w(location_id actual_user_id)

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
         {:ok, event_time} <- event_time(body["event_time"]),
         {:ok, raw_lines} <- raw_lines(body["lines"]),
         {:ok, lines} <- lines(raw_lines) do
      {:ok, %{kind: kind, header: Map.put(header, "event_time", event_time), lines: lines}}
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

  defp header_value("note", value, acc, _spec) when is_binary(value) do
    note = :unicode.characters_to_nfc_binary(value)

    if String.valid?(value) and is_binary(note) and byte_size(note) <= @note_max,
      do: {:cont, {:ok, Map.put(acc, "note", note)}},
      else: {:halt, refuse("field_invalid", %{"field" => "note"})}
  end

  defp header_value(key, value, acc, spec) do
    with true <- key in spec.id_keys,
         {:ok, id} <- uuid(value) do
      {:cont, {:ok, Map.put(acc, key, id)}}
    else
      _bad -> {:halt, refuse("field_invalid", %{"field" => key})}
    end
  end

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

  defp lines(raw) do
    raw
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, no}, {:ok, acc} ->
      case line(line, no) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp line(line, no) when is_map(line) and not is_struct(line) do
    with :ok <- line_allowed(line, no),
         :ok <- line_required(line, no),
         {:ok, asset} <- asset_id(line["asset_id"], no),
         {:ok, quantity} <- quantity(line["quantity"], no) do
      {:ok, %{"line_no" => no, "asset_id" => asset, "quantity" => quantity}}
    end
  end

  defp line(_line, no), do: refuse("field_invalid", %{"field" => "lines", "line_no" => no})

  defp line_allowed(line, no) do
    case line |> Map.keys() |> Enum.reject(&(&1 in @line_keys)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> refuse("field_not_allowed", %{"field" => printable(key), "line_no" => no})
    end
  end

  defp line_required(line, no) do
    case Enum.find(@line_keys, &(not Map.has_key?(line, &1))) do
      nil -> :ok
      key -> refuse("field_required", %{"field" => key, "line_no" => no})
    end
  end

  defp asset_id(value, no) do
    case uuid(value) do
      {:ok, id} -> {:ok, id}
      :error -> refuse("field_invalid", %{"field" => "asset_id", "line_no" => no})
    end
  end

  defp quantity(text, no) do
    if is_binary(text) and Regex.match?(@quantity, text),
      do: {:ok, text |> Decimal.new() |> Decimal.round(9) |> Decimal.to_string(:normal)},
      else: refuse("field_invalid", %{"field" => "quantity", "line_no" => no})
  end

  defp refuse(reason, extras \\ %{}), do: {:error, {reason, extras}}

  # A key name from the body is echoed only when it is short printable text.
  defp printable(key) when is_binary(key) do
    if String.printable?(key) and byte_size(key) <= 64, do: key, else: "?"
  end

  defp printable(_key), do: "?"
end
