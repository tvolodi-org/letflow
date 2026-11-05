Code.require_file("catalog_items/catalog_items_fixture.exs", __DIR__)
Code.require_file("org/org_fixture.exs", __DIR__)
Code.require_file("locations/locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.ReadApiExternalRefTest do
  @moduledoc """
  REQ-727 / GH #3773 criterion 1: `Letflow.Modules.ReadApi.lookup_by_external_ref/5` and the
  `lookup_by_external_ref/4` wrappers of Org, Locations and CatalogItems, on fresh committed tenants.
  R1-1 found; R1-2 soft-deleted; R1-3 type outside the list; R1-4 non-text arguments, no raise;
  R1-5 another tenant's pair; R1-6 the three wrappers; R1-7 an absent pair.
  """

  use Letflow.DataCase, async: false

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.LocationsFixture, as: LocFx
  alias Letflow.OrgFixture

  defp ref(id), do: %{"external_ref_system" => "erp", "external_ref_id" => id}
  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  setup do
    a = Cat.installed_tenant!("gh3773-ra")
    {:ok, a: a.schema}
  end

  test "R1-1 a live record is found by its pair, in the lookup/3 map shape", %{a: a} do
    uom = Cat.uom!(a, "PCS1", ref("U1"))

    assert {:ok, found} =
             ReadApi.lookup_by_external_ref(a, "catalog_uom", "erp", "U1", ["catalog_uom"])

    assert found["record_id"] == uom.record_id
    assert found["entity_type"] == "catalog_uom"
    assert found["code"] == "PCS1"
    assert {:ok, ^found} = ReadApi.lookup(a, uom.record_id, ["catalog_uom"])
  end

  test "R1-2 a soft-deleted record is not found", %{a: a} do
    uom = Cat.uom!(a, "PCS2", ref("U2"))
    Cat.delete!(a, uom)

    assert {:error, :not_found} =
             ReadApi.lookup_by_external_ref(a, "catalog_uom", "erp", "U2", ["catalog_uom"])
  end

  test "R1-3 a type outside the list, and a wrong system, are not found", %{a: a} do
    Cat.uom!(a, "PCS3", ref("U3"))

    assert {:error, :not_found} =
             ReadApi.lookup_by_external_ref(a, "catalog_uom", "erp", "U3", ["catalog_item"])

    assert {:error, :not_found} =
             ReadApi.lookup_by_external_ref(a, "catalog_item", "erp", "U3", ["catalog_uom"])

    assert {:error, :not_found} =
             ReadApi.lookup_by_external_ref(a, "catalog_uom", "other", "U3", ["catalog_uom"])
  end

  test "R1-4 non-text arguments answer not_found and never raise", %{a: a} do
    bad = [nil, 1, 1.5, :atom, %{}, [], <<255>>]
    types = ["catalog_uom"]

    for v <- bad do
      assert {:error, :not_found} =
               ReadApi.lookup_by_external_ref(a, "catalog_uom", v, "x", types)

      assert {:error, :not_found} =
               ReadApi.lookup_by_external_ref(a, "catalog_uom", "erp", v, types)

      assert {:error, :not_found} = ReadApi.lookup_by_external_ref(a, v, "erp", "x", types)

      assert {:error, :not_found} =
               ReadApi.lookup_by_external_ref(v, "catalog_uom", "erp", "x", types)
    end

    assert {:error, :not_found} =
             ReadApi.lookup_by_external_ref(a, "catalog_uom", "erp", "x", nil)

    assert {:error, :not_found} =
             ReadApi.lookup_by_external_ref("not a schema", "t", "e", "x", types)
  end

  test "R1-5 a pair held in tenant B is not found from tenant A's prefix", %{a: a} do
    b = Cat.installed_tenant!("gh3773-rb")
    Cat.uom!(b.schema, "PCSB", ref("UB"))

    assert {:ok, _} =
             ReadApi.lookup_by_external_ref(b.schema, "catalog_uom", "erp", "UB", ["catalog_uom"])

    assert {:error, :not_found} =
             ReadApi.lookup_by_external_ref(a, "catalog_uom", "erp", "UB", ["catalog_uom"])
  end

  test "R1-6 the Org, Locations and CatalogItems wrappers use their own type lists" do
    org = OrgFixture.installed_tenant!("gh3773-ro")

    {:ok, unit_le} =
      Org.create_legal_entity(
        org.schema,
        %{"code" => "LE1", "name" => "LE", "bin" => "555555555551"},
        opts()
      )

    {:ok, site} =
      Org.create_site(
        org.schema,
        %{"code" => "S1", "name" => "S", "legal_entity_id" => unit_le["record_id"]},
        opts()
      )

    {:ok, unit} =
      Org.create_unit(
        org.schema,
        Map.merge(
          %{
            "code" => "U1",
            "name" => "U",
            "legal_entity_id" => unit_le["record_id"],
            "site_id" => site["record_id"]
          },
          ref("ORG1")
        ),
        opts()
      )

    assert {:ok, %{"record_id" => id}} =
             Org.lookup_by_external_ref(org.schema, "org_unit", "erp", "ORG1")

    assert id == unit["record_id"]

    assert {:error, :not_found} =
             Org.lookup_by_external_ref(org.schema, "catalog_uom", "erp", "ORG1")

    loc = Cat.installed_tenant!("gh3773-rl")
    cat_uom = Cat.uom!(loc.schema, "PCSW", ref("W1"))

    assert {:ok, %{"record_id" => cid}} =
             CatalogItems.lookup_by_external_ref(loc.schema, "catalog_uom", "erp", "W1")

    assert cid == cat_uom.record_id

    assert {:error, :not_found} =
             CatalogItems.lookup_by_external_ref(loc.schema, "org_unit", "erp", "W1")

    lt = LocFx.installed_tenant!("gh3773-rn")

    {:ok, node} =
      Locations.create_node(
        lt.schema,
        Map.merge(%{"code" => "N1", "name" => "N", "node_kind" => "zone"}, ref("LOC1")),
        opts()
      )

    assert {:ok, %{"record_id" => nid}} =
             Locations.lookup_by_external_ref(lt.schema, "location_node", "erp", "LOC1")

    assert nid == node["record_id"]

    assert {:error, :not_found} =
             Locations.lookup_by_external_ref(lt.schema, "catalog_uom", "erp", "LOC1")
  end

  test "R1-7 an absent pair is not found", %{a: a} do
    assert {:error, :not_found} =
             ReadApi.lookup_by_external_ref(a, "catalog_uom", "erp", "none", ["catalog_uom"])
  end
end
