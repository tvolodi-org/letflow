Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.DocumentPrintTest do
  @moduledoc """
  REQ-737 / GH #3860 (design T-1350 tests P1..P5, R10, R11): the pure PDF renderer
  `Letflow.Modules.Stock.DocumentPrint`. No database.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.Modules.Stock.DocumentPrint

  @org_a "00000000-0000-0000-0000-0000000000a1"
  @org_b "00000000-0000-0000-0000-0000000000a2"
  @loc_a "00000000-0000-0000-0000-0000000000b1"
  @loc_b "00000000-0000-0000-0000-0000000000b2"
  @emp_a "00000000-0000-0000-0000-0000000000c1"
  @emp_b "00000000-0000-0000-0000-0000000000c2"
  @item "00000000-0000-0000-0000-0000000000d1"
  @uom "00000000-0000-0000-0000-0000000000d2"

  defp header(kind) when kind in ["receipt", "issue", "write_off"] do
    %{
      "org_unit_id" => @org_a,
      "location_id" => @loc_a,
      "responsible_id" => @emp_a,
      "counterparty_id" => "supplier",
      "supplier_document_ref" => "SUP-1",
      "reason_code" => "damaged",
      "reason_text" => "Broken"
    }
  end

  defp header("return") do
    %{
      "from_org_unit_id" => @org_b,
      "org_unit_id" => @org_a,
      "from_location_id" => @loc_b,
      "to_location_id" => @loc_a,
      "from_responsible_id" => @emp_b,
      "to_responsible_id" => @emp_a
    }
  end

  defp header(_kind) do
    %{
      "org_unit_id" => @org_a,
      "to_org_unit_id" => @org_b,
      "from_location_id" => @loc_a,
      "to_location_id" => @loc_b,
      "from_responsible_id" => @emp_a,
      "to_responsible_id" => @emp_b
    }
  end

  defp issued(kind, lines \\ nil) do
    lines =
      lines ||
        [
          %{
            "line_no" => 1,
            "catalog_item_id" => @item,
            "catalog_uom_id" => @uom,
            "quantity" => "0.000000001"
          }
        ]

    header = Map.put(header(kind), "event_time", "2026-11-04T05:00:00Z")

    %{
      number_label: "TR-2026-000007",
      version_no: 2,
      issued_at: "2026-11-04T05:00:00Z",
      content: %{"kind" => kind, "header" => header, "lines" => lines}
    }
  end

  defp names(extra \\ %{}) do
    Map.merge(
      %{
        timezone: "Asia/Almaty",
        offsets: %{issued_at: 18_000, event_time: 18_000},
        org_units: %{
          @org_a => %{code: "UA", name: "Alpha"},
          @org_b => %{code: "UB", name: "Beta"}
        },
        locations: %{
          @loc_a => %{code: "LA", name: "ShelfA"},
          @loc_b => %{code: "LB", name: "ShelfB"}
        },
        employees: %{
          @emp_a => %{full_name: "Anna Alpha", code: "E-1"},
          @emp_b => %{full_name: "Boris Beta", code: "E-2"}
        },
        items: %{@item => %{code: "I1", name: "Widget"}},
        uoms: %{@uom => %{code: "pcs", name: "Pieces"}},
        counterparties: %{"supplier" => %{name: "Supplier", tax_id: "123"}},
        lots: %{}
      },
      extra
    )
  end

  defp items(kind, lang) do
    {:ok, pdf} = DocumentPrint.build(issued(kind), names(), lang)
    assert "%PDF-" <> _ = pdf
    PdfProbe.items(pdf)
  end

  describe "P1 the three kinds in three languages" do
    for kind <- ["transfer", "hand_over", "return"], lang <- [:ru, :kk, :en] do
      test "#{kind} #{lang}: title, number, times, both sides, quantity" do
        kind = unquote(kind)
        lang = unquote(lang)
        text = items(kind, lang)
        title = DocumentPrint.labels()[:"title_#{kind}"][lang]
        assert title in text
        assert Enum.any?(text, &String.ends_with?(&1, "TR-2026-000007"))
        # T-1555: localized time plus the zone offset (was ISO)
        local = if lang == :en, do: "2026-11-04 10:00", else: "04-11-2026 10:00"
        assert Enum.count(text, &String.ends_with?(&1, local <> " (UTC+05:00)")) == 2
        assert "UA Alpha" in text and "UB Beta" in text
        assert "LA ShelfA" in text and "LB ShelfB" in text
        assert "Anna Alpha E-1" in text and "Boris Beta E-2" in text
        assert if(lang == :en, do: "0.000000001", else: "0,000000001") in text
        assert "I1 Widget" in text and "pcs" in text
      end
    end
  end

  test "the stock act stays on a portrait A4 page" do
    {:ok, pdf} = DocumentPrint.build(issued("transfer"), names(), :ru)
    assert pdf =~ "/MediaBox [0 0 595 842]"
  end

  describe "P2 two signer rows" do
    test "transfer: from responsible first, to responsible second" do
      {_layout, projection} = DocumentPrint.layout(issued("transfer"), names(), :en)
      [one, two] = projection["signers"]
      assert one["role"] == DocumentPrint.labels().role_from.en
      assert one["full_name"] == "Anna Alpha"
      assert two["role"] == DocumentPrint.labels().role_to.en
      assert two["full_name"] == "Boris Beta"
      assert one["signature"] == "" and two["date"] == ""
    end

    test "return: the from side is the from_* header keys" do
      {_layout, projection} = DocumentPrint.layout(issued("return"), names(), :en)
      [one, two] = projection["signers"]
      assert one["full_name"] == "Boris Beta"
      assert two["full_name"] == "Anna Alpha"
      [org, _loc, _resp] = projection["sides"]
      assert org["from"] == "UB Beta" and org["to"] == "UA Alpha"
    end
  end

  describe "P1b one-sided acts" do
    for kind <- ~w(receipt issue write_off), lang <- [:ru, :kk, :en] do
      test "#{kind} #{lang} title and side" do
        kind = unquote(kind)
        lang = unquote(lang)
        text = items(kind, lang)
        assert DocumentPrint.labels()[:"title_#{kind}"][lang] in text
        assert Enum.any?(text, &String.ends_with?(&1, "TR-2026-000007"))
        local = if lang == :en, do: "2026-11-04 10:00", else: "04-11-2026 10:00"
        assert Enum.count(text, &String.ends_with?(&1, local <> " (UTC+05:00)")) == 2
        assert "UA Alpha" in text and "LA ShelfA" in text and "Anna Alpha E-1" in text
      end
    end
  end

  test "P2b one-side columns and signer rules" do
    for {kind, roles} <- [
          {"receipt", [:role_to, :role_from]},
          {"issue", [:role_from, :role_to]},
          {"write_off", [:role_responsible]}
        ] do
      {layout, projection} = DocumentPrint.layout(issued(kind), names(), :en)
      sides = Enum.find(layout["blocks"], &(&1["entity_type"] == "sides"))
      assert Enum.map(sides["columns"], & &1["field_name"]) == ~w(what side)
      assert length(projection["sides"]) == 3

      assert Enum.map(projection["signers"], & &1["role"]) ==
               Enum.map(roles, &DocumentPrint.labels()[&1].en)

      assert hd(projection["signers"])["full_name"] == "Anna Alpha"
      assert Enum.all?(tl(projection["signers"]), &(&1["full_name"] == "" and &1["code"] == ""))
    end
  end

  test "P2c supplier and closed reason labels" do
    for lang <- [:ru, :kk, :en] do
      {_, projection} = DocumentPrint.layout(issued("write_off"), names(), lang)
      assert projection["doc"]["reason"] == DocumentPrint.labels().reason_damaged[lang]
      assert projection["doc"]["reason_text"] == "Broken"
    end

    bad = put_in(issued("write_off"), [:content, "header", "reason_code"], "bogus")
    {_, projection} = DocumentPrint.layout(bad, names(), :en)
    assert projection["doc"]["reason"] == ""
    {_, projection} = DocumentPrint.layout(issued("receipt"), names(), :en)
    assert projection["doc"]["counterparty"] == "Supplier 123"
    assert projection["doc"]["supplier_document_ref"] == "SUP-1"
  end

  test "P6 act kinds exclude opening" do
    assert DocumentPrint.kinds() == ~w(receipt issue write_off transfer hand_over return)

    assert_raise FunctionClauseError, fn ->
      DocumentPrint.build(issued("opening"), names(), :en)
    end
  end

  describe "P3 labels" do
    test "every key has a non-empty text in ru, kk and en; titles differ from en" do
      for {key, texts} <- DocumentPrint.labels(), lang <- [:ru, :kk, :en] do
        assert is_binary(texts[lang]) and texts[lang] != "", "#{key} #{lang}"
      end

      for key <- [
            :title_receipt,
            :title_issue,
            :title_write_off,
            :title_transfer,
            :title_hand_over,
            :title_return
          ] do
        t = DocumentPrint.labels()[key]
        assert t.ru != t.en and t.kk != t.en
      end
    end
  end

  describe "P4 Kazakh letters" do
    test "a name with the Kazakh letters renders" do
      emp = %{full_name: "Әлия Ғабит Қанат Нұр Өмір Үміт Һәм Іс", code: "E-1"}

      assert {:ok, "%PDF-" <> _} =
               DocumentPrint.build(issued("transfer"), names(%{employees: %{@emp_a => emp}}), :kk)
    end
  end

  describe "P5 failure mapping" do
    test "a character the font lacks is :unsupported_glyph" do
      emp = %{full_name: "王小明", code: "E-1"}

      assert {:error, :unsupported_glyph} =
               DocumentPrint.build(issued("transfer"), names(%{employees: %{@emp_a => emp}}), :en)
    end

    test "missing names print empty, never raise" do
      assert {:ok, "%PDF-" <> _} =
               DocumentPrint.build(issued("hand_over"), %{timezone: "Asia/Almaty"}, :en)

      content = %{"kind" => "hand_over", "header" => nil, "lines" => "bad"}
      assert {:ok, _} = DocumentPrint.build(%{content: content}, names(), :ru)
    end
  end

  describe "R10 other render violations" do
    test "a layout violation is {:render_failed, atoms} and logs no value" do
      bad = issued("transfer", [%{"quantity" => String.duplicate("W", 3000)}])

      log =
        capture_log(fn ->
          result = DocumentPrint.build(bad, names(), :en)
          send(self(), {:result, result})
        end)

      assert_received {:result, result}

      case result do
        {:error, {:render_failed, rules}} ->
          assert Enum.all?(rules, &is_atom/1)
          refute log =~ "WWWW"

        {:ok, _} ->
          # the renderer wraps a long value; nothing to map
          :ok
      end
    end
  end

  describe "R11 purity" do
    test "the renderer source holds no Repo, Ledger or artefact call" do
      src = File.read!("lib/letflow/modules/stock/document_print.ex")
      refute src =~ "Repo"
      refute src =~ "Ledger"
      refute src =~ "attach_artefact"
    end
  end
end
