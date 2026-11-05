Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountPrintTest do
  @moduledoc """
  REQ-736 / GH #3861, criteria 1 to 3 and 8 (design T-1349 tests P1, P2, P3): the pure PDF renderer
  `Letflow.Modules.Stock.CountPrint`. No database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Stock.CountPaperwork
  alias Letflow.Modules.Stock.CountPrint
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  @chair "00000000-0000-0000-0000-0000000000c1"
  @member "00000000-0000-0000-0000-0000000000a1"
  @hidden "00000000-0000-0000-0000-0000000000a2"
  @resp "00000000-0000-0000-0000-0000000000b1"
  @loc "00000000-0000-0000-0000-0000000000d1"
  @item "00000000-0000-0000-0000-0000000000e1"

  defp line(n, extra \\ %{}) do
    Map.merge(
      %{
        "line_no" => n,
        "location_id" => @loc,
        "catalog_item_id" => @item,
        "responsible_employee_id" => @resp,
        "unit_ref" => "pcs",
        "book_quantity" => "0.000000001",
        "counted_quantity" => "12345678901234.5",
        "difference" => "12345678901234.499999999",
        "direction" => "surplus"
      },
      extra
    )
  end

  defp issued(lines) do
    order = %{
      "chair_employee_id" => @chair,
      "member_employee_ids" => [@member, @hidden],
      "location_ids" => [@loc]
    }

    content = %{
      "lines" => lines,
      "cut_off_at" => "2026-11-04T05:00:00Z",
      "planned_start" => "2026-11-04T05:00:00Z",
      "planned_end" => "2026-11-05T05:00:00Z"
    }

    %{
      number_label: "CS-2026-1",
      version_no: 1,
      issued_at: "2026-11-04T05:00:00Z",
      content: content,
      order_content: order
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
        org_unit: %{code: "U1", name: "Main"},
        employees: %{
          @chair => %{full_name: "Chair Person", code: "E-1"},
          @member => %{full_name: "Member One", code: "E-2"},
          @hidden => nil,
          @resp => %{full_name: "Resp Owner", code: "E-3"}
        },
        locations: %{@loc => %{code: "L1", name: "Shelf"}},
        items: %{@item => %{code: "I1", name: "Widget"}},
        lots: %{}
      },
      extra
    )
  end

  defp items(kind, lang, lines \\ [line(1)]) do
    {:ok, pdf} = CountPrint.build(kind, issued(lines), names(), lang)
    assert "%PDF-" <> _ = pdf
    PdfProbe.items(pdf)
  end

  describe "P5 unit of measure name" do
    test "the lines table shows the unit name, the raw ref only when unknown" do
      units = %{"known" => %{code: "KG", name: "Kilogram"}}
      lines = [line(1, %{"unit_ref" => "known"}), line(2)]
      {:ok, pdf} = CountPrint.build(:sheet, issued(lines), names(%{units: units}), :en)
      text = PdfProbe.items(pdf)
      assert Enum.any?(text, &(&1 =~ "KG Kilogram"))
      assert Enum.any?(text, &(&1 =~ "pcs"))
      refute Enum.any?(text, &(&1 =~ "known"))
    end
  end

  describe "P1 the three documents in three languages" do
    for kind <- [:order, :sheet, :differences], lang <- [:ru, :kk, :en] do
      test "#{kind} #{lang}: title, number, time with offset, one signature row per signer" do
        kind = unquote(kind)
        lang = unquote(lang)
        text = items(kind, lang)
        title = CountPrint.labels()[:"title_#{kind}"][lang]
        assert title in text
        assert Enum.any?(text, &String.ends_with?(&1, "CS-2026-1"))
        assert Enum.any?(text, &String.ends_with?(&1, "2026-11-04T10:00:00+05:00"))
        assert "Chair Person" in text and "E-1" in text

        signers = CountPaperwork.signers(kind, issued([line(1)]).order_content, line_list(kind))
        assert length(signers) == expected_signers(kind)

        if expected_signers(kind) > 1 do
          assert "Member One" in text
          assert "Resp Owner" in text
          # the member hidden by scope keeps a signer row with no name
          assert Enum.count(text, &(&1 == CountPrint.labels().role_member[lang])) == 2
        end
      end
    end

    test "quantities are the stored decimal text, unchanged" do
      text = items(:differences, :en)
      assert "0.000000001" in text
      assert "12345678901234.5" in text
      assert "12345678901234.499999999" in text
    end

    test "an order lists locations and the commission" do
      text = items(:order, :en)
      assert "Shelf" in text and "L1" in text
      assert "Chair Person" in text and "Member One" in text
    end

    test "a sheet without lines still renders" do
      assert {:ok, "%PDF-" <> _} = CountPrint.build(:sheet, issued([]), names(), :en)
    end
  end

  defp expected_signers(:order), do: 1
  defp expected_signers(_), do: 4

  defp line_list(:order), do: []
  defp line_list(_), do: [line(1)]

  describe "P2 labels and Kazakh glyphs" do
    test "every label has a non-empty text in ru, kk and en" do
      for {key, texts} <- CountPrint.labels(), lang <- [:ru, :kk, :en] do
        assert is_binary(texts[lang]) and texts[lang] != "", "#{key} #{lang}"
      end
    end

    test "titles differ between languages" do
      for key <- [:title_order, :title_sheet, :title_differences] do
        t = CountPrint.labels()[key]
        assert t.ru != t.en and t.kk != t.en and t.ru != t.kk
      end
    end

    test "Kazakh letters render" do
      name = "Әлия Ғабитқызы Қасым Ңұрлан Өмір Ұлы Үміт Һәм Іздеу"

      nm =
        names(%{
          employees: %{
            @chair => %{full_name: name, code: "E-1"},
            @member => nil,
            @hidden => nil,
            @resp => nil
          }
        })

      assert {:ok, pdf} = CountPrint.build(:order, issued([]), nm, :kk)
      assert name in PdfProbe.items(pdf)
    end

    test "a character outside the font is refused, not replaced" do
      nm = names(%{employees: %{@chair => %{full_name: "Bob 漢字", code: "E-1"}}})
      assert {:error, :unsupported_glyph} = CountPrint.build(:order, issued([]), nm, :en)
    end
  end

  describe "P3 a long sheet" do
    test "2000 lines render in tables of at most 1000 rows" do
      lines = for n <- 1..2000, do: line(n)
      {layout, projection} = CountPrint.layout(:sheet, issued(lines), names(), :en)

      tables = for %{"type" => "table", "entity_type" => et} <- layout["blocks"], do: et
      assert "lines_0" in tables and "lines_1" in tables

      for {_et, rows} <- projection, is_list(rows), do: assert(length(rows) <= 1000)

      {micros, {:ok, pdf}} =
        :timer.tc(fn -> CountPrint.build(:sheet, issued(lines), names(), :en) end)

      IO.puts("2000-line sheet render: #{div(micros, 1000)} ms")
      text = PdfProbe.items(pdf)
      assert "1" in text and "2000" in text
    end
  end
end
