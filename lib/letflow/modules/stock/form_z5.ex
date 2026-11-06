defmodule Letflow.Modules.Stock.FormZ5 do
  @moduledoc """
  T-1417 (phase E, E5c): the data of official form Z-5 (ru) / Q-5 (kk), annex 29 of order No. 562
  "invoice for the internal movement of stock", for an ISSUED `transfer` document. Pure: the output
  of `DocumentPrintSource.read/4` (with `kinds: ["transfer"]`, `legal_entities: true`) in, the data
  map of `Letflow.Documents.FormPrint` (form `z5`) out. Layout and wording are in
  `priv/print_forms/z5.json` and `messages.json`.

  Filled in: organisation name and BIN of the legal entity of the sending unit, number, date,
  sending and receiving structural unit (with the location name after a slash when the document
  has one), the sender's and the receiver's responsible person, line number, item name and code,
  unit, issued quantity as the stored text. Left out of the map, so it prints blank (nothing is
  invented; mapping doc `docs/assets/kz-forms-mapping.md`): the basis (G7), planned quantity (G9),
  price and amount (G5), amounts in words (G10), the persons who allowed and checked, and every
  signer position (G4), the sort, brand and size of the item (G13).
  """

  alias Letflow.Modules.Stock.CountPaperwork
  alias Letflow.Modules.Stock.FormCount

  @spec data(map(), map()) :: map()
  def data(issued, names) do
    content = Map.get(issued, :content, %{})
    header = map(content["header"])
    entity = names |> Map.get(:legal_entities, %{}) |> Map.get(header["org_unit_id"], %{})
    from = lookup(names, :employees, header["from_responsible_id"])
    to = lookup(names, :employees, header["to_responsible_id"])

    %{
      "org_name" => CountPaperwork.text(entity[:name]),
      "org_bin" => CountPaperwork.text(entity[:bin]),
      "number" => CountPaperwork.text(issued[:number_label]),
      "date" => FormCount.date(CountPaperwork.time(header["event_time"], names, :event_time)),
      "sender_unit" => unit(names, header["org_unit_id"], header["from_location_id"]),
      "receiver_unit" => unit(names, header["to_org_unit_id"], header["to_location_id"]),
      "responsible" => CountPaperwork.text(from[:full_name]),
      "released" => CountPaperwork.text(from[:full_name]),
      "received" => CountPaperwork.text(to[:full_name]),
      "lines" => lines(content, names)
    }
  end

  defp unit(names, unit_id, location_id) do
    [lookup(names, :org_units, unit_id), lookup(names, :locations, location_id)]
    |> Enum.map(&CountPaperwork.text(&1[:name]))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" / ")
  end

  defp lines(content, names) do
    list = if is_list(content["lines"]), do: Enum.filter(content["lines"], &is_map/1), else: []

    list
    |> Enum.sort_by(&(&1["line_no"] || 0))
    |> Enum.with_index(1)
    |> Enum.map(fn {line, n} ->
      item = lookup(names, :items, line["catalog_item_id"])
      uom = lookup(names, :uoms, line["catalog_uom_id"])

      %{
        "no" => CountPaperwork.text(line["line_no"] || n),
        "name" => CountPaperwork.text(item[:name]),
        "nom" => CountPaperwork.text(item[:code]),
        "unit" => CountPaperwork.text(uom[:name] || uom[:code]),
        "qty_issued" => CountPaperwork.text(line["quantity"])
      }
    end)
  end

  defp lookup(names, group, id) when is_binary(id),
    do: names |> Map.get(group, %{}) |> Map.get(id) |> map_atom()

  defp lookup(_names, _group, _id), do: %{}

  defp map_atom(%{} = m), do: m
  defp map_atom(_), do: %{}

  defp map(%{} = m), do: m
  defp map(_), do: %{}
end
