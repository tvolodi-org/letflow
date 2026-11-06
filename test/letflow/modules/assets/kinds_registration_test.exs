defmodule Letflow.Modules.Assets.KindsRegistrationTest do
  @moduledoc """
  GH #3889 / REQ-753 (assets C11): the manifest, document types and pack of the change, hand over and
  write off documents. Reads the manifest and the committed pack only.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Assets

  @pack Path.join([File.cwd!(), "priv", "modules", "assets", "pack.json"])
  @kinds ~w(change handover writeoff)

  defp pack, do: @pack |> File.read!() |> Jason.decode!()

  defp definition(name),
    do:
      pack()["entity_definitions"]
      |> Enum.find(&(&1["name"] == name))
      |> Map.fetch!("definition_json")

  defp field_names(name), do: definition(name)["fields"] |> Enum.map(& &1["name"])

  test "R1 the version is above 0.6.0, six types are managed and scoped by org_unit_id" do
    m = Assets.manifest()
    assert Version.compare(m.version, "0.6.0") == :gt

    for k <- @kinds, type <- ["assets_#{k}", "assets_#{k}_line"] do
      assert type in m.manages_entity_types
      assert m.scope_declarations[type] == {:column, "org_unit_id"}
    end

    # part 1: the post handler still writes only the mark (the card sync is part 2)
    handler = Enum.find(m.write_handlers, &(&1.name == "post_document"))
    assert handler.targets == ["assets_posting_mark"]
  end

  test "R2 the document types: ACH, AHO, AWO, yearly, pad 6, no legal entity" do
    types = Map.new(Assets.document_types(), &{&1.key, &1})

    for {k, prefix} <- [{"change", "ACH"}, {"handover", "AHO"}, {"writeoff", "AWO"}] do
      t = types["assets_#{k}"]

      assert {t.owner_module, t.number_prefix, t.number_pad, t.numbering_scope} ==
               {"assets", prefix, 6, :year}

      refute t.legal_entity_required
    end
  end

  test "R3 three process definitions, one HUMAN_TASK post each, and the exact field sets" do
    defs = pack()["definitions"] |> Map.new(&{&1["process_key"], &1})

    for k <- @kinds do
      tasks =
        Enum.filter(defs["assets_#{k}"]["graph"]["nodes"], &(&1["node_type"] == "HUMAN_TASK"))

      assert [%{"id" => "post", "attributes" => attrs}] = tasks
      refute Map.has_key?(attrs, "assignee")
      assert [%{"module" => "assets", "handler" => "post_document"}] = attrs["module_writes"]

      line = definition("assets_#{k}_line")

      assert Enum.map(line["fields"], & &1["name"]) ==
               ~w(header_id org_unit_id line_no asset_id quantity)

      header_type = "assets_#{k}"

      assert [%{"field" => "header_id", "references_entity" => ^header_type}] =
               line["foreign_keys"]
    end

    assert field_names("assets_change") ==
             ~w(document_id event_time org_unit_id location_id from_material_responsible_id from_actual_user_id to_material_responsible_id to_actual_user_id note)

    assert field_names("assets_handover") ==
             ~w(document_id event_time org_unit_id from_location_id from_material_responsible_id from_actual_user_id to_org_unit_id to_location_id to_material_responsible_id to_actual_user_id note)

    assert field_names("assets_writeoff") ==
             ~w(document_id event_time org_unit_id location_id material_responsible_id actual_user_id reason_code reason_text note)

    reason = Enum.find(definition("assets_writeoff")["fields"], &(&1["name"] == "reason_code"))
    assert reason["enum_values"] == ~w(disposed lost broken expired other)
  end

  test "R4 no price, value, cost, amount or currency field on the six types" do
    for k <- @kinds, type <- ["assets_#{k}", "assets_#{k}_line"] do
      refute Enum.any?(
               field_names(type),
               &Regex.match?(~r/price|value|cost|amount|currency/, &1)
             ),
             type
    end
  end
end
