defmodule Letflow.Scripts.FormsCompareTest do
  @moduledoc """
  `scripts/forms_compare.py` (T-1965): structure summary and diff of .docx files, plus the
  kk wording check. Inputs are built here (two Z-2 files from `FormPrint.build/5`, one
  hand-made reference), so no binary fixture is committed and no Ministry template is copied.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Documents.FormPrint

  @script Path.expand("../../scripts/forms_compare.py", __DIR__)
  @allowed ~w(argparse difflib json os re sys unicodedata zipfile xml.etree.ElementTree)

  defp run(args), do: System.cmd("python3", ["-I", "-B", @script | args], stderr_to_stdout: true)

  defp tmp(name) do
    path = Path.join(System.tmp_dir!(), "t1965_#{System.unique_integer([:positive])}_#{name}")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp data do
    %{
      "org_name" => "ТОО Ромашка",
      "sender" => "ТОО Ромашка",
      "org_bin" => "123456789012",
      "number" => "DOC-7",
      "date" => "05.11.2026",
      "responsible" => "Иванов И.",
      "released" => "Иванов И.",
      "lines" => [
        %{"no" => "1", "name" => "Болт", "nom" => "B-1", "unit" => "шт", "qty_issued" => "1.5"}
      ]
    }
  end

  defp gen(lang) do
    {:ok, bin} = FormPrint.build("z2", data(), lang, :docx)
    path = tmp("gen_#{lang}.docx")
    File.write!(path, bin)
    path
  end

  defp zip(files) do
    path = tmp("ref.docx")
    list = for {n, c} <- files, do: {String.to_charlist(n), c}
    {:ok, _} = :zip.create(String.to_charlist(path), list)
    path
  end

  @ns ~s(xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  defp ref do
    cell = fn text, extra ->
      "<w:tc><w:tcPr>#{extra}</w:tcPr><w:p><w:r><w:t>#{text}</w:t></w:r></w:p></w:tc>"
    end

    doc = """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:document #{@ns}><w:body>
    <w:p><w:r><w:t>Приложение 26 к приказу Министра финансов</w:t></w:r></w:p>
    <w:p><w:r><w:t>Форма З-2</w:t></w:r></w:p>
    <w:p><w:r><w:t>Тестовая строка шаблона</w:t></w:r></w:p>
    <w:tbl><w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>
    <w:tr><w:trPr><w:tblHeader/></w:trPr>#{cell.("Наименование, характеристика", ~s(<w:gridSpan w:val="2"/>))}#{cell.("Единица измерения", "")}</w:tr>
    <w:tr>#{cell.("Болт", ~s(<w:vMerge w:val="restart"/>))}#{cell.("шт", "")}#{cell.("2", "")}</w:tr>
    </w:tbl>
    <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="850" w:bottom="1134" w:left="1276" w:header="708" w:footer="708"/></w:sectPr>
    </w:body></w:document>
    """

    styles = """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:styles #{@ns}><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:sz w:val="24"/></w:rPr></w:rPrDefault></w:docDefaults></w:styles>
    """

    zip([
      {"[Content_Types].xml",
       ~s(<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>)},
      {"word/document.xml", doc},
      {"word/styles.xml", styles}
    ])
  end

  defp json!(args) do
    {out, 0} = run(args)
    Jason.decode!(out)
  end

  test "T1 summary of a generated Z-2 (landscape, TNR 10 pt, table columns from the layout)" do
    s = json!(["summary", gen("ru"), "--json"])
    sec = hd(s["sections"])
    assert {sec["page_w"], sec["page_h"], sec["orientation"]} == {16838, 11906, "landscape"}
    assert sec["margins"]["top"] == 720 and sec["margins"]["left"] == 720
    assert s["default_font"] == %{"name" => "Times New Roman", "size_half_pt" => 20}
    assert s["tables"] != []

    {:ok, layout} = FormPrint.layout("z2")
    table_block = Enum.find(layout["blocks"], &(&1["type"] == "table"))
    assert table_block, "z2 layout has a table block"
    assert hd(s["tables"])["columns"] == length(table_block["columns"])

    first = Enum.find(s["blocks"], &(&1["kind"] == "p"))
    assert first["text"] =~ "Приложение 26"
  end

  test "T2 summary of the hand-made reference" do
    s = json!(["summary", ref(), "--json"])
    sec = hd(s["sections"])
    assert sec["orientation"] == "portrait"

    assert sec["margins"] |> Map.take(["top", "right", "bottom", "left"]) ==
             %{"top" => 1134, "right" => 850, "bottom" => 1134, "left" => 1276}

    assert s["default_font"] == %{"name" => "Arial", "size_half_pt" => 24}
    t = hd(s["tables"])
    assert t["columns"] == 3
    assert t["merged"]["gridspan"] == 1
    assert t["merged"]["vmerge"] >= 1
    assert t["header_rows"] == 1
  end

  test "T3 diff of ru and kk prints: layout facts equal, wording differs" do
    {out, 0} = run(["diff", gen("ru"), gen("kk")])
    lines = String.split(out, "\n", trim: true)
    refute Enum.any?(lines, &String.starts_with?(&1, ~w(PAGE MARGIN FONT HEADER_FOOTER)))
    assert Enum.any?(lines, &String.starts_with?(&1, "TEXT_MISSING"))
  end

  test "T4 diff of reference against generated Z-2 reports page, margins, font, table, text" do
    {out, 0} = run(["diff", ref(), gen("ru")])
    lines = String.split(out, "\n", trim: true)
    assert Enum.any?(lines, &(&1 =~ ~r/^PAGE\t.*portrait.*landscape/))
    assert Enum.any?(lines, &String.starts_with?(&1, "MARGIN"))
    assert Enum.any?(lines, &(&1 =~ ~r/^FONT\t.*Arial.*Times New Roman/))
    assert Enum.any?(lines, &(&1 =~ ~r/^TABLE\t.*columns ref 3/))
    assert Enum.any?(lines, &(&1 =~ ~r/^TEXT_MISSING\t.*тестовая строка шаблона/))
    refute Enum.any?(lines, &String.starts_with?(&1, "TITLE"))
  end

  test "T5 diff --json is a list of maps with category and detail" do
    list = json!(["diff", ref(), gen("ru"), "--json"])
    cats = ~w(PAGE MARGIN HEADER_FOOTER FONT TITLE TABLE_COUNT TABLE TEXT_MISSING TEXT_EXTRA)
    assert is_list(list) and list != []
    assert Enum.all?(list, &(&1["category"] in cats and is_binary(&1["detail"])))
  end

  test "T6 bad input exits 2 with one error line and no traceback" do
    txt = tmp("x.docx")
    File.write!(txt, "not a zip")
    {out, code} = run(["summary", txt])
    assert code == 2
    assert out =~ "forms_compare: error:"
    refute out =~ "Traceback"

    nodoc = zip([{"readme.txt", "hi"}])
    {out2, code2} = run(["summary", nodoc])
    assert code2 == 2
    assert out2 =~ "forms_compare: error:"
    refute out2 =~ "Traceback"
  end

  test "T7 text check: kk wording found in the reference is quiet, other text is reported" do
    kk_text = FormPrint.catalog() |> get_in(["z2.title", "kk"])
    assert is_binary(kk_text)
    reftxt = tmp("ref.txt")
    File.write!(reftxt, "26-қосымша\n#{kk_text}\n")
    {out, 0} = run(["text", gen("kk"), reftxt])
    refute out =~ kk_text
    assert out =~ "TEXT_NOT_IN_REF"
  end

  test "T8 the script imports the standard library only" do
    src = File.read!(@script)

    mods =
      Regex.scan(~r/^(?:import|from)\s+([\w.]+)/m, src)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.uniq()

    assert mods -- @allowed == []
    refute src =~ "lxml"
    refute src =~ "import docx"
  end
end
