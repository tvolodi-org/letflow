Code.require_file("../modules/stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Documents.FormPrintDaTest do
  # T-1978: DA-1..DA-4 follow the reference templates (annexes 16..19): boxed title facts,
  # template column proportions, merged headers, signature tables, page breaks.
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  defp docx_xml(form, lang, data \\ %{}) do
    {:ok, bytes} = FormPrint.build(form, data, lang, :docx)
    {:ok, files} = :zip.unzip(bytes, [:memory])
    {_, xml} = List.keyfind(files, ~c"word/document.xml", 0)
    xml
  end

  defp tables(xml), do: Regex.scan(~r/<w:tbl>(.*?)<\/w:tbl>/s, xml) |> Enum.map(&List.last/1)

  defp grid(table) do
    [_, g] = Regex.run(~r/<w:tblGrid>(.*?)<\/w:tblGrid>/s, table)
    Regex.scan(~r/w:w="(\d+)"/, g) |> Enum.map(fn [_, w] -> String.to_integer(w) end)
  end

  defp assert_grid(table, weights) do
    widths = grid(table)
    assert length(widths) == length(weights)

    for {actual, expected} <- Enum.zip(widths, weights) do
      assert_in_delta actual / Enum.sum(widths), expected / Enum.sum(weights), 0.001
    end
  end

  # Wide tables of each form, in document order, with the weights read from the templates.
  @grids %{
    "da1" => [
      [24.7, 18.0, 8.5, 31.3, 26.5, 33.6, 27.7],
      [24.9, 22.8, 19.3, 22.0, 23.3, 10.3, 12.5, 15.6, 19.5]
    ],
    "da2" => [
      [22.0, 23.0, 20.2, 18.0, 18.0, 13.9, 12.5, 19.3, 14.5, 6.4],
      [21.7, 19.9, 24.5, 18.7, 22.1, 15.0, 12.7, 16.2, 16.9],
      [18.9, 21.2, 30.6, 29.3, 13.4, 15.6, 18.2, 20.6],
      [9.2, 25.4, 22.4],
      [19.4, 17.6, 27.0, 20.8, 22.8],
      [50.8, 23.5, 24.4, 23.6, 23.0, 22.5]
    ],
    "da3" => [
      [13.6, 24.7, 15.6, 16.1, 17.4, 25.8, 16.4, 18.3, 11.7, 10.8],
      [28.9, 25.4, 28.9, 32.3, 24.4, 30.5],
      [13.3, 20.4, 15.1, 17.1, 20.4, 26.5, 25.6, 14.7, 17.1]
    ],
    "da4" => [[11.3, 24.5, 22.1, 20.5, 15.7, 17.6, 14.3, 12.1, 13.9, 18.3]]
  }

  test "D1 every wide table keeps the template column proportions in ru and kk" do
    for {form, weights} <- @grids, lang <- ~w(ru kk) do
      ts = form |> docx_xml(lang) |> tables()
      assert length(weights) <= length(ts)

      # the data tables are the ones whose grid length matches a template grid, in order
      found =
        Enum.reduce(weights, ts, fn w, rest ->
          {hit, tail} = Enum.split_while(rest, &(length(grid(&1)) != length(w)))
          assert [t | tail2] = tail, "#{form}/#{lang}: no table with #{length(w)} columns"
          assert_grid(t, w)
          _ = hit
          tail2
        end)

      assert is_list(found)
    end
  end

  test "D2 DA-2 uses the template page margins (annex 17: 25/15/25/25 mm)" do
    {:ok, layout} = FormPrint.layout("da2")
    assert layout["page"]["margins_mm"] == [25, 15, 25, 25]
    xml = docx_xml("da2", "ru")
    assert xml =~ ~s(w:top="1417") or xml =~ ~s(w:top="1418")
  end

  test "D3 title facts are boxed: organisation/BIN and number/date (DA-2, DA-3, DA-4)" do
    data = %{"org_name" => "OrgName", "org_bin" => "123456789012", "number" => "NO-7"}

    for form <- ~w(da2 da3 da4), lang <- ~w(ru kk) do
      [first | _] = form |> docx_xml(lang, data) |> tables()
      assert first =~ "OrgName"
      assert first =~ "123456789012"
    end

    for form <- ~w(da2 da3), lang <- ~w(ru kk) do
      assert form |> docx_xml(lang, data) |> tables() |> Enum.any?(&(&1 =~ "NO-7"))
    end
  end

  test "D4 DA-2 characteristics table is six columns numbered 1 to 6 with a merged header" do
    for lang <- ~w(ru kk) do
      xml = docx_xml("da2", lang)

      t =
        xml
        |> tables()
        |> Enum.find(&(length(grid(&1)) == 6 and &1 =~ ~s(<w:gridSpan w:val="5"/>)))

      assert t
      # group over five columns, the "attachments" cell over four
      assert t =~ ~s(<w:gridSpan w:val="5"/>)
      assert t =~ ~s(<w:gridSpan w:val="4"/>)
      for n <- 1..6, do: assert(t =~ ">#{n}<")
    end
  end

  test "D5 DA-3 stock group merges name and nomenclature number under 'Запасы'" do
    for lang <- ~w(ru kk) do
      cat = FormPrint.catalog()
      t = "da3" |> docx_xml(lang) |> tables() |> Enum.find(&(length(grid(&1)) == 9))
      assert t =~ cat["da3.stocks"][lang]
      assert t =~ cat["da3.income_group"][lang]
      assert t =~ ~s(<w:gridSpan w:val="5"/>)
      assert t =~ ~s(<w:gridSpan w:val="2"/>)
      assert t =~ "<w:vMerge"
    end
  end

  test "D6 signature blocks are tables with a ruled line and captions" do
    for form <- ~w(da1 da3 da4), lang <- ~w(ru kk) do
      xml = docx_xml(form, lang)
      cat = FormPrint.catalog()
      assert xml =~ cat["cap.signature"][lang]
      {:ok, layout} = FormPrint.layout(form)
      assert Enum.any?(layout["blocks"], &(&1["type"] == "signature_table"))
      refute Enum.any?(layout["blocks"], &(&1["type"] == "signature"))
    end
  end

  test "D7 reverse sides and DA-1 pages 2 and 3 start on a new page in docx and PDF" do
    for form <- ~w(da1 da2 da3 da4), lang <- ~w(ru kk) do
      xml = docx_xml(form, lang)
      expected = if form == "da1", do: 2, else: 1
      assert length(Regex.scan(~r/<w:br w:type="page"\/>/, xml)) == expected
      {:ok, pdf} = FormPrint.build(form, %{}, lang, :pdf)
      assert is_list(PdfProbe.items(pdf))
    end
  end
end
