defmodule Letflow.Modules.Org.ReadApiTest do
  @moduledoc """
  GH #2662 / REQ-506 AC4, AC5 and the hostile-input requirement (spec `test/specs/GH-2662.md`,
  tests R-*, M-*, H-*, T-*): `Letflow.Modules.Org.lookup/2`, `active?/2`, `member?/3` on real
  provisioned tenants with the real installed module. Isolation is by prefix alone.
  """

  use Letflow.DataCase, async: false

  import Letflow.OrgFixture

  alias Letflow.Modules.Org

  @types ["org_legal_entity", "org_site", "org_unit", "org_unit_membership"]

  # Values that are not a uuid; none may raise.
  @non_uuids [nil, 123, "x", "", %{}, %{"a" => 1}, [], :atom, 1.5, "not-a-uuid", <<255>>]

  setup do
    {:ok, installed_tenant!("gh2662-read")}
  end

  defp unit!(schema, code, active \\ true) do
    create!(schema, "org_unit", values("org_unit", code, %{"active" => active}))
  end

  defp membership!(schema, user_id, unit, active \\ true) do
    create!(
      schema,
      "org_unit_membership",
      values("org_unit_membership", nil, %{
        "user_id" => user_id,
        "org_unit_id" => unit.record_id,
        "active" => active
      })
    )
  end

  describe "lookup/2 and active?/2 for each of the four types" do
    for type <- @types do
      test "R-#{type}: lookup returns record_id, entity_type and the field values", %{
        schema: schema
      } do
        type = unquote(type)
        vals = values(type, "RD-1", %{"active" => true})
        rec = create!(schema, type, vals)

        assert {:ok, map} = Org.lookup(schema, rec.record_id)
        assert map["record_id"] == rec.record_id
        assert map["entity_type"] == type

        for {field, value} <- vals do
          assert map[field] == value, "#{type}.#{field}"
        end

        assert Org.active?(schema, rec.record_id) == true
      end

      test "R-#{type}-inactive: an inactive record is found but not active?", %{schema: schema} do
        type = unquote(type)
        rec = create!(schema, type, values(type, "RD-2", %{"active" => false}))

        assert {:ok, %{"active" => false}} = Org.lookup(schema, rec.record_id)
        assert Org.active?(schema, rec.record_id) == false
      end

      test "R-#{type}-deleted: a soft-deleted record is :not_found and not active?", %{
        schema: schema
      } do
        type = unquote(type)
        rec = create!(schema, type, values(type, "RD-3"))
        assert Org.active?(schema, rec.record_id)

        delete!(schema, rec)

        assert {:error, :not_found} = Org.lookup(schema, rec.record_id)
        assert Org.active?(schema, rec.record_id) == false
      end
    end

    test "R-unknown: a well-formed unknown uuid is :not_found and not active?", %{schema: schema} do
      create!(schema, "org_site", values("org_site", "SOME"))
      unknown = Ecto.UUID.generate()

      assert {:error, :not_found} = Org.lookup(schema, unknown)
      assert Org.active?(schema, unknown) == false
    end

    test "R-nonuuid: a non-uuid id never raises", %{schema: schema} do
      for bad <- @non_uuids do
        assert {:error, :not_found} = Org.lookup(schema, bad), inspect(bad)
        assert Org.active?(schema, bad) == false, inspect(bad)
      end
    end

    test "R-nonbinary-prefix: a non-binary prefix is not found, never a raise" do
      assert {:error, :not_found} = Org.lookup(nil, Ecto.UUID.generate())
      assert Org.active?(nil, Ecto.UUID.generate()) == false
      assert Org.member?(nil, "u", Ecto.UUID.generate()) == false
    end
  end

  describe "member?/3 truth table" do
    test "M-01: active membership of an active unit is true", %{schema: schema} do
      unit = unit!(schema, "U-A")
      membership!(schema, "alice", unit)

      assert Org.member?(schema, "alice", unit.record_id) == true
    end

    test "M-02: inactive membership is false", %{schema: schema} do
      unit = unit!(schema, "U-B")
      membership!(schema, "alice", unit, false)

      assert Org.member?(schema, "alice", unit.record_id) == false
    end

    test "M-03: active membership of an inactive unit is false", %{schema: schema} do
      unit = unit!(schema, "U-C", false)
      membership!(schema, "alice", unit)

      assert Org.member?(schema, "alice", unit.record_id) == false
    end

    test "M-04: unknown unit and a deleted unit are false", %{schema: schema} do
      assert Org.member?(schema, "alice", Ecto.UUID.generate()) == false

      unit = unit!(schema, "U-D")
      membership!(schema, "alice", unit)
      assert Org.member?(schema, "alice", unit.record_id)

      delete!(schema, unit)
      assert Org.member?(schema, "alice", unit.record_id) == false
    end

    test "M-05: another user, and a member of a different unit, is false", %{schema: schema} do
      unit = unit!(schema, "U-E")
      other = unit!(schema, "U-F")
      membership!(schema, "alice", unit)

      assert Org.member?(schema, "bob", unit.record_id) == false
      assert Org.member?(schema, "alice", other.record_id) == false
    end

    test "M-06: a deleted membership is false", %{schema: schema} do
      unit = unit!(schema, "U-G")
      membership = membership!(schema, "alice", unit)
      assert Org.member?(schema, "alice", unit.record_id)

      delete!(schema, membership)
      assert Org.member?(schema, "alice", unit.record_id) == false
    end

    test "M-07: a non-uuid org_unit_id and a non-text user_id never raise", %{schema: schema} do
      unit = unit!(schema, "U-H")
      membership!(schema, "alice", unit)

      for bad <- @non_uuids do
        assert Org.member?(schema, "alice", bad) == false, inspect(bad)
      end

      for bad <- [nil, 123, %{}, :alice, ["alice"]] do
        assert Org.member?(schema, bad, unit.record_id) == false, inspect(bad)
      end
    end
  end

  describe "member?/3 with a hostile user_id" do
    test "H-01: NUL, invalid UTF-8, over 256 bytes and empty are false even for a live unit",
         %{schema: schema} do
      unit = unit!(schema, "U-Z")
      membership!(schema, "alice", unit)
      assert Org.member?(schema, "alice", unit.record_id)

      hostile = [
        "alice" <> <<0>>,
        <<0>>,
        <<255>>,
        "alice" <> <<255, 254>>,
        String.duplicate("a", 257),
        String.duplicate("a", 100_000),
        ""
      ]

      for user_id <- hostile do
        assert Org.member?(schema, user_id, unit.record_id) == false,
               inspect(user_id, binaries: :as_binaries, limit: 8)
      end
    end

    test "H-02: a 256-byte user_id is accepted (boundary), 257 is not", %{schema: schema} do
      unit = unit!(schema, "U-Y")
      at_cap = String.duplicate("b", 256)
      membership!(schema, at_cap, unit)

      assert Org.member?(schema, at_cap, unit.record_id) == true
      assert Org.member?(schema, at_cap <> "b", unit.record_id) == false
    end
  end

  describe "tenant isolation" do
    test "T-01: tenant B's prefix never returns tenant A's records", %{schema: schema_a} do
      %{schema: schema_b} = installed_tenant!("gh2662-readb")

      site = create!(schema_a, "org_site", values("org_site", "ISO"))
      unit = unit!(schema_a, "ISO-U")
      membership!(schema_a, "alice", unit)

      # Control: visible in A.
      assert {:ok, _} = Org.lookup(schema_a, site.record_id)
      assert Org.active?(schema_a, site.record_id)
      assert Org.member?(schema_a, "alice", unit.record_id)

      # Invisible through B's prefix.
      assert {:error, :not_found} = Org.lookup(schema_b, site.record_id)
      assert {:error, :not_found} = Org.lookup(schema_b, unit.record_id)
      assert Org.active?(schema_b, site.record_id) == false
      assert Org.member?(schema_b, "alice", unit.record_id) == false

      # Same code in B is an independent record (uniqueness is per tenant).
      b_site = create!(schema_b, "org_site", values("org_site", "ISO"))
      assert b_site.record_id != site.record_id
      assert {:error, :not_found} = Org.lookup(schema_a, b_site.record_id)
    end
  end
end
