defmodule Letflow.Modules.Codes.EntityDefinitionsTest do
  @moduledoc """
  GH #3588 / REQ-648 criterion 1 (D-01..D-03): reads the committed source documents under
  `priv/modules/codes/entity_definitions/` and the pack, and asserts the exact shape the requirement
  fixes. Pure file reads: no database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @pack_dir Path.join([File.cwd!(), "priv", "modules", "codes"])
  @dir Path.join(@pack_dir, "entity_definitions")

  # {name, type, required, queried}
  @expected %{
    "code_tag" => [
      {"value", "string", true, true},
      {"kind", "enum", true, true},
      {"status", "enum", true, true}
    ],
    "code_assignment" => [
      {"code_id", "string", true, true},
      {"target_type", "string", true, true},
      {"target_id", "string", true, true},
      {"assigned_at", "datetime", true, true},
      {"assigned_by", "string", true, true},
      {"released_at", "datetime", false, true},
      {"released_by", "string", false, true}
    ],
    "code_value_change" => [
      {"code_id", "string", true, true},
      {"old_value", "string", true, true},
      {"new_value", "string", true, true},
      {"changed_at", "datetime", true, true},
      {"changed_by", "string", true, true}
    ]
  }

  defp doc(type), do: @dir |> Path.join("#{type}.json") |> File.read!() |> Jason.decode!()

  test "D-01: exactly the three files; fields, types, flags, enums, keys and indexes as fixed" do
    assert File.ls!(@dir) |> Enum.sort() ==
             ["code_assignment.json", "code_tag.json", "code_value_change.json"]

    for {type, expected} <- @expected do
      d = doc(type)
      assert d["name"] == type

      actual =
        for f <- d["fields"],
            do:
              {f["name"], f["type"], Map.get(f, "required", false), Map.get(f, "queried", false)}

      assert Enum.sort(actual) == Enum.sort(expected), type
      assert Enum.all?(d["fields"], &(&1["queried"] == true)), "#{type}: every field is queried"
    end

    tag = doc("code_tag")
    field = fn n -> Enum.find(tag["fields"], &(&1["name"] == n)) end
    assert field.("kind")["enum_values"] == ["barcode", "qr", "epc", "tid"]
    assert field.("status")["enum_values"] == ["not_assigned", "assigned", "retired"]
    refute Map.has_key?(tag, "foreign_keys")
    refute Map.has_key?(tag, "indexes")

    assert doc("code_assignment")["foreign_keys"] == [
             %{
               "name" => "fk_code_assignment_code_id",
               "field" => "code_id",
               "references_entity" => "code_tag"
             }
           ]

    assert doc("code_assignment")["indexes"] == [
             %{"name" => "idx_code_assignment_code_id", "fields" => ["code_id"]}
           ]

    assert doc("code_value_change")["foreign_keys"] == [
             %{
               "name" => "fk_code_value_change_code_id",
               "field" => "code_id",
               "references_entity" => "code_tag"
             }
           ]

    assert doc("code_value_change")["indexes"] == [
             %{"name" => "idx_code_value_change_code_id", "fields" => ["code_id"]}
           ]
  end

  test "D-02: the value of code_tag is unique through uq_code_tag_value, nothing else is" do
    assert doc("code_tag")["constraints"] == [
             %{"name" => "uq_code_tag_value", "type" => "unique", "fields" => ["value"]}
           ]

    refute Map.has_key?(doc("code_assignment"), "constraints")
    refute Map.has_key?(doc("code_value_change"), "constraints")
  end

  test "D-03: code_tag comes first in pack.json" do
    pack = @pack_dir |> Path.join("pack.json") |> File.read!() |> Jason.decode!()

    assert Enum.map(pack["entity_definitions"], & &1["name"]) ==
             ["code_tag", "code_assignment", "code_value_change"]
  end
end
