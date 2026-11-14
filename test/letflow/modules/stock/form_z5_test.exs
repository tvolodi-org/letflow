defmodule Letflow.Modules.Stock.FormZ5Test do
  @moduledoc "T-1959: the Z-5 / Қ-5 data map for transfer, hand over and return (pure, no DB)."

  use ExUnit.Case, async: true

  alias Letflow.Modules.Stock.FormZ5

  @header %{
    "org_unit_id" => "u-1",
    "from_org_unit_id" => "u-2",
    "to_org_unit_id" => "u-2",
    "from_location_id" => "l-1",
    "to_location_id" => "l-2",
    "from_responsible_id" => "e-1",
    "to_responsible_id" => "e-2",
    "event_time" => "2026-11-05T21:30:00+00:00"
  }

  defp issued(kind, header \\ @header) do
    %{
      number_label: "D-1",
      content: %{
        "kind" => kind,
        "header" => header,
        "lines" => [
          %{
            "line_no" => 1,
            "catalog_item_id" => "i-1",
            "catalog_uom_id" => "m-1",
            "quantity" => "5"
          }
        ]
      }
    }
  end

  defp names do
    %{
      offsets: %{event_time: 0},
      legal_entities: %{"u-1" => %{name: "ТОО Степь", bin: "123456789012"}},
      employees: %{"e-1" => %{full_name: "Алмазов А."}, "e-2" => %{full_name: "Берик Б."}},
      org_units: %{"u-1" => %{name: "Warehouse"}, "u-2" => %{name: "Sales"}},
      locations: %{"l-1" => %{name: "Showroom"}, "l-2" => %{name: "Central"}},
      items: %{"i-1" => %{code: "B-1", name: "Болт"}},
      uoms: %{"m-1" => %{code: "PCS", name: "шт"}}
    }
  end

  test "U-Z5-1 a return: the returning unit sends, the filing unit receives" do
    d = FormZ5.data(issued("return"), names())
    assert d["sender_unit"] == "Sales / Showroom"
    assert d["receiver_unit"] == "Warehouse / Central"
    assert d["released"] == "Алмазов А."
    assert d["responsible"] == "Алмазов А."
    assert d["received"] == "Берик Б."
    assert d["org_name"] == "ТОО Степь"
    assert d["org_bin"] == "123456789012"
  end

  test "U-Z5-2 a hand over uses the transfer mapping" do
    d = FormZ5.data(issued("hand_over"), names())
    assert d["sender_unit"] == "Warehouse / Showroom"
    assert d["receiver_unit"] == "Sales / Central"
    assert d["released"] == "Алмазов А."
    assert d["received"] == "Берик Б."
  end

  test "U-Z5-3 the known gaps stay out of the map (print blank)" do
    d = FormZ5.data(issued("return"), names())

    for k <- ["basis", "price", "amount", "amount_words"],
        do: refute(Map.has_key?(d, k), k)

    assert [%{"name" => "Болт", "qty_issued" => "5", "unit" => "шт"}] = d["lines"]
  end

  test "U-Z5-4 a transfer prints as before" do
    t = FormZ5.data(issued("transfer"), names())
    assert t["sender_unit"] == "Warehouse / Showroom"
    assert t["receiver_unit"] == "Sales / Central"
    assert t == FormZ5.data(issued("hand_over"), names())
  end

  test "U-Z5-5 an unknown or missing kind does not raise" do
    assert FormZ5.data(issued("nonsense"), names())["sender_unit"] == "Warehouse / Showroom"
    assert FormZ5.data(%{content: %{"header" => @header}}, names())["sender_unit"] =~ "Warehouse"
    assert is_map(FormZ5.data(%{}, %{}))
  end
end
