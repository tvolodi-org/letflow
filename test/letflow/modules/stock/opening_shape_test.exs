defmodule Letflow.Modules.Stock.OpeningShapeTest do
  @moduledoc """
  REQ-725 / GH #3775 criterion 3 (O-SHAPE-1..): the pure shape check of an opening body, the shared
  functions with the receipt (O-REUSE-1), and the `Kinds` dispatch. No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Stock.Documents.Kinds
  alias Letflow.Modules.Stock.Documents.OpeningShape
  alias Letflow.Modules.Stock.Documents.Shape

  @id "11111111-1111-4111-8111-111111111111"
  @id2 "22222222-2222-4222-8222-222222222222"

  defp line(extra \\ %{}) do
    Map.merge(
      %{
        "location_id" => @id,
        "responsible_id" => @id,
        "catalog_item_id" => @id2,
        "catalog_uom_id" => @id2,
        "quantity" => "10.5",
        "received_on" => "2025-01-31"
      },
      extra
    )
  end

  defp body(extra \\ %{}, lines \\ [line()]),
    do: Map.merge(%{"kind" => "opening", "org_unit_id" => @id, "lines" => lines}, extra)

  defp refused(body, reason, extras \\ %{}),
    do: assert({:error, {^reason, ^extras}} = OpeningShape.parse(body, :create))

  test "O-SHAPE-1 a valid body is normalised with 9 decimals and line numbers" do
    assert {:ok, %{kind: "opening", header: header, lines: [one, two]}} =
             OpeningShape.parse(
               body(%{"note" => "n"}, [
                 line(%{"unit_price" => "0", "line_value" => "7.5"}),
                 line(%{"catalog_lot_id" => @id})
               ]),
               :create
             )

    assert header == %{"org_unit_id" => @id, "note" => "n"}
    assert one["quantity"] == "10.500000000" and one["line_no"] == 1
    assert one["unit_price"] == "0.000000000" and one["line_value"] == "7.500000000"
    assert two["line_no"] == 2 and two["catalog_lot_id"] == @id
    refute Map.has_key?(two, "unit_price")
  end

  test "O-SHAPE-2 server-set and receipt-only keys are field_not_allowed" do
    for key <- ~w(event_time location_id responsible_id counterparty_id number state document_id
                  header_id supplier_document_ref received_on) do
      refused(body(%{key => "x"}), "field_not_allowed", %{"field" => key})
    end

    for key <- ~w(line_no org_unit_id event_time header_id) do
      refused(body(%{}, [line(%{key => "x"})]), "field_not_allowed", %{
        "field" => key,
        "line_no" => 1
      })
    end
  end

  test "O-SHAPE-3 required keys, ids and the kind" do
    refused(Map.delete(body(), "org_unit_id"), "field_required", %{"field" => "org_unit_id"})
    refused(Map.delete(body(), "lines"), "field_required", %{"field" => "lines"})
    refused(Map.delete(body(), "kind"), "field_required", %{"field" => "kind"})
    refused(body(%{"kind" => "receipt"}), "unknown_kind")
    refused(body(%{"org_unit_id" => "x"}), "field_invalid", %{"field" => "org_unit_id"})
    refused(body(%{"lines" => "x"}), "field_invalid", %{"field" => "lines"})

    for key <- ~w(location_id responsible_id catalog_item_id catalog_uom_id received_on quantity) do
      refused(body(%{}, [Map.delete(line(), key)]), "field_required", %{
        "field" => key,
        "line_no" => 1
      })
    end

    refused(body(%{}, [line(%{"catalog_lot_id" => 5})]), "field_invalid", %{
      "field" => "catalog_lot_id",
      "line_no" => 1
    })

    refused(body(%{}, ["x"]), "field_invalid", %{"field" => "lines", "line_no" => 1})
  end

  test "O-SHAPE-4 lines_count, quantity, price, received_on, in order" do
    refused(body(%{}, []), "lines_count")
    refused(body(%{}, List.duplicate(line(), 101)), "lines_count")
    assert {:ok, _} = OpeningShape.parse(body(%{}, List.duplicate(line(), 100)), :create)

    for bad <- ["0", "-1", "1e3", "", 5, nil, "1.1234567891"] do
      refused(body(%{}, [line(%{"quantity" => bad})]), "quantity_invalid", %{"line_no" => 1})
    end

    for key <- ~w(unit_price line_value), bad <- ["-1", 1.5, nil, "1.1234567891", " 1"] do
      refused(body(%{}, [line(%{key => bad})]), "price_invalid", %{"field" => key, "line_no" => 1})
    end

    for bad <- ["2025-13-01", "25-01-01", "1999-12-31", "2101-01-01", 5, nil, "2025-1-1"] do
      refused(body(%{}, [line(%{"received_on" => bad})]), "field_invalid", %{
        "field" => "received_on",
        "line_no" => 1
      })
    end

    # a future date is not a shape rule (it is the check reason received_on_in_future)
    assert {:ok, _} =
             OpeningShape.parse(body(%{}, [line(%{"received_on" => "2100-12-31"})]), :create)
  end

  test "O-SHAPE-5 the external reference pair" do
    refused(body(%{"external_ref_system" => "erp"}), "external_ref_pair")
    refused(body(%{"external_ref_id" => "1"}), "external_ref_pair")

    refused(body(%{"external_ref_system" => "", "external_ref_id" => "1"}), "field_invalid", %{
      "field" => "external_ref_system"
    })

    refused(
      body(%{"external_ref_system" => "a\nb", "external_ref_id" => "1"}),
      "field_invalid",
      %{"field" => "external_ref_system"}
    )

    refused(body(%{}, [line(%{"external_ref_id" => "1"})]), "external_ref_pair", %{"line_no" => 1})

    assert {:ok, %{header: header, lines: [l]}} =
             OpeningShape.parse(
               body(%{"external_ref_system" => "erp", "external_ref_id" => "A-1"}, [
                 line(%{"external_ref_system" => "erp", "external_ref_id" => "L-1"})
               ]),
               :create
             )

    assert header["external_ref_id"] == "A-1" and l["external_ref_id"] == "L-1"
  end

  test "O-SHAPE-6 replace needs the document's own kind; Kinds dispatches" do
    assert {:ok, %{kind: "opening"}} =
             Kinds.parse(Map.delete(body(), "kind"), {:replace, "opening"})

    assert {:error, {"unknown_kind", %{}}} = Kinds.parse(body(), {:replace, "receipt"})
    assert {:ok, %{kind: "opening"}} = Kinds.parse(body(), :create)
    assert {:error, {"unknown_kind", %{}}} = Kinds.parse(%{"kind" => "bogus"}, :create)
    assert Kinds.get("opening").definition == "stock_opening"
    assert Kinds.for_type_key("stock_receipt").kind == "receipt"
    assert Kinds.for_type_key("count.order") == nil
  end

  test "O-REUSE-1 the opening and the receipt share one definition of price, quantity, date" do
    receipt = fn quantity, price ->
      Shape.parse(
        %{
          "kind" => "receipt",
          "org_unit_id" => @id,
          "location_id" => @id,
          "responsible_id" => @id,
          "event_time" => "2026-11-04T10:00:00Z",
          "received_on" => "2025-01-31",
          "lines" => [
            %{
              "catalog_item_id" => @id2,
              "catalog_uom_id" => @id2,
              "quantity" => quantity,
              "unit_price" => price
            }
          ]
        },
        :create
      )
    end

    for {quantity, price} <- [
          {"10.5", "0"},
          {"1", "1.1234567891"},
          {"0", "2"},
          {"3", "-1"},
          {"x", "1"}
        ] do
      opening =
        OpeningShape.parse(
          body(%{}, [line(%{"quantity" => quantity, "unit_price" => price})]),
          :create
        )

      case {receipt.(quantity, price), opening} do
        {{:ok, %{lines: [r]}}, {:ok, %{lines: [o]}}} ->
          assert Map.take(r, ~w(quantity unit_price)) == Map.take(o, ~w(quantity unit_price))

        {{:error, {reason, extras}}, {:error, {reason, extras2}}} ->
          assert Map.drop(extras, ["line_no"]) == Map.drop(extras2, ["line_no"])
      end
    end

    assert Shape.quantity_text("10.5") == {:ok, "10.500000000"}
    assert Shape.quantity_text("0") == :error
    assert Shape.price_text("0") == {:ok, "0.000000000"}
    assert Shape.received_on_text("2025-02-28") == {:ok, "2025-02-28"}
    assert Shape.received_on_text("2025-02-30") == :error
  end
end
