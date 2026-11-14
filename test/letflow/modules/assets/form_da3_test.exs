Code.require_file("../stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Assets.FormDa3Test do
  @moduledoc """
  T-1923 (design tests F1..F6): the pure mapper `FormDa3.data/3` and the layout `da3.json`.
  No database: the issued and names maps are built by hand.
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Assets.DocumentPrint
  alias Letflow.Modules.Assets.FormDa3
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  @unit "11111111-1111-1111-1111-111111111111"
  @emp "55555555-5555-5555-5555-555555555555"
  @card "77777777-7777-7777-7777-777777777777"
  @card2 "88888888-8888-8888-8888-888888888888"

  defp kzt_card(extra \\ %{}) do
    Map.merge(
      %{
        inventory_number: "INV-1",
        name: "Lathe",
        acquisition_date: "2026-03-01",
        currency: "KZT",
        acquisition_cost: "1200000.000000000",
        accumulated_depreciation: "49360.500000000",
        book_value: "1150639.500000000",
        depreciation_as_of: "2026-10-31"
      },
      extra
    )
  end

  defp names(card \\ kzt_card(), extra \\ %{}) do
    Map.merge(
      %{
        offsets: %{event_time: 0},
        legal_entities: %{@unit => %{name: "Alpha LLP", bin: "111111111111"}},
        employees: %{@emp => %{full_name: "Aidar Keeper"}},
        positions: %{@emp => "Foreman"},
        cards: %{@card => card, @card2 => kzt_card(%{name: "Press", inventory_number: "INV-2"})}
      },
      extra
    )
  end

  defp writeoff(extra \\ %{}, lines \\ nil) do
    %{
      number_label: "AWO-5",
      content: %{
        "kind" => "writeoff",
        "header" =>
          Map.merge(
            %{
              "org_unit_id" => @unit,
              "material_responsible_id" => @emp,
              "reason_code" => "broken",
              "reason_text" => "Dropped",
              "event_time" => "2026-11-03T09:15:00Z",
              "note" => "not printed"
            },
            extra
          ),
        "lines" => lines || [%{"line_no" => 1, "asset_id" => @card, "quantity" => "1"}]
      }
    }
  end

  defp line(data), do: data |> Map.fetch!("lines") |> hd()
  defp money(v), do: DocumentPrint.number(v, :ru)

  test "F1 maps the stored facts" do
    data = FormDa3.data(writeoff(), names(), "ru")
    assert data["org_name"] == "Alpha LLP" and data["org_bin"] == "111111111111"
    assert data["number"] == "AWO-5" and data["date"] == "03.11.2026"
    assert data["reason"] == "Сломан: Dropped"
    assert data["mol"] == "Aidar Keeper" and data["mol_position"] == "Foreman"
    assert FormDa3.data(writeoff(), names(), "kk")["reason"] == "Сынған: Dropped"

    assert line(data) == %{
             "no" => "1",
             "name" => "Lathe",
             "acquired" => "01.03.2026",
             "inv" => "INV-1",
             "cost" => money("1200000.000000000"),
             "depr" => money("49360.500000000"),
             "book" => money("1150639.500000000")
           }

    two =
      writeoff(%{}, [
        %{"line_no" => 2, "asset_id" => @card2},
        %{"line_no" => 1, "asset_id" => @card}
      ])

    rows = FormDa3.data(two, names(), "ru")["lines"]
    assert Enum.map(rows, &{&1["no"], &1["inv"]}) == [{"1", "INV-1"}, {"2", "INV-2"}]
  end

  test "F2 the exact key sets: the commission and every gap stay out of the map" do
    data = FormDa3.data(writeoff(), names(), "ru")

    assert Enum.sort(Map.keys(data)) ==
             Enum.sort(~w(org_name org_bin number date reason mol mol_position lines))

    assert line(data) |> Map.keys() |> Enum.sort() == ~w(acquired book cost depr inv name no)

    for key <-
          ~w(approver chair member1 member2 state conclusion docs income chief_acc accessories costs released life factory quantity qty) do
      refute Map.has_key?(data, key)
      refute Map.has_key?(line(data), key)
    end
  end

  test "F3 money rules" do
    usd = FormDa3.data(writeoff(), names(kzt_card(%{currency: "USD"})), "ru")
    assert {line(usd)["cost"], line(usd)["depr"], line(usd)["book"]} == {"", "", ""}

    later = FormDa3.data(writeoff(), names(kzt_card(%{depreciation_as_of: "2026-12-01"})), "ru")
    assert line(later)["cost"] == money("1200000.000000000")
    assert {line(later)["depr"], line(later)["book"]} == {"", ""}

    empty = FormDa3.data(writeoff(), names(kzt_card(%{depreciation_as_of: nil})), "ru")
    assert line(empty)["cost"] != "" and line(empty)["depr"] != "" and line(empty)["book"] != ""
  end

  test "F4 the reason rule and the local date" do
    assert FormDa3.data(writeoff(%{"reason_code" => "zzz"}), names(), "ru")["reason"] == "Dropped"

    blank = writeoff(%{"reason_code" => "zzz", "reason_text" => nil})
    assert FormDa3.data(blank, names(), "ru")["reason"] == ""

    other = writeoff(%{"reason_code" => "other", "reason_text" => nil})
    assert FormDa3.data(other, names(), "ru")["reason"] == "Другое"

    other_text = writeoff(%{"reason_code" => "other", "reason_text" => "burnt"})
    assert FormDa3.data(other_text, names(), "ru")["reason"] == "Другое: burnt"
    assert FormDa3.data(other_text, names(), "kk")["reason"] == "Басқа: burnt"

    late = writeoff(%{"event_time" => "2026-11-03T20:00:00Z"})
    n = names(kzt_card(), %{offsets: %{event_time: 18_000}})
    assert FormDa3.data(late, n, "ru")["date"] == "04.11.2026"
  end

  test "F5 the layout validates and builds both formats and languages" do
    {:ok, layout} = FormPrint.layout("da3")
    cat = FormPrint.catalog()
    assert FormPrint.validate_layout(layout, cat) == :ok

    tables = Enum.filter(layout["blocks"], &(&1["type"] == "table"))

    assert Enum.map(tables, &{&1["rows"], length(&1["columns"])}) == [
             {"lines", 10},
             {"accessories", 6},
             {"costs", 9}
           ]

    [a | _] = tables

    assert a["columns"]
           |> Enum.filter(&(&1["group"] == "da1.number"))
           |> Enum.map(& &1["key"]) == ["factory", "inv"]

    for {key, entry} <- cat,
        String.starts_with?(key, "da3."),
        do: assert(entry["kk_status"] == "official", key)

    for {lang, title} <- [{"ru", "АКТ НА ВЫБЫТИЕ"}, {"kk", "ІСТЕН ШЫҒАРУ"}],
        format <- [:pdf, :docx] do
      assert {:ok, bin} =
               FormPrint.build("da3", FormDa3.data(writeoff(), names(), lang), lang, format)

      if format == :pdf do
        assert "%PDF-" <> _ = bin
        assert Enum.any?(PdfProbe.items(bin), &(&1 =~ title)), "no #{lang} title item"
        refute Enum.any?(PdfProbe.items(bin), &(&1 =~ "draft" or &1 =~ "черновик"))
      else
        assert "PK" <> _ = bin
      end
    end
  end

  test "F6 hostile values: unknown ids print blank, a long reason text is capped" do
    gone = names(kzt_card(), %{cards: %{}, employees: %{}, legal_entities: %{}})
    data = FormDa3.data(writeoff(), gone, "ru")
    l = line(data)
    assert l["name"] == "" and l["inv"] == "" and l["cost"] == "" and l["acquired"] == ""
    assert data["org_name"] == "" and data["mol"] == "" and data["mol_position"] == ""

    assert %{"lines" => []} = FormDa3.data(%{content: %{"kind" => "writeoff"}}, %{}, "ru")

    long = String.duplicate("n", 600)
    {:ok, layout} = FormPrint.layout("da3")

    model =
      FormPrint.resolve(
        layout,
        FormDa3.data(writeoff(%{"reason_text" => long}), names(), "ru"),
        "ru",
        FormPrint.catalog()
      )

    assert {:field, _, shown} = Enum.find(model, &match?({:field, "Причина списания", _}, &1))
    assert String.length(shown) < String.length(long)
  end
end
