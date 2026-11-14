defmodule Letflow.Modules.Assets.FormDa4 do
  @moduledoc """
  T-1922 (official forms audit T-1906, slice 6): the data of official form ДА-4 (ru) / ҰМА-4 (kk), annex
  19 of order No. 562, "invoice for internal movement of long-term assets", for an issued, posted or
  reversed asset `change` or `handover` document. Pure: the output of `DocumentPrintSource.read/4`
  (with `kinds: ["change", "handover"]`, `form: true`) in, the data map of `Letflow.Documents.FormPrint`
  (form `da4`) out. Layout and wording are in `priv/print_forms/da4.json` and `messages.json`. The form is
  to be confirmed by the accountant (PM decision 2026-11-14, not blocking); see
  `docs/assets/kz-forms-mapping.md` section 7.4.

  Filled in, from stored facts only: the name and BIN of the legal entity of the giving unit, sender and
  receiver unit and location, the giving materially responsible person ("Ответственный за поставку"),
  the document's own number and date, the note, the signers "Сдал" and "Принял" with position, and per
  card the name, acquisition date, inventory number and the quantity (plain trimmed decimal text, no
  digit grouping, so the total row of the engine can sum it).

  Left out of the map, so it prints blank (never an invented value): price and cost (Q22, which cost goes
  there is open), factory and passport numbers, the unit of measure (the card has none), the basis, the
  amounts in words and the chief accountant mark. A hand over between two legal entities (Q21) prints the
  giving unit's organisation; the form has no field for the receiving one.
  """

  alias Letflow.Modules.Assets.FormDa1

  @spec data(map(), map(), String.t()) :: map()
  def data(issued, names, _lang) do
    content = Map.get(issued, :content, %{})
    header = map(content["header"])
    handover? = content["kind"] == "handover"

    own = FormDa1.lookup(names, :legal_entities, header["org_unit_id"])

    {sender_loc, receiver_unit, receiver_loc} =
      if handover? do
        {header["from_location_id"], header["to_org_unit_id"], header["to_location_id"]}
      else
        {header["location_id"], header["org_unit_id"], header["location_id"]}
      end

    {handed_pos, handed} = FormDa1.person(names, header["from_material_responsible_id"])
    {accepted_pos, accepted} = FormDa1.person(names, header["to_material_responsible_id"])

    %{
      "org_name" => FormDa1.text(own[:name]),
      "org_bin" => FormDa1.text(own[:bin]),
      "sender_unit" => unit(names, header["org_unit_id"], sender_loc),
      "receiver_unit" => unit(names, receiver_unit, receiver_loc),
      "responsible" => handed,
      "number" => FormDa1.text(Map.get(issued, :number_label)),
      "date" => act_date(header["event_time"], names),
      "note" => FormDa1.text(header["note"]),
      "handed" => handed,
      "handed_position" => handed_pos,
      "accepted" => accepted,
      "accepted_position" => accepted_pos,
      "lines" => lines(content, names)
    }
  end

  defp act_date(value, names) do
    case FormDa1.local_date(value, names) do
      %Date{} = d -> FormDa1.date(Date.to_iso8601(d))
      _ -> ""
    end
  end

  defp unit(names, unit_id, location_id) do
    [FormDa1.lookup(names, :org_units, unit_id), FormDa1.lookup(names, :locations, location_id)]
    |> Enum.map(&FormDa1.text(&1[:name]))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" / ")
  end

  defp lines(content, names) do
    list = if is_list(content["lines"]), do: Enum.filter(content["lines"], &is_map/1), else: []

    list
    |> Enum.sort_by(&(&1["line_no"] || 0))
    |> Enum.with_index(1)
    |> Enum.map(fn {line, index} ->
      card = FormDa1.lookup(names, :cards, line["asset_id"])

      %{
        "no" => Integer.to_string(index),
        "name" => FormDa1.text(card[:name]),
        "acquired" => FormDa1.date(card[:acquisition_date]),
        "inv" => FormDa1.text(card[:inventory_number]),
        "qty" => qty(line["quantity"])
      }
    end)
  end

  # Plain decimal text: fraction zeros and a bare dot dropped; no grouping (the engine sums with Decimal.parse).
  defp qty(value) when is_binary(value) do
    if Regex.match?(~r/\A-?\d+(\.\d+)?\z/, value) and String.contains?(value, ".") do
      value |> String.trim_trailing("0") |> String.trim_trailing(".")
    else
      FormDa1.text(value)
    end
  end

  defp qty(value) when is_integer(value), do: Integer.to_string(value)
  defp qty(%Decimal{} = d), do: d |> Decimal.to_string(:normal) |> qty()
  defp qty(value) when is_float(value), do: value |> Float.to_string() |> qty()
  defp qty(_), do: ""

  defp map(%{} = m), do: m
  defp map(_), do: %{}
end
