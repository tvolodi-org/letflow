defmodule Letflow.Modules.Stock.FormZ6Test do
  @moduledoc "T-1914: the Z-6 / Қ-6 data map from an issued write-off document (pure, no DB)."

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Stock.FormZ6

  @unit "u-1"
  @loc "loc-1"

  defp issued(header \\ %{}, lines \\ nil) do
    %{
      number_label: "WO-1",
      content: %{
        "kind" => "write_off",
        "header" =>
          Map.merge(
            %{
              "org_unit_id" => @unit,
              "location_id" => @loc,
              "responsible_id" => "e-1",
              "reason_code" => "damaged",
              "event_time" => "2026-11-05T21:30:00+00:00"
            },
            header
          ),
        "lines" =>
          lines ||
            [
              %{
                "line_no" => 2,
                "catalog_item_id" => "i-2",
                "catalog_uom_id" => "m-1",
                "quantity" => "3"
              },
              %{
                "line_no" => 1,
                "catalog_item_id" => "i-1",
                "catalog_uom_id" => "m-1",
                "quantity" => "5"
              }
            ]
      }
    }
  end

  defp names do
    %{
      offsets: %{event_time: 6 * 3600},
      legal_entities: %{@unit => %{name: "ТОО Степь", bin: "123456789012"}},
      employees: %{"e-1" => %{full_name: "Алмазов А.", code: "E1"}},
      org_units: %{@unit => %{code: "U1", name: "Участок 1"}},
      locations: %{@loc => %{code: "W1", name: "Склад 1"}},
      items: %{"i-1" => %{code: "B-1", name: "Болт"}, "i-2" => %{code: "G-2", name: "Гайка"}},
      uoms: %{"m-1" => %{code: "PCS", name: "шт"}}
    }
  end

  test "Z6-U1 fills what Letflow holds; lines sorted by line_no" do
    d = FormZ6.data(issued(), names(), "ru")

    assert %{
             "org_name" => "ТОО Степь",
             "org_bin" => "123456789012",
             "number" => "WO-1",
             "date" => "06.11.2026",
             "unit" => "Участок 1 / Склад 1",
             "responsible" => "Алмазов А.",
             "mol" => "Алмазов А."
           } = d

    assert [
             %{"no" => "1", "name" => "Болт", "nom" => "B-1", "unit" => "шт", "qty" => "5"},
             %{"no" => "2", "name" => "Гайка", "nom" => "G-2", "unit" => "шт", "qty" => "3"}
           ] = d["lines"]
  end

  test "Z6-U2 every gap is absent from the map, so it prints blank" do
    d = FormZ6.data(issued(), names(), "ru")

    for k <-
          ~w(approver basis guilty_qty guilty_damage guilty_shortage org_sum org_damage org_shortage decision scrap scrap_sum chair member1 member2 mol_position) do
      refute Map.has_key?(d, k), "unexpected key #{k}"
    end

    for k <- ~w(acquired life price sum), line <- d["lines"] do
      refute Map.has_key?(line, k), "unexpected line key #{k}"
    end
  end

  test "Z6-U3 the stored reason of the document is printed on every line, in the form language" do
    for {lang, want} <- [{"ru", "Повреждено"}, {"kk", "Зақымдалған"}] do
      d = FormZ6.data(issued(), names(), lang)
      assert Enum.map(d["lines"], & &1["reason"]) == [want, want]
    end

    other = issued(%{"reason_code" => "other", "reason_text" => "burnt"})
    assert hd(FormZ6.data(other, names(), "ru")["lines"])["reason"] == "Другое: burnt"
    assert hd(FormZ6.data(other, names(), "kk")["lines"])["reason"] == "Басқа: burnt"

    bogus = issued(%{"reason_code" => "bogus"})
    assert hd(FormZ6.data(bogus, names(), "ru")["lines"])["reason"] == ""

    bogus_text = issued(%{"reason_code" => "bogus", "reason_text" => "x"})
    assert hd(FormZ6.data(bogus_text, names(), "ru")["lines"])["reason"] == "x"

    lost = issued(%{"reason_code" => "lost", "reason_text" => ""})
    assert hd(FormZ6.data(lost, names(), "ru")["lines"])["reason"] == "Утеряно"
  end

  test "Z6-U4 hidden or unknown ids give blanks, not an id; odd lines are skipped" do
    d =
      FormZ6.data(
        issued(%{"org_unit_id" => "zzz", "responsible_id" => "zzz", "location_id" => "zzz"}),
        names(),
        "ru"
      )

    assert d["org_name"] == "" and d["responsible"] == "" and d["mol"] == "" and d["unit"] == ""

    skipped =
      FormZ6.data(issued(%{}, ["junk", %{"line_no" => 1, "quantity" => "1"}]), names(), "ru")

    assert [%{"no" => "1", "name" => "", "qty" => "1"}] = skipped["lines"]

    empty = FormZ6.data(%{content: %{}}, %{}, "ru")
    assert %{"org_name" => "", "number" => "", "date" => "", "lines" => []} = empty
  end

  test "Z6-U5 the layout builds a pdf and a docx in ru and kk with official wording" do
    assert {:ok, _} = FormPrint.layout("z6")

    for {lang, texts} <- [
          {"ru",
           [
             "АКТ списания запасов",
             "Форма З-6",
             "Оборотная сторона формы № З-6",
             "Председатель комиссии"
           ]},
          {"kk",
           [
             "ҚОРЛАРДЫ ЕСЕПТЕН ШЫҒАРУ АКТІСІ",
             "Қ-6 нысаны",
             "Қ-6 нысанының екінші жағы",
             "Комиссия төрағасы"
           ]}
        ],
        fmt <- [:pdf, :docx] do
      assert {:ok, bin} = FormPrint.build("z6", FormZ6.data(issued(), names(), lang), lang, fmt)
      assert byte_size(bin) > 1000

      if fmt == :docx do
        {:ok, files} = :zip.unzip(bin, [:memory])
        {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
        text = xml |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")
        for t <- texts, do: assert(text =~ t, "missing #{t} (#{lang})")
      end
    end
  end

  test "Z6-U6 every z6 message is official in both languages" do
    path = Path.join(:code.priv_dir(:letflow), "print_forms/messages.json")
    messages = path |> File.read!() |> Jason.decode!()
    z6 = Enum.filter(messages, fn {k, _} -> String.starts_with?(k, "z6.") end)
    assert length(z6) >= 28

    for {k, v} <- z6 do
      assert v["kk_status"] == "official", k
      assert v["ru"] not in [nil, ""], k
      assert v["kk"] not in [nil, ""], k
    end
  end
end
