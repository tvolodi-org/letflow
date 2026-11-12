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
    # a document sheet has no frozen header: nothing to patch, same bytes as Elixlsx
    wb = %Workbook{sheets: [XlsxStyle.style(%Sheet{name: "e", rows: [["k", "v"]]}, false)]}
    {:ok, {_, plain}} = Elixlsx.write_to_memory(wb, "t.xlsx")
    {:ok, {_, ours}} = XlsxStyle.write_to_memory(wb, "t.xlsx")
    # Zip entries carry the write time (DOS time, 2 s resolution), so two writes straddling a
    # tick differ in raw bytes (CI run 42983525653). Unpatched means: same entries, same content.
    assert unzip(plain) == unzip(ours)
  end

  defp unzip(bin) do
    {:ok, entries} = :zip.unzip(bin, [:memory])
    entries |> Enum.map(fn {n, c} -> {to_string(n), c} end) |> Enum.sort()
  end

  describe "CORE S2 cell helpers (canary, values taken from the old module copies)" do
    @at ~U[2026-11-11 10:20:30Z]

    test "cell_text/1" do
      for {input, expected} <- [
            {nil, nil},
            {@at, "2026-11-11T10:20:30Z"},
            {"abc", "abc"},
            {:basis, "basis"},
            {true, "true"},
            {7, "7"},
            {1.5, "1.5"},
            {~D[2026-11-11], ~s("2026-11-11")},
            {%{"a" => 1}, ~s({"a":1})},
            {[1, "x"], ~s([1,"x"])}
          ] do
        assert XlsxStyle.cell_text(input) == expected
      end
    end

    test "cell_scalar/1" do
      for {input, expected} <- [
            {nil, nil},
            {42, 42},
            {1.5, "1.5"},
            {"s", "s"},
            {:a, "a"},
            {@at, "2026-11-11T10:20:30Z"},
            {%{"a" => 1}, ~s({"a":1})}
          ] do
        assert XlsxStyle.cell_scalar(input) == expected
      end
    end

    test "cell_json/1" do
      assert XlsxStyle.cell_json(nil) == nil
      assert XlsxStyle.cell_json(%{"a" => [1]}) == ~s({"a":[1]})
      assert XlsxStyle.cell_json("x") == ~s("x")
      assert XlsxStyle.cell_json(3) == "3"
    end
  end

  # B16#4 canary: expected values taken from the old private copies in assets/xlsx_export.ex
  # and stock/xlsx_export.ex (identical bodies, confirmed by diff before removal).
  describe "cell_quantity/1 and cell_number_or_text/2" do
    test "nil passes through" do
      assert XlsxStyle.cell_quantity(nil) == nil
    end

    test "parseable decimal binary with <=15 significant digits becomes a float" do
      assert XlsxStyle.cell_quantity("1.5") == 1.5
      assert XlsxStyle.cell_quantity("100") == 100.0
    end

    test "non-parseable binary is kept as text" do
      assert XlsxStyle.cell_quantity("abc") == "abc"
      assert XlsxStyle.cell_quantity("1.2.3") == "1.2.3"
    end

    test "Decimal with <=15 significant digits becomes a float" do
      assert XlsxStyle.cell_quantity(Decimal.new("2.5")) == 2.5
    end

    test "Decimal with >15 significant digits keeps its text form" do
      # 16 significant digits: too many for float
      assert XlsxStyle.cell_quantity(Decimal.new("1234567890123456")) ==
               "1234567890123456"
    end

    test "integer is returned unchanged" do
      assert XlsxStyle.cell_quantity(42) == 42
    end

    test "other values fall back to cell_text/1" do
      assert XlsxStyle.cell_quantity(:atom) == "atom"
      assert XlsxStyle.cell_quantity(nil) == nil
    end

    test "cell_number_or_text/2: infinity keeps text form" do
      assert XlsxStyle.cell_number_or_text(Decimal.new("Inf"), "Inf") == "Inf"
    end

    test "cell_number_or_text/2: NaN keeps text form" do
      assert XlsxStyle.cell_number_or_text(Decimal.new("NaN"), "NaN") == "NaN"
    end

    test "cell_number_or_text/2: normal decimal becomes a float" do
      assert XlsxStyle.cell_number_or_text(Decimal.new("3.14"), "3.14") == 3.14
    end
  end
end
