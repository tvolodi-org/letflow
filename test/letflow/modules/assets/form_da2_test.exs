Code.require_file("../stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Assets.FormDa2Test do
  @moduledoc """
  T-1924 (design tests F1..F6): the pure mapper `FormDa2.data/3` and the layout `da2.json`.
  No database: the card and names maps are built by hand.
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Assets.DocumentPrint
  alias Letflow.Modules.Assets.FormDa2
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  # One row per layout path: source and applicability. Manual entries are explicit gaps,
  # not invented events. Commission-document sources are the ordered slice 1b remainder.
  @sources [
    {"org_name", "org_legal_entity.name", :always},
    {"org_bin", "org_legal_entity.bin", :always},
    {"unit", "org_unit.name (single register holder, else card.org_unit_id)", :always},
    {"mol", "org_employee.full_name (single register holder)", :after_commission},
    {"number", "commission document.number (slice 1b)", :manual},
    {"date", "commission document.issued_at (slice 1b)", :manual},
    {"full_name", "assets_card.name", :always},
    {"maker", "assets_card.manufacturer", :always},
    {"model", "assets_card.asset_type,model,type,brand,category,sort", :always},
    {"lines.name", "assets_card.name", :always},
    {"lines.cost", "assets_card.acquisition_cost (KZT only)", :always},
    {"lines.commissioned",
     "assets_card.commissioning_date; commission act number pending slice 1b", :after_commission},
    {"lines.released", "manufacture year: not captured", :manual},
    {"lines.inv", "assets_card.inventory_number", :always},
    {"lines.factory", "assets_card.serial_number", :always},
    {"lines.passport", "assets_card.passport_number", :always},
    {"lines.acq_doc", "commission document kind (slice 1b)", :manual},
    {"lines.acq_no", "commission document.number (slice 1b)", :manual},
    {"lines.acquired", "assets_card.acquisition_date", :always},
    {"lines.life", "assets_card.useful_life_months (months)", :always},
    {"lines.depr", "assets_card.accumulated_depreciation (KZT only)", :always},
    {"lines.liquidation", "residual value: not captured", :"on_event:disposal"},
    {"lines.impairment", "impairment loss: not captured", :"on_event:revaluation"},
    {"lines.ownership", "ownership: not captured", :manual},
    {"lines.out_doc", "disposal document: pending history slice", :"on_event:disposal"},
    {"lines.out_reason", "disposal reason: pending history slice", :"on_event:disposal"},
    {"lines.out_income", "disposal proceeds: pending history slice", :"on_event:disposal"},
    {"lines.book", "assets_card.book_value (KZT only)", :always},
    {"precious", "precious metals: manual declaration", :manual},
    {"repairs.m_date", "modernisation document date: pending history slice",
     :"on_event:modernisation"},
    {"repairs.m_no", "modernisation document number: pending history slice",
     :"on_event:modernisation"},
    {"repairs.m_inv", "modernised asset number: pending history slice",
     :"on_event:modernisation"},
    {"repairs.m_sum", "modernisation cost: pending history slice", :"on_event:modernisation"},
    {"repairs.r_date", "repair document date: pending history slice", :"on_event:repair"},
    {"repairs.r_no", "repair document number: pending history slice", :"on_event:repair"},
    {"repairs.r_kind", "repair type: pending history slice", :"on_event:repair"},
    {"repairs.r_sum", "repair cost: pending history slice", :"on_event:repair"},
    {"revaluations.v_date", "revaluation date: pending history slice", :"on_event:revaluation"},
    {"revaluations.v_coef", "revaluation coefficient: pending history slice",
     :"on_event:revaluation"},
    {"revaluations.v_cost", "revalued cost: pending history slice", :"on_event:revaluation"},
    {"moves.t_doc", "transfer document: pending history slice", :"on_event:move"},
    {"moves.t_op", "transfer operation: pending history slice", :"on_event:move"},
    {"moves.t_unit", "destination unit: pending history slice", :"on_event:move"},
    {"moves.t_book", "transfer book value: pending history slice", :"on_event:move"},
    {"moves.t_note", "transfer note: pending history slice", :"on_event:move"},
    {"elements.e_name", "component name: manual declaration", :manual},
    {"elements.e_main", "component characteristics: manual declaration", :manual},
    {"elements.e_extra", "component characteristics: manual declaration", :manual},
    {"elements.e_extra2", "component characteristics: manual declaration", :manual},
    {"elements.e_extra3", "component characteristics: manual declaration", :manual},
    {"elements.e_extra4", "component characteristics: manual declaration", :manual},
    {"filled.position", "preparer position: manual signature", :manual},
    {"filled.signature", "preparer signature: manual signature", :manual},
    {"filled.name", "preparer name: manual signature", :manual}
  ]

  defp technical do
    %{
      "manufacturer" => "Almaty Machines",
      "asset_type" => "Lathe",
      "model" => "M16",
      "type" => "Universal",
      "brand" => "AM",
      "category" => "Industrial",
      "sort" => "First",
      "serial_number" => "SN-2026",
      "passport_number" => "PASS-7",
      "useful_life_months" => 120,
      "commissioning_date" => "2026-03-02"
    }
  end

  defp card(extra \\ %{}) do
    Map.merge(
      %{
        "record_id" => "c-1",
        "name" => "Lathe",
        "inventory_number" => "INV-7",
        "acquisition_date" => "2026-03-01",
        "currency" => "KZT",
        "acquisition_cost" => "1200000.000000000",
        "accumulated_depreciation" => "49360.500000000",
        "book_value" => "1150639.500000000",
        "org_unit_id" => "u1"
      },
      extra
    )
  end

  defp names(holders \\ [], extra \\ %{}) do
    Map.merge(
      %{
        holders: holders,
        org_units: %{"u1" => %{name: "Workshop"}, "u2" => %{name: "Store"}},
        legal_entities: %{
          "u1" => %{name: "LE One", bin: "111111111111"},
          "u2" => %{name: "LE Two", bin: "222222222222"}
        },
        employees: %{"e1" => %{full_name: "Aigul N."}}
      },
      extra
    )
  end

  defp one, do: [%{org_unit: "u2", material_responsible: "e1"}]
  defp line(data), do: data |> Map.fetch!("lines") |> hd()

  test "F1 values with one register holder, ru and kk" do
    for {lang, atom} <- [{"ru", :ru}, {"kk", :kk}] do
      data = FormDa2.data(card(), names(one()), lang)
      assert data["org_name"] == "LE Two" and data["org_bin"] == "222222222222"
      assert data["unit"] == "Store" and data["mol"] == "Aigul N."
      assert data["full_name"] == "Lathe"

      assert Map.take(line(data), ~w(name inv acquired cost depr book)) == %{
               "name" => "Lathe",
               "inv" => "INV-7",
               "acquired" => "01.03.2026",
               "cost" => DocumentPrint.number("1200000.000000000", atom),
               "depr" => DocumentPrint.number("49360.500000000", atom),
               "book" => DocumentPrint.number("1150639.500000000", atom)
             }
    end
  end

  test "F2 every layout path has a source and applicability; applicable cells are populated" do
    {:ok, layout} = FormPrint.layout("da2")

    paths =
      Enum.flat_map(layout["blocks"], fn block ->
        case block["type"] do
          "table" -> Enum.map(block["columns"], &(block["rows"] <> "." <> &1["key"]))
          "signature_table" -> Enum.map(block["parts"], &(block["key"] <> "." <> &1))
          "boxed_pairs" -> Enum.map(block["cells"], & &1["key"])
          "field" -> [block["key"]]
          _ -> []
        end
      end)

    assert Enum.sort(paths) == Enum.sort(Enum.map(@sources, &elem(&1, 0)))
    data = FormDa2.data(card(technical()), names(one()), "ru")

    for {path, source, applicability} <- @sources do
      assert source != ""

      assert applicability in [
               :always,
               :after_commission,
               :manual,
               :"on_event:disposal",
               :"on_event:repair",
               :"on_event:modernisation",
               :"on_event:revaluation",
               :"on_event:move"
             ]

      value =
        case String.split(path, ".") do
          [key] -> Map.get(data, key, "")
          ["lines", key] -> Map.get(line(data), key, "")
          _ -> ""
        end

      if applicability in [:always, :after_commission] do
        assert value not in [nil, ""], "#{path} from #{source} is blank"
      else
        assert value in [nil, ""], "#{path} must not invent history or signatures"
      end
    end
  end

  test "F2b technical characteristics use reference order, omit blanks and preserve kind" do
    data = FormDa2.data(card(Map.put(technical(), "kind", "fixed")), names(), "ru")
    assert data["maker"] == "Almaty Machines"
    assert data["model"] == "Lathe, M16, Universal, AM, Industrial, First"
    assert line(data)["factory"] == "SN-2026"
    assert line(data)["passport"] == "PASS-7"
    assert line(data)["life"] == "120"
    assert line(data)["commissioned"] == "02.03.2026"

    partial =
      FormDa2.data(card(%{"asset_type" => " ", "model" => "M16", "brand" => nil}), names(), "ru")

    assert partial["model"] == "M16"
  end

  test "F3 holder rule: 0 or 2 rows use the card unit and a blank person" do
    two = one() ++ [%{org_unit: "u1", material_responsible: "e1"}]

    for holders <- [[], two] do
      data = FormDa2.data(card(), names(holders), "ru")
      assert data["unit"] == "Workshop" and data["org_name"] == "LE One"
      assert data["mol"] == ""
    end

    unknown = [%{org_unit: "u2", material_responsible: "gone"}]
    assert FormDa2.data(card(), names(unknown), "ru")["mol"] == ""
  end

  test "F4 money only for a KZT card" do
    usd = FormDa2.data(card(%{"currency" => "USD"}), names(), "ru") |> line()
    assert {usd["cost"], usd["depr"], usd["book"]} == {"", "", ""}
    nil_cur = FormDa2.data(card(%{"currency" => nil}), names(), "ru") |> line()
    assert {nil_cur["cost"], nil_cur["depr"], nil_cur["book"]} == {"", "", ""}

    l = FormDa2.data(card(%{"book_value" => nil}), names(), "ru") |> line()
    assert l["book"] == "" and l["cost"] != "" and l["depr"] != ""
  end

  test "F5 the layout validates and builds both formats and languages" do
    {:ok, layout} = FormPrint.layout("da2")
    cat = FormPrint.catalog()
    assert FormPrint.validate_layout(layout, cat) == :ok

    tables = Enum.filter(layout["blocks"], &(&1["type"] == "table"))

    assert Enum.map(tables, &{&1["rows"], length(&1["columns"])}) == [
             {"lines", 10},
             {"lines", 9},
             {"repairs", 8},
             {"revaluations", 3},
             {"moves", 5},
             {"elements", 6}
           ]

    [t1, t2 | _] = tables

    keys = fn t, g ->
      t["columns"] |> Enum.filter(&(g in (&1["groups"] || []))) |> Enum.map(& &1["key"])
    end

    assert keys.(t1, "da1.number") == ["inv", "factory", "passport"]
    assert keys.(t1, "da2.acquired") == ["acq_doc", "acq_no", "acquired"]
    assert keys.(t2, "da2.disposed") == ["out_doc", "out_reason", "out_income"]
    assert Enum.map(t2["columns"], & &1["no"]) == Enum.to_list(11..19)

    for {key, entry} <- cat,
        String.starts_with?(key, "da2."),
        do: assert(entry["kk_status"] == "official", key)

    for {lang, title} <- [{"ru", "ИНВЕНТАРНАЯ КАРТОЧКА"}, {"kk", "ТҮГЕНДЕУ КАРТОЧКАСЫ"}],
        format <- [:pdf, :docx] do
      assert {:ok, bin} =
               FormPrint.build(
                 "da2",
                 FormDa2.data(card(technical()), names(one()), lang),
                 lang,
                 format
               )

      if format == :pdf do
        assert "%PDF-" <> _ = bin
        assert Enum.any?(PdfProbe.items(bin), &(&1 =~ title)), "no #{lang} title item"
        refute Enum.any?(PdfProbe.items(bin), &(&1 =~ "draft" or &1 =~ "черновик"))
        text = Enum.join(PdfProbe.items(bin), "\n")

        for value <-
              ~w(Almaty Machines M16 Universal AM Industrial First SN-2026 PASS-7 120 02.03.2026),
            do: assert(text =~ value, "missing #{value} in #{lang} PDF")
      else
        assert "PK" <> _ = bin
        {:ok, files} = :zip.unzip(bin, [:memory])
        {_, xml} = Enum.find(files, fn {name, _} -> name == ~c"word/document.xml" end)

        for value <-
              ~w(Almaty Machines M16 Universal AM Industrial First SN-2026 PASS-7 120 02.03.2026),
            do: assert(xml =~ value, "missing #{value} in #{lang} DOCX")
      end
    end
  end

  test "F6 hostile values: unknown ids print blank, a long name is capped" do
    data = FormDa2.data(%{"record_id" => "x"}, %{}, "ru")
    assert data["org_name"] == "" and data["unit"] == "" and data["mol"] == ""
    l = line(data)
    assert Enum.all?(Map.values(l), &(&1 == ""))

    long = String.duplicate("n", 600)
    {:ok, layout} = FormPrint.layout("da2")

    model =
      FormPrint.resolve(
        layout,
        FormDa2.data(card(%{"name" => long}), names(), "ru"),
        "ru",
        FormPrint.catalog()
      )

    assert {:field, _, shown} =
             Enum.find(model, &match?({:field, "полное наименование и назначение", _}, &1))

    assert String.length(shown) < String.length(long)
  end
end
