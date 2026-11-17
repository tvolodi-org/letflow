defmodule Letflow.Modules.Stock.Documents.QuickCountPosting do
  @moduledoc """
  REQ-854 / GH #4564: the pure helpers that turn an issued quick count document into the posting
  command of cause `count_set` and into the leg that command must produce. No database. Used by
  `Letflow.Modules.Stock.Documents.Posting`.

  `command/3` is built ONLY from the frozen content of the issued version. The one line becomes ONE
  leg: quantity = the absolute difference, a `to` side when the counted quantity is above the book,
  a `from` side when it is below, and `expected_on_hand` = the stored `book_quantity` (REQ-853): if
  anything moved the key between the count and the approval the core refuses `balance_changed`
  (stock alias `quick_count_stale`). It carries NO `device_id`, `client_seq` or `client_event_time`
  (the event time is the posting time) and the header's `reason_code`.

  A count equal to the book has no leg: `command/3` answers `:none` and `expected_legs/2` is empty.
  """

  @doc "True when the one line of `content` has a zero difference (a count that confirmed the book)."
  @spec confirmed?(map()) :: boolean()
  def confirmed?(content) do
    case line(content) do
      nil -> false
      line -> zero?(Map.get(line, "difference"))
    end
  end

  @doc "The posting command, `:none` for a zero difference, `{:error, :line_record_missing}` without the line record."
  @spec command(map(), map(), %{optional(integer()) => String.t()}) ::
          {:ok, map()} | :none | {:error, :line_record_missing}
  def command(view, %{content: content} = issued, line_ids) do
    header = Map.get(content, "header", %{})

    with %{} = line <- line(content),
         {:ok, line_id} <- Map.fetch(line_ids, Map.get(line, "line_no")) do
      if zero?(Map.get(line, "difference")) do
        :none
      else
        {:ok,
         %{
           "cause" => "count_set",
           "document_type" => "stock_quick_count",
           "document_id" => view.id,
           "client_op_id" => issued.version_id,
           "reason_code" => Map.get(header, "reason_code"),
           "lines" => [leg_line(line, line_id, header)]
         }}
      end
    else
      _missing -> {:error, :line_record_missing}
    end
  end

  defp leg_line(line, line_id, header) do
    difference = decimal(Map.get(line, "difference"))

    side = %{
      "org_unit" => Map.get(header, "org_unit_id"),
      "location" => Map.get(line, "location_id"),
      "responsible" => Map.get(line, "responsible_id")
    }

    base = %{
      "line_id" => line_id,
      "sku" => Map.get(line, "catalog_item_id"),
      "lot" => Map.get(line, "catalog_lot_id"),
      "unit" => Map.get(line, "catalog_uom_id"),
      "quantity" => difference |> Decimal.abs() |> Decimal.to_string(:normal),
      "expected_on_hand" => Map.get(line, "book_quantity")
    }

    if Decimal.lt?(difference, 0),
      do: Map.put(base, "from", side),
      else: Map.put(base, "to", side)
  end

  @doc """
  The expected legs of the frozen `content` as the tuple `leg_key` builds (the caller's function, one
  normal form for every kind): none for a zero difference, else one with the signed difference.
  """
  @spec expected_legs(map(), (term(), term(), term(), term(), term(), term(), term() -> tuple())) ::
          [tuple()]
  def expected_legs(content, leg_key) do
    header = Map.get(content, "header", %{})

    case line(content) do
      nil ->
        []

      line ->
        if zero?(Map.get(line, "difference")) do
          []
        else
          [
            leg_key.(
              Map.get(line, "catalog_item_id"),
              Map.get(line, "location_id"),
              Map.get(header, "org_unit_id"),
              Map.get(line, "responsible_id"),
              Map.get(line, "catalog_lot_id"),
              Map.get(line, "catalog_uom_id"),
              Map.get(line, "difference")
            )
          ]
        end
    end
  end

  defp line(content) do
    case Map.get(content, "lines") do
      [line | _] when is_map(line) -> line
      _other -> nil
    end
  end

  defp zero?(text), do: Decimal.eq?(decimal(text), 0)

  defp decimal(text) do
    case Decimal.parse(to_string(text)) do
      {%Decimal{} = d, ""} -> d
      _bad -> Decimal.new(0)
    end
  end
end
