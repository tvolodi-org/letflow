defmodule Letflow.Modules.Org.PackDriftTest do
  @moduledoc """
  GH #2661 / REQ-473 AC1 (spec `test/specs/GH-2661.md`, tests P-01..P-04): the drift guard named
  in the header of `priv/modules/org/generate_pack.exs`. `pack.json` is committed output of that
  script; this test re-reads the four source documents and proves the committed pack still says
  exactly what they say: `definition_json` equal to the decoded source, the content-derived
  `entity_definition_id`, and the logical-shape digest.

  Pure file reads plus the pure `Shape.logical_shape_of/1`: no database. `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.Definition.Shape

  @org_dir Path.join([File.cwd!(), "priv", "modules", "org"])
  @types ~w(org_legal_entity org_site org_unit org_unit_membership)

  defp pack, do: @org_dir |> Path.join("pack.json") |> File.read!() |> Jason.decode!()

  defp source(type),
    do:
      @org_dir |> Path.join("entity_definitions/#{type}.json") |> File.read!() |> Jason.decode!()

  defp entry(type), do: Enum.find(pack()["entity_definitions"], &(&1["name"] == type))

  # Same derivation as the generator: a SHA-256 prefix laid out as UUID text.
  defp expected_id(type) do
    h =
      :crypto.hash(:sha256, "letflow-org:" <> type)
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)

    Enum.join(
      [
        binary_part(h, 0, 8),
        binary_part(h, 8, 4),
        binary_part(h, 12, 4),
        binary_part(h, 16, 4),
        binary_part(h, 20, 12)
      ],
      "-"
    )
  end

  # Atom-keyed Definition document from the source JSON (the keys and types the org documents use).
  defp atomise(raw) do
    raw
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> Map.update!(:fields, fn fields ->
      Enum.map(fields, fn f ->
        f = Map.new(f, fn {k, v} -> {String.to_existing_atom(k), v} end)
        Map.update!(f, :type, &String.to_existing_atom/1)
      end)
    end)
    |> Map.update!(:constraints, fn cs ->
      Enum.map(cs, fn c ->
        c = Map.new(c, fn {k, v} -> {String.to_existing_atom(k), v} end)
        Map.update!(c, :type, &String.to_existing_atom/1)
      end)
    end)
  end

  test "P-01: the pack holds exactly the four entity definitions, in the source set, and nothing else" do
    document = pack()

    assert document["pack_id"] == "letflow-org"

    assert document["entity_definitions"] |> Enum.map(& &1["name"]) |> Enum.sort() ==
             Enum.sort(@types)

    assert document["definitions"] == []
    assert document["variable_schemas"] == []
    assert document["service_catalog_entries"] == []
    assert document["manifest"] == %{"required_roles" => []}
  end

  test "P-02: every packed definition_json equals the decoded source document" do
    for type <- @types do
      entry = entry(type)

      assert entry["definition_json"] == source(type),
             "#{type}: pack.json drifted from its source"

      assert entry["display_name"] == source(type)["display_name"]
    end
  end

  test "P-03: every entity_definition_id is the content-derived id, so regeneration is stable" do
    for type <- @types do
      assert entry(type)["entity_definition_id"] == expected_id(type)
    end

    ids = Enum.map(pack()["entity_definitions"], & &1["entity_definition_id"])
    assert ids == Enum.uniq(ids)
  end

  test "P-04: every logical_shape_version is the digest of the source's logical shape" do
    for type <- @types do
      digest =
        type |> source() |> atomise() |> Shape.logical_shape_of() |> Base.encode16(case: :lower)

      assert entry(type)["logical_shape_version"] == digest, "#{type}: shape digest drifted"
    end
  end
end
