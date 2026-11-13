defmodule Letflow.Modules.Stock.FormZ1 do
  @moduledoc """
  T-1912: the data of official form Z-1 (ru) / Қ-1 (kk), annex 25 of order No. 562
  "warehouse receipt order", for an ISSUED or POSTED `receipt` document. Pure: the output
  of `DocumentPrintSource.read/4` (with `kinds: ["receipt"]`, `legal_entities: true`) in,
  the data map of `Letflow.Documents.FormPrint` (form `z1`) out. Layout and wording are in
  `priv/print_forms/z1.json` and `messages.json`.

  Filled in: organisation name and BIN of the legal entity of the header org unit, warehouse
  (location name), number, date (the date part of event_time in the tenant zone, DD.MM.YYYY),
  supplier name and tax_id (joined with " / " when present), accompanying document reference,
  the responsible person as "Принял", line item name, code, unit, quantity, price and amount
  as the stored text. The lot is not printed (the form has no lot column).

  Left out of the map, so they print blank (nothing is invented; mapping doc
  `docs/assets/kz-forms-mapping.md` section 7.1): kind of operation (G6), account (G6),
  payment document (G7), "Сдал" (G4), and per line: qty_doc, mass_doc, mass, passport,
  card_no (G13). The IIN is never stored (G1). received_on is not printed (the form has
  no arrival-date cell). Quantities and prices print as the stored 9-decimal text.
  """

  alias Letflow.Modules.Stock.CountPaperwork
  alias Letflow.Modules.Stock.FormCount

  @spec data(map(), map()) :: map()
  def data(issued, names) do
    content = Map.get(issued, :content, %{})
    header = map(content["header"])
    entity = names |> Map.get(:legal_entities, %{}) |> Map.get(header["org_unit_id"], %{})
    responsible = lookup(names, :employees, header["responsible_id"])
    location = lookup(names, :locations, header["location_id"])
    counterparty = names |> Map.get(:counterparties, %{}) |> Map.get(header["counterparty_id"])

    %{
      "org_name" => CountPaperwork.text(entity[:name]),
      "org_bin" => CountPaperwork.text(entity[:bin]),
      "warehouse" => CountPaperwork.text(location[:name]),
      "number" => CountPaperwork.text(issued[:number_label]),
      "date" => FormCount.date(CountPaperwork.time(header["event_time"], names, :event_time)),
      "supplier" => supplier(counterparty),
      "accomp_doc" => CountPaperwork.text(header["supplier_document_ref"]),
      "accepted_by" => CountPaperwork.text(responsible[:full_name]),
      "lines" => lines(content, names)
    }
  end

  defp supplier(nil), do: ""

  defp supplier(c) do
    name = c[:name] || ""
    tax_id = c[:tax_id]

    if is_binary(tax_id) and tax_id != "" do
      name <> " / " <> tax_id
    else
      name
    end
  end

  defp lines(content, names) do
    list = if is_list(content["lines"]), do: Enum.filter(content["lines"], &is_map/1), else: []

    list
    |> Enum.sort_by(&(&1["line_no"] || 0))
    |> Enum.map(fn line ->
      item = lookup(names, :items, line["catalog_item_id"])
      uom = lookup(names, :uoms, line["catalog_uom_id"])

      row = %{
        "name" => CountPaperwork.text(item[:name]),
        "nom" => CountPaperwork.text(item[:code]),
        "unit" => CountPaperwork.text(uom[:name] || uom[:code]),
        "qty" => CountPaperwork.text(line["quantity"])
      }

      row
      |> maybe_put("price", line["unit_price"])
      |> maybe_put("sum", line["line_value"])
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp lookup(names, group, id) when is_binary(id),
    do: names |> Map.get(group, %{}) |> Map.get(id) |> map_atom()

  defp lookup(_names, _group, _id), do: %{}

  defp map_atom(%{} = m), do: m
  defp map_atom(_), do: %{}

  defp map(%{} = m), do: m
  defp map(_), do: %{}
end
