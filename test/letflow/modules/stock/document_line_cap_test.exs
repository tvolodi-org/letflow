defmodule Letflow.Modules.Stock.DocumentLineCapTest do
  @moduledoc """
  REQ-774 criterion 1 (the pure part): every stock document kind takes 1000 lines and refuses 1001 with
  `lines_count`. No database. The route level (HTTP save with 1000 and 1001 lines, nothing written) is in
  `documents_router_test.exs` (L1-HTTP). Tests: L1-1 (all six kinds), L1-2 (the cap value).
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Stock.Documents.Shape

  @id "7c92df01-53e8-43c9-8f33-0cb6d90e34e1"
  @line %{"catalog_item_id" => @id, "catalog_uom_id" => @id, "quantity" => "2"}

  defp one_sided(kind, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => kind,
        "org_unit_id" => @id,
        "location_id" => @id,
        "responsible_id" => @id,
        "event_time" => "2026-11-04T10:00:00Z"
      },
      extra
    )
  end

  defp two_sided(kind) do
    %{
      "kind" => kind,
      "org_unit_id" => @id,
      "from_location_id" => @id,
      "from_responsible_id" => @id,
      "to_org_unit_id" => Ecto.UUID.generate(),
      "to_location_id" => @id,
      "to_responsible_id" => @id,
      "event_time" => "2026-11-04T10:00:00Z"
    }
  end

  defp headers do
    [
      one_sided("receipt"),
      one_sided("issue"),
      one_sided("write_off", %{"reason_code" => "lost"}),
      two_sided("transfer"),
      two_sided("hand_over"),
      Map.merge(two_sided("return"), %{"from_org_unit_id" => Ecto.UUID.generate()})
      |> Map.delete("to_org_unit_id")
    ]
  end

  test "L1-2 the cap is 1000" do
    assert Shape.max_lines() == 1000
  end

  test "L1-1 each kind accepts 1000 lines and refuses 1001 with lines_count" do
    for header <- headers() do
      lines = fn n -> List.duplicate(@line, n) end
      assert {:ok, parsed} = Shape.parse(Map.put(header, "lines", lines.(1000)), :create)
      assert length(parsed.lines) == 1000, header["kind"]

      assert {:error, {"lines_count", _}} =
               Shape.parse(Map.put(header, "lines", lines.(1001)), :create)

      assert {:error, {"lines_count", _}} = Shape.parse(Map.put(header, "lines", []), :create)
    end
  end
end
