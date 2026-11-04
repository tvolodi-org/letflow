defmodule Letflow.Modules.Stock.PackDriftTest do
  @moduledoc """
  REQ-700 / GH #3737 (P-DRIFT): `pack.json` is the committed output of `priv/modules/stock/generate_pack.exs`;
  this test re-reads the sources and proves the pack says exactly what they say (definition, content-derived
  id, logical-shape digest). Pure file reads, no database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Entities.Definition.Shape

  @dir Path.join([File.cwd!(), "priv", "modules", "stock"])
  @types ~w(count_order count_order_scope count_commission_member)

  defp pack, do: @dir |> Path.join("pack.json") |> File.read!() |> Jason.decode!()

  defp source(type),
    do: @dir |> Path.join("entity_definitions/#{type}.json") |> File.read!() |> Jason.decode!()

  defp expected_id(type) do
    h =
      :crypto.hash(:sha256, "letflow-stock:" <> type)
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

  test "P-DRIFT the pack lists exactly the three types, in the activation order" do
    assert Enum.map(pack()["entity_definitions"], & &1["name"]) == @types
    assert pack()["pack_id"] == "letflow-stock"
    assert pack()["manifest"] == %{"required_roles" => []}
  end

  for type <- @types do
    test "P-DRIFT #{type}: definition, id and digest equal the source" do
      type = unquote(type)
      entry = Enum.find(pack()["entity_definitions"], &(&1["name"] == type))
      raw = source(type)
      assert entry["definition_json"] == raw
      assert entry["entity_definition_id"] == expected_id(type)

      atomised = atomise(raw)
      assert :ok = Letflow.Entities.Definition.Validator.validate(atomised)

      assert entry["logical_shape_version"] ==
               atomised |> Shape.logical_shape_of() |> Base.encode16(case: :lower)
    end
  end

  defp atomise(raw) do
    raw
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> Map.update!(:fields, fn fields ->
      Enum.map(fields, fn f ->
        f = Map.new(f, fn {k, v} -> {String.to_existing_atom(k), v} end)
        Map.update!(f, :type, &String.to_existing_atom/1)
      end)
    end)
    |> atomise_list(:foreign_keys)
    |> atomise_list(:indexes)
  end

  defp atomise_list(doc, key) do
    case Map.fetch(doc, key) do
      {:ok, list} ->
        Map.put(
          doc,
          key,
          Enum.map(list, &Map.new(&1, fn {k, v} -> {String.to_existing_atom(k), v} end))
        )

      :error ->
        doc
    end
  end
end
