defmodule Letflow.Modules.Stock.FormZ2 do
  @moduledoc """
  T-1416 (phase E, E5b): the data of official form Z-2 (ru) / Q-2 (kk), annex 26 of order No. 562
  "invoice for the release of stock to a third party", for an ISSUED `issue` document. Pure: the
  output of `DocumentPrintSource.read/4` (with `kinds: ["issue"]`, `legal_entities: true`) in, the
  data map of `Letflow.Documents.FormPrint` (form `z2`) out. The layout and the wording are in
  `priv/print_forms/z2.json` and `messages.json`, not here.

  What Letflow holds is filled in (organisation name and BIN of the header org unit's legal
  entity, number, date, responsible person, line number, item name and code, unit, issued
  quantity as the stored text). Everything else (receiver, transport, plan quantity, price, VAT,
  amounts in words, the signatures other than the releaser's name, the power of attorney) is
  absent from the issue document (mapping doc `docs/assets/kz-forms-mapping.md`, G3, G4, G5, G8,
  G9, G10) and is left out of the map, so it prints as a blank line; nothing is invented. The IIN
  is never stored (G1). The date is the date part of the header event time in the tenant zone,
  printed `DD.MM.YYYY`.
  """

  alias Letflow.Modules.Stock.CountPaperwork
  alias Letflow.Modules.Stock.FormCount

  @spec data(map(), map()) :: map()
  def data(issued, names) do
    content = Map.get(issued, :content, %{})
    header = map(content["header"])
    entity = names |> Map.get(:legal_entities, %{}) |> Map.get(header["org_unit_id"], %{})
    org = CountPaperwork.text(entity[:name])
    responsible = lookup(names, :employees, header["responsible_id"])

    %{
      "org_name" => org,
      "sender" => org,
      "org_bin" => CountPaperwork.text(entity[:bin]),
      "number" => CountPaperwork.text(issued[:number_label]),
      "date" => FormCount.date(CountPaperwork.time(header["event_time"], names, :event_time)),
      "responsible" => CountPaperwork.text(responsible[:full_name]),
      "released" => CountPaperwork.text(responsible[:full_name]),
      "lines" => lines(content, names)
    }
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
