defmodule Letflow.Modules.Assets.FormDa3 do
  @moduledoc """
  T-1923 (official forms audit T-1906, slice 7): the data of official form ДА-3 (ru) / ҰМА-3 (kk),
  annex 18 of order No. 562, "act for the disposal (write-off) of long-term assets", for an issued,
  posted or reversed asset `writeoff` document. Pure: the output of `DocumentPrintSource.read/4`
  (with `kinds: ["writeoff"]`, `form: true`) in, the data map of `Letflow.Documents.FormPrint`
  (form `da3`) out. Layout and wording are in `priv/print_forms/da3.json` and `messages.json`. The
  form is to be confirmed by the accountant (PM decision 2026-11-14, not blocking); see
  `docs/assets/kz-forms-mapping.md` section 7.5.

  Filled in, from stored facts only: the name and BIN of the legal entity of the unit, the document's
  own number and date, the write-off reason in the form language (label, then the free text), the
  materially responsible person with position, and per card the name, acquisition date, inventory
  number, original cost, accumulated depreciation and book value. The money follows the ДА-1 rule
  (`FormDa1.money/2`, `FormDa1.as_of_ok?/2`): only for a KZT card, and depreciation and book value
  only when the card's `depreciation_as_of` is not after the act date. Card values are the live
  values at print time.

  Left out of the map, so it prints blank (never an invented value): the whole commission block
  (order, chair, members, inspection, asset state, conclusion; REQ-777 stores it, not built yet),
  the approver, release date, actual service life, factory number, accessories and precious
  materials, repairs, attached documents, costs and income of the write-off and the chief
  accountant mark. The line quantity is not printed: the form has no quantity column.
  """

  alias Letflow.Modules.Assets.DocumentPrint
  alias Letflow.Modules.Assets.FormDa1

  @reasons %{
    "disposed" => :reason_disposed,
    "lost" => :reason_lost,
    "broken" => :reason_broken,
    "expired" => :reason_expired,
    "other" => :reason_other
  }

  @spec data(map(), map(), String.t()) :: map()
  def data(issued, names, lang) do
    atom = if lang == "kk", do: :kk, else: :ru
    content = Map.get(issued, :content, %{})
    header = map(content["header"])
    own = FormDa1.lookup(names, :legal_entities, header["org_unit_id"])
    {mol_position, mol} = FormDa1.person(names, header["material_responsible_id"])
    act = FormDa1.local_date(header["event_time"], names)

    %{
      "org_name" => FormDa1.text(own[:name]),
      "org_bin" => FormDa1.text(own[:bin]),
      "number" => FormDa1.text(Map.get(issued, :number_label)),
      "date" => act_date(act),
      "reason" => reason(header, atom),
      "mol" => mol,
      "mol_position" => mol_position,
      "lines" => lines(content, names, atom, act)
    }
  end

  defp act_date(%Date{} = d), do: FormDa1.date(Date.to_iso8601(d))
  defp act_date(_), do: ""

  # The Z-6 rule: label of the code in the form language, then the free text after a colon.
  defp reason(header, lang) do
    text = FormDa1.text(header["reason_text"])

    label =
      case Map.get(@reasons, header["reason_code"]) do
        nil -> ""
        key -> DocumentPrint.labels() |> Map.fetch!(key) |> Map.fetch!(lang)
      end

    cond do
      label == "" -> text
      text == "" -> label
      true -> label <> ": " <> text
    end
  end

  defp lines(content, names, lang, act) do
    list = if is_list(content["lines"]), do: Enum.filter(content["lines"], &is_map/1), else: []

    list
    |> Enum.sort_by(&(&1["line_no"] || 0))
    |> Enum.with_index(1)
    |> Enum.map(fn {line, index} ->
      card = FormDa1.lookup(names, :cards, line["asset_id"])
      kzt? = card[:currency] == "KZT"
      depr? = kzt? and FormDa1.as_of_ok?(card[:depreciation_as_of], act)

      %{
        "no" => Integer.to_string(index),
        "name" => FormDa1.text(card[:name]),
        "acquired" => FormDa1.date(card[:acquisition_date]),
        "inv" => FormDa1.text(card[:inventory_number]),
        "cost" => if(kzt?, do: FormDa1.money(card[:acquisition_cost], lang), else: ""),
        "depr" => if(depr?, do: FormDa1.money(card[:accumulated_depreciation], lang), else: ""),
        "book" => if(depr?, do: FormDa1.money(card[:book_value], lang), else: "")
      }
    end)
  end

  defp map(%{} = m), do: m
  defp map(_), do: %{}
end
