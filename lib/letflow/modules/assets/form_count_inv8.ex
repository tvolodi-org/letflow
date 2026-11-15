defmodule Letflow.Modules.Assets.FormCountInv8 do
  @moduledoc """
  T-1932 (REQ-821, asset count K6): the data of official form Инв-8 (ru) / Түг-8 (kk), annex 39 of order
  No. 562, "inventory list of long-term assets", for the ISSUED count sheet. Pure: the output of
  `CountPrintSource.read/3` in, the data map of `Letflow.Documents.FormPrint` (form `inv8`) out. Layout
  and wording are in `priv/print_forms/inv8.json` and `messages.json`.

  **To be confirmed by accountant** (PM decision 2026-11-14, not blocking): that Инв-8 is the right form
  for the asset count sheet, and the assumption [A] of `docs/assets/asset-count.md` section 7 that the
  book cost is the card's stored book value.

  Filled from Letflow (keys always present, `""` when the sheet holds nothing): organisation name and BIN,
  number and date of the sheet, the location (when the count has exactly one root), the order number and
  date, the cut-off date, the material responsible persons of the lines (first one, the rest joined onto
  the second), the commission chair and members, and per line the number, name (the description of a
  surplus line without a card), inventory number, acquisition date, counted quantity, book quantity and
  book cost; the row count and the total counted quantity.

  Book cost prints the sheet's stored `book_value` only on a book line whose card currency is KZT (the
  column header says "в теңге", the same rule as ДА-1/ДА-2); it is blank on a surplus line and on a card
  of another currency. Left out of the map, so it prints blank (never invented): the kind of objects, the
  accounts (G6), the release date, factory and passport numbers (G11), the actual cost (G5), the actual
  start and end (G12), the amounts in words (G10), the responsible persons' statement and its date, every
  signature and the checker.
  """

  alias Letflow.Modules.Assets.CountPrintSource
  alias Letflow.Modules.Assets.FormDa1

  @spec data(map(), map()) :: map()
  def data(issued, names) do
    content = Map.get(issued, :content, %{})
    lines = CountPrintSource.lines(content)
    rows = Enum.map(lines, &row(&1, names))
    order = Map.get(names, :order) || %{}
    entity = FormDa1.lookup(names, :legal_entities, content["org_unit_id"])

    {first, rest} = content |> CountPrintSource.responsible_ids() |> Enum.split(1)
    chair = content["chair_employee_id"]

    members =
      content["member_employee_ids"]
      |> List.wrap()
      |> Enum.reject(&(&1 == chair))
      |> Enum.split(1)

    {m1, m_rest} = members

    %{
      "org_name" => text(entity[:name]),
      "org_bin" => text(entity[:bin]),
      "number" => text(issued[:number_label]),
      "date" => date_of(issued[:issued_at], names, :issued_at),
      "location" => location(content, names),
      "order_no" => order_no(order, content),
      "order_date" => date_of(order[:issued_at], names, :order_issued_at),
      "cut_off" => date_of(content["cut_off_at"], names, :cut_off_at),
      "lines" => rows,
      "total_nos" => if(rows == [], do: "", else: Integer.to_string(length(rows))),
      "total_qty" => sum_text(Enum.map(rows, & &1["qty_fact"]))
    }
    |> Map.merge(signature("resp1", people(names, first)))
    |> Map.merge(signature("resp2", people(names, rest)))
    |> Map.merge(signature("chair", FormDa1.person(names, chair)))
    |> Map.merge(signature("member1", people(names, m1)))
    |> Map.merge(signature("member2", people(names, m_rest)))
  end

  defp row(line, names) do
    book? = line["kind"] == "book"
    kzt? = names |> Map.get(:card_currency, %{}) |> Map.get(line["asset_id"]) == "KZT"

    %{
      "no" => text(line["line_no"]),
      "name" => name(line),
      "inv" => text(line["inventory_number"]),
      "acquired" => FormDa1.date(line["acquisition_date"]),
      "qty_fact" => text(line["counted_quantity"]),
      "qty_book" => text(line["book_quantity"]),
      "cost_book" => if(book? and kzt?, do: text(line["book_value"]), else: "")
    }
  end

  defp name(line) do
    case text(line["name"]) do
      "" -> text(line["description"])
      name -> name
    end
  end

  # The one root location's name; any other number of roots prints blank.
  defp location(content, names) do
    case List.wrap(content["location_ids"]) do
      [id] -> text(FormDa1.lookup(names, :locations, id)[:name])
      _ -> ""
    end
  end

  defp order_no(order, content) do
    case text(order[:number_label]) do
      "" -> text(content["order_number"])
      label -> label
    end
  end

  # The local date `DD.MM.YYYY` of a stored instant (the tenant zone offset is in `names.offsets`).
  defp date_of(value, names, key) do
    with {:ok, dt} <- instant(value),
         offset = names |> Map.get(:offsets, %{}) |> Map.get(key, 0) do
      dt |> DateTime.add(offset, :second) |> Calendar.strftime("%d.%m.%Y")
    else
      _ -> ""
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

  # Several people as two texts joined by `; `: `{position, name}`; unknown ids are skipped.
  defp people(names, ids) do
    persons = ids |> Enum.map(&FormDa1.person(names, &1)) |> Enum.reject(&(&1 == {"", ""}))

    joined = fn pick ->
      persons |> Enum.map(pick) |> Enum.reject(&(&1 == "")) |> Enum.join("; ")
    end

    {joined.(&elem(&1, 0)), joined.(&elem(&1, 1))}
  end

  defp signature(key, {position, name}), do: %{key => name, (key <> "_position") => position}

  @doc false
  # The sum of decimal texts; `""` when the list is empty or one value is not a decimal.
  def sum_text([]), do: ""

  def sum_text(values) do
    decimals = Enum.map(values, &decimal/1)

    if Enum.any?(decimals, &is_nil/1),
      do: "",
      else: decimals |> Enum.reduce(Decimal.new(0), &Decimal.add/2) |> Decimal.to_string(:normal)
  end

  defp decimal(v) when is_binary(v) do
    case Decimal.parse(v) do
      {%Decimal{} = d, ""} -> d
      _ -> nil
    end
  end

  defp decimal(_), do: nil

  defp text(v), do: FormDa1.text(v)
end
