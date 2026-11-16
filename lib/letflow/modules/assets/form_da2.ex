defmodule Letflow.Modules.Assets.FormDa2 do
  @moduledoc """
  T-1924 (official forms audit T-1906, slice 8): the data of official form ДА-2 (ru) / ҰМА-2 (kk), annex
  17 of order No. 562, "inventory card of long-term assets", for one asset card. Pure: the output of
  `CardPrintSource.read/3` in, the data map of `Letflow.Documents.FormPrint` (form `da2`) out. Layout
  and wording are in `priv/print_forms/da2.json` and `messages.json`. The form is to be confirmed by
  the accountant (PM decision 2026-11-14, not blocking); see `docs/assets/kz-forms-mapping.md`
  section 7.6.

  Filled in, from stored facts only: the legal entity name and BIN, the unit, the materially
  responsible person, the card name, inventory number, acquisition date and, for a KZT card, the
  original cost, accumulated depreciation and book value (the live card values, no as-of date).

  Holder rule: unit and person come from the register only when the card has exactly one non-zero
  row (`names.holders`); otherwise the unit is the card's own `org_unit_id` and the person stays
  blank (never commissioned, written off, or a split low-value card).

  T-2017 slice 1 also reads manufacturer, technical characteristics (asset_type, model, type,
  brand, category, sort, in that reference order), serial/passport numbers, useful life in months
  and commissioning date from the live card. These attributes are optional; a missing value is blank.
  No separate grade/class or invented age: the reference says "возраст".

  Commission-document number/date and acquisition document fields await slice 1b. Release year,
  liquidation value, impairment, ownership, disposal, precious materials, repairs, revaluations,
  movements, elements and signatures remain blank, never invented.
  """

  alias Letflow.Modules.Assets.FormDa1

  @spec data(map(), map(), String.t()) :: map()
  def data(card, names, lang) do
    atom = if lang == "kk", do: :kk, else: :ru
    holders = names |> Map.get(:holders, []) |> List.wrap()
    {unit_id, mol_id} = holder(card, holders)
    unit = FormDa1.lookup(names, :org_units, unit_id)
    own = FormDa1.lookup(names, :legal_entities, unit_id)
    employee = FormDa1.lookup(names, :employees, mol_id)
    kzt? = Map.get(card, "currency") == "KZT"

    %{
      "org_name" => FormDa1.text(own[:name]),
      "org_bin" => FormDa1.text(own[:bin]),
      "unit" => FormDa1.text(unit[:name]),
      "mol" => FormDa1.text(employee[:full_name]),
      "maker" => FormDa1.text(Map.get(card, "manufacturer")),
      "model" => characteristics(card),
      "full_name" => FormDa1.text(Map.get(card, "name")),
      "lines" => [
        %{
          "commissioned" => FormDa1.date(Map.get(card, "commissioning_date")),
          "factory" => FormDa1.text(Map.get(card, "serial_number")),
          "passport" => FormDa1.text(Map.get(card, "passport_number")),
          "life" => FormDa1.text(Map.get(card, "useful_life_months")),
          "name" => FormDa1.text(Map.get(card, "name")),
          "cost" => money(kzt?, Map.get(card, "acquisition_cost"), atom),
          "inv" => FormDa1.text(Map.get(card, "inventory_number")),
          "acquired" => FormDa1.date(Map.get(card, "acquisition_date")),
          "depr" => money(kzt?, Map.get(card, "accumulated_depreciation"), atom),
          "book" => money(kzt?, Map.get(card, "book_value"), atom)
        }
      ]
    }
  end

  defp characteristics(card) do
    ~w(asset_type model type brand category sort)
    |> Enum.map(&(card |> Map.get(&1) |> FormDa1.text() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  defp holder(_card, [%{org_unit: unit, material_responsible: mol}]), do: {unit, mol}
  defp holder(card, _), do: {Map.get(card, "org_unit_id"), nil}

  defp money(true, value, lang), do: FormDa1.money(value, lang)
  defp money(false, _value, _lang), do: ""
end
