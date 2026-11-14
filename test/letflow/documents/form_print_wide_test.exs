Code.require_file("../modules/stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Documents.FormPrintWideTest do
  @moduledoc """
  T-1418 (E5d), design tests E1..E3: the print engine changes for wide tables (14 columns), several
  tables in one PDF, the signature position part and `skip_blank` totals. Pure (no database).
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Documents.FormPrint.Pdf
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  defp docx_xml(bin) do
    {:ok, files} = :zip.unzip(bin, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml
  end

  defp docx_text(bin),
    do: bin |> docx_xml() |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")

  defp wide_data do
    row = fn n ->
      %{"no" => "#{n}", "name" => "Name#{n}", "nom" => "N#{n}", "unit" => "pcs"}
      |> Map.merge(%{
        "surplus_qty" => if(n == 1, do: "2", else: ""),
        "shortage_qty" => if(n == 2, do: "5", else: ""),
        "surplus_sum" => "s#{n}",
        "adj_shortage_acct" => "acct#{n}"
      })
    end

    %{"lines" => [row.(1), row.(2)], "regrade" => [%{}, %{}]}
  end

  describe "E1 layouts" do
    test "every shipped layout validates, every kk entry is official" do
      cat = FormPrint.catalog()
      assert Enum.sort(FormPrint.forms()) == ["inv10", "inv18", "z1", "z2", "z3", "z5", "z6"]

      for form <- FormPrint.forms() do
        {:ok, layout} = FormPrint.layout(form)
        assert FormPrint.validate_layout(layout, cat) == :ok, form

        keys =
          for b <- layout["blocks"],
              k <-
                [b["label"], b["stamp"]] ++
                  Enum.flat_map(b["columns"] || [], &[&1["label"], &1["group"]]) ++
                  [get_in(b, ["totals", "label"])],
              k != nil,
              do: k

        for k <- keys, do: assert(%{"kk_status" => "official"} = cat[k], k)
      end
    end

    test "14 columns are accepted, 15 are refused" do
      {:ok, layout} = FormPrint.layout("inv18")
      cat = FormPrint.catalog()
      front = Enum.find(layout["blocks"], &(&1["rows"] == "lines"))
      assert length(front["columns"]) == 14

      too_wide = %{front | "columns" => front["columns"] ++ [hd(front["columns"])]}
      blocks = Enum.map(layout["blocks"], &if(&1 == front, do: too_wide, else: &1))

      assert {:error, {:bad_columns, _}} =
               FormPrint.validate_layout(%{layout | "blocks" => blocks}, cat)
    end

    test "the back side columns carry their official numbers 15 to 26" do
      {:ok, layout} = FormPrint.layout("inv18")
      back = Enum.find(layout["blocks"], &(&1["rows"] == "regrade"))
      assert Enum.map(back["columns"], & &1["no"]) == Enum.to_list(15..26)
    end
  end

  describe "E2 PDF with a 14-column table and a second table" do
    setup do
      {:ok, layout} = FormPrint.layout("inv18")
      model = FormPrint.resolve(layout, wide_data(), "ru", FormPrint.catalog())
      %{model: model}
    end

    test "chunks of at most 12 keys, column 1 repeated, official header numbers", %{model: model} do
      {blocks, _doc, tables} = Pdf.compile(model)

      front =
        tables |> Enum.filter(fn {et, _} -> String.starts_with?(et, "t11c") end) |> Map.new()

      assert Enum.sort(Map.keys(front)) == ["t11c0", "t11c1"]

      {rows0, keys0} = front["t11c0"]
      {rows1, keys1} = front["t11c1"]
      assert length(keys0) == 12 and length(keys1) == 3
      assert keys1 == ["no", "adj_shortage_sum", "adj_shortage_acct"]
      assert Enum.all?(tables, fn {_et, {_r, keys}} -> length(keys) <= 12 end)

      # each chunk's rows carry only its own keys and its own cell values
      assert Enum.all?(rows0, &(Map.keys(&1) |> Enum.sort() == Enum.sort(keys0)))
      assert Enum.all?(rows1, &(Map.keys(&1) |> Enum.sort() == Enum.sort(keys1)))
      refute Enum.any?(rows1, &Map.has_key?(&1, "surplus_sum"))
      assert Enum.at(rows0, 0)["surplus_sum"] == "s1"

      # the totals row of chunk 1 holds the quantity sums, the all-blank chunk 2 has none
      assert List.last(rows0)["surplus_qty"] == "2"
      assert List.last(rows0)["shortage_qty"] == "5"
      assert length(rows0) == 3 and length(rows1) == 2

      headers =
        for %{"type" => "table", "entity_type" => "t11c1", "columns" => cols} <- blocks,
            c <- cols,
            do: c["header"]

      assert length(headers) == 3
      assert Enum.map(headers, &(&1 |> String.split(".") |> hd())) == ["1", "13", "14"]
    end

    test "the back side is its own table with blank rows; the whole form renders", %{model: model} do
      {_blocks, _doc, tables} = Pdf.compile(model)
      {rows, keys} = tables["t13c0"]
      assert length(keys) == 12 and length(rows) == 2
      assert Enum.all?(rows, fn r -> Enum.all?(r, fn {_k, v} -> v == "" end) end)

      for lang <- ["ru", "kk"] do
        assert {:ok, "%PDF" <> _} = FormPrint.build("inv18", wide_data(), lang, :pdf)
      end
    end

    test "DOCX keeps all 14 columns in one table with a numbers row 1..14 and 15..26" do
      {:ok, docx} = FormPrint.build("inv18", wide_data(), "ru", :docx)
      xml = docx_xml(docx)

      rows =
        for [_, tr] <- Regex.scan(~r/<w:tr>(.*?)<\/w:tr>/s, xml) do
          for [_, tc] <- Regex.scan(~r/<w:tc>(.*?)<\/w:tc>/s, tr) do
            tc |> String.replace(~r/<[^>]+>/, "")
          end
        end

      assert Enum.map(1..14, &Integer.to_string/1) in rows
      assert Enum.map(15..26, &Integer.to_string/1) in rows
      assert length(Regex.scan(~r/<w:gridCol /, xml)) == 14 + 12
    end
  end

  describe "E3 signature position and skip_blank" do
    defp sig_layout do
      %{
        "form_layout_version" => 1,
        "form" => "t",
        "blocks" => [
          %{
            "type" => "signature",
            "label" => "inv18.mol",
            "key" => "mol",
            "parts" => ["position", "signature", "name"]
          }
        ]
      }
    end

    test "a filled position prints in its own DOCX cell part and joined in the PDF" do
      data = %{"mol" => "Иванов И.", "mol_position" => "Кладовщик"}
      opts = [layout: sig_layout()]
      {:ok, docx} = FormPrint.build("t", data, "ru", :docx, opts)
      assert docx_text(docx) =~ "Кладовщик / ____________ / Иванов И."

      {:ok, pdf} = FormPrint.build("t", data, "ru", :pdf, opts)
      assert Enum.any?(PdfProbe.items(pdf), &(&1 =~ "Кладовщик / ____________ / Иванов И."))
    end

    test "an unset position is the blank line, in both formats" do
      opts = [layout: sig_layout()]
      blank = "____________ / ____________ / ____________"
      {:ok, docx} = FormPrint.build("t", %{}, "ru", :docx, opts)
      assert docx_text(docx) =~ blank
      {:ok, pdf} = FormPrint.build("t", %{}, "ru", :pdf, opts)
      assert Enum.any?(PdfProbe.items(pdf), &(&1 =~ blank))
    end

    test "skip_blank sums the filled cells; an invalid text or all blank still blanks the total" do
      {:ok, layout} = FormPrint.layout("inv18")
      cat = FormPrint.catalog()

      total = fn lines ->
        model = FormPrint.resolve(layout, %{"lines" => lines}, "ru", cat)
        {:table, %{total: t}} = Enum.find(model, &match?({:table, %{total: %{}}}, &1))
        t
      end

      mixed = [
        %{"surplus_qty" => "1.5", "shortage_qty" => ""},
        %{"surplus_qty" => "", "shortage_qty" => "2"},
        %{"surplus_qty" => "2.5"}
      ]

      assert total.(mixed)["surplus_qty"] == "4.0"
      assert total.(mixed)["shortage_qty"] == "2"
      assert total.([])["surplus_qty"] == ""
      assert total.([%{"surplus_qty" => ""}])["surplus_qty"] == ""
      assert total.([%{"surplus_qty" => "1"}, %{"surplus_qty" => "abc"}])["surplus_qty"] == ""
    end
  end

  describe "T-1555 paper: landscape PDF, docx header rows and signature keep" do
    test "W1 every official form (9 to 14 columns) prints on a landscape A4" do
      {:ok, wide} = FormPrint.build("inv18", wide_data(), "ru", :pdf)
      assert wide =~ "/MediaBox [0 0 842 595]"

      data = %{"lines" => [%{"no" => "1", "name" => "A", "nom" => "B", "unit" => "pcs"}]}
      {:ok, z2} = FormPrint.build("z2", data, "ru", :pdf)
      assert z2 =~ "/MediaBox [0 0 842 595]"
    end

    test "D2 docx: header and number rows repeat on each page, no row splits across pages" do
      {:ok, docx} = FormPrint.build("inv18", wide_data(), "ru", :docx)
      xml = docx_xml(docx)
      rows = Regex.scan(~r/<w:tr>(.*?)<\/w:tr>/s, xml) |> Enum.map(&List.last/1)
      assert rows != []
      assert Enum.all?(rows, &(&1 =~ "<w:cantSplit/>"))
      heads = Enum.filter(rows, &(&1 =~ "<w:tblHeader/>"))
      # grouped header: two rows, plus the row of column numbers, for each of the two tables
      assert length(heads) >= 3
      assert length(rows) > length(heads)
    end

    test "D3 docx: the signature line is kept with its caption" do
      {:ok, docx} = FormPrint.build("inv18", wide_data(), "ru", :docx)
      assert docx_xml(docx) =~ "<w:pPr><w:keepNext/></w:pPr>"
    end
  end
end
