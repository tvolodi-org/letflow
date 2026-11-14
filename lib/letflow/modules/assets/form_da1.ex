defmodule Letflow.Modules.Assets.FormDa1 do
  @moduledoc """
  T-1921 (official forms audit T-1906, slice 5): the data of official form ДА-1 (ru) / ҰМА-1 (kk), annex
  16 of order No. 562, "act of acceptance and transfer of long-term assets", for an issued, posted or
  reversed asset `commission` or `handover` document. Pure: the output of
  `DocumentPrintSource.read/4` (with `kinds: ["commission", "handover"]`, `form: true`) in, the data map
  of `Letflow.Documents.FormPrint` (form `da1`) out. Layout and wording are in `priv/print_forms/da1.json`
  and `messages.json`. The form is to be confirmed by the accountant (PM decision 2026-11-14, not
  blocking); see `docs/assets/kz-forms-mapping.md` section 7.3.

  Filled in, from stored facts only: the BIN and the name of the legal entity of the unit (receiving side
  on a commissioning, giving and receiving side on a hand over), the location, the signers "Сдал" and
  "Принял" with position, the materially responsible person of the giving side (column 4) and per card the
  name, the inventory number, the acquisition date and the money columns.

  Money rules: the headers say "в теңге", so cost, depreciation and book value print only when the card
  currency is KZT. Depreciation and book value print only when the card's `depreciation_as_of` is empty or
  not later than the local date of the act: a later value would be wrong for the act. The card values are
  the live card values at print time (not the values at the act date); the card is corrected by a card
  PATCH only, so that is acceptable.

  Left out of the map, so it prints blank (never an invented value): basis columns 1-3 and the basis of
  the move, useful life, factory and passport numbers, debit and credit accounts, the sale value with VAT
  (Q21: a transfer between organisations; an in-tenant hand over is not a sale), both head approvals, the
  receiver BIN, the inspection order, the commission and its conclusions, the power of attorney, the
  custody mark and both chief accountant marks. A commissioning has no giving side: the giving
  organisation, "Сдал" and the column 4 person are blank. An empty `to_location_id` prints a blank
  location (no fallback to the location of the giving side).
  """

  alias Letflow.Modules.Assets.DocumentPrint

  @spec data(map(), map(), String.t()) :: map()
  def data(issued, names, lang) do
    content = Map.get(issued, :content, %{})
    header = map(content["header"])
    handover? = content["kind"] == "handover"
    atom = if lang == "kk", do: :kk, else: :ru

    receiving_unit = if handover?, do: header["to_org_unit_id"], else: header["org_unit_id"]
    receiver = lookup(names, :legal_entities, receiving_unit)

    giver =
      if handover?, do: lookup(names, :legal_entities, header["org_unit_id"]), else: %{}

    own = lookup(names, :legal_entities, header["org_unit_id"])
    location_id = if handover?, do: header["to_location_id"], else: header["location_id"]
    giver_id = if handover?, do: header["from_material_responsible_id"]

    taker_id =
      if handover?,
        do: header["to_material_responsible_id"],
        else: header["material_responsible_id"]

    {giver_pos, giver_name} = person(names, giver_id)
    {taker_pos, taker_name} = person(names, taker_id)
    act_date = local_date(header["event_time"], names)

    base = %{
      "org_bin" => text(own[:bin]),
      "receiver_name" => text(receiver[:name]),
      "location" => text(lookup(names, :locations, location_id)[:name]),
      "accepted" => taker_name,
      "accepted_position" => taker_pos,
      "lines" => lines(content, names, atom, act_date, mol(giver_pos, giver_name))
    }

    if handover? do
      Map.merge(base, %{
        "sender_name" => text(giver[:name]),
        "handed" => giver_name,
        "handed_position" => giver_pos
      })
    else
      base
    end
  end

  defp mol("", ""), do: ""
  defp mol("", name), do: name
  defp mol(pos, ""), do: pos
  defp mol(pos, name), do: name <> ", " <> pos

  defp lines(content, names, lang, act_date, mol) do
    handover? = content["kind"] == "handover"
    list = if is_list(content["lines"]), do: Enum.filter(content["lines"], &is_map/1), else: []

    list
    |> Enum.sort_by(&(&1["line_no"] || 0))
    |> Enum.map(fn line ->
      card = lookup(names, :cards, line["asset_id"])
      kzt? = card[:currency] == "KZT"
      depr? = kzt? and as_of_ok?(card[:depreciation_as_of], act_date)

      row = %{
        "name" => text(card[:name]),
        "inv" => text(card[:inventory_number]),
        "acquired" => date(card[:acquisition_date]),
        "cost" => if(kzt?, do: money(card[:acquisition_cost], lang), else: ""),
        "depr" => if(depr?, do: money(card[:accumulated_depreciation], lang), else: ""),
        "book" => if(depr?, do: money(card[:book_value], lang), else: "")
      }

      if handover?, do: Map.put(row, "mol", mol), else: row
    end)
  end

  defp money(nil, _lang), do: ""
  defp money(value, lang), do: DocumentPrint.number(value, lang)

  # An empty as-of keeps the value; a later as-of than the act date is a value from after the act.
  defp as_of_ok?(as_of, _act) when as_of in [nil, ""], do: true

  defp as_of_ok?(as_of, act_date) when is_binary(as_of) do
    case {Date.from_iso8601(String.slice(as_of, 0, 10)), act_date} do
      {{:ok, d}, %Date{} = a} -> Date.compare(d, a) != :gt
      _ -> false
    end
  end

  defp as_of_ok?(_, _), do: false

  defp date(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{4})-(\d{2})-(\d{2})/, value) do
      [_, y, m, d] -> "#{d}.#{m}.#{y}"
      _ -> value
    end
  end

  defp date(_), do: ""

  # The local calendar date of the act's event instant (the tenant zone offset is in `names`).
  defp local_date(value, names) do
    with {:ok, dt} <- instant(value),
         offset = names |> Map.get(:offsets, %{}) |> Map.get(:event_time, 0) do
      dt |> DateTime.add(offset, :second) |> DateTime.to_date()
    else
      _ -> nil
    end
  end

  defp instant(%DateTime{} = dt), do: {:ok, dt}

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp instant(_), do: :error

  # `{position, full_name}` of an employee id; `{"", ""}` for an unknown id.
  defp person(names, id) when is_binary(id) do
    case names |> Map.get(:employees, %{}) |> Map.get(id) do
      %{} = e -> {text(names |> Map.get(:positions, %{}) |> Map.get(id)), text(e[:full_name])}
      _ -> {"", ""}
    end
  end

  defp person(_names, _id), do: {"", ""}

  defp lookup(names, group, id) when is_binary(id) do
    case names |> Map.get(group, %{}) |> Map.get(id) do
      %{} = m -> m
      _ -> %{}
    end
  end

  defp lookup(_names, _group, _id), do: %{}

  defp text(v), do: DocumentPrint.text(v)

  defp map(%{} = m), do: m
  defp map(_), do: %{}
end
