Code.require_file("../modules/stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Documents.FormPrintInventoryTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  defp tables(bytes) do
    {:ok, files} = :zip.unzip(bytes, [:memory])
    {_, xml} = List.keyfind(files, ~c"word/document.xml", 0)
    Regex.scan(~r/<w:tbl>(.*?)<\/w:tbl>/s, xml) |> Enum.map(&List.last/1)
  end

  defp assert_grid(table, weights) do
    [_, grid] = Regex.run(~r/<w:tblGrid>(.*?)<\/w:tblGrid>/s, table)
    widths = Regex.scan(~r/w:w="(\d+)"/, grid) |> Enum.map(fn [_, w] -> String.to_integer(w) end)
    assert length(widths) == length(weights)

    for {actual, expected} <- Enum.zip(widths, weights) do
      assert_in_delta actual / Enum.sum(widths), expected / Enum.sum(weights), 0.001
    end
  end

  test "I1 inventory forms box organisation and number pairs in both languages" do
    for form <- ~w(inv10 inv18), lang <- ~w(ru kk) do
      {:ok, bytes} =
        FormPrint.build(
          form,
          %{"org_name" => "Organisation", "number" => "INV-TEST"},
          lang,
          :docx
        )

      ts = tables(bytes)
      assert length(ts) == if(form == "inv10", do: 3, else: 4)
      assert Enum.at(ts, 0) =~ "Organisation"
      assert Enum.at(ts, 1) =~ "INV-TEST"

      if form == "inv10" do
        assert_grid(Enum.at(ts, 2), [13.9, 25.3, 8.7, 28.2, 17.5, 15.2, 18.2, 11.3, 18.2, 11.3])
      else
        assert_grid(Enum.at(ts, 2), [
          11.5,
          20.1,
          22.3,
          14.2,
          14,
          8.7,
          14,
          8.7,
          14,
          8.7,
          5.8,
          14,
          8.7,
          5.8
        ])

        assert_grid(Enum.at(ts, 3), [
          17.7,
          11,
          18.9,
          17.7,
          11,
          18.9,
          18.3,
          11.6,
          7.8,
          18.3,
          11.6,
          7.8
        ])
      end

      {:ok, pdf} =
        FormPrint.build(form, %{"org_name" => "Organisation", "number" => "INV-TEST"}, lang, :pdf)

      assert "Organisation" in PdfProbe.items(pdf)
      assert "INV-TEST" in PdfProbe.items(pdf)
    end
  end

  test "I2 Inv-18 has the template's three-level front and regrading headers" do
    for lang <- ~w(ru kk) do
      {:ok, bytes} = FormPrint.build("inv18", %{}, lang, :docx)
      [_, _, front, back] = tables(bytes)
      # Annex 49 has SIX header spans; the report's eight includes two body cells
      # (the instruction 'line to end of page' and the totals label).
      assert length(Regex.scan(~r/<w:gridSpan /, front)) == 6
      assert length(Regex.scan(~r/<w:vMerge/, front)) == 12
      assert length(Regex.scan(~r/<w:gridSpan /, back)) == 5
      assert length(Regex.scan(~r/<w:vMerge/, back)) == 12
      assert front =~ ~s(<w:gridSpan w:val="6"/>)
      assert back =~ ~s(<w:gridSpan w:val="6"/>)
      assert front =~ "<w:noWrap/>"
      assert front =~ ~s(<w:left w:w="15" w:type="dxa"/>)
      cat = FormPrint.catalog()
      assert front =~ cat["inv18.g_results"][lang]
      assert back =~ cat["inv18.g_regrade"][lang]
      {:ok, pdf} = FormPrint.build("inv18", %{}, lang, :pdf)
      assert cat["inv18.g_results"][lang] in PdfProbe.items(pdf)
      assert cat["inv18.g_regrade"][lang] in PdfProbe.items(pdf)
      for no <- ~w(11 14 15 26), do: assert(no in PdfProbe.items(pdf))
    end
  end

  test "I3 groups are bounded catalog paths and draft labels remain visible" do
    {:ok, layout} = FormPrint.layout("inv18")
    table = Enum.find(layout["blocks"], &(&1["type"] == "table"))

    for groups <- [nil, [], "invalid", ["missing"], List.duplicate("inv18.g_results", 3)] do
      bad = put_in(table, ["columns", Access.at(4), "groups"], groups)

      assert {:error, _} =
               FormPrint.validate_layout(%{layout | "blocks" => [bad]}, FormPrint.catalog())
    end

    bad = put_in(table, ["columns", Access.at(4), "group"], "inv18.g_res_surplus")

    assert {:error, _} =
             FormPrint.validate_layout(%{layout | "blocks" => [bad]}, FormPrint.catalog())

    cat = put_in(FormPrint.catalog(), ["inv18.g_results", "kk_status"], "machine_draft")
    assert {:notice, _} = FormPrint.resolve(layout, %{}, "kk", cat) |> List.last()
  end

  test "I4 reverse-side tables start on a new page and quantities keep their precision" do
    for form <- ~w(inv10 inv18), lang <- ~w(ru kk) do
      data = %{
        "lines" => [
          %{
            "name" => "InventoryItem",
            "qty_fact" => "1.500000000",
            "qty_book" => "5.000000000",
            "surplus_qty" => "1.500000000"
          }
        ]
      }

      {:ok, docx} = FormPrint.build(form, data, lang, :docx)
      assert Enum.join(tables(docx)) =~ "1.5"
      refute Enum.join(tables(docx)) =~ "1.500000000"
      {:ok, pdf} = FormPrint.build(form, data, lang, :pdf)
      items = PdfProbe.items(pdf)
      assert "1.5" in items
      refute Enum.any?(items, &Regex.match?(~r/\d\.\d{9}/, &1))
      assert length(Regex.scan(~r/\/Type \/Page \//, pdf)) >= 2

      if form == "inv10" do
        {:ok, files} = :zip.unzip(docx, [:memory])
        {_, xml} = List.keyfind(files, ~c"word/document.xml", 0)
        [first, reverse] = String.split(xml, ~s(<w:br w:type="page"/>))
        refute first =~ "InventoryItem"
        assert reverse =~ "InventoryItem"
      end
    end
  end
end
