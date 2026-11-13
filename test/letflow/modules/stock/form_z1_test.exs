defmodule Letflow.Modules.Stock.FormZ1Test do
  @moduledoc "T-1912: the Z-1 / Қ-1 data map from an issued receipt document (pure, no DB)."

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Stock.FormZ1

  @unit "u-1"
  @loc "loc-1"
  @supplier "sup-1"

  defp issued(header \\ %{}, lines \\ nil) do
    %{
      number_label: "RCP-1",
      content: %{
        "kind" => "receipt",
        "header" =>
          Map.merge(
            %{
              "org_unit_id" => @unit,
              "location_id" => @loc,
              "responsible_id" => "e-1",
              "counterparty_id" => @supplier,
              "event_time" => "2026-11-05T21:30:00+00:00",
              "supplier_document_ref" => "INV-77"
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
                "quantity" => "3.000000000",
                "unit_price" => "50.000000000",
                "line_value" => "150.000000000"
              },
              %{
                "line_no" => 1,
                "catalog_item_id" => "i-1",
                "catalog_uom_id" => "m-1",
                "quantity" => "5.000000000",
                "unit_price" => "100.000000000",
                "line_value" => "500.000000000"
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
      locations: %{@loc => %{code: "W1", name: "Склад 1"}},
      counterparties: %{@supplier => %{name: "Steppe LLP", tax_id: "123456789012"}},
      items: %{"i-1" => %{code: "B-1", name: "Болт"}, "i-2" => %{code: "G-2", name: "Гайка"}},
      uoms: %{"m-1" => %{code: "PCS", name: "шт"}}
    }
  end

  # Z1-M1
  test "Z1-M1 fills what Letflow holds; lines sorted by line_no; never-set keys absent" do
    d = FormZ1.data(issued(), names())

    assert %{
             "org_name" => "ТОО Степь",
             "org_bin" => "123456789012",
             "warehouse" => "Склад 1",
             "number" => "RCP-1",
             "date" => "06.11.2026",
             "supplier" => "Steppe LLP / 123456789012",
             "accomp_doc" => "INV-77",
             "accepted_by" => "Алмазов А."
           } = d

    assert [
             %{
               "name" => "Болт",
               "nom" => "B-1",
               "unit" => "шт",
               "qty" => "5.000000000",
               "price" => "100.000000000",
               "sum" => "500.000000000"
             },
             %{
               "name" => "Гайка",
               "nom" => "G-2",
               "qty" => "3.000000000",
               "price" => "50.000000000",
               "sum" => "150.000000000"
             }
           ] = d["lines"]

    for k <- ~w(operation account payment_doc handed_by) do
      refute Map.has_key?(d, k), "unexpected key #{k}"
    end

    for k <- ~w(qty_doc mass_doc mass passport card_no) do
      refute Map.has_key?(hd(d["lines"]), k), "unexpected line key #{k}"
    end
  end

  # Z1-M2: bare receipt (no counterparty, no ref, no prices)
  test "Z1-M2 bare receipt: supplier, accomp_doc and warehouse blank; a line without line_value blanks sum total" do
    bare_issued =
      issued(%{
        "counterparty_id" => nil,
        "supplier_document_ref" => nil,
        "location_id" => "unknown"
      })

    no_price_lines = [
      %{
        "line_no" => 1,
        "catalog_item_id" => "i-1",
        "catalog_uom_id" => "m-1",
        "quantity" => "5.000000000",
        "line_value" => "500.000000000"
      },
      %{
        "line_no" => 2,
        "catalog_item_id" => "i-2",
        "catalog_uom_id" => "m-1",
        "quantity" => "3.000000000"
      }
    ]

    bare_issued_no_sum =
      Map.update!(bare_issued, :content, fn c ->
        Map.put(c, "lines", no_price_lines)
      end)

    d = FormZ1.data(bare_issued_no_sum, names())
    assert d["supplier"] == ""
    assert d["accomp_doc"] == ""
    assert d["warehouse"] == ""

    # Line 2 has no line_value, so sum total must be blank
    {:ok, layout} = FormPrint.layout("z1")
    model = FormPrint.resolve(layout, d, "ru", FormPrint.catalog())
    {:table, t} = List.keyfind(model, :table, 0)
    assert t.total["sum"] == ""
    # qty total is sum of both
    assert t.total["qty"] == "8.000000000"
  end

  test "Z1 supplier with no tax_id: name only, no slash" do
    names_no_tid =
      put_in(names(), [:counterparties, @supplier], %{name: "Steppe LLP", tax_id: nil})

    d = FormZ1.data(issued(), names_no_tid)
    assert d["supplier"] == "Steppe LLP"
  end

  test "Z1 supplier with empty tax_id: name only" do
    names_empty_tid =
      put_in(names(), [:counterparties, @supplier], %{name: "Steppe LLP", tax_id: ""})

    d = FormZ1.data(issued(), names_empty_tid)
    assert d["supplier"] == "Steppe LLP"
  end

  test "Z1 missing names give blanks, not an id" do
    d = FormZ1.data(issued(%{"org_unit_id" => "zzz", "responsible_id" => "zzz"}), names())
    assert d["org_name"] == "" and d["org_bin"] == "" and d["accepted_by"] == ""

    empty = FormZ1.data(%{content: %{}}, %{})
    assert %{"org_name" => "", "number" => "", "date" => "", "lines" => []} = empty
  end
end
