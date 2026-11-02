Code.require_file("locations_fixture.exs", __DIR__)
Code.require_file("../org/org_fixture.exs", __DIR__)

defmodule Letflow.Modules.Locations.LinkWriteTest do
  @moduledoc """
  GH #3586 / REQ-644 criterion 4: the stored shape of `location_org_unit_link` on the owner path
  (no write function exists yet): one pair is unique, many to many is accepted, an unknown
  location is refused by the foreign key, an unknown org unit is stored and never `linked?`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Letflow.LocationsFixture

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Locations

  setup do
    {:ok, installed_tenant!("gh3586-link")}
  end

  defp link_count(schema),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == "location_org_unit_link"), :count,
        prefix: schema
      )

  test "W-1: a link is accepted and read back", %{schema: schema} do
    loc = node!(schema, "W1")
    unit = org_unit!(schema)
    link = link!(schema, unit, loc.record_id)
    assert link.field_values["active"] == true
    assert link_count(schema) == 1
  end

  test "W-2: the same pair twice is refused by the unique constraint", %{schema: schema} do
    loc = node!(schema, "W2")
    unit = org_unit!(schema)
    link!(schema, unit, loc.record_id)

    result =
      create(schema, "location_org_unit_link", %{
        "location_id" => loc.record_id,
        "org_unit_id" => unit,
        "active" => true
      })

    assert {:error, _} = result
    refute match?({:ok, _}, result)
    assert link_count(schema) == 1
  end

  test "W-3: one location with two units and one unit with two locations", %{schema: schema} do
    l1 = node!(schema, "W3A")
    l2 = node!(schema, "W3B")
    u1 = org_unit!(schema)
    u2 = org_unit!(schema)
    link!(schema, u1, l1.record_id)
    link!(schema, u2, l1.record_id)
    link!(schema, u1, l2.record_id)
    assert link_count(schema) == 3
    assert Locations.location_ids_for_org_unit(schema, u1) |> length() == 2
    assert Locations.org_unit_ids_for_location(schema, l1.record_id) |> length() == 2
  end

  test "W-4: an unknown location id is refused as a reference violation and stores nothing",
       %{schema: schema} do
    unit = org_unit!(schema)

    assert {:error, {:record_payload_invalid, violations}} =
             create(schema, "location_org_unit_link", %{
               "location_id" => Ecto.UUID.generate(),
               "org_unit_id" => unit,
               "active" => true
             })

    assert Enum.any?(violations, &(inspect(&1) =~ "reference" and inspect(&1) =~ "location_id"))
    assert link_count(schema) == 0
  end

  test "W-5: an unknown org unit id is stored but never linked", %{schema: schema} do
    loc = node!(schema, "W5")
    ghost = Ecto.UUID.generate()
    link!(schema, ghost, loc.record_id)
    assert link_count(schema) == 1
    refute Locations.linked?(schema, ghost, loc.record_id)
    assert Locations.org_unit_ids_for_location(schema, loc.record_id) == []
  end
end
