Code.require_file("../stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Assets.FormDa2Test do
  @moduledoc """
  T-1924 (design tests F1..F6): the pure mapper `FormDa2.data/3` and the layout `da2.json`.
  No database: the card and names maps are built by hand.
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Assets.DocumentPrint
  alias Letflow.Modules.Assets.FormDa2
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  @top ~w(org_name org_bin unit mol full_name lines)
  @line ~w(name cost inv acquired depr book)

  defp card(extra \\ %{}) do
    Map.merge(
      %{
        "record_id" => "c-1",
        "name" => "Lathe",
        "inventory_number" => "INV-7",
        "acquisition_date" => "2026-03-01",
        "currency" => "KZT",
        "acquisition_cost" => "1200000.000000000",
        "accumulated_depreciation" => "49360.500000000",
        "book_value" => "1150639.500000000",
        "org_unit_id" => "u1"
      },
      extra
    )
  end

  defp names(holders \\ [], extra \\ %{}) do
    Map.merge(
      %{
        holders: holders,
        org_units: %{"u1" => %{name: "Workshop"}, "u2" => %{name: "Store"}},
        legal_entities: %{
          "u1" => %{name: "LE One", bin: "111111111111"},
          "u2" => %{name: "LE Two", bin: "222222222222"}
        },
        employees: %{"e1" => %{full_name: "Aigul N."}}
      },
      extra
    )
  end

  defp one, do: [%{org_unit: "u2", material_responsible: "e1"}]
  defp line(data), do: data |> Map.fetch!("lines") |> hd()

  test "F1 values with one register holder, ru and kk" do
    for {lang, atom} <- [{"ru", :ru}, {"kk", :kk}] do
      data = FormDa2.data(card(), names(one()), lang)
      assert data["org_name"] == "LE Two" and data["org_bin"] == "222222222222"
      assert data["unit"] == "Store" and data["mol"] == "Aigul N."
      assert data["full_name"] == "Lathe"

      assert line(data) == %{
               "name" => "Lathe",
               "inv" => "INV-7",
               "acquired" => "01.03.2026",
               "cost" => DocumentPrint.number("1200000.000000000", atom),
               "depr" => DocumentPrint.number("49360.500000000", atom),
               "book" => DocumentPrint.number("1150639.500000000", atom)
             }
    end
  end

  test "F2 exact key sets: nothing else is invented" do
    data = FormDa2.data(card(), names(one()), "ru")
    assert Enum.sort(Map.keys(data)) == Enum.sort(@top)
    assert length(data["lines"]) == 1
    assert Enum.sort(Map.keys(line(data))) == Enum.sort(@line)

    for k <- ~w(number date maker model commissioned released factory passport acq_doc acq_no life
                liquidation impairment ownership out_doc out_reason out_income precious repairs
                revaluations moves elements filled kind) do
      refute Map.has_key?(data, k), k
      refute Map.has_key?(line(data), k), k
    end
  end

  test "F3 holder rule: 0 or 2 rows use the card unit and a blank person" do
    two = one() ++ [%{org_unit: "u1", material_responsible: "e1"}]

    for holders <- [[], two] do
      data = FormDa2.data(card(), names(holders), "ru")
      assert data["unit"] == "Workshop" and data["org_name"] == "LE One"
      assert data["mol"] == ""
    end

    unknown = [%{org_unit: "u2", material_responsible: "gone"}]
    assert FormDa2.data(card(), names(unknown), "ru")["mol"] == ""
  end

  test "F4 money only for a KZT card" do
    usd = FormDa2.data(card(%{"currency" => "USD"}), names(), "ru") |> line()
    assert {usd["cost"], usd["depr"], usd["book"]} == {"", "", ""}
    nil_cur = FormDa2.data(card(%{"currency" => nil}), names(), "ru") |> line()
    assert {nil_cur["cost"], nil_cur["depr"], nil_cur["book"]} == {"", "", ""}

    l = FormDa2.data(card(%{"book_value" => nil}), names(), "ru") |> line()
    assert l["book"] == "" and l["cost"] != "" and l["depr"] != ""
  end

  test "F5 the layout validates and builds both formats and languages" do
    {:ok, layout} = FormPrint.layout("da2")
    cat = FormPrint.catalog()
    assert FormPrint.validate_layout(layout, cat) == :ok

    tables = Enum.filter(layout["blocks"], &(&1["type"] == "table"))

    assert Enum.map(tables, &{&1["rows"], length(&1["columns"])}) == [
             {"lines", 10},
             {"lines", 9},
             {"repairs", 8},
             {"revaluations", 3},
             {"moves", 5},
             {"elements", 3}
           ]

    [t1, t2 | _] = tables

    keys = fn t, g ->
      t["columns"] |> Enum.filter(&(&1["group"] == g)) |> Enum.map(& &1["key"])
    end

    assert keys.(t1, "da1.number") == ["inv", "factory", "passport"]
    assert keys.(t1, "da2.acquired") == ["acq_doc", "acq_no", "acquired"]
    assert keys.(t2, "da2.disposed") == ["out_doc", "out_reason", "out_income"]
    assert Enum.map(t2["columns"], & &1["no"]) == Enum.to_list(11..19)

    for {key, entry} <- cat,
        String.starts_with?(key, "da2."),
        do: assert(entry["kk_status"] == "official", key)

    for {lang, title} <- [{"ru", "ИНВЕНТАРНАЯ КАРТОЧКА"}, {"kk", "ТҮГЕНДЕУ КАРТОЧКАСЫ"}],
        format <- [:pdf, :docx] do
      assert {:ok, bin} =
               FormPrint.build("da2", FormDa2.data(card(), names(one()), lang), lang, format)

      if format == :pdf do
        assert "%PDF-" <> _ = bin
        assert Enum.any?(PdfProbe.items(bin), &(&1 =~ title)), "no #{lang} title item"
        refute Enum.any?(PdfProbe.items(bin), &(&1 =~ "draft" or &1 =~ "черновик"))
      else
        assert "PK" <> _ = bin
      end
    end
  end

  test "F6 hostile values: unknown ids print blank, a long name is capped" do
    data = FormDa2.data(%{"record_id" => "x"}, %{}, "ru")
    assert data["org_name"] == "" and data["unit"] == "" and data["mol"] == ""
    l = line(data)
    assert Enum.all?(Map.values(l), &(&1 == ""))

    long = String.duplicate("n", 600)
    {:ok, layout} = FormPrint.layout("da2")

    model =
      FormPrint.resolve(
        layout,
        FormDa2.data(card(%{"name" => long}), names(), "ru"),
        "ru",
        FormPrint.catalog()
      )

    assert {:field, _, shown} =
             Enum.find(model, &match?({:field, "полное наименование и назначение", _}, &1))

    assert String.length(shown) < String.length(long)
  end
end
