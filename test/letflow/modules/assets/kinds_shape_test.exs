defmodule Letflow.Modules.Assets.KindsShapeTest do
  @moduledoc """
  GH #3889 / REQ-753 (assets C11): the pure shape of the change, hand over and write off bodies
  (`Shape.parse/2`) and the side table (`Kinds.sides/2`). No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Assets.Documents.Kinds
  alias Letflow.Modules.Assets.Documents.Shape

  @a "11111111-1111-4111-8111-111111111111"
  @b "22222222-2222-4222-8222-222222222222"
  @c "33333333-3333-4333-8333-333333333333"
  @d "44444444-4444-4444-8444-444444444444"
  @time "2026-11-07T10:00:00Z"
  @lines [%{"asset_id" => @a, "quantity" => "1"}]

  defp change(extra \\ %{}),
    do:
      Map.merge(
        %{
          "kind" => "change",
          "org_unit_id" => @a,
          "from_material_responsible_id" => @b,
          "to_material_responsible_id" => @c,
          "event_time" => @time,
          "lines" => @lines
        },
        extra
      )

  defp handover(extra \\ %{}),
    do:
      Map.merge(
        %{
          "kind" => "handover",
          "org_unit_id" => @a,
          "from_material_responsible_id" => @b,
          "to_org_unit_id" => @d,
          "to_material_responsible_id" => @c,
          "event_time" => @time,
          "lines" => @lines
        },
        extra
      )

  defp writeoff(extra \\ %{}),
    do:
      Map.merge(
        %{
          "kind" => "writeoff",
          "org_unit_id" => @a,
          "material_responsible_id" => @b,
          "reason_code" => "lost",
          "event_time" => @time,
          "lines" => @lines
        },
        extra
      )

  defp refusal(body), do: Shape.parse(body, :create)

  test "S-pure the three kinds parse; empty optional keys are dropped" do
    assert {:ok, %{kind: "change", header: h}} =
             Shape.parse(change(%{"from_actual_user_id" => "", "location_id" => ""}), :create)

    refute Map.has_key?(h, "from_actual_user_id") or Map.has_key?(h, "location_id")

    assert {:ok, %{header: %{"to_org_unit_id" => @d}}} =
             Shape.parse(handover(%{"to_location_id" => ""}), :create)

    assert {:ok, %{header: %{"reason_code" => "lost"}}} = Shape.parse(writeoff(), :create)
  end

  test "S-pure required and unknown keys" do
    assert {:error, {"field_required", %{"field" => "to_material_responsible_id"}}} =
             refusal(Map.delete(change(), "to_material_responsible_id"))

    assert {:error, {"field_required", %{"field" => "to_org_unit_id"}}} =
             refusal(Map.delete(handover(), "to_org_unit_id"))

    assert {:error, {"field_required", %{"field" => "reason_code"}}} =
             refusal(Map.delete(writeoff(), "reason_code"))

    # a key of another kind
    assert {:error, {"field_not_allowed", %{"field" => "reason_code"}}} =
             refusal(change(%{"reason_code" => "lost"}))

    assert {:error, {"field_not_allowed", %{"field" => "to_org_unit_id"}}} =
             refusal(change(%{"to_org_unit_id" => @d}))

    assert {:error, {"field_invalid", %{"field" => "to_org_unit_id"}}} =
             refusal(handover(%{"to_org_unit_id" => "nope"}))
  end

  test "S-pure the write off reason" do
    for bad <- ["nope", "", 5, nil] do
      assert {:error, {"reason_invalid", %{"field" => "reason_code"}}} =
               refusal(writeoff(%{"reason_code" => bad}))
    end

    assert {:error, {"reason_required", %{"field" => "reason_text"}}} =
             refusal(writeoff(%{"reason_code" => "other"}))

    assert {:error, {"reason_required", %{"field" => "reason_text"}}} =
             refusal(writeoff(%{"reason_code" => "other", "reason_text" => "  "}))

    assert {:ok, %{header: %{"reason_text" => "scrap"}}} =
             Shape.parse(writeoff(%{"reason_code" => "other", "reason_text" => "scrap"}), :create)

    # a blank text for another code is dropped; too long and a non-string are field_invalid
    assert {:ok, %{header: h}} = Shape.parse(writeoff(%{"reason_text" => " "}), :create)
    refute Map.has_key?(h, "reason_text")

    long = String.duplicate("x", 501)

    assert {:error, {"field_invalid", %{"field" => "reason_text"}}} =
             refusal(writeoff(%{"reason_text" => long}))

    assert {:error, {"field_invalid", %{"field" => "reason_text"}}} =
             refusal(writeoff(%{"reason_text" => 7}))
  end

  test "S-pure Kinds.sides/2 for the four kinds" do
    h = %{
      "org_unit_id" => "u",
      "location_id" => "l",
      "from_location_id" => "fl",
      "to_org_unit_id" => "tu",
      "to_location_id" => "tl",
      "material_responsible_id" => "r",
      "actual_user_id" => "a",
      "from_material_responsible_id" => "fr",
      "from_actual_user_id" => "fa",
      "to_material_responsible_id" => "tr"
    }

    assert {nil, %{org_unit: "u", location: "l", material_responsible: "r", actual_user: "a"}} =
             Kinds.sides(Kinds.get("commission"), h)

    assert {%{material_responsible: "r"}, nil} = Kinds.sides(Kinds.get("writeoff"), h)

    assert {%{org_unit: "u", location: "l", material_responsible: "fr", actual_user: "fa"},
            %{org_unit: "u", location: "l", material_responsible: "tr", actual_user: nil}} =
             Kinds.sides(Kinds.get("change"), h)

    assert {%{org_unit: "u", location: "fl", material_responsible: "fr"},
            %{org_unit: "tu", location: "tl", material_responsible: "tr"}} =
             Kinds.sides(Kinds.get("handover"), h)

    assert Kinds.side_fields(Kinds.get("handover"), :to).org_unit == "to_org_unit_id"
  end
end
