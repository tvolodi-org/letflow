Code.require_file("../modules/stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Documents.PageFurnitureTest do
  @moduledoc "T-1612 P1..P3, D1: PDF page footer and docx column widths of the wide forms."
  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Documents.PrintLayout.{Flow, Font, Pdf}
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  defp lines(n) do
    for i <- 1..n do
      %{"no" => "#{i}", "name" => "Name#{i}", "nom" => "N#{i}", "unit" => "pcs"}
    end
  end

  defp footers(pdf), do: Enum.filter(PdfProbe.items(pdf), &(&1 =~ ~r/^(Страница|Бет) \d+ /))

  test "P1 every page of a multi-page form carries the page N of M line" do
    {:ok, pdf} = FormPrint.build("inv18", %{"lines" => lines(90), "regrade" => []}, "ru", :pdf)
    f = footers(pdf)
    [_, total] = Regex.run(~r/из (\d+)$/, List.last(f))
    n = String.to_integer(total)
    assert n > 1
    assert f == for(k <- 1..n, do: "Страница #{k} из #{n}")

    {:ok, kk} = FormPrint.build("inv18", %{"lines" => lines(90), "regrade" => []}, "kk", :pdf)
    fk = footers(kk)
    assert List.first(fk) == "Бет 1 / #{length(fk)}"
  end

  test "P1 a short form still counts its pages" do
    {:ok, pdf} = FormPrint.build("inv18", %{"lines" => lines(1), "regrade" => []}, "ru", :pdf)
    f = footers(pdf)
    n = length(f)
    assert f == for(k <- 1..n, do: "Страница #{k} из #{n}")
  end

  test "P2 without a footer option the bytes do not change" do
    doc = %{pages: [[]], cps: [65], size: {59_500, 84_200}, margin: 3_400}
    assert Pdf.build(doc) == Pdf.build(doc, [])
    assert Pdf.build(doc) == Pdf.build(doc, footer: nil)
    refute Pdf.build(doc) == Pdf.build(doc, footer: %{word: "P", of: "of"})
    assert {:ok, %{margin: _}} = Flow.run(layout(), %{})
  end

  defp layout,
    do: %{
      "blocks" => [
        %{"type" => "page", "size" => "A4", "margin_mm" => 12, "font" => "dejavu-sans"}
      ]
    }

  test "P3 catalog words have ru, kk, official status and glyphs in the font" do
    cat = FormPrint.catalog()

    for k <- ["page.word", "page.of"] do
      assert %{"ru" => ru, "kk" => kk, "kk_status" => "official"} = cat[k]
      for cp <- String.to_charlist(ru <> kk), do: assert(Font.glyph_id(cp), "#{k} #{cp}")
    end
  end

  test "D1 Inv-18 column widths fit every header word and the page" do
    for lang <- ["ru", "kk"] do
      {:ok, docx} = FormPrint.build("inv18", %{"lines" => lines(2), "regrade" => []}, lang, :docx)
      {:ok, files} = :zip.unzip(docx, [:memory])
      {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)

      [grid | _] = Regex.scan(~r{<w:tblGrid>(.*?)</w:tblGrid>}s, xml, capture: :all_but_first)

      widths =
        Regex.scan(~r/w:w="(\d+)"/, hd(grid)) |> Enum.map(&String.to_integer(List.last(&1)))

      assert length(widths) == 14
      assert Enum.sum(widths) <= 15_400

      # the 3rd column holds "Номенклатурный" (ru): 14 letters need more than the old 958 (LibreOffice breaks it below about 1300)
      if lang == "ru", do: assert(Enum.at(widths, 2) >= 1_300)
      assert Enum.all?(Enum.drop(widths, 2), &(&1 >= 800))
    end
  end
end
