Code.require_file("locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.Locations.BehaviourTest do
  @moduledoc """
  GH #3501 / REQ-625 criteria 6, 7 and 8 (tests H-1, T-1, X-1): the site/zone/address hierarchy,
  uniqueness, enum and required-field refusals, external_ref semantics and retire with `active`
  false, through the owner path on a real provisioned tenant with the real installed module.
  """

  use Letflow.DataCase, async: false

  import Letflow.LocationsFixture

  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Registry.ValidationFailure
  alias Letflow.Modules.Locations

  @type_values ~w(receiving pick ship reject quarantine custody outdoor)

  setup do
    {:ok, installed_tenant!("gh3501-beh")}
  end

  defp ref(system, id), do: %{"external_ref_system" => system, "external_ref_id" => id}

  describe "criterion 6: hierarchy and uniqueness" do
    test "H-1a: a site, a zone under it and an address under the zone are stored and read back",
         %{schema: schema} do
      site = node!(schema, "S1", "site")
      zone = node!(schema, "Z1", "zone", %{"parent_id" => site.record_id})

      addr =
        node!(schema, "A1", "address", %{"parent_id" => zone.record_id, "address" => "A-01-01"})

      assert {:ok, %{"node_kind" => "site"} = s} = Locations.lookup(schema, site.record_id)
      refute Map.has_key?(s, "parent_id")
      assert {:ok, %{"parent_id" => zid}} = Locations.lookup(schema, zone.record_id)
      assert zid == site.record_id

      assert {:ok, %{"parent_id" => pid, "address" => "A-01-01"}} =
               Locations.lookup(schema, addr.record_id)

      assert pid == zone.record_id
    end

    test "H-1b: a second node with an existing code is a :unique violation on code", %{
      schema: schema
    } do
      node!(schema, "DUP")

      assert {:error, {:record_payload_invalid, [%Violation{rule: :unique, path: ["code"]}]}} =
               create(
                 schema,
                 "location_node",
                 values("location_node", "DUP", %{"name" => "other"})
               )

      assert {:ok, _} = create(schema, "location_node", values("location_node", "OTHER", %{}))
    end

    test "H-1c: an existing non-null address is a :unique violation on address", %{schema: schema} do
      node!(schema, "AD1", "address", %{"address" => "R-1"})

      assert {:error, {:record_payload_invalid, [%Violation{rule: :unique, path: ["address"]}]}} =
               create(
                 schema,
                 "location_node",
                 values("location_node", "AD2", %{"node_kind" => "address", "address" => "R-1"})
               )
    end

    test "H-1d: two rows with no address are accepted", %{schema: schema} do
      assert {:ok, %{record: a}} =
               create(schema, "location_node", values("location_node", "NA1", %{}))

      assert {:ok, %{record: b}} =
               create(schema, "location_node", values("location_node", "NA2", %{}))

      assert a.record_id != b.record_id
    end

    test "H-1e: the same address in another tenant's schema is accepted", %{schema: schema} do
      node!(schema, "T1", "address", %{"address" => "SHARED"})
      other = installed_tenant!("gh3501-beh2")

      assert {:ok, _} =
               create(
                 other.schema,
                 "location_node",
                 values("location_node", "T1", %{"node_kind" => "address", "address" => "SHARED"})
               )
    end
  end

  describe "criterion 7: types and required fields" do
    test "T-1a: location_type outside the seven values is refused naming the field", %{
      schema: schema
    } do
      assert {:error,
              {:record_payload_invalid,
               [%ValidationFailure{field_path: "/location_type", constraint: "enum"}]}} =
               create(
                 schema,
                 "location_node",
                 values("location_node", "B1", %{"location_type" => "bin"})
               )
    end

    test "T-1b: node_kind outside site | zone | address is refused naming the field", %{
      schema: schema
    } do
      assert {:error,
              {:record_payload_invalid,
               [%ValidationFailure{field_path: "/node_kind", constraint: "enum"}]}} =
               create(
                 schema,
                 "location_node",
                 values("location_node", "B2", %{"node_kind" => "rack"})
               )
    end

    for field <- ~w(code name node_kind active) do
      test "T-1c-#{field}: a missing #{field} is refused naming the field", %{schema: schema} do
        vals = Map.delete(values("location_node", "M1", %{}), unquote(field))

        assert {:error,
                {:record_payload_invalid,
                 [%ValidationFailure{field_path: path, constraint: "required"}]}} =
                 create(schema, "location_node", vals)

        assert path == "/" <> unquote(field)
      end
    end

    test "T-1d: an address is created with each of the seven location_type values", %{
      schema: schema
    } do
      for {lt, i} <- Enum.with_index(@type_values) do
        assert {:ok, _} =
                 create(
                   schema,
                   "location_node",
                   values("location_node", "LT#{i}", %{
                     "node_kind" => "address",
                     "location_type" => lt,
                     "address" => "LT-#{i}"
                   })
                 )
      end
    end
  end

  describe "criterion 8: external_ref and retire" do
    test "X-1a: two rows with both external_ref fields NULL are accepted", %{schema: schema} do
      assert {:ok, %{record: a}} =
               create(schema, "location_node", values("location_node", "N1", %{}))

      assert {:ok, %{record: b}} =
               create(schema, "location_node", values("location_node", "N2", %{}))

      assert a.record_id != b.record_id
    end

    test "X-1b: a duplicate non-NULL pair is a :unique violation on the pair", %{schema: schema} do
      assert {:ok, _} =
               create(schema, "location_node", values("location_node", "P1", ref("1c", "42")))

      assert {:error,
              {:record_payload_invalid,
               [%Violation{rule: :unique, path: ["external_ref_system", "external_ref_id"]}]}} =
               create(schema, "location_node", values("location_node", "P2", ref("1c", "42")))

      assert {:ok, _} =
               create(schema, "location_node", values("location_node", "P3", ref("sap", "42")))
    end

    test "X-1c: a retired location (active false) stays readable; lookup shows false, active? is false",
         %{schema: schema} do
      rec = node!(schema, "RET")
      assert Locations.active?(schema, rec.record_id)

      update!(schema, rec, values("location_node", "RET", %{"active" => false}))

      assert {:ok, %{"active" => false, "entity_type" => "location_node"}} =
               Locations.lookup(schema, rec.record_id)

      refute Locations.active?(schema, rec.record_id)
    end

    test "X-1d: a delete through the generic path is refused as for the other managed types",
         %{schema: schema} do
      rec = node!(schema, "DEL")

      assert {:error, :entity_type_managed} =
               Records.delete_record(
                 %{
                   entity_type: "location_node",
                   record_id: rec.record_id,
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert {:ok, _} = Locations.lookup(schema, rec.record_id)
    end
  end
end
