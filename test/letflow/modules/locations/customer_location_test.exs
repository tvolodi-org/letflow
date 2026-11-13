Code.require_file("locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.Locations.CustomerLocationTest do
  @moduledoc """
  T-1840 (MES L2, plan 13 s8): the optional boolean `customer_location` on `location_node`
  (absent = false). Tests CL-1..CL-7: write through create, update and import, refusal of a
  non-boolean, old nodes read as not customer, the tree operations keep the field, the class A
  upgrade from 0.4.0, and tenant isolation.
  """

  use Letflow.DataCase, async: false

  import Letflow.LocationsFixture

  alias Letflow.Entities.ExternalRef
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Locations.Import
  alias Letflow.Modules.UpgradePlan
  alias Letflow.Repo

  @pack_path Path.join([File.cwd!(), "priv", "modules", "locations", "entity_definitions"])

  setup do
    {:ok, installed_tenant!("t1840-cl")}
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  defp attrs(code, extra),
    do: Map.merge(%{"code" => code, "name" => "N #{code}", "node_kind" => "zone"}, extra)

  defp mk!(schema, code, extra \\ %{}) do
    {:ok, node} = Locations.create_node(schema, attrs(code, extra), opts())
    node
  end

  defp count(schema) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}"."entity_location_node"|)
    n
  end

  defp import_row(schema, ext_id, cells) do
    entry = %{
      entity_type: "location_node",
      external_ref: %ExternalRef{system: "t1840", id: ext_id},
      field_values: cells
    }

    Import.row(schema, entry, %{
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    })
  end

  test "CL-1: create saves and reads the marker; update to false, then nil removes it", %{
    schema: schema
  } do
    node = mk!(schema, "C1", %{"customer_location" => true})
    assert node["customer_location"] == true
    assert {:ok, %{"customer_location" => true}} = Locations.lookup(schema, node["record_id"])

    assert {:ok, n2} =
             Locations.update_node(
               schema,
               node["record_id"],
               %{"customer_location" => false},
               opts()
             )

    assert n2["customer_location"] == false

    assert {:ok, n3} =
             Locations.update_node(
               schema,
               node["record_id"],
               %{"customer_location" => nil},
               opts()
             )

    refute Map.get(n3, "customer_location")
  end

  test "CL-2: a non-boolean is refused on create and update, nothing written", %{schema: schema} do
    before = count(schema)

    for bad <- ["yes", 1, "true", %{"a" => 1}] do
      assert {:error, {:field_invalid, "customer_location"}} =
               Locations.create_node(schema, attrs("C2", %{"customer_location" => bad}), opts())
    end

    assert count(schema) == before

    node = mk!(schema, "C2u")
    after_create = count(schema)

    assert {:error, {:field_invalid, "customer_location"}} =
             Locations.update_node(
               schema,
               node["record_id"],
               %{"customer_location" => "yes"},
               opts()
             )

    assert count(schema) == after_create
    assert {:ok, stored} = Locations.lookup(schema, node["record_id"])
    refute Map.get(stored, "customer_location")
  end

  test "CL-3: a node without the key reads as not customer", %{schema: schema} do
    node = mk!(schema, "C3")
    refute Map.has_key?(node, "customer_location")
    assert {:ok, stored} = Locations.lookup(schema, node["record_id"])
    refute Map.get(stored, "customer_location") == true
  end

  test "CL-4: import creates, updates, leaves unchanged and refuses a non-boolean", %{
    schema: schema
  } do
    cells = %{"code" => "I1", "name" => "I1", "node_kind" => "zone", "customer_location" => true}
    assert {:ok, %{record_id: id, outcome: :created}} = import_row(schema, "i1", cells)
    assert {:ok, %{"customer_location" => true}} = Locations.lookup(schema, id)

    assert {:ok, %{outcome: :unchanged}} = import_row(schema, "i1", cells)

    assert {:ok, %{outcome: :updated}} =
             import_row(schema, "i1", Map.put(cells, "customer_location", false))

    assert {:ok, %{"customer_location" => false}} = Locations.lookup(schema, id)

    assert {:error, {:field_invalid, "customer_location"}} =
             import_row(
               schema,
               "i2",
               %{cells | "code" => "I2"} |> Map.put("customer_location", "yes")
             )
  end

  test "CL-5: move and retire keep the marker", %{schema: schema} do
    a = mk!(schema, "A5")
    b = mk!(schema, "B5", %{"customer_location" => true})

    assert {:ok, moved} =
             Locations.move_node(schema, b["record_id"], a["record_id"], opts())

    assert moved["customer_location"] == true
    assert {:ok, retired} = Locations.retire_node(schema, b["record_id"], opts())
    assert retired["customer_location"] == true
  end

  test "CL-6: adding the field to a 0.4.0 definition is class A and 0.4.0 -> 0.5.0 has a path" do
    new = @pack_path |> Path.join("location_node.json") |> File.read!() |> Jason.decode!()

    old =
      Map.update!(new, "fields", &Enum.reject(&1, fn f -> f["name"] == "customer_location" end))

    assert {"A", "optional_field_added"} = UpgradePlan.classify_entity(old, new)
    assert Locations.manifest().version == "0.5.0"
    assert {:ok, []} = Catalog.upgrade_path(Locations.manifest(), "0.4.0", "0.5.0")

    # T-1860: the window now reaches back to 0.1.0, so older tenants have a path too.
    assert {:ok, []} = Catalog.upgrade_path(Locations.manifest(), "0.3.0", "0.5.0")
  end

  test "CL-7: a marker on one tenant's node does not reach another tenant", %{schema: schema} do
    other = installed_tenant!("t1840-cl2")
    mk!(schema, "SAME", %{"customer_location" => true})
    n = mk!(other.schema, "SAME")
    assert {:ok, stored} = Locations.lookup(other.schema, n["record_id"])
    refute Map.get(stored, "customer_location")
  end
end
