defmodule Letflow.Modules.Assets.PackDriftTest do
  @moduledoc """
  GH #3894 / REQ-748 criterion 1 (tests P-01..P-04): the drift guard named
  in the header of `priv/modules/assets/generate_pack.exs`. `pack.json` is committed output of that
  script; this test re-reads the source document and proves the committed pack still says
  exactly what they say: `definition_json` equal to the decoded source, the content-derived
  `entity_definition_id`, and the logical-shape digest.

  Pure file reads plus the pure `Shape.logical_shape_of/1`: no database. `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Entities.Definition.Shape

  @dir Path.join([File.cwd!(), "priv", "modules", "assets"])
  @types ~w(assets_card assets_commission assets_commission_line assets_posting_mark)

  defp pack, do: @dir |> Path.join("pack.json") |> File.read!() |> Jason.decode!()

  defp source(type),
    do: @dir |> Path.join("entity_definitions/#{type}.json") |> File.read!() |> Jason.decode!()

  defp entry(type), do: Enum.find(pack()["entity_definitions"], &(&1["name"] == type))

  # Same derivation as the generator: a SHA-256 prefix laid out as UUID text.
  defp expected_id(type) do
    h =
      :crypto.hash(:sha256, "letflow-assets:" <> type)
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

  # Atomises the string-keyed maps of an optional list key; a constraint `type` becomes an atom.
  defp atomise_list(doc, key) do
    case Map.fetch(doc, key) do
      {:ok, items} ->
        Map.put(
          doc,
          key,
          Enum.map(items, fn item ->
            item = Map.new(item, fn {k, v} -> {String.to_existing_atom(k), v} end)

            if key == :constraints,
              do: Map.update!(item, :type, &String.to_existing_atom/1),
              else: item
          end)
        )

      :error ->
        doc
    end
  end

  # Atom-keyed Definition document from the source JSON .
  defp atomise(raw) do
    raw
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> Map.update!(:fields, fn fields ->
      Enum.map(fields, fn f ->
        f = Map.new(f, fn {k, v} -> {String.to_existing_atom(k), v} end)
        Map.update!(f, :type, &String.to_existing_atom/1)
      end)
    end)
    |> atomise_list(:indexes)
    |> atomise_list(:foreign_keys)
    |> atomise_list(:constraints)
  end

  test "P-01: the pack holds exactly the source entity definitions and the two posting processes" do
    document = pack()

    assert document["pack_id"] == "letflow-assets"

    assert document["entity_definitions"] |> Enum.map(& &1["name"]) |> Enum.sort() ==
             Enum.sort(@types)

    assert document["definitions"] |> Enum.map(& &1["process_key"]) ==
             ["assets_commission", "assets_reversal"]

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
