Code.require_file("../stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Assets.FormDa1Test do
  @moduledoc """
  T-1921 (design tests F1..F6): the pure mapper `FormDa1.data/3` and the layout `da1.json`.
  No database: the issued and names maps are built by hand.
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Assets.FormDa1
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  @unit_a "11111111-1111-1111-1111-111111111111"
  @unit_b "22222222-2222-2222-2222-222222222222"
  @loc_a "33333333-3333-3333-3333-333333333333"
  @loc_b "44444444-4444-4444-4444-444444444444"
  @emp_a "55555555-5555-5555-5555-555555555555"
  @emp_b "66666666-6666-6666-6666-666666666666"
  @card "77777777-7777-7777-7777-777777777777"

  defp card(extra \\ %{}) do
    Map.merge(
      %{
        inventory_number: "INV-1",
        name: "Lathe",
        acquisition_date: "2026-03-01",
        currency: "KZT",
        acquisition_cost: "1200000.000000000",
        accumulated_depreciation: "49360.500000000",
        book_value: "1150639.500000000",
        depreciation_as_of: nil
      },
      extra
    )
  end

  defp names(extra \\ %{}) do
    Map.merge(
      %{
        offsets: %{event_time: 0},
        legal_entities: %{
          @unit_a => %{name: "Alpha LLP", bin: "111111111111"},
          @unit_b => %{name: "Beta LLP", bin: "222222222222"}
        },
        locations: %{@loc_a => %{name: "Hall A"}, @loc_b => %{name: "Hall B"}},
        employees: %{
          @emp_a => %{full_name: "Aidar Giver"},
          @emp_b => %{full_name: "Dana Taker"}
        },
        positions: %{@emp_a => "Foreman", @emp_b => nil},
        cards: %{@card => card()}
      },
      extra
    )
  end

  defp commission(extra \\ %{}) do
    %{
      content: %{
        "kind" => "commission",
        "header" =>
          Map.merge(
            %{
              "org_unit_id" => @unit_a,
              "location_id" => @loc_a,
              "material_responsible_id" => @emp_b,
              "event_time" => "2026-03-31T12:00:00Z"
            },
            extra
          ),
        "lines" => [%{"line_no" => 1, "asset_id" => @card}]
      }
    }
  end

  defp handover(extra \\ %{}) do
    %{
      content: %{
        "kind" => "handover",
        "header" =>
          Map.merge(
            %{
              "org_unit_id" => @unit_a,
              "from_location_id" => @loc_a,
              "from_material_responsible_id" => @emp_a,
              "to_org_unit_id" => @unit_b,
              "to_location_id" => @loc_b,
              "to_material_responsible_id" => @emp_b,
              "event_time" => "2026-03-31T12:00:00Z"
            },
            extra
          ),
        "lines" => [%{"line_no" => 1, "asset_id" => @card}]
      }
    }
  end

  defp line(data), do: data |> Map.fetch!("lines") |> hd()

  test "F1 commission maps the stored facts" do
    data = FormDa1.data(commission(), names(), "ru")
    assert data["org_bin"] == "111111111111"
    assert data["receiver_name"] == "Alpha LLP"
    assert data["location"] == "Hall A"
    assert data["accepted"] == "Dana Taker"
    assert data["accepted_position"] == ""

    l = line(data)
    assert l["name"] == "Lathe" and l["inv"] == "INV-1"
    assert l["acquired"] == "01.03.2026"
    assert l["cost"] == "1\u00A0200\u00A0000"
    assert l["depr"] == "49\u00A0360,5"
    assert l["book"] == "1\u00A0150\u00A0639,5"
  end

  test "F1 handover: sender, receiver, signers, MOL and the receiving location" do
    data = FormDa1.data(handover(), names(), "kk")
    assert data["sender_name"] == "Alpha LLP"
    assert data["receiver_name"] == "Beta LLP"
    assert data["location"] == "Hall B"
    assert data["handed"] == "Aidar Giver" and data["handed_position"] == "Foreman"
    assert data["accepted"] == "Dana Taker"
    assert line(data)["mol"] == "Aidar Giver, Foreman"
  end

  test "F1 an empty to_location_id prints a blank location (no fallback to the giving side)" do
    data = FormDa1.data(handover(%{"to_location_id" => nil}), names(), "ru")
    assert data["location"] == ""
  end

  test "F2 the exact key sets: every gap and every Q21 cell stays out of the map" do
    c = FormDa1.data(commission(), names(), "ru")

    assert Enum.sort(Map.keys(c)) ==
             ~w(accepted accepted_position lines location org_bin receiver_name)

    assert line(c) |> Map.keys() |> Enum.sort() == ~w(acquired book cost depr inv name)

    h = FormDa1.data(handover(), names(), "ru")

    assert Enum.sort(Map.keys(h)) ==
             ~w(accepted accepted_position handed handed_position lines location org_bin receiver_name sender_name)

    assert line(h) |> Map.keys() |> Enum.sort() == ~w(acquired book cost depr inv mol name)

    for key <- ~w(approver_sender approver_receiver sale basis factory debit credit passport
                  depr_life chair member1 member2 custody acc_out acc_open),
        data <- [c, h] do
      refute Map.has_key?(data, key)
      refute Map.has_key?(line(data), key)
    end
  end

  test "F3 money is printed only in KZT; as-of later than the act blanks depreciation and book value" do
    for currency <- ["USD", nil] do
      n = names(%{cards: %{@card => card(%{currency: currency})}})
      l = line(FormDa1.data(commission(), n, "ru"))
      assert {l["cost"], l["depr"], l["book"]} == {"", "", ""}
    end

    later = names(%{cards: %{@card => card(%{depreciation_as_of: "2026-04-01"})}})
    l = line(FormDa1.data(commission(), later, "ru"))
    assert l["cost"] == "1\u00A0200\u00A0000" and l["depr"] == "" and l["book"] == ""

    for as_of <- ["2026-03-31", "2026-03-01", nil, ""] do
      n = names(%{cards: %{@card => card(%{depreciation_as_of: as_of})}})
      l = line(FormDa1.data(commission(), n, "ru"))
      assert l["depr"] == "49\u00A0360,5", "as_of #{inspect(as_of)}"
    end
  end

  test "F3 the act date is the local date: event 20:00Z with offset +5h is the next day" do
    issued = commission(%{"event_time" => "2026-03-31T20:00:00Z"})

    n =
      names(%{
        offsets: %{event_time: 18_000},
        cards: %{@card => card(%{depreciation_as_of: "2026-04-01"})}
      })

    assert line(FormDa1.data(issued, n, "ru"))["depr"] == "49\u00A0360,5"

    n0 = %{n | offsets: %{event_time: 0}}
    assert line(FormDa1.data(issued, n0, "ru"))["depr"] == ""
  end

  test "F4 the layout validates, tables fit, page-2 columns are numbered 8..16" do
    {:ok, layout} = FormPrint.layout("da1")
    assert FormPrint.validate_layout(layout, FormPrint.catalog()) == :ok
    tables = Enum.filter(layout["blocks"], &(&1["type"] == "table"))
    assert length(tables) == 2
    assert Enum.all?(tables, &(length(&1["columns"]) <= 14))

    assert tables |> List.last() |> Map.fetch!("columns") |> Enum.map(& &1["no"]) ==
             Enum.to_list(8..16)

    for {lang, title} <- [
          {"ru", "АКТ ПРИЕМКИ - ПЕРЕДАЧИ ДОЛГОСРОЧНЫХ АКТИВОВ"},
          {"kk", "ҰЗАҚ МЕРЗІМДІ АКТИВТЕРДІ ҚАБЫЛДАП АЛУ-БЕРУ АКТІСІ"}
        ] do
      {:ok, pdf} = FormPrint.build("da1", FormDa1.data(commission(), names(), lang), lang, :pdf)
      assert Enum.any?(PdfProbe.items(pdf), &(&1 =~ title)), "no #{lang} title item"
    end
  end

  test "F5 build gives pdf and docx in both languages, no draft notice" do
    for lang <- ["ru", "kk"], format <- [:pdf, :docx], data <- [commission(), handover()] do
      assert {:ok, bin} = FormPrint.build("da1", FormDa1.data(data, names(), lang), lang, format)
      assert byte_size(bin) > 0
    end

    {:ok, pdf} = FormPrint.build("da1", FormDa1.data(commission(), names(), "kk"), "kk", :pdf)
    refute Enum.any?(PdfProbe.items(pdf), &(&1 =~ "draft" or &1 =~ "черновик"))
  end

  test "F6 hostile values: an unparseable cost prints as stored, a missing card prints blank" do
    n = names(%{cards: %{@card => card(%{acquisition_cost: "abc"})}})
    assert line(FormDa1.data(commission(), n, "ru"))["cost"] == "abc"

    gone = names(%{cards: %{}})
    l = line(FormDa1.data(commission(), gone, "ru"))
    assert l["name"] == "" and l["inv"] == "" and l["cost"] == ""

    assert %{"lines" => []} = FormDa1.data(%{content: %{"kind" => "commission"}}, %{}, "ru")
  end
end
