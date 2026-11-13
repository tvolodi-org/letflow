Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountWorksheetTest do
  @moduledoc """
  T-1905 (design tests W1..W9): the pure worksheet builder `Letflow.Modules.Stock.CountWorksheet`.
  No database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Codes.Code128
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.Modules.Stock.CountWorksheet

  @chair "00000000-0000-0000-0000-0000000000c1"
  @member "00000000-0000-0000-0000-0000000000a1"
  @resp "00000000-0000-0000-0000-0000000000b1"
  @loc "00000000-0000-0000-0000-0000000000d1"
  @item "00000000-0000-0000-0000-0000000000e1"
  @unit "00000000-0000-0000-0000-0000000000f1"
  @order_id "11111111-2222-3333-4444-555555555555"

  defp line(n),
    do: %{
      "line_no" => n,
      "location_id" => @loc,
      "catalog_item_id" => @item,
      "responsible_employee_id" => @resp,
      "unit_ref" => "pcs",
      "book_quantity" => "987.654"
    }

  defp input(lines, status \\ "counting") do
    order_content = %{
      "chair_employee_id" => @chair,
      "member_employee_ids" => [@member],
      "org_unit_id" => @unit,
      "planned_start" => "2026-11-04T05:00:00Z",
      "planned_end" => "2026-11-05T05:00:00Z"
    }

    %{
      status: status,
      order: %{
        number_label: "CO-2026-000012",
        issued_at: "2026-11-03T05:00:00Z",
        order_id: @order_id,
        content: order_content
      },
      order_id: @order_id,
      lines: lines,
      as_of: "2026-11-04T06:00:00Z",
      as_of_key: :cut_off_at,
      names: %{
        timezone: "Asia/Almaty",
        offsets: %{
          issued_at: 18_000,
          cut_off_at: 18_000,
          planned_start: 18_000,
          planned_end: 18_000
        },
        org_unit: %{code: "U1", name: "Main store"},
        legal_entities: %{@unit => %{name: "Acme LLP", bin: "123456789012"}},
        employees: %{
          @chair => %{full_name: "Chair Person", code: "T1"},
          @member => %{full_name: "Member Person", code: "T2"},
          @resp => %{full_name: "Resp Person", code: "T3"}
        },
        locations: %{@loc => %{code: "L1", name: "Shelf one"}},
        items: %{@item => %{code: "SKU-1", name: "Widget"}},
        lots: %{},
        units: %{"pcs" => %{code: "pcs", name: "pcs"}}
      }
    }
  end

  defp pdf!(input, lang, expected?) do
    assert {:ok, "%PDF-" <> _ = pdf} = CountWorksheet.build_pdf(input, lang, expected?)
    pdf
  end

  describe "W1 / W2 blank and expected variants" do
    test "blank has no expected column and no book quantity; expected has both" do
      inp = input([line(1), line(2)])

      {layout, projection} = CountWorksheet.layout(inp, :ru, false)

      cols =
        for %{"type" => "table", "entity_type" => "lines_0", "columns" => c} <- layout["blocks"],
            do: c

      refute Enum.any?(hd(cols), &(&1["field_name"] == "expected"))
      refute Enum.any?(projection["lines_0"], &Map.has_key?(&1, "expected"))

      blank = pdf!(inp, :ru, false) |> PdfProbe.items()
      refute Enum.any?(blank, &String.contains?(&1, "987"))
      refute "Ожидается (по учёту)" in blank

      expected = pdf!(inp, :ru, true) |> PdfProbe.items()
      assert "Ожидается (по учёту)" in expected
      assert "987,654" in expected
    end
  end

  describe "W3 columns" do
    test "header order and empty counted and notes" do
      inp = input([line(1)])
      {layout, projection} = CountWorksheet.layout(inp, :en, true)
      [cols] = for %{"entity_type" => "lines_0", "columns" => c} <- layout["blocks"], do: c

      assert Enum.map(cols, & &1["header"]) ==
               [
                 "No.",
                 "Location",
                 "Item code",
                 "Name",
                 "Lot",
                 "Unit",
                 "Expected (book)",
                 "Counted qty",
                 "Notes"
               ]

      assert [%{"counted" => "\n", "notes" => ""}] = projection["lines_0"]
    end
  end

  describe "W4 / W5 header, signers, footer" do
    test "header fields, commission, signers and the page footer" do
      texts = pdf!(input([line(1)]), :en, false) |> PdfProbe.items()

      for want <- [
            "Count order: CO-2026-000012",
            "Organisation: Acme LLP",
            "BIN/IIN: 123456789012",
            "Organisation unit: U1 Main store",
            "Order date: 2026-11-03 10:00 (UTC+05:00)",
            "Planned start: 2026-11-04 10:00 (UTC+05:00)",
            "Chair Person",
            "Member Person",
            "Resp Person",
            "Chair",
            "Member",
            "Responsible",
            "Page 1 of 1"
          ] do
        assert want in texts, want
      end

      assert Enum.count(texts, &(&1 == "Resp Person")) == 1
      assert "Бет 1 / 1" in (pdf!(input([line(1)]), :kk, false) |> PdfProbe.items())
    end

    test "the ordered preview says so and prints the book time" do
      texts = pdf!(input([line(1)], "ordered"), :en, false) |> PdfProbe.items()
      assert "Preview: the count sheet lines are fixed when the count is opened" in texts
      assert Enum.any?(texts, &String.starts_with?(&1, "Book as of: "))
    end
  end

  describe "W6 marks" do
    test "barcode and QR rectangles match the encoders and lie in the top margin" do
      {pw, ph} = {84_200, 59_500}
      marks = CountWorksheet.marks("CO-2026-000012", @order_id, {pw, ph}, 5669)
      {:ok, widths} = Code128.encode("CO-2026-000012")
      bars = widths |> Enum.with_index() |> Enum.count(fn {_, i} -> rem(i, 2) == 0 end)
      %{matrix: m} = EQRCode.encode(@order_id, :m)

      dark =
        m
        |> Tuple.to_list()
        |> Enum.map(&(&1 |> Tuple.to_list() |> Enum.count(fn v -> v == 1 end)))
        |> Enum.sum()

      assert length(marks) == bars + dark

      for {:rect, x, y, w, h} <- marks do
        assert x >= 0 and x + w <= pw
        assert y >= ph - 5669 and y + h <= ph
      end

      assert length(CountWorksheet.marks("", @order_id, {pw, ph}, 5669)) == dark
      assert length(CountWorksheet.marks("CO-é", @order_id, {pw, ph}, 5669)) == dark
    end

    test "every page carries the marks" do
      pdf = pdf!(input(Enum.map(1..150, &line/1)), :ru, false)
      streams = pdf_streams(pdf)
      assert length(streams) > 1
      {:ok, widths} = Code128.encode("CO-2026-000012")
      bars = widths |> Enum.with_index() |> Enum.count(fn {_, i} -> rem(i, 2) == 0 end)
      for st <- streams, do: assert(length(Regex.scan(~r/ re f\n/, st)) >= bars)
    end
  end

  describe "W7 paper friendly" do
    test "A4 landscape; no colour operators; only the marks are filled" do
      {layout, _} = CountWorksheet.layout(input([line(1)]), :ru, false)
      assert %{"size" => "A4-landscape"} = hd(layout["blocks"])

      pdf = pdf!(input([line(1)]), :ru, false)
      streams = pdf_streams(pdf)
      assert streams != []
      refute Enum.any?(streams, &Regex.match?(~r/ (rg|RG|k|K|sc|SC|scn|SCN)\n/, &1))
    end
  end

  describe "W8 pagination" do
    @tag timeout: 60_000
    test "150 lines paginate and the header row repeats" do
      pdf = pdf!(input(Enum.map(1..150, &line/1)), :ru, false)
      n = length(Regex.scan(~r/\/Type \/Page /, pdf))
      assert n > 1
      texts = PdfProbe.items(pdf)
      assert "Страница #{n} из #{n}" in texts
      heads = Enum.count(texts, &(&1 == "Фактически"))
      assert heads == n or heads == n - 1
      assert heads > 1
    end
  end

  describe "W9 labels" do
    test "every label has en, ru and kk; the title is printed in each language" do
      for {_k, t} <- CountWorksheet.labels() do
        for lang <- [:en, :ru, :kk], do: assert(Map.fetch!(t, lang) != "")
      end

      for {lang, title} <- [
            {:en, "Count worksheet"},
            {:ru, "Рабочий лист инвентаризации"},
            {:kk, "Түгендеудің жұмыс парағы"}
          ] do
        assert title in (pdf!(input([line(1)]), lang, false) |> PdfProbe.items())
      end
    end
  end

  describe "xlsx" do
    test "document, lines and signatures sheets; counted cells empty" do
      assert {:ok, bin} = CountWorksheet.build_xlsx(input([line(1), line(2)]), :en, false)
      {:ok, files} = :zip.unzip(bin, [:memory])
      names = Map.new(files, fn {n, c} -> {to_string(n), c} end)
      wb = Map.fetch!(names, "xl/workbook.xml")
      assert wb =~ "Document" and wb =~ "Lines" and wb =~ "Signatures"
      refute Map.fetch!(names, "xl/sharedStrings.xml") =~ "987"
    end
  end

  # The inflated page content streams (objects 10, 12, ...).
  defp pdf_streams(bin) do
    for [{s, l}, {ns, nl}, {ds, dl}] <-
          Regex.scan(~r/(\d+) 0 obj\n<< ([^>]*)>>\nstream\n/, bin, return: :index),
        n = bin |> binary_part(ns, nl) |> String.to_integer(),
        n >= 10 and rem(n, 2) == 0,
        [_, len] = Regex.run(~r/\/Length (\d+)/, binary_part(bin, ds, dl)),
        do: :zlib.uncompress(binary_part(bin, s + l, String.to_integer(len)))
  end
end
