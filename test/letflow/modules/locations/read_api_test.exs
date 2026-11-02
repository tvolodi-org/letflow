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
    parent = node!(schema, "RD-0", "zone")

    vals =
      values("location_node", "RD-1", %{
        "node_kind" => "address",
        "address" => "A-1",
        "location_type" => "pick",
        "parent_id" => parent.record_id,
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

  describe "GH #3586: links between org units and locations" do
    setup %{schema: schema} do
      loc = node!(schema, "LK-1")
      unit = org_unit!(schema)
      link = link!(schema, unit, loc.record_id)
      %{loc: loc, unit: unit, link: link}
    end

    test "L-A4-1: linked? is true for an active pair", %{schema: s, loc: loc, unit: unit} do
      assert Locations.linked?(s, unit, loc.record_id)
      assert Locations.linked?(s, String.upcase(unit), String.upcase(loc.record_id))
    end

    test "L-A4-2: an inactive link is not linked", %{schema: s, loc: loc, unit: unit, link: link} do
      update!(s, link, Map.put(link.field_values, "active", false))
      refute Locations.linked?(s, unit, loc.record_id)
    end

    test "L-A4-3: a soft-deleted link is not linked", %{
      schema: s,
      loc: loc,
      unit: unit,
      link: link
    } do
      delete!(s, link)
      refute Locations.linked?(s, unit, loc.record_id)
    end

    test "L-A4-4: no link for another pair", %{schema: s, loc: loc, unit: unit} do
      refute Locations.linked?(s, org_unit!(s), loc.record_id)
      refute Locations.linked?(s, unit, node!(s, "LK-OTHER").record_id)
    end

    test "L-A4-5: an inactive org unit is not linked", %{schema: s, loc: loc, unit: unit} do
      inactive = org_unit!(s, "IN-1", %{"active" => false})
      link!(s, inactive, loc.record_id)
      refute Locations.linked?(s, inactive, loc.record_id)
      assert Locations.linked?(s, unit, loc.record_id)
    end

    test "L-A4-6: an inactive location is not linked", %{schema: s} do
      loc = node!(s, "LK-OFF", "site", %{"active" => false})
      unit = org_unit!(s)
      link!(s, unit, loc.record_id)
      refute Locations.linked?(s, unit, loc.record_id)
    end

    test "L-A4-7: an org_site id is not an org unit", %{schema: s} do
      loc = node!(s, "LK-SITE")

      site =
        Letflow.OrgFixture.create!(s, "org_site", Letflow.OrgFixture.values("org_site", "S-1"))

      link!(s, site.record_id, loc.record_id)
      refute Locations.linked?(s, site.record_id, loc.record_id)
      assert Locations.org_unit_ids_for_location(s, loc.record_id) == []
    end

    test "L-A4-8: values that are not uuids are false and never raise", %{
      schema: s,
      loc: loc,
      unit: unit
    } do
      for bad <- @non_uuids do
        refute Locations.linked?(s, bad, loc.record_id)
        refute Locations.linked?(s, unit, bad)
        assert Locations.location_ids_for_org_unit(s, bad) == []
        assert Locations.org_unit_ids_for_location(s, bad) == []
      end
    end

    test "L-A4-9: a non-binary or malformed prefix is false and empty", %{loc: loc, unit: unit} do
      for p <- [nil, 5, :x, "public"] do
        refute Locations.linked?(p, unit, loc.record_id)
        assert Locations.location_ids_for_org_unit(p, unit) == []
        assert Locations.org_unit_ids_for_location(p, loc.record_id) == []
      end
    end

    test "D-A4-1: lists are sorted and hold one element for one link", %{
      schema: s,
      loc: loc,
      unit: unit
    } do
      assert Locations.location_ids_for_org_unit(s, unit) == [loc.record_id]
      assert Locations.org_unit_ids_for_location(s, loc.record_id) == [unit]
      l2 = node!(s, "LK-2")
      l3 = node!(s, "LK-3")
      link!(s, unit, l2.record_id)
      link!(s, unit, l3.record_id)
      ids = Locations.location_ids_for_org_unit(s, unit)
      assert ids == Enum.sort([loc.record_id, l2.record_id, l3.record_id])
    end

    test "D-A4-2: an inactive link is left out of both lists", %{
      schema: s,
      loc: loc,
      unit: unit,
      link: link
    } do
      update!(s, link, Map.put(link.field_values, "active", false))
      assert Locations.location_ids_for_org_unit(s, unit) == []
      assert Locations.org_unit_ids_for_location(s, loc.record_id) == []
    end

    test "D-A4-3: a retired location drops out of the unit list and its own list is empty", %{
      schema: s,
      loc: loc,
      unit: unit
    } do
      update!(s, loc, Map.put(loc.field_values, "active", false))
      assert Locations.location_ids_for_org_unit(s, unit) == []
      assert Locations.org_unit_ids_for_location(s, loc.record_id) == []
    end

    test "D-A4-4: unknown ids give empty lists", %{schema: s} do
      assert Locations.location_ids_for_org_unit(s, Ecto.UUID.generate()) == []
      assert Locations.org_unit_ids_for_location(s, Ecto.UUID.generate()) == []
    end

    test "D-A4-5: a link whose org unit is soft-deleted is left out", %{schema: s, loc: loc} do
      row =
        Letflow.OrgFixture.create!(
          s,
          "org_unit",
          Letflow.OrgFixture.values("org_unit", "GONE-1")
        )

      link!(s, row.record_id, loc.record_id)
      assert row.record_id in Locations.org_unit_ids_for_location(s, loc.record_id)
      Letflow.OrgFixture.delete!(s, row)
      refute row.record_id in Locations.org_unit_ids_for_location(s, loc.record_id)
      refute Locations.linked?(s, row.record_id, loc.record_id)
    end

    test "L-A4-10: a link id is not a location for lookup or active?", %{schema: s, link: link} do
      assert Locations.lookup(s, link.record_id) == {:error, :not_found}
      refute Locations.active?(s, link.record_id)
    end

    test "T-A4-1: another tenant's prefix sees none of these ids", %{
      schema: s,
      loc: loc,
      unit: unit
    } do
      %{schema: other} = installed_tenant!("gh3586-other")
      assert Locations.linked?(s, unit, loc.record_id)
      refute Locations.linked?(other, unit, loc.record_id)
      assert Locations.location_ids_for_org_unit(other, unit) == []
      assert Locations.org_unit_ids_for_location(other, loc.record_id) == []
    end
  end
end
