defmodule Letflow.Modules.Stock.FormZ6 do
  @moduledoc """
  T-1914 (official forms audit T-1906, slice 3): the data of official form Z-6 (ru) / Қ-6 (kk), annex 30 of
  order No. 562 "act of writing off stock", for an issued, posted or reversed `write_off` document. Pure: the
  output of `DocumentPrintSource.read/4` (with `kinds: ["write_off"]`, `legal_entities: true`) in, the data map
  of `Letflow.Documents.FormPrint` (form `z6`) out. Layout and wording are in `priv/print_forms/z6.json` and
  `messages.json`.

  Filled in: organisation name and BIN of the legal entity of the unit, number, date, structural unit (with
  the location name after a slash when the document has one), the responsible person (also as the signer of
  the responsible-person line), and per line the number, item name and code, unit, quantity as the stored text
  and the reason of the write-off. A write-off stores one reason for the whole document (`reason_code` and an
  optional `reason_text`); every line prints that stored reason in the reason column, in the language of the
  form. That copies a stored fact; nothing is invented.

  Left out of the map, so it prints blank (mapping doc `docs/assets/kz-forms-mapping.md`): the approver and the
  approval date (G4), the basis (G7), per line date of acquisition and service life (G13), price and sum (G5; a
  write-off line stores no price), every "in words" line of the back side (G10), the commission decision, the
  scrap table rows, the commission chair and members (G14, REQ-776, not built yet) and the position of the
  responsible person (G4).
  """

  alias Letflow.Modules.Stock.CountPaperwork
  alias Letflow.Modules.Stock.DocumentPrint
  alias Letflow.Modules.Stock.FormCount

  @langs %{"ru" => :ru, "kk" => :kk}
  @reasons %{
    "lost" => :reason_lost,
    "damaged" => :reason_damaged,
    "used_up" => :reason_used_up,
    "other" => :reason_other
  }

  @spec data(map(), map(), String.t()) :: map()
  def data(issued, names, lang) do
    content = Map.get(issued, :content, %{})
    header = map(content["header"])
    entity = names |> Map.get(:legal_entities, %{}) |> Map.get(header["org_unit_id"], %{})
    person = lookup(names, :employees, header["responsible_id"])
    name = CountPaperwork.text(person[:full_name])

    %{
      "org_name" => CountPaperwork.text(entity[:name]),
      "org_bin" => CountPaperwork.text(entity[:bin]),
      "number" => CountPaperwork.text(issued[:number_label]),
      "date" => FormCount.date(CountPaperwork.time(header["event_time"], names, :event_time)),
      "unit" => unit(names, header["org_unit_id"], header["location_id"]),
      "responsible" => name,
      "mol" => name,
      "lines" => lines(content, names, reason(header, lang))
    }
  end

  defp reason(header, lang) do
    key = Map.get(@reasons, header["reason_code"])
    atom = Map.get(@langs, lang)

    label =
      if key && atom,
        do: DocumentPrint.labels() |> Map.get(key, %{}) |> Map.get(atom, ""),
        else: ""

    case {label, header["reason_text"]} do
      {l, text} when is_binary(text) and text != "" and l != "" -> l <> ": " <> text
      {"", text} when is_binary(text) -> text
      {l, _} -> l
    end
  end

  defp unit(names, unit_id, location_id) do
    [lookup(names, :org_units, unit_id), lookup(names, :locations, location_id)]
    |> Enum.map(&CountPaperwork.text(&1[:name]))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" / ")
  end

  defp lines(content, names, reason) do
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
        "qty" => CountPaperwork.text(line["quantity"]),
        "reason" => CountPaperwork.text(reason)
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
