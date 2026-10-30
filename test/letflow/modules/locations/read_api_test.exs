Code.require_file("locations_fixture.exs", __DIR__)
Code.require_file("../org/org_fixture.exs", __DIR__)

defmodule Letflow.Modules.Locations.ReadApiTest do
  @moduledoc """
  GH #3501 / REQ-625 criteria 9 and 10 (tests L-1.., S-1): `Letflow.Modules.Locations.lookup/2` and
  `active?/2` on real provisioned tenants with the real installed module. Isolation is by prefix
  alone.
  """

  use Letflow.DataCase, async: false

  import Letflow.LocationsFixture

  alias Letflow.Modules.Locations

  # Values that are not a uuid; none may raise.
  @non_uuids [nil, 123, "x", "", %{}, %{"a" => 1}, [], :atom, 1.5, "not-a-uuid", <<255>>]

  setup do
    {:ok, installed_tenant!("gh3501-read")}
  end

  test "L-1a: lookup returns record_id, entity_type and every stored field; active? is true",
       %{schema: schema} do
    vals =
      values("location_node", "RD-1", %{
        "node_kind" => "address",
        "address" => "A-1",
        "location_type" => "pick",
        "parent_id" => "z-1",
        "org_site_id" => "s-1",
        "external_ref_system" => "1c",
        "external_ref_id" => "7"
      })

    rec = create!(schema, "location_node", vals)

    assert {:ok, map} = Locations.lookup(schema, rec.record_id)
    assert map["record_id"] == rec.record_id
    assert map["entity_type"] == "location_node"

    for {field, value} <- vals, do: assert(map[field] == value, field)

    assert Locations.active?(schema, rec.record_id) == true
  end

  test "L-1b: active? is false for a retired location, an unknown uuid and a deleted record",
       %{schema: schema} do
    retired = node!(schema, "RT", "site", %{"active" => false})
    assert {:ok, %{"active" => false}} = Locations.lookup(schema, retired.record_id)
    refute Locations.active?(schema, retired.record_id)

    unknown = Ecto.UUID.generate()
    assert {:error, :not_found} = Locations.lookup(schema, unknown)
    refute Locations.active?(schema, unknown)

    gone = node!(schema, "GONE")
    assert Locations.active?(schema, gone.record_id)
    delete!(schema, gone)
    assert {:error, :not_found} = Locations.lookup(schema, gone.record_id)
    refute Locations.active?(schema, gone.record_id)
  end

  test "L-1c: the id of a record of another type is not found and not active", %{schema: _} do
    # A tenant with org installed first, then locations: an org_site id must not read as a location.
    tenant = Letflow.OrgFixture.installed_tenant!("gh3501-oth")
    install_locations!(tenant.tenant_id)

    site =
      Letflow.OrgFixture.create!(
        tenant.schema,
        "org_site",
        Letflow.OrgFixture.values("org_site", "OS1", %{})
      )

    assert {:error, :not_found} = Locations.lookup(tenant.schema, site.record_id)
    refute Locations.active?(tenant.schema, site.record_id)

    own = node!(tenant.schema, "OWN")

    assert {:ok, %{"entity_type" => "location_node"}} =
             Locations.lookup(tenant.schema, own.record_id)
  end

  test "L-1d: a non-uuid id never raises", %{schema: schema} do
    for bad <- @non_uuids do
      assert {:error, :not_found} = Locations.lookup(schema, bad), inspect(bad)
      assert Locations.active?(schema, bad) == false, inspect(bad)
    end
  end

  test "L-1e: a non-binary prefix is not found, never a raise" do
    id = Ecto.UUID.generate()

    for bad <- [nil, 123, :tenant_x, %{}, [], 1.5] do
      assert {:error, :not_found} = Locations.lookup(bad, id), inspect(bad)
      assert Locations.active?(bad, id) == false, inspect(bad)
    end
  end

  test "S-1: a location of tenant A is invisible to tenant B and answers like an absent id",
       %{schema: schema_a} do
    b = installed_tenant!("gh3501-read-b")
    rec = node!(schema_a, "ISO")
    assert Locations.active?(schema_a, rec.record_id)

    absent = Ecto.UUID.generate()
    assert Locations.lookup(b.schema, rec.record_id) == Locations.lookup(b.schema, absent)
    assert {:error, :not_found} = Locations.lookup(b.schema, rec.record_id)
    assert Locations.active?(b.schema, rec.record_id) == false
    assert Locations.active?(b.schema, absent) == false
  end
end
