defmodule Letflow.Modules.Stock.Documents.QuickCountPosting do
  @moduledoc """
  REQ-854 / GH #4564: the pure helpers that turn an issued quick count document into the posting
  command of cause `count_set` and into the legs that command must produce. No database. Used by
  `Letflow.Modules.Stock.Documents.Posting`.

  `command/3` is built ONLY from the frozen content of the issued version. Each non-zero-difference
  line becomes ONE leg: quantity = the absolute difference, a `to` side when the counted quantity is
  above the book, a `from` side when it is below, and `expected_on_hand` = the stored `book_quantity`
  (REQ-853): if anything moved the key between the count and the approval the core refuses
  `balance_changed` (stock alias `quick_count_stale`). It carries NO `device_id`, `client_seq` or
  `client_event_time` (the event time is the posting time) and the header's `reason_code`.

  A count equal to the book on ALL lines normally has no leg: `command/3` answers `:none` and
  `expected_legs/2` is empty. The old Qoimeks address alone uses `command/4` and `expected_legs/3`
  with `record_zero` true: its empty-shelf count then has one zero leg, because the old server stored
  that count as a real reversible movement rather than confirming it without a history row.

  REQ-885: a workbook-load quick count may have more than one line; each non-zero-diff line
  contributes one leg to the same posting command.
  """

  @doc "True when ALL lines of `content` have a zero difference (a count that confirmed the book)."
  @spec confirmed?(map()) :: boolean()
  def confirmed?(content) do
    case Map.get(content, "lines") do
      lines when is_list(lines) and lines != [] ->
        Enum.all?(lines, &zero?(Map.get(&1, "difference")))

      _other ->
        false
    end
  end

  @doc "The posting command, `:none` when all differences are zero, `{:error, :line_record_missing}` when a non-zero-diff line has no record id."
  @spec command(map(), map(), %{optional(integer()) => String.t()}) ::
          {:ok, map()} | :none | {:error, :line_record_missing}
  def command(view, issued, line_ids), do: command(view, issued, line_ids, false)

  @doc false
  @spec command(map(), map(), %{optional(integer()) => String.t()}, boolean()) ::
          {:ok, map()} | :none | {:error, :line_record_missing}
  def command(view, %{content: content} = issued, line_ids, record_zero) do
    header = Map.get(content, "header", %{})
    lines = Map.get(content, "lines", [])

    selected =
      if record_zero, do: lines, else: Enum.reject(lines, &zero?(Map.get(&1, "difference")))

    if selected == [] do
      :none
    else
      result =
        Enum.reduce_while(selected, {:ok, []}, fn line, {:ok, acc} ->
          case Map.fetch(line_ids, Map.get(line, "line_no")) do
            {:ok, line_id} -> {:cont, {:ok, [leg_line(line, line_id, header) | acc]}}
            :error -> {:halt, {:error, :line_record_missing}}
          end
        end)

      case result do
        {:ok, legs} ->
          command = %{
            "cause" => "count_set",
            "document_type" => "stock_quick_count",
            "document_id" => view.id,
            "client_op_id" => issued.version_id,
            "reason_code" => Map.get(header, "reason_code"),
            "lines" => Enum.reverse(legs)
          }

          {:ok, if(record_zero, do: Map.put(command, "record_zero", true), else: command)}

        {:error, reason} ->
          {:error, reason}
      end
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
  normal form for every kind): none for zero differences, else one per non-zero-difference line.
  """
  @spec expected_legs(map(), (term(), term(), term(), term(), term(), term(), term() -> tuple())) ::
          [tuple()]
  def expected_legs(content, leg_key), do: expected_legs(content, leg_key, false)

  @doc false
  @spec expected_legs(
          map(),
          (term(), term(), term(), term(), term(), term(), term() -> tuple()),
          boolean()
        ) :: [tuple()]
  def expected_legs(content, leg_key, record_zero) do
    header = Map.get(content, "header", %{})
    lines = Map.get(content, "lines", [])

    lines
    |> then(
      &if(record_zero,
        do: &1,
        else: Enum.reject(&1, fn line -> zero?(Map.get(line, "difference")) end)
      )
    )
    |> Enum.map(fn line ->
      leg_key.(
        Map.get(line, "catalog_item_id"),
        Map.get(line, "location_id"),
        Map.get(header, "org_unit_id"),
        Map.get(line, "responsible_id"),
        Map.get(line, "catalog_lot_id"),
        Map.get(line, "catalog_uom_id"),
        Map.get(line, "difference")
      )
    end)
  end

  defp zero?(text), do: Decimal.eq?(decimal(text), 0)

  defp decimal(text) do
    case Decimal.parse(to_string(text)) do
      {%Decimal{} = d, ""} -> d
      _bad -> Decimal.new(0)
    end
  end
end
