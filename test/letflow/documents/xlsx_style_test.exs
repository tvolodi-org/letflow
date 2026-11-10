defmodule Letflow.Documents.XlsxStyleTest do
  @moduledoc "T-1612 X1..X3: print titles, landscape and fit to width added to the xlsx zip."
  use ExUnit.Case, async: true

  alias Elixlsx.{Sheet, Workbook}
  alias Letflow.Documents.XlsxStyle

  defp parts(bin) do
    {:ok, files} = :zip.unzip(bin, [:memory])
    Map.new(files, fn {n, c} -> {List.to_string(n), c} end)
  end

  defp write(sheets) do
    {:ok, {_, bin}} = XlsxStyle.write_to_memory(%Workbook{sheets: sheets}, "t.xlsx")
    bin
  end

  test "X1 titles for each header sheet, none for the document sheet" do
    bin =
      write([
        XlsxStyle.style(%Sheet{name: "balances", rows: [["a", "b"], ["1", "2"]]}),
        XlsxStyle.style(%Sheet{name: "doc", rows: [["k", "v"]]}, false),
        XlsxStyle.style(%Sheet{name: "report", rows: [["key", "value"], ["x", "y"]]})
      ])

    wb = parts(bin)["xl/workbook.xml"]
    assert wb =~ ~s(localSheetId="0">'balances'!$1:$1</definedName>)
    assert wb =~ ~s(localSheetId="2">'report'!$1:$1</definedName>)
    refute wb =~ ~s(localSheetId="1")
    assert wb =~ ~r{</sheets><definedNames>.*</definedNames>\s*<calcPr}s
  end

  test "X2 fit to page and landscape after pageMargins; values still read back" do
    bin = write([XlsxStyle.style(%Sheet{name: "s", rows: [["a"], ["1"]]})])
    sheet = parts(bin)["xl/worksheets/sheet1.xml"]
    assert sheet =~ ~s(fitToPage="true")
    refute sheet =~ ~s(fitToPage="false")

    assert sheet =~
             ~r{<pageMargins[^>]*/><pageSetup orientation="landscape" fitToWidth="1" fitToHeight="0"/>}

    assert sheet =~ "<sheetData>"
  end

  test "X3 sheet name with quote and ampersand is escaped" do
    bin = write([XlsxStyle.style(%Sheet{name: "o'k & co", rows: [["a"], ["1"]]})])
    assert parts(bin)["xl/workbook.xml"] =~ "'o''k &amp; co'!$1:$1"
  end

  test "X3 an unmatched anchor returns the unpatched bytes" do
    # a sheet with no rows has no frozen header: nothing to patch, same bytes as Elixlsx
    wb = %Workbook{sheets: [XlsxStyle.style(%Sheet{name: "e", rows: []})]}
    {:ok, {_, plain}} = Elixlsx.write_to_memory(wb, "t.xlsx")
    {:ok, {_, ours}} = XlsxStyle.write_to_memory(wb, "t.xlsx")
    assert plain == ours
  end
end
