Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.TrackingPolicyCrossTenantTest do
  @moduledoc """
  GH #3581 / REQ-641 (X-01): `validate_capture/3` reads through the given schema only; an item of
  tenant A is not found with tenant B's schema, and each tenant applies its own policy.
  """

  use Letflow.DataCase, async: false

  import Letflow.CatalogItemsFixture

  alias Letflow.Modules.CatalogItems

  test "tracking_policy_cross_tenant_test: the schema alone decides" do
    a = installed_tenant!("gh3581-xa")
    b = installed_tenant!("gh3581-xb")

    item_a =
      item!(a.schema, "X-1", uom!(a.schema, "U-A").record_id, %{"tracking_policy" => "serial"})

    item_b =
      item!(b.schema, "X-1", uom!(b.schema, "U-B").record_id, %{"tracking_policy" => "lot"})

    capture = %{"serial" => "S1"}
    assert :ok = CatalogItems.validate_capture(a.schema, item_a.record_id, capture)

    foreign = CatalogItems.validate_capture(b.schema, item_a.record_id, capture)
    unknown = CatalogItems.validate_capture(b.schema, Ecto.UUID.generate(), capture)
    assert foreign == {:error, :item_not_found}
    assert foreign == unknown

    assert :ok = CatalogItems.validate_capture(b.schema, item_b.record_id, %{"lot" => "L"})

    assert {:error, {:capture_not_allowed, "lot"}} =
             CatalogItems.validate_capture(a.schema, item_a.record_id, %{
               "serial" => "S",
               "lot" => "L"
             })
  end
end
