defmodule Letflow.Modules.Assets.FormCountInv8Test do
  @moduledoc """
  T-1932 (REQ-821, asset count K6) design tests M1..M5, L1, L2, S1: the pure mapper of the official
  form Инв-8 / Түг-8, its catalog and layout, and the PDF cap.
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Assets.CountPrintSource
  alias Letflow.Modules.Assets.FormCountInv8

  @unit "11111111-1111-4111-8111-111111111111"
  @loc "22222222-2222-4222-8222-222222222222"
  @chair "33333333-3333-4333-8333-333333333333"
  @member "44444444-4444-4444-8444-444444444444"
  @resp1 "55555555-5555-4555-8555-555555555555"
  @resp2 "66666666-6666-4666-8666-666666666666"
  @asset1 "77777777-7777-4777-8777-777777777777"
  @asset2 "88888888-8888-4888-8888-888888888888"

  defp line(no, extra) do
    Map.merge(
      %{
        "line_no" => no,
        "kind" => "book",
        "asset_id" => @asset1,
        "inventory_number" => "INV-#{no}",
        "name" => "Chair #{no}",
        "acquisition_date" => "2024-03-05",
        "book_value" => "1500.50",
        "book_quantity" => "1",
        "counted_quantity" => "1",
        "book_material_responsible_id" => @resp1
      },
      extra
    )
  end

  defp issued(lines \\ nil, content \\ %{}) do
    lines =
      lines ||
        [
          line(2, %{"asset_id" => @asset2, "counted_quantity" => "0"}),
          line(1, %{}),
          line(3, %{
            "kind" => "surplus",
            "book_quantity" => "0",
            "book_value" => nil,
            "observed_material_responsible_id" => @resp2
          }),
          line(4, %{
            "kind" => "surplus",
            "asset_id" => nil,
            "name" => nil,
            "description" => "unknown chair",
            "inventory_number" => nil,
            "acquisition_date" => nil,
            "book_quantity" => "0",
            "book_value" => nil
          })
        ]

    %{
      number_label: "ACS-000007",
      issued_at: "2026-11-05T20:00:00Z",
      content:
        Map.merge(
          %{
            "org_unit_id" => @unit,
            "order_number" => "ACO-1",
            "location_ids" => [@loc],
            "cut_off_at" => "2026-11-05T20:00:00Z",
            "chair_employee_id" => @chair,
            "member_employee_ids" => [@chair, @member],
            "lines" => lines
          },
          content
        )
    }
  end

  defp names(extra \\ %{}) do
    Map.merge(
      %{
        offsets: %{issued_at: 18_000, cut_off_at: 18_000, order_issued_at: 18_000},
        order: %{number_label: "ORD-9", issued_at: "2026-11-01T10:00:00Z"},
        legal_entities: %{@unit => %{name: "Acme LLP", bin: "123456789012"}},
        locations: %{@loc => %{code: "L1", name: "Main office"}},
        employees: %{
          @chair => %{full_name: "Chair Person", code: "E1"},
          @member => %{full_name: "Member One", code: "E2"},
          @resp1 => %{full_name: "Resp One", code: "E3"},
          @resp2 => %{full_name: "Resp Two", code: "E4"}
        },
        positions: %{@chair => "Head", @member => "Clerk", @resp1 => "Keeper", @resp2 => nil},
        card_currency: %{@asset1 => "KZT", @asset2 => "USD"}
      },
      extra
    )
  end

  @top_blank ~w(objects account started ended total_nos_words total_qty_words total_sum
                total_sum_words resp_end resp_end_position resp_date checker checker_position
                checked_date)
  @row_blank ~w(acct released factory passport cost_fact note)

  test "M1: every filled key holds the exact text" do
    d = FormCountInv8.data(issued(), names())

    assert d["org_name"] == "Acme LLP"
    assert d["org_bin"] == "123456789012"
    assert d["number"] == "ACS-000007"
    assert d["date"] == "06.11.2026"
    assert d["cut_off"] == "06.11.2026"
    assert d["location"] == "Main office"
    assert d["order_no"] == "ORD-9"
    assert d["order_date"] == "01.11.2026"
    assert d["resp1"] == "Resp One" and d["resp1_position"] == "Keeper"
    assert d["resp2"] == "Resp Two" and d["resp2_position"] == ""
    assert d["chair"] == "Chair Person" and d["chair_position"] == "Head"
    assert d["member1"] == "Member One" and d["member1_position"] == "Clerk"
    assert d["member2"] == "" and d["member2_position"] == ""

    assert [r1, r2, r3, r4] = d["lines"]

    assert r1 == %{
             "no" => "1",
             "name" => "Chair 1",
             "inv" => "INV-1",
             "acquired" => "05.03.2024",
             "qty_fact" => "1",
             "qty_book" => "1",
             "cost_book" => "1500.50"
           }

    assert r2["no"] == "2" and r3["no"] == "3" and r4["no"] == "4"
  end

  test "M2: blank keys are never in the map" do
    d = FormCountInv8.data(issued(), names())
    for k <- @top_blank, do: refute(Map.has_key?(d, k), k)

    for row <- d["lines"], k <- @row_blank do
      refute Map.has_key?(row, k), k
    end
  end

  test "M3: cost only on a KZT book line; a surplus line without a card prints its description" do
    [r1, r2, r3, r4] = FormCountInv8.data(issued(), names())["lines"]
    assert r1["cost_book"] == "1500.50"
    # line 2 is a book line of a USD card
    assert r2["cost_book"] == ""
    # line 3 is a surplus line of a KZT card
    assert r3["cost_book"] == "" and r3["qty_book"] == "0"
    assert r4["name"] == "unknown chair" and r4["inv"] == "" and r4["acquired"] == ""
    assert r4["cost_book"] == ""
  end

  test "M4: location, unknown employee, joined responsible persons, chair kept out of members" do
    content = %{"location_ids" => [@loc, Ecto.UUID.generate()]}
    assert FormCountInv8.data(issued(nil, content), names())["location"] == ""
    assert FormCountInv8.data(issued(nil, %{"location_ids" => []}), names())["location"] == ""

    gone = names(%{employees: %{}, positions: %{}})
    d = FormCountInv8.data(issued(), gone)
    assert d["chair"] == "" and d["resp1"] == "" and d["member1"] == ""

    members = %{"member_employee_ids" => [@chair, @member, @resp1]}
    d = FormCountInv8.data(issued(nil, members), names())
    assert d["member1"] == "Member One" and d["member2"] == "Resp One"

    two = [line(1, %{"observed_material_responsible_id" => @resp2})]
    d = FormCountInv8.data(issued(two), names())
    assert d["resp1"] == "Resp One" and d["resp2"] == "Resp Two"
  end

  test "M5: totals" do
    d = FormCountInv8.data(issued(), names())
    assert d["total_nos"] == "4"
    # 1 + 0 + 1 + 1
    assert d["total_qty"] == "3"

    empty = FormCountInv8.data(issued([]), names())
    assert empty["total_nos"] == "" and empty["total_qty"] == "" and empty["lines"] == []
  end

  describe "catalog and layout" do
    test "L1: every label is in the catalog with an official ru and kk text; kk title = row 39" do
      {:ok, layout} = FormPrint.layout("inv8")
      catalog = FormPrint.catalog()
      assert FormPrint.validate_layout(layout, catalog) == :ok

      labels =
        for b <- layout["blocks"],
            l <-
              [b["label"]] ++
                Enum.flat_map(b["columns"] || [], &[&1["label"], &1["group"]]) ++
                [get_in(b, ["totals", "label"])],
            is_binary(l),
            do: l

      for l <- Enum.uniq(labels) do
        entry = Map.fetch!(catalog, l)
        assert is_binary(entry["ru"]) and entry["ru"] != "", l
        assert is_binary(entry["kk"]) and entry["kk"] != "", l
        assert entry["kk_status"] == "official", l
      end

      md = File.read!("docs/assets/kz-forms-mapping.md")
      [_, kk_title] = Regex.run(~r/^\| 39 \| Инв-8 \| Түг-8 \| (.+?) \|/mu, md)
      assert catalog["inv8.title"]["kk"] == kk_title
    end

    test "L2: the form builds in ru and kk, pdf and docx; 13 numbered header cells" do
      data = FormCountInv8.data(issued(), names())

      for lang <- ["ru", "kk"], format <- [:pdf, :docx] do
        assert {:ok, bin} = FormPrint.build("inv8", data, lang, format)
        assert binary_part(bin, 0, 2) == if(format == :pdf, do: "%P", else: "PK")
      end

      {:ok, bin} = FormPrint.build("inv8", data, "ru", :docx)
      {:ok, files} = :zip.unzip(bin, [:memory])
      {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
      text = String.replace(xml, ~r/<[^>]+>/, "|")

      for n <- 1..13, do: assert(text =~ "|#{n}|", "header cell #{n}")
    end
  end

  test "S1: 999 lines fit a form PDF, 1000 do not" do
    lines = fn n -> %{content: %{"lines" => for(i <- 1..n, do: %{"line_no" => i})}} end
    refute CountPrintSource.pdf_too_large?(lines.(999))
    assert CountPrintSource.pdf_too_large?(lines.(1000))
  end
end
