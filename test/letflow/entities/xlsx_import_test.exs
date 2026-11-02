defmodule Letflow.Entities.XlsxImportTest do
  @moduledoc """
  GH #3603 / REQ-650: `Letflow.Entities.XlsxImport`, the pure xlsx converter. Workbooks are
  built in memory by `Letflow.XlsxFixture`. C2 is the happy path side by side with the CSV
  converter, C3a..C3l are the whole-file refusals and limits of criterion 3.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Entities.CsvImport
  alias Letflow.Entities.XlsxImport
  alias Letflow.XlsxFixture

  @fields [
    %{"name" => "title", "type" => "string"},
    %{"name" => "qty", "type" => "integer"},
    %{"name" => "price", "type" => "decimal", "decimal_strict" => true},
    %{"name" => "ratio", "type" => "decimal"},
    %{"name" => "flag", "type" => "boolean"},
    %{"name" => "due", "type" => "date"},
    %{"name" => "at", "type" => "datetime"}
  ]

  defp convert(sheets, opts \\ []),
    do: sheets |> XlsxFixture.build() |> XlsxImport.convert(@fields, opts)

  defp entries(rows), do: for(%{result: {:ok, entry}} <- rows, do: entry)

  describe "C2: happy path" do
    test "C2: the same entries as the CSV converter for the same cell texts" do
      xlsx =
        convert([
          [
            ["title", "qty", "price", "ratio", "flag", "due"],
            ["One", 3, "12.50", 0.25, true, {:date, 45_356}],
            ["Two, with comma", 4.0, "7", 2, false, {:date, 45_357}]
          ]
        ])

      csv =
        CsvImport.convert(
          "title,qty,price,ratio,flag,due\nOne,3,12.50,0.25,true,2024-03-05\n" <>
            "\"Two, with comma\",4,7,2,false,2024-03-06\n",
          @fields
        )

      assert {:ok, xrows} = xlsx
      assert {:ok, crows} = csv
      assert entries(xrows) == entries(crows)
      assert [%{line: 2}, %{line: 3}] = xrows
    end

    test "C2: a date-and-time cell is UTC ISO text, an empty cell has no key" do
      assert {:ok, [%{result: {:ok, entry}}]} =
               convert([[["title", "qty", "at"], ["A", nil, {:datetime, 45_356.5}]]])

      assert entry == %{"field_values" => %{"title" => "A", "at" => "2024-03-05T12:00:00Z"}}
    end

    test "C2: a formula cell is its cached value" do
      assert {:ok, [%{result: {:ok, %{"field_values" => %{"qty" => 3}}}}]} =
               convert([[["qty"], [{:formula, 3}]]])
    end

    test "C2: a number cell without a style attribute is read as its stored text" do
      raw = {:raw, ~s(<c r="B2"><v>12</v></c>)}

      assert {:ok, [%{result: {:ok, %{"field_values" => %{"qty" => 12}}}}]} =
               convert([[["title", "qty"], ["A", raw]]])
    end

    test "C2: line is the sheet row number, blank rows are skipped" do
      assert {:ok, [%{line: 2}, %{line: 5}]} =
               convert([[["title"], ["A"], [nil], [""], ["B"], [nil]]])
    end

    test "C2: upsert mode builds the external_ref pair" do
      assert {:ok, [%{result: {:ok, entry}}]} =
               convert([[["title", "external_ref_system", "external_ref_id"], ["A", "sap", 7]]],
                 upsert: true
               )

      assert entry == %{
               "field_values" => %{"title" => "A"},
               "external_ref" => %{"system" => "sap", "id" => "7"}
             }
    end
  end

  describe "C3: refusals and limits" do
    test "C3a: bytes that are not a zip" do
      assert XlsxImport.convert("not a zip at all", @fields) == {:error, :xlsx_unreadable}
      assert XlsxImport.convert("", @fields) == {:error, :xlsx_unreadable}
    end

    test "C3b: a zip without a workbook" do
      {:ok, {_, zip}} = :zip.create(~c"x.zip", [{~c"hello.txt", "hi"}], [:memory])
      assert XlsxImport.convert(zip, @fields) == {:error, :xlsx_unreadable}
    end

    test "C3c: an XML part with a DOCTYPE, or in UTF-16, is unreadable" do
      doctype = ~s(<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "b">]><x/>)
      lower = ~s(<?xml version="1.0"?><!doctype x><x/>)
      utf16 = :unicode.characters_to_binary("<x/>", :utf8, {:utf16, :little})

      for {part, body} <- [
            {"xl/styles.xml", doctype},
            {"xl/sharedStrings.xml", lower},
            {"xl/styles.xml", <<0xFF, 0xFE>> <> utf16}
          ] do
        bytes = XlsxFixture.build([[["title"], ["A"]]], replace: %{part => body})
        assert XlsxImport.convert(bytes, @fields) == {:error, :xlsx_unreadable}, part
      end
    end

    test "C3d: declared total over the limit is too_large before any part is parsed" do
      big = :binary.copy(<<0>>, XlsxImport.max_inflated_bytes() + 1)

      bytes =
        XlsxFixture.build([[["title"], ["A"]]],
          replace: %{"xl/workbook.xml" => "<<< corrupt"},
          extra: [{"xl/big.bin", big}]
        )

      assert byte_size(bytes) < 2_097_152
      assert XlsxImport.convert(bytes, @fields) == {:error, :xlsx_too_large}
    end

    test "C3e: an empty sheet and a blank header row have no header" do
      assert convert([[]]) == {:error, :xlsx_header_missing}
      assert convert([[[nil, nil]]]) == {:error, :xlsx_header_missing}
    end

    test "C3f: a duplicate header column" do
      assert convert([[["title", "title"], ["A", "B"]]]) == {:error, :xlsx_duplicate_header}
    end

    test "C3g: an unknown header column, and a blank one inside the header" do
      assert convert([[["title", "nope"], ["A", "B"]]]) == {:error, :xlsx_unknown_header}
      assert convert([[["title", nil, "qty"], ["A", nil, 1]]]) == {:error, :xlsx_unknown_header}
    end

    test "C3h: half an external reference pair in upsert mode" do
      assert convert([[["title", "external_ref_system"], ["A", "sap"]]], upsert: true) ==
               {:error, :xlsx_external_ref_pair}

      # without upsert the reference columns are not fields
      assert convert([[["title", "external_ref_system"], ["A", "sap"]]]) ==
               {:error, :xlsx_unknown_header}
    end

    test "C3i: 201 data rows are too many, 200 are fine" do
      rows = fn n -> [["title"] | for(i <- 1..n, do: ["T#{i}"])] end
      assert convert([rows.(201)], max_rows: 200) == {:error, :too_many_records, 201}
      assert {:ok, list} = convert([rows.(200)], max_rows: 200)
      assert length(list) == 200
    end

    test "C3j: a bad cell is a row error with the header, never the cell text" do
      assert {:ok, [bad, good]} = convert([[["title", "qty"], ["A", "abc"], ["B", 2]]])
      assert bad == %{line: 2, result: {:error, :csv_invalid_integer, "qty"}}
      assert {:ok, _entry} = good.result
    end

    test "C3j: a cell beyond the header is a row error, a blank one is ignored" do
      assert {:ok, [bad, ok]} = convert([[["title"], ["A", "x"], ["B", nil]]])
      assert bad == %{line: 2, result: {:error, :xlsx_cell_count, nil}}
      assert {:ok, _} = ok.result
    end

    test "C3k: only the first worksheet is read" do
      assert {:ok, [%{result: {:ok, %{"field_values" => %{"title" => "first"}}}}]} =
               convert([[["title"], ["first"]], [["nope"], ["second"]]])
    end

    test "C3l: garbage never raises" do
      truncated = binary_part(XlsxFixture.build([[["title"], ["A"]]]), 0, 120)

      for bytes <- [<<>>, <<0>>, "PK", "PK\x03\x04", :crypto.strong_rand_bytes(300), truncated] do
        assert {:error, :xlsx_unreadable} = XlsxImport.convert(bytes, @fields)
      end
    end
  end
end
