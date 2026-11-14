Code.require_file("../stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Assets.FormDa4Test do
  @moduledoc """
  T-1922 (design tests G1..G6): the pure mapper `FormDa4.data/3` and the layout `da4.json`.
  No database: the issued and names maps are built by hand.
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Assets.FormDa4
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  @unit_a "11111111-1111-1111-1111-111111111111"
  @unit_b "22222222-2222-2222-2222-222222222222"
  @loc_a "33333333-3333-3333-3333-333333333333"
  @loc_b "44444444-4444-4444-4444-444444444444"
  @emp_a "55555555-5555-5555-5555-555555555555"
  @emp_b "66666666-6666-6666-6666-666666666666"
  @card "77777777-7777-7777-7777-777777777777"

  defp names(extra \\ %{}) do
    Map.merge(
      %{
        offsets: %{event_time: 0},
        org_units: %{@unit_a => %{name: "Unit A"}, @unit_b => %{name: "Unit B"}},
        legal_entities: %{
          @unit_a => %{name: "Alpha LLP", bin: "111111111111"},
          @unit_b => %{name: "Beta LLP", bin: "222222222222"}
        },
        locations: %{@loc_a => %{name: "Hall A"}, @loc_b => %{name: "Hall B"}},
        employees: %{
          @emp_a => %{full_name: "Aidar Giver"},
          @emp_b => %{full_name: "Dana Taker"}
        },
        positions: %{@emp_a => "Foreman", @emp_b => nil},
        cards: %{
          @card => %{inventory_number: "INV-1", name: "Lathe", acquisition_date: "2026-03-01"}
        }
      },
      extra
    )
  end

  defp lines(qty), do: [%{"line_no" => 1, "asset_id" => @card, "quantity" => qty}]

  defp change(extra \\ %{}, qty \\ "1.000000000") do
    %{
      number_label: "ACH-7",
      content: %{
        "kind" => "change",
        "header" =>
          Map.merge(
            %{
              "org_unit_id" => @unit_a,
              "location_id" => @loc_a,
              "from_material_responsible_id" => @emp_a,
              "to_material_responsible_id" => @emp_b,
              "event_time" => "2026-11-03T09:15:00Z",
              "note" => "Moved to the new shift"
            },
            extra
          ),
        "lines" => lines(qty)
      }
    }
  end

  defp handover(extra \\ %{}) do
    %{
      number_label: "AHO-2",
      content: %{
        "kind" => "handover",
        "header" =>
          Map.merge(
            %{
              "org_unit_id" => @unit_a,
              "from_location_id" => @loc_a,
              "from_material_responsible_id" => @emp_a,
              "to_org_unit_id" => @unit_b,
              "to_location_id" => @loc_b,
              "to_material_responsible_id" => @emp_b,
              "event_time" => "2026-11-03T09:15:00Z"
            },
            extra
          ),
        "lines" => lines("1")
      }
    }
  end

  defp line(data), do: data |> Map.fetch!("lines") |> hd()

  test "G1 change maps the stored facts" do
    data = FormDa4.data(change(), names(), "ru")
    assert data["org_name"] == "Alpha LLP" and data["org_bin"] == "111111111111"
    assert data["sender_unit"] == "Unit A / Hall A" and data["receiver_unit"] == "Unit A / Hall A"
    assert data["responsible"] == "Aidar Giver" and data["handed"] == "Aidar Giver"
    assert data["handed_position"] == "Foreman"
    assert data["accepted"] == "Dana Taker" and data["accepted_position"] == ""
    assert data["number"] == "ACH-7" and data["date"] == "03.11.2026"
    assert data["note"] == "Moved to the new shift"

    assert line(data) == %{
             "no" => "1",
             "name" => "Lathe",
             "acquired" => "01.03.2026",
             "inv" => "INV-1",
             "qty" => "1"
           }
  end

  test "G1b hand over: sender from the giving location, receiver the receiving unit" do
    data = FormDa4.data(handover(), names(), "kk")
    assert data["org_name"] == "Alpha LLP"
    assert data["sender_unit"] == "Unit A / Hall A"
    assert data["receiver_unit"] == "Unit B / Hall B"
    assert data["accepted"] == "Dana Taker"

    empty = FormDa4.data(handover(%{"to_location_id" => nil}), names(), "ru")
    assert empty["receiver_unit"] == "Unit B"
  end

  test "G2 the exact key sets: price, cost and every gap stay out of the map" do
    for issued <- [change(), handover()] do
      data = FormDa4.data(issued, names(), "ru")

      assert Enum.sort(Map.keys(data)) ==
               Enum.sort(
                 ~w(org_name org_bin sender_unit receiver_unit responsible number date note
                            handed handed_position accepted accepted_position lines)
               )

      assert line(data) |> Map.keys() |> Enum.sort() == ~w(acquired inv name no qty)

      for key <- ~w(price cost factory passport unit basis words_qty words_sum chief_acc) do
        refute Map.has_key?(data, key)
        refute Map.has_key?(line(data), key)
      end
    end
  end

  test "G3 quantity text rule and the total row" do
    for {stored, printed} <- [
          {"2.500000000", "2.5"},
          {"1500", "1500"},
          {"abc", "abc"},
          {"1.000000000", "1"}
        ] do
      assert line(FormDa4.data(change(%{}, stored), names(), "ru"))["qty"] == printed
    end

    issued = change()

    two = %{
      issued
      | content: %{
          issued.content
          | "lines" => [
              %{"line_no" => 1, "asset_id" => @card, "quantity" => "1"},
              %{"line_no" => 2, "asset_id" => @card, "quantity" => "2.500000000"}
            ]
        }
    }

    {:ok, layout} = FormPrint.layout("da4")
    model = FormPrint.resolve(layout, FormDa4.data(two, names(), "ru"), "ru", FormPrint.catalog())
    {:table, %{total: total}} = Enum.find(model, &match?({:table, _}, &1))
    assert total["name"] == "Итого"
    assert {total["qty"], total["price"], total["cost"]} == {"3.5", "x", ""}
  end

  test "G4 the act date is the local date" do
    issued = change(%{"event_time" => "2026-11-03T20:00:00Z"})
    n = names(%{offsets: %{event_time: 18_000}})
    assert FormDa4.data(issued, n, "ru")["date"] == "04.11.2026"
  end

  test "G5 the layout validates and builds both formats and languages" do
    {:ok, layout} = FormPrint.layout("da4")
    cat = FormPrint.catalog()
    assert FormPrint.validate_layout(layout, cat) == :ok
    [table] = Enum.filter(layout["blocks"], &(&1["type"] == "table"))
    assert length(table["columns"]) == 10 and length(table["columns"]) <= 14

    assert table["columns"]
           |> Enum.filter(&(&1["group"] == "da1.number"))
           |> Enum.map(& &1["key"]) == ["inv", "factory", "passport"]

    for {key, entry} <- cat,
        String.starts_with?(key, "da4."),
        do: assert(entry["kk_status"] == "official", key)

    for {lang, title} <- [{"ru", "ВНУТРЕННЕЕ ПЕРЕМЕЩЕНИЕ"}, {"kk", "ІШКІ ӨТКІЗУГЕ"}],
        format <- [:pdf, :docx],
        issued <- [change(), handover()] do
      assert {:ok, bin} =
               FormPrint.build("da4", FormDa4.data(issued, names(), lang), lang, format)

      if format == :pdf do
        assert "%PDF-" <> _ = bin
        assert Enum.any?(PdfProbe.items(bin), &(&1 =~ title)), "no #{lang} title item"
        refute Enum.any?(PdfProbe.items(bin), &(&1 =~ "draft" or &1 =~ "черновик"))
      else
        assert "PK" <> _ = bin
      end
    end
  end

  test "G6 hostile values: unknown ids print blank, a long note is capped" do
    gone = names(%{cards: %{}, employees: %{}, legal_entities: %{}})
    data = FormDa4.data(change(), gone, "ru")
    l = line(data)
    assert l["name"] == "" and l["inv"] == "" and l["acquired"] == ""
    assert data["org_name"] == "" and data["responsible"] == "" and data["accepted"] == ""

    assert %{"lines" => []} = FormDa4.data(%{content: %{"kind" => "change"}}, %{}, "ru")

    long = String.duplicate("n", 600)
    {:ok, layout} = FormPrint.layout("da4")

    model =
      FormPrint.resolve(
        layout,
        FormDa4.data(change(%{"note" => long}), names(), "ru"),
        "ru",
        FormPrint.catalog()
      )

    assert {:field, _, shown} = Enum.find(model, &match?({:field, "Примечание", _}, &1))
    assert String.length(shown) < String.length(long)
  end
end
