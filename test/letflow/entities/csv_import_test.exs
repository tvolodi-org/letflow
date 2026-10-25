defmodule Letflow.Entities.CsvImportTest do
  @moduledoc """
  GH #3182 / REQ-557: the pure CSV converter (no database). U1..U20 of the T-0498 design.
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.CsvImport

  @fields [
    %{"name" => "title", "type" => "string"},
    %{"name" => "note", "type" => "string"},
    %{"name" => "qty", "type" => "integer"},
    %{"name" => "price", "type" => "decimal", "decimal_strict" => true},
    %{"name" => "ratio", "type" => "decimal"},
    %{"name" => "active", "type" => "boolean"},
    %{"name" => "due", "type" => "date"},
    %{"name" => "at", "type" => "datetime"},
    %{"name" => "kind", "type" => "enum"},
    %{"name" => "meta", "type" => "json"},
    %{"name" => "label", "type" => "localized_text"}
  ]

  defp convert(text, opts \\ []), do: CsvImport.convert(text, @fields, opts)

  defp entries(text, opts \\ []) do
    {:ok, rows} = convert(text, opts)
    Enum.map(rows, fn %{result: {:ok, entry}} -> entry end)
  end

  defp one_error(text) do
    {:ok, [row]} = convert(text)
    row
  end

  test "U1: quoted comma, quoted line break with doubled quote, empty cell" do
    text = ~s(title,note\r\n"a, b",x\r\n"line1\r\nsay ""hi""",y\r\nonly,\r\n)

    assert {:ok, rows} = convert(text)

    assert [
             %{line: 2, result: {:ok, %{"field_values" => %{"title" => "a, b", "note" => "x"}}}},
             %{
               line: 3,
               result:
                 {:ok, %{"field_values" => %{"title" => ~s(line1\nsay "hi"), "note" => "y"}}}
             },
             %{line: 5, result: {:ok, %{"field_values" => fv}}}
           ] = rows

    assert fv == %{"title" => "only"}
    refute Map.has_key?(fv, "note")
  end

  test "U2: a BOM changes nothing" do
    text = "title,qty\nA,1\n"
    assert entries("﻿" <> text) == entries(text)
  end

  test "U3: invalid UTF-8 refuses the whole file" do
    assert {:error, :csv_invalid_utf8} = convert("title\n" <> <<0xFF, 0xFE>> <> "\n")
  end

  test "U4: LF and CRLF give identical entries" do
    lf = "title,note\nA,\"x\ny\"\nB,z\n"
    crlf = String.replace(lf, "\n", "\r\n")
    assert entries(lf) == entries(crlf)
  end

  test "U5: a blank line is skipped, later lines keep their physical number" do
    assert {:ok, [%{line: 2}, %{line: 4}]} = convert("title\nA\n\nB\n")
  end

  test "U6: too many or too few cells is a row error with its line" do
    assert {:ok, [r1, r2, r3]} = convert("title,note\nA,B,C\nD\nE,F\n")
    assert %{line: 2, result: {:error, :csv_cell_count, nil}} = r1
    assert %{line: 3, result: {:error, :csv_cell_count, nil}} = r2
    assert %{line: 4, result: {:ok, _}} = r3
  end

  test "U7: an empty body and a BOM-only body have no header" do
    assert {:error, :csv_header_missing} = convert("")
    assert {:error, :csv_header_missing} = convert("﻿")
    assert {:error, :csv_header_missing} = convert("\n\n")
  end

  test "U7b: an unterminated quote or a stray quote is malformed" do
    assert {:error, :csv_malformed} = convert("title\n\"abc\n")
    assert {:error, :csv_malformed} = convert("title\nab\"c\n")
    assert {:error, :csv_malformed} = convert("title\n\"ab\"c\n")
  end

  test "U7c: a header-only file has no rows" do
    assert {:ok, []} = convert("title,note\n")
  end

  test "U8: header refusals, constant reasons" do
    assert {:error, :csv_unknown_header} = convert("title,nope\nA,B\n")
    assert {:error, :csv_duplicate_header} = convert("title,title\nA,B\n")

    assert {:error, :csv_external_ref_pair} =
             convert("title,external_ref_system\nA,B\n", upsert: true)

    assert {:error, :csv_external_ref_pair} =
             convert("title,external_ref_id\nA,B\n", upsert: true)

    # reserved headers only exist in upsert mode
    assert {:error, :csv_unknown_header} =
             convert("title,external_ref_system,external_ref_id\nA,s,1\n")

    assert {:ok, [%{result: {:ok, entry}}]} =
             convert("title,external_ref_system,external_ref_id\nA,s,1\n", upsert: true)

    assert entry == %{
             "field_values" => %{"title" => "A"},
             "external_ref" => %{"system" => "s", "id" => "1"}
           }
  end

  test "U8b: an empty reference cell leaves the key out" do
    assert {:ok, [%{result: {:ok, entry}}]} =
             convert("title,external_ref_system,external_ref_id\nA,,1\n", upsert: true)

    refute Map.has_key?(entry, "external_ref")
  end

  describe "coercion (U9..U17)" do
    test "string and enum are passed on as text" do
      assert [%{"field_values" => %{"title" => "007", "kind" => "weird"}}] =
               entries("title,kind\n007,weird\n")
    end

    test "integer" do
      assert [%{"field_values" => %{"qty" => -12}}] = entries("qty\n-12\n")
      assert %{result: {:error, :csv_invalid_integer, "qty"}} = one_error("qty\n1.5\n")
    end

    test "decimal strict keeps 17 significant digits as a string" do
      assert [%{"field_values" => %{"price" => "12345678901234567.5"}}] =
               entries("price\n12345678901234567.5\n")

      assert %{result: {:error, :csv_invalid_decimal, "price"}} = one_error("price\n1e5\n")
      assert %{result: {:error, :csv_invalid_decimal, "price"}} = one_error("price\nabc\n")
    end

    test "decimal not strict decodes like the JSON number of the same literal" do
      for literal <- ["10", "1.5", "1e2", "-0.25", "12345678901234567.5"] do
        assert [%{"field_values" => %{"ratio" => n}}] = entries("ratio\n#{literal}\n")
        assert n == Jason.decode!(literal)
        assert is_number(n)
      end

      assert %{result: {:error, :csv_invalid_decimal, "ratio"}} =
               one_error("ratio\n1,5\n")
               |> then(&%{&1 | result: {:error, :csv_invalid_decimal, "ratio"}})

      assert %{result: {:error, :csv_invalid_decimal, "ratio"}} = one_error("ratio\nNaN\n")
      assert %{result: {:error, :csv_invalid_decimal, "ratio"}} = one_error("ratio\n.5\n")
    end

    test "boolean, case-insensitive" do
      assert [%{"field_values" => %{"active" => true}}, %{"field_values" => %{"active" => false}}] =
               entries("active\nTRUE\nfalse\n")

      assert %{result: {:error, :csv_invalid_boolean, "active"}} = one_error("active\nyes\n")
    end

    test "date" do
      assert [%{"field_values" => %{"due" => "2026-02-28"}}] = entries("due\n2026-02-28\n")
      assert %{result: {:error, :csv_invalid_date, "due"}} = one_error("due\n2026-02-30\n")
      assert %{result: {:error, :csv_invalid_date, "due"}} = one_error("due\n28/02/2026\n")
    end

    test "datetime needs an offset" do
      assert [%{"field_values" => %{"at" => "2026-02-28T10:00:00Z"}}] =
               entries("at\n2026-02-28T10:00:00Z\n")

      assert %{result: {:error, :csv_invalid_datetime, "at"}} =
               one_error("at\n2026-02-28T10:00:00\n")
    end

    test "json" do
      assert [%{"field_values" => %{"meta" => %{"a" => [1, 2]}}}] =
               entries(~s(meta\n"{""a"": [1, 2]}"\n))

      assert %{result: {:error, :csv_invalid_json, "meta"}} = one_error("meta\n{oops\n")
    end

    test "localized_text must be a JSON object" do
      assert [%{"field_values" => %{"label" => %{"en" => "Hi"}}}] =
               entries(~s(label\n"{""en"": ""Hi""}"\n))

      assert %{result: {:error, :csv_invalid_localized_text, "label"}} =
               one_error("label\nplain\n")

      assert %{result: {:error, :csv_invalid_localized_text, "label"}} = one_error("label\n[1]\n")
    end
  end

  test "U18: the line of a bad row after a multi-line quoted cell; no cell text in the result" do
    text = "title,qty\n\"one\ntwo\nthree\",1\nB,SECRETMARK\n"
    assert {:ok, [ok, bad]} = convert(text)
    assert %{line: 2, result: {:ok, _}} = ok
    assert %{line: 5, result: {:error, :csv_invalid_integer, "qty"}} = bad
    refute inspect(bad) =~ "SECRETMARK"
  end

  test "U19: the converter reaches no database, Ecto or record write function" do
    source = File.read!("lib/letflow/entities/csv_import.ex")
    code = source |> String.split("\n") |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    code = Enum.join(code, "\n")
    # strip the moduledoc, which describes the design in prose
    code = Regex.replace(~r/@moduledoc """.*?"""/s, code, "")

    for forbidden <- ["Repo", "Ecto", "Records", "ImportUpsert"] do
      refute code =~ forbidden, "csv_import.ex mentions #{forbidden}"
    end
  end

  test "U20: more data rows than max_rows is refused before coercion" do
    text = "qty\n" <> String.duplicate("x\n", 5)
    assert {:error, :too_many_records, 5} = convert(text, max_rows: 4)
    assert {:ok, rows} = convert(text, max_rows: 5)
    assert length(rows) == 5
  end
end
