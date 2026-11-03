defmodule Letflow.Modules.CatalogItems.EntityDefinitionsTest do
  @moduledoc """
  GH #2663 / REQ-474 AC1 (spec `test/specs/GH-2663.md`, tests D-01..D-06) and the fixture-hygiene
  AC (H-01, H-02): reads the committed source documents under
  `priv/modules/catalog_items/entity_definitions/` and asserts the exact shape the issue fixes:
  four types, exact fields, types, required and queried flags, the enum values, the unique
  constraints (code and the external_ref pair), `catalog_lot` as the only type with a `foreign_keys` entry (GH #3593 /
  REQ-647, D-066), no decimal field.

  Pure file reads: no database. `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @dir Path.join([File.cwd!(), "priv", "modules", "catalog_items", "entity_definitions"])

  @types ~w(catalog_counterparty catalog_item catalog_lot catalog_uom)

  # {name, type, required, queried}; the order inside a document is not asserted.
  @external_ref [
    {"external_ref_system", "string", false, true},
    {"external_ref_id", "string", false, true}
  ]
  @active {"active", "boolean", true, true}

  @expected_fields %{
    "catalog_uom" =>
      [
        {"code", "string", true, true},
        {"name", "string", true, false},
        @active
      ] ++ @external_ref,
    "catalog_item" =>
      [
        {"code", "string", true, true},
        {"name", "string", true, false},
        {"base_uom_id", "string", true, true},
        {"kind", "enum", true, true},
        @active
      ] ++ @external_ref,
    "catalog_counterparty" =>
      [
        {"code", "string", true, true},
        {"name", "string", true, false},
        {"kind", "enum", true, true},
        {"tax_id", "string", false, true},
        @active
      ] ++ @external_ref,
    "catalog_lot" =>
      [
        {"item_id", "string", true, true},
        {"code", "string", true, true},
        {"producer", "string", false, true},
        {"mark", "string", false, true},
        {"expiry_date", "date", false, true},
        @active
      ] ++ @external_ref
  }

  @expected_constraints %{
    "catalog_uom" => [
      {"uq_catalog_uom_code", ["code"]},
      {"uq_catalog_uom_external_ref", ["external_ref_system", "external_ref_id"]}
    ],
    "catalog_item" => [
      {"uq_catalog_item_code", ["code"]},
      {"uq_catalog_item_external_ref", ["external_ref_system", "external_ref_id"]}
    ],
    "catalog_counterparty" => [
      {"uq_catalog_counterparty_code", ["code"]},
      {"uq_catalog_counterparty_external_ref", ["external_ref_system", "external_ref_id"]}
    ],
    "catalog_lot" => [
      {"uq_catalog_lot_item_id_code", ["item_id", "code"]},
      {"uq_catalog_lot_external_ref", ["external_ref_system", "external_ref_id"]}
    ]
  }

  defp read!(type), do: @dir |> Path.join("#{type}.json") |> File.read!() |> Jason.decode!()

  defp field_tuples(doc) do
    for f <- doc["fields"] do
      {f["name"], f["type"], Map.get(f, "required", false), Map.get(f, "queried", false)}
    end
  end

  describe "AC1: the entity-definition source documents" do
    test "D-01: the directory holds exactly the four type files" do
      assert @dir |> File.ls!() |> Enum.sort() == Enum.map(@types, &"#{&1}.json")
    end

    test "D-02: each document's name matches its file and carries nothing but the known keys" do
      for type <- @types do
        doc = read!(type)
        assert doc["name"] == type

        expected =
          if type == "catalog_lot",
            do: ~w(constraints display_name fields foreign_keys name),
            else: ~w(constraints display_name fields name)

        assert Enum.sort(Map.keys(doc) -- ["description"]) == expected
      end
    end

    test "D-03: each type has exactly the expected fields with exact type, required and queried flags" do
      for type <- @types do
        actual = type |> read!() |> field_tuples() |> Enum.sort()
        assert actual == Enum.sort(@expected_fields[type]), "#{type}: #{inspect(actual)}"
      end
    end

    test "D-04: field names are unique, every type has an active flag, kind is the material/service enum" do
      for type <- @types do
        names = type |> read!() |> Map.fetch!("fields") |> Enum.map(& &1["name"])
        assert names == Enum.uniq(names)
        assert "active" in names
      end

      kind = read!("catalog_item")["fields"] |> Enum.find(&(&1["name"] == "kind"))
      assert kind["type"] == "enum"
      assert kind["enum_values"] == ["material", "service"]

      supplier_kind =
        read!("catalog_counterparty")["fields"] |> Enum.find(&(&1["name"] == "kind"))

      assert supplier_kind["type"] == "enum"
      assert supplier_kind["enum_values"] == ["supplier", "contractor"]
    end

    test "D-05: the unique constraints are exactly code and the external_ref pair, per type" do
      for type <- @types do
        constraints = read!(type)["constraints"]

        assert Enum.all?(constraints, &(&1["type"] == "unique"))

        actual = constraints |> Enum.map(&{&1["name"], &1["fields"]}) |> Enum.sort()
        assert actual == Enum.sort(@expected_constraints[type]), "#{type}: #{inspect(actual)}"
      end
    end

    test "D-06: foreign_keys only on catalog_lot, no indexes, no decimal field (scale and conversion are REQ-504)" do
      for type <- @types do
        doc = read!(type)

        if type != "catalog_lot",
          do: refute(Map.has_key?(doc, "foreign_keys"), "#{type} declares foreign_keys")

        refute Map.has_key?(doc, "indexes"), "#{type} declares indexes"
        refute Enum.any?(doc["fields"], &(&1["type"] == "decimal")), "#{type} has a decimal"
      end
    end
  end

  describe "GH #3593 / REQ-647: catalog_lot" do
    test "D-lot-fields: the fields are in the documented order" do
      names = read!("catalog_lot")["fields"] |> Enum.map(& &1["name"])

      assert names ==
               ~w(item_id code producer mark expiry_date active external_ref_system external_ref_id)
    end

    test "D-lot-fk: exactly one real foreign key, item_id to catalog_item" do
      assert read!("catalog_lot")["foreign_keys"] == [
               %{
                 "name" => "fk_catalog_lot_item_id",
                 "field" => "item_id",
                 "references_entity" => "catalog_item"
               }
             ]
    end

    test "D-lot-no-indexes: no separate indexes entry (the unique index leads with item_id)" do
      refute Map.has_key?(read!("catalog_lot"), "indexes")
    end

    test "D-pack-order: catalog_item comes before catalog_lot in pack.json" do
      pack = Path.join([File.cwd!(), "priv", "modules", "catalog_items", "pack.json"])
      names = pack |> File.read!() |> Jason.decode!() |> pack_type_names()

      assert Enum.find_index(names, &(&1 == "catalog_item")) <
               Enum.find_index(names, &(&1 == "catalog_lot"))
    end

    defp pack_type_names(doc) do
      for d <- doc["entity_definitions"], do: d["name"] || get_in(d, ["definition_json", "name"])
    end
  end

  describe "fixture hygiene: the test fixtures do not claim the real catalog names" do
    @real_names ~w(catalog_item catalog_uom catalog_counterparty catalog_lot)

    for {label, id, parts} <- [
          {"fixture_managed.ex", 1,
           ["test", "support", "modules", "fixture_managed", "fixture_managed.ex"]},
          {"managed_foundation.json", 2, ["priv", "module_fixtures", "managed_foundation.json"]}
        ] do
      test "H-0#{id}: #{label} contains none of the real catalog names" do
        source = File.read!(Path.join([File.cwd!() | unquote(parts)]))

        assert source != ""

        for name <- @real_names do
          refute source =~ name, "#{unquote(label)} still mentions #{name}"
        end
      end
    end
  end
end
