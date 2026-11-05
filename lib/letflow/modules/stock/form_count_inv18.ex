defmodule Letflow.Modules.Stock.FormCountInv18 do
  @moduledoc """
  T-1418 (phase E, E5d): the data of official form Inv-18 (ru) / Tug-18 (kk), annex 49 of order
  No. 562, "reconciliation sheet of stock count results", for the ISSUED `differences` document of
  a count. Pure: the output of `CountPaperworkSource.read_form/4` in, the data map of
  `Letflow.Documents.FormPrint` (form `inv18`) out. Layout and wording are in
  `priv/print_forms/inv18.json` and `messages.json`.

  Filled from Letflow: organisation name and BIN, number and date of the differences document, the
  count date (cut-off), the order number and date, the responsible persons of the lines (name and
  position, only the ones the caller's scope shows), line number, item name and code, unit, and
  the quantity of the surplus or the shortage of each line. Left blank (never invented): all
  sums (no price on count lines, gap G5), accounts and accounting corrections (G6, G15), the
  regrading table of the back side, the accountant, every signature, the IIN (G1).
  """

  alias Letflow.Modules.Stock.CountPaperwork
  alias Letflow.Modules.Stock.FormCount

  @spec data(map(), map()) :: map()
  def data(issued, names) do
    content = Map.get(issued, :content, %{})
    order_content = Map.get(issued, :order_content, %{})
    lines = FormCount.lines(content)
    {order_no, order_date} = FormCount.order(names)

    # The same set and order as the "responsible" signers of the xlsx and the PDF.
    responsible =
      :differences
      |> CountPaperwork.signers(order_content, lines)
      |> Enum.flat_map(fn
        {"responsible", id} -> [id]
        _ -> []
      end)
      |> then(&FormCount.people(names, &1))

    Map.merge(FormCount.org(content, order_content, names), %{
      "number" => FormCount.text(issued[:number_label]),
      "date" => FormCount.date_of(issued[:issued_at], names, :issued_at),
      "count_date" => FormCount.date_of(content["cut_off_at"], names, :cut_off_at),
      "order" => order_text(order_date, order_no),
      "lines" => Enum.map(lines, &row(&1, names)),
      "regrade" => [%{}, %{}]
    })
    |> Map.merge(FormCount.signature("responsible", responsible))
  end

  defp order_text("", ""), do: ""
  defp order_text(date, ""), do: date
  defp order_text("", no), do: "№ " <> no
  defp order_text(date, no), do: date <> " № " <> no

  defp row(line, names) do
    {surplus, shortage} =
      case line["direction"] do
        "surplus" -> {FormCount.abs_text(line["difference"]), ""}
        "shortage" -> {"", FormCount.abs_text(line["difference"])}
        _ -> {"", ""}
      end

    line
    |> FormCount.line_cells(names)
    |> Map.merge(%{"surplus_qty" => surplus, "shortage_qty" => shortage})
  end
end
