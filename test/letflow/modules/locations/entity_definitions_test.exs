defmodule Letflow.Modules.Locations.EntityDefinitionsTest do
  @moduledoc """
  GH #3501 / REQ-625 criterion 1 (tests E-1a..E-1d): reads the committed source document
  `priv/modules/locations/entity_definitions/location_node.json` and asserts the exact shape the
  requirement fixes: the ten fields with type, required and queried flags, the two enums, the three
  unique constraints, no `foreign_keys`.

  Pure file reads: no database. `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @dir Path.join([File.cwd!(), "priv", "modules", "locations", "entity_definitions"])

  # {name, type, required, queried}; the order inside the document is not asserted.
  @expected_fields [
    {"code", "string", true, true},
    {"name", "string", true, true},
    {"node_kind", "string", true, true},
    {"parent_id", "string", false, true},
    {"segment", "string", false, true},
    {"address", "string", false, true},
    {"location_type", "enum", false, true},
    {"active", "boolean", true, true},
    {"external_ref_system", "string", false, true},
    {"external_ref_id", "string", false, true}
  ]

  defp doc, do: @dir |> Path.join("location_node.json") |> File.read!() |> Jason.decode!()

  defp field(name), do: Enum.find(doc()["fields"], &(&1["name"] == name))

  test "E-1a: the directory holds exactly location_node.json, with the known keys only" do
    assert File.ls!(@dir) == ["location_node.json"]
    assert doc()["name"] == "location_node"

    assert Enum.sort(Map.keys(doc()) -- ["description"]) ==
             ~w(constraints display_name fields foreign_keys indexes name)
  end

  test "E-1b: exactly the ten fields with exact type, required and queried flags" do
    actual =
      for f <- doc()["fields"] do
        {f["name"], f["type"], Map.get(f, "required", false), Map.get(f, "queried", false)}
      end

    assert Enum.sort(actual) == Enum.sort(@expected_fields)
  end

  test "E-1c: node_kind is a free string (no enum values); location_type keeps its enum" do
    assert field("node_kind")["type"] == "string"
    refute Map.has_key?(field("node_kind"), "enum_values")
    refute field("org_site_id")
    refute field("ancestor_path")
    refute field("depth")

    assert field("location_type")["enum_values"] ==
             ~w(receiving pick ship reject quarantine custody outdoor)
  end

  test "E-1d: three unique constraints (code, address, external_ref pair), the parent foreign key and its index" do
    constraints = doc()["constraints"]
    assert Enum.all?(constraints, &(&1["type"] == "unique"))

    assert constraints |> Enum.map(&{&1["name"], &1["fields"]}) |> Enum.sort() == [
             {"uq_location_node_address", ["address"]},
             {"uq_location_node_code", ["code"]},
             {"uq_location_node_external_ref", ["external_ref_system", "external_ref_id"]}
           ]

    assert doc()["foreign_keys"] == [
             %{
               "name" => "fk_location_node_parent_id",
               "field" => "parent_id",
               "references_entity" => "location_node"
             }
           ]

    assert doc()["indexes"] == [
             %{"name" => "idx_location_node_parent_id", "fields" => ["parent_id"]}
           ]
  end
end
