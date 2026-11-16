defmodule Letflow.Modules.Stock.FormZ7 do
  @moduledoc """
  T-1925 (audit slice 9): the data of official form Z-7 (ru) / Q-7 (kk), annex 31 of order No. 562
  "stock balances sheet at the warehouse", for one location and one period. Pure: the sheet of
  `StockSheetSource.read/4` in, the data map of `Letflow.Documents.FormPrint` (form `z7`) out.
  Layout and wording are in `priv/print_forms/z7.json` and `messages.json`.

  Filled in: organisation name and BIN (when the printed legs belong to one legal entity), the
  warehouse (the location), the responsible person and the structural unit (when the printed legs
  point to exactly one), the date of the print (tenant zone), the period, and per item the name,
  code, unit of measure and the four quantities (opening, income, expense, closing). A zero
  quantity prints blank. Left out, so blank: the workshop and pantry, the document number (the
  sheet is not a document of record), the position, the signatures, column 5, the price, the stock
  norm and every sum (mapping doc G4, G5; nothing is invented). Not printed: column 15 and the
  further-period columns 16-27 (the print engine allows 14 columns; one period per sheet) and the
  "turnover" header level above income and expense (one header group level).
  """

  alias Letflow.Modules.Stock.CountPaperwork

  @spec data(%{header: map(), rows: [map()]}) :: map()
  def data(%{header: header, rows: rows}) do
    %{
      "org_name" => CountPaperwork.text(header[:org_name]),
      "org_bin" => CountPaperwork.text(header[:org_bin]),
      "warehouse" => CountPaperwork.text(header[:location_name]),
      "shop" => "",
      "mol" => CountPaperwork.text(header[:mol_name]),
      "mol_position" => "",
      "mol_sign" => "",
      "accountant" => "",
      "head" => [
        %{
          "number" => "",
          "made" => date(header[:made_on]),
          "period" => date(header[:from]) <> " – " <> date(header[:to]),
          "unit" => CountPaperwork.text(header[:struct_unit]),
          "shop" => "",
          "warehouse" => CountPaperwork.text(header[:location_name]),
          "pantry" => ""
        }
      ],
      "lines" => rows |> Enum.with_index(1) |> Enum.map(&line/1)
    }
  end

  defp line({row, n}) do
    %{
      "no" => Integer.to_string(n),
      "name" => CountPaperwork.text(row[:name]),
      "nom" => CountPaperwork.text(row[:nom]),
      "unit" => CountPaperwork.text(row[:unit]),
      "qty" => "",
      "price" => "",
      "norm" => "",
      "open_qty" => qty(row[:opening]),
      "open_sum" => "",
      "in_qty" => qty(row[:income]),
      "in_sum" => "",
      "out_qty" => qty(row[:expense]),
      "out_sum" => "",
      "close_qty" => qty(row[:closing])
    }
  end

  defp date(%Date{day: d, month: m, year: y}) do
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    "#{pad.(d)}.#{pad.(m)}.#{String.pad_leading(Integer.to_string(y), 4, "0")}"
  end

  defp date(_), do: ""

  defp qty(%Decimal{} = d), do: if(Decimal.eq?(d, 0), do: "", else: Decimal.to_string(d, :normal))
  defp qty(_), do: ""
end
