Code.require_file("../modules/stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Documents.FormPrintBlocksTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.Documents.PrintLayout
  alias Letflow.Documents.PrintLayout.{Flow, Font}

  test "B4 PDF annex right edge and signature values above captions" do
    page = %{"type" => "page", "size" => "A4", "margin_mm" => 20, "font" => "dejavu-sans"}
    text = %{"type" => "text", "text" => "Annex 26", "align" => "right"}
    layout = %{"layout_schema_version" => 1, "blocks" => [page, text]}
    assert :ok = PrintLayout.validate(layout, %{})
    {:ok, doc} = Flow.run(layout, %{})
    [{:item, [{x, _, cps}]}] = hd(doc.pages)
    width = Enum.sum(Enum.map(cps, &Font.advance(Font.glyph_id(&1))))
    assert x + width == 59_500 - doc.margin

    for bad <- ["center", 7, nil] do
      assert {:error, _} =
               PrintLayout.validate(
                 %{layout | "blocks" => [page, Map.put(text, "align", bad)]},
                 %{}
               )
    end

    {:ok, form} = FormPrint.layout("z2")
    model = FormPrint.resolve(form, %{"allowed_by" => "Signer"}, "ru", FormPrint.catalog())
    {blocks, fields, tables} = FormPrint.Pdf.compile(model)
    signature = Enum.find(blocks, &(&1["header_position"] == "bottom"))
    layout = %{layout | "blocks" => [page, signature]}
    projection = Map.new(tables, fn {key, {rows, _}} -> {key, rows} end) |> Map.put("doc", fields)
    {:ok, placed} = Flow.run(layout, projection)
    items = for {:item, runs} <- hd(placed.pages), do: runs

    signer =
      Enum.find(items, fn runs ->
        Enum.map_join(runs, fn {_, _, cps} -> List.to_string(cps) end) == "Signer"
      end)

    caption =
      Enum.find(items, fn runs ->
        Enum.map_join(runs, fn {_, _, cps} -> List.to_string(cps) end) ==
          FormPrint.catalog()["cap.name"]["ru"]
      end)

    assert elem(hd(signer), 1) > elem(hd(caption), 1)
    assert Enum.any?(hd(placed.pages), &match?({:rule, _, _, _}, &1))
    assert Enum.any?(hd(placed.pages), &match?({:vrule, _, _, _}, &1))
    declared = Map.new(tables, fn {key, {_, keys}} -> {key, keys} end)

    for bad <- ["side", 7, nil] do
      assert {:error, _} =
               PrintLayout.validate(
                 %{layout | "blocks" => [page, Map.put(signature, "header_position", bad)]},
                 declared
               )
    end
  end

  defp xml(bin) do
    {:ok, files} = :zip.unzip(bin, [:memory])
    {_, xml} = List.keyfind(files, ~c"word/document.xml", 0)
    xml
  end

  test "B1 boxed pairs accept 2 to 8 cells and reject malformed cells" do
    {:ok, layout} = FormPrint.layout("z2")
    pair = %{"key" => "number", "label" => "z2.number"}

    for n <- [2, 5, 8] do
      block = %{"type" => "boxed_pairs", "cells" => List.duplicate(pair, n)}
      assert :ok = FormPrint.validate_layout(%{layout | "blocks" => [block]}, FormPrint.catalog())

      for lang <- ["ru", "kk"], format <- [:docx, :pdf] do
        assert {:ok, bytes} =
                 FormPrint.build("z2", %{}, lang, format, layout: %{layout | "blocks" => [block]})

        if format == :docx, do: assert(length(Regex.scan(~r/<w:tc>/, xml(bytes))) == n * 2)
      end
    end

    for cells <- [
          [],
          [pair],
          List.duplicate(pair, 9),
          [pair, %{"key" => 7, "label" => "z2.number"}],
          [pair, Map.put(pair, "extra", true)],
          [pair, Map.put(pair, "label", "missing")]
        ] do
      assert {:error, _} =
               FormPrint.validate_layout(
                 %{layout | "blocks" => [%{"type" => "boxed_pairs", "cells" => cells}]},
                 FormPrint.catalog()
               )
    end
  end

  test "B2 pilot renders boxes, right annex and ruled signatures in ru and kk" do
    for lang <- ["ru", "kk"] do
      {:ok, layout} = FormPrint.layout("z2")
      assert Enum.count(layout["blocks"], &(&1["type"] == "boxed_pairs")) == 3
      assert Enum.any?(layout["blocks"], &(&1["type"] == "annex_line"))
      assert Enum.count(layout["blocks"], &(&1["type"] == "signature_table")) == 4

      data = %{
        "number" => "PILOT-26",
        "allowed_by" => "Signer",
        "allowed_by_position" => "Director"
      }

      {:ok, docx} = FormPrint.build("z2", data, lang, :docx)
      doc = xml(docx)
      assert doc =~ ~s(<w:jc w:val="right"/>)
      assert length(Regex.scan(~r/<w:tbl>/, doc)) == 8
      assert doc =~ "<w:pBdr><w:bottom"
      assert doc =~ "Director" and doc =~ "Signer"
      assert doc =~ FormPrint.catalog()["z2.mp"][lang]
      assert doc =~ FormPrint.catalog()["z2.number"][lang]
      assert doc =~ ~r/<w:t[^>]*>PILOT-26<\/w:t>/
      tables = Regex.scan(~r/<w:tbl>.*?<\/w:tbl>/s, doc) |> Enum.map(&hd/1)
      [labels, values] = Regex.scan(~r/<w:tr>.*?<\/w:tr>/s, Enum.at(tables, 1)) |> Enum.map(&hd/1)
      assert labels =~ FormPrint.catalog()["z2.number"][lang]
      refute labels =~ "PILOT-26"
      assert values =~ "PILOT-26"
      refute values =~ FormPrint.catalog()["z2.number"][lang]
      {:ok, pdf} = FormPrint.build("z2", data, lang, :pdf)
      items = PdfProbe.items(pdf)

      for value <- ["PILOT-26", "Director", "Signer", FormPrint.catalog()["z2.mp"][lang]] do
        assert value in items
      end
    end
  end

  test "B3 nested draft labels add notice and values are cleaned and escaped" do
    {:ok, layout} = FormPrint.layout("z2")

    block = %{
      "type" => "boxed_pairs",
      "cells" => [%{"key" => "x", "label" => "z2.number"}, %{"key" => "y", "label" => "z2.date"}]
    }

    layout = %{layout | "blocks" => [block]}
    catalog = put_in(FormPrint.catalog(), ["z2.number", "kk_status"], "machine_draft")
    model = FormPrint.resolve(layout, %{"x" => "<x>&" <> <<1>>}, "kk", catalog)
    assert {:notice, _} = List.last(model)

    {:ok, docx} =
      FormPrint.build("z2", %{"x" => "<x>&" <> <<1>>}, "kk", :docx,
        layout: layout,
        catalog: catalog
      )

    assert xml(docx) =~ "&lt;x&gt;&amp;"
    refute xml(docx) =~ <<1>>
  end
end
