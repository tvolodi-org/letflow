defmodule Letflow.Modules.Org.EntityDefinitionsTest do
  @moduledoc """
  GH #2661 / REQ-473 AC1 (spec `test/specs/GH-2661.md`, tests D-01..D-06) and the fixture-hygiene
  AC (#2584, H-01, H-02): reads the committed source documents under
  `priv/modules/org/entity_definitions/` and asserts the exact shape the issue fixes: four
  types, exact fields, types, required and queried flags, the unique constraints, no
  `foreign_keys`, no `org_position`, no external_ref on the membership.

  Pure file reads: no database. `async: true`.
  """

  use ExUnit.Case, async: true

  @dir Path.join([File.cwd!(), "priv", "modules", "org", "entity_definitions"])

  @types ~w(org_legal_entity org_site org_unit org_unit_membership)
  @masters ~w(org_legal_entity org_site org_unit)

  # {name, type, required, queried}; the order inside a document is not asserted.
  @external_ref [
    {"external_ref_system", "string", false, true},
    {"external_ref_id", "string", false, true}
  ]
  @active {"active", "boolean", true, true}

  @expected_fields %{
    "org_legal_entity" =>
      [
        {"code", "string", true, true},
        {"name", "string", true, false},
        {"bin", "string", true, false},
        @active
      ] ++ @external_ref,
    "org_site" =>
      [
        {"code", "string", true, true},
        {"name", "string", true, false},
        {"legal_entity_id", "string", true, true},
        @active
      ] ++ @external_ref,
    "org_unit" =>
      [
        {"code", "string", true, true},
        {"name", "string", true, false},
        {"legal_entity_id", "string", true, false},
        {"site_id", "string", true, false},
        {"parent", "string", false, false},
        @active
      ] ++ @external_ref,
    "org_unit_membership" => [
      {"user_id", "string", true, true},
      {"org_unit_id", "string", true, true},
      @active
    ]
  }

  @expected_constraints %{
    "org_legal_entity" => [
      {"uq_org_legal_entity_code", ["code"]},
      {"uq_org_legal_entity_external_ref", ["external_ref_system", "external_ref_id"]}
    ],
    "org_site" => [
      {"uq_org_site_code", ["code"]},
      {"uq_org_site_external_ref", ["external_ref_system", "external_ref_id"]}
    ],
    "org_unit" => [
      {"uq_org_unit_code", ["code"]},
      {"uq_org_unit_external_ref", ["external_ref_system", "external_ref_id"]}
    ],
    "org_unit_membership" => [{"uq_org_unit_membership", ["user_id", "org_unit_id"]}]
  }

  defp read!(type), do: @dir |> Path.join("#{type}.json") |> File.read!() |> Jason.decode!()

  defp field_tuples(doc) do
    for f <- doc["fields"] do
      {f["name"], f["type"], Map.get(f, "required", false), Map.get(f, "queried", false)}
    end
  end

  describe "AC1: the entity-definition source documents" do
    test "D-01: the directory holds exactly the four type files and no org_position" do
      files = @dir |> File.ls!() |> Enum.sort()

      assert files == Enum.map(Enum.sort(@types), &"#{&1}.json")
      refute File.exists?(Path.join(@dir, "org_position.json"))
    end

    test "D-02: each document's name matches its file and carries nothing but the known keys" do
      for type <- @types do
        doc = read!(type)
        assert doc["name"] == type

        assert Enum.sort(Map.keys(doc) -- ["description"]) ==
                 ~w(constraints display_name fields name)
      end
    end

    test "D-03: each type has exactly the expected fields with exact type, required and queried flags" do
      for type <- @types do
        actual = type |> read!() |> field_tuples() |> Enum.sort()
        assert actual == Enum.sort(@expected_fields[type]), "#{type}: #{inspect(actual)}"
      end
    end

    test "D-04: every field name is unique within its type and every type has an active flag" do
      for type <- @types do
        names = type |> read!() |> Map.fetch!("fields") |> Enum.map(& &1["name"])
        assert names == Enum.uniq(names)
        assert "active" in names
      end
    end

    test "D-05: the unique constraints are exactly the expected ones (code per master, pair, external_ref pair)" do
      for type <- @types do
        constraints = read!(type)["constraints"]

        assert Enum.all?(constraints, &(&1["type"] == "unique"))

        actual = constraints |> Enum.map(&{&1["name"], &1["fields"]}) |> Enum.sort()
        assert actual == Enum.sort(@expected_constraints[type]), "#{type}: #{inspect(actual)}"
      end
    end

    test "D-06: no type declares foreign_keys or indexes, and the membership has no external_ref" do
      for type <- @types do
        doc = read!(type)
        refute Map.has_key?(doc, "foreign_keys"), "#{type} declares foreign_keys"
        refute Map.has_key?(doc, "indexes"), "#{type} declares indexes"
      end

      membership_fields =
        "org_unit_membership" |> read!() |> Map.fetch!("fields") |> Enum.map(& &1["name"])

      refute "external_ref_system" in membership_fields
      refute "external_ref_id" in membership_fields

      for type <- @masters do
        names = type |> read!() |> Map.fetch!("fields") |> Enum.map(& &1["name"])
        assert "external_ref_system" in names and "external_ref_id" in names
      end
    end
  end

  describe "#2584 fixture hygiene: the test fixtures no longer claim the real foundation names" do
    @real_names ~w(org_legal_entity org_site org_unit org_unit_membership catalog_item catalog_uom)

    for {label, parts} <- [
          {"fixture_managed.ex",
           ["test", "support", "modules", "fixture_managed", "fixture_managed.ex"]},
          {"managed_foundation.json", ["priv", "module_fixtures", "managed_foundation.json"]}
        ] do
      test "H-0#{if label == "fixture_managed.ex", do: 1, else: 2}: #{label} contains none of the six real names" do
        source = File.read!(Path.join([File.cwd!() | unquote(parts)]))

        assert source != ""

        for name <- @real_names do
          refute source =~ name, "#{unquote(label)} still mentions #{name}"
        end
      end
    end
  end
end
