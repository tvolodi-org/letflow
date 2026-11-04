defmodule Letflow.Modules.Stock.Documents.Shape do
  @moduledoc """
  REQ-712 / GH #3749: the pure shape check of a stock document request body (save and replace).
  No database, no clock. `parse/2` returns the normalised document or the first refusal, in the order
  of the entry: `unknown_kind`, `field_not_allowed`, `field_required`, `field_invalid`,
  `event_time_invalid`, `lines_count`, `quantity_invalid`.

  A refusal is `{:error, {reason, extras}}` with `reason` one of the strings above and `extras` a
  map of fixed keys (`"field"`, `"line_no"`); a supplied value is never echoed. `field_invalid` and
  `event_time_invalid` are additions to the entry's closed list (an unparseable value has to be refused
  with some reason; assumption, owner may change at GATE B).

  Server-set keys (`document_id`, `header_id`, `line_no`, `number`, `state`, anything else) are
  `field_not_allowed`. Ids are canonical lowercase uuid text. `event_time` is ISO 8601 with an offset
  and is returned as UTC text without fraction (`2026-11-04T10:00:00Z`), year 2000..2100. Strings of the
  header are NFC-normalised once here so the saved record and the versioned content are the same bytes.
  A quantity is a decimal string (no float, no number) that is greater than zero and has at most 9
  decimals; it is stored and rendered with exactly 9 decimals (`10.5` becomes `10.500000000`, the form of a
  strict decimal field) so the record and the versioned content are the same text.
  """

  @kinds ["receipt"]
  @max_lines 100
  @note_max 500
  @header_required ~w(org_unit_id location_id responsible_id event_time)
  @header_optional ~w(counterparty_id note)
  @header_keys @header_required ++ @header_optional
  @id_keys ~w(org_unit_id location_id responsible_id counterparty_id)
  @line_required ~w(catalog_item_id catalog_uom_id quantity)
  @line_keys @line_required ++ ["catalog_lot_id"]
  @quantity ~r/\A(0|[1-9][0-9]{0,14})(\.[0-9]{1,9})?\z/

  @type refusal :: {:error, {String.t(), map()}}

  @doc "The closed set of document kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The line cap."
  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @doc """
  Parses `body`. `mode` is `:create` (kind required) or `{:replace, kind}` (kind optional, but it must
  equal the document's). Returns `{:ok, %{kind: kind, header: map, lines: [map]}}`; lines carry their
  `line_no` (position, 1..n).
  """
  @spec parse(term(), :create | {:replace, String.t()}) :: {:ok, map()} | refusal()
  def parse(body, mode) when is_map(body) and not is_struct(body) do
    with {:ok, kind} <- kind(body, mode),
         :ok <- allowed(body),
         :ok <- required(body),
         {:ok, header} <- header(body),
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
      {:ok, kind} when kind in @kinds -> {:ok, kind}
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

  defp allowed(body) do
    case body
         |> Map.keys()
         |> Enum.reject(&(&1 in ["kind", "lines" | @header_keys]))
         |> Enum.sort() do
      [] -> :ok
      [key | _] -> refuse("field_not_allowed", %{"field" => printable(key)})
    end
  end

  defp required(body) do
    case Enum.find(@header_required ++ ["lines"], &(not Map.has_key?(body, &1))) do
      nil -> :ok
      key -> refuse("field_required", %{"field" => key})
    end
  end

  # -- header -------------------------------------------------------------------------------------

  defp header(body) do
    Enum.reduce_while(@header_keys -- ["event_time"], {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(body, key) do
        :error -> {:cont, {:ok, acc}}
        {:ok, value} -> header_value(key, value, acc)
      end
    end)
  end

  defp header_value(key, value, acc) when key in @id_keys do
    case uuid(value) do
      {:ok, id} -> {:cont, {:ok, Map.put(acc, key, id)}}
      :error -> {:halt, refuse("field_invalid", %{"field" => key})}
    end
  end

  defp header_value("note", value, acc) when is_binary(value) do
    note = :unicode.characters_to_nfc_binary(value)

    if String.valid?(value) and is_binary(note) and byte_size(note) <= @note_max,
      do: {:cont, {:ok, Map.put(acc, "note", note)}},
      else: {:halt, refuse("field_invalid", %{"field" => "note"})}
  end

  defp header_value(key, _value, _acc), do: {:halt, refuse("field_invalid", %{"field" => key})}

  @doc "Canonical lowercase uuid text of a binary, else `:error`."
  @spec uuid(term()) :: {:ok, String.t()} | :error
  def uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  def uuid(_other), do: :error

  @doc "UTC text without fraction of an ISO 8601 time with an offset, else `:error`."
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
      :error -> refuse("event_time_invalid")
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
         {:ok, ids} <- line_ids(line, no),
         {:ok, quantity} <- quantity(line["quantity"], no) do
      {:ok, ids |> Map.put("line_no", no) |> Map.put("quantity", quantity)}
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
    case Enum.find(@line_required, &(not Map.has_key?(line, &1))) do
      nil -> :ok
      key -> refuse("field_required", %{"field" => key, "line_no" => no})
    end
  end

  defp line_ids(line, no) do
    Enum.reduce_while(["catalog_item_id", "catalog_uom_id", "catalog_lot_id"], {:ok, %{}}, fn key,
                                                                                              {:ok,
                                                                                               acc} ->
      case Map.fetch(line, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case uuid(value) do
            {:ok, id} -> {:cont, {:ok, Map.put(acc, key, id)}}
            :error -> {:halt, refuse("field_invalid", %{"field" => key, "line_no" => no})}
          end
      end
    end)
  end

  defp quantity(text, no) when is_binary(text) do
    if Regex.match?(@quantity, text) and Decimal.gt?(Decimal.new(text), 0),
      do: {:ok, text |> Decimal.new() |> Decimal.round(9) |> Decimal.to_string(:normal)},
      else: refuse("quantity_invalid", %{"line_no" => no})
  end

  defp quantity(_other, no), do: refuse("quantity_invalid", %{"line_no" => no})

  defp refuse(reason, extras \\ %{}), do: {:error, {reason, extras}}

  # A key name from the body is echoed only when it is short printable text.
  defp printable(key) when is_binary(key) do
    if String.printable?(key) and byte_size(key) <= 64, do: key, else: "?"
  end

  defp printable(_key), do: "?"
end
