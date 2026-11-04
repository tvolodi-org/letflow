defmodule Letflow.Modules.Stock.Documents.OpeningPosting do
  @moduledoc """
  REQ-726 / GH #3774: the pure helpers that turn an issued opening balance document into the posting
  command of cause `opening` and into the legs that command must produce. No database. Used by
  `Letflow.Modules.Stock.Documents.Posting`.

  `command/2` is built ONLY from the frozen content of the issued version. It carries NO `device_id`,
  `client_seq` or `client_event_time` (so the entry's event time is its posting time, decision 0079 D1)
  and NEVER the real receipt date, the price or the value of a line (they stay on the document). The location and
  the responsible employee are the line's own; the org unit is the header's.
  """

  @spec command(map(), map(), %{optional(integer()) => String.t()}) ::
          {:ok, map()} | {:error, :line_record_missing}
  def command(view, %{content: content} = issued, line_ids) do
    header = Map.get(content, "header", %{})

    content
    |> Map.get("lines", [])
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Map.fetch(line_ids, Map.get(line, "line_no")) do
        {:ok, line_id} -> {:cont, {:ok, [leg_line(line, line_id, header) | acc]}}
        :error -> {:halt, {:error, :line_record_missing}}
      end
    end)
    |> case do
      {:ok, acc} ->
        {:ok,
         %{
           "cause" => "opening",
           "document_type" => "stock_opening",
           "document_id" => view.id,
           "client_op_id" => issued.version_id,
           "lines" => Enum.reverse(acc)
         }}

      error ->
        error
    end
  end

  defp leg_line(line, line_id, header) do
    %{
      "line_id" => line_id,
      "sku" => Map.get(line, "catalog_item_id"),
      "lot" => Map.get(line, "catalog_lot_id"),
      "unit" => Map.get(line, "catalog_uom_id"),
      "quantity" => Map.get(line, "quantity"),
      "to" => %{
        "org_unit" => Map.get(header, "org_unit_id"),
        "location" => Map.get(line, "location_id"),
        "responsible" => Map.get(line, "responsible_id")
      }
    }
  end

  @doc """
  The expected legs of the frozen `content` as `{sku, location, org_unit, responsible, lot, unit,
  quantity}` tuples built by `leg_key` (the caller's function, so the receipt and the opening share
  one normal form).
  """
  @spec expected_legs(map(), (term(), term(), term(), term(), term(), term(), term() -> tuple())) ::
          [tuple()]
  def expected_legs(content, leg_key) do
    header = Map.get(content, "header", %{})

    for line <- Map.get(content, "lines", []) do
      leg_key.(
        Map.get(line, "catalog_item_id"),
        Map.get(line, "location_id"),
        Map.get(header, "org_unit_id"),
        Map.get(line, "responsible_id"),
        Map.get(line, "catalog_lot_id"),
        Map.get(line, "catalog_uom_id"),
        Map.get(line, "quantity")
      )
    end
  end
end
