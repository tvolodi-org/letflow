defmodule Letflow.Modules.Stock.CountPaperworkTest do
  @moduledoc """
  REQ-719 / GH #3762 criterion 1 (P1..P6): the pure renderer `CountPaperwork.build/3`. No database.
  Read back by unzipping the parts with `:zip.unzip/2`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Stock.CountPaperwork

  @chair "00000000-0000-0000-0000-00000000000c"
  @m1 "00000000-0000-0000-0000-0000000000a1"
  @m2 "00000000-0000-0000-0000-0000000000a2"
  @r1 "00000000-0000-0000-0000-0000000000b1"
  @loc "00000000-0000-0000-0000-0000000000d1"
  @item "00000000-0000-0000-0000-0000000000e1"

  defp order_content(extra \\ %{}) do
    Map.merge(
      %{
        "org_unit_id" => "u1",
        "kind" => "selective",
        "planned_start" => "2026-11-10T04:00:00Z",
        "planned_end" => "2026-11-11T04:00:00Z",
        "chair_employee_id" => @chair,
        "member_employee_ids" => [@m1, @m2],
        "location_ids" => [@loc],
        "note" => "year end"
      },
      extra
    )
  end

  defp sheet_content(lines),
    do: %{"cut_off_at" => "2026-11-10T05:00:00Z", "lines" => lines}

  defp line(n, extra \\ %{}) do
    Map.merge(
      %{
        "line_no" => n,
        "kind" => "book",
        "location_id" => @loc,
        "catalog_item_id" => @item,
        "unit_ref" => "pcs",
        "book_quantity" => "0.000000001",
        "counted_quantity" => "12345678901234.5",
        "responsible_employee_id" => @r1
      },
      extra
    )
  end

  defp issued(content, order \\ nil) do
    %{
      number_label: "CS-2026-0001",
      version_no: 1,
      issued_at: ~U[2026-11-10 05:00:00Z],
      content: content,
      order_content: order || order_content()
    }
  end

  defp names(extra \\ %{}) do
    Map.merge(
      %{
        timezone: "Asia/Almaty",
        offsets: %{
          issued_at: 18_000,
          cut_off_at: 18_000,
          planned_start: 18_000,
          planned_end: 18_000
        },
        org_unit: %{code: "U1", name: "Unit one"},
        employees: %{
          @chair => %{full_name: "Chair Person", code: "E-C"},
          @m1 => %{full_name: "Member One", code: "E-1"},
          @m2 => nil,
          @r1 => %{full_name: "Resp Person", code: "E-R"}
        },
        locations: %{@loc => %{code: "L1", name: "Rack"}},
        items: %{@item => %{code: "I1", name: "Item one"}},
        lots: %{}
      },
      extra
    )
  end

  defp parts(binary) do
    {:ok, files} = :zip.unzip(binary, [:memory])
    Map.new(files, fn {n, c} -> {to_string(n), c} end)
  end

  defp workbook_sheets(binary) do
    parts = parts(binary)
    strings = shared(parts)

    wb = Map.fetch!(parts, "xl/workbook.xml")
    names = Regex.scan(~r/<sheet [^>]*name="([^"]+)"/, wb) |> Enum.map(&List.last/1)

    names
    |> Enum.with_index(1)
    |> Map.new(fn {name, i} ->
      {name, rows(Map.fetch!(parts, "xl/worksheets/sheet#{i}.xml"), strings)}
    end)
  end

  defp shared(parts) do
    xml = Map.fetch!(parts, "xl/sharedStrings.xml")

    Regex.scan(~r/<si>(.*?)<\/si>/s, xml)
    |> Enum.map(fn [_, si] ->
      Regex.scan(~r/<t[^>]*>(.*?)<\/t>/s, si) |> Enum.map_join(fn [_, t] -> unescape(t) end)
    end)
  end

  defp unescape(t),
    do:
      t
      |> String.replace("&amp;", "&")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&apos;", "'")

  # Each row is a list of {type, value}; a string cell is {"s", text}, a number {"n", text}.
  defp rows(xml, strings) do
    Regex.scan(~r/<row [^>]*>(.*?)<\/row>/s, xml)
    |> Enum.map(fn [_, row] ->
      Regex.scan(~r/<c ([^>]*?)(?:\/>|>(.*?)<\/c>)/s, row)
      |> Enum.map(fn [_ | m] ->
        attrs = Enum.at(m, 0)
        body = Enum.at(m, 1) || ""
        type = (Regex.run(~r/ t="(\w+)"/, " " <> attrs) || [nil, "n"]) |> List.last()
        v = (Regex.run(~r/<v>(.*?)<\/v>/, body) || [nil, nil]) |> List.last()
        f? = body =~ "<f"

        cond do
          f? -> {:formula, v}
          type == "s" -> {"s", Enum.at(strings, String.to_integer(v))}
          v == nil -> {"s", ""}
          true -> {type, v}
        end
      end)
    end)
  end

  defp texts(rows), do: Enum.map(rows, fn r -> Enum.map(r, &elem(&1, 1)) end)

  describe "P1 sheets and rows" do
    test "order: document, scope, signatures; no lines" do
      assert {:ok, bin} =
               CountPaperwork.build(:order, issued(order_content(), order_content()), names())

      sheets = workbook_sheets(bin)
      assert Map.keys(sheets) |> Enum.sort() == ["document", "scope", "signatures"]

      doc = texts(sheets["document"])
      assert ["document", "order"] in doc
      assert ["number", "CS-2026-0001"] in doc
      assert ["org_unit", "U1 Unit one"] in doc
      assert ["count_kind", "selective"] in doc
      assert ["planned_start", "2026-11-10T09:00:00+05:00"] in doc
      assert ["note", "year end"] in doc

      scope = texts(sheets["scope"])
      assert ["role", "code", "name"] in scope
      assert ["location", "L1", "Rack"] in scope
      assert ["chair", "E-C", "Chair Person"] in scope
      assert ["member", "E-1", "Member One"] in scope

      assert texts(sheets["signatures"]) == [
               ~w(role full_name personnel_code signature date),
               ["chair", "Chair Person", "E-C", "", ""]
             ]
    end

    test "sheet: document, lines, signatures; lines in line_no order" do
      content = sheet_content([line(2, %{"counted_quantity" => "1"}), line(1)])
      assert {:ok, bin} = CountPaperwork.build(:sheet, issued(content), names())
      sheets = workbook_sheets(bin)
      assert Map.keys(sheets) |> Enum.sort() == ["document", "lines", "signatures"]
      assert ["cut_off_at", "2026-11-10T10:00:00+05:00"] in texts(sheets["document"])

      [header | body] = sheets["lines"]

      assert Enum.map(header, &elem(&1, 1)) |> Enum.take(3) ==
               ~w(line_no location_code location_name)

      refute "difference" in Enum.map(header, &elem(&1, 1))
      assert [{"n", "1"} | _] = hd(body)
      assert [{"n", "2"} | _] = Enum.at(body, 1)

      assert texts(body) |> hd() |> Enum.slice(1, 6) ==
               ["L1", "Rack", "I1", "Item one", "", "Resp Person"]
    end

    test "differences: lines carry difference and direction" do
      lines = [line(1, %{"difference" => "-2", "direction" => "shortage"})]
      content = %{"cut_off_at" => "2026-11-10T05:00:00Z", "lines" => lines}
      assert {:ok, bin} = CountPaperwork.build(:differences, issued(content), names())
      [header, row] = workbook_sheets(bin)["lines"] |> texts()
      assert Enum.take(header, -2) == ["difference", "direction"]
      assert Enum.take(row, -2) == ["-2", "shortage"]
    end
  end

  describe "T4 the unit cell shows the unit of measure name" do
    test "code and name when the master is known, the raw reference when it is not" do
      content = sheet_content([line(1), line(2, %{"unit_ref" => "u-known"})])
      units = %{"u-known" => %{code: "KG", name: "Kilogram"}}

      {:ok, bin} = CountPaperwork.build(:sheet, issued(content), names(%{units: units}))
      [header, first, second] = workbook_sheets(bin)["lines"] |> texts()
      at = Enum.find_index(header, &(&1 == "unit"))
      assert Enum.at(first, at) == "pcs"
      assert Enum.at(second, at) == "KG Kilogram"
    end
  end

  describe "P2 quantities are exact text" do
    test "sheet and differences keep the stored decimal string" do
      for kind <- [:sheet, :differences] do
        content = sheet_content([line(1, %{"difference" => "0.000000001"})])
        {:ok, bin} = CountPaperwork.build(kind, issued(content), names())
        [_, row] = workbook_sheets(bin)["lines"]
        assert {"s", "0.000000001"} in row
        assert {"s", "12345678901234.5"} in row
      end
    end
  end

  describe "P3 no formulas" do
    test "texts starting with = + - @ are string cells" do
      evil = ["=1+1", "+cmd", "-cmd", "@SUM(A1)"]
      order = order_content(%{"note" => hd(evil)})
      {:ok, bin} = CountPaperwork.build(:order, issued(order, order), names())
      refute Enum.any?(parts(bin), fn {_, c} -> c =~ "<f>" end)
      assert ["note", "=1+1"] in texts(workbook_sheets(bin)["document"])

      emp =
        for {t, i} <- Enum.with_index(evil), into: %{}, do: {"e#{i}", %{full_name: t, code: t}}

      lines =
        for {_t, i} <- Enum.with_index(evil),
            do: line(i + 1, %{"responsible_employee_id" => "e#{i}"})

      nm =
        names(%{
          employees: Map.put(emp, @chair, %{full_name: "=boss", code: "E"}),
          items: %{@item => %{code: "-I", name: "@item"}}
        })

      {:ok, bin} = CountPaperwork.build(:sheet, issued(sheet_content(lines)), nm)
      refute Enum.any?(parts(bin), fn {_, c} -> c =~ "<f>" or c =~ "<f " end)
      cells = workbook_sheets(bin)["lines"] |> List.flatten()
      assert {"s", "@item"} in cells and {"s", "+cmd"} in cells
      refute Enum.any?(cells, &match?({:formula, _}, &1))
    end
  end

  describe "P4 time zone" do
    test "Asia/Almaty shows +05:00; a negative offset shows -03:30" do
      {:ok, bin} = CountPaperwork.build(:sheet, issued(sheet_content([])), names())
      doc = texts(workbook_sheets(bin)["document"])
      assert ["issued_at", "2026-11-10T10:00:00+05:00"] in doc
      assert ["timezone", "Asia/Almaty"] in doc

      nm = names(%{offsets: %{issued_at: -12_600}})
      {:ok, bin} = CountPaperwork.build(:sheet, issued(sheet_content([])), nm)
      assert ["issued_at", "2026-11-10T01:30:00-03:30"] in texts(workbook_sheets(bin)["document"])
    end
  end

  describe "P5 signatures" do
    test "sheet: chair, members, responsible; one row per employee; hidden keeps the role" do
      lines = [line(1), line(2, %{"responsible_employee_id" => @m1})]
      {:ok, bin} = CountPaperwork.build(:sheet, issued(sheet_content(lines)), names())
      [header | rows] = texts(workbook_sheets(bin)["signatures"])
      assert header == ~w(role full_name personnel_code signature date)

      assert rows == [
               ["chair", "Chair Person", "E-C", "", ""],
               ["member", "Member One", "E-1", "", ""],
               ["member", "", "", "", ""],
               ["responsible", "Resp Person", "E-R", "", ""]
             ]
    end

    test "differences: only responsible people of difference lines sign" do
      lines = [
        line(1, %{"difference" => "0"}),
        line(2, %{"difference" => "-1", "responsible_employee_id" => @m1})
      ]

      content = %{"cut_off_at" => "2026-11-10T05:00:00Z", "lines" => lines}
      {:ok, bin} = CountPaperwork.build(:differences, issued(content), names())
      roles = workbook_sheets(bin)["signatures"] |> texts() |> tl() |> Enum.map(&hd/1)
      assert roles == ["chair", "member", "member"]
    end
  end

  describe "P6 deterministic" do
    test "two builds of the same input have equal rows" do
      content = sheet_content([line(1), line(2)])
      {:ok, a} = CountPaperwork.build(:sheet, issued(content), names())
      {:ok, b} = CountPaperwork.build(:sheet, issued(content), names())
      assert workbook_sheets(a) == workbook_sheets(b)
    end
  end
end
