Code.require_file("locations_fixture.exs", __DIR__)
Code.require_file("../org/org_fixture.exs", __DIR__)

defmodule Letflow.Modules.Locations.LinkWritersTest do
  @moduledoc """
  GH #3616 / REQ-662 (tests F-*, R-*, U-*, A-*, T-*, D-*): `link_unit_location/4` and
  `unlink_unit_location/4` on freshly provisioned tenants with the real installed modules.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Letflow.LocationsFixture

  alias Letflow.Audit.Entry
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Modules.Locations
  alias Letflow.OrgFixture
  alias Letflow.Repo

  @links_path Path.join([File.cwd!(), "lib", "letflow", "modules", "locations", "links.ex"])
  @locations_path Path.join([
                    File.cwd!(),
                    "lib",
                    "letflow",
                    "modules",
                    "locations",
                    "locations.ex"
                  ])

  setup do
    {:ok, installed_tenant!("gh3616-lw")}
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  defp link_count(schema),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == "location_org_unit_link"), :count,
        prefix: schema
      )

  defp audit_actions(schema) do
    Repo.all(
      from(a in Entry,
        where: like(a.action, "location_org_unit_link.%"),
        order_by: a.timestamp,
        select: a.action
      ),
      prefix: schema
    )
  end

  defp audit_entries(schema) do
    Repo.all(
      from(a in Entry, where: like(a.action, "location_org_unit_link.%"), order_by: a.timestamp),
      prefix: schema
    )
  end

  defp unit!(schema, code \\ "U-#{System.unique_integer([:positive])}"),
    do: OrgFixture.create!(schema, "org_unit", OrgFixture.values("org_unit", code))

  # Retires a unit on the owner path (the fixture units have no scope tree node).
  defp retire_unit!(schema, unit) do
    {:ok, _} =
      Records.update_record(
        %{
          entity_type: "org_unit",
          record_id: unit.record_id,
          field_values: Map.put(unit.field_values, "active", false),
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        schema,
        OrgFixture.owner()
      )

    :ok
  end

  defp retire_location!(schema, node) do
    update!(schema, node, Map.put(node.field_values, "active", false))
    :ok
  end

  describe "criterion 1: link, unlink, relink" do
    test "F-1: a link is created and read by the three reads", %{schema: schema} do
      loc = node!(schema, "F1")
      unit = unit!(schema)

      assert {:ok, %{"active" => true, "location_id" => lid, "org_unit_id" => uid} = link} =
               Locations.link_unit_location(schema, unit.record_id, loc.record_id, opts())

      assert lid == loc.record_id and uid == unit.record_id
      assert link["entity_type"] == "location_org_unit_link"
      assert Locations.linked?(schema, unit.record_id, loc.record_id)
      assert Locations.location_ids_for_org_unit(schema, unit.record_id) == [loc.record_id]
      assert Locations.org_unit_ids_for_location(schema, loc.record_id) == [unit.record_id]
    end

    test "F-2: unlink makes the pair not linked and keeps the record", %{schema: schema} do
      loc = node!(schema, "F2")
      unit = unit!(schema)
      {:ok, link} = Locations.link_unit_location(schema, unit.record_id, loc.record_id, opts())

      assert {:ok, %{"active" => false} = out} =
               Locations.unlink_unit_location(schema, unit.record_id, loc.record_id, opts())

      assert out["record_id"] == link["record_id"]
      refute Locations.linked?(schema, unit.record_id, loc.record_id)
      assert link_count(schema) == 1
    end

    test "F-3: linking again after unlink reuses the record", %{schema: schema} do
      loc = node!(schema, "F3")
      unit = unit!(schema)
      {:ok, link} = Locations.link_unit_location(schema, unit.record_id, loc.record_id, opts())
      {:ok, _} = Locations.unlink_unit_location(schema, unit.record_id, loc.record_id, opts())

      assert {:ok, %{"active" => true} = again} =
               Locations.link_unit_location(schema, unit.record_id, loc.record_id, opts())

      assert again["record_id"] == link["record_id"]
      assert link_count(schema) == 1
      assert Locations.linked?(schema, unit.record_id, loc.record_id)
    end

    test "F-4: linking a linked pair is a no-op without record or audit entry", %{schema: schema} do
      loc = node!(schema, "F4")
      unit = unit!(schema)
      {:ok, link} = Locations.link_unit_location(schema, unit.record_id, loc.record_id, opts())

      assert {:ok, same} =
               Locations.link_unit_location(schema, unit.record_id, loc.record_id, opts())

      assert same == link
      assert link_count(schema) == 1
      assert audit_actions(schema) == ["location_org_unit_link.created"]
    end

    test "F-5: many to many", %{schema: schema} do
      l1 = node!(schema, "F5A")
      l2 = node!(schema, "F5B")
      u1 = unit!(schema)
      u2 = unit!(schema)

      for {u, l} <- [{u1, l1}, {u2, l1}, {u1, l2}] do
        assert {:ok, _} = Locations.link_unit_location(schema, u.record_id, l.record_id, opts())
      end

      assert link_count(schema) == 3

      assert Locations.location_ids_for_org_unit(schema, u1.record_id) ==
               Enum.sort([l1.record_id, l2.record_id])

      assert Locations.org_unit_ids_for_location(schema, l1.record_id) ==
               Enum.sort([u1.record_id, u2.record_id])
    end
  end

  describe "criterion 2: refusals write nothing" do
    setup %{schema: schema} do
      {:ok, loc: node!(schema, "RL"), unit: unit!(schema)}
    end

    defp refused(schema, fun, args, expected) do
      assert {:error, ^expected} = apply(Locations, fun, [schema | args] ++ [opts()])
      assert link_count(schema) == 0
      assert audit_actions(schema) == []
    end

    test "R-1..R-4: unit not found", %{schema: schema, loc: loc} do
      refused(schema, :link_unit_location, ["not-a-uuid", loc.record_id], :unit_not_found)
      refused(schema, :link_unit_location, [Ecto.UUID.generate(), loc.record_id], :unit_not_found)

      dead = unit!(schema)
      OrgFixture.delete!(schema, dead)
      refused(schema, :link_unit_location, [dead.record_id, loc.record_id], :unit_not_found)

      {:ok, site} =
        OrgFixture.create(schema, "org_site", OrgFixture.values("org_site", "S-R4"))

      refused(
        schema,
        :link_unit_location,
        [site.record.record_id, loc.record_id],
        :unit_not_found
      )
    end

    test "R-5: retired unit", %{schema: schema, loc: loc, unit: unit} do
      retire_unit!(schema, unit)
      refused(schema, :link_unit_location, [unit.record_id, loc.record_id], :unit_inactive)
    end

    test "R-6, R-7: location not found", %{schema: schema, unit: unit} do
      refused(
        schema,
        :link_unit_location,
        [unit.record_id, Ecto.UUID.generate()],
        :location_not_found
      )

      refused(schema, :link_unit_location, [unit.record_id, "nope"], :location_not_found)
      refused(schema, :link_unit_location, [unit.record_id, unit.record_id], :location_not_found)
    end

    test "R-7: the id of a link record is not a location", %{schema: schema, loc: loc, unit: unit} do
      {:ok, link} = Locations.link_unit_location(schema, unit.record_id, loc.record_id, opts())
      other = unit!(schema)

      assert {:error, :location_not_found} =
               Locations.link_unit_location(schema, other.record_id, link["record_id"], opts())

      assert link_count(schema) == 1
    end

    test "R-8: retired location", %{schema: schema, loc: loc, unit: unit} do
      retire_location!(schema, loc)
      refused(schema, :link_unit_location, [unit.record_id, loc.record_id], :location_inactive)
    end

    test "R-9..R-11: unlink without an active link", %{schema: schema, loc: loc, unit: unit} do
      refused(schema, :unlink_unit_location, [unit.record_id, loc.record_id], :link_not_found)

      refused(
        schema,
        :unlink_unit_location,
        [Ecto.UUID.generate(), Ecto.UUID.generate()],
        :link_not_found
      )

      refused(schema, :unlink_unit_location, ["x", "y"], :link_not_found)

      {:ok, _} = Locations.link_unit_location(schema, unit.record_id, loc.record_id, opts())
      {:ok, _} = Locations.unlink_unit_location(schema, unit.record_id, loc.record_id, opts())
      before = audit_actions(schema)

      assert {:error, :link_not_found} =
               Locations.unlink_unit_location(schema, unit.record_id, loc.record_id, opts())

      assert audit_actions(schema) == before
    end
  end

  describe "criterion 3: unlink when an end is retired" do
    test "U-1, U-2: retired unit can be unlinked, not linked", %{schema: schema} do
      loc = node!(schema, "U1")
      unit = unit!(schema)
      {:ok, _} = Locations.link_unit_location(schema, unit.record_id, loc.record_id, opts())
      retire_unit!(schema, unit)

      assert {:ok, %{"active" => false}} =
               Locations.unlink_unit_location(schema, unit.record_id, loc.record_id, opts())

      assert {:error, :unit_inactive} =
               Locations.link_unit_location(schema, unit.record_id, loc.record_id, opts())
    end

    test "U-3: retired location can be unlinked", %{schema: schema} do
      loc = node!(schema, "U3")
      unit = unit!(schema)
      {:ok, _} = Locations.link_unit_location(schema, unit.record_id, loc.record_id, opts())
      retire_location!(schema, loc)

      assert {:ok, %{"active" => false}} =
               Locations.unlink_unit_location(schema, unit.record_id, loc.record_id, opts())
    end
  end

  describe "criterion 4: audit and idempotency" do
    test "A-1: created, reactivated, retired, one entry each", %{schema: schema} do
      loc = node!(schema, "A1")
      unit = unit!(schema)
      actor = Ecto.UUID.generate()
      o = fn -> %{actor_id: actor, idempotency_key: Ecto.UUID.generate()} end

      {:ok, link} = Locations.link_unit_location(schema, unit.record_id, loc.record_id, o.())
      {:ok, _} = Locations.unlink_unit_location(schema, unit.record_id, loc.record_id, o.())
      {:ok, _} = Locations.link_unit_location(schema, unit.record_id, loc.record_id, o.())

      entries = audit_entries(schema)

      assert Enum.map(entries, & &1.action) ==
               [
                 "location_org_unit_link.created",
                 "location_org_unit_link.retired",
                 "location_org_unit_link.reactivated"
               ]

      for e <- entries do
        assert e.actor_id == actor
        assert e.resource_type == "location_org_unit_link"
        assert e.resource_id == link["record_id"]
      end

      [created, retired, reactivated] = entries
      assert created.before_state == nil
      assert created.after_state["active"] == true
      assert retired.before_state["active"] == true and retired.after_state["active"] == false
      assert reactivated.before_state["active"] == false
      assert reactivated.after_state["active"] == true
      assert created.after_state["org_unit_id"] == unit.record_id
    end

    test "A-2: a refusal writes no entry", %{schema: schema} do
      assert {:error, :unit_not_found} =
               Locations.link_unit_location(
                 schema,
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate(),
                 opts()
               )

      assert audit_actions(schema) == []
    end

    test "A-3: a repeated key returns the original, nothing new", %{schema: schema} do
      loc = node!(schema, "A3")
      unit = unit!(schema)
      k1 = %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
      k2 = %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
      k3 = %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
      u = unit.record_id
      l = loc.record_id

      {:ok, created} = Locations.link_unit_location(schema, u, l, k1)
      assert {:ok, %{"record_id" => id}} = Locations.link_unit_location(schema, u, l, k1)
      assert id == created["record_id"]

      {:ok, _} = Locations.unlink_unit_location(schema, u, l, k3)
      {:ok, _} = Locations.link_unit_location(schema, u, l, k2)
      assert {:ok, %{"record_id" => ^id}} = Locations.link_unit_location(schema, u, l, k2)

      # the create key again, after the link was unlinked and relinked, and the unlink key again
      assert {:ok, %{"record_id" => ^id}} = Locations.link_unit_location(schema, u, l, k1)
      assert {:ok, %{"record_id" => ^id}} = Locations.unlink_unit_location(schema, u, l, k3)

      assert link_count(schema) == 1

      assert audit_actions(schema) == [
               "location_org_unit_link.created",
               "location_org_unit_link.retired",
               "location_org_unit_link.reactivated"
             ]
    end

    test "A-4: the same key for a different pair is refused", %{schema: schema} do
      l1 = node!(schema, "A4A")
      l2 = node!(schema, "A4B")
      unit = unit!(schema)
      o = opts()
      {:ok, _} = Locations.link_unit_location(schema, unit.record_id, l1.record_id, o)

      assert {:error, :idempotency_key_reuse} =
               Locations.link_unit_location(schema, unit.record_id, l2.record_id, o)

      assert link_count(schema) == 1
    end

    test "A-5: an audit failure rolls the record back", %{schema: schema} do
      loc = node!(schema, "A5")
      unit = unit!(schema)
      Repo.query!(~s(DROP TABLE "#{schema}".audit_entries))

      assert {:error, :audit_failed} =
               Locations.link_unit_location(schema, unit.record_id, loc.record_id, opts())

      assert link_count(schema) == 0
    end

    test "A-6: a missing or bad actor or key raises ArgumentError", %{schema: schema} do
      id = Ecto.UUID.generate()

      assert_raise ArgumentError, fn ->
        Locations.link_unit_location(schema, id, id, %{idempotency_key: "k"})
      end

      assert_raise ArgumentError, fn ->
        Locations.unlink_unit_location(schema, id, id, %{actor_id: "nope", idempotency_key: "k"})
      end

      assert_raise ArgumentError, fn ->
        Locations.link_unit_location(schema, id, id, %{actor_id: Ecto.UUID.generate()})
      end
    end
  end

  describe "criterion 5: tenant isolation" do
    test "T-1, T-2: ids of another tenant are indistinguishable from unknown ids", %{schema: a} do
      %{schema: b} = installed_tenant!("gh3616-lw-b")
      loc_a = node!(a, "TA")
      unit_a = unit!(a)
      loc_b = node!(b, "TB")
      unit_b = unit!(b)
      {:ok, _} = Locations.link_unit_location(a, unit_a.record_id, loc_a.record_id, opts())

      assert {:error, :unit_not_found} =
               Locations.link_unit_location(b, unit_a.record_id, loc_b.record_id, opts())

      assert {:error, :location_not_found} =
               Locations.link_unit_location(b, unit_b.record_id, loc_a.record_id, opts())

      assert {:error, :link_not_found} =
               Locations.unlink_unit_location(b, unit_a.record_id, loc_a.record_id, opts())

      assert link_count(b) == 0
      assert link_count(a) == 1
      assert Locations.linked?(a, unit_a.record_id, loc_a.record_id)
    end

    test "T-3: the functions take no tenant argument and read no prefix from opts" do
      src = File.read!(@links_path)
      refute src =~ ~r/opts\[:(prefix|tenant)/
      refute src =~ ~r/Map\.(get|fetch!?)\(opts, :(prefix|tenant)/
      refute src =~ ~r/def (un)?link_unit_location\([^)]*tenant/
    end
  end

  describe "criterion 6: documentation" do
    test "D-2: the locations moduledoc names both functions" do
      src = File.read!(@locations_path)
      assert src =~ "link_unit_location/4"
      assert src =~ "unlink_unit_location/4"
      refute src =~ "Nothing writes links yet"
    end
  end
end
