defmodule Letflow.Modules.Stock.Documents.QuickCountShape do
  @moduledoc """
  REQ-854 / GH #4564 (Qoimeks parity G5 part 2): the pure shape check of the body of
  `POST /quick-counts`. No database, no clock. Same refusal style as
  `Letflow.Modules.Stock.Documents.Shape`: `{:error, {reason, extras}}`, `extras` a map of the fixed key
  `"field"`, a supplied value never echoed.

  The body is flat (one line, no `lines` list). Required keys: `org_unit_id`, `location_id`,
  `catalog_item_id`, `catalog_uom_id`, `counted_quantity`, `reason_code`. Optional keys: `catalog_lot_id`,
  `responsible_id`, `reason_text`. Anything else (`kind` and the server-set `book_quantity`, `difference`,
  `document_id` included) is `field_not_allowed`.

  `counted_quantity` is a decimal string, 0 or more, at most 9 decimals (the limit of
  `Letflow.Ledger.Validate`); 0 is allowed here and only here (the other kinds keep `Shape.quantity_text/1`,
  which refuses it). It is returned with exactly 9 decimals, the form of a strict decimal field.
  `reason_code` is one of `recount`, `found`, `missing`, `damaged`, `other`; `reason_text` follows the
  write-off rule of `Shape` (1..500 characters, not blank, required for `other`); a missing or wrong
  `reason_code` or `reason_text` is `reason_invalid`.

  Order of refusals: `field_not_allowed`, `field_required`, `field_invalid` (ids), `quantity_invalid`,
  `reason_invalid`.
  """

  alias Letflow.Modules.Stock.Documents.Shape

  @required ~w(org_unit_id location_id catalog_item_id catalog_uom_id counted_quantity reason_code)
  @optional ~w(catalog_lot_id responsible_id reason_text)
  @ids ~w(org_unit_id location_id catalog_item_id catalog_uom_id catalog_lot_id responsible_id)
  @reasons ~w(recount found missing damaged other)
  @reason_text_max 500
  # byte bound first (INV-8): 500 characters of up to 4 bytes each; checked before any per-character work,
  # since a multipart text part reaches here up to 25 MiB and one grapheme can be megabytes of marks
  @reason_text_max_bytes @reason_text_max * 4
  @quantity ~r/\A(0|[1-9][0-9]{0,14})(\.[0-9]{1,9})?\z/

  @doc "The closed list of quick count reason codes."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc """
  Parses `body`. Returns `{:ok, %{kind: "quick_count", header: map, lines: [line]}}` with the same
  header-and-lines shape as the other kinds; the line has `line_no` 1, the ids and `counted_quantity`
  (the server adds `book_quantity` and `difference`).
  """
  @spec parse(term()) :: {:ok, map()} | {:error, {String.t(), map()}}
  def parse(body) when is_map(body) and not is_struct(body) do
    with :ok <- allowed(body),
         :ok <- required(body),
         {:ok, ids} <- ids(body),
         {:ok, counted} <- counted(body["counted_quantity"]),
         {:ok, reason} <- reason(body) do
      header = Map.merge(%{"org_unit_id" => ids["org_unit_id"]}, reason)

      line =
        ids
        |> Map.drop(["org_unit_id"])
        |> Map.put("line_no", 1)
        |> Map.put("counted_quantity", counted)

      {:ok, %{kind: "quick_count", header: header, lines: [line]}}
    end
  end

  def parse(_body), do: refuse("field_invalid", %{"field" => "body"})

  defp allowed(body) do
    case body |> Map.keys() |> Enum.reject(&(&1 in (@required ++ @optional))) |> Enum.sort() do
      [] -> :ok
      [key | _] -> refuse("field_not_allowed", %{"field" => printable(key)})
    end
  end

  defp required(body) do
    case Enum.find(@required, &(not Map.has_key?(body, &1))) do
      nil -> :ok
      "reason_code" -> refuse("reason_invalid")
      key -> refuse("field_required", %{"field" => key})
    end
  end

  defp ids(body) do
    Enum.reduce_while(@ids, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(body, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case Shape.uuid(value) do
            {:ok, id} -> {:cont, {:ok, Map.put(acc, key, id)}}
            :error -> {:halt, refuse("field_invalid", %{"field" => key})}
          end
      end
    end)
  end

  defp counted(text) when is_binary(text) do
    if Regex.match?(@quantity, text),
      do: {:ok, text |> Decimal.new() |> decimal_text()},
      else: refuse("quantity_invalid", %{"field" => "counted_quantity"})
  end

  defp counted(_other), do: refuse("quantity_invalid", %{"field" => "counted_quantity"})

  @doc "The text of `value` with exactly 9 decimals (the form of a strict decimal field), `-` kept."
  @spec decimal_text(Decimal.t()) :: String.t()
  def decimal_text(%Decimal{} = value) do
    value |> Decimal.round(9) |> Decimal.to_string(:normal) |> nine()
  end

  # `Decimal.to_string(:normal)` of a rounded value keeps the scale it had; pad to exactly 9 decimals.
  defp nine(text) do
    case String.split(text, ".", parts: 2) do
      [whole] -> whole <> "." <> String.duplicate("0", 9)
      [whole, frac] -> whole <> "." <> String.pad_trailing(frac, 9, "0")
    end
  end

  defp reason(body) do
    code = body["reason_code"]

    with true <- code in @reasons,
         {:ok, text} <- reason_text(Map.fetch(body, "reason_text")),
         true <- code != "other" or is_binary(text) do
      {:ok,
       %{"reason_code" => code}
       |> then(fn header -> if text, do: Map.put(header, "reason_text", text), else: header end)}
    else
      _bad -> refuse("reason_invalid")
    end
  end

  defp reason_text(:error), do: {:ok, nil}

  defp reason_text({:ok, value})
       when is_binary(value) and byte_size(value) <= @reason_text_max_bytes do
    text = String.valid?(value) && :unicode.characters_to_nfc_binary(value)

    if is_binary(text) and String.trim(text) != "" and String.length(text) <= @reason_text_max,
      do: {:ok, text},
      else: :error
  end

  defp reason_text(_other), do: :error

  defp refuse(reason, extras \\ %{}), do: {:error, {reason, extras}}

  defp printable(key) when is_binary(key) do
    if String.printable?(key) and byte_size(key) <= 64, do: key, else: "?"
  end

  defp printable(_key), do: "?"
end
