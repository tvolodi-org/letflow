defmodule Letflow.Modules.Stock.FormZ3 do
  @moduledoc """
  T-1417 (phase E, E5c): the data of official form Z-3 (ru) / Q-3 (kk), annex 27 of order No. 562
  "stock card", for one item at one place. Pure: the card of `StockCardSource.read/4` in, the data
  map of `Letflow.Documents.FormPrint` (form `z3`) out. Layout and wording are in
  `priv/print_forms/z3.json` and `messages.json`.

  Filled in: organisation name and BIN, structural unit, item name and code, unit of measure, the
  lot's mark and expiry date when a lot was asked for, and per movement the date (`DD.MM.YYYY`,
  tenant zone), the document number, the line number, income, expense and the running balance.
  Left out, so blank: the counterparty and the accounting unit of finished output (the card is
  built from the ledger, which holds neither), kind of production, sort, profile, size, account,
  price, the person responsible, shop, executor, the control signature and the precious-materials
  note (mapping doc G4, G5, G13; nothing is invented). The header is a list of plain lines: the
  engine has no multi-cell header block, so the arrangement differs from the official sheet.
  """

  alias Letflow.Modules.Stock.CountPaperwork
  alias Letflow.Modules.Stock.FormCount

  @spec data(%{header: map(), rows: [map()]}) :: map()
  def data(%{header: header, rows: rows}) do
    %{
      "org_name" => CountPaperwork.text(header[:org_name]),
      "org_bin" => CountPaperwork.text(header[:org_bin]),
      "struct_unit" => CountPaperwork.text(header[:struct_unit]),
      "item_name" => CountPaperwork.text(header[:item_name]),
      "nom" => CountPaperwork.text(header[:nom]),
      "unit" => CountPaperwork.text(header[:unit]),
      "mark" => CountPaperwork.text(header[:mark]),
      "shelf" => FormCount.date(CountPaperwork.text(header[:shelf])),
      "rows" => Enum.map(rows, &row/1)
    }
  end

  defp row(row) do
    %{
      "date" => FormCount.date(CountPaperwork.text(row[:event_time])),
      "doc_number" => CountPaperwork.text(row[:document_number]),
      "no" => CountPaperwork.text(row[:no]),
      "income" => decimal(row[:income]),
      "expense" => decimal(row[:expense]),
      "balance" => decimal(row[:balance])
    }
  end

  defp decimal(nil), do: ""
  defp decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)
end
