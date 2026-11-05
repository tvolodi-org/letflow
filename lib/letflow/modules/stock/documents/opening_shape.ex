defmodule Letflow.Modules.Stock.Documents.OpeningShape do
  @moduledoc """
  REQ-725 / GH #3775: the pure shape check of the save and replace body of an opening balance
  document (kind `opening`). No database, no clock. Same refusal style as
  `Letflow.Modules.Stock.Documents.Shape`: `{:error, {reason, extras}}`, `extras` a map of the fixed
  keys `"field"` and `"line_no"`, a supplied value never echoed.

  Header keys: `kind`, `lines`, `org_unit_id` (required), `note`, `external_ref_system`,
  `external_ref_id`. There is NO event time (the ledger stamps the posting time, REQ-726), no
  location, no responsible and no counterparty on the header: those are per line. Line keys:
  `location_id`, `responsible_id`, `catalog_item_id`, `catalog_uom_id`, `received_on`, `quantity`
  (required), `catalog_lot_id`, `unit_price`, `line_value`, `external_ref_system`, `external_ref_id`
  (optional). Anything else is `field_not_allowed`.

  Order of refusals: `field_not_allowed`, `field_required`, `field_invalid`, `external_ref_pair`,
  `lines_count`, then per line in order `field_not_allowed`, `field_required`, `field_invalid`,
  `external_ref_pair`, `quantity_invalid`, `price_invalid`, and `field_invalid` for `received_on`.
  Quantity, price, value and `received_on` use the functions of `Shape` (one definition with the
  receipt). A real receipt date in the future is NOT a shape rule (it needs the clock: the check and
  issue reason `received_on_in_future`). Optional keys that are absent stay absent; `null` is refused.
  """

  alias Letflow.Modules.Stock.Documents.Shape

  @header_required ~w(org_unit_id)
  @header_optional ~w(note external_ref_system external_ref_id)
  @header_keys @header_required ++ @header_optional
  @line_required ~w(location_id responsible_id catalog_item_id catalog_uom_id received_on quantity)
  @line_optional ~w(catalog_lot_id unit_price line_value external_ref_system external_ref_id)
  @line_keys @line_required ++ @line_optional
  @line_ids ~w(location_id responsible_id catalog_item_id catalog_uom_id catalog_lot_id)
  @note_max 500
  @ref_max 128

  @spec parse(term(), :create | {:replace, String.t()}) ::
          {:ok, map()} | {:error, {String.t(), map()}}
  def parse(body, mode) when is_map(body) and not is_struct(body) do
    with :ok <- kind(body, mode),
         :ok <- allowed(body, ["kind", "lines" | @header_keys], %{}),
         :ok <- required(body, @header_required ++ ["lines"], %{}),
         {:ok, header} <- header(body),
         :ok <- ref_pair(header, %{}),
         {:ok, raw_lines} <- raw_lines(body["lines"]),
         {:ok, lines} <- lines(raw_lines) do
      {:ok, %{kind: "opening", header: header, lines: lines}}
    end
  end

  def parse(_body, _mode), do: refuse("field_invalid", %{"field" => "body"})

  defp kind(body, :create) do
    case Map.fetch(body, "kind") do
      {:ok, "opening"} -> :ok
      {:ok, _other} -> refuse("unknown_kind")
      :error -> refuse("field_required", %{"field" => "kind"})
    end
  end

  defp kind(body, {:replace, current}) do
    case Map.fetch(body, "kind") do
      :error -> :ok
      {:ok, ^current} -> :ok
      {:ok, _other} -> refuse("unknown_kind")
    end
  end

  defp allowed(map, keys, extras) do
    case map |> Map.keys() |> Enum.reject(&(&1 in keys)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> refuse("field_not_allowed", Map.put(extras, "field", printable(key)))
    end
  end

  defp required(map, keys, extras) do
    case Enum.find(keys, &(not Map.has_key?(map, &1))) do
      nil -> :ok
      key -> refuse("field_required", Map.put(extras, "field", key))
    end
  end

  # -- header -------------------------------------------------------------------------------------

  defp header(body) do
    Enum.reduce_while(@header_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(body, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case header_value(key, value) do
            {:ok, parsed} -> {:cont, {:ok, Map.put(acc, key, parsed)}}
            :error -> {:halt, refuse("field_invalid", %{"field" => key})}
          end
      end
    end)
  end

  defp header_value("org_unit_id", value), do: Shape.uuid(value)

  defp header_value("note", value) when is_binary(value) do
    note = String.valid?(value) && :unicode.characters_to_nfc_binary(value)
    if is_binary(note) and byte_size(note) <= @note_max, do: {:ok, note}, else: :error
  end

  defp header_value(key, value) when key in ~w(external_ref_system external_ref_id),
    do: ref_text(value)

  defp header_value(_key, _value), do: :error

  # 1..128 characters, NFC, no control character.
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

  # -- lines --------------------------------------------------------------------------------------

  defp raw_lines(lines) when is_list(lines) do
    if length(lines) in 1..Shape.max_lines(), do: {:ok, lines}, else: refuse("lines_count")
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
    extras = %{"line_no" => no}

    with :ok <- allowed(line, @line_keys, extras),
         :ok <- required(line, @line_required, extras),
         {:ok, ids} <- line_ids(line, no),
         {:ok, refs} <- line_refs(line, no),
         :ok <- ref_pair(refs, extras),
         {:ok, quantity} <- quantity(line["quantity"], no),
         {:ok, prices} <- prices(line, no),
         {:ok, received_on} <- received_on(line["received_on"], no) do
      {:ok,
       ids
       |> Map.merge(refs)
       |> Map.merge(prices)
       |> Map.put("line_no", no)
       |> Map.put("quantity", quantity)
       |> Map.put("received_on", received_on)}
    end
  end

  defp line(_line, no), do: refuse("field_invalid", %{"field" => "lines", "line_no" => no})

  defp line_ids(line, no) do
    Enum.reduce_while(@line_ids, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(line, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case Shape.uuid(value) do
            {:ok, id} -> {:cont, {:ok, Map.put(acc, key, id)}}
            :error -> {:halt, refuse("field_invalid", %{"field" => key, "line_no" => no})}
          end
      end
    end)
  end

  defp line_refs(line, no) do
    Enum.reduce_while(~w(external_ref_system external_ref_id), {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(line, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case ref_text(value) do
            {:ok, text} -> {:cont, {:ok, Map.put(acc, key, text)}}
            :error -> {:halt, refuse("field_invalid", %{"field" => key, "line_no" => no})}
          end
      end
    end)
  end

  defp quantity(text, no) do
    case Shape.quantity_text(text) do
      {:ok, value} -> {:ok, value}
      :error -> refuse("quantity_invalid", %{"line_no" => no})
    end
  end

  defp prices(line, no) do
    Enum.reduce_while(~w(unit_price line_value), {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(line, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, text} ->
          case Shape.price_text(text) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            :error -> {:halt, refuse("price_invalid", %{"field" => key, "line_no" => no})}
          end
      end
    end)
  end

  defp received_on(text, no) do
    case Shape.received_on_text(text) do
      {:ok, value} -> {:ok, value}
      :error -> refuse("field_invalid", %{"field" => "received_on", "line_no" => no})
    end
  end

  defp refuse(reason, extras \\ %{}), do: {:error, {reason, extras}}

  defp printable(key) when is_binary(key) do
    if String.printable?(key) and byte_size(key) <= 64, do: key, else: "?"
  end

  defp printable(_key), do: "?"
end
