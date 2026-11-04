defmodule Letflow.Modules.Stock.IssueWriteoffShapeTest do
  @moduledoc """
  REQ-715 / GH #3746 criterion 2, the pure part: `Shape` for the kinds `issue` and `write_off`, and the
  kind table. No database. Tests: S1, S2, K1.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Stock.Documents.Kinds
  alias Letflow.Modules.Stock.Documents.Shape

  @id "7c92df01-53e8-43c9-8f33-0cb6d90e34e1"

  defp line(extra \\ %{}),
    do: Map.merge(%{"catalog_item_id" => @id, "catalog_uom_id" => @id, "quantity" => "2"}, extra)

  defp body(kind, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => kind,
        "org_unit_id" => @id,
        "location_id" => @id,
        "responsible_id" => @id,
        "event_time" => "2026-11-04T10:00:00Z",
        "lines" => [line()]
      },
      extra
    )
  end

  defp writeoff(extra), do: body("write_off", Map.merge(%{"reason_code" => "lost"}, extra))

  defp refusal(body), do: Shape.parse(body, :create)

  test "K1 the kind table is the three kinds with distinct keys" do
    assert Shape.kinds() == ["receipt", "issue", "write_off"]
    assert Kinds.kinds() == Shape.kinds()
    assert Kinds.type_keys() == ["stock_receipt", "stock_issue", "stock_writeoff"]
    assert Kinds.header_types() == Kinds.type_keys()
    assert Kinds.process_definitions() == Kinds.type_keys()
    assert Kinds.get("issue").side == "from" and Kinds.get("receipt").side == "to"
    assert Kinds.by_type_key("stock_writeoff").kind == "write_off"
    assert Kinds.get("transfer") == nil
    assert length(Enum.uniq_by(Kinds.all(), & &1.device_id)) == 3
  end

  test "S1 reason rules of a write-off and an issue" do
    assert {:ok, %{kind: "issue", header: %{"reason_text" => "kitchen"}}} =
             refusal(body("issue", %{"reason_text" => "kitchen"}))

    assert {:ok, %{kind: "write_off", header: %{"reason_code" => "lost"}}} =
             refusal(writeoff(%{}))

    assert {:ok, %{header: %{"reason_code" => "other", "reason_text" => "flood"}}} =
             refusal(writeoff(%{"reason_code" => "other", "reason_text" => "flood"}))

    assert {:error, {"field_required", %{"field" => "reason_code"}}} =
             refusal(Map.delete(writeoff(%{}), "reason_code"))

    for bad <- ["stolen", nil, 5, "LOST"] do
      assert {:error, {"reason_invalid", %{}}} = refusal(writeoff(%{"reason_code" => bad}))
    end

    assert {:error, {"reason_invalid", %{}}} = refusal(writeoff(%{"reason_code" => "other"}))

    assert {:error, {"reason_invalid", %{}}} =
             refusal(writeoff(%{"reason_code" => "other", "reason_text" => " "}))

    assert {:error, {"reason_invalid", %{}}} =
             refusal(writeoff(%{"reason_text" => String.duplicate("x", 501)}))

    assert {:ok, _} = refusal(writeoff(%{"reason_text" => String.duplicate("x", 500)}))
    assert {:error, {"reason_invalid", %{}}} = refusal(writeoff(%{"reason_text" => 5}))

    assert {:error, {"field_invalid", %{"field" => "reason_text"}}} =
             refusal(body("issue", %{"reason_text" => String.duplicate("x", 501)}))

    assert {:error, {"field_not_allowed", %{"field" => "reason_code"}}} =
             refusal(body("issue", %{"reason_code" => "lost"}))
  end

  test "S2 price, value and receipt-only keys are refused on issue and write-off" do
    for kind <- ["issue", "write_off"], key <- ["unit_price", "line_value"] do
      extra = %{"lines" => [line(), line(%{key => "1.5"})]}
      payload = if kind == "issue", do: body(kind, extra), else: writeoff(extra)

      assert {:error, {"field_not_allowed", %{"field" => ^key, "line_no" => 2}}} =
               refusal(payload)
    end

    for key <- ["counterparty_id", "supplier_document_ref", "received_on"] do
      value = if key == "counterparty_id", do: @id, else: "2026-01-01"

      assert {:error, {"field_not_allowed", %{"field" => ^key}}} =
               refusal(body("issue", %{key => value}))

      assert {:error, {"field_not_allowed", %{"field" => ^key}}} =
               refusal(writeoff(%{key => value}))
    end

    # the receipt is unchanged
    assert {:ok, %{kind: "receipt"}} =
             refusal(
               body("receipt", %{
                 "counterparty_id" => @id,
                 "received_on" => "2026-01-01",
                 "lines" => [line(%{"unit_price" => "1", "line_value" => "2"})]
               })
             )

    assert {:error, {"unknown_kind", %{}}} = refusal(body("transfer"))
  end
end
