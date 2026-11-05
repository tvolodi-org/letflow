defmodule Letflow.Modules.Stock.FormZ2Test do
  @moduledoc "T-1416 (E5b), design test Z1: the Z-2 data map from an issued issue document (pure)."

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Stock.FormZ2

  @unit "u-1"

  defp issued(header \\ %{}, lines \\ nil) do
    %{
      number_label: "ISS-5",
      content: %{
        "kind" => "issue",
        "header" =>
          Map.merge(
            %{
              "org_unit_id" => @unit,
              "responsible_id" => "e-1",
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
                "quantity" => "2"
              },
              %{
                "line_no" => 1,
                "catalog_item_id" => "i-1",
                "catalog_uom_id" => "m-1",
                "quantity" => "1.5"
              }
            ]
      }
    }
  end

  defp names do
    %{
      offsets: %{event_time: 6 * 3600},
      legal_entities: %{@unit => %{name: "ТОО Ромашка", bin: "123456789012"}},
      employees: %{"e-1" => %{full_name: "Иванов И.", code: "E1"}},
      items: %{"i-1" => %{code: "B-1", name: "Болт"}, "i-2" => %{code: "G-2", name: "Гайка"}},
      uoms: %{"m-1" => %{code: "PCS", name: "шт"}}
    }
  end

  test "Z1 fills what Letflow holds" do
    d = FormZ2.data(issued(), names())

    assert %{
             "org_name" => "ТОО Ромашка",
             "sender" => "ТОО Ромашка",
             "org_bin" => "123456789012",
             "number" => "ISS-5",
             "date" => "06.11.2026",
             "responsible" => "Иванов И.",
             "released" => "Иванов И."
           } = d

    assert [
             %{
               "no" => "1",
               "name" => "Болт",
               "nom" => "B-1",
               "unit" => "шт",
               "qty_issued" => "1.5"
             },
             %{"no" => "2", "name" => "Гайка", "nom" => "G-2", "qty_issued" => "2"}
           ] = d["lines"]

    for k <- ~w(receiver transport ttn words_qty words_sum allowed_by chief_acc received) do
      refute Map.has_key?(d, k), k
    end
  end

  test "Z1 total through the engine: 1.5 + 2 = 3.5; an invalid quantity blanks it" do
    {:ok, layout} = FormPrint.layout("z2")

    total = fn issued ->
      model = FormPrint.resolve(layout, FormZ2.data(issued, names()), "ru", FormPrint.catalog())
      {:table, t} = List.keyfind(model, :table, 0)
      t.total["qty_issued"]
    end

    assert total.(issued()) == "3.5"
    bad = [%{"line_no" => 1, "catalog_item_id" => "i-1", "quantity" => "many"}]
    assert total.(issued(%{}, bad)) == ""
  end

  test "Z1 missing names and header values give blanks, never an id" do
    d =
      FormZ2.data(
        issued(%{"org_unit_id" => "zzz", "responsible_id" => "zzz", "event_time" => "garbage"}),
        names()
      )

    assert d["org_name"] == "" and d["org_bin"] == "" and d["responsible"] == ""
    assert d["date"] == "garbage"

    empty = FormZ2.data(%{content: %{}}, %{})
    assert %{"org_name" => "", "number" => "", "date" => "", "lines" => []} = empty

    unknown = FormZ2.data(issued(), %{})
    assert [%{"name" => "", "nom" => "", "unit" => ""} | _] = unknown["lines"]
  end
end
