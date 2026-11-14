Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.FormZ7Test do
  @moduledoc """
  T-1925 (audit slice 9), design tests F1..F4: the Z-7 data map (blank gaps, formatting), a header of
  only nils, and the layout against the catalog (build in ru and kk, both formats).
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.Modules.Stock.FormZ7

  @blank ~w(qty price norm open_sum in_sum out_sum)

  defp sheet do
    %{
      header: %{
        org_name: "ТОО Тест",
        org_bin: "123456789012",
        location_name: "Central",
        location_code: "L1",
        struct_unit: "Склад-1",
        mol_name: "Иванов И.",
        made_on: ~D[2026-11-14],
        from: ~D[2026-11-01],
        to: ~D[2026-11-07]
      },
      rows: [
        %{
          name: "Laptop",
          nom: "N-1",
          unit: "шт",
          opening: Decimal.new("2.000000000"),
          income: Decimal.new("1.500000000"),
          expense: Decimal.new(0),
          closing: Decimal.new("3.500000000")
        },
        %{
          name: "Mouse",
          nom: "N-2",
          unit: "шт",
          opening: Decimal.new(0),
          income: nil,
          expense: Decimal.new("1"),
          closing: Decimal.new("-1")
        }
      ]
    }
  end

  test "F1 the key sets, and every gap is an empty text" do
    d = FormZ7.data(sheet())

    assert Enum.sort(Map.keys(d)) ==
             ~w(accountant head lines mol mol_position mol_sign org_bin org_name shop warehouse)

    for k <- ~w(shop mol_position mol_sign accountant), do: assert(d[k] == "")
    [head] = d["head"]
    assert Enum.sort(Map.keys(head)) == ~w(made number pantry period shop unit warehouse)
    for k <- ~w(number shop pantry), do: assert(head[k] == "")

    [line | _] = d["lines"]

    assert Enum.sort(Map.keys(line)) ==
             ~w(close_qty in_qty in_sum name no nom norm open_qty open_sum out_qty out_sum price qty unit)

    for k <- @blank, do: assert(line[k] == "")
  end

  test "F2 values: dates, decimals, zero and nil blank, numbering" do
    d = FormZ7.data(sheet())
    [head] = d["head"]
    assert head["made"] == "14.11.2026"
    assert head["period"] == "01.11.2026 – 07.11.2026"
    assert head["unit"] == "Склад-1" and head["warehouse"] == "Central"
    assert d["mol"] == "Иванов И."

    [a, b] = d["lines"]
    assert [a["no"], b["no"]] == ["1", "2"]
    assert a["open_qty"] == "2.000000000" and a["in_qty"] == "1.500000000"
    assert a["out_qty"] == "" and a["close_qty"] == "3.500000000"
    assert b["open_qty"] == "" and b["in_qty"] == "" and b["out_qty"] == "1"
    assert b["close_qty"] == "-1"
  end

  test "F3 a header of nils gives empty texts and no crash" do
    d = FormZ7.data(%{header: %{}, rows: []})
    assert d["org_name"] == "" and d["warehouse"] == "" and d["mol"] == ""
    assert [%{"made" => "", "period" => " – "}] = d["head"]
    assert d["lines"] == []
  end

  test "F4 the layout is valid, 14 columns, official wording, builds in ru and kk" do
    {:ok, layout} = FormPrint.layout("z7")
    assert "z7" in FormPrint.forms()
    lines = layout["blocks"] |> Enum.filter(&(&1["type"] == "table")) |> List.last()
    assert length(lines["columns"]) == 14

    for {lang, title} <- [
          {"ru", "Ведомость учета остатков запасов на складе"},
          {"kk", "ҚОЙМАДАҒЫ ҚОРЛАРДЫҢ ҚАЛДЫҚТАРЫН ЕСЕПКЕ АЛУ ТІЗІМДЕМЕСІ"}
        ] do
      assert {:ok, pdf} = FormPrint.build("z7", FormZ7.data(sheet()), lang, :pdf)
      assert "%PDF" <> _ = pdf
      items = PdfProbe.items(pdf)
      assert title in items
      refute Enum.any?(items, &(&1 =~ "Машиналық аударма"))
      assert {:ok, "PK" <> _} = FormPrint.build("z7", FormZ7.data(sheet()), lang, :docx)
    end
  end
end
