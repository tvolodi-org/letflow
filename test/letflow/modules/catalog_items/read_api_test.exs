Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.ReadApiTest do
  @moduledoc """
  GH #2664 / REQ-507 AC2, AC4 and the hostile-input requirement (spec `test/specs/GH-2664.md`,
  tests R-*, V-*, H-*, T-*): `Letflow.Modules.CatalogItems.lookup/2`, `active?/2` and
  `item_uom_valid?/3` on real provisioned tenants with the real installed module. Isolation is
  by prefix alone.
  """

  use Letflow.DataCase, async: false

  import Letflow.CatalogItemsFixture

  alias Letflow.Modules.CatalogItems

  @types ["catalog_uom", "catalog_item", "catalog_counterparty"]

  # Values that are not a uuid; none may raise.
  @non_uuids [nil, 123, "x", "", %{}, %{"a" => 1}, [], :atom, 1.5, "not-a-uuid", <<255>>]

  setup do
    {:ok, installed_tenant!("gh2664-read")}
  end

  # An active uom and an active item whose base unit is it.
  defp pair!(schema, code) do
    uom = uom!(schema, "U-#{code}")
    item = item!(schema, "I-#{code}", uom.record_id)
    {item, uom}
  end

  describe "lookup/2 and active?/2 for each of the three types" do
    for type <- @types do
      test "R-#{type}: lookup returns record_id, entity_type and the field values", %{
        schema: schema
      } do
        type = unquote(type)

        vals =
          values(type, "RD-1", %{
            "active" => true,
            "external_ref_system" => "1c",
            "external_ref_id" => "7"
          })

        rec = create!(schema, type, vals)

        assert {:ok, map} = CatalogItems.lookup(schema, rec.record_id)
        assert map["record_id"] == rec.record_id
        assert map["entity_type"] == type

        for {field, value} <- vals do
          assert map[field] == value, "#{type}.#{field}"
        end

        assert CatalogItems.active?(schema, rec.record_id) == true
      end

      test "R-#{type}-inactive: an inactive record is found but not active?", %{schema: schema} do
        type = unquote(type)
        rec = create!(schema, type, values(type, "RD-2", %{"active" => false}))

        assert {:ok, %{"active" => false}} = CatalogItems.lookup(schema, rec.record_id)
        assert CatalogItems.active?(schema, rec.record_id) == false
      end

      test "R-#{type}-deleted: a soft-deleted record is :not_found and not active?", %{
        schema: schema
      } do
        type = unquote(type)
        rec = create!(schema, type, values(type, "RD-3", %{}))
        assert CatalogItems.active?(schema, rec.record_id)

        delete!(schema, rec)

        assert {:error, :not_found} = CatalogItems.lookup(schema, rec.record_id)
        assert CatalogItems.active?(schema, rec.record_id) == false
      end

      test "R-#{type}-uppercase: an uppercase uuid finds the record (cast to canonical)", %{
        schema: schema
      } do
        type = unquote(type)
        rec = create!(schema, type, values(type, "RD-4", %{}))

        assert {:ok, %{"code" => "RD-4"}} =
                 CatalogItems.lookup(schema, String.upcase(rec.record_id))

        assert CatalogItems.active?(schema, String.upcase(rec.record_id)) == true
      end
    end

    test "R-unknown: a well-formed unknown uuid is :not_found and not active?", %{schema: schema} do
      uom!(schema, "SOME")
      unknown = Ecto.UUID.generate()

      assert {:error, :not_found} = CatalogItems.lookup(schema, unknown)
      assert CatalogItems.active?(schema, unknown) == false
    end

    test "R-nonuuid: a non-uuid id never raises", %{schema: schema} do
      for bad <- @non_uuids do
        assert {:error, :not_found} = CatalogItems.lookup(schema, bad), inspect(bad)
        assert CatalogItems.active?(schema, bad) == false, inspect(bad)
      end
    end

    test "R-rawbinary: a raw 16-byte binary is cast like Ecto.UUID.cast/1 (documented)",
         %{schema: schema} do
      rec = uom!(schema, "RAW")
      raw = Ecto.UUID.dump!(rec.record_id)
      assert byte_size(raw) == 16

      # `Ecto.UUID.cast/1` accepts the 16 raw bytes, so the real record is found.
      assert {:ok, %{"code" => "RAW"}} = CatalogItems.lookup(schema, raw)

      # A 16-byte binary of an unknown uuid is not found; a 15- or 17-byte one is not a uuid.
      unknown_raw = Ecto.UUID.dump!(Ecto.UUID.generate())
      assert {:error, :not_found} = CatalogItems.lookup(schema, unknown_raw)
      assert {:error, :not_found} = CatalogItems.lookup(schema, binary_part(raw, 0, 15))
      assert {:error, :not_found} = CatalogItems.lookup(schema, raw <> <<0>>)
    end

    test "R-nonbinary-prefix: a non-binary prefix is not found, never a raise" do
      id = Ecto.UUID.generate()

      for bad <- [nil, 123, :tenant_x, %{}, [], 1.5] do
        assert {:error, :not_found} = CatalogItems.lookup(bad, id), inspect(bad)
        assert CatalogItems.active?(bad, id) == false, inspect(bad)
        assert CatalogItems.item_uom_valid?(bad, id, id) == false, inspect(bad)
      end
    end

    test "H-01: hostile id strings (NUL suffix, 100k bytes, invalid UTF-8) never raise",
         %{schema: schema} do
      rec = uom!(schema, "HOST")
      assert CatalogItems.active?(schema, rec.record_id)

      hostile = [
        rec.record_id <> <<0>>,
        <<0>> <> rec.record_id,
        rec.record_id <> <<255, 254>>,
        String.duplicate("a", 100_000),
        String.duplicate("0", 36),
        " " <> rec.record_id
      ]

      for bad <- hostile do
        label = inspect(bad, binaries: :as_binaries, limit: 8)
        assert {:error, :not_found} = CatalogItems.lookup(schema, bad), label
        assert CatalogItems.active?(schema, bad) == false, label
        assert CatalogItems.item_uom_valid?(schema, bad, rec.record_id) == false, label
        assert CatalogItems.item_uom_valid?(schema, rec.record_id, bad) == false, label
      end
    end

    test "H-02: a well-formed but unprovisioned tenant prefix raises undefined_table (documented)" do
      prefix = "tenant_" <> String.duplicate("0", 32)

      assert_raise Postgrex.Error, ~r/undefined_table|does not exist/, fn ->
        CatalogItems.lookup(prefix, Ecto.UUID.generate())
      end
    end
  end

  describe "item_uom_valid?/3 truth table" do
    test "V-01: the base unit of an active item with an active unit is true", %{schema: schema} do
      {item, uom} = pair!(schema, "V1")

      assert CatalogItems.item_uom_valid?(schema, item.record_id, uom.record_id) == true
    end

    test "V-02: an inactive item is false (the unit is active and the base unit)",
         %{schema: schema} do
      uom = uom!(schema, "U-V2")
      item = item!(schema, "I-V2", uom.record_id, %{"active" => false})

      assert {:ok, %{"base_uom_id" => base}} = CatalogItems.lookup(schema, item.record_id)
      assert base == uom.record_id
      assert CatalogItems.item_uom_valid?(schema, item.record_id, uom.record_id) == false
    end

    test "V-03: an inactive unit is false (the item is active and names it)", %{schema: schema} do
      uom = uom!(schema, "U-V3", %{"active" => false})
      item = item!(schema, "I-V3", uom.record_id)

      assert CatalogItems.item_uom_valid?(schema, item.record_id, uom.record_id) == false
    end

    test "V-04: an unknown item is false, an unknown unit is false", %{schema: schema} do
      {item, uom} = pair!(schema, "V4")

      assert CatalogItems.item_uom_valid?(schema, Ecto.UUID.generate(), uom.record_id) == false
      assert CatalogItems.item_uom_valid?(schema, item.record_id, Ecto.UUID.generate()) == false
    end

    test "V-05: an unknown unit named as base_uom_id (no reference check) is false",
         %{schema: schema} do
      ghost = Ecto.UUID.generate()
      item = item!(schema, "I-V5", ghost, %{})

      # The write is accepted (declarative string, no foreign key); the read says false.
      assert {:ok, %{"base_uom_id" => ^ghost}} = CatalogItems.lookup(schema, item.record_id)
      assert CatalogItems.item_uom_valid?(schema, item.record_id, ghost) == false
    end

    test "V-06: a non-uuid item id or unit id is false, never a raise", %{schema: schema} do
      {item, uom} = pair!(schema, "V6")

      for bad <- @non_uuids do
        assert CatalogItems.item_uom_valid?(schema, bad, uom.record_id) == false, inspect(bad)
        assert CatalogItems.item_uom_valid?(schema, item.record_id, bad) == false, inspect(bad)
        assert CatalogItems.item_uom_valid?(schema, bad, bad) == false, inspect(bad)
      end
    end

    test "V-07: a different active unit is false (only the base unit is allowed)",
         %{schema: schema} do
      {item, base} = pair!(schema, "V7")
      other = uom!(schema, "U-V7-other", %{})

      assert CatalogItems.item_uom_valid?(schema, item.record_id, base.record_id) == true
      assert CatalogItems.item_uom_valid?(schema, item.record_id, other.record_id) == false
    end

    test "V-08: ids of the wrong type: unit as item, item as unit, both swapped", %{
      schema: schema
    } do
      {item, uom} = pair!(schema, "V8")

      assert CatalogItems.item_uom_valid?(schema, uom.record_id, item.record_id) == false
      assert CatalogItems.item_uom_valid?(schema, uom.record_id, uom.record_id) == false
      assert CatalogItems.item_uom_valid?(schema, item.record_id, item.record_id) == false
    end

    test "V-09: a soft-deleted unit is false; a soft-deleted item is false", %{schema: schema} do
      {item, uom} = pair!(schema, "V9")
      assert CatalogItems.item_uom_valid?(schema, item.record_id, uom.record_id)

      delete!(schema, uom)
      assert CatalogItems.item_uom_valid?(schema, item.record_id, uom.record_id) == false

      {item2, uom2} = pair!(schema, "V9b")
      assert CatalogItems.item_uom_valid?(schema, item2.record_id, uom2.record_id)

      delete!(schema, item2)
      assert CatalogItems.item_uom_valid?(schema, item2.record_id, uom2.record_id) == false
    end

    test "V-10: an uppercase uuid for the real base unit and item is true (cast, as implemented)",
         %{schema: schema} do
      {item, uom} = pair!(schema, "V10")

      assert CatalogItems.item_uom_valid?(
               schema,
               String.upcase(item.record_id),
               String.upcase(uom.record_id)
             ) == true
    end

    test "V-11: a stored non-canonical (uppercase) base_uom_id fails closed (runbook limit 7)",
         %{schema: schema} do
      uom = uom!(schema, "U-V11")
      item = item!(schema, "I-V11", String.upcase(uom.record_id))

      assert {:ok, %{"base_uom_id" => stored}} = CatalogItems.lookup(schema, item.record_id)
      assert stored == String.upcase(uom.record_id)

      assert CatalogItems.item_uom_valid?(schema, item.record_id, uom.record_id) == false

      assert CatalogItems.item_uom_valid?(schema, item.record_id, String.upcase(uom.record_id)) ==
               false
    end
  end

  describe "tenant isolation" do
    test "T-01: tenant B prefix never returns tenant A records", %{schema: schema_a} do
      %{schema: schema_b} = installed_tenant!("gh2664-readb")

      {item, uom} = pair!(schema_a, "ISO")

      # Control: visible in A.
      assert {:ok, _} = CatalogItems.lookup(schema_a, item.record_id)
      assert {:ok, _} = CatalogItems.lookup(schema_a, uom.record_id)
      assert CatalogItems.active?(schema_a, item.record_id)
      assert CatalogItems.item_uom_valid?(schema_a, item.record_id, uom.record_id)

      # Invisible through B prefix.
      assert {:error, :not_found} = CatalogItems.lookup(schema_b, item.record_id)
      assert {:error, :not_found} = CatalogItems.lookup(schema_b, uom.record_id)
      assert CatalogItems.active?(schema_b, item.record_id) == false
      assert CatalogItems.active?(schema_b, uom.record_id) == false
      assert CatalogItems.item_uom_valid?(schema_b, item.record_id, uom.record_id) == false

      # Same code in B is an independent record (uniqueness is per tenant).
      b_uom = uom!(schema_b, "U-ISO")
      assert b_uom.record_id != uom.record_id
      assert {:error, :not_found} = CatalogItems.lookup(schema_a, b_uom.record_id)
    end

    test "T-02: a B item naming A unit id is not valid in B (the unit is not in B)",
         %{schema: schema_a} do
      %{schema: schema_b} = installed_tenant!("gh2664-readc")

      a_uom = uom!(schema_a, "U-A")
      b_item = item!(schema_b, "I-B", a_uom.record_id)

      # The write is accepted (no reference check); B cannot see A unit, so it is false in B.
      assert {:ok, %{"base_uom_id" => base}} = CatalogItems.lookup(schema_b, b_item.record_id)
      assert base == a_uom.record_id
      assert CatalogItems.active?(schema_b, b_item.record_id) == true
      assert CatalogItems.item_uom_valid?(schema_b, b_item.record_id, a_uom.record_id) == false

      # Control: the same unit id is valid for an A item in A.
      a_item = item!(schema_a, "I-A", a_uom.record_id)
      assert CatalogItems.item_uom_valid?(schema_a, a_item.record_id, a_uom.record_id) == true
    end
  end
end
