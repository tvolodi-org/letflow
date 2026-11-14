defmodule Letflow.Documents.FormPrintPageTest do
  @moduledoc """
  T-1971: the page of an official form (orientation, margins, body size, footer) comes from the
  layout JSON and both renderers honour it; quantities never print nine decimals. Pure.
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint

  defp docx_part(bin, name) do
    {:ok, files} = :zip.unzip(bin, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == String.to_charlist(name) end)
    xml
  end

  defp data do
    line = fn n ->
      for k <-
            ~w(qty qty_doc qty_issued qty_plan qty_fact qty_book mass mass_doc price cost sum surplus_qty shortage_qty),
          into: %{"no" => "#{n}", "name" => "N#{n}", "nom" => "x", "unit" => "pcs"},
          do: {k, "5.000000000"}
    end

    %{"lines" => [line.(1), line.(2)], "regrade" => [%{}, %{}]}
  end

  defp twips(mm), do: round(mm * 56.6929)

  test "P1 every shipped layout declares its page; docx page size and margins equal it" do
    for form <- FormPrint.forms(), lang <- ["ru", "kk"] do
      {:ok, layout} = FormPrint.layout(form)
      assert layout["page"]["orientation"] == "portrait", form
      page = FormPrint.page(layout)
      [t, r, b, l] = Enum.map(page.margins_mm, &twips/1)

      {:ok, docx} = FormPrint.build(form, data(), lang, :docx)
      xml = docx_part(docx, "word/document.xml")
      assert xml =~ ~s(<w:pgSz w:w="11906" w:h="16838"/>), form
      assert xml =~ ~s(<w:pgMar w:top="#{t}" w:right="#{r}" w:bottom="#{b}" w:left="#{l}"), form

      {:ok, pdf} = FormPrint.build(form, data(), lang, :pdf)
      assert pdf =~ "/MediaBox [0 0 595 842]", form
    end
  end

  test "P2 landscape and other margins in the layout reach docx and pdf" do
    {:ok, layout} = FormPrint.layout("z2")

    page = %{
      "orientation" => "landscape",
      "margins_mm" => [10, 11, 12, 13],
      "font_pt" => 11,
      "table_font_pt" => 9
    }

    layout = Map.put(layout, "page", page)
    assert FormPrint.validate_layout(layout, FormPrint.catalog()) == :ok

    {:ok, docx} = FormPrint.build("z2", data(), "ru", :docx, layout: layout)
    xml = docx_part(docx, "word/document.xml")
    assert xml =~ ~s(<w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/>)

    assert xml =~
             ~s(w:top="#{twips(10)}" w:right="#{twips(11)}" w:bottom="#{twips(12)}" w:left="#{twips(13)}")

    assert docx_part(docx, "word/styles.xml") =~ ~s(<w:sz w:val="22"/>)

    {:ok, pdf} = FormPrint.build("z2", data(), "ru", :pdf, layout: layout)
    assert pdf =~ "/MediaBox [0 0 842 595]"
  end

  test "P3 a bad page is refused" do
    {:ok, layout} = FormPrint.layout("z2")
    cat = FormPrint.catalog()

    for bad <- [
          %{"orientation" => "diagonal"},
          %{"margins_mm" => [1, 2, 3]},
          %{"margins_mm" => [1, 2, 3, 99]},
          %{"font_pt" => 0},
          %{"size" => "A3"},
          "portrait"
        ] do
      assert {:error, _} = FormPrint.validate_layout(Map.put(layout, "page", bad), cat),
             inspect(bad)
    end
  end

  test "P4 docx has a footer part with PAGE and NUMPAGES fields" do
    {:ok, docx} = FormPrint.build("z2", data(), "ru", :docx)

    assert docx_part(docx, "word/document.xml") =~
             ~s(<w:footerReference w:type="default" r:id="rId2"/>)

    assert docx_part(docx, "word/_rels/document.xml.rels") =~ "footer1.xml"
    assert docx_part(docx, "[Content_Types].xml") =~ "/word/footer1.xml"
    footer = docx_part(docx, "word/footer1.xml")
    assert footer =~ "PAGE" and footer =~ "NUMPAGES"
  end

  test "P5 no generated form prints nine decimals, in docx text or in the totals" do
    for form <- FormPrint.forms(), lang <- ["ru", "kk"] do
      {:ok, docx} = FormPrint.build(form, data(), lang, :docx)
      refute docx_part(docx, "word/document.xml") =~ ~r/\d\.\d{9}/, form
    end

    # the PDF content streams are compressed or hex, so the model itself is checked as well
    for form <- FormPrint.forms() do
      {:ok, layout} = FormPrint.layout(form)
      model = FormPrint.resolve(layout, data(), "ru", FormPrint.catalog())
      {_blocks, doc, tables} = FormPrint.Pdf.compile(model)

      cells =
        Map.values(doc) ++ for {_, {rows, _}} <- tables, r <- rows, v <- Map.values(r), do: v

      refute Enum.any?(cells, &(is_binary(&1) and &1 =~ ~r/\d\.\d{9}/)), form
    end
  end

  test "P6 number/2: trailing zeros go, decimals pad, identifiers stay" do
    assert FormPrint.number("5.000000000") == "5"
    assert FormPrint.number("1.500000000") == "1.5"
    assert FormPrint.number("21.000000000", 2) == "21.00"
    assert FormPrint.number("12.5", 2) == "12.50"
    assert FormPrint.number("0.123456", 2) == "0.12"
    assert FormPrint.number("0012") == "0012"
    assert FormPrint.number("1.50") == "1.50"
    assert FormPrint.number("abc") == "abc"
    assert FormPrint.number("") == ""
  end

  test "P7 priced columns print two decimals and the total is formatted the same way" do
    {:ok, layout} = FormPrint.layout("z2")
    model = FormPrint.resolve(layout, data(), "ru", FormPrint.catalog())
    {:table, %{rows: rows, total: total}} = Enum.find(model, &match?({:table, _}, &1))
    assert hd(rows)["qty_issued"] == "5"
    assert hd(rows)["price"] == "5.00"
    assert total["qty_issued"] == "10"
  end
end
