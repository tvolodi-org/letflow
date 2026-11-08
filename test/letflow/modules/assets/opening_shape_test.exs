defmodule Letflow.Modules.Assets.OpeningShapeTest do
  @moduledoc """
  GH #4037 (assets G5 part 1), tests K1 and S1: the opening row of the kind table and the pure shape
  of an opening body (`Shape.parse/2`). No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Assets.Documents.Kinds
  alias Letflow.Modules.Assets.Documents.Shape

  @a "11111111-1111-4111-8111-111111111111"
  @b "22222222-2222-4222-8222-222222222222"
  @c "33333333-3333-4333-8333-333333333333"

  defp line(extra \\ %{}),
    do:
      Map.merge(
        %{"asset_id" => @a, "material_responsible_id" => @b, "quantity" => "1"},
        extra
      )

  defp opening(extra \\ %{}),
    do: Map.merge(%{"kind" => "opening", "org_unit_id" => @c, "lines" => [line()]}, extra)

  defp refusal(body), do: Shape.parse(body, :create)

  test "K1 the kind table has the opening: AOP, no event_time, five line keys, does not post" do
    spec = Kinds.get("opening")

    assert {spec.type_key, spec.line_type, spec.prefix} ==
             {"assets_opening", "assets_opening_line", "AOP"}

    assert spec.header_keys == ~w(org_unit_id note)
    refute "event_time" in spec.header_keys

    assert spec.line_keys ==
             ~w(asset_id location_id material_responsible_id actual_user_id quantity)

    refute spec.posts?
    assert spec.definition == nil
    assert "opening" in Kinds.kinds()
    refute nil in Kinds.definition_names()
  end

  test "S1 a valid body parses; no event_time in the header" do
    assert {:ok, %{kind: "opening", header: header, lines: [l]}} = Shape.parse(opening(), :create)
    assert header == %{"org_unit_id" => @c}

    assert l == %{
             "asset_id" => @a,
             "material_responsible_id" => @b,
             "quantity" => "1.000000000",
             "line_no" => 1
           }
  end

  test "S1 event_time on the header is field_not_allowed" do
    assert {:error, {"field_not_allowed", %{"field" => "event_time"}}} =
             refusal(opening(%{"event_time" => "2026-11-07T10:00:00Z"}))
  end

  test "S1 a line without a material responsible is field_required with line_no" do
    body = opening(%{"lines" => [line(), Map.delete(line(), "material_responsible_id")]})

    assert {:error, {"field_required", %{"field" => "material_responsible_id", "line_no" => 2}}} =
             refusal(body)
  end

  test "S1 an empty location is dropped, a bad actual user is field_invalid" do
    assert {:ok, %{lines: [l]}} = refusal(opening(%{"lines" => [line(%{"location_id" => ""})]}))
    refute Map.has_key?(l, "location_id")

    assert {:error, {"field_invalid", %{"field" => "actual_user_id", "line_no" => 1}}} =
             refusal(opening(%{"lines" => [line(%{"actual_user_id" => "nope"})]}))
  end

  test "S1 the line cap is 100; a decimal quantity passes the shape (the value rule is a check)" do
    many = for _ <- 1..101, do: line()
    assert {:error, {"lines_count", _}} = refusal(opening(%{"lines" => many}))

    assert {:ok, %{lines: [%{"quantity" => "2.500000000"}]}} =
             refusal(opening(%{"lines" => [line(%{"quantity" => "2.5"})]}))
  end
end
