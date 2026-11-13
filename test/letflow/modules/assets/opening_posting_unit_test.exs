defmodule Letflow.Modules.Assets.OpeningPostingUnitTest do
  @moduledoc "GH #4037 (G5 part 2): the pure `OpeningPosting` helpers, OPP-1."

  use ExUnit.Case, async: true

  alias Letflow.Modules.Assets.Documents.OpeningPosting

  @unit "44444444-4444-4444-8444-444444444444"
  @asset "11111111-1111-4111-8111-111111111111"
  @resp "22222222-2222-4222-8222-222222222222"
  @loc "33333333-3333-4333-8333-333333333333"

  defp issued do
    %{
      version_id: "v1",
      content: %{
        "header" => %{"org_unit_id" => @unit},
        "lines" => [
          %{
            "line_no" => 1,
            "asset_id" => @asset,
            "location_id" => @loc,
            "material_responsible_id" => @resp,
            "quantity" => "1.000000000"
          }
        ]
      }
    }
  end

  test "OPP-1 command: no client time keys, per-line placement, whole quantity" do
    assert {:ok, command} = OpeningPosting.command(%{id: "d1"}, issued(), %{1 => "l1"})

    assert command |> Map.keys() |> Enum.sort() ==
             ~w(cause client_op_id document_id document_type lines)

    assert [line] = command["lines"]
    assert line["quantity"] == "1" and line["from"] == nil and line["line_id"] == "l1"

    assert line["to"] == %{
             "org_unit" => @unit,
             "location" => @loc,
             "material_responsible" => @resp,
             "actual_user" => nil
           }
  end

  test "OPP-1 a line without a record id is refused; expected legs one per line" do
    assert {:error, :line_record_missing} = OpeningPosting.command(%{id: "d1"}, issued(), %{})

    assert [{@asset, @unit, @loc, @resp, nil, "pcs", "1.000000000"}] =
             OpeningPosting.expected_legs(issued().content, fn a, o, l, r, u, p, q ->
               {a, o, l, r, u, p, q}
             end)
  end
end
